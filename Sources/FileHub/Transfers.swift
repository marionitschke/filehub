import CoreServices
import Foundation

/// Upload and download flow, independent of the UI (also used by the checks).
enum Transfers {
    enum Step {
        case deleting(String)
        case transferring(Int)
    }

    struct UploadReport {
        var uploaded = 0
        var bytes: Int64 = 0
        var replaced: [String] = []
        var deletedFiles = 0
    }

    /// Folders to replace from the plan ("Alte Daten beim Upload löschen", e.g. dist) that already
    /// exist on the server, with their contents. Listed up front so that deleting them takes only
    /// one more login with FTPS. Unreadable means missing here.
    static func oldVersions(_ plan: UploadPlan, client: RemoteClient, cancel: Cancellation) throws -> [RemoteTree] {
        guard !plan.replaceDirectories.isEmpty else { return [] }
        let listings = try client.listMany(plan.replaceDirectories, cancel: cancel)
        var known: [String: [RemoteEntry]] = [:]
        for path in plan.replaceDirectories {
            if let entries = try? listings[path]?.get() { known[path] = entries }
        }
        let roots = plan.replaceDirectories.filter { known[$0] != nil }
        guard !roots.isEmpty else { return [] }
        let all = try client.walk(roots, known: known, cancel: cancel)
        // Folders to replace are never nested (UploadPlan), so the split is unambiguous.
        func inside(_ path: String, _ root: String) -> Bool { path == root || path.hasPrefix(root + "/") }
        return roots.map { root in
            RemoteTree(root: root, files: all.files.filter { inside($0.path, root) },
                       directories: all.directories.filter { inside($0, root) })
        }
    }

    /// First delete every folder to replace and check that it is gone, then create folders and
    /// upload files in plan order.
    static func upload(_ plan: UploadPlan, replacing dist: [RemoteTree], client: RemoteClient,
                       cancel: Cancellation, step: @escaping (Step) -> Void) throws -> UploadReport {
        var report = UploadReport()
        for tree in dist {
            step(.deleting(tree.root))
            let gone = try client.deleteTree(tree, cancel: cancel)
            if cancel.isCancelled { throw RemoteError.cancelled }
            guard gone else {
                throw RemoteError("„\(tree.root)“ ließ sich nicht vollständig löschen. Hochladen abgebrochen, "
                    + "damit keine alten Dateien liegen bleiben.")
            }
            report.deletedFiles += tree.files.count
            report.replaced.append(tree.root)
        }
        step(.transferring(0))
        try client.upload(plan.files, directories: plan.directories, last: plan.lastCount, cancel: cancel) { done in
            step(.transferring(done))
        }
        report.uploaded = plan.files.count
        report.bytes = plan.totalBytes
        return report
    }

    static func download(_ plan: DownloadPlan, client: RemoteClient, cancel: Cancellation,
                         progress: @escaping (Int) -> Void) throws {
        for directory in plan.directories {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        // Even after an abort: whatever was written is marked, folders too (an .app is a folder).
        var done = 0
        defer { Quarantine.mark(plan.directories + plan.files.prefix(min(done + 1, plan.files.count)).map(\.local)) }
        try client.download(plan.files, cancel: cancel) { count in
            done = count
            progress(count)
        }
    }
}

/// A download first goes to ".name.filehub-part" next to the target and replaces it only when
/// complete: a broken transfer never destroys an existing copy. Such names count as system files.
enum Partial {
    static let suffix = ".filehub-part"

    static func url(for target: URL) -> URL {
        let name = target.lastPathComponent
        guard name.utf8.count + suffix.utf8.count + 1 <= 255 else { return target }
        return target.deletingLastPathComponent().appendingPathComponent("." + name + suffix)
    }

    /// Moves the finished file into place (replacing an older one). curl creates no file for an
    /// empty download, so then an empty file is created.
    static func finish(_ target: URL) throws {
        let part = url(for: target)
        guard part != target else { return }
        if Darwin.rename(part.path, target.path) == 0 { return }
        let code = errno
        if code == ENOENT, FileManager.default.createFile(atPath: target.path, contents: Data()) { return }
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    static func discard(_ target: URL) {
        let part = url(for: target)
        if part != target { unlink(part.path) }
    }
}

/// Downloaded files get the macOS quarantine flag like Safari downloads: Gatekeeper checks a
/// program or script from the server before it is first opened. Only on volumes that store
/// extended attributes natively (APFS, HFS+); on exFAT/FAT macOS would add a ._ file next to
/// every file.
enum Quarantine {
    static let agent = "FileHub"

    @discardableResult
    static func mark(_ urls: [URL]) -> Int {
        var native: [String: Bool] = [:]
        var marked = 0
        for url in urls {
            let folder = url.deletingLastPathComponent().path
            let supported = native[folder] ?? storesAttributes(folder)
            native[folder] = supported
            guard supported, FileManager.default.fileExists(atPath: url.path) else { continue }
            var values = URLResourceValues()
            values.quarantineProperties = [kLSQuarantineAgentNameKey as String: agent,
                                           kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String]
            var target = url
            if (try? target.setResourceValues(values)) != nil { marked += 1 }
        }
        return marked
    }

    static func isMarked(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) > 0
    }

    /// APFS or HFS+: extended attributes without ._ files.
    static func storesAttributes(_ path: String) -> Bool {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return false }
        let type = withUnsafeBytes(of: info.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return type == "apfs" || type == "hfs"
    }
}
