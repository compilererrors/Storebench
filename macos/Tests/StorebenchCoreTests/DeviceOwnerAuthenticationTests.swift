import Foundation
import Testing
@testable import StorebenchCore

private actor SyntheticAuthentication: WorkspaceAuthenticating {
    private(set) var calls = 0
    var failure: WorkspaceAuthenticationFailure?
    func fail(_ next: WorkspaceAuthenticationFailure?) { failure = next }
    func authenticate() async throws {
        calls += 1
        try await Task.sleep(for: .milliseconds(20))
        if let failure { throw failure }
    }
}

@Suite(.serialized) @MainActor struct DeviceOwnerAuthenticationTests {
    init() throws { _ = try TestIsolation.require() }
    private func root() throws -> URL { try TestIsolation.require().appendingPathComponent("synthetic-mac-unlock-\(UUID().uuidString)") }
    private func model(_ root: URL, _ storage: CountingCredentialStorage, _ authenticator: SyntheticAuthentication) -> WorkspaceController {
        WorkspaceController(workspace: Workspace(root: root), keychainStorage: storage, authenticator: authenticator, backupDelay: .seconds(3600), availabilityDelay: .seconds(3600))
    }
    @Test func guardedFixturesCannotInvokeActualMacAuthentication() async {
        await #expect(throws: WorkspaceAuthenticationFailure.unavailable) { try await DeviceOwnerAuthentication().authenticate() }
    }
    @Test func authenticatedKeychainUnlockIsExplicitCoalescedAndFailsClosedOnCancellation() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let storage = CountingCredentialStorage(), auth = SyntheticAuthentication(), initial = model(root, storage, auth)
        await initial.start(); await initial.selectStorage(.keychain); await initial.setUp(password: nil)
        try await #require(initial.session).setDisplayCurrency("SEK")
        try await initial.changeDeviceAuthentication(required: true)
        let initialCalls = await auth.calls
        #expect(initial.requiresDeviceAuthentication && initialCalls == 1)
        await initial.signOut()
        let before = storage.calls, restarted = model(root, storage, auth)
        await restarted.start(); await restarted.start()
        #expect(restarted.state == .locked && restarted.lockMode == .device && storage.calls == before)
        await auth.fail(.cancelled)
        await withTaskGroup(of: Void.self) { group in for _ in 0..<12 { group.addTask { await restarted.unlock(password: "") } } }
        #expect(restarted.state == .locked && restarted.session == nil && storage.calls == before)
        let cancelledCalls = await auth.calls
        #expect(cancelledCalls == 2)
        await auth.fail(nil); await restarted.unlock(password: "")
        let unlockedCalls = await auth.calls
        #expect(restarted.state == .unlocked([]) && unlockedCalls == 3)
        #expect(try await #require(restarted.session).displayCurrency() == "SEK")
        await auth.fail(.denied)
        await #expect(throws: WorkspaceAuthenticationFailure.denied) { try await restarted.changeDeviceAuthentication(required: false) }
        #expect(restarted.requiresDeviceAuthentication && restarted.session != nil)
        #expect(try CredentialStorageChoice.preference(root: root)?.requireDeviceAuthentication == true)
        await auth.fail(nil); try await restarted.changeDeviceAuthentication(required: false)
        await restarted.signOut()
        let count = await auth.calls, automatic = model(root, storage, auth)
        await automatic.start(); #expect(automatic.state == .unlocked([]) && !automatic.requiresDeviceAuthentication)
        let automaticCalls = await auth.calls
        #expect(automaticCalls == count)
        await automatic.signOut()
    }
    @Test func invalidPolicyCannotEnableAuthenticationForPasswordOnlyStorageOrReplaceNewerSettings() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        try CredentialStorageChoice.save(.keychain, root: root, expected: nil)
        try CredentialStorageChoice.saveAuthentication(true, root: root, expected: false)
        #expect(throws: CredentialAccessFailure.changed) { try CredentialStorageChoice.saveAuthentication(false, root: root, expected: false) }
        try CredentialStorageChoice.save(.password, root: root, expected: .keychain)
        #expect(try CredentialStorageChoice.preference(root: root)?.requireDeviceAuthentication == false)
        #expect(throws: CredentialAccessFailure.changed) { try CredentialStorageChoice.saveAuthentication(true, root: root, expected: false) }
        let storage = CountingCredentialStorage(), auth = SyntheticAuthentication(), local = model(root, storage, auth)
        await local.start(); await local.setUp(password: "synthetic-password-storage")
        await #expect(throws: CredentialAccessFailure.changed) { try await local.changeDeviceAuthentication(required: true) }
        let passwordCalls = await auth.calls
        #expect(passwordCalls == 0 && storage.calls == 0)
        await local.signOut()
    }
    @Test func changingDatabaseProtectionKeepsMacAuthenticationAndUsesTheNewLockMode() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let storage = CountingCredentialStorage(), auth = SyntheticAuthentication(), controller = model(root, storage, auth)
        await controller.start(); await controller.selectStorage(.keychain); await controller.setUp(password: nil)
        try await #require(controller.session).setDisplayCurrency("EUR")
        try await controller.changeDeviceAuthentication(required: true)
        try await controller.changeLock(currentPassword: nil, newPassword: "synthetic-mac-protected-password")
        #expect(controller.state == .locked && controller.lockMode == .password && controller.session == nil)
        await auth.fail(.cancelled); await controller.unlock(password: "synthetic-mac-protected-password")
        #expect(controller.state == .locked && controller.session == nil)
        await auth.fail(nil); await controller.unlock(password: "synthetic-mac-protected-password")
        #expect(try await #require(controller.session).displayCurrency() == "EUR")
        try await controller.changeLock(currentPassword: "synthetic-mac-protected-password", newPassword: nil)
        #expect(controller.state == .locked && controller.lockMode == .device && controller.session == nil && controller.requiresDeviceAuthentication)
        await controller.unlock(password: "")
        #expect(try await #require(controller.session).displayCurrency() == "EUR")
        await controller.signOut()
    }
}
