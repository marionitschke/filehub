import Foundation

/// FTP over explicit TLS (AUTH TLS) via /usr/bin/curl. Control and data channels are always
/// encrypted (`ssl-reqd`, PROT P), TLS 1.2 or later, certificate and host name are always verified.
/// If the server offers no TLS, curl aborts. Credentials go with the config via stdin (`-K -`),
/// never as an argument.
final class FTPSClient: RemoteClient, @unchecked Sendable {
    let profile: ServerProfile
    private let password: String
    /// MLSD gives machine-readable listings including dotfiles; older servers (vsftpd) lack it.
    private var listCommand = "MLSD"
    /// vsftpd requires the control channel's TLS session on the data channel, which fails with
    /// curl/LibreSSL over TLS 1.3 (reply 522). Such a connection then stays on TLS 1.2.
    private var tls12Only = false
    /// curl up to 8.8 (macOS ships 8.7.1) closes the TLS 1.3 data connection of an upload without a
    /// proper shutdown; ProFTPD (All-inkl) then replies 426 and discards the file (curl#13556, fixed
    /// in 8.9.0). Uploads therefore use TLS 1.2, listing and downloads stay on TLS 1.3.
    /// Lazy so that `curl --version` never runs on the main thread.
    private lazy var uploadTLS12 = Self.curlHasUploadBug
    /// The server refused a second connection: stay on one for this session.
    private var parallelRefused = false

    #if CHECKS
    /// Checks build only: CA of the Docker test server (scripts/testserver.sh).
    nonisolated(unsafe) static var testCA = ProcessInfo.processInfo.environment["FILEHUB_TEST_CA"]
    #endif

    init(profile: ServerProfile, password: String) {
        self.profile = profile
        self.password = password
    }

    // MARK: RemoteClient

    func connect(cancel: Cancellation) throws -> ConnectionInfo {
        guard Self.isSafeSecret(password) else {
            throw RemoteError("Das Passwort enthält einen Zeilenumbruch oder ein Steuerzeichen. FTP machte daraus einen "
                + "zweiten Befehl – FileHub verbindet so nicht. Bitte das Passwort neu eingeben.")
        }
        var result = probe(cancel: cancel)
        if !result.ok, Self.needsTLS12(result) {
            tls12Only = true
            result = probe(cancel: cancel)
        }
        guard result.ok else { throw failure(result, action: "Verbinden") }

        // Parse the verbose output, never log it (it contains "PASS …").
        let lines = result.errors.split(whereSeparator: \.isNewline).map(String.init)
            .filter { !$0.contains("PASS") }
        func value(after marker: String) -> String? {
            lines.first { $0.contains(marker) }.flatMap { line in
                line.range(of: marker).map { line[$0.upperBound...].trimmingCharacters(in: .whitespaces) }
            }
        }
        let tls = value(after: "SSL connection using")?.components(separatedBy: " / ") ?? []
        let version = tls.first ?? "TLS"
        let subject = value(after: "subject:") ?? ""
        let issuer = value(after: "issuer:") ?? ""
        let expires = value(after: "expire date:") ?? ""
        var home = "/"
        if let reply = lines.first(where: { $0.hasPrefix("< 257 ") }),
           let open = reply.firstIndex(of: "\""), let close = reply[reply.index(after: open)...].firstIndex(of: "\"") {
            home = RemotePath.normalize(String(reply[reply.index(after: open)..<close]))
        }
        guard lines.contains(where: { $0.contains("SSL certificate verify ok") }) else {
            throw RemoteError("Das Zertifikat des Servers ließ sich nicht bestätigen. FileHub verbindet nicht.")
        }
        var details = ["Protokoll: FTP über TLS (explizit), Daten verschlüsselt", "TLS: \(tls.prefix(2).joined(separator: ", "))"]
        if !subject.isEmpty { details.append("Zertifikat: \(subject)") }
        if !issuer.isEmpty { details.append("Aussteller: \(issuer)") }
        if !expires.isEmpty { details.append("Gültig bis: \(expires)") }
        if tls12Only {
            details.append("Auf TLS 1.2 begrenzt (Server verlangt TLS-Sitzung im Datenkanal)")
        } else if uploadTLS12 {
            details.append("Hochladen über TLS 1.2 (curl von macOS beendet TLS-1.3-Datenverbindungen nicht sauber)")
        }
        return ConnectionInfo(summary: "FTPS · \(version) · Zertifikat geprüft", details: details, home: home)
    }

