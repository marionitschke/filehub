import Foundation

/// An entry in a server folder. Server paths are always absolute ("/www/dist").
struct RemoteEntry: Hashable {
    enum Kind: Hashable { case file, directory, link }

    var name: String
    var path: String
    var kind: Kind
    var size: Int64?
    var modified: Date?
    /// Permission bits (0o777) if the listing shows them.
    var mode: Int? = nil

    var isDirectory: Bool { kind == .directory }
}

enum FileMode {
    /// "644"
    static func octal(_ mode: Int) -> String { String(format: "%03o", mode & 0o777) }

    /// "rw-r--r--"
    static func symbolic(_ mode: Int) -> String {
        (0..<9).map { index in
            mode & (1 << (8 - index)) == 0 ? "-" : ["r", "w", "x"][index % 3]
        }.joined()
    }

    /// The nine permission characters after the type in `ls -l` ("-rwxr-sr-t" → 0o755).
    static func parse(symbolic text: String) -> Int? {
        let characters = Array(text.dropFirst().prefix(9))
        guard characters.count == 9 else { return nil }
        var mode = 0
        for (index, character) in characters.enumerated() {
            let expected: Set<Character> = index % 3 == 0 ? ["r"] : index % 3 == 1 ? ["w"] : ["x", "s", "t"]
            if expected.contains(character) {
                mode |= 1 << (8 - index)
            } else if !"-STl".contains(character) {
                return nil
            }
        }
        return mode
    }
}

struct ConnectionInfo: Equatable {
    /// For the toolbar, e.g. "FTPS · TLSv1.3 · Zertifikat geprüft".
    var summary: String
    /// Details for the help popover (certificate, algorithms).
    var details: [String]
    /// Login folder on the server.
    var home: String
}

/// Error with a user-facing (German) message for notices and the log.
struct RemoteError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
    static let cancelled = RemoteError("Abgebrochen.")
}

/// Shared interface of SFTP and FTPS. All calls are synchronous and run on the AppModel queue,
/// never on the main thread and never two at once.
protocol RemoteClient: AnyObject, Sendable {
    var profile: ServerProfile { get }
    func connect(cancel: Cancellation) throws -> ConnectionInfo
    func list(_ path: String, cancel: Cancellation) throws -> [RemoteEntry]
    /// Lists several folders, over one connection with FTPS. Per path the contents, or an error if
    /// the folder is missing or unreadable; connection errors throw.
    func listMany(_ paths: [String], cancel: Cancellation) throws -> [String: Result<[RemoteEntry], RemoteError>]
    func makeDirectory(_ path: String, cancel: Cancellation) throws
    func rename(_ from: String, to: String, cancel: Cancellation) throws
    /// Sets the permission bits of each path (not recursive).
    func changeMode(_ paths: [String], to mode: Int, cancel: Cancellation) throws
    /// Folders must be empty and come deepest first.
    func delete(files: [String], directories: [String], ignoreErrors: Bool, cancel: Cancellation) throws
    /// Like `delete`, then answers "does `path` still exist?" (with FTPS over the same connection).
    func delete(files: [String], directories: [String], ignoreErrors: Bool, thenCheck path: String,
                cancel: Cancellation) throws -> Bool
    /// The client creates `directories` first (parents first; existing ones are not an error).
    /// The `last` files at the end ("Zuletzt hochladen") start only after all others are done.
    func upload(_ files: [UploadPlan.File], directories: [String], last: Int, cancel: Cancellation,
                progress: @escaping (Int) -> Void) throws
    func download(_ files: [DownloadPlan.File], cancel: Cancellation, progress: @escaping (Int) -> Void) throws
    func disconnect()
}

extension RemoteClient {
    func upload(_ files: [UploadPlan.File], directories: [String], cancel: Cancellation,
                progress: @escaping (Int) -> Void) throws {
        try upload(files, directories: directories, last: 0, cancel: cancel, progress: progress)
    }

    /// One `list` per path (SFTP runs everything over one SSH connection anyway).
    func listMany(_ paths: [String], cancel: Cancellation) throws -> [String: Result<[RemoteEntry], RemoteError>] {
        var results: [String: Result<[RemoteEntry], RemoteError>] = [:]
        for path in paths {
            if cancel.isCancelled { throw RemoteError.cancelled }
            do {
                results[path] = .success(try list(path, cancel: cancel))
            } catch let error as RemoteError where error.message != RemoteError.cancelled.message {
                results[path] = .failure(error)
            }
        }
        return results
    }

    func delete(files: [String], directories: [String], ignoreErrors: Bool, thenCheck path: String,
                cancel: Cancellation) throws -> Bool {
        try delete(files: files, directories: directories, ignoreErrors: ignoreErrors, cancel: cancel)
        if cancel.isCancelled { throw RemoteError.cancelled }
        return (try? listMany([path], cancel: cancel)[path]?.get()) != nil
    }

