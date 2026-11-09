import CryptoKit
import Foundation
import Security

/// Storebench's one Keychain item, "Storebench credentials".
/// Every secret is an entry in a JSON object, so macOS asks once per app identity instead of once per credential.
public struct CredentialVault: Sendable {
    public static let service = "app.storebench.vault.v1", account = "storebench"
    public let entries: [String: String]
    private init(entries: [String: String]) { self.entries = entries }
    static let empty = CredentialVault(entries: [:])

    public enum Failure: Error, Equatable { case unreadable, keychain(OSStatus) }

    /// Parses the item's JSON with fixed rules: version 1 and known entry kinds only.
    public init(json data: Data) throws {
        guard data.count <= 256 * 1024 + 1024, let object = try? JSONText.parse(data), object["version"] == .number(1),
              case .object(let entries)? = object["entries"] else { throw Failure.unreadable }
        var parsed: [String: String] = [:]
        for (key, value) in entries {
            guard (try? Self.legacyIdentity(key)) != nil,
                  let text = value.text, !text.isEmpty, text.utf16.count <= 20_000 else { throw Failure.unreadable }
            parsed[key] = text
        }
        self.entries = parsed
    }

    /// Preserves the exact credential identities used by earlier storage versions.
    static func legacyIdentity(_ key: String) throws -> (service: String, account: String) {
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        let services = ["apple": "app.storebench.apple-api-key.v1", "reporter": "app.storebench.reporter-token.v1",
                        "database": "app.storebench.database-key.v1", "backup": "app.storebench.backup-passphrase.v1", "appleid": "app.storebench.apple-id-session.v1",
                        "ai": "app.storebench.ai-api-key.v1", "appleidpassword": "app.storebench.apple-id-password.v1"]
        guard parts.count == 2, let service = services[parts[0]],
              parts[1].range(of: #"\A[A-Za-z0-9_-]{1,200}\z"#, options: .regularExpression) != nil else { throw VaultWriter.Failure.invalid }
        return (service, parts[1])
    }

    /// Reads the item from the login keychain. An absent item is an empty vault.
    public static func read() throws -> CredentialVault {
        try CredentialVault(json: try KeychainVaultStorage().load() ?? Data(#"{"version":1,"entries":{}}"#.utf8))
    }

    /// The entry name for a data directory's database key, named `db_<sha256(root)[:40]>`.
    public static func databaseEntry(root: URL) -> String {
        let digest = SHA256.hash(data: Data(LocalPaths.lexical(root).utf8)).map { String(format: "%02x", $0) }.joined()
        return "database:db_\(digest.prefix(40))"
    }

    public func databaseKeyRecord(root: URL) throws -> DatabaseKeyRecord? {
        guard let text = entries[Self.databaseEntry(root: root)] else { return nil }
        return try DatabaseKeyRecord(json: text)
    }
}
