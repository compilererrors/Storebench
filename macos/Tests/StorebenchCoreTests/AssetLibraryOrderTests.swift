import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) @MainActor struct AssetLibraryOrderTests {
    init() throws { _ = try TestIsolation.require() }
    private func scope(_ account: String, target: String = "synthetic-target", group: String = "SYNTHETIC_GROUP") throws -> AssetLibrary.OrderScope {
        try .init(accountId: account, appId: "1000000001", surface: .versions, targetId: target, group: group)
    }
    private func placements() throws -> [AssetLibrary.Placement] {
        try ["one", "two", "three"].map { id in
            let json = """
            {"type":"appAssetLibraryPlacements","id":"synthetic-\(id)","attributes":{"mediaType":"IMAGE","placementType":"PRODUCT_PAGE_HEADER_ASSET","placementGroup":"SYNTHETIC_GROUP","state":"READY"},"relationships":{"image":{"data":{"type":"appAssetLibraryImages","id":"synthetic-asset-\(id)"}}}}
            """
            return try AssetLibrary.Placement(JSONDecoder().decode(AppStoreConnectClient.Resource.self, from: Data(json.utf8)))
        }
    }
    @Test func localOrderSurvivesReopeningAndStaleWindowsCannotOverwriteIt() async throws {
        let (first, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let second = try WorkspaceSession(workspace: Workspace(root: root), vault: await first.vault)
        let account = try #require(try await first.accounts().first), scope = try scope(account.id), placements = try placements(), ids = placements.map(\.id)
        let store = try EncryptedDocumentStore(url: EncryptedDocumentStore.databaseURL(root: root), key: Data(0..<32), writable: true)
        let originalDrafts = try store.documents(namespace: "drafts"), beforeMedia = try store.documents(namespace: "asset_library_files")
        #expect(try await first.assetLibraryOrder(scope) == nil)
        let saved = try await first.saveAssetLibraryOrder(scope, baseline: ids, baselineDigest: AssetLibrary.orderDigest(placements), order: Array(ids.reversed()), expectedRevision: nil)
        #expect(try await second.assetLibraryOrder(scope) == saved && saved.revision == 1)
        await #expect(throws: (any Error).self) { try await second.saveAssetLibraryOrder(scope, baseline: ids, baselineDigest: AssetLibrary.orderDigest(placements), order: ids, expectedRevision: nil) }
        #expect(try await second.assetLibraryOrder(scope) == saved)
        let updated = try await second.saveAssetLibraryOrder(scope, baseline: ids, baselineDigest: AssetLibrary.orderDigest(placements), order: [ids[1], ids[0], ids[2]], expectedRevision: saved.revision)
        #expect(updated.revision == 2)
        await #expect(throws: (any Error).self) { try await first.saveAssetLibraryOrder(scope, baseline: ids, baselineDigest: AssetLibrary.orderDigest(placements), order: ids, expectedRevision: saved.revision) }
        #expect(try await first.assetLibraryOrder(scope) == updated)
        #expect(try await first.assetLibraryOrder(self.scope(account.id, target: "another-synthetic-target")) == nil)
        #expect(try store.documents(namespace: "drafts") == originalDrafts && store.documents(namespace: "asset_library_files") == beforeMedia)
        let editor = try AssetLibraryOrderEditor(scope: scope, placements: placements, saved: updated)
        #expect(!editor.dirty && editor.pendingUpload && editor.canReview)
    }
    @Test func reorderSaveReviewAndConcurrentBaselineChoicesRemainSeparate() async throws {
        let group = try placements(), scope = try scope("synthetic-account"), ids = group.map(\.id), digest = AssetLibrary.orderDigest(group)
        let editor = try AssetLibraryOrderEditor(scope: scope, placements: group, saved: nil)
        #expect(editor.reorder(Array(ids.reversed()), expected: ids, context: editor.context))
        #expect(editor.dirty && editor.pendingUpload && !editor.canReview)
        #expect(!editor.reorder(ids, expected: ids, context: editor.context))
        #expect(await editor.save { _ in try .init(revision: 1, baseline: ids, baselineDigest: digest, order: Array(ids.reversed())) })
        #expect(!editor.dirty && editor.canReview)
        let latest = try AssetLibrary.OrderDraft(revision: 2, baseline: ids, baselineDigest: digest, order: [ids[1], ids[0], ids[2]])
        await editor.readLatest { latest }
        #expect(editor.saved?.revision == 1 && editor.order == Array(ids.reversed()))
        editor.acceptLocalLatest(keepEdits: true)
        #expect(editor.saved?.revision == 2 && editor.dirty && !editor.canReview)
        editor.retire(); #expect(!editor.reorder(ids, expected: editor.order, context: editor.context))
    }
    @Test func simultaneousEditorsSaveOneRevisionAndNeverLoseTheWinningOrder() async throws {
        let (first, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let second = try WorkspaceSession(workspace: Workspace(root: root), vault: await first.vault), account = try #require(try await first.accounts().first)
        let group = try placements(), scope = try scope(account.id), ids = group.map(\.id), digest = AssetLibrary.orderDigest(group)
        let successes = await withTaskGroup(of: Bool.self) { tasks in
            for (session, order) in [(first, Array(ids.reversed())), (second, [ids[1], ids[0], ids[2]])] {
                tasks.addTask { do { _ = try await session.saveAssetLibraryOrder(scope, baseline: ids, baselineDigest: digest, order: order, expectedRevision: nil); return true } catch { return false } }
            }
            var count = 0; for await success in tasks { if success { count += 1 } }; return count
        }
        #expect(successes == 1)
        let saved = try #require(try await first.assetLibraryOrder(scope)); #expect(saved.revision == 1 && saved.order != ids)
        #expect(try await second.assetLibraryOrder(scope) == saved)
    }
    @Test func changedAppleMembershipRequiresAComparisonAndDoesNotEraseTheSavedDraft() throws {
        let group = try placements(), scope = try scope("synthetic-account"), ids = group.map(\.id)
        let saved = try AssetLibrary.OrderDraft(revision: 1, baseline: ids, baselineDigest: AssetLibrary.orderDigest(group), order: Array(ids.reversed()))
        let editor = try AssetLibraryOrderEditor(scope: scope, placements: Array(group.prefix(2)), saved: saved)
        #expect(editor.needsComparison && editor.blocked && editor.order == saved.order && !editor.canReview)
        editor.acceptLatest(keepEdits: true)
        #expect(editor.order == [ids[1], ids[0]] && editor.dirty && !editor.canReview && editor.saved == saved)
        #expect(throws: (any Error).self) { try AssetLibrary.OrderDraft(revision: 1, baseline: ids, baselineDigest: "invalid", order: ids) }
        #expect(throws: (any Error).self) { try AssetLibrary.OrderDraft(revision: 1, baseline: ids, baselineDigest: AssetLibrary.orderDigest(group), order: [ids[0], ids[0], ids[1]]) }
    }
    @Test func keepingAnUnchangedLocalOrderStillRequiresSavingTheComparedAppleBaseline() async throws {
        let group = try placements(), scope = try scope("synthetic-account"), ids = group.map(\.id)
        let saved = try AssetLibrary.OrderDraft(revision: 1, baseline: ids, baselineDigest: AssetLibrary.orderDigest(group), order: Array(ids.reversed()))
        let current = [group[1], group[2], group[0]], editor = try AssetLibraryOrderEditor(scope: scope, placements: current, saved: saved)
        #expect(editor.needsComparison && !editor.canReview)
        editor.acceptLatest(keepEdits: true)
        #expect(editor.order == saved.order && editor.dirty && !editor.canReview)
        let didSave = await editor.save { before in
            #expect(before == saved)
            return try .init(revision: 2, baseline: current.map(\.id), baselineDigest: AssetLibrary.orderDigest(current), order: saved.order)
        }
        #expect(didSave)
        #expect(!editor.dirty && editor.canReview)
        let reopened = try AssetLibraryOrderEditor(scope: scope, placements: current, saved: editor.saved)
        #expect(!reopened.needsComparison && reopened.order == saved.order && reopened.canReview)
    }
    @Test func failedSavesAndFailedLatestReadsNeverReplaceUnsavedInput() async throws {
        let group = try placements(), editor = try AssetLibraryOrderEditor(scope: scope("synthetic-account"), placements: group, saved: nil)
        let edited = Array(editor.order.reversed())
        #expect(editor.reorder(edited, expected: editor.order, context: editor.context))
        #expect(await editor.save { _ in throw AssetLibrary.failure("Synthetic unavailable storage.") } == false)
        #expect(editor.order == edited && editor.dirty && editor.localConflict && !editor.canReview)
        await editor.readLatest { throw AssetLibrary.failure("Synthetic failed read.") }
        editor.acceptLocalLatest(keepEdits: false)
        #expect(editor.order == edited && editor.localConflict && !editor.latestRead)
        await editor.readLatest { nil }; editor.acceptLocalLatest(keepEdits: true)
        #expect(editor.order == edited && editor.dirty && !editor.localConflict)
    }
}