    /// All files and folders below `paths`, level by level, parents before children. All folders of
    /// a level go into one `listMany`, so FTPS needs one login per level instead of per folder.
    /// Symlinks are not followed and count as files. `known`: folders already listed.
    func walk(_ paths: [String], known: [String: [RemoteEntry]] = [:],
              cancel: Cancellation) throws -> (files: [RemoteEntry], directories: [String]) {
        var files: [RemoteEntry] = []
        var directories = paths
        var level = paths
        var depth = 0
        while !level.isEmpty {
            if cancel.isCancelled { throw RemoteError.cancelled }
            // A server that reports a link to a parent folder as a folder would loop forever.
            depth += 1
            guard depth <= RemotePath.maxDepth else {
                throw RemoteError("Ordner lesen: mehr als \(RemotePath.maxDepth) Ebenen – vermutlich eine Verknüpfung im Kreis.")
            }
            let unknown = level.filter { known[$0] == nil }
            var listings = unknown.isEmpty ? [:] : try listMany(unknown, cancel: cancel)
            for (path, entries) in known where level.contains(path) { listings[path] = .success(entries) }
            var next: [String] = []
            for directory in level {
                guard let listing = listings[directory] else { throw RemoteError("Ordner lesen: keine Antwort für „\(directory)“.") }
                for entry in try listing.get() {
                    if entry.isDirectory {
                        directories.append(entry.path)
                        next.append(entry.path)
                    } else {
                        files.append(entry)
                    }
                }
            }
            level = next
        }
        return (files, directories)
    }

    /// Deletes files and folders with their contents, deepest folders first.
    func deleteRecursively(_ entries: [RemoteEntry], ignoreErrors: Bool, cancel: Cancellation) throws -> Int {
        let tree = try walk(entries.filter(\.isDirectory).map(\.path), cancel: cancel)
        let files = entries.filter { !$0.isDirectory }.map(\.path) + tree.files.map(\.path)
        let directories = tree.directories.sorted { RemotePath.depth($0) > RemotePath.depth($1) }
        try delete(files: files, directories: directories, ignoreErrors: ignoreErrors, cancel: cancel)
        return files.count
    }

    /// Deletes a folder with its contents (from a tree listed before) and checks that it is gone.
    /// One login with FTPS. If something was added meanwhile, RMD fails and the check reports the
    /// folder as still present.
    func deleteTree(_ tree: RemoteTree, cancel: Cancellation) throws -> Bool {
        let directories = tree.directories.sorted { RemotePath.depth($0) > RemotePath.depth($1) }
        return try !delete(files: tree.files.map(\.path), directories: directories, ignoreErrors: true,
                           thenCheck: tree.root, cancel: cancel)
    }
}

/// A server folder with everything below it, listed before deleting.
struct RemoteTree: Equatable {
    var root: String
    var files: [RemoteEntry]
    /// Including `root`.
    var directories: [String]

    var bytes: Int64 { files.reduce(0) { $0 + ($1.size ?? 0) } }
}

enum RemotePath {
    /// Cleans an absolute path: duplicate slashes, "." and ".." (purely textual).
    static func normalize(_ path: String) -> String {
        var parts: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(String(part))
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    static func join(_ directory: String, _ name: String) -> String {
        directory == "/" ? "/" + name : directory + "/" + name
    }

    static func parent(_ path: String) -> String {
        let normalized = normalize(path)
        guard let slash = normalized.lastIndex(of: "/"), normalized != "/" else { return "/" }
        let parent = String(normalized[..<slash])
        return parent.isEmpty ? "/" : parent
    }

    static func name(_ path: String) -> String {
        normalize(path).split(separator: "/").last.map(String.init) ?? "/"
    }

    /// Deepest folder level `walk` goes into.
    static let maxDepth = 64

    static func depth(_ path: String) -> Int {
        path.split(separator: "/").count
    }

    /// Control characters (line breaks!) would inject a second FTP command or start a new sftp
    /// batch line, so FileHub rejects such paths.
    static func isSafe(_ path: String) -> Bool {
        !path.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    /// A single name as it comes from a server: not empty, not "." or "..", no "/", so a
    /// malicious server cannot escape the target folder on download. Also no invisible control or
    /// direction characters: "invoice\u{202E}fdp.app" would otherwise display as "invoiceppa.pdf".
    static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && isSafe(name)
            && !name.unicodeScalars.contains(where: isDeceptive)
    }

    /// C1 control characters and characters that reverse the text direction or separate lines.
    static func isDeceptive(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x80...0x9F, 0x061C, 0x200E, 0x200F, 0x2028...0x202E, 0x2066...0x2069: return true
        default: return false
        }
    }
}