    func list(_ path: String, cancel: Cancellation) throws -> [RemoteEntry] {
        guard let result = try listMany([path], cancel: cancel)[path] else { throw RemoteError("Ordner lesen: keine Antwort.") }
        return try result.get()
    }

    /// All folders in one curl call: curl keeps the connection open between URLs and logs in once.
    /// `fail-early`: if the login fails, curl does not retry for every folder (which would look like
    /// password guessing to the provider). A missing folder stops curl there; the rest follows in the
    /// next call.
    func listMany(_ paths: [String], cancel: Cancellation) throws -> [String: Result<[RemoteEntry], RemoteError>] {
        guard paths.allSatisfy(RemotePath.isSafe) else { throw RemoteError("Unzulässiger Pfad.") }
        var results: [String: Result<[RemoteEntry], RemoteError>] = [:]
        var pending = paths[...]
        while !pending.isEmpty {
            let chunk = Array(pending.prefix(Self.listBatch))
            let marker = Self.newMarker()
            // singlecwd: one "CWD /full/path" instead of one CWD per level; a missing folder still fails.
            var lines = baseConfig() + ["fail-early", "ftp-method = singlecwd", "request = \(Self.quote(listCommand))",
                                        "write-out = \"\(marker) %{exitcode}\\n\""]
            lines += chunk.map { "url = \(Self.quote(directoryURL($0)))" }
            let result = curl(lines, cancel: cancel)
            if result.cancelled { throw RemoteError.cancelled }
            if result.truncated { throw RemoteError("Ordner lesen: Die Liste ist zu groß (über 32 MB).") }
            let segments = Self.segments(result.output, marker: marker)
            guard !segments.isEmpty else { throw failure(result, action: "Ordner lesen") }
            var consumed = 0
            for (path, segment) in zip(chunk, segments) {
                switch segment.status {
                case 0:
                    results[path] = .success(listCommand == "MLSD"
                        ? ListingParser.mlsd(segment.body, in: path)
                        : ListingParser.unix(segment.body, in: path, timeZone: TimeZone(identifier: "UTC")!))
                case 9, 78:
                    results[path] = .failure(RemoteError("Ordner lesen: Ordner nicht vorhanden oder kein Zugriff."))
                case 19 where Self.deniedReply(result.errors):
                    // An unreadable folder, not an unknown command (curl reports both as 19).
                    results[path] = .failure(RemoteError("Ordner lesen: Kein Zugriff auf „\(RemotePath.name(path))“."))
                case 19 where listCommand != "LIST":
                    // Listing command unknown: fall back to LIST -a (shows .htaccess), then LIST.
                    listCommand = listCommand == "MLSD" ? "LIST -a" : "LIST"
                    break
                default:
                    throw failure(status: segment.status, errors: result.errors, action: "Ordner lesen")
                }
                if results[path] == nil { break }
                consumed += 1
            }
            pending = pending.dropFirst(consumed)
        }
        return results
    }

    func makeDirectory(_ path: String, cancel: Cancellation) throws {
        try command(["MKD \(path)"], cancel: cancel, action: "Ordner anlegen")
    }

    func rename(_ from: String, to: String, cancel: Cancellation) throws {
        try command(["RNFR \(from)", "RNTO \(to)"], cancel: cancel, action: "Umbenennen")
    }

