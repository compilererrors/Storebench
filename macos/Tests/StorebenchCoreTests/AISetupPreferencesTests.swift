import Foundation
import Testing
@testable import StorebenchCore

@Suite struct AISetupPreferencesTests {
    init() throws { _ = try TestIsolation.require() }
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func firstOpeningOffersSetupAndLaterWaitsSevenDaysAcrossReopening() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let original = try await session.aiSetupPreferences()
        #expect(original.revision == 0 && original.choice == nil && original.defaultProvider == .chatgpt && original.shouldAsk(now: now))
        let later = try await session.saveAISetupPreferences(original.answering(.later, now: now))
        #expect(later.revision == 1 && !later.shouldAsk(now: now.addingTimeInterval(7 * 86400 - 1)))
        let reopened = try WorkspaceSession(workspace: Workspace(root: root), vault: await session.vault)
        let restored = try await reopened.aiSetupPreferences()
        #expect(restored == later && restored.shouldAsk(now: now.addingTimeInterval(7 * 86400)))
        #expect(try await session.aiConnections().isEmpty)
        #expect(try await session.aiJobs(accountId: "synthetic-account", appId: "1000000001").isEmpty)
        #expect(try await session.publishHistory(accountId: "synthetic-account", appId: "1000000001").isEmpty)
    }

    @Test(arguments: [AISetupPreferences.Choice.setup, .never]) func setupAndNeverSuppressFutureIntroductions(_ choice: AISetupPreferences.Choice) async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let original = try await session.aiSetupPreferences()
        let saved = try await session.saveAISetupPreferences(original.answering(choice, now: now))
        #expect(!saved.shouldAsk(now: now.addingTimeInterval(365 * 86400)) && saved.remindAfter == nil)
        var edited = saved; edited.defaultProvider = .openai
        let updated = try await session.saveAISetupPreferences(edited)
        #expect(updated.defaultProvider == .openai && updated.choice == choice && !updated.shouldAsk(now: now))
        #expect(try await session.aiConnections().isEmpty)
    }

    @Test func twoWindowsCannotOverwriteEachOthersSetupChoice() async throws {
        let (first, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let second = try WorkspaceSession(workspace: Workspace(root: root), vault: await first.vault)
        let firstRead = try await first.aiSetupPreferences(), secondRead = try await second.aiSetupPreferences()
        func save(_ session: WorkspaceSession, _ value: AISetupPreferences) async -> Bool {
            do { _ = try await session.saveAISetupPreferences(value); return true }
            catch { #expect(error as? DraftFailure == .stale); return false }
        }
        async let one = save(first, firstRead.answering(.later, now: now))
        async let two = save(second, secondRead.answering(.never, now: now))
        let results = await [one, two]
        #expect(results.filter { $0 }.count == 1)
        let saved = try await first.aiSetupPreferences()
        #expect(saved.revision == 1 && saved.choice == (results[0] ? .later : .never))
        await #expect(throws: DraftFailure.stale) { try await second.saveAISetupPreferences(secondRead.answering(.setup, now: now)) }
        #expect(try await second.aiSetupPreferences() == saved)
    }

    @Test func malformedPreferencesArePreservedAndTheMutexIsNeverReplaced() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let original = try await session.aiSetupPreferences()
        let first = try await session.saveAISetupPreferences(original.answering(.later, now: now))
        let mutex = root.appendingPathComponent("state-v2/ai_preferences.mutex")
        let inode = try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber
        _ = try await session.saveAISetupPreferences(first.answering(.never, now: now))
        #expect(try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber == inode)
        let bad = JSONText.object([("schemaVersion", .number(999))]).data
        try await session.storeAccess { store in try store.transaction { _ in [.put(namespace: "ai_preferences", key: "current", json: bad)] } }
        await #expect(throws: DraftFailure.invalid) { try await session.aiSetupPreferences() }
        await #expect(throws: DraftFailure.invalid) { try await session.saveAISetupPreferences(first.answering(.setup, now: now)) }
        #expect(try await session.storeAccess { try $0.document(namespace: "ai_preferences", key: "current")?.payload } == bad)
    }
}

extension AITests {
    @Test @MainActor func incompleteCardDraftsSaveWithNoAvailableAIServiceAndStillExplainGenerationRequirements() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let scope = LocalEditorDraft.Scope(accountId: "synthetic-account", appId: "1000000001", editor: "ai-cards", resource: "composer")
        let editor = LocalEditorDraftEditor(scope: scope, session: session)
        let initial = JSONText.object([("name", .string("")), ("brief", .string("")), ("provider", .string("apple"))])
        _ = await editor.load(initial: initial)
        let value = initial.setting("name", .string("Synthetic draft"))
        #expect(await editor.saveCurrent(value: { value }))
        #expect(await editor.saveCurrent(value: { value }))
        #expect(try await session.localEditorDraft(scope)?.value == value)
        #expect(!AppleLocalAI.available)
        #expect(AICards.generationIssue(name: "Synthetic draft", brief: "", screenshots: 0, provider: "apple", connections: [], localAvailable: false) != nil)
        #expect(try await session.aiJobs(accountId: scope.accountId, appId: scope.appId).isEmpty)
    }

    @Test func cardGenerationReadinessNamesTheMissingServiceWithoutSwitchingProviders() async throws {
        let (session, root, _, connection) = try await connected(); defer { try? FileManager.default.removeItem(at: root) }
        func issue(_ provider: AIProvider, local: Bool) -> String? {
            AICards.generationIssue(name: "Synthetic draft", brief: "Show synthetic benefits", screenshots: 2, provider: provider.rawValue, connections: [connection], localAvailable: local)
        }
        #expect(issue(.apple, local: false)?.contains("Apple Intelligence is unavailable") == true)
        #expect(issue(.apple, local: true) == nil)
        #expect(issue(.openai, local: false) == nil)
        #expect(issue(.anthropic, local: true)?.contains("Connect Claude API") == true)
        #expect(try await session.aiJobs(accountId: "synthetic-account", appId: "1000000001").isEmpty)
    }
}
