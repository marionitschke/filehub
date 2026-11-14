import Darwin
import Foundation

/// SFTP password login without the password in arguments, environment or files: ssh runs
/// FileHub itself as SSH_ASKPASS, and the helper fetches the password from the running app over a
/// Unix socket in a user-only directory, exactly once and only with the one-time token from its
/// environment. The socket also checks that the peer runs as the same user.
final class AskpassServer: @unchecked Sendable {
    static let socketKey = "FILEHUB_ASKPASS_SOCKET"
    static let tokenKey = "FILEHUB_ASKPASS_TOKEN"

    let socketPath: String
    let token: String
    private let secret: Data
    private let fd: Int32
    private let lock = NSLock()
    private var used = false
    private var stopped = false
    private var closed = false

    init(directory: URL, secret: String) throws {
        socketPath = directory.appendingPathComponent("a").path
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw RemoteError("Zufallszahl für die Anmeldung fehlgeschlagen.")
        }
        token = bytes.map { String(format: "%02x", $0) }.joined()
        self.secret = Data(secret.utf8)

        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RemoteError("Anmelde-Socket ließ sich nicht öffnen.") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketPath.utf8)
        guard path.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw RemoteError("Pfad des Anmelde-Sockets ist zu lang.")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path)
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        unlink(socketPath)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(socketPath, 0o600) == 0, listen(fd, 4) == 0 else {
            close(fd)
            unlink(socketPath)
            throw RemoteError("Anmelde-Socket ließ sich nicht einrichten.")
        }
        let thread = Thread { [self] in self.serve() }
        thread.name = "FileHub-Askpass"
        thread.start()
    }

    var environment: [String: String] {
        [Self.socketKey: socketPath, Self.tokenKey: token]
    }

    /// Stops accepting requests. The serving thread closes the socket itself within 0.2 s;
    /// a blocked accept() cannot be woken from outside.
    func stop() {
        let first = lock.withLock { () -> Bool in
            defer { stopped = true }
            return !stopped
        }
        if first { unlink(socketPath) }
    }

    /// Thread finished and socket closed (for the checks).
    var isClosed: Bool { lock.withLock { closed } }

    private func serve() {
        defer {
            close(fd)
            unlink(socketPath)
            lock.withLock { closed = true }
        }
        while !lock.withLock({ used || stopped }) {
            var pending = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pending, 1, 200)
            if ready < 0 {
                if errno == EINTR { continue }
                return
            }
            guard ready > 0 else { continue }
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR || errno == EAGAIN || errno == ECONNABORTED { continue }
                return
            }
            handle(client)
            close(client)
        }
    }

    private func handle(_ client: Int32) {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { return }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, [Int32(1)], socklen_t(MemoryLayout<Int32>.size))
        var received = [UInt8]()
        var byte: UInt8 = 0
        while received.count < 128, read(client, &byte, 1) == 1, byte != 0x0A {
            received.append(byte)
        }
        let expected = Array(token.utf8)
        guard received.count == expected.count else { return }
        var difference: UInt8 = 0
        for (a, b) in zip(received, expected) { difference |= a ^ b }
        guard difference == 0 else { return }
        let deliver = lock.withLock { () -> Bool in
            guard !used else { return false }
            used = true
            return true
        }
        guard deliver else { return }
        secret.withUnsafeBytes { buffer in
            _ = write(client, buffer.baseAddress, buffer.count)
        }
    }
}

/// Helper side: runs when ssh starts FileHub as SSH_ASKPASS, then exits.
enum AskpassHelper {
    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let path = env[AskpassServer.socketKey], let token = env[AskpassServer.tokenKey] else { return }
        // Answer password prompts only, never host key or passphrase questions.
        let prompt = CommandLine.arguments.dropFirst().joined(separator: " ").lowercased()
        guard prompt.contains("password"), !prompt.contains("passphrase") else { exit(1) }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { exit(1) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { exit(1) }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { exit(1) }
        let request = Array((token + "\n").utf8)
        guard write(fd, request, request.count) == request.count else { exit(1) }
        var answer = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 512)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count <= 0 { break }
            answer += chunk[0..<count]
        }
        close(fd)
        guard !answer.isEmpty else { exit(1) }
        answer.append(0x0A)
        _ = answer.withUnsafeBytes { write(STDOUT_FILENO, $0.baseAddress, $0.count) }
        exit(0)
    }
}
