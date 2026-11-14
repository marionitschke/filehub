import AppKit
import Observation

/// A row in either column. `id` is the full path (Mac or server).
struct FileRow: Identifiable, Hashable {
    let id: String
    let name: String
    let isDirectory: Bool
    let isLink: Bool
    let size: Int64?
    let modified: Date?
    /// System file on the server (e.g. an old .DS_Store): greyed out, never transferred.
    let isSystem: Bool
    /// Permission bits of a server entry, if the listing shows them.
    let mode: Int?

    init(remote entry: RemoteEntry) {
        id = entry.path
        name = entry.name
        isDirectory = entry.isDirectory
        isLink = entry.kind == .link
        size = entry.size
        modified = entry.modified
        isSystem = SystemFiles.isSystem(entry.name)
        mode = entry.mode
    }

    init(id: String, name: String, isDirectory: Bool, isLink: Bool, size: Int64?, modified: Date?, isSystem: Bool = false,
         mode: Int? = nil) {
        self.id = id
        self.name = name
        self.isDirectory = isDirectory
        self.isLink = isLink
        self.size = size
        self.modified = modified
        self.isSystem = isSystem
        self.mode = mode
    }

    var remoteEntry: RemoteEntry {
        RemoteEntry(name: name, path: id, kind: isDirectory ? .directory : isLink ? .link : .file, size: size, modified: modified,
                    mode: mode)
    }
}

/// The two columns.
enum Pane { case local, remote }

struct Notice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct Job: Equatable {
    var title: String
    var detail = ""
    var done = 0
    var total = 0
    /// File in progress: path below the target folder, with size.
    var current = ""
    /// Bytes of the first n files in transfer order (n = 0…total), for the share done, speed and time left.
    var bytesBefore: [Int64] = []
    var started = Date()

    init(title: String, total: Int = 0, sizes: [Int64] = []) {
        self.title = title
        self.total = total
        if sizes.contains(where: { $0 > 0 }) {
            var sum: Int64 = 0
            bytesBefore = [0] + sizes.map { sum += $0; return sum }
        }
    }

    /// Share done, by bytes where known, otherwise by files.
    var fraction: Double {
        if let all = bytesBefore.last, all > 0 { return Double(bytesBefore[min(done, bytesBefore.count - 1)]) / Double(all) }
        return total > 0 ? Double(done) / Double(total) : 0
    }

    /// `done` files are finished; the next one in `labels` is in progress. With parallel uploads the
    /// finished files are not exactly the first ones; for the byte count that is close enough.
    mutating func step(_ done: Int, labels: [String], now: Date = Date()) {
        self.done = done
        current = done < labels.count ? labels[done] : ""
        var parts = ["\(done) von \(total)"]
        if let all = bytesBefore.last, all > 0 {
            let finished = bytesBefore[min(done, bytesBefore.count - 1)]
            parts.append("\(Fmt.size(finished)) von \(Fmt.size(all))")
            let elapsed = now.timeIntervalSince(started)
            if elapsed >= 3, finished > 0, done < total {
                let rate = Double(finished) / elapsed
                parts.append("\(Fmt.size(Int64(rate)))/s")
                parts.append("noch \(Fmt.remaining(Double(all - finished) / rate))")
            }
        }
        detail = parts.joined(separator: " · ")
    }

    /// "dist/css/board.min.css · 24 KB": path below the target folder.
    static func label(_ path: String, in base: String, size: Int64?) -> String {
        let prefix = base.hasSuffix("/") ? base : base + "/"
        let shown = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
        return size.map { "\(shown) · \(Fmt.size($0))" } ?? shown
    }
}

struct LogLine: Identifiable, Equatable {
    let id = UUID()
    let time: Date
    let text: String
    let isError: Bool
}

enum ConnectionState: Equatable {
    case offline, connecting, online(ConnectionInfo), failed(String)
}

