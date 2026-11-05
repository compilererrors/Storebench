import Foundation
import Security
import Testing
@testable import StorebenchCore

private final class SyntheticProtectedVault: VaultStorage, @unchecked Sendable {
    enum Failure: Error { case denied }
    private let lock = NSLock()
    private var bytes: Data?
    var corruptReadback = false
    var rejectSave = false
    var rejectRead = false
    var rejectCapability = false
    private(set) var reads = 0
    func load() throws -> Data? { try lock.withLock {
        reads += 1
        if rejectRead { throw CredentialVault.Failure.keychain(errSecUserCanceled) }
        if corruptReadback && bytes != nil { return Data(#"{"version":1,"entries":{}}"#.utf8) }
        return bytes
    } }
    func save(_ data: Data) throws { try lock.withLock { if rejectSave { throw Failure.denied }; bytes = data } }
    func validateAccess() throws { if rejectCapability { throw TouchIDKeychainFailure.signing } }
}

@Suite(.serialized) @MainActor struct TouchIDKeychainTests {
    init() throws { _ = try TestIsolation.require() }
    private func root() throws -> URL { try TestIsolation.require().appendingPathComponent("synthetic-touch-id-\(UUID().uuidString)") }

    @Test func signedPolicyRejectsMissingMismatchedOrAdHocIdentitiesAndFixturesNeverCallKeychain() throws {
        #expect(TouchIDKeychainPolicy.supports(applicationIdentifier: "SYNTHETIC1.com.example.synthetic", team: "SYNTHETIC1", bundleIdentifier: "com.example.synthetic"))
        #expect(!TouchIDKeychainPolicy.supports(applicationIdentifier: "SYNTHETIC1.com.example.other", team: "SYNTHETIC1", bundleIdentifier: "com.example.synthetic"))
        #expect(!TouchIDKeychainPolicy.supports(applicationIdentifier: "com.example.synthetic", team: nil, bundleIdentifier: "com.example.synthetic"))
        #expect(!TouchIDKeychainStorage.supported)
        let realBackend = TouchIDKeychainStorage(dataRoot: try root())
        #expect(throws: TouchIDKeychainFailure.signing) { try realBackend.load() }
        #expect(throws: TouchIDKeychainFailure.signing) { try realBackend.save(Data()) }
    }

    @Test func verifiedTransitionUnlocksProtectedCopyWithoutReadingOrWritingSourceAgain() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let source = CountingCredentialStorage(), protected = SyntheticProtectedVault()
        let model = WorkspaceController(workspace: Workspace(root: root), keychainStorage: source, protectedStorage: protected, backupDelay: .seconds(3600), availabilityDelay: .seconds(3600))
        await model.start(); await model.selectStorage(.keychain); await model.setUp(password: nil)
        try await #require(model.session).setDisplayCurrency("EUR")
        let staleWriter = VaultWriter(dataRoot: root, storage: source)
        _ = try staleWriter.read()
        try await model.enableTouchIDKeychain()
        #expect(model.state == .locked && model.session == nil && model.storageMode == .touchID)
        #expect(try CredentialStorageChoice.read(root: root) == .touchID)
        let oldCalls = source.calls
        #expect(throws: CredentialAccessFailure.changed) { try staleWriter.read() }
        await model.unlock(password: "")
        #expect(model.state == .unlocked([]) && source.calls == oldCalls)
        #expect(try await #require(model.session).displayCurrency() == "EUR")
        await model.signOut()
        let restarted = WorkspaceController(workspace: Workspace(root: root), keychainStorage: source, protectedStorage: protected, backupDelay: .seconds(3600), availabilityDelay: .seconds(3600))
        let before = protected.reads
        await restarted.start()
        #expect(restarted.state == .locked && protected.reads == before && source.calls == oldCalls)
        protected.rejectRead = true; await restarted.unlock(password: "")
        #expect(restarted.state == .locked && restarted.session == nil && source.calls == oldCalls)
        protected.rejectRead = false; await restarted.unlock(password: "")
        #expect(try await #require(restarted.session).displayCurrency() == "EUR")
        await restarted.signOut()
    }

    @Test func failedCopyCorruptReadbackAndStalePreferencesKeepOriginalVaultAndChoice() throws {
        for failure in 0..<3 {
            let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
            let sourceStorage = MemoryVaultStorage(), source = VaultWriter(dataRoot: root, storage: sourceStorage)
            try CredentialStorageChoice.save(.keychain, root: root, expected: nil)
            _ = try source.set("apple:synthetic-account", "synthetic-credential-value")
            let original = try sourceStorage.load(), protected = SyntheticProtectedVault()
            if failure == 0 { protected.rejectSave = true }
            if failure == 1 { protected.corruptReadback = true }
            if failure == 2 { try CredentialStorageChoice.saveAuthentication(true, root: root, expected: false) }
            #expect(throws: (any Error).self) { try CredentialStorageChoice.enableTouchID(root: root, source: source, destination: protected, expectedAuthentication: false) }
            #expect(try sourceStorage.load() == original && CredentialStorageChoice.read(root: root) == .keychain)
        }
    }
}
