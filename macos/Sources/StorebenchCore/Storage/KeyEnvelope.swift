import CryptoKit
import Foundation

/// The wrapped SQLCipher database key in its stored envelope format (version 1).
public enum KeyEnvelope: Equatable, Sendable {
    case device(key: Data)
    case password(salt: Data, nonce: Data, ciphertext: Data, tag: Data)

    public enum Failure: Error, Equatable { case invalidEnvelope, passwordRequired, incorrectPassword }

    static let context = Data("storebench-database-key-v1".utf8)

    /// Parses the envelope JSON object with exactly the stored fields and lengths.
    public init(json object: [String: Any]) throws {
        guard object["version"] as? Int == 1, let mode = object["mode"] as? String else { throw Failure.invalidEnvelope }
        let keys = Set(object.keys)
        switch mode {
        case "device" where keys == ["version", "mode", "key"]:
            self = .device(key: try Base64URL.decode(object["key"], length: 32))
        case "password" where keys == ["version", "mode", "salt", "nonce", "ciphertext", "tag"]:
            self = .password(salt: try Base64URL.decode(object["salt"], length: 16), nonce: try Base64URL.decode(object["nonce"], length: 12),
                             ciphertext: try Base64URL.decode(object["ciphertext"], length: 32), tag: try Base64URL.decode(object["tag"], length: 16))
        default: throw Failure.invalidEnvelope
        }
    }

    public var requiresPassword: Bool { if case .password = self { true } else { false } }

    /// Returns the 32-byte database key. A password envelope uses scrypt (N=2^17, r=8, p=1) and AES-256-GCM.
    public func unwrap(password: String? = nil) throws -> Data {
        try unwrap(password: password, context: Self.context)
    }

    func unwrap(password: String?, context: Data) throws -> Data {
        switch self {
        case .device(let key): return key
        case .password(let salt, let nonce, let ciphertext, let tag):
            guard let password else { throw Failure.passwordRequired }
            guard (12...256).contains(password.utf16.count) else { throw Failure.incorrectPassword }
            var wrapping = try Scrypt.derive(password: Data(password.utf8), salt: salt, n: 1 << 17, r: 8, p: 1, length: 32)
            defer { wrapping.resetBytes(in: 0..<wrapping.count) }
            do {
                let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: ciphertext, tag: tag)
                return try AES.GCM.open(box, using: SymmetricKey(data: wrapping), authenticating: context)
            } catch { throw Failure.incorrectPassword }
        }
    }
}

/// The database key record kept in the shared Keychain item: `{ schemaVersion: 1, phase, envelope }`.
public struct DatabaseKeyRecord: Sendable {
    public let ready: Bool
    public let envelope: KeyEnvelope

    public init(json text: String) throws {
        guard text.utf8.count <= 2048, let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              Set(object.keys) == ["schemaVersion", "phase", "envelope"], object["schemaVersion"] as? Int == 1,
              let phase = object["phase"] as? String, ["preparing", "ready"].contains(phase),
              let envelope = object["envelope"] as? [String: Any] else { throw KeyEnvelope.Failure.invalidEnvelope }
        self.ready = phase == "ready"
        self.envelope = try KeyEnvelope(json: envelope)
    }
}

enum Base64URL {
    static func decode(_ value: Any?, length: Int) throws -> Data {
        guard let text = value as? String, !text.isEmpty, text.utf8.allSatisfy({ byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || byte == 45 || byte == 95
        }) else { throw KeyEnvelope.Failure.invalidEnvelope }
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64), data.count == length else { throw KeyEnvelope.Failure.invalidEnvelope }
        return data
    }
}
