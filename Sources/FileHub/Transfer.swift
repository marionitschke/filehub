import CommonCrypto
import CryptoKit
import Foundation

/// Setting up more Macs: connections, passwords and confirmed host keys in a password-encrypted
/// file (PBKDF2-SHA256 with 600,000 rounds, AES-256-GCM). SSH keys are not included. Values are
/// never stored unencrypted in the file.
enum SetupTransfer {
    struct Payload: Codable, Equatable {
        var created: String
        var servers: [ServerProfile]
        var passwords: [String: String]
        var knownHosts: String
    }

    private struct Envelope: Codable {
        var format: String
        var version: Int
        var iterations: Int
        var salt: String
        var box: String
    }

    enum Failure: LocalizedError {
        case notASetupFile, wrongPassword, keyDerivation

        var errorDescription: String? {
            switch self {
            case .notASetupFile: return "Das ist keine Verbindungsdatei von FileHub."
            case .wrongPassword: return "Passwort falsch oder Datei beschädigt."
            case .keyDerivation: return "Der Schlüssel ließ sich nicht ableiten."
            }
        }
    }

    static let fileName = "FileHub-Verbindungen.filehub"
    static let minPasswordLength = 10
    /// Real files are a few KB; anything above 5 MB is not even read.
    static let maxFileSize = 5 << 20
    private static let format = "FileHub-Verbindungen"
    private static let iterations = 600_000

    static func seal(_ payload: Payload, password: String) throws -> Data {
        let salt = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
        let key = try deriveKey(password, salt: salt, iterations: iterations)
        let plain = try JSONEncoder().encode(payload)
        guard let combined = try AES.GCM.seal(plain, using: key).combined else { throw Failure.keyDerivation }
        let envelope = Envelope(format: format, version: 1, iterations: iterations,
                                salt: salt.base64EncodedString(), box: combined.base64EncodedString())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(envelope)
    }

    static func open(_ data: Data, password: String) throws -> Payload {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.format == format, envelope.version == 1,
              (100_000...10_000_000).contains(envelope.iterations),
              let salt = Data(base64Encoded: envelope.salt), salt.count >= 16,
              let combined = Data(base64Encoded: envelope.box) else { throw Failure.notASetupFile }
        let key = try deriveKey(password, salt: salt, iterations: envelope.iterations)
        guard let box = try? AES.GCM.SealedBox(combined: combined),
              let plain = try? AES.GCM.open(box, using: key),
              let payload = try? JSONDecoder().decode(Payload.self, from: plain) else { throw Failure.wrongPassword }
        return payload
    }

    /// Unicode-normalized so the same password gives the same bytes on both Macs.
    private static func deriveKey(_ password: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        let bytes = Array(password.precomposedStringWithCanonicalMapping.utf8).map { CChar(bitPattern: $0) }
        var derived = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltBytes in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), bytes, bytes.count,
                                 saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                 &derived, derived.count)
        }
        guard status == Int32(kCCSuccess) else { throw Failure.keyDerivation }
        return SymmetricKey(data: derived)
    }
}