    func changeMode(_ paths: [String], to mode: Int, cancel: Cancellation) throws {
        for chunk in Self.chunks(paths.map { "SITE CHMOD \(FileMode.octal(mode)) \($0)" }, of: Self.commandBatch) {
            try command(chunk, cancel: cancel, action: "Rechte ändern")
        }
    }

    func delete(files: [String], directories: [String], ignoreErrors: Bool, cancel: Cancellation) throws {
        for chunk in Self.chunks(Self.deleteCommands(files: files, directories: directories, ignoreErrors: ignoreErrors),
                                 of: Self.commandBatch) {
            try command(chunk, cancel: cancel, action: "Löschen")
        }
    }

    /// Delete commands, then list `path`, all with one login (curl sends the commands before
    /// listing). Returns whether `path` still exists.
    func delete(files: [String], directories: [String], ignoreErrors: Bool, thenCheck path: String,
                cancel: Cancellation) throws -> Bool {
        var batches = Self.chunks(Self.deleteCommands(files: files, directories: directories, ignoreErrors: ignoreErrors),
                                  of: Self.commandBatch)
        let last = batches.popLast() ?? []
        for chunk in batches {
            try command(chunk, cancel: cancel, action: "Löschen")
        }
        guard RemotePath.isSafe(path), last.allSatisfy(RemotePath.isSafe) else { throw RemoteError("Unzulässiger Pfad.") }
        let marker = Self.newMarker()
        var lines = baseConfig() + ["ftp-method = singlecwd", "request = \(Self.quote(listCommand))",
                                    "write-out = \"\(marker) %{exitcode}\\n\""]
        lines += last.map { "quote = \(Self.quote($0))" }
        lines.append("url = \(Self.quote(directoryURL(path)))")
        let result = curl(lines, cancel: cancel)
        if result.cancelled { throw RemoteError.cancelled }
        guard let status = Self.segments(result.output, marker: marker).last?.status else {
            throw failure(result, action: "Löschen")
        }
        switch status {
        case 0: return true
        case 9, 78: return false
        default: throw failure(status: status, errors: result.errors, action: "Löschen")
        }
    }

    static func deleteCommands(files: [String], directories: [String], ignoreErrors: Bool) -> [String] {
        let prefix = ignoreErrors ? "*" : ""
        return files.map { "\(prefix)DELE \($0)" } + directories.map { "\(prefix)RMD \($0)" }
    }

    func upload(_ files: [UploadPlan.File], directories: [String], last: Int, cancel: Cancellation,
                progress: @escaping (Int) -> Void) throws {
        // "*": existing folders are not an error.
        let folders = Self.chunks(directories.map { "*MKD \($0)" }, of: Self.commandBatch)
        guard !files.isEmpty else {
            for chunk in folders { try command(chunk, cancel: cancel, action: "Ordner anlegen") }
            return
        }
        let counter = UploadCounter(progress)
        let split = max(files.count - min(max(last, 0), files.count), 0)
        let main = Array(files[..<split]), tail = Array(files[split...])
        guard main.count >= Self.parallelMinimum, !parallelRefused else {
            uploadTLS12 = try send(files[...], folders: folders, tls12: uploadTLS12, cancel: cancel) { counter.add() }
            return
        }
        // Two connections, like FileZilla's default. The second one logs in only after the first has
        // uploaded a file: a wrong password or a broken folder never costs two logins.
        let first = main.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
        let second = main.enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
        let tls12 = uploadTLS12
        let parallel = ParallelUpload()
        let group = DispatchGroup()
        // Each connection stops the other when it fails, instead of finishing its half first.
        let firstCancel = cancel.child(), secondCancel = cancel.child()
        var firstError: Error?
        var firstTLS12 = tls12
        do {
            firstTLS12 = try send(first[...], folders: folders, tls12: tls12, cancel: firstCancel) {
                counter.add()
                guard parallel.claimStart() else { return }
                DispatchQueue.global(qos: .userInitiated).async(group: group) { [self] in
                    do {
                        _ = try send(second[...], folders: [], tls12: tls12, cancel: secondCancel) {
                            parallel.sent()
                            counter.add()
                        }
                    } catch {
                        // Refused before its first file (connection limit): the first carries on.
                        if parallel.fail(error) > 0 { firstCancel.cancel() }
                    }
                }
            }
        } catch {
            firstError = error
            secondCancel.cancel()
        }
        group.wait()
        if cancel.isCancelled { throw RemoteError.cancelled }
        if let firstError {
            // Stopped because the second connection failed: its error is the one that counts.
            if Self.isCancellation(firstError), let (error, sent) = parallel.failure, sent > 0 { throw error }
            throw firstError
        }
        uploadTLS12 = firstTLS12
        var rest = tail
        if let (error, sent) = parallel.failure {
            guard sent == 0 else { throw error }
            parallelRefused = true
            rest = Array(second) + tail
        }
        // "Zuletzt hochladen" only after both connections are done.
        guard !rest.isEmpty else { return }
        uploadTLS12 = try send(rest[...], folders: [], tls12: uploadTLS12, cancel: cancel) { counter.add() }
    }

