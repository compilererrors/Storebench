import Foundation
import Security

/// One permission attempt across startup, account reads, reporting and background work.
final class KeychainAccessSession: @unchecked Sendable {
    static let shared = KeychainAccessSession()
    private let lock = NSLock()
    private var prompted = false
    private var paused = false

    func perform(_ operation: (Bool) -> OSStatus) throws -> OSStatus {
        try lock.withLock {
            guard !paused else { throw CredentialAccessFailure.paused }
            let quiet = operation(false)
            guard [errSecInteractionNotAllowed, errSecInteractionRequired, errSecAuthFailed].contains(quiet) else {
                if quiet == errSecUserCanceled { paused = true }
                return quiet
            }
            guard !prompted else { paused = true; throw CredentialAccessFailure.paused }
            prompted = true
            let result = operation(true)
            if result != errSecSuccess && result != errSecItemNotFound { paused = true }
            return result
        }
    }

    func retry() { lock.withLock { prompted = false; paused = false } }
}

/// Cached reads are valid only for the generation checked under the shared OS mutex.
final class VaultReadSession: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: (version: String, vault: CredentialVault)?
    func read(version: String, load: () throws -> CredentialVault) throws -> CredentialVault {
        try lock.withLock {
            if let cached, cached.version == version { return cached.vault }
            cached = nil
            let vault = try load()
            cached = (version, vault)
            return vault
        }
    }
    func discard() { lock.withLock { cached = nil } }
}
