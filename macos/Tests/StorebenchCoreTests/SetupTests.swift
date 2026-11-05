import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct SetupTests {
    init() throws { _ = try TestIsolation.require() }
    func root() throws -> URL {
        let root = (try TestIsolation.require()).appendingPathComponent("storebench-setup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return root
    }

    @Test func firstRunCreatesAnEncryptedStoreWithAKeychainKey() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let writer = VaultWriter(dataRoot: root, storage: MemoryVaultStorage())
        let workspace = Workspace(root: root)
        #expect(try workspace.lock(writer: writer) == nil)
        let session = try workspace.createFresh(writer: writer, password: nil)
        #expect(try await session.accounts().isEmpty)
        let record = try #require(try writer.read().entries[CredentialVault.databaseEntry(root: root)])
        #expect(record.hasPrefix(#"{"schemaVersion":1,"phase":"ready","envelope":{"version":1,"mode":"device","key":""#))
        let bytes = try Data(contentsOf: EncryptedDocumentStore.databaseURL(root: root))
        #expect(bytes.count >= 1024 && bytes.prefix(16) != Data("SQLite format 3\0".utf8))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("state-v2/access-generation").path))
        #expect(throws: Setup.Failure.alreadyConfigured) { try workspace.createFresh(writer: writer, password: nil) }
        _ = try WorkspaceSession(workspace: workspace, vault: try writer.read())
    }

    @Test func passwordSetupNeedsThePasswordToOpen() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let writer = VaultWriter(dataRoot: root, storage: MemoryVaultStorage()), workspace = Workspace(root: root)
        #expect(throws: Setup.Failure.invalidPassword) { try workspace.createFresh(writer: writer, password: "short") }
        _ = try workspace.createFresh(writer: writer, password: "synthetic-setup-password")
        #expect(try workspace.lock(writer: writer) == .password)
        #expect(throws: KeyEnvelope.Failure.incorrectPassword) { try WorkspaceSession(workspace: workspace, vault: try writer.read(), password: "synthetic-wrong-password") }
        _ = try WorkspaceSession(workspace: workspace, vault: try writer.read(), password: "synthetic-setup-password")
    }

    @Test func aSetupThatStoppedWhilePreparingIsCompleted() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let writer = VaultWriter(dataRoot: root, storage: MemoryVaultStorage()), workspace = Workspace(root: root)
        let envelope = try KeyEnvelope.wrap(Data(0..<32), password: nil)
        _ = try writer.set(CredentialVault.databaseEntry(root: root), envelope.record(ready: false))
        #expect(throws: Workspace.Failure.notReady) { try WorkspaceSession(workspace: workspace, vault: try writer.read()) }
        _ = try workspace.completeSetup(writer: writer, password: nil)
        #expect(try DatabaseKeyRecord(json: try #require(try writer.read().entries[CredentialVault.databaseEntry(root: root)])).ready)
    }
}

@Suite(.serialized) struct SettingsTests {
    init() throws { _ = try TestIsolation.require() }
    @Test func lockChangesKeepTheKeyAndPreferencesKeepOtherFields() async throws {
        let root = (try TestIsolation.require()).appendingPathComponent("storebench-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = VaultWriter(dataRoot: root, storage: MemoryVaultStorage()), workspace = Workspace(root: root)
        let session = try workspace.createFresh(writer: writer, password: nil)
        try await session.setDisplayCurrency("SEK")
        #expect(try await session.displayCurrency() == "SEK")
        await #expect(throws: PricingFailure.self) { try await session.setDisplayCurrency("XXQ") }
        #expect(try await session.syncDays() == nil)
        try await session.setSyncDays(90)
        #expect(try await session.syncDays() == 90)

        try workspace.changeLock(writer: writer, currentPassword: nil, newPassword: "synthetic-new-password")
        #expect(try workspace.lock(writer: writer) == .password)
        #expect(throws: KeyEnvelope.Failure.incorrectPassword) { try workspace.changeLock(writer: writer, currentPassword: "synthetic-wrong-password", newPassword: nil) }
        let reopened = try WorkspaceSession(workspace: workspace, vault: try writer.read(), password: "synthetic-new-password")
        #expect(try await reopened.displayCurrency() == "SEK")
        try workspace.changeLock(writer: writer, currentPassword: "synthetic-new-password", newPassword: nil)
        #expect(try workspace.lock(writer: writer) == .device)
    }
}
