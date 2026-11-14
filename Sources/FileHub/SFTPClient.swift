import Foundation

/// SFTP via /usr/bin/ssh and /usr/bin/sftp. One shared SSH connection (ControlMaster) carries
/// all commands; every action is a short `sftp -b -` run over it.
///
/// Security: own known_hosts with strict checking, no forwarding, no agent forwarding,
/// ~/.ssh/config is ignored (`-F /dev/null`). Passwords only go through the askpass bridge
/// (once, with a token), key passphrases come from the macOS keychain.
final class SFTPClient: RemoteClient, @unchecked Sendable {
    let profile: ServerProfile
    private let password: String?
    private var master: Process?
    private let masterLog = LineBuffer()
    private var controlDirectory: URL?
    private var askpass: AskpassServer?

    init(profile: ServerProfile, password: String?) {
        self.profile = profile
        self.password = password
    }

    deinit { disconnect() }

    private var controlPath: String { controlDirectory?.appendingPathComponent("c").path ?? "/nonexistent" }

    // MARK: Connection

    func connect(cancel: Cancellation) throws -> ConnectionInfo {
        disconnect()
        guard HostKeys.isKnown(host: profile.host, port: profile.port) else {
            throw RemoteError("Der Hostschlüssel von \(profile.host) ist noch nicht bestätigt.")
        }
        if !profile.usesPassword, !FileManager.default.fileExists(atPath: profile.expandedKeyPath) {
            throw RemoteError("SSH-Schlüssel nicht gefunden: \(profile.keyPath)")
        }
        let directory = try Self.makeControlDirectory()
        controlDirectory = directory

        var extra: [String: String] = [:]
        if profile.usesPassword {
            guard let password, !password.isEmpty else { throw RemoteError("Für diese Verbindung ist kein Passwort hinterlegt.") }
            let server = try AskpassServer(directory: directory, secret: password)
            askpass = server
            extra = server.environment
            extra["SSH_ASKPASS"] = Bundle.main.executablePath ?? CommandLine.arguments[0]
            extra["SSH_ASKPASS_REQUIRE"] = "force"
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        // -v for the master only: provides algorithms and host key for display (no secrets).
        process.arguments = options(master: true) + ["-v", "-o", "ControlMaster=yes", "-o", "ControlPersist=no",
                                                     "-N", "-p", String(profile.port), "--", profile.host]
        process.environment = Shell.environment(extra)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        masterLog.reset()
        let log = masterLog
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { log.append(data) }
        }
        do {
            try process.run()
        } catch {
            disconnect()
            throw RemoteError("ssh ließ sich nicht starten: \(error.localizedDescription)")
        }
        master = process

        let deadline = Date().addingTimeInterval(45)
        while true {
            if cancel.isCancelled {
                disconnect()
                throw RemoteError.cancelled
            }
            if !process.isRunning {
                usleep(100_000)
                let text = masterLog.text
                disconnect()
                throw Self.connectFailure(text, profile: profile)
            }
            if FileManager.default.fileExists(atPath: controlPath),
               Shell.run("/usr/bin/ssh", ["-F", "/dev/null", "-o", "ControlPath=\(Self.optionValue(controlPath))",
                                          "-O", "check", "--", profile.host]).ok {
                break
            }
            if Date() > deadline {
                disconnect()
                throw RemoteError("Zeitüberschreitung bei der Anmeldung an \(profile.host).")
            }
            usleep(100_000)
        }
        // The password has been fetched; the bridge is no longer needed.
        askpass?.stop()
        askpass = nil

        let pwd = try batch(["pwd"], cancel: cancel)
        guard pwd.ok else { throw failure(pwd, action: "Verbinden") }
        let home = pwd.output.split(whereSeparator: \.isNewline)
            .first { $0.hasPrefix("Remote working directory: ") }
            .map { RemotePath.normalize(String($0.dropFirst("Remote working directory: ".count))) } ?? "/"
        return describe(home: home)
    }

    private func describe(home: String) -> ConnectionInfo {
        let lines = masterLog.lines
        func value(_ marker: String) -> String? {
            lines.first { $0.contains(marker) }.flatMap { line in
                line.range(of: marker).map { String(line[$0.upperBound...]).trimmingCharacters(in: .whitespaces) }
            }
        }
        let cipher = value("kex: server->client cipher:")?.components(separatedBy: " ").first ?? ""
        let kex = value("kex: algorithm:") ?? ""
        let hostKey = value("Server host key:") ?? ""
        let method = lines.first { $0.contains("Authenticated to") }.flatMap { line -> String? in
            line.components(separatedBy: "\"").dropFirst().first
        }
        var details = ["Protokoll: SFTP über SSH", "Hostschlüssel geprüft (gespeichert in FileHub)"]
        if !hostKey.isEmpty { details.append("Hostschlüssel: \(hostKey)") }
        if !kex.isEmpty { details.append("Schlüsseltausch: \(kex)") }
        if !cipher.isEmpty { details.append("Verschlüsselung: \(cipher)") }
        if let method { details.append("Anmeldung: \(method == "publickey" ? "SSH-Schlüssel" : method == "password" ? "Passwort" : method)") }
        let shortCipher = cipher.components(separatedBy: "@").first ?? cipher
        return ConnectionInfo(summary: "SFTP · \(shortCipher.isEmpty ? "SSH" : shortCipher) · Hostschlüssel geprüft",
                              details: details, home: home)
    }