@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    private(set) var servers: [ServerProfile] = []
    var activeID: UUID? {
        didSet {
            UserDefaults.standard.set(activeID?.uuidString, forKey: "server")
            if activeID != connectedID, connectedID != nil { disconnect() }
        }
    }
    private(set) var connection: ConnectionState = .offline
    private(set) var connectedID: UUID?

    private(set) var localURL: URL
    private(set) var localRows: [FileRow] = []
    var localSelection: Set<String> = []
    /// Mounted volumes, kept current via the macOS mount notifications.
    private(set) var volumes: [LocalPlace] = []

    private(set) var remotePath = "/"
    private(set) var remoteRows: [FileRow] = []
    var remoteSelection: Set<String> = []
    private(set) var remoteLoading = false

    private(set) var job: Job?
    private(set) var log: [LogLine] = []
    /// The column last clicked; menu commands such as Delete act on it.
    var focusedPane: Pane?
    var notice: Notice?
    /// Connection open in the editor (new or existing).
    var editing: ServerProfile?

    @ObservationIgnored private var client: RemoteClient?
    @ObservationIgnored private let queue = DispatchQueue(label: "local.filehub.remote", qos: .userInitiated)
    @ObservationIgnored private var cancellation: Cancellation?
    /// The folder listing in progress: a new one, connecting or disconnecting cancels it, so a
    /// server that stops answering never blocks the app until curl gives up.
    @ObservationIgnored private var listing: Cancellation?
    @ObservationIgnored private var lastStep = Date.distantPast
    @ObservationIgnored private var secrets: [String] = []
    @ObservationIgnored private var home = "/"
    @ObservationIgnored private var volumeObservers: [NSObjectProtocol] = []
    /// Start folder on a volume that is not mounted yet, and where the column went instead.
    @ObservationIgnored private var waitingStart: (path: URL, fallback: URL)?
    /// Keeps the Mac awake while a job runs: idle sleep would drop the connection mid-transfer.
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var jobStarted = Date()

    private init() {
        localURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        watchVolumes()
        #if SNAPSHOT
        return
        #else
        servers = ServerStore.load()
        let saved = UserDefaults.standard.string(forKey: "server").flatMap(UUID.init(uuidString:))
        activeID = servers.first { $0.id == saved }?.id ?? servers.first?.id
        if let server = activeServer {
            if let start = localStart(server) { localURL = start } else { noteMissingStart(server) }
        }
        loadLocal()
        #endif
    }

    // MARK: State

    var activeServer: ServerProfile? { servers.first { $0.id == activeID } }
    var connectedServer: ServerProfile? { servers.first { $0.id == connectedID } }

    var isOnline: Bool {
        if case .online = connection { return true }
        return false
    }

    var connectionInfo: ConnectionInfo? {
        if case .online(let info) = connection { return info }
        return nil
    }

    var isBusy: Bool { job != nil || connection == .connecting }
    /// The column menu commands act on: the one last clicked, otherwise the server while online.
    var actionPane: Pane { focusedPane ?? (isOnline ? .remote : .local) }
    var canTransfer: Bool { isOnline && job == nil }

    var selectedLocal: [FileRow] { localRows.filter { localSelection.contains($0.id) } }
    var selectedRemote: [FileRow] { remoteRows.filter { remoteSelection.contains($0.id) } }

    // MARK: Log and errors

    func record(_ text: String, error: Bool = false) {
        let clean = Redactor.clean(text, secrets: secrets)
        log.append(LogLine(time: Date(), text: clean, isError: error))
        if log.count > 600 { log.removeFirst(log.count - 600) }
        LogFile.append((error ? "FEHLER: " : "") + clean)
    }

    func clearLog() { log.removeAll() }

    private func fail(_ error: Error, action: String) {
        let message = Redactor.clean((error as? LocalizedError)?.errorDescription ?? error.localizedDescription, secrets: secrets)
        if message == RemoteError.cancelled.message {
            record("\(action) abgebrochen.")
            return
        }
        record(message, error: true)
        notice = Notice(title: "\(action) fehlgeschlagen", message: message)
    }

    // MARK: Background

    /// Runs on the serial queue: never two server actions at once.
    private func perform<T>(_ cancel: Cancellation = Cancellation(), _ work: @escaping (Cancellation) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try work(cancel)) } catch { continuation.resume(throwing: error) }
            }
        }
    }

    nonisolated private static func background<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try work()) } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func startJob(_ title: String, total: Int = 0) -> Cancellation {
        let cancel = Cancellation()
        cancellation = cancel
        job = Job(title: title, total: total)
        jobStarted = Date()
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "FileHub überträgt Dateien")
        }
        return cancel
    }

    private func endJob() {
        job = nil
        cancellation = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        guard let app = NSApp else { return }
        app.dockTile.badgeLabel = nil
        // A long transfer finished while FileHub was in the background: bounce the Dock icon once.
        if Date().timeIntervalSince(jobStarted) > 20, !app.isActive { app.requestUserAttention(.informationalRequest) }
    }

    /// Progress of a transfer, also as a percentage on the Dock icon.
    private func step(_ done: Int, labels: [String]) {
        // Uploads report 0 once old folders are deleted: the speed counts from there.
        if done == 0 { job?.started = Date() }
        guard let current = job, done >= current.done else { return }
        // Thousands of small files: at most ten updates a second, the last one always.
        let now = Date()
        guard done == current.total || done == 0 || now.timeIntervalSince(lastStep) >= 0.1 else { return }
        lastStep = now
        job?.step(done, labels: labels, now: now)
        guard let job, job.total > 0 else { return }
        NSApp?.dockTile.badgeLabel = "\(Int(job.fraction * 100)) %"
    }

    func cancelJob() {
        cancellation?.cancel()
    }

    /// Progress from the background, delivered in order on the main thread.
    nonisolated private func progress(_ update: @escaping @MainActor (AppModel) -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { update(AppModel.shared) }
        }
    }

    // MARK: Connect

    func connect() {
        guard let server = activeServer, !isBusy else { return }
        if let problem = server.problem {
            notice = Notice(title: "Verbindung unvollständig", message: problem)
            editing = server
            return
        }
        disconnect(quiet: true)
        connectedID = server.id
        connection = .connecting
        Task { await runConnect(server, askAgain: false) }
    }

    private func runConnect(_ server: ServerProfile, askAgain: Bool) async {
        let cancel = startJob("Verbinden mit \(server.displayName) …")
        defer { endJob() }
        var password: String?
        do {
            if server.proto == .sftp {
                let known = try await Self.background { HostKeys.isKnown(host: server.host, port: server.port) }
                if !known {
                    job?.detail = "Hostschlüssel abfragen …"
                    let scan = try await Self.background { try HostKeys.scan(host: server.host, port: server.port) }
                    guard Dialogs.confirmHostKey(server: server, fingerprints: scan.fingerprints) else {
                        connection = .offline
                        connectedID = nil
                        record("Verbindung abgebrochen: Hostschlüssel von \(server.host) nicht bestätigt.")
                        return
                    }
                    try await Self.background { try HostKeys.trust(scan) }
                    record("Hostschlüssel von \(server.host) bestätigt: \(scan.fingerprints.joined(separator: ", "))")
                }
            }
            if server.usesPassword {
                password = askAgain ? nil : try await Self.background { try Keychain.password(for: server.id) }
                if password == nil {
                    guard let entered = Dialogs.askPassword(server: server, retry: askAgain) else {
                        connection = .offline
                        connectedID = nil
                        return
                    }
                    guard FTPSClient.isSafeSecret(entered.password) else {
                        throw RemoteError("Das Passwort enthält einen Zeilenumbruch oder ein Steuerzeichen und wurde nicht verwendet.")
                    }
                    password = entered.password
                    if entered.save {
                        try await Self.background { try Keychain.setPassword(entered.password, for: server.id) }
                    }
                }
            }
            secrets = [password].compactMap { $0 }
            job?.detail = "Anmelden …"
            let fresh: RemoteClient = server.proto == .sftp
                ? SFTPClient(profile: server, password: password)
                : FTPSClient(profile: server, password: password ?? "")
            let info = try await perform(cancel) { try fresh.connect(cancel: $0) }
            guard connectedID == server.id, !cancel.isCancelled else {
                queue.async { fresh.disconnect() }
                return
            }
            client = fresh
            home = info.home
            connection = .online(info)
            record("Verbunden mit \(server.displayName) (\(server.user)@\(server.host)): \(info.summary)")
            if let start = localStart(server) {
                if start != localURL { loadLocal(start) }
            } else {
                noteMissingStart(server)
            }
            let start = server.remotePath.isEmpty ? info.home : RemotePath.normalize(server.remotePath)
            if !(await listRemote(start)), start != info.home {
                _ = await listRemote(info.home)
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if message == RemoteError.cancelled.message {
                connection = .offline
                connectedID = nil
                record("Verbinden abgebrochen.")
                return
            }
            connection = .failed(message)
            fail(error, action: "Verbinden")
            // Password rejected: ask again right away.
            if server.usesPassword, message.contains("Anmeldung abgelehnt"), !askAgain {
                notice = nil
                endJob()
                connection = .connecting
                connectedID = server.id
                await runConnect(server, askAgain: true)
            }
        }
    }

    func disconnect(quiet: Bool = false) {
        cancellation?.cancel()
        listing?.cancel()
        if let old = client {
            queue.async { old.disconnect() }
            if !quiet { record("Verbindung zu \(old.profile.displayName) getrennt.") }
        }
        client = nil
        connectedID = nil
        connection = .offline
        remoteRows = []
        remoteSelection = []
        secrets = []
    }

    /// On quit: cancel the running transfer and close the SSH connection (at most 3 s).
    func shutdown() {
        cancellation?.cancel()
        guard let old = client else { return }
        client = nil
        let done = DispatchSemaphore(value: 0)
        queue.async {
            old.disconnect()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 3)
    }

    // MARK: Mac side

    /// Configured start folder, whether it exists or not.
    private func localStartPath(_ server: ServerProfile) -> URL? {
        guard !server.localPath.isEmpty else { return nil }
        return URL(fileURLWithPath: (server.localPath as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
    }

    /// Start folder, if it exists right now.
    private func localStart(_ server: ServerProfile) -> URL? {
        guard let url = localStartPath(server) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return url
    }

    /// Start folder missing, usually because the SSD is unplugged: log it and switch there
    /// once the volume appears, unless the user has navigated elsewhere.
    private func noteMissingStart(_ server: ServerProfile) {
        guard let path = localStartPath(server), localStart(server) == nil else {
            waitingStart = nil
            return
        }
        if waitingStart?.path != path {
            if let volume = Places.volumeRoot(of: path), !FileManager.default.fileExists(atPath: volume.path) {
                record("Startordner \(Places.display(path)) liegt auf „\(volume.lastPathComponent)“, das Laufwerk ist nicht angeschlossen. "
                       + "Sobald es da ist, wechselt die Mac-Spalte dorthin.")
            } else {
                record("Startordner \(Places.display(path)) nicht gefunden – bitte in der Verbindung neu wählen.", error: true)
            }
        }
        waitingStart = (path, localURL)
    }

    func loadLocal(_ url: URL? = nil, select: String? = nil) {
        let target = (url ?? localURL).standardizedFileURL
        Task {
            do {
                let rows = try await Self.background { try LocalFiles.list(target) }
                if target != localURL { localSelection = [] }
                localURL = target
                localRows = rows
                if let select { localSelection = [target.appendingPathComponent(select).path] }
                localSelection = localSelection.intersection(rows.map(\.id))
            } catch {
                notice = Notice(title: "Ordner nicht lesbar", message: Self.localReadProblem(target, error))
            }
        }
    }

    /// Error text for an unreadable Mac folder; for a volume, explains where to grant access.
    private static func localReadProblem(_ url: URL, _ error: Error) -> String {
        let nsError = error as NSError
        let denied = nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoPermissionError
        if denied, let volume = Places.volumeRoot(of: url) {
            let network = Places.volumes().first { $0.url == volume }?.kind == .network
            return "macOS lässt FileHub nicht auf „\(volume.lastPathComponent)“ zugreifen. Erlauben unter Systemeinstellungen → "
                + "Datenschutz & Sicherheit → Dateien und Ordner → FileHub → „\(network ? "Netzwerkvolumes" : "Wechselmedien")“. "
                + "Nach einem Neubau von FileHub fragt macOS eventuell noch einmal."
        }
        return "„\(url.path)“: \(error.localizedDescription)"
    }

    func openLocal(_ row: FileRow) {
        guard row.isDirectory else { return }
        loadLocal(URL(fileURLWithPath: row.id, isDirectory: true))
    }

    func localUp() { loadLocal(localURL.deletingLastPathComponent()) }

    func localHome() {
        if let server = activeServer, localStart(server) == nil, let path = localStartPath(server) {
            notice = Notice(title: "Startordner nicht erreichbar",
                            message: Places.volumeRoot(of: path).map { "\(Places.display(path)) liegt auf „\($0.lastPathComponent)“. Ist das Laufwerk angeschlossen?" }
                                ?? "\(Places.display(path)) gibt es nicht mehr. Bitte in der Verbindung neu wählen.")
            return
        }
        loadLocal(activeServer.flatMap(localStart) ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
    }

    func openPlace(_ place: LocalPlace) { loadLocal(place.url) }

    /// Volume the Mac column is on (not the startup volume).
    var localVolume: LocalPlace? {
        volumes.first { $0.kind != .startup && Places.isInside(localURL, $0.url) }
    }

    // MARK: Volumes

    private func watchVolumes() {
        volumes = Places.volumes()
        let center = NSWorkspace.shared.notificationCenter
        let events = [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification]
        for event in events {
            volumeObservers.append(center.addObserver(forName: event, object: nil, queue: .main) { note in
                let volume = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
                let old = note.userInfo?[NSWorkspace.oldVolumeURLUserInfoKey] as? URL
                MainActor.assumeIsolated { AppModel.shared.volumesChanged(event, volume: volume, old: old) }
            })
        }
    }

    private func volumesChanged(_ event: Notification.Name, volume: URL?, old: URL?) {
        volumes = Places.volumes()
        guard let volume = volume?.standardizedFileURL else { return }
        let name = volume.lastPathComponent
        switch event {
        case NSWorkspace.didUnmountNotification:
            guard volume.path != "/", Places.isInside(localURL, volume) else { return }
            let fallback = activeServer.flatMap(localStart).flatMap { Places.isInside($0, volume) ? nil : $0 }
                ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            record("Laufwerk „\(name)“ ist nicht mehr da – Mac-Spalte zurück auf \(Places.display(fallback)).")
            localRows = []
            localSelection = []
            loadLocal(fallback)
        case NSWorkspace.didMountNotification:
            // Don't rely on the reported volume (macOS also reports "/" at login):
            // only the start folder's volume counts.
            guard let waiting = waitingStart, activeServer.flatMap(localStartPath) == waiting.path,
                  let root = Places.volumeRoot(of: waiting.path),
                  FileManager.default.fileExists(atPath: root.path) else { return }
            waitingStart = nil
            guard FileManager.default.fileExists(atPath: waiting.path.path) else {
                record("„\(root.lastPathComponent)“ ist angeschlossen, aber den Startordner \(Places.display(waiting.path)) gibt es dort nicht.", error: true)
                return
            }
            record("„\(root.lastPathComponent)“ angeschlossen.")
            if localURL == waiting.fallback.standardizedFileURL { loadLocal(waiting.path) }
        case NSWorkspace.didRenameVolumeNotification:
            guard let old = old?.standardizedFileURL, Places.isInside(localURL, old) else { return }
            let rest = String(localURL.path.dropFirst(old.path.count))
            loadLocal(URL(fileURLWithPath: volume.path + rest, isDirectory: true))
        default:
            break
        }
    }

    func eject(_ place: LocalPlace) {
        guard place.ejectable else { return }
        if let job {
            notice = Notice(title: "Gerade läuft „\(job.title)“",
                            message: "Erst abwarten oder abbrechen, dann „\(place.name)“ auswerfen.")
            return
        }
        if Places.isInside(localURL, place.url) {
            localRows = []
            localSelection = []
            localURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            loadLocal()
        }
        let url = place.url
        Task {
            do {
                try await Self.background { try NSWorkspace.shared.unmountAndEjectDevice(at: url) }
                record("„\(place.name)“ ausgeworfen – das Laufwerk kann jetzt ab.")
            } catch {
                let reason = (error as NSError).localizedFailureReason ?? error.localizedDescription
                notice = Notice(title: "„\(place.name)“ ließ sich nicht auswerfen",
                                message: "\(reason)\n\nMeist hat noch ein Programm Dateien darauf geöffnet.")
            }
        }
    }

    func chooseLocalFolder() {
        if let url = Dialogs.chooseFolder(start: localURL, title: "Ordner auf dem Mac wählen") { loadLocal(url) }
    }

    func revealLocal() {
        let urls = selectedLocal.map { URL(fileURLWithPath: $0.id) }
        // Reveal only, never open: `open` would launch an app bundle the column is inside.
        if urls.isEmpty {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: localURL.path)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    func newLocalFolder() {
        let folder = localURL
        guard let name = askName(title: "Neuer Ordner", message: "Name des neuen Ordners in „\(folder.lastPathComponent)“:",
                                 value: "", action: "Anlegen") else { return }
        Task {
            do {
                try await Self.background {
                    try FileManager.default.createDirectory(at: folder.appendingPathComponent(name, isDirectory: true),
                                                            withIntermediateDirectories: false)
                }
                record("Ordner auf dem Mac angelegt: \(Places.display(folder.appendingPathComponent(name)))")
            } catch {
                notice = Notice(title: "Ordner anlegen fehlgeschlagen", message: error.localizedDescription)
            }
            loadLocal(folder, select: name)
        }
    }

    func renameLocal() {
        guard let row = selectedLocal.first, selectedLocal.count == 1,
              let name = askName(title: "Umbenennen", message: "Neuer Name für „\(row.name)“:", value: row.name, action: "Umbenennen"),
              name != row.name else { return }
        let source = URL(fileURLWithPath: row.id)
        let target = source.deletingLastPathComponent().appendingPathComponent(name)
        Task {
            do {
                try await Self.background {
                    // Only a change of case may hit the "same" file on a case-insensitive volume;
                    // anything else must never replace an existing item.
                    if name.lowercased() == row.name.lowercased() {
                        guard Darwin.rename(source.path, target.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    } else {
                        try FileManager.default.moveItem(at: source, to: target)
                    }
                }
                record("Auf dem Mac umbenannt: \(row.name) → \(name)")
            } catch {
                notice = Notice(title: "Umbenennen fehlgeschlagen", message: error.localizedDescription)
            }
            loadLocal(select: name)
        }
    }

    /// To the Trash, never deleted for good. On volumes without a Trash this fails with a notice.
    func trashLocal() {
        let rows = selectedLocal
        guard !rows.isEmpty, job == nil else { return }
        Task {
            let failures = (try? await Self.background {
                rows.compactMap { row -> String? in
                    do {
                        try FileManager.default.trashItem(at: URL(fileURLWithPath: row.id), resultingItemURL: nil)
                        return nil
                    } catch {
                        return "„\(row.name)“: \(error.localizedDescription)"
                    }
                }
            }) ?? []
            let moved = rows.count - failures.count
            if moved > 0 { record("In den Papierkorb gelegt: \(Fmt.names(rows.map(\.name), limit: 5))" + (failures.isEmpty ? "" : " (\(moved) von \(rows.count))")) }
            if !failures.isEmpty {
                notice = Notice(title: "Nicht in den Papierkorb",
                                message: failures.joined(separator: "\n") + "\n\nManche Laufwerke haben keinen Papierkorb – dort im Finder löschen.")
            }
            loadLocal()
        }
    }

    /// A single new name from the user, or nil (cancelled, unchanged or invalid, with a notice).
    private func askName(title: String, message: String, value: String, action: String) -> String? {
        guard let name = Dialogs.text(title: title, message: message, value: value, action: action)?
            .trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        // ":" shows as "/" in the Finder.
        guard RemotePath.isSafeName(name), !name.contains(":") else {
            notice = Notice(title: "Name nicht möglich", message: "„\(name)“ darf weder „/“, „:“ noch Steuerzeichen enthalten.")
            return nil
        }
        return name
    }

    /// Paths of the selection in a column (or its folder) as text, one per line.
    func copyPaths(_ pane: Pane) {
        let paths: [String]
        switch pane {
        case .local: paths = selectedLocal.isEmpty ? [localURL.path] : selectedLocal.map(\.id)
        case .remote: paths = selectedRemote.isEmpty ? [remotePath] : selectedRemote.map(\.id)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.sorted().joined(separator: "\n"), forType: .string)
    }

    func openSelection(_ pane: Pane) {
        switch pane {
        case .local: if let row = selectedLocal.first, selectedLocal.count == 1 { openLocal(row) }
        case .remote: if let row = selectedRemote.first, selectedRemote.count == 1 { openRemote(row) }
        }
    }

    func goUp(_ pane: Pane) {
        switch pane {
        case .local: if localURL.path != "/" { localUp() }
        case .remote: if canTransfer, remotePath != "/" { remoteUp() }
        }
    }

    // MARK: Server side

    @discardableResult
    private func listRemote(_ path: String, select: String? = nil) async -> Bool {
        guard let client else { return false }
        let target = RemotePath.normalize(path)
        listing?.cancel()
        let cancel = Cancellation()
        listing = cancel
        remoteLoading = true
        defer { if listing === cancel { remoteLoading = false } }
        do {
            let entries = try await perform(cancel) { try client.list(target, cancel: $0) }
            guard !cancel.isCancelled else { return false }
            guard self.client === client else { return false }
            if target != remotePath { remoteSelection = [] }
            remotePath = target
            remoteRows = entries.map(FileRow.init(remote:))
            if let select { remoteSelection = [RemotePath.join(target, select)] }
            remoteSelection = remoteSelection.intersection(remoteRows.map(\.id))
            return true
        } catch {
            // Replaced by a newer listing or a disconnect: nothing to report.
            if !cancel.isCancelled { fail(error, action: "Ordner lesen") }
            return false
        }
    }

    func loadRemote(_ path: String? = nil) {
        guard isOnline else { return }
        Task { await listRemote(path ?? remotePath) }
    }

    func openRemote(_ row: FileRow) {
        guard row.isDirectory || row.isLink, job == nil else { return }
        loadRemote(row.id)
    }

    func remoteUp() { loadRemote(RemotePath.parent(remotePath)) }

    func remoteHome() {
        guard let server = connectedServer else { return }
        loadRemote(server.remotePath.isEmpty ? home : server.remotePath)
    }

    func goRemote(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, RemotePath.isSafe(trimmed) else { return }
        loadRemote(trimmed.hasPrefix("/") ? trimmed : RemotePath.join(remotePath, trimmed))
    }

    func refreshBoth() {
        loadLocal()
        loadRemote()
    }

    // MARK: Upload

    func uploadSelection() {
        upload(selectedLocal.map { URL(fileURLWithPath: $0.id) })
    }

    func upload(_ urls: [URL], into folder: String? = nil) {
        guard let client, let server = connectedServer, canTransfer, !urls.isEmpty else { return }
        let target = RemotePath.normalize(folder ?? remotePath)
        Task { await runUpload(urls, target: target, client: client, server: server) }
    }

    private func runUpload(_ urls: [URL], target: String, client: RemoteClient, server: ServerProfile) async {
        do {
            let cancel = startJob("Hochladen vorbereiten …")
            defer { endJob() }
            do {
                let plan = try await Self.background {
                    UploadPlan.build(items: urls, into: target, neverUpload: server.neverUploadPatterns,
                                     uploadLast: server.uploadLastPatterns, replace: server.replacePatterns)
                }
                let skipped = plan.skippedSummary
                guard !plan.files.isEmpty || !plan.directories.isEmpty else {
                    notice = Notice(title: "Nichts hochzuladen",
                                    message: (["Die Auswahl enthält nur Dateien, die FileHub nie überträgt."] + skipped).joined(separator: "\n"))
                    return
                }
                job?.detail = "Ziel prüfen …"
                let dist = try await perform(cancel) { try Transfers.oldVersions(plan, client: client, cancel: $0) }
                let summary = "\(Fmt.count(plan.files.count, "Datei", "Dateien")) (\(Fmt.size(plan.totalBytes)))"
                // Replace rules apply without confirmation (per-connection rule, logged).
                record("Hochladen nach \(target): \(summary)" + (skipped.isEmpty ? "" : "; " + skipped.joined(separator: ", ")))
                job = Job(title: "Hochladen nach \(RemotePath.name(target))", total: plan.files.count, sizes: plan.files.map(\.size))
                let labels = plan.files.map { Job.label($0.remote, in: target, size: $0.size) }
                let report = try await perform(cancel) { [weak self] cancel in
                    try Transfers.upload(plan, replacing: dist, client: client, cancel: cancel) { step in
                        self?.progress { model in
                            switch step {
                            case .deleting(let path): model.job?.detail = "Lösche \(path) …"
                            case .transferring(let done): model.step(done, labels: labels)
                            }
                        }
                    }
                }
                for tree in dist where report.replaced.contains(tree.root) {
                    record("Vorher gelöscht: \(tree.root) (\(Fmt.count(tree.files.count, "Datei", "Dateien")))")
                }
                record("Hochgeladen: \(Fmt.count(report.uploaded, "Datei", "Dateien")) (\(Fmt.size(report.bytes))) nach \(target).")
            } catch {
                fail(error, action: "Hochladen")
            }
        }
        await listRemote(remotePath)
    }

    // MARK: Download

    func downloadSelection() {
        download(selectedRemote.map(\.id))
    }

    func download(_ paths: [String], into folder: URL? = nil) {
        guard let client, canTransfer else { return }
        let wanted = Set(paths)
        let entries = remoteRows.filter { wanted.contains($0.id) }.map(\.remoteEntry)
        guard !entries.isEmpty else { return }
        let target = folder ?? localURL
        Task { await runDownload(entries, target: target, client: client) }
    }

    private func runDownload(_ entries: [RemoteEntry], target: URL, client: RemoteClient) async {
        do {
            let cancel = startJob("Herunterladen vorbereiten …")
            defer { endJob() }
            do {
                let plan = try await perform(cancel) { try DownloadPlan.build(entries, into: target, client: client, cancel: $0) }
                let skipped = plan.skippedSummary
                guard !plan.files.isEmpty || !plan.directories.isEmpty else {
                    notice = Notice(title: "Nichts herunterzuladen",
                                    message: (["Die Auswahl enthält nur Dateien, die FileHub nie überträgt."] + skipped).joined(separator: "\n"))
                    return
                }
                if !plan.existing.isEmpty {
                    let names = Fmt.names(plan.existing.map(\.lastPathComponent))
                    let message = "\(names) gibt es in „\(target.lastPathComponent)“ schon. Gleichnamige Dateien werden überschrieben."
                    guard Dialogs.confirm(title: "Vorhandenes auf dem Mac ersetzen?", message: message,
                                          action: "Ersetzen", destructive: true) else { return }
                }
                let summary = "\(Fmt.count(plan.files.count, "Datei", "Dateien")) (\(Fmt.size(plan.totalBytes)))"
                if let free = Places.freeSpace(at: target), plan.totalBytes > free {
                    let drive = Places.volumes().first { $0.kind != .startup && Places.isInside(target, $0.url) }
                    notice = Notice(title: "Nicht genug Platz",
                                    message: "\(summary) \(plan.files.count == 1 ? "passt" : "passen") nicht auf "
                                        + "\(drive.map { "„\($0.name)“" } ?? "den Mac"): "
                                        + "frei sind nur \(Fmt.size(free)).")
                    return
                }
                record("Herunterladen nach \(target.path): \(summary)" + (skipped.isEmpty ? "" : "; " + skipped.joined(separator: ", ")))
                job = Job(title: "Herunterladen nach \(target.lastPathComponent)", total: plan.files.count,
                          sizes: plan.files.map { $0.size ?? 0 })
                let labels = plan.files.map { Job.label($0.local.path, in: target.standardizedFileURL.path, size: $0.size) }
                try await perform(cancel) { [weak self] cancel in
                    try Transfers.download(plan, client: client, cancel: cancel) { done in
                        self?.progress { model in model.step(done, labels: labels) }
                    }
                }
                record("Heruntergeladen: \(summary).")
            } catch {
                fail(error, action: "Herunterladen")
            }
        }
        loadLocal()
    }

    // MARK: Server folders, rename, delete

    func newRemoteFolder() {
        guard let client, canTransfer,
              let name = Dialogs.text(title: "Neuer Ordner", message: "Name des neuen Ordners in „\(remotePath)“:",
                                      value: "", action: "Anlegen")?.trimmingCharacters(in: .whitespaces),
              !name.isEmpty else { return }
        guard RemotePath.isSafeName(name) else {
            notice = Notice(title: "Name nicht möglich", message: "„\(name)“ darf weder „/“ noch Steuerzeichen enthalten.")
            return
        }
        let path = RemotePath.join(remotePath, name)
        Task {
            _ = startJob("Ordner anlegen …")
            defer { endJob() }
            do {
                try await perform { try client.makeDirectory(path, cancel: $0) }
                record("Ordner angelegt: \(path)")
            } catch {
                fail(error, action: "Ordner anlegen")
            }
            await listRemote(remotePath, select: name)
        }
    }

    func renameRemote() {
        guard let client, canTransfer, let row = selectedRemote.first, selectedRemote.count == 1,
              let name = Dialogs.text(title: "Umbenennen", message: "Neuer Name für „\(row.name)“:",
                                      value: row.name, action: "Umbenennen")?.trimmingCharacters(in: .whitespaces),
              !name.isEmpty, name != row.name else { return }
        guard RemotePath.isSafeName(name) else {
            notice = Notice(title: "Name nicht möglich", message: "„\(name)“ darf weder „/“ noch Steuerzeichen enthalten.")
            return
        }
        let target = RemotePath.join(RemotePath.parent(row.id), name)
        // FTP and SFTP servers replace an existing entry without asking.
        if let existing = remoteRows.first(where: { $0.name == name }) {
            guard Dialogs.confirm(title: "„\(name)“ gibt es schon", message: "\(existing.isDirectory ? "Der Ordner" : "Die Datei") „\(name)“ in "
                                    + "„\(RemotePath.name(RemotePath.parent(row.id)))“ wird ersetzt und ist danach weg. Trotzdem umbenennen?",
                                  action: "Ersetzen", destructive: true) else { return }
        }
        Task {
            _ = startJob("Umbenennen …")
            defer { endJob() }
            do {
                try await perform { try client.rename(row.id, to: target, cancel: $0) }
                record("Umbenannt: \(row.id) → \(name)")
            } catch {
                fail(error, action: "Umbenennen")
            }
            await listRemote(remotePath, select: name)
        }
    }

    func deleteRemote() {
        let rows = selectedRemote
        guard let client, canTransfer, !rows.isEmpty else { return }
        let folders = rows.contains { $0.isDirectory }
        guard Dialogs.confirm(title: rows.count == 1 ? "„\(rows[0].name)“ löschen?" : "\(rows.count) Einträge löschen?",
                              message: "\(Fmt.names(rows.map(\.name))) \(folders ? "samt Inhalt " : "")endgültig von "
                                + "\(connectedServer?.displayName ?? "dem Server") löschen? Das lässt sich nicht rückgängig machen.",
                              action: "Löschen", destructive: true) else { return }
        Task {
            let cancel = startJob("Löschen …")
            defer { endJob() }
            do {
                let count = try await perform(cancel) { try client.deleteRecursively(rows.map(\.remoteEntry), ignoreErrors: false, cancel: $0) }
                record("Gelöscht auf dem Server: \(rows.map(\.id).joined(separator: ", ")) (\(Fmt.count(count, "Datei", "Dateien")))")
            } catch {
                fail(error, action: "Löschen")
            }
            await listRemote(remotePath)
        }
    }

    /// Permission bits of the selection (not recursive), with the common 3×3 dialog.
    func changeRemoteMode() {
        // chmod follows links and would change their target, possibly outside the folder.
        let rows = selectedRemote.filter { !$0.isLink }
        guard let client, canTransfer, let first = rows.first else { return }
        let modes = Set(rows.map(\.mode))
        let current = first.mode ?? (first.isDirectory ? 0o755 : 0o644)
        var message = rows.count == 1 ? "Für „\(first.name)“ auf \(connectedServer?.displayName ?? "dem Server")."
            : "Für \(Fmt.names(rows.map(\.name))) auf \(connectedServer?.displayName ?? "dem Server")."
        if modes.count > 1 { message += " Die Auswahl hat unterschiedliche Rechte; alle bekommen dieselben." }
        if rows.contains(where: \.isDirectory) { message += " Inhalte von Ordnern bleiben unverändert." }
        guard let mode = Dialogs.permissions(title: "Rechte ändern", message: message, mode: current) else { return }
        Task {
            let cancel = startJob("Rechte ändern …")
            defer { endJob() }
            do {
                try await perform(cancel) { try client.changeMode(rows.map(\.id), to: mode, cancel: $0) }
                record("Rechte \(FileMode.octal(mode)) (\(FileMode.symbolic(mode))) gesetzt: \(rows.map(\.id).joined(separator: ", "))")
            } catch {
                fail(error, action: "Rechte ändern")
            }
            await listRemote(remotePath)
        }
    }

    // MARK: Connections

    func newServer() {
        var profile = ServerProfile()
        profile.localPath = Places.display(localURL)
        editing = profile
    }

    func editServer() {
        editing = activeServer
    }

    func isNew(_ profile: ServerProfile) -> Bool { !servers.contains { $0.id == profile.id } }

    /// Saves a connection. `password` nil keeps the stored password.
    func save(_ profile: ServerProfile, password: String?, removePassword: Bool) throws {
        var profile = profile
        profile.name = profile.name.trimmingCharacters(in: .whitespaces)
        profile.host = profile.host.trimmingCharacters(in: .whitespaces)
        profile.user = profile.user.trimmingCharacters(in: .whitespaces)
        profile.remotePath = profile.remotePath.trimmingCharacters(in: .whitespaces)
        if let problem = profile.problem { throw RemoteError(problem) }
        if let password, !FTPSClient.isSafeSecret(password) {
            throw RemoteError("Das Passwort darf keinen Zeilenumbruch und keine Steuerzeichen enthalten.")
        }
        let previous = servers.first { $0.id == profile.id }
        var updated = servers
        if let index = updated.firstIndex(where: { $0.id == profile.id }) { updated[index] = profile } else { updated.append(profile) }
        try ServerStore.save(updated)
        if removePassword {
            try Keychain.setPassword(nil, for: profile.id)
        } else if let password, !password.isEmpty {
            try Keychain.setPassword(password, for: profile.id)
        }
        servers = updated
        let relevant = previous.map { old in
            old.proto != profile.proto || old.host != profile.host || old.port != profile.port || old.user != profile.user
                || old.auth != profile.auth || old.keyPath != profile.keyPath
        } ?? false
        if connectedID == profile.id, relevant || password?.isEmpty == false || removePassword {
            disconnect()
            record("Einstellungen von \(profile.displayName) geändert – bitte neu verbinden.")
        }
        if previous == nil { activeID = profile.id }
        record(previous == nil ? "Verbindung angelegt: \(profile.displayName)" : "Verbindung gespeichert: \(profile.displayName)")
    }

    func deleteServer(_ profile: ServerProfile? = nil) {
        guard let server = profile ?? activeServer,
              Dialogs.confirm(title: "„\(server.displayName)“ löschen?",
                              message: "Die Verbindung und ihr Passwort im Schlüsselbund werden entfernt. Dateien bleiben unberührt.",
                              action: "Löschen", destructive: true) else { return }
        if connectedID == server.id { disconnect() }
        let remaining = servers.filter { $0.id != server.id }
        do {
            try ServerStore.save(remaining)
            try? Keychain.setPassword(nil, for: server.id)
            if !remaining.contains(where: { $0.proto == .sftp && $0.host == server.host && $0.port == server.port }) {
                HostKeys.forget(host: server.host, port: server.port)
            }
            servers = remaining
            activeID = remaining.first?.id
            editing = nil
            record("Verbindung gelöscht: \(server.displayName)")
        } catch {
            fail(error, action: "Löschen")
        }
    }

    func forgetHostKey(_ profile: ServerProfile) {
        if connectedID == profile.id { disconnect() }
        HostKeys.forget(host: profile.host, port: profile.port)
        record("Gespeicherten Hostschlüssel von \(profile.host):\(profile.port) entfernt. Beim nächsten Verbinden wird er neu abgefragt.")
    }

    // MARK: Setup transfer to other Macs

    func exportSetup() {
        guard !servers.isEmpty else {
            notice = Notice(title: "Nichts zu exportieren", message: "Es gibt noch keine Verbindung.")
            return
        }
        guard let password = Dialogs.newPassword(servers: servers.map(\.displayName)),
              let url = Dialogs.saveLocation() else { return }
        let servers = self.servers
        Task {
            do {
                let data = try await Self.background { () -> Data in
                    let ids = Set(servers.map(\.id.uuidString))
                    let passwords = try Keychain.passwords().filter { ids.contains($0.key) }
                    let payload = SetupTransfer.Payload(created: Fmt.logStamp(Date()), servers: servers,
                                                        passwords: passwords, knownHosts: HostKeys.exportText())
                    return try SetupTransfer.seal(payload, password: password)
                }
                try ServerStore.writePrivate(data, to: url)
                record("Verbindungen exportiert: \(url.path)")
                notice = Notice(title: "Exportiert",
                                message: "„\(url.lastPathComponent)“ enthält \(Fmt.count(servers.count, "Verbindung", "Verbindungen")) samt "
                                    + "Passwörtern und bestätigten Hostschlüsseln, verschlüsselt mit deinem Passwort. Per AirDrop auf den "
                                    + "anderen Mac, dort „Verbindung → Verbindungen importieren …“ – danach die Datei auf beiden Macs löschen. "
                                    + "SSH-Schlüssel reisen nicht mit.")
            } catch {
                fail(error, action: "Exportieren")
            }
        }
    }

    func importSetup() {
        guard let url = Dialogs.openLocation(), let password = Dialogs.password(file: url.lastPathComponent) else { return }
        Task {
            do {
                let payload = try await Self.background { () -> SetupTransfer.Payload in
                    let size = (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
                    guard size <= SetupTransfer.maxFileSize else { throw SetupTransfer.Failure.notASetupFile }
                    return try SetupTransfer.open(try Data(contentsOf: url), password: password)
                }
                // Only take complete, valid connections (host, user and paths checked).
                let accepted = payload.servers.filter { $0.problem == nil }
                let rejected = payload.servers.count - accepted.count
                var merged = servers
                for server in accepted {
                    if let index = merged.firstIndex(where: { $0.id == server.id }) { merged[index] = server } else { merged.append(server) }
                }
                let ids = Set(accepted.map(\.id.uuidString))
                let passwords = payload.passwords.filter { ids.contains($0.key) && FTPSClient.isSafeSecret($0.value) }
                try await Self.background {
                    try ServerStore.save(merged)
                    var all = try Keychain.passwords()
                    all.merge(passwords) { _, new in new }
                    try Keychain.store(all)
                    try HostKeys.importText(payload.knownHosts)
                }
                if let connected = connectedID, accepted.contains(where: { $0.id == connected }) { disconnect() }
                servers = merged
                if activeID == nil { activeID = merged.first?.id }
                record("Verbindungen importiert aus \(url.lastPathComponent): \(accepted.map(\.displayName).joined(separator: ", "))"
                       + (rejected > 0 ? " (\(rejected) ungültige ausgelassen)" : ""))
                notice = Notice(title: "Importiert",
                                message: "\(Fmt.count(accepted.count, "Verbindung", "Verbindungen")) übernommen. "
                                    + (rejected > 0 ? "\(Fmt.count(rejected, "ungültige Verbindung", "ungültige Verbindungen")) ausgelassen. " : "")
                                    + "Die Datei „\(url.lastPathComponent)“ jetzt löschen.")
            } catch {
                fail(error, action: "Importieren")
            }
        }
    }

    #if SNAPSHOT
    /// Snapshot build only: demo data without network or keychain.
    func setDemo(servers: [ServerProfile], local: URL, localRows: [FileRow], remotePath: String, remoteRows: [FileRow],
                 info: ConnectionInfo?, job: Job?, log: [String]) {
        self.servers = servers
        activeID = servers.first?.id
        connectedID = info == nil ? nil : servers.first?.id
        connection = info.map { .online($0) } ?? .offline
        localURL = local
        self.localRows = localRows
        self.remotePath = remotePath
        self.remoteRows = remoteRows
        self.job = job
        self.log = log.map { LogLine(time: Date(), text: $0, isError: $0.hasPrefix("!")) }
    }
    #endif
}

enum LocalFiles {
    /// Mac folder contents without system files. Dotfiles like .htaccess stay visible.
    static func list(_ url: URL) throws -> [FileRow] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .isPackageKey]
        return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [])
            .filter { !SystemFiles.isSystem($0.lastPathComponent) }
            .map { item in
                let values = try? item.resourceValues(forKeys: Set(keys))
                let isLink = values?.isSymbolicLink == true
                return FileRow(id: item.path, name: item.lastPathComponent, isDirectory: values?.isDirectory == true && !isLink,
                               isLink: isLink, size: values?.fileSize.map(Int64.init), modified: values?.contentModificationDate)
            }
    }
}
