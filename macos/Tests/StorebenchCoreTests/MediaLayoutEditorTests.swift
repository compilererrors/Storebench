import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) @MainActor struct MediaLayoutEditorTests {
    init() throws { _ = try TestIsolation.require() }
    private let scope = MediaDraftScope(accountId: "synthetic-account", appId: "1000000001", revisionId: "00000000-0000-4000-8000-000000000002")
    private enum SyntheticFailure: Error { case save, timeout }
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
    @MainActor private final class Catalog {
        var value: MediaLayoutDraft, reads = 0, saves = 0, fails = false
        init(_ value: MediaLayoutDraft) { self.value = value }
        func read() -> MediaLayoutDraft { reads += 1; return value }
        func save(_ input: MediaDraftInputs, expected: String) throws -> MediaLayoutDraft {
            saves += 1
            guard !fails else { throw SyntheticFailure.save }
            guard value.signature.utf8.elementsEqual(expected.utf8) else { throw ScreenshotFailure.stale }
            guard case .screenshots(let draft) = value else { throw DraftFailure.invalid }
            value = .screenshots(.init(setId: draft.setId, displayType: draft.displayType, items: input.order.compactMap { id in draft.items.first { $0.id == id } },
                hidden: input.hidden, signature: ScreenshotSpecs.signature((input.order, input.order.filter(input.hidden.contains)))))
            return value
        }
    }
    private func catalog(_ ids: [String] = ["synthetic-first", "synthetic-second"], hidden: Set<String> = []) -> MediaLayoutDraft {
        .screenshots(.init(setId: "synthetic-set", displayType: "APP_IPHONE_67", items: ids.map { .init(id: $0, fileName: $0 + ".png", sha256: String(repeating: "0", count: 64), width: 1290, height: 2796, local: false) },
            hidden: hidden, signature: ScreenshotSpecs.signature((ids, ids.filter(hidden.contains)))))
    }
    private func editor(_ store: Catalog) -> MediaLayoutEditor {
        MediaLayoutEditor(scope: scope, key: store.value.key, read: { store.read() }, save: { try store.save($0, expected: $1) })
    }

    @Test func cleanSaveDoesNotWriteAndReloadCannotEraseInputs() async {
        let store = Catalog(catalog()), model = editor(store)
        await model.load(); #expect(await model.save()); #expect(store.saves == 0 && store.reads == 1)
        model.inputs.hidden.insert("synthetic-first"); await model.load()
        #expect(model.dirty && store.reads == 1 && model.inputs.hidden == ["synthetic-first"])
        #expect(await model.save()); #expect(!model.dirty && store.saves == 1)
    }
    @Test func droppedOrdersKeepExclusionsAndRequireTheExactCurrentOwner() async throws {
        let store = Catalog(catalog()), model = editor(store)
        await model.load(); model.inputs.hidden.insert("synthetic-first")
        let original = model.inputs.order, context = model.reorderContext
        #expect(model.reorder(Array(original.reversed()), expected: original, context: context))
        #expect(model.inputs.hidden == ["synthetic-first"] && model.dirty && store.saves == 0)
        #expect(!model.reorder(original, expected: original, context: context))
        #expect(!model.reorder(original, expected: model.inputs.order, context: "another-synthetic-owner"))
        #expect(await model.save()); #expect(store.saves == 1 && !model.dirty)
        #expect(!model.reorder(original, expected: model.inputs.order, context: context))
        #expect(model.inputs.hidden == ["synthetic-first"])
        model.retire(); #expect(!model.reorder(original, expected: model.inputs.order, context: model.reorderContext))
    }

    @Test func laterEditsRemainAfterAnEarlierPhysicalSave() async throws {
        let store = Catalog(catalog()), gate = Gate()
        let model = MediaLayoutEditor(scope: scope, key: store.value.key, read: { store.read() }, save: { inputs, expected in await gate.hold(); return try store.save(inputs, expected: expected) })
        await model.load(); model.inputs.hidden.insert("synthetic-first")
        let operation = Task { await model.save() }; try await gate.wait(); defer { gate.release() }
        model.inputs.hidden.insert("synthetic-second"); gate.release(); #expect(await operation.value)
        #expect(model.dirty && model.inputs.hidden.count == 2 && model.draft?.inputs.hidden == ["synthetic-first"] && store.saves == 1)
    }

    @Test func retiringAnOwnerAcknowledgesItsWriteWithoutChangingItsEditor() async throws {
        let store = Catalog(catalog()), gate = Gate()
        let model = MediaLayoutEditor(scope: scope, key: store.value.key, read: { store.read() }, save: { inputs, expected in await gate.hold(); return try store.save(inputs, expected: expected) })
        await model.load(); model.inputs.hidden.insert("synthetic-first")
        let baseline = model.draft?.signature, operation = Task { await model.save() }
        try await gate.wait(); defer { gate.release() }; model.retire(); gate.release()
        #expect(await operation.value); #expect(store.saves == 1 && !model.active && !model.busy && model.draft?.signature == baseline)
        #expect(!(await model.save()))
    }

    @Test func staleSavesRequireAnExplicitComparedBaseline() async throws {
        let store = Catalog(catalog()), model = editor(store)
        await model.load(); let baseline = model.draft?.signature
        model.inputs.hidden.insert("synthetic-first"); store.value = catalog(["synthetic-second", "synthetic-first"])
        #expect(!(await model.save())); #expect(model.dirty && model.autosave.phase == .paused)
        await model.readLatest(); #expect(model.draft?.signature == baseline && model.inputs.order.first == "synthetic-first" && model.latest != nil)
        model.acceptLatest(keepEdits: true)
        #expect(model.dirty && model.inputs.hidden == ["synthetic-first"] && model.autosave.phase == .paused && store.saves == 1)
        #expect(await model.save()); #expect(!model.dirty && store.saves == 2)
    }

    @Test func confirmedAdditionsAdvanceOnlyMatchingCleanOwnedCatalogs() async {
        let original = catalog(), added = catalog(["synthetic-first", "synthetic-second", "synthetic-added"])
        let clean = editor(Catalog(original)); await clean.load()
        #expect(clean.reconcile(.init(before: original, after: added), scope: scope)); #expect(!clean.dirty && clean.inputs.order.count == 3)
        let dirty = editor(Catalog(original)); await dirty.load(); dirty.inputs.hidden.insert("synthetic-first")
        #expect(!dirty.reconcile(.init(before: original, after: added), scope: scope))
        #expect(dirty.needsComparison && dirty.state.blocked && dirty.inputs.order.count == 2 && dirty.inputs.hidden == ["synthetic-first"])
        dirty.revert(); #expect(dirty.needsComparison && dirty.state.blocked)
        let stale = editor(Catalog(original)); await stale.load()
        #expect(!stale.reconcile(.init(before: catalog(["synthetic-second", "synthetic-first"]), after: added), scope: scope)); #expect(stale.needsComparison)
        let foreign = editor(Catalog(original)); await foreign.load()
        #expect(!foreign.reconcile(.init(before: original, after: added), scope: .init(accountId: "synthetic-other-account", appId: scope.appId, revisionId: scope.revisionId)))
        #expect(!foreign.needsComparison && foreign.inputs.order.count == 2)
    }

    @Test func acceptingLatestCanRecoverAnUnreadBaselineWithoutWriting() async {
        let original = catalog(); var failRead = true, writes = 0
        let model = MediaLayoutEditor(scope: scope, key: original.key, read: { if failRead { throw SyntheticFailure.save }; return original }, save: { _, _ in writes += 1; return original })
        await model.load(); #expect(model.state.blocked && model.draft == nil)
        failRead = false; await model.readLatest(); #expect(model.draft == nil && model.latest != nil)
        model.acceptLatest(keepEdits: false); #expect(!model.state.blocked && !model.dirty && writes == 0)
    }

    @Test func invalidPosterTimesBlockPreparationBeforeWriting() async {
        let item = PreviewSetDraft.Item(id: "synthetic-video", fileName: "synthetic.mp4", sha256: String(repeating: "0", count: 64), ext: "mp4", width: 886, height: 1920, duration: 20)
        let inputs = MediaDraftInputs(order: [item.id], hidden: [], posterTimes: [item.id: 5])
        let original = MediaLayoutDraft.previews(localizationId: "synthetic-language", type: "IPHONE_67", draft: .init(items: [item], hidden: [], posterTimes: inputs.posterTimes, signature: inputs.signature))
        var writes = 0
        let model = MediaLayoutEditor(scope: scope, key: original.key, draft: original, read: { original }, save: { _, _ in writes += 1; return original })
        for invalid in [-1, 20, .infinity, .nan] {
            model.inputs.posterTimes[item.id] = invalid
            let saved = await model.save()
            #expect(model.state.blocked && model.problem != nil && !saved)
        }
        #expect(writes == 0)
    }
}
