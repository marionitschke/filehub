import Foundation

/// Runs command line tools (curl, ssh, sftp, ssh-keygen, ssh-keyscan), always by absolute path
/// since an app does not inherit the shell's PATH. All calls are synchronous and never run on
/// the main thread. Secrets only go via stdin or the askpass bridge, never as arguments or in
/// the environment.
enum Shell {
    struct Result {
        let status: Int32
        let output: String
        let errors: String
        let cancelled: Bool
        /// stdout went over `outputLimit` and was cut off.
        var truncated = false
        var ok: Bool { status == 0 && !cancelled }
    }

    /// Kept stdout at most (listings): more is cut off and reported as `truncated`.
    static let outputLimit = 32 << 20

    /// Fixed, minimal environment. `en_US.UTF-8` so sftp prints English dates and keeps umlauts in
    /// file names unchanged.
    static func environment(_ extra: [String: String] = [:]) -> [String: String] {
        let current = ProcessInfo.processInfo.environment
        var env = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "LANG": "en_US.UTF-8",
        ]
        for key in ["USER", "LOGNAME", "TMPDIR", "SSH_AUTH_SOCK"] {
            if let value = current[key] { env[key] = value }
        }
        env.merge(extra) { _, new in new }
        return env
    }

    /// Waits for the end. `onLine` gets every stdout line right away (for progress), stderr is
    /// collected. `input` goes to stdin, which is closed afterwards.
    static func run(_ executable: String, _ arguments: [String], input: Data? = nil,
                    environment extra: [String: String] = [:], cancel: Cancellation? = nil,
                    onLine: ((String) -> Void)? = nil) -> Result {
        if cancel?.isCancelled == true {
            return Result(status: -1, output: "", errors: "", cancelled: true)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment(extra)
        let out = Pipe(), err = Pipe(), inPipe = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = input == nil ? FileHandle.nullDevice : inPipe

        do {
            try process.run()
        } catch {
            return Result(status: -1, output: "", errors: error.localizedDescription, cancelled: false)
        }
        cancel?.attach(process)
        defer { cancel?.detach(process) }

        let group = DispatchGroup()
        // Keep stderr bounded: a server sending endless text (curl -v passes it on) must not fill
        // memory. For messages, the beginning and the end matter.
        var errorText = HeadTail(limit: 1 << 20)
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            let handle = err.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                errorText.append(chunk)
            }
            group.leave()
        }
        if let input {
            let writer = inPipe.fileHandleForWriting
            DispatchQueue.global(qos: .utility).async {
                // If the program exits early, the write fails (SIGPIPE is ignored).
                try? writer.write(contentsOf: input)
                try? writer.close()
            }
        }

        var collected = Data()
        var truncated = false
        var buffer = Data()
        let handle = out.fileHandleForReading
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            if collected.count < outputLimit { collected.append(chunk) } else { truncated = true }
            guard let onLine else { continue }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                onLine(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            // A line without an end is passed on in chunks instead of growing the buffer.
            if buffer.count > 1 << 20 {
                onLine(String(decoding: buffer, as: UTF8.self))
                buffer.removeAll()
            }
        }
        if let onLine, !buffer.isEmpty { onLine(String(decoding: buffer, as: UTF8.self)) }
        process.waitUntilExit()
        group.wait()
        return Result(status: process.terminationStatus,
                      output: String(decoding: collected, as: UTF8.self),
                      errors: String(decoding: errorText.data, as: UTF8.self),
                      cancelled: cancel?.isCancelled == true, truncated: truncated)
    }
}

/// Beginning and end of a long output, at most `limit` bytes each, with "…" in between.
struct HeadTail {
    let limit: Int
    private var head = Data()
    private var tail = Data()
    private var dropped = false

    init(limit: Int) { self.limit = limit }

    mutating func append(_ chunk: Data) {
        var rest = chunk[...]
        if head.count < limit {
            let take = min(limit - head.count, rest.count)
            head.append(rest.prefix(take))
            rest = rest.dropFirst(take)
        }
        guard !rest.isEmpty else { return }
        tail.append(rest)
        if tail.count > limit {
            tail = Data(tail.suffix(limit))
            dropped = true
        }
    }

    var data: Data { dropped ? head + Data("\n…\n".utf8) + tail : head + tail }
}

/// Cancellation of a running task: terminates the running program and prevents another one
/// from starting.
final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var processes: [Process] = []
    private var children: [Cancellation] = []

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() {
        let (running, linked) = lock.withLock { () -> ([Process], [Cancellation]) in
            cancelled = true
            return (processes, children)
        }
        for process in running where process.isRunning { process.terminate() }
        for child in linked { child.cancel() }
    }

    /// Cancelled with this one, but can also be cancelled on its own (one of two connections).
    func child() -> Cancellation {
        let child = Cancellation()
        let stop = lock.withLock { () -> Bool in
            children.append(child)
            return cancelled
        }
        if stop { child.cancel() }
        return child
    }

    func attach(_ process: Process) {
        let stop = lock.withLock { () -> Bool in
            processes.append(process)
            return cancelled
        }
        if stop, process.isRunning { process.terminate() }
    }

    func detach(_ process: Process) {
        lock.withLock { processes.removeAll { $0 === process } }
    }
}
