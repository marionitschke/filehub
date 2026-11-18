import Foundation

/// SFTP host keys in FileHub's own known_hosts (~/Library/Application Support/FileHub).
/// ssh checks strictly against it (StrictHostKeyChecking=yes): an unknown server is added only
/// after its fingerprint is confirmed, a changed key aborts the connection.
enum HostKeys {
    struct Scan {
        /// Lines in known_hosts format.
        let lines: [String]
        /// "ED25519  SHA256:…" per key.
        let fingerprints: [String]
    }

    static var file: URL { ServerStore.directory.appendingPathComponent("known_hosts") }

    /// The name as ssh-keyscan writes it and ssh looks it up.
    static func name(host: String, port: Int) -> String {
        port == 22 ? host : "[\(host)]:\(port)"
    }

    static func isKnown(host: String, port: Int) -> Bool {
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        let result = Shell.run("/usr/bin/ssh-keygen", ["-F", name(host: host, port: port), "-f", file.path])
        return result.ok && !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Fingerprints of the stored keys for a server.
    static func knownFingerprints(host: String, port: Int) -> [String] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let result = Shell.run("/usr/bin/ssh-keygen", ["-l", "-E", "sha256", "-F", name(host: host, port: port), "-f", file.path])
        return fingerprints(from: result.output)
    }

    /// Fetches the server's keys (not trusted yet; the user decides).
    static func scan(host: String, port: Int) throws -> Scan {
        let result = Shell.run("/usr/bin/ssh-keyscan", ["-T", "10", "-p", String(port), "-t", "ed25519,ecdsa,rsa", "--", host])
        let lines = plainLines(result.output, only: name(host: host, port: port))
        guard !lines.isEmpty else {
            throw RemoteError("Der Server \(host) hat auf Port \(port) keinen SSH-Schlüssel geliefert. Läuft dort SFTP?")
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("filehub-scan-\(UUID().uuidString)")
        try lines.joined(separator: "\n").appending("\n").write(to: temp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: temp) }
        let listed = Shell.run("/usr/bin/ssh-keygen", ["-l", "-E", "sha256", "-f", temp.path])
        return Scan(lines: lines, fingerprints: fingerprints(from: listed.output))
    }

    /// "256 SHA256:abc [host]:22 (ED25519)" (ssh-keygen -l -f) or
    /// "[host]:22 ED25519 SHA256:abc" (ssh-keygen -l -F) → "ED25519  SHA256:abc".
    static func fingerprints(from output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            guard !line.hasPrefix("#") else { return nil }
            let parts = line.split(separator: " ").map(String.init)
            guard let index = parts.firstIndex(where: { $0.hasPrefix("SHA256:") }) else { return nil }
            let type: String
            if let last = parts.last, last.hasPrefix("("), last.hasSuffix(")") {
                type = String(last.dropFirst().dropLast())
            } else {
                type = index > 0 ? parts[index - 1] : ""
            }
            return "\(type)  \(parts[index])"
        }
    }

    static func trust(_ scan: Scan) throws {
        try append(scan.lines)
    }

    static func forget(host: String, port: Int) {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        _ = Shell.run("/usr/bin/ssh-keygen", ["-R", name(host: host, port: port), "-f", file.path])
        try? FileManager.default.removeItem(atPath: file.path + ".old")
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    static func exportText() -> String {
        (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    }

    /// Adds lines from a setup file, skipping duplicates.
    static func importText(_ text: String) throws {
        try append(plainLines(text))
    }

    static let keyTypes: Set<String> = [
        "ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521", "ssh-rsa",
        "sk-ssh-ed25519@openssh.com", "sk-ecdsa-sha2-nistp256@openssh.com",
    ]

    /// Only plain "host type key" lines for exactly one server. Rejects anything that would grant
    /// more trust than one key for one name: "@cert-authority" (trusts a CA for many servers),
    /// "@revoked", wildcards like "*", host lists, hashed names, unknown key types.
    /// `only`: lines for this name only (ssh-keyscan).
    static func plainLines(_ text: String, only expected: String? = nil) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { raw -> String? in
            let parts = raw.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count == 3 || parts.count == 4, keyTypes.contains(parts[1]),
                  let key = Data(base64Encoded: parts[2]), key.count >= 32,
                  isPlainName(parts[0]), expected == nil || parts[0] == expected else { return nil }
            return parts.prefix(3).joined(separator: " ")
        }
    }

    /// "host" or "[host]:port" with a valid server name.
    static func isPlainName(_ field: String) -> Bool {
        if field.hasPrefix("["), let close = field.firstIndex(of: "]"), close != field.index(before: field.endIndex) {
            let host = String(field[field.index(after: field.startIndex)..<close])
            let rest = field[field.index(after: close)...]
            guard rest.hasPrefix(":"), let port = Int(rest.dropFirst()), (1...65_535).contains(port) else { return false }
            return ServerProfile.isValidHost(host) || ServerProfile.isValidHost("[\(host)]")
        }
        return ServerProfile.isValidHost(field)
    }

    private static func append(_ lines: [String]) throws {
        try ServerStore.ensureDirectory()
        let existing = Set(exportText().split(whereSeparator: \.isNewline).map(String.init))
        let fresh = lines.filter { !existing.contains($0) }
        guard !fresh.isEmpty else { return }
        var text = exportText()
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        text += fresh.joined(separator: "\n") + "\n"
        try ServerStore.writePrivate(Data(text.utf8), to: file)
    }
}