/// Parses folder listings: MLSD (RFC 3659), Unix LIST and `ls -lna` from sftp.
enum ListingParser {
    static func mlsd(_ text: String, in directory: String) -> [RemoteEntry] {
        var entries: [RemoteEntry] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            guard let space = line.firstIndex(of: " ") else { continue }
            let name = String(line[line.index(after: space)...])
            guard RemotePath.isSafeName(name) else { continue }
            var facts: [String: String] = [:]
            for fact in line[..<space].split(separator: ";") {
                let pair = fact.split(separator: "=", maxSplits: 1).map(String.init)
                if pair.count == 2 { facts[pair[0].lowercased()] = pair[1] }
            }
            let type = (facts["type"] ?? "").lowercased()
            if type == "cdir" || type == "pdir" { continue }
            var kind: RemoteEntry.Kind = type == "dir" ? .directory : .file
            if type.hasPrefix("os.unix=slink") || type.hasPrefix("os.unix=symlink") { kind = .link }
            let size = (facts["size"] ?? facts["sizd"]).flatMap { Int64($0) }
            let mode = facts["unix.mode"].flatMap { Int($0, radix: 8) }.map { $0 & 0o777 }
            entries.append(RemoteEntry(name: name, path: RemotePath.join(directory, name), kind: kind,
                                       size: kind == .directory ? nil : size,
                                       modified: facts["modify"].flatMap(mlsdDate), mode: mode))
        }
        return entries
    }

    static func mlsdDate(_ value: String) -> Date? {
        let digits = String(value.prefix(14))
        guard digits.count == 14 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.date(from: digits)
    }

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    /// `-rw-r--r--  1 owner group 1234 Nov  8 07:12 Name with spaces`, also without the group
    /// column. A time without a year belongs to the current year (or the previous one if it would
    /// otherwise lie in the future). sftp uses local time, FTP servers mostly UTC.
    static func unix(_ text: String, in directory: String, timeZone: TimeZone, now: Date = Date()) -> [RemoteEntry] {
        var entries: [RemoteEntry] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            guard let first = line.first, "-dlcbps".contains(first), line.count > 10 else { continue }
            let tokens = tokenize(line, limit: 9)
            guard tokens.count >= 8 else { continue }
            guard let monthIndex = (3...5).first(where: { index in
                index + 2 < tokens.count && months.contains(tokens[index].text.lowercased())
            }), monthIndex + 3 <= tokens.count else { continue }
            let nameStart = tokens[monthIndex + 2].end
            guard nameStart < line.endIndex else { continue }
            var name = String(line[line.index(after: nameStart)...])
            let kind: RemoteEntry.Kind = first == "d" ? .directory : first == "l" ? .link : .file
            if kind == .link, let arrow = name.range(of: " -> ") { name = String(name[..<arrow.lowerBound]) }
            guard RemotePath.isSafeName(name) else { continue }
            let size = Int64(tokens[monthIndex - 1].text)
            let date = unixDate(month: tokens[monthIndex].text, day: tokens[monthIndex + 1].text,
                                timeOrYear: tokens[monthIndex + 2].text, timeZone: timeZone, now: now)
            entries.append(RemoteEntry(name: name, path: RemotePath.join(directory, name), kind: kind,
                                       size: kind == .directory ? nil : size, modified: date,
                                       mode: FileMode.parse(symbolic: tokens[0].text)))
        }
        return entries
    }

    private struct Token { let text: String; let end: String.Index }

    /// The first `limit` whitespace-separated words with their end positions.
    private static func tokenize(_ line: String, limit: Int) -> [Token] {
        var tokens: [Token] = []
        var index = line.startIndex
        while index < line.endIndex, tokens.count < limit {
            while index < line.endIndex, line[index] == " " || line[index] == "\t" { index = line.index(after: index) }
            guard index < line.endIndex else { break }
            let start = index
            while index < line.endIndex, line[index] != " ", line[index] != "\t" { index = line.index(after: index) }
            tokens.append(Token(text: String(line[start..<index]), end: index))
        }
        return tokens
    }

    static func unixDate(month: String, day: String, timeOrYear: String, timeZone: TimeZone, now: Date) -> Date? {
        guard let monthNumber = months.firstIndex(of: month.lowercased()).map({ $0 + 1 }),
              let dayNumber = Int(day) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var parts = DateComponents(month: monthNumber, day: dayNumber)
        if timeOrYear.contains(":") {
            let time = timeOrYear.split(separator: ":").compactMap { Int($0) }
            guard time.count == 2 else { return nil }
            parts.hour = time[0]
            parts.minute = time[1]
            parts.year = calendar.component(.year, from: now)
            if let date = calendar.date(from: parts), date > now.addingTimeInterval(86_400) {
                parts.year = parts.year! - 1
            }
        } else {
            guard let year = Int(timeOrYear) else { return nil }
            parts.year = year
        }
        return calendar.date(from: parts)
    }
}
