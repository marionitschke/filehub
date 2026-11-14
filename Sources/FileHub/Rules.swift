import Darwin
import Foundation

/// System files FileHub never transfers in either direction (case-insensitive), plus anything
/// starting with "._" (AppleDouble, real files on exFAT/FAT) or ".Trash-" (Linux trash on
/// external drives). Version control never belongs on a web server.
enum SystemFiles {
    static let names: Set<String> = [
        ".ds_store", ".localized", ".spotlight-v100", ".trashes", ".fseventsd", ".temporaryitems",
        ".documentrevisions-v100", ".volumeicon.icns", ".appledouble", ".appledb", ".appledesktop",
        ".apdisk", ".com.apple.timemachine.donotpresent", ".com.apple.timemachine.supported",
        "__macosx", "icon\r", "network trash folder", "temporary items",
        "thumbs.db", "ehthumbs.db", "desktop.ini", "$recycle.bin", "system volume information",
        ".git", ".svn", ".hg",
    ]

    static func isSystem(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasPrefix("._") || lower.hasPrefix(".trash-") || lower.hasSuffix(Partial.suffix) || names.contains(lower)
    }

    static let summary = ".DS_Store, ._*, .Spotlight-V100, .Trashes, .fseventsd, __MACOSX, Icon, Thumbs.db, desktop.ini, .git, .svn, .hg"
}

/// Private credentials of the Mac that never belong on a server, even if someone drags the
/// whole home folder: SSH and GPG folders, private SSH keys and FileHub's own export file
/// (encrypted, but open to offline attacks on a web server).
enum SecretFiles {
    static let names: Set<String> = [
        ".ssh", ".gnupg", "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", "id_ecdsa_sk", "id_ed25519_sk",
    ]

    static func isSecret(_ name: String) -> Bool {
        let lower = name.lowercased()
        return names.contains(lower) || lower.hasSuffix(".filehub")
    }

    static let summary = ".ssh, .gnupg, private SSH-Schlüssel (id_rsa, id_ed25519 …) und *.filehub"
}

/// Patterns like "php/config.php, logs, *.map", separated by comma or line break. A pattern
/// matches when its parts equal the last parts of the target path ("php/config.php" matches
/// "/www/php/config.php"), each part with * and ? as in the shell.
struct PathPatterns: Equatable {
    let patterns: [[String]]

    init(_ text: String) {
        patterns = text
            .split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
            .filter { !$0.isEmpty }
            .map { $0.split(separator: "/").map(String.init) }
    }

    var isEmpty: Bool { patterns.isEmpty }

    /// Index of the first matching pattern, or nil.
    func firstMatch(_ path: String) -> Int? {
        let parts = path.split(separator: "/").map(String.init)
        for (index, pattern) in patterns.enumerated() where pattern.count <= parts.count {
            let tail = parts.suffix(pattern.count)
            if zip(pattern, tail).allSatisfy({ fnmatch($0.0, $0.1, 0) == 0 }) { return index }
        }
        return nil
    }

    func matches(_ path: String) -> Bool { firstMatch(path) != nil }

    /// True if a pattern covers the whole relative path, not just its end.
    func matchesExactly<C: Collection>(_ parts: C) -> Bool where C.Element == String {
        patterns.contains { pattern in
            pattern.count == parts.count && zip(pattern, parts).allSatisfy { fnmatch($0.0, $0.1, 0) == 0 }
        }
    }
}

/// What an upload will do, before it does anything: for the log.
struct UploadPlan {
    struct File: Hashable {
        let local: URL
        let remote: String
        let size: Int64
    }

    var files: [File] = []
    /// The last this many `files` match "Zuletzt hochladen".
    var lastCount = 0
    /// Folders to create on the server, parents first (empty ones included).
    var directories: [String] = []
    /// Folders in the upload that match "Alte Daten beim Upload löschen" (default "dist"): their
    /// counterpart on the server is deleted first. Top level only: the pattern must name the whole
    /// path from the target folder (or from the folder, if a single one is dragged), so "dist"
    /// never hits vendor/lib/dist or assets/dist next to it.
    /// Never nested; the outer one covers the rest.
    var replaceDirectories: [String] = []
    var skippedSystem = 0
    var skippedSecret: [String] = []
    var skippedByRule: [String] = []
    var skippedLinks: [String] = []
    var skippedUnsafe: [String] = []
    var unreadable: [String] = []

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    /// Walks the dragged files and folders. Symlinks are never followed (a link to ~/.ssh must
    /// not end up on the server); names go to the server as NFC (otherwise umlauts in URLs are
    /// encoded differently than in the HTML).
    static func build(items: [URL], into remoteDirectory: String, neverUpload: PathPatterns,
                      uploadLast: PathPatterns, replace: PathPatterns) -> UploadPlan {
        var plan = UploadPlan()
        let single = items.count == 1
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]

