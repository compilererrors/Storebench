import CryptoKit
import Foundation
import LocalAuthentication
import Security

public enum TouchIDKeychainFailure: Error, Equatable {
    case signing, unavailable, differentCopy, verification
    public var message: String {
        switch self {
        case .signing: "Touch ID Keychain needs a provisioned, Apple-signed Storebench app. This build cannot enable it; your existing Keychain is unchanged."
        case .unavailable: "Touch ID Keychain is unavailable. Set up Touch ID or a Mac login password in System Settings."
        case .differentCopy: "A different protected credential copy already exists. Nothing was overwritten."
        case .verification: "The protected copy could not be verified. Your current credential storage is unchanged."
        }
    }
}

/// A provisioned application identity is required; ad hoc signatures cannot opt into this backend.
public enum TouchIDKeychainPolicy {
    public static func supports(applicationIdentifier: String?, team: String?, bundleIdentifier: String?) -> Bool {
        guard let team, team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil,
              let bundleIdentifier, bundleIdentifier.range(of: "^[A-Za-z][A-Za-z0-9-]*(\\.[A-Za-z0-9-]+)+$", options: .regularExpression) != nil else { return false }
        return applicationIdentifier == team + "." + bundleIdentifier
    }
}

/// Native-only, device-local credentials. Cancellation never falls back to the login Keychain.
public final class TouchIDKeychainStorage: VaultStorage, @unchecked Sendable {
    private let account: String
    private let lock = NSLock()
    private let access = KeychainAccessSession()
    private var context: LAContext?
    public init(dataRoot: URL) {
        account = SHA256.hash(data: Data(dataRoot.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public static var supported: Bool {
        guard !Network.testMode else { return false }
        return signedSupport
    }
    private static let signedSupport: Bool = {
        var code: SecCode?, staticCode: SecStaticCode?, result: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &result) == errSecSuccess,
              let info = result as? [String: Any], let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else { return false }
        return TouchIDKeychainPolicy.supports(applicationIdentifier: entitlements["com.apple.application-identifier"] as? String,
            team: info[kSecCodeInfoTeamIdentifier as String] as? String, bundleIdentifier: Bundle.main.bundleIdentifier)
    }()
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.storebench.credentials.user-presence.v1",
         kSecAttrAccount as String: account, kSecUseDataProtectionKeychain as String: true]
    }
    private func authenticatedQuery() throws -> [String: Any] {
        guard Self.supported else { throw TouchIDKeychainFailure.signing }
        if context == nil {
            let next = LAContext(); next.localizedReason = "Unlock Storebench credentials."; next.localizedCancelTitle = "Cancel"
            var error: NSError?
            guard next.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { throw TouchIDKeychainFailure.unavailable }
            context = next
        }
        var value = query; value[kSecUseAuthenticationContext as String] = context; return value
    }
    public func validateAccess() throws { guard Self.supported else { throw TouchIDKeychainFailure.signing } }
    public func retryAccess() { lockAccess(); access.retry() }
    public func lockAccess() { lock.withLock { context?.invalidate(); context = nil } }
    public func load() throws -> Data? {
        try lock.withLock {
            var lookup = try authenticatedQuery(), result: CFTypeRef?
            lookup[kSecReturnData as String] = true; lookup[kSecMatchLimit as String] = kSecMatchLimitOne
            defer { context?.interactionNotAllowed = false }
            let status = try access.perform { interactive in
                context?.interactionNotAllowed = !interactive
                return SecItemCopyMatching(lookup as CFDictionary, &result)
            }
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = result as? Data else { throw CredentialVault.Failure.keychain(status) }
            return data
        }
    }
    public func save(_ data: Data) throws {
        try lock.withLock {
            let lookup = try authenticatedQuery()
            defer { context?.interactionNotAllowed = false }
            let updated = try access.perform { interactive in
                context?.interactionNotAllowed = !interactive
                return SecItemUpdate(lookup as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            }
            if updated == errSecSuccess { return }
            guard updated == errSecItemNotFound else { throw CredentialVault.Failure.keychain(updated) }
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, &error) else { throw TouchIDKeychainFailure.unavailable }
            var item = lookup; item[kSecAttrAccessControl as String] = access; item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Storebench protected credentials"
            let status = SecItemAdd(item as CFDictionary, nil)
            guard status == errSecSuccess else { throw CredentialVault.Failure.keychain(status) }
        }
    }
    deinit { context?.invalidate() }
}
