import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) @MainActor struct LocalEditorDraftTests {
    init() throws { _ = try TestIsolation.require() }
    private let scope = LocalEditorDraft.Scope(accountId: "synthetic-account", appId: "1000000001", editor: "synthetic-form", resource: "synthetic-resource")

    @Test func partialAnswersSurviveReopeningWithoutAnAppleWrite() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let editor = LocalEditorDraftEditor(scope: scope, session: session)
        #expect(await editor.load(initial: .null) == nil)
        let partial = EncryptionQuestionnaire(json: .object([("algorithms", .string("proprietary")), ("france", .string(""))])).json
        #expect(await editor.save(partial))
        #expect(!editor.dirty(partial))
        #expect(editor.hasChangesToSync(partial))
        let reopened = LocalEditorDraftEditor(scope: scope, session: session)
        #expect(await reopened.load(initial: .null) == partial)
        #expect(reopened.loaded && !reopened.dirty(partial))
        #expect(reopened.hasChangesToSync(partial))
        #expect(try await session.publishHistory(accountId: scope.accountId, appId: scope.appId).isEmpty)
        let other = LocalEditorDraft.Scope(accountId: scope.accountId, appId: "1000000002", editor: scope.editor, resource: scope.resource)
        #expect(try await session.localEditorDraft(other) == nil)
    }

    @Test func staleEditorMustCompareBeforeSavingAndKeepsItsEdits() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let first = LocalEditorDraftEditor(scope: scope, session: session), second = LocalEditorDraftEditor(scope: scope, session: session)
        _ = await first.load(initial: .null); _ = await second.load(initial: .null)
        #expect(await first.save(.string("First synthetic draft")))
        #expect(!(await second.save(.string("Other synthetic edits"))))
        #expect(second.needsComparison && second.dirty(.string("Other synthetic edits")))
        #expect(!(await second.save(.string("Other synthetic edits"))))
        await second.readLatest()
        #expect(second.latest?.value == .string("First synthetic draft"))
        #expect(second.acceptLatest(keepEdits: true) == nil)
        #expect(!second.needsComparison && second.dirty(.string("Other synthetic edits")))
        #expect(await second.save(.string("Other synthetic edits")))
        #expect(try await session.localEditorDraft(scope)?.revision == 2)
        #expect(!(await first.save(.string("First synthetic draft"))))
        #expect(first.needsComparison)
        await first.readLatest()
        #expect(first.acceptLatest(keepEdits: false) == .string("Other synthetic edits"))
    }

    @Test func boundedDraftWriteCannotReplaceSavedData() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await session.saveLocalEditorDraft(.string("Synthetic saved value"), scope: scope, expected: 0)
        await #expect(throws: DraftFailure.tooLarge) {
            try await session.saveLocalEditorDraft(.string(String(repeating: "x", count: 1_000_001)), scope: scope, expected: 1)
        }
        #expect(try await session.localEditorDraft(scope)?.value == .string("Synthetic saved value"))
        let compound = LocalEditorDraft.Scope(accountId: "synthetic-account:other", appId: "1000000001", editor: scope.editor, resource: scope.resource)
        #expect(compound.key != scope.key)
    }

    @Test func aDepartureSaveCannotApproveNewerFormInputs() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let editor = LocalEditorDraftEditor(scope: scope, session: session)
        _ = await editor.load(initial: .null)
        var reads = 0
        let complete = await editor.saveCurrent(value: {
            reads += 1
            return .string(reads == 1 ? "Synthetic captured draft" : "Synthetic newer inputs")
        })
        #expect(!complete && reads == 2)
        #expect(editor.dirty(.string("Synthetic newer inputs")))
        #expect(try await session.localEditorDraft(scope)?.value == .string("Synthetic captured draft"))
    }
    @Test func publishedDraftDoesNotReplaceLaterAppleValuesAndPreservesUnpublishedFields() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let original = JSONText.object([("notes", .string("Original notes")), ("name", .string("Synthetic original"))])
        let changed = original.setting("name", .string("Synthetic published")).setting("notes", .string("Unpublished notes"))
        let editor = LocalEditorDraftEditor(scope: scope, session: session)
        _ = await editor.load(initial: original); #expect(await editor.save(changed))
        let snapshot = try #require(editor.syncSnapshot(paths: [["name"]]))
        await editor.acknowledge(snapshot)
        #expect(editor.hasChangesToSync(changed))
        let remote = original.setting("name", .string("Synthetic newer Apple value"))
        let reopened = LocalEditorDraftEditor(scope: scope, session: session)
        let restored = try #require(await reopened.load(initial: remote))
        #expect(restored["name"] == remote["name"] && restored["notes"] == changed["notes"])
        #expect(!reopened.needsComparison)
        #expect(!reopened.dirty(.object([("name", remote["name"]!), ("notes", changed["notes"]!)])))
        let conflict = LocalEditorDraftEditor(scope: scope, session: session)
        #expect(await conflict.load(initial: remote.setting("notes", .string("New remote notes"))) == nil)
        #expect(conflict.needsComparison && conflict.latest?.value["name"] == remote["name"])
        #expect(conflict.latest?.value["notes"] == changed["notes"])
        await conflict.readLatest()
        #expect(conflict.latest?.value["name"] == remote["name"])
    }

    @Test func successfulSyncClearsHighlightAndAnOlderReviewCannotAcknowledgeNewerSavedEdits() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let editor = LocalEditorDraftEditor(scope: scope, session: session)
        _ = await editor.load(initial: .string("Synthetic original"))
        #expect(await editor.save(.string("Synthetic published")))
        let snapshot = try #require(editor.syncSnapshot())
        await editor.acknowledge(snapshot)
        #expect(!editor.hasChangesToSync(.string("Synthetic published")))
        let reopened = LocalEditorDraftEditor(scope: scope, session: session)
        #expect(await reopened.load(initial: .string("Synthetic newer Apple value")) == nil)
        #expect(await editor.save(.string("Synthetic newer draft")))
        await editor.acknowledge(snapshot)
        #expect(editor.hasChangesToSync(.string("Synthetic newer draft")))
        #expect(try await session.localEditorDraft(scope)?.value == .string("Synthetic newer draft"))
    }

    @Test func concurrentRemoteEditsRequireComparisonAndIndependentEditsMerge() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let original = JSONText.object([("notes", .string("Original notes")), ("name", .string("Synthetic original"))])
        let editor = LocalEditorDraftEditor(scope: scope, session: session)
        _ = await editor.load(initial: original)
        #expect(await editor.save(original.setting("name", .string("Synthetic local"))))
        let conflict = LocalEditorDraftEditor(scope: scope, session: session)
        #expect(await conflict.load(initial: original.setting("name", .string("Synthetic remote"))) == nil)
        #expect(conflict.needsComparison && conflict.latest?.value["name"] == .string("Synthetic local"))
        #expect(!(await conflict.save(original)))
        let independent = LocalEditorDraftEditor(scope: scope, session: session)
        let merged = try #require(await independent.load(initial: original.setting("notes", .string("Remote notes"))))
        #expect(merged["name"] == .string("Synthetic local") && merged["notes"] == .string("Remote notes"))
    }

}