    func disconnect() {
        if let master, master.isRunning {
            _ = Shell.run("/usr/bin/ssh", ["-F", "/dev/null", "-o", "ControlPath=\(Self.optionValue(controlPath))",
                                           "-O", "exit", "--", profile.host])
            if master.isRunning { master.terminate() }
        }
        master = nil
        askpass?.stop()
        askpass = nil
        if let controlDirectory { try? FileManager.default.removeItem(at: controlDirectory) }
        controlDirectory = nil
    }

    private func ensureConnected(_ cancel: Cancellation) throws {
        if master?.isRunning != true { _ = try connect(cancel: cancel) }
    }

    // MARK: Commands

    func list(_ path: String, cancel: Cancellation) throws -> [RemoteEntry] {
        guard RemotePath.isSafe(path) else { throw RemoteError("Unzulässiger Pfad.") }
        let result = try batch(["cd \(Self.escape(path))", "ls -lna"], cancel: cancel)
        guard result.ok else { throw failure(result, action: "Ordner lesen") }
        if result.truncated { throw RemoteError("Ordner lesen: Die Liste ist zu groß (über 32 MB).") }
        let text = result.output.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("sftp> ") }.joined(separator: "\n")
        return ListingParser.unix(text, in: path, timeZone: .current)
    }

    /// Only a missing or unreadable folder is a per-folder result; a broken connection throws, so
    /// that "Alte Daten beim Upload löschen" never mistakes it for "no old version there".
    func listMany(_ paths: [String], cancel: Cancellation) throws -> [String: Result<[RemoteEntry], RemoteError>] {
        var results: [String: Result<[RemoteEntry], RemoteError>] = [:]
        for path in paths {
            if cancel.isCancelled { throw RemoteError.cancelled }
            do {
                results[path] = .success(try list(path, cancel: cancel))
            } catch let error as RemoteError where error.message.contains(Self.missing) || error.message.contains(Self.denied) {
                results[path] = .failure(error)
            }
        }
        return results
    }

    func makeDirectory(_ path: String, cancel: Cancellation) throws {
        let result = try batch(["mkdir \(Self.escape(path))"], cancel: cancel)
        guard result.ok else { throw failure(result, action: "Ordner anlegen") }
    }

    func rename(_ from: String, to: String, cancel: Cancellation) throws {
        let result = try batch(["rename \(Self.escape(from)) \(Self.escape(to))"], cancel: cancel)
        guard result.ok else { throw failure(result, action: "Umbenennen") }
    }

    func changeMode(_ paths: [String], to mode: Int, cancel: Cancellation) throws {
        guard !paths.isEmpty else { return }
        let result = try batch(paths.map { "chmod \(FileMode.octal(mode)) \(Self.escape($0))" }, cancel: cancel)
        guard result.ok else { throw failure(result, action: "Rechte ändern") }
    }

    func delete(files: [String], directories: [String], ignoreErrors: Bool, cancel: Cancellation) throws {
        let prefix = ignoreErrors ? "-" : ""
        let commands = files.map { "\(prefix)rm \(Self.escape($0))" } + directories.map { "\(prefix)rmdir \(Self.escape($0))" }
        guard !commands.isEmpty else { return }
        let result = try batch(commands, cancel: cancel)
        guard result.ok else { throw failure(result, action: "Löschen") }
    }

    /// One connection in plan order, so the `last` files are last anyway.
    func upload(_ files: [UploadPlan.File], directories: [String], last: Int, cancel: Cancellation,
                progress: @escaping (Int) -> Void) throws {
        // "-mkdir": existing folders are not an error.
        let commands = directories.map { "-mkdir \(Self.escape($0))" }
            + files.map { "put \(Self.escape($0.local.path)) \(Self.escape($0.remote))" }
        guard !commands.isEmpty else { return }
        var started = 0
        let result = try batch(commands, cancel: cancel) { line in
            if line.hasPrefix("sftp> put ") {
                started += 1
                progress(started - 1)
            }
        }
        if result.cancelled { throw RemoteError.cancelled }
        guard result.ok else {
            let name = started > 0 && started <= files.count ? RemotePath.name(files[started - 1].remote) : ""
            throw failure(result, action: name.isEmpty ? "Hochladen" : "Hochladen von „\(name)“")
        }
        progress(files.count)
    }

    /// To temporary names first (see `Partial`); finished files replace their targets afterwards.
    func download(_ files: [DownloadPlan.File], cancel: Cancellation, progress: @escaping (Int) -> Void) throws {
        let commands = files.map { "get \(Self.escape($0.remote)) \(Self.escape(Partial.url(for: $0.local).path))" }
        guard !commands.isEmpty else { return }
        var started = 0
        let result: Shell.Result
        do {
            result = try batch(commands, cancel: cancel) { line in
                if line.hasPrefix("sftp> get ") {
                    started += 1
                    progress(started - 1)
                }
            }
        } catch {
            if started > 0, started <= files.count { Partial.discard(files[started - 1].local) }
            throw error
        }
        let finished = result.ok ? files.count : max(started - 1, 0)
        var renameError: String?
        for file in files.prefix(finished) {
            do { try Partial.finish(file.local) } catch {
                renameError = renameError ?? "„\(file.local.lastPathComponent)“: \(error.localizedDescription)"
            }
        }
        if !result.ok, started > 0, started <= files.count { Partial.discard(files[started - 1].local) }
        if result.cancelled { throw RemoteError.cancelled }
        guard result.ok else {
            let name = started > 0 && started <= files.count ? RemotePath.name(files[started - 1].remote) : ""
            throw failure(result, action: name.isEmpty ? "Herunterladen" : "Herunterladen von „\(name)“")
        }
        if let renameError { throw RemoteError("Herunterladen: \(renameError)") }
        progress(files.count)
    }

    private func batch(_ commands: [String], cancel: Cancellation, onLine: ((String) -> Void)? = nil) throws -> Shell.Result {
        try ensureConnected(cancel)
        guard commands.allSatisfy(RemotePath.isSafe) else { throw RemoteError("Unzulässiger Pfad.") }
        let arguments = options(master: false) + ["-o", "LogLevel=ERROR", "-o", "ControlMaster=no",
                                                  "-P", String(profile.port), "-b", "-", "--", profile.host]
        let result = Shell.run("/usr/bin/sftp", arguments, input: Data((commands.joined(separator: "\n") + "\n").utf8),
                               cancel: cancel, onLine: onLine)
        if result.cancelled { throw RemoteError.cancelled }
        return result
    }

    // MARK: Options

    private func options(master: Bool) -> [String] {
        var values = [
            "User=\(profile.user)",
            "StrictHostKeyChecking=yes",
            "UserKnownHostsFile=\(Self.optionValue(HostKeys.file.path))",
            "GlobalKnownHostsFile=/dev/null",
            "CheckHostIP=no", "UpdateHostKeys=no", "HashKnownHosts=no",
            "ConnectTimeout=20", "ServerAliveInterval=15", "ServerAliveCountMax=3",
            "ForwardAgent=no", "ForwardX11=no", "ClearAllForwardings=yes", "PermitLocalCommand=no",
            "AddKeysToAgent=no",
            "ControlPath=\(Self.optionValue(controlPath))",
        ]
        if profile.usesPassword {
            values += [master ? "BatchMode=no" : "BatchMode=yes",
                       "PreferredAuthentications=keyboard-interactive,password",
                       "PubkeyAuthentication=no", "NumberOfPasswordPrompts=1"]
        } else {
            values += ["BatchMode=yes", "PreferredAuthentications=publickey", "PubkeyAuthentication=yes",
                       "PasswordAuthentication=no", "KbdInteractiveAuthentication=no", "IdentitiesOnly=yes",
                       "IdentityFile=\(Self.optionValue(profile.expandedKeyPath))",
                       // Apple's ssh: key passphrase from the keychain (ssh-add --apple-use-keychain).
                       "UseKeychain=yes"]
        }
        return ["-F", "/dev/null"] + values.flatMap { ["-o", $0] }
    }

    /// Values with spaces (Application Support) in quotes; "%" doubled, otherwise ssh expands
    /// tokens there. `\` and `"` escaped, so a path with quotes stays one value and never appends
    /// another option.
    static func optionValue(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "%", with: "%%")
        return "\"" + escaped + "\""
    }

    /// Path for an sftp batch line: unquoted, every special character prefixed with "\". This
    /// keeps *, ?, [ ] literal (on the Mac and on the server) and umlauts unchanged.
    static func escape(_ path: String) -> String {
        var result = ""
        for scalar in path.unicodeScalars {
            let plain = (scalar >= "a" && scalar <= "z") || (scalar >= "A" && scalar <= "Z")
                || (scalar >= "0" && scalar <= "9") || "/._-+,:@%=~".unicodeScalars.contains(scalar)
                || scalar.value >= 0x80
            if !plain { result.append("\\") }
            result.unicodeScalars.append(scalar)
        }
        return result
    }

    private static func makeControlDirectory() throws -> URL {
        // Short path: Unix sockets allow at most 104 characters.
        let base = FileManager.default.temporaryDirectory
        for _ in 0..<5 {
            let url = base.appendingPathComponent("fh-" + UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
            if (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                          attributes: [.posixPermissions: 0o700])) != nil {
                return url
            }
        }
        throw RemoteError("Arbeitsordner für die SSH-Verbindung ließ sich nicht anlegen.")
    }

    // MARK: Errors

    static func connectFailure(_ log: String, profile: ServerProfile) -> RemoteError {
        let text = log
        if text.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") || text.contains("Host key verification failed") {
            return RemoteError("Der Hostschlüssel von \(profile.host) passt nicht zum gespeicherten. Das kann ein Angriff sein – "
                + "FileHub verbindet nicht. Hat der Hoster den Schlüssel bestätigt geändert, unter „Verbindung bearbeiten“ "
                + "den gespeicherten Hostschlüssel vergessen und neu bestätigen.")
        }
        if text.contains("Could not resolve hostname") { return RemoteError("Server „\(profile.host)“ nicht gefunden.") }
        if text.contains("Connection refused") { return RemoteError("\(profile.host) lehnt Verbindungen auf Port \(profile.port) ab.") }
        if text.contains("timed out") { return RemoteError("Zeitüberschreitung – \(profile.host) antwortet nicht.") }
        if text.contains("incorrect passphrase") || text.contains("passphrase") && text.contains("Load key") {
            return RemoteError("Der SSH-Schlüssel hat eine Passphrase, die nicht im Schlüsselbund liegt. Einmal im Terminal "
                + "`ssh-add --apple-use-keychain \(profile.keyPath)` ausführen.")
        }
        if text.contains("Permission denied") || text.contains("Too many authentication failures") {
            return RemoteError(profile.usesPassword ? "Anmeldung abgelehnt – Benutzer oder Passwort falsch."
                                                    : "Anmeldung abgelehnt – der Server kennt diesen SSH-Schlüssel nicht.")
        }
        let last = text.split(whereSeparator: \.isNewline).map(String.init)
            .last { !$0.hasPrefix("debug") && !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "unbekannter Fehler"
        return RemoteError("Verbindung fehlgeschlagen: \(last)")
    }

    private static let missing = "Nicht gefunden."
    private static let denied = "Kein Zugriff."

    private func failure(_ result: Shell.Result, action: String) -> RemoteError {
        if result.cancelled { return .cancelled }
        let lines = result.errors.split(whereSeparator: \.isNewline).map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let last = Redactor.clean(lines.last ?? "", secrets: [password ?? ""])
        let reason: String
        if master?.isRunning != true || last.contains("Connection closed") || last.contains("Control socket") {
            reason = "Die Verbindung ist abgerissen."
        } else if last.contains("Permission denied") {
            reason = Self.denied
        } else if last.contains("No such file") || last.contains("not found") {
            reason = Self.missing
        } else if last.hasSuffix("Failure") {
            reason = "Vom Server abgelehnt (vorhanden? Rechte?)."
        } else if last.isEmpty {
            reason = "sftp meldet Fehler \(result.status)."
        } else {
            reason = last
        }
        return RemoteError("\(action): \(reason)" + (last.isEmpty || reason == last ? "" : " (\(last))"))
    }
}

/// Collects the SSH master's output: the beginning (algorithms, login) and the end (errors).
final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var head: [String] = []
    private var tail: [String] = []
    private var partial = Data()

    func reset() { lock.withLock { head = []; tail = []; partial = Data() } }

    func append(_ data: Data) {
        lock.withLock {
            partial.append(data)
            // A line without an end (server sends endless text) does not grow beyond 64 KB.
            if partial.count > 64 << 10, !partial.contains(0x0A) {
                partial = Data(partial.suffix(16 << 10))
            }
            while let newline = partial.firstIndex(of: 0x0A) {
                let line = String(decoding: partial[partial.startIndex..<newline], as: UTF8.self)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                partial.removeSubrange(partial.startIndex...newline)
                if head.count < 400 { head.append(line) } else {
                    tail.append(line)
                    if tail.count > 100 { tail.removeFirst(tail.count - 100) }
                }
            }
        }
    }

    var lines: [String] {
        lock.withLock { head + tail + (partial.isEmpty ? [] : [String(decoding: partial, as: UTF8.self)]) }
    }

    var text: String { lines.joined(separator: "\n") }
}