    /// Uploads `files` in order over one connection (one login per `transferBatch`), creating
    /// `folders` first. Calls `sent` after each file. Returns the TLS limit for later calls.
    /// A dropped or timed-out connection is retried from the affected file (one more login each),
    /// again only if the attempt before got further; an abort over TLS 1.3 switches to TLS 1.2.
    private func send(_ files: ArraySlice<UploadPlan.File>, folders: [[String]], tls12 start: Bool,
                      cancel: Cancellation, sent: @escaping () -> Void) throws -> Bool {
        var folders = folders
        var tls12 = start
        var retries = 0
        var pending = files
        while !pending.isEmpty {
            let chunk = Array(pending.prefix(Self.transferBatch))
            var lines: [String] = []
            // Create all folders up front in the same curl call ("next" starts a new option group on
            // the same connection): the files below rely on them. All groups need the same TLS
            // limit, otherwise curl opens a second connection.
            for mkdirs in folders {
                guard mkdirs.allSatisfy(RemotePath.isSafe) else { throw RemoteError("Unzulässiger Pfad.") }
                lines += baseConfig(tls12: tls12) + ["head"]
                lines += mkdirs.map { "quote = \(Self.quote($0))" }
                lines += ["url = \(Self.quote("ftp://\(hostPort)/"))", "next"]
            }
            let created = folders
            folders = []
            lines += try uploadGroups(chunk, tls12: tls12)
            var done = 0
            let result = curl(lines, cancel: cancel) { line in
                if line.hasPrefix("FILEHUB 0") {
                    done += 1
                    sent()
                }
            }
            if result.cancelled { throw RemoteError.cancelled }
            guard result.ok else {
                let failed = min(done, chunk.count - 1)
                if retries < Self.uploadRetries, retries == 0 || done > 0,
                   Self.uploadAborted(status: result.status, errors: result.errors) {
                    retries += 1
                    if !tls12Only { tls12 = true }
                    if done == 0 { folders = created }
                    pending = pending.dropFirst(failed)
                    continue
                }
                let file = chunk[failed]
                let name = RemotePath.name(file.remote)
                let note = Self.partialName(file) != nil
                    ? " „\(name)“ auf dem Server ist unverändert."
                    : " „\(name)“ auf dem Server ist womöglich unvollständig – bitte noch einmal hochladen."
                throw RemoteError(failure(result, action: "Hochladen von „\(name)“").message + note)
            }
            pending = pending.dropFirst(chunk.count)
        }
        return tls12
    }

    /// Retries per `send` after a broken connection.
    static let uploadRetries = 3
    /// From this size on a file goes up under a temporary name and is renamed when complete, so a
    /// broken transfer never leaves a truncated file live (two more round trips, same login).
    static let partialMinimum: Int64 = 1 << 20

    /// ".app.js.filehub-part" next to the target, for big files; nil for small ones.
    static func partialName(_ file: UploadPlan.File) -> String? {
        let name = RemotePath.name(file.remote)
        guard file.size >= partialMinimum, name.utf8.count + 15 <= 255 else { return nil }
        return "." + name + Partial.suffix
    }

    /// Option groups for the files of one curl call: small files together, every big file in a
    /// group of its own with the rename after the upload (quoted commands apply to a whole group).
    /// nocwd: "STOR /full/path" instead of one CWD per path level. write-out must not start with "@",
    /// or curl reads the format from a file.
    private func uploadGroups(_ files: [UploadPlan.File], tls12: Bool) throws -> [String] {
        let header = baseConfig(tls12: tls12) + ["ftp-method = nocwd", "fail-early", "write-out = \"FILEHUB %{exitcode}\\n\""]
        var lines: [String] = []
        var groupOpen = false
        for file in files {
            guard RemotePath.isSafe(file.remote) else { throw RemoteError("Unzulässiger Pfad: \(file.remote)") }
            if let partial = Self.partialName(file) {
                let temporary = RemotePath.join(RemotePath.parent(file.remote), partial)
                if groupOpen { lines.append("next") }
                // "-" before a quoted command: sent after the transfer.
                lines += header + ["quote = \(Self.quote("-RNFR \(temporary)"))", "quote = \(Self.quote("-RNTO \(file.remote)"))",
                                   "url = \(Self.quote(fileURL(temporary)))", "upload-file = \(Self.quote(file.local.path))", "next"]
                groupOpen = false
                continue
            }
            if !groupOpen {
                if lines.last == "next" || lines.isEmpty { lines += header } else { lines += ["next"] + header }
                groupOpen = true
            }
            lines.append("url = \(Self.quote(fileURL(file.remote)))")
            lines.append("upload-file = \(Self.quote(file.local.path))")
        }
        if lines.last == "next" { lines.removeLast() }
        return lines
    }

    static func isCancellation(_ error: Error) -> Bool {
        (error as? RemoteError)?.message == RemoteError.cancelled.message
    }

    /// Each file arrives under a temporary name and replaces the target only when complete, so a
    /// broken download never destroys an existing copy. nocwd: "RETR /full/path", no CWD per level.
    func download(_ files: [DownloadPlan.File], cancel: Cancellation, progress: @escaping (Int) -> Void) throws {
        var done = 0
        for chunk in Self.chunks(files, of: Self.transferBatch) {
            var lines = baseConfig() + ["ftp-method = nocwd", "create-dirs", "fail-early", "remove-on-error",
                                        "write-out = \"FILEHUB %{exitcode}\\n\""]
            for file in chunk {
                guard RemotePath.isSafe(file.remote) else { throw RemoteError("Unzulässiger Pfad: \(file.remote)") }
                lines.append("url = \(Self.quote(fileURL(file.remote)))")
                lines.append("output = \(Self.quote(Partial.url(for: file.local).path))")
            }
            let start = done
            var renameError: String?
            let result = curl(lines, cancel: cancel) { line in
                guard line.hasPrefix("FILEHUB 0"), done - start < chunk.count else { return }
                do {
                    try Partial.finish(chunk[done - start].local)
                } catch {
                    renameError = renameError ?? "„\(chunk[done - start].local.lastPathComponent)“: \(error.localizedDescription)"
                }
                done += 1
                progress(done)
            }
            if !result.ok, done - start < chunk.count { Partial.discard(chunk[done - start].local) }
            if result.cancelled { throw RemoteError.cancelled }
            guard result.ok else {
                let failed = chunk[min(max(done - start, 0), chunk.count - 1)]
                throw failure(result, action: "Herunterladen von „\(RemotePath.name(failed.remote))“")
            }
            if let renameError { throw RemoteError("Herunterladen: \(renameError)") }
        }
    }

    func disconnect() {}

    // MARK: curl

    /// URLs or commands per curl call. Every call is one login.
    static let listBatch = 500
    static let transferBatch = 1000
    static let commandBatch = 5000
    /// From this many files on, uploads use a second connection (one more login).
    static let parallelMinimum = 40

    static func chunks<T>(_ items: [T], of size: Int) -> [[T]] {
        stride(from: 0, to: items.count, by: size).map { Array(items[$0..<min($0 + size, items.count)]) }
    }

    /// Random separator for write-out: a server cannot anticipate it in file names.
    static func newMarker() -> String {
        "FILEHUB-" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    /// Splits the output of several transfers at the "<marker> <exitcode>" lines.
    static func segments(_ output: String, marker: String) -> [(body: String, status: Int32)] {
        var segments: [(body: String, status: Int32)] = []
        var body: [Substring] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let range = line.range(of: marker + " ") else {
                body.append(line)
                continue
            }
            let before = line[..<range.lowerBound]
            if !before.isEmpty { body.append(before) }
            let status = Int32(line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
            segments.append((body.joined(separator: "\n"), status))
            body = []
        }
        return segments
    }

    /// TLS 1.2 only with forward secrecy and authenticated encryption (TLS 1.3 has nothing else).
    /// All-inkl refuses the others anyway.
    static let tls12Ciphers = [
        "ECDHE-ECDSA-AES256-GCM-SHA384", "ECDHE-RSA-AES256-GCM-SHA384",
        "ECDHE-ECDSA-CHACHA20-POLY1305", "ECDHE-RSA-CHACHA20-POLY1305",
        "ECDHE-ECDSA-AES128-GCM-SHA256", "ECDHE-RSA-AES128-GCM-SHA256",
    ].joined(separator: ":")

    private func baseConfig(tls12: Bool = false) -> [String] {
        var lines = [
            // globoff: [ ] and { } in file names are not curl patterns. proto: ftp:// only (with TLS),
            // never file:// or anything else. ftp-skip-pasv-ip: data only from the logged-in server,
            // never from an address named in its PASV reply.
            "silent", "show-error", "globoff", "ssl-reqd", "tlsv1.2", "proto = \"=ftp\"", "ftp-skip-pasv-ip",
            "ciphers = \(Self.quote(Self.tls12Ciphers))",
            "connect-timeout = 20", "speed-limit = 1", "speed-time = 60",
            "user = \(Self.quote(profile.user + ":" + password))",
        ]
        if tls12Only || tls12 { lines.append("tls-max = \"1.2\"") }
        #if CHECKS
        if let ca = Self.testCA { lines.append("cacert = \(Self.quote(ca))") }
        #endif
        return lines
    }

    /// Login, certificate and home folder in one run (verbose, for parsing only).
    private func probe(cancel: Cancellation) -> Shell.Result {
        let lines = baseConfig() + ["verbose", "list-only", "output = \"/dev/null\"",
                                    "url = \(Self.quote("ftp://\(hostPort)/"))"]
        return curl(lines, cancel: cancel)
    }

    /// Plain FTP commands (MKD, DELE, RMD, RNFR/RNTO, SITE CHMOD) with absolute paths. `head`: no
    /// listing and no data connection afterwards, a failed command still fails the call.
    private func command(_ commands: [String], cancel: Cancellation, action: String) throws {
        guard !commands.isEmpty else { return }
        guard commands.allSatisfy(RemotePath.isSafe) else { throw RemoteError("Unzulässiger Pfad.") }
        var lines = baseConfig() + ["head"]
        lines += commands.map { "quote = \(Self.quote($0))" }
        lines.append("url = \(Self.quote("ftp://\(hostPort)/"))")
        let result = curl(lines, cancel: cancel)
        if result.cancelled { throw RemoteError.cancelled }
        guard result.ok else { throw failure(result, action: action) }
    }

    private func curl(_ lines: [String], cancel: Cancellation, onLine: ((String) -> Void)? = nil) -> Shell.Result {
        // Last line of defence: every line is exactly one option. A line break in a value would
        // turn the rest into an option of its own (such as "insecure").
        guard Self.isSafeSecret(password), Self.isSafeConfig(lines) else {
            return Shell.Result(status: 2, output: "", errors: "curl: Einstellung mit Zeilenumbruch abgelehnt", cancelled: false)
        }
        // -q first: no ~/.curlrc. Everything else, the password included, comes via stdin.
        return Shell.run("/usr/bin/curl", ["-q", "-K", "-"], input: Data((lines.joined(separator: "\n") + "\n").utf8),
                         cancel: cancel, onLine: onLine)
    }

    static func isSafeConfig(_ lines: [String]) -> Bool {
        lines.allSatisfy { line in !line.unicodeScalars.contains { $0 == "\n" || $0 == "\r" || $0.value == 0 } }
    }

    /// No control characters: FTP sends the password as a command line of its own ("PASS …").
    static func isSafeSecret(_ secret: String) -> Bool {
        !secret.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    private var hostPort: String { "\(profile.host):\(profile.port)" }

    /// Folder URL for `ftp-method = singlecwd`: "%2Fwww/htdocs/" becomes "CWD /www/htdocs".
    func directoryURL(_ path: String) -> String { fileURL(path) + "/" }

    /// File URL for `ftp-method = nocwd`: curl sends the decoded path as is, so "%2Fwww/a.txt"
    /// becomes "STOR /www/a.txt" (the "%2F/" form would give "//www/a.txt"). Everything else is
    /// percent-encoded (";" too, or curl would read ";type=" as an option).
    func fileURL(_ path: String) -> String {
        let parts = RemotePath.normalize(path).split(separator: "/").map { Self.encode(String($0)) }
        return "ftp://\(hostPort)/%2F" + parts.joined(separator: "/")
    }

    static func encode(_ part: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return part.addingPercentEncoding(withAllowedCharacters: allowed) ?? part
    }

    /// Value for the curl config: quoted, `\` and `"` escaped, line breaks and tabs as \n, \r, \t
    /// (curl decodes them). A Mac path with a line break stays a path and never becomes an option.
    static func quote(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\u{0B}": result += "\\v"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }

    static func needsTLS12(_ result: Shell.Result) -> Bool {
        needsTLS12(status: result.status, errors: result.errors)
    }

    static func needsTLS12(status: Int32, errors: String) -> Bool {
        [18, 19, 56].contains(status) && (errors.contains("522") || errors.contains("425"))
    }

    /// The server dropped the data connection during upload (426/451), it broke off or stalled.
    static func uploadAborted(status: Int32, errors: String) -> Bool {
        if needsTLS12(status: status, errors: errors) { return false }
        switch status {
        case 18: return errors.contains("426") || errors.contains("451")
        case 28, 55, 56: return true
        default: return false
        }
    }

    /// curl's last error names a reply like "550" (no access, not a folder): the listing command
    /// itself is fine. Unknown commands get 500/502.
    static func deniedReply(_ errors: String) -> Bool {
        let line = lastCurlLine(errors)
        return line.range(of: #"response: (4|5)5\d"#, options: .regularExpression) != nil
    }

    /// Does the macOS curl have the TLS 1.3 data connection bug (up to 8.8)?
    /// Unknown version: assume yes, TLS 1.2 does no harm.
    static let curlHasUploadBug: Bool = {
        let version = curlVersion(Shell.run("/usr/bin/curl", ["--version"]).output)
        return hasUploadBug(version)
    }()

    /// "curl 8.7.1 (x86_64-apple-darwin…) …" → [8, 7, 1]
    static func curlVersion(_ text: String) -> [Int]? {
        let words = text.split(whereSeparator: { $0 == " " || $0.isNewline })
        guard words.count >= 2, words[0] == "curl" else { return nil }
        let numbers = words[1].split(separator: ".").map { Int($0.prefix { $0.isNumber }) }
        guard numbers.count >= 2, numbers.allSatisfy({ $0 != nil }) else { return nil }
        return numbers.compactMap { $0 }
    }

    static func hasUploadBug(_ version: [Int]?) -> Bool {
        guard let version else { return true }
        return version.lexicographicallyPrecedes([8, 9])
    }

    private func failure(_ result: Shell.Result, action: String) -> RemoteError {
        if result.cancelled { return .cancelled }
        return failure(status: result.status, errors: result.errors, action: action)
    }

    private func failure(status: Int32, errors: String, action: String) -> RemoteError {
        let detail = Redactor.clean(Self.lastCurlLine(errors), secrets: [password])
        let reason: String
        switch status {
        case 6: reason = "Server „\(profile.host)“ nicht gefunden."
        case 7: reason = "Keine Verbindung zu \(hostPort)."
        case 9: reason = "Ordner nicht vorhanden oder kein Zugriff."
        case 28: reason = "Zeitüberschreitung – der Server antwortet nicht."
        case 35: reason = "TLS-Verbindung fehlgeschlagen."
        case 51, 60: reason = "Das Zertifikat des Servers ist nicht vertrauenswürdig oder passt nicht zu „\(profile.host)“. FileHub verbindet nicht."
        case 64: reason = "Der Server bietet kein FTP über TLS an. Unverschlüsselt verbindet FileHub nicht."
        case 67: reason = "Anmeldung abgelehnt – Benutzer oder Passwort falsch."
        case 78: reason = "Datei nicht gefunden."
        case 21: reason = "Der Server hat den Befehl abgelehnt."
        case 25: reason = "Der Server hat das Hochladen abgelehnt (Rechte? Speicherplatz?)."
        case 23: reason = "Die Datei ließ sich auf dem Mac nicht schreiben."
        case 26: reason = "Die Datei ließ sich auf dem Mac nicht lesen."
        case 55, 56: reason = "Die Verbindung ist abgerissen."
        case 18, 19:
            reason = Self.needsTLS12(status: status, errors: errors) ? "Der Datenkanal ließ sich nicht verschlüsseln." : "Die Übertragung ist unvollständig."
        default: reason = "curl meldet Fehler \(status)."
        }
        return RemoteError("\(action): \(reason)" + (detail.isEmpty ? "" : " (\(detail))"))
    }

    static func lastCurlLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).last { $0.hasPrefix("curl:") }.map(String.init) ?? ""
        return line.replacingOccurrences(of: "curl: ", with: "")
    }
}

/// Removes secrets from text before it reaches the log or a notice.
enum Redactor {
    static func clean(_ text: String, secrets: [String]) -> String {
        var result = text
        for secret in secrets where secret.count >= 3 {
            result = result.replacingOccurrences(of: secret, with: "••••")
        }
        return result
    }
}

/// Files uploaded so far, over all connections.
private final class UploadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var done = 0
    private let progress: (Int) -> Void

    init(_ progress: @escaping (Int) -> Void) { self.progress = progress }

    /// Inside the lock: with two connections the counts must arrive in order.
    func add() {
        lock.withLock {
            done += 1
            progress(done)
        }
    }
}

/// State of the second upload connection.
private final class ParallelUpload: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var count = 0
    private var error: Error?

    /// True exactly once: the caller starts the second connection.
    func claimStart() -> Bool {
        lock.withLock {
            defer { started = true }
            return !started
        }
    }

    func sent() { lock.withLock { count += 1 } }

    /// Records the error; returns how many files the connection had uploaded.
    func fail(_ error: Error) -> Int {
        lock.withLock {
            self.error = error
            return count
        }
    }

    /// The error of the second connection and how many files it had uploaded before.
    var failure: (Error, Int)? {
        lock.withLock { error.map { ($0, count) } }
    }
}
