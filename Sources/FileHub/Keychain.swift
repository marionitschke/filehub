import Foundation
import Security

/// Passwords of all connections in a single keychain item (service "FileHub") created via the
/// Security framework, so other programs (`/usr/bin/security` in a script, too) cannot read it
/// without a prompt. A rebuild changes the ad hoc signature and macOS asks again (access list
/// and partition list); one item instead of one per connection keeps it at that.
/// Read once per launch and then kept in memory (Hardened Runtime: no debugger, no foreign
/// libraries). Values never go into files, arguments, the environment or the log.
enum Keychain {
    private static let cache = Cached<[String: String]>()

    static var service: String {
        #if CHECKS
        return ProcessInfo.processInfo.environment["FILEHUB_KEYCHAIN_SERVICE"] ?? "FileHub-Prüfung"
        #else
        return "FileHub"
        #endif
    }
    private static let account = "Zugangsdaten"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func passwords() throws -> [String: String] {
        try cache.get(read)
    }

    private static func read() throws -> [String: String] {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return [:] }
        guard status == errSecSuccess, let data = result as? Data else { throw failure(status) }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    static func password(for id: UUID) throws -> String? {
        try passwords()[id.uuidString]
    }

    static func hasPassword(for id: UUID) -> Bool {
        ((try? passwords()) ?? [:])[id.uuidString] != nil
    }

    /// nil removes the connection's password.
    static func setPassword(_ password: String?, for id: UUID) throws {
        var all = try passwords()
        all[id.uuidString] = password
        try store(all)
    }

    static func store(_ all: [String: String]) throws {
        if all.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
            cache.set(all)
            return
        }
        let data = try JSONEncoder().encode(all)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess {
            cache.set(all)
            return
        }
        guard update == errSecItemNotFound else { throw failure(update) }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = service
        item[kSecAttrDescription as String] = "Zugangsdaten der FileHub-Verbindungen"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw failure(status) }
        cache.set(all)
    }

    private static func failure(_ status: OSStatus) -> RemoteError {
        switch status {
        case errSecUserCanceled, errSecAuthFailed:
            return RemoteError("Zugriff auf den Schlüsselbund wurde abgelehnt.")
        case errSecInteractionNotAllowed:
            return RemoteError("Der Schlüsselbund ist gesperrt.")
        default:
            let text = SecCopyErrorMessageString(status, nil) as String? ?? "Fehler \(status)"
            return RemoteError("Schlüsselbund: \(text)")
        }
    }
}

/// Value loaded once and then served from memory. Failures (denied, locked) are not kept, the
/// next access retries. Concurrent first accesses wait for each other so macOS asks only once.
final class Cached<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?

    func get(_ load: () throws -> Value) rethrows -> Value {
        lock.lock()
        defer { lock.unlock() }
        if let value { return value }
        let loaded = try load()
        value = loaded
        return loaded
    }

    /// New value after a successful write; nil means reload on the next access.
    func set(_ newValue: Value?) {
        lock.withLock { value = newValue }
    }
}
