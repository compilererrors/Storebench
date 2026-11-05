import Foundation
import Security
import Testing
@testable import StorebenchCore

@Suite struct KeychainAccessSessionTests {
    init() throws { _ = try TestIsolation.require() }

    @Test func authorizationIsSharedAcrossReadsWritesAndBackgroundRequests() throws {
        let access = KeychainAccessSession()
        var prompts = 0, allowed = false
        let operation: (Bool) -> OSStatus = { interactive in
            if interactive { prompts += 1; allowed = true }
            return allowed ? errSecSuccess : errSecInteractionNotAllowed
        }
        #expect(try access.perform(operation) == errSecSuccess)
        for _ in 0..<30 { #expect(try access.perform(operation) == errSecSuccess) }
        #expect(prompts == 1)
        #expect(throws: CredentialAccessFailure.paused) { try access.perform { _ in errSecInteractionNotAllowed } }
        #expect(prompts == 1)
    }

    @Test func cancellationDoesNotRepromptUntilAnExplicitRetry() throws {
        let access = KeychainAccessSession()
        var prompts = 0, calls = 0
        let denied: (Bool) -> OSStatus = { interactive in
            calls += 1
            if interactive { prompts += 1; return errSecUserCanceled }
            return errSecInteractionNotAllowed
        }
        #expect(try access.perform(denied) == errSecUserCanceled)
        for _ in 0..<20 { #expect(throws: CredentialAccessFailure.paused) { try access.perform(denied) } }
        #expect(prompts == 1 && calls == 2)
        access.retry()
        #expect(try access.perform(denied) == errSecUserCanceled)
        #expect(prompts == 2 && calls == 4)
    }

    @Test func missingItemsAndSilentAccessDoNotConsumeThePermissionAttempt() throws {
        let access = KeychainAccessSession()
        for _ in 0..<5 { #expect(try access.perform { _ in errSecItemNotFound } == errSecItemNotFound) }
        #expect(try access.perform { _ in errSecSuccess } == errSecSuccess)
        var calls: [Bool] = []
        #expect(try access.perform { interactive in calls.append(interactive); return interactive ? errSecSuccess : errSecInteractionNotAllowed } == errSecSuccess)
        #expect(calls == [false, true])
    }

    @Test func concurrentRequestsHaveOnePermissionAttempt() async throws {
        let access = KeychainAccessSession(), count = PromptCount()
        await withTaskGroup(of: Void.self) { tasks in
            for _ in 0..<40 {
                tasks.addTask {
                    do { _ = try access.perform { interactive in if interactive { count.add() }; return interactive ? errSecSuccess : errSecInteractionNotAllowed } }
                    catch { #expect(error as? CredentialAccessFailure == .paused) }
                }
            }
        }
        #expect(count.value == 1)
    }

    @Test func startupAndRepeatedSnapshotReadsShareOneGeneration() async throws {
        let root = try TestIsolation.require().appendingPathComponent("keychain-session-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = SyntheticCredentialStorage(Data(#"{"version":1,"entries":{}}"#.utf8))
        let writer = VaultWriter(dataRoot: root, storage: storage), workspace = Workspace(root: root)
        let created = try workspace.createFresh(writer: writer, password: nil)
        try await created.signOut()
        let baseline = storage.counts.reads
        #expect(try workspace.lock(writer: writer) == .device)
        let session = try WorkspaceSession(workspace: workspace, credentialWriter: writer)
        for _ in 0..<20 { _ = try writer.snapshot(); _ = try writer.read() }
        #expect(storage.counts.reads == baseline + 1)
        try await session.signOut()
        _ = try writer.read()
        #expect(storage.counts.reads == baseline + 2)
    }

    @Test func anotherWriterInvalidatesCachedReadsWithoutLosingEitherChange() throws {
        let root = try TestIsolation.require().appendingPathComponent("keychain-writers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = SyntheticCredentialStorage(Data(#"{"version":1,"entries":{}}"#.utf8))
        let first = VaultWriter(dataRoot: root, storage: storage), second = VaultWriter(dataRoot: root, storage: storage)
        _ = try first.read()
        _ = try second.set("backup:first", "synthetic-first-secret")
        #expect(try first.read().entries["backup:first"] == "synthetic-first-secret")
        _ = try first.set("backup:second", "synthetic-second-secret")
        let saved = try second.read()
        #expect(saved.entries["backup:first"] == "synthetic-first-secret" && saved.entries["backup:second"] == "synthetic-second-secret")
    }
}

private final class PromptCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
