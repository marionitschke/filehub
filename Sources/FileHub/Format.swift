import Foundation

enum Fmt {
    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = "dd.MM.yy HH:mm"
        return formatter
    }()

    static func date(_ date: Date?) -> String {
        date.map { dateFormatter.string(from: $0) } ?? ""
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    static func time(_ date: Date) -> String { timeFormatter.string(from: date) }

    private static let logFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static func logStamp(_ date: Date) -> String { logFormatter.string(from: date) }

    /// Time left, rounded: "12 s", "4 Min.", "1 Std. 20 Min.".
    static func remaining(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "–" }
        let total = Int(seconds.rounded(.up))
        if total < 60 { return "\(max(total, 1)) s" }
        let minutes = (total + 30) / 60
        if minutes < 60 { return "\(minutes) Min." }
        return "\(minutes / 60) Std. \(minutes % 60) Min."
    }

    static func count(_ n: Int, _ one: String, _ many: String) -> String {
        "\(n) \(n == 1 ? one : many)"
    }

    /// Quoted name list for the UI: „a“, „a und b“, „a, b und 3 weitere“.
    static func names(_ names: [String], limit: Int = 3) -> String {
        let quoted = names.map { "„\($0)“" }
        if quoted.count <= 1 { return quoted.first ?? "" }
        if quoted.count <= limit { return quoted.dropLast().joined(separator: ", ") + " und " + quoted.last! }
        return quoted.prefix(limit - 1).joined(separator: ", ") + " und \(quoted.count - limit + 1) weitere"
    }
}

/// Log at ~/Library/Logs/FileHub.log: one line per entry, never with secrets.
enum LogFile {
    static var url: URL {
        #if CHECKS || SNAPSHOT
        if let override = ProcessInfo.processInfo.environment["FILEHUB_SUPPORT_DIR"] {
            return URL(fileURLWithPath: override).appendingPathComponent("FileHub.log")
        }
        #endif
        return FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs/FileHub.log")
    }

    static func append(_ line: String) {
        let text = Fmt.logStamp(Date()) + " " + line.replacingOccurrences(of: "\n", with: " ") + "\n"
        let url = self.url
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           (attributes[.size] as? Int64 ?? 0) > 2_000_000 {
            let old = url.deletingPathExtension().appendingPathExtension("old.log")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: url, to: old)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
        } else {
            FileManager.default.createFile(atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600])
        }
    }
}
