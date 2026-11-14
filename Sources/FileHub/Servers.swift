import Foundation

/// Encrypted protocols only. FileHub has no plain FTP.
enum TransferProtocol: String, Codable, CaseIterable, Identifiable {
    case sftp, ftps

    var id: String { rawValue }
    var label: String { self == .sftp ? "SFTP (SSH)" : "FTPS (FTP über TLS)" }
    var short: String { self == .sftp ? "SFTP" : "FTPS" }
    var defaultPort: Int { self == .sftp ? 22 : 21 }
}

enum AuthMethod: String, Codable, CaseIterable, Identifiable {
    case password, key

    var id: String { rawValue }
    var label: String { self == .password ? "Passwort" : "SSH-Schlüssel" }
}

/// A saved connection. Never contains a password; that lives in the keychain.
struct ServerProfile: Codable, Identifiable, Hashable {
    var id = UUID()
    var name = ""
    var proto: TransferProtocol = .sftp
    var host = ""
    var port = 22
    var user = ""
    var auth: AuthMethod = .password
    /// With "~", so the same entry works on every Mac.
    var keyPath = "~/.ssh/id_ed25519"
    /// Empty: the server's login folder.
    var remotePath = ""
    /// Empty: the home folder.
    var localPath = ""
    var neverUpload = ""
    var uploadLast = "dist/version.txt, sw.js"
    /// Folders whose old version on the server is deleted completely before the upload when they
    /// are part of it (patterns as for "Nie hochladen"). Empty: delete nothing.
    var replaceOnUpload = "dist"

    init() {}

    /// Missing fields (older files, another version on another Mac) get defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ServerProfile()
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? defaults.name
        proto = try c.decodeIfPresent(TransferProtocol.self, forKey: .proto) ?? defaults.proto
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? defaults.host
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? proto.defaultPort
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? defaults.user
        auth = try c.decodeIfPresent(AuthMethod.self, forKey: .auth) ?? defaults.auth
        keyPath = try c.decodeIfPresent(String.self, forKey: .keyPath) ?? defaults.keyPath
        remotePath = try c.decodeIfPresent(String.self, forKey: .remotePath) ?? defaults.remotePath
        localPath = try c.decodeIfPresent(String.self, forKey: .localPath) ?? defaults.localPath
        neverUpload = try c.decodeIfPresent(String.self, forKey: .neverUpload) ?? defaults.neverUpload
        uploadLast = try c.decodeIfPresent(String.self, forKey: .uploadLast) ?? defaults.uploadLast
        replaceOnUpload = try c.decodeIfPresent(String.self, forKey: .replaceOnUpload) ?? defaults.replaceOnUpload
    }

    /// FTPS always logs in with a password.
    var usesPassword: Bool { proto == .ftps || auth == .password }

    var displayName: String { name.isEmpty ? host : name }

    var expandedKeyPath: String { (keyPath as NSString).expandingTildeInPath }

    var neverUploadPatterns: PathPatterns { PathPatterns(neverUpload) }
    var uploadLastPatterns: PathPatterns { PathPatterns(uploadLast) }
    var replacePatterns: PathPatterns { PathPatterns(replaceOnUpload) }

    /// Host names and users go to ssh/curl as arguments: harmless characters only, nothing starting
    /// with "-" (ssh would read it as an option).
    static func isValidHost(_ host: String) -> Bool {
        if host.hasPrefix("["), host.hasSuffix("]") {
            let inner = host.dropFirst().dropLast()
            return !inner.isEmpty && inner.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." }
        }
        guard let first = host.first, first.isLetter || first.isNumber, host.count <= 253 else { return false }
        return host.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "." || $0 == "-" }
    }

    static func isValidUser(_ user: String) -> Bool {
        guard let first = user.first, first != "-", user.count <= 128 else { return false }
        return user.unicodeScalars.allSatisfy { scalar in
            scalar.value > 0x20 && scalar.value != 0x7F && !"\"'\\:;,<>|&$`*?()[]{}#%".unicodeScalars.contains(scalar)
        }
    }

    /// First problem in the input, or nil.
    var problem: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Bitte einen Namen vergeben." }
        if !Self.isValidHost(host) { return "Der Servername ist ungültig (nur Buchstaben, Ziffern, Punkt und Bindestrich)." }
        if !(1...65_535).contains(port) { return "Der Port muss zwischen 1 und 65535 liegen." }
        if !Self.isValidUser(user) { return "Der Benutzername ist leer oder enthält unzulässige Zeichen." }
        if !remotePath.isEmpty && (!remotePath.hasPrefix("/") || !RemotePath.isSafe(remotePath)) {
            return "Der Startordner auf dem Server muss mit „/“ beginnen."
        }
        if proto == .sftp, auth == .key, keyPath.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Bitte die Datei des SSH-Schlüssels angeben."
        }
        if !RemotePath.isSafe(keyPath) || !RemotePath.isSafe(localPath) {
            return "Schlüsseldatei und Startordner auf dem Mac dürfen keine Zeilenumbrüche oder Steuerzeichen enthalten."
        }
        return nil
    }
}

/// Connections in ~/Library/Application Support/FileHub/servers.json (readable by the user only).
enum ServerStore {
    static var directory: URL {
        #if CHECKS || SNAPSHOT
        if let override = ProcessInfo.processInfo.environment["FILEHUB_SUPPORT_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        #endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("FileHub", isDirectory: true)
    }

    static var file: URL { directory.appendingPathComponent("servers.json") }

    static func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    static func load() -> [ServerProfile] {
        guard let data = try? Data(contentsOf: file),
              let servers = try? JSONDecoder().decode([ServerProfile].self, from: data) else { return [] }
        return servers
    }

    static func save(_ servers: [ServerProfile]) throws {
        try ensureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writePrivate(try encoder.encode(servers), to: file)
    }

    /// Writes atomically, readable by the user only (0600).
    static func writePrivate(_ data: Data, to url: URL) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw RemoteError("„\(url.lastPathComponent)“ ließ sich nicht schreiben.")
        }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
