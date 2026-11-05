import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) @MainActor struct LanguageDraftEditorTests {
    init() throws { _ = try TestIsolation.require() }
    private let scope = MediaDraftScope(accountId: "synthetic-account", appId: "1000000001", revisionId: "00000000-0000-4000-8000-000000000002")
    private let selection = LanguageDrafts.Selection(id: "synthetic-version-locale", scope: .version)
    private enum SyntheticFailure: Error { case read, timeout }
    @MainActor private final class Gate {
        var entered = false
        private var continuation: CheckedContinuation<Void, Never>?
        func hold() async { await withCheckedContinuation { continuation = $0; entered = true } }
        func release() { continuation?.resume(); continuation = nil }
        func wait() async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while !entered { guard ContinuousClock.now < deadline else { throw SyntheticFailure.timeout }; try await Task.sleep(for: .milliseconds(10)) }
        }
    }
    private func sections(_ description: String = "Synthetic imported text", id: String = "synthetic-version-locale") -> [LanguageDrafts.Section] {
        let fields = Dictionary(uniqueKeysWithValues: TextDrafts.versionFields.map { ($0, $0 == "description" ? description : "") })
        return [.init(selection: .init(id: id, scope: .version), imported: fields, draft: .init(fields: fields, fingerprint: TextDrafts.fingerprint(fields), edited: false))]
    }
    private func owner(read: @escaping @MainActor () async throws -> [LanguageDrafts.Section], workflow: ListingSaveWorkflow? = nil,
                       save: @escaping @MainActor ([LanguageDrafts.Entry]) async throws -> [String: String]) -> LanguageDraftEditor {
        .init(scope: scope, versionId: "synthetic-version", locale: "en-US", selections: [selection], workflow: workflow, read: read, save: save)
    }
    private func description(_ owner: LanguageDraftEditor) throws -> LanguageEditorState.Field {
        try #require(owner.editor?.fields.first { $0.key == "description" })
    }
    private func receipt(_ entries: [LanguageDrafts.Entry]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.selection.id, TextDrafts.fingerprint($0.fields)) })
    }
    @Test func aCleanSaveDoesNotWriteAndReloadCannotEraseTyping() async throws {
        let saved = sections(); var reads = 0, writes = 0
        let owner = owner(read: { reads += 1; return saved }, save: { writes += 1; return receipt($0) })
        await owner.load(); #expect(await owner.save()); #expect(writes == 0)
        try owner.change(description(owner), to: "Synthetic local edit"); await owner.load()
        #expect(owner.dirty && reads == 1 && owner.workflow.dirty)
        #expect(await owner.save()); #expect(!owner.dirty && writes == 1)
    }
    @Test func aLateEditSurvivesItsEarlierConfirmedPhysicalWrite() async throws {
        let saved = sections(), gate = Gate(); var writes = 0
        let owner = owner(read: { saved }, save: { entries in writes += 1; await gate.hold(); return receipt(entries) })
        await owner.load(); let field = try description(owner); try owner.change(field, to: "Synthetic first snapshot")
        let task = Task { await owner.save() }; try await gate.wait(); defer { gate.release() }
        try owner.change(field, to: "Synthetic later typing"); gate.release(); #expect(await task.value)
        #expect(owner.dirty && owner.editor?.saved(field) == "Synthetic first snapshot" && owner.editor?.value(field) == "Synthetic later typing" && writes == 1)
    }
    @Test func initialReadFailureNeedsExplicitBaselineSelection() async throws {
        let saved = sections(); var fails = true, writes = 0
        let owner = owner(read: { if fails { throw SyntheticFailure.read }; return saved }, save: { writes += 1; return receipt($0) })
        await owner.load(); #expect(owner.editor == nil && owner.state.blocked)
        fails = false; await owner.readLatest(); #expect(owner.editor == nil && owner.latest != nil && owner.state.blocked && writes == 0)
        owner.acceptLatest(keepEdits: false); #expect(owner.editor != nil && !owner.state.blocked && !owner.dirty && writes == 0 && owner.autosave.phase == .paused)
    }
    @Test func aForeignReadCannotReplaceTheCapturedTextScope() async {
        let foreign = sections(id: "synthetic-other-language"), owner = owner(read: { foreign }, save: { receipt($0) })
        await owner.load(); await owner.readLatest()
        #expect(owner.editor == nil && owner.latest == nil && owner.workflow.blocked)
    }
    @Test func staleSaveAndRevertDoNotClearTheNeedForComparison() async throws {
        let first = sections(), latest = sections("Synthetic concurrent text"); var current = first, writes = 0
        let owner = owner(read: { current }, save: { entries in
            writes += 1
            guard entries.first?.fingerprint == current.first?.draft.fingerprint else { throw DraftFailure.stale }
            return receipt(entries)
        })
        await owner.load(); let field = try description(owner); try owner.change(field, to: "Synthetic retained wording"); current = latest
        #expect(!(await owner.save())); #expect(owner.needsComparison && owner.dirty && writes == 1)
        owner.revert(); #expect(!owner.dirty && owner.needsComparison && owner.state.blocked)
        try owner.change(field, to: "Synthetic retained wording"); let captured = owner.editor?.fingerprints
        await owner.readLatest(); #expect(owner.editor?.fingerprints == captured && owner.editor?.value(field) == "Synthetic retained wording")
        owner.acceptLatest(keepEdits: true); #expect(!owner.needsComparison && owner.dirty && owner.autosave.phase == .paused && writes == 1)
        #expect(await owner.save()); #expect(!owner.dirty && writes == 2)
    }
    @Test func aMismatchedReceiptKeepsInputsAndCannotBeUsedForReview() async throws {
        let saved = sections(), owner = owner(read: { saved }, save: { _ in [selection.id: String(repeating: "f", count: 64)] })
        await owner.load(); try owner.change(description(owner), to: "Synthetic pending wording")
        #expect(!(await owner.save())); #expect(owner.dirty && owner.needsComparison && owner.state.blocked)
        #expect(throws: PublishFailure.self) { try owner.publishingRequest(targetMode: "apple-version") }
    }
    @Test func anOwnedFileDialogAndAuxiliaryReadBlockSharedSaving() async throws {
        let saved = sections(), owner = owner(read: { saved }, save: { receipt($0) }); await owner.load()
        owner.dialogOpen = true; let dialog = await owner.workflow.run(); #expect(dialog.failure == .blocked)
        owner.dialogOpen = false; owner.auxiliaryBusy = true; let auxiliary = await owner.workflow.run(); #expect(auxiliary.failure == .blocked)
        owner.auxiliaryBusy = false; #expect(owner.workflow.ready)
    }
    @Test func textSavesBeforeLayoutsAndFilesAndAReviewIsInvalidatedImmediately() async throws {
        let saved = sections(), workflow = ListingSaveWorkflow(identity: "Synthetic combined language"), gate = Gate()
        var layoutDirty = true, fileDirty = true, order: [String] = [], policy = EditorProtectionPolicy()
        workflow.register(priority: .file, state: { .init(dirty: fileDirty, blocked: false, signature: "Synthetic file") }, save: { order.append("file"); fileDirty = false; return true })
        workflow.register(priority: .layout, state: { .init(dirty: layoutDirty, blocked: false, signature: "Synthetic layout") }, save: { order.append("layout"); layoutDirty = false; return true })
        let owner = owner(read: { saved }, workflow: workflow, save: { order.append("text"); return receipt($0) })
        owner.didChange = { policy.update(id: "synthetic-language-owner", dirty: workflow.dirty, busy: workflow.busy || owner.busy) }
        await owner.load(); let field = try description(owner); try owner.change(field, to: "Synthetic combined text")
        let task = Task { await workflow.run(prepare: { await gate.hold() }) }; try await gate.wait(); defer { gate.release() }
        #expect(order == ["text", "layout", "file"] && policy.decision == .wait)
        gate.release(); let result = await task.value; #expect(result.reviewReady && workflow.owns(result) && policy.decision == .ready)
        try owner.change(field, to: "Synthetic new wording")
        #expect(!workflow.owns(result) && workflow.dirty && policy.decision == .confirmDiscard)
    }
    @Test func aLateEditDuringPreparationWithholdsTheReview() async throws {
        let saved = sections(), owner = owner(read: { saved }, save: { receipt($0) }), gate = Gate()
        await owner.load(); let field = try description(owner)
        let task = Task { await owner.workflow.run(prepare: { await gate.hold() }) }; try await gate.wait(); defer { gate.release() }
        try owner.change(field, to: "Synthetic late input"); gate.release(); let result = await task.value
        #expect(result.failure == .changed && !result.reviewReady && owner.dirty)
    }
    @Test func retirementOnlyReleasesThisOwnersRegistrationsAndObserver() async throws {
        let saved = sections(), workflow = ListingSaveWorkflow(identity: "Synthetic shared ownership"); var otherDirty = true, callbacks = 0, saves = 0
        let observer = workflow.observe { callbacks += 1 }
        workflow.register(priority: .text, state: { .init(dirty: otherDirty, blocked: false, signature: "Synthetic other owner") }, save: { saves += 1; otherDirty = false; return true })
        let owner = owner(read: { saved }, workflow: workflow, save: { receipt($0) }); await owner.load(); owner.retire()
        let result = await workflow.run(); #expect(result.complete && result.saves == 1 && saves == 1 && callbacks > 0)
        #expect(!(await owner.save())); let before = callbacks; workflow.removeObserver(observer); workflow.changed(); #expect(callbacks == before)
    }
    @Test func retiringDuringASaveAcknowledgesOnlyItsCompletedSnapshot() async throws {
        let saved = sections(), ownerGate = Gate(); var writes = 0
        let owner = owner(read: { saved }, save: { entries in writes += 1; await ownerGate.hold(); return receipt(entries) })
        await owner.load(); let field = try description(owner); try owner.change(field, to: "Synthetic owned snapshot")
        let before = owner.editor?.fingerprints, task = Task { await owner.save() }; try await ownerGate.wait(); defer { ownerGate.release() }
        owner.retire(); ownerGate.release(); #expect(await task.value)
        #expect(writes == 1 && owner.editor?.fingerprints == before && owner.dirty && !owner.active && !owner.busy)
    }
}