        func visit(_ url: URL, remoteParent: String, relative: [String], insideReplaced: Bool) {
            let name = url.lastPathComponent
            if SystemFiles.isSystem(name) {
                plan.skippedSystem += 1
                return
            }
            if SecretFiles.isSecret(name) {
                plan.skippedSecret.append(url.path)
                return
            }
            let remoteName = name.precomposedStringWithCanonicalMapping
            guard RemotePath.isSafeName(remoteName) else {
                plan.skippedUnsafe.append(url.path)
                return
            }
            let remote = RemotePath.join(remoteParent, remoteName)
            let path = relative + [remoteName]
            if neverUpload.matches(remote) {
                plan.skippedByRule.append(remote)
                return
            }
            guard let values = try? url.resourceValues(forKeys: keys) else {
                plan.unreadable.append(url.path)
                return
            }
            if values.isSymbolicLink == true {
                plan.skippedLinks.append(url.path)
                return
            }
            if values.isDirectory == true {
                plan.directories.append(remote)
                let replaced = insideReplaced || replace.matchesExactly(path) || (single && replace.matchesExactly(path.dropFirst()))
                if replaced, !insideReplaced { plan.replaceDirectories.append(remote) }
                guard let children = try? FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: Array(keys), options: []) else {
                    plan.unreadable.append(url.path)
                    return
                }
                for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    visit(child, remoteParent: remote, relative: path, insideReplaced: replaced)
                }
            } else if values.isRegularFile == true {
                plan.files.append(File(local: url, remote: remote, size: Int64(values.fileSize ?? 0)))
            } else {
                plan.unreadable.append(url.path)
            }
        }

        for item in items {
            visit(item, remoteParent: remoteDirectory, relative: [], insideReplaced: false)
        }

        // "Zuletzt hochladen" (e.g. sw.js, dist/version.txt) goes last, in the order of the patterns.
        if !uploadLast.isEmpty {
            let indexed = plan.files.enumerated().map { ($0.offset, $0.element, uploadLast.firstMatch($0.element.remote)) }
            plan.files = indexed.sorted { lhs, rhs in
                switch (lhs.2, rhs.2) {
                case (nil, nil): return lhs.0 < rhs.0
                case (nil, _): return true
                case (_, nil): return false
                case let (l?, r?): return l == r ? lhs.0 < rhs.0 : l < r
                }
            }.map(\.1)
            plan.lastCount = indexed.filter { $0.2 != nil }.count
        }
        return plan
    }

    /// Summary of the skipped items for the log and notices.
    var skippedSummary: [String] {
        var lines: [String] = []
        if skippedSystem > 0 { lines.append("\(skippedSystem) Systemdatei\(skippedSystem == 1 ? "" : "en") ausgelassen") }
        if !skippedSecret.isEmpty {
            lines.append("\(skippedSecret.count) private Zugangsdate\(skippedSecret.count == 1 ? "i" : "ien") (SSH, GPG) ausgelassen")
        }
        if !skippedByRule.isEmpty { lines.append("\(skippedByRule.count) nach „Nie hochladen“ ausgelassen") }
        if !skippedLinks.isEmpty { lines.append("\(skippedLinks.count) Verknüpfung\(skippedLinks.count == 1 ? "" : "en") ausgelassen") }
        if !skippedUnsafe.isEmpty { lines.append("\(skippedUnsafe.count) mit unzulässigem Namen ausgelassen") }
        if !unreadable.isEmpty { lines.append("\(unreadable.count) nicht lesbar") }
        return lines
    }
}

/// Download: target paths on the Mac, only inside the chosen folder.
struct DownloadPlan {
    struct File: Hashable {
        let remote: String
        let local: URL
        let size: Int64?
    }

    var files: [File] = []
    var directories: [URL] = []
    var skippedSystem = 0
    var skippedLinks: [String] = []
    var skippedUnsafe: [String] = []
    /// Top-level targets that already exist (for the "replace?" question).
    var existing: [URL] = []

    var totalBytes: Int64 { files.reduce(0) { $0 + ($1.size ?? 0) } }

    static func build(_ entries: [RemoteEntry], into localDirectory: URL, client: RemoteClient,
                      cancel: Cancellation) throws -> DownloadPlan {
        var plan = DownloadPlan()
        let root = localDirectory.standardizedFileURL

        func target(_ parent: URL, _ name: String) -> URL? {
            guard RemotePath.isSafeName(name) else { return nil }
            let url = parent.appendingPathComponent(name).standardizedFileURL
            return url.deletingLastPathComponent().path == parent.standardizedFileURL.path ? url : nil
        }

        /// Folders whose contents are still to be listed, with their target on the Mac.
        var level: [(remote: String, local: URL)] = []

        func visit(_ entry: RemoteEntry, into parent: URL, topLevel: Bool) {
            if SystemFiles.isSystem(entry.name) {
                plan.skippedSystem += 1
                return
            }
            guard let local = target(parent, entry.name) else {
                plan.skippedUnsafe.append(entry.path)
                return
            }
            if topLevel, FileManager.default.fileExists(atPath: local.path) { plan.existing.append(local) }
            switch entry.kind {
            case .link:
                plan.skippedLinks.append(entry.path)
            case .file:
                plan.files.append(File(remote: entry.path, local: local, size: entry.size))
            case .directory:
                plan.directories.append(local)
                level.append((entry.path, local))
            }
        }

        for entry in entries {
            visit(entry, into: root, topLevel: true)
        }
        // Level by level: all folders of a level in one listMany (FTPS: one login).
        while !level.isEmpty {
            if cancel.isCancelled { throw RemoteError.cancelled }
            let current = level
            level = []
            let listings = try client.listMany(current.map(\.remote), cancel: cancel)
            for folder in current {
                guard let listing = listings[folder.remote] else { throw RemoteError("Ordner lesen: keine Antwort für „\(folder.remote)“.") }
                for child in try listing.get().sorted(by: { $0.name < $1.name }) {
                    visit(child, into: folder.local, topLevel: false)
                }
            }
        }
        return plan
    }

    var skippedSummary: [String] {
        var lines: [String] = []
        if skippedSystem > 0 { lines.append("\(skippedSystem) Systemdatei\(skippedSystem == 1 ? "" : "en") ausgelassen") }
        if !skippedLinks.isEmpty { lines.append("\(skippedLinks.count) Verknüpfung\(skippedLinks.count == 1 ? "" : "en") ausgelassen") }
        if !skippedUnsafe.isEmpty { lines.append("\(skippedUnsafe.count) mit unzulässigem Namen ausgelassen") }
        return lines
    }
}
