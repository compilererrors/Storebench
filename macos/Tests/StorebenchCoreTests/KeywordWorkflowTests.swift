import Foundation
import Testing
@testable import StorebenchCore

@Suite struct KeywordWorkflowTests {
    init() throws { _ = try TestIsolation.require() }
    private func fixture() throws -> JSONText { try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/keyword-workflow.json"))) }
    private func rows(_ value: JSONText?) throws -> [JSONText] { guard case .array(let rows)? = value else { throw KeywordFailure.format }; return rows }
    private func notebook(_ key: String) throws -> KeywordNotebook { try Keywords.fromJSON(#require(fixture()[key])) }
    private func ids(_ value: JSONText?) throws -> [String] { try rows(value).map { try #require($0.text) } }

    @Test func filteringStableSortingAndPagesMatchPrimaryHelpers() throws {
        let fixture = try fixture(), notebook = try notebook("notebook")
        for row in try rows(fixture["filters"]) {
            let f = try #require(row["filters"]), filters = Keywords.Filters(query: f["query"]?.text ?? "", locale: f["locale"]?.text ?? "", territory: f["territory"]?.text ?? "", status: f["status"]?.text ?? "", source: f["source"]?.text ?? "")
            #expect(Keywords.filtered(notebook.items, filters).map(\.id) == (try ids(row["expected"])))
        }
        let filtered = Keywords.filtered(notebook.items, .init())
        for row in try rows(fixture["sorts"]) {
            let ordered = Keywords.ordered(filtered, key: row["key"]?.text ?? "", descending: row["direction"] == .string("descending"), picker: row["picker"] == .bool(true))
            #expect(ordered.map(\.id) == (try ids(row["expected"])), "Column \(row["key"]?.text ?? "default")")
            let last = Keywords.Page(ordered, requested: 999, size: 8)
            #expect(last.rows.map(\.id) == Array(ordered.suffix(ordered.count % 8 == 0 ? 8 : ordered.count % 8)).map(\.id))
        }
        #expect(Keywords.Page([], requested: -1, size: 0).number == 1)
    }

    @Test func listingChoicesAndDuplicateReviewsMatchPrimaryByteContracts() throws {
        let fixture = try fixture(), notebook = try notebook("notebook"), scope = try RecoveryGuidance.Scope(accountId: notebook.accountId, appId: notebook.appId)
        let compositions = try rows(fixture["compositions"]); #expect(compositions.count == 180)
        for row in compositions {
            let picker = try KeywordPickerSnapshot(notebook: notebook, scope: scope, locale: #require(row["locale"]?.text))
            let choice = try picker.selection(current: #require(row["current"]?.text), selected: Set(ids(row["selected"])), mode: #require(KeywordListingSelection.Mode(rawValue: row["mode"]?.text ?? "")))
            #expect(choice.json == row["expected"])
        }
        for row in try rows(fixture["reviews"]) { #expect(Keywords.reviewText(try #require(row["text"]?.text)).json == row["expected"]) }
        for row in try rows(fixture["selections"]) {
            let items = try Keywords.fromJSON(.object([("schemaVersion", .number(1)), ("accountId", .string(scope.accountId)), ("appId", .string(scope.appId)), ("items", #require(row["items"]))])).items
            #expect(Keywords.selection(items).json == row["expected"])
        }
        let foreign = try RecoveryGuidance.Scope(accountId: "synthetic-other", appId: notebook.appId)
        #expect(throws: KeywordFailure.scope) { try KeywordPickerSnapshot(notebook: notebook, scope: foreign, locale: "en-US") }
        #expect(throws: KeywordFailure.scope) { try KeywordPickerSnapshot(notebook: notebook, scope: scope, locale: "unsupported") }
        for row in try rows(fixture["invalidNotebooks"]) {
            #expect(row["code"] == .string("SB-KEYWORDS-FORMAT"))
            #expect(throws: KeywordFailure.format) { try Keywords.fromJSON(#require(row["input"])) }
        }
    }

    @Test func reviewIsBoundToExactInputsAndLatestReadDoesNotAdoptOrSave() throws {
        let fixture = try fixture(), before = try notebook("baseline"), after = try notebook("after"), revision = try #require(fixture["revision"]?.text)
        var editor = try KeywordNotebookEditor(notebook: before, revision: revision)
        try editor.change(after); try editor.prepareReview()
        #expect(editor.review?.fingerprint == fixture["fingerprint"]?.text)
        #expect(JSONText.array(editor.changes.map(\.json)) == fixture["differences"])
        let reviewed = try editor.reviewedSave(); #expect(reviewed.revision == revision)
        #expect(throws: KeywordFailure.storage) { try editor.confirmedSave(revision) }
        #expect(throws: KeywordFailure.stale) { try editor.prepareReview(currentRevision: String(repeating: "a", count: 64)) }
        #expect(editor.values.inputs == after && editor.values.baseline.revision == revision && editor.review == nil)
        try editor.prepareReview(currentRevision: revision)
        try editor.compare(notebook: before, revision: revision)
        #expect(editor.values.baseline.value == before && editor.values.inputs == after && editor.dirty)
        #expect(throws: KeywordFailure.stale) { try editor.reviewedSave() }
        editor.acceptLatest(useSaved: false); #expect(editor.values.inputs == after && editor.dirty)
        try editor.prepareReview(); try editor.confirmedSave(try #require(fixture["fingerprint"]?.text)); #expect(!editor.dirty && editor.review == nil)
        try editor.change(before); try editor.compare(notebook: after, revision: Keywords.revision(after)); editor.acceptLatest(useSaved: true)
        #expect(editor.values.inputs == after && !editor.dirty && editor.review == nil)
        try editor.change(before); try editor.prepareReview(); editor.discardComparison()
        #expect(editor.values.inputs == before && editor.values.comparison == nil && editor.review == nil)
        editor.discard(); #expect(!editor.dirty)
        var unicode = before; unicode.items[0].notes = "é"; try editor.change(unicode); try editor.prepareReview()
        unicode.items[0].notes = "e\u{301}"; try editor.change(unicode); #expect(editor.review == nil)
        #expect(throws: KeywordFailure.stale) { try editor.reviewedSave() }
    }

    @Test func eachChangeIsReadyToSaveInOneStepAndAStaleSaveKeepsTheEdits() throws {
        let fixture = try fixture(), before = try notebook("baseline"), after = try notebook("after"), revision = try #require(fixture["revision"]?.text)
        var editor = try KeywordNotebookEditor(notebook: before, revision: revision)
        try editor.change(after)
        #expect(throws: KeywordFailure.stale) { try editor.prepareSave(currentRevision: String(repeating: "b", count: 64)) }
        #expect(editor.values.inputs == after && editor.dirty && editor.review == nil)
        let ready = try editor.prepareSave(currentRevision: revision)
        #expect(ready.fingerprint == fixture["fingerprint"]?.text && ready.revision == revision && !ready.changes.isEmpty)
        try editor.confirmedSave(ready.fingerprint); #expect(!editor.dirty && editor.values.baseline.value == after)
        #expect(throws: KeywordFailure.limit) { try editor.prepareSave(currentRevision: ready.fingerprint) }
    }

    @Test func selectionChangesEveryChosenRowAcrossFiltersAndRejectsForeignScope() throws {
        let before = try notebook("baseline"); var editor = try KeywordNotebookEditor(notebook: before, revision: Keywords.revision(before))
        let chosen = Set([before.items[0].id, before.items[13].id])
        try editor.selectedStatus(chosen, status: "rejected")
        #expect(editor.values.inputs.items.filter { chosen.contains($0.id) }.allSatisfy { $0.status == "rejected" })
        #expect(editor.changes.count == 2)
        try editor.removeSelected(chosen); #expect(editor.values.inputs.items.count == 12)
        let retained = editor.values.inputs
        #expect(throws: KeywordFailure.scope) { try editor.change(KeywordNotebook(accountId: "synthetic-other", appId: before.appId)) }
        #expect(editor.values.inputs == retained)
        #expect(throws: KeywordFailure.format) { try editor.selectedStatus(chosen, status: "measured") }
        #expect(throws: KeywordFailure.storage) { try KeywordNotebookEditor(notebook: before, revision: "invalid") }
    }

    @Test func concurrentReviewedSavesKeepTheLosingEditorsOriginalBaseline() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let other = try WorkspaceSession(workspace: Workspace(root: root), vault: await session.vault)
        let loaded = try await session.keywordNotebook(accountId: "synthetic-account", appId: "1000000001")
        var first = try KeywordNotebookEditor(notebook: loaded.notebook, revision: loaded.revision), second = first
        try first.change(notebook("baseline")); try first.prepareReview()
        try second.change(notebook("after")); try second.prepareReview()
        let left = try first.reviewedSave(), right = try second.reviewedSave()
        let results = try await withThrowingTaskGroup(of: (Int, String?).self) { group in
            group.addTask { do { return (0, try await session.saveReviewedKeywordNotebook(left)) } catch KeywordFailure.stale { return (0, nil) } }
            group.addTask { do { return (1, try await other.saveReviewedKeywordNotebook(right)) } catch KeywordFailure.stale { return (1, nil) } }
            var values: [(Int, String?)] = []; for try await value in group { values.append(value) }; return values
        }
        #expect(results.filter { $0.1 != nil }.count == 1)
        let latest = try await session.keywordNotebook(accountId: loaded.notebook.accountId, appId: loaded.notebook.appId)
        var losing = results.first { $0.1 == nil }?.0 == 0 ? first : second
        let inputs = losing.values.inputs
        #expect(losing.values.baseline.revision == loaded.revision && losing.dirty)
        try losing.compare(notebook: latest.notebook, revision: latest.revision)
        #expect(losing.values.inputs == inputs && losing.values.baseline.revision == loaded.revision)
        #expect(try await other.keywordNotebook(accountId: loaded.notebook.accountId, appId: loaded.notebook.appId).revision == latest.revision)
        losing.acceptLatest(useSaved: false); try losing.prepareReview()
        let saved = try await session.saveReviewedKeywordNotebook(losing.reviewedSave()); try losing.confirmedSave(saved)
        #expect(!losing.dirty && losing.values.inputs == inputs)
    }

    @Test func fileCodecsReuseSavedCsvIdentitiesAndRejectCorruptOrForeignImports() throws {
        let fixture = try fixture(), saved = try notebook("baseline")
        for row in try rows(fixture["codecs"]) {
            let encoded = try #require(row["bytes"]?.text), data = try #require(Data(base64Encoded: encoded))
            if row["invalid"] == .bool(true) { #expect(throws: KeywordFailure.format) { try KeywordFiles.parse(data, accountId: saved.accountId, appId: saved.appId, saved: saved) } }
            else { #expect(try KeywordFiles.parse(data, accountId: saved.accountId, appId: saved.appId, saved: saved).json == row["expected"]) }
        }
        #expect(throws: KeywordFailure.scope) { try KeywordFiles.parse(saved.json.data, accountId: "synthetic-other", appId: saved.appId, saved: saved) }
        var table = try Delimited.parse(Keywords.csv(saved)); table.rows.append(table.rows[0]); let duplicate = Delimited.write(table)
        #expect(throws: KeywordFailure.duplicate) { try Keywords.importText(duplicate, accountId: saved.accountId, appId: saved.appId, saved: saved) }
    }

    @Test func keywordFileLimitsActualReadsAndAtomicExportsPreserveExistingDestinations() async throws {
        let root = try TestIsolation.require().appendingPathComponent("synthetic-keywords-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("synthetic.csv"), link = root.appendingPathComponent("synthetic-link.csv"), before = Data("Synthetic existing destination".utf8), saved = try notebook("baseline")
        try before.write(to: file); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: ReportFiles.Failure.read) { try ReportFiles.read([link], purpose: .keywords) }
        #expect(throws: ReportFiles.Failure.format) { try ReportFiles.texts([before, before], purpose: .keywords) }
        #expect(try ReportFiles.texts([Data(repeating: 65, count: 8_100_000)], purpose: .keywords).first?.utf8.count == 8_100_000)
        let over = Data(repeating: 65, count: 10_000_001)
        #expect(throws: ReportFiles.Failure.size) { try ReportFiles.texts([Data(repeating: 65, count: 8_100_001)], purpose: .keywords) }
        #expect(throws: ReportFiles.Failure.size) { try ReportFiles.texts([ReportFiles.gzip(over)], purpose: .keywords) }
        try over.write(to: file); #expect(throws: ReportFiles.Failure.size) { try ReportFiles.read([file], purpose: .keywords) }
        try before.write(to: file)
        let cancelled = Task { withUnsafeCurrentTask { $0?.cancel() }; try KeywordFiles.export(saved, json: true, to: file) }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try Data(contentsOf: file) == before)
        try KeywordFiles.export(saved, json: false, to: file)
        #expect(try Keywords.importText(String(decoding: Data(contentsOf: file), as: UTF8.self), accountId: saved.accountId, appId: saved.appId) == saved)
        #expect(throws: ReportFiles.Failure.write) { try KeywordFiles.export(saved, json: true, to: link) }
        let huge = KeywordNotebook(accountId: saved.accountId, appId: saved.appId, items: (0..<2000).map { KeywordIdea(id: String(format: "00000000-0000-4000-8000-%012d", $0), term: "Synthetic \($0)", locale: "en-US", notes: String(repeating: "🎉", count: 1000)) })
        var editor = try KeywordNotebookEditor(notebook: saved, revision: Keywords.revision(saved))
        #expect(throws: KeywordFailure.limit) { try editor.change(huge) }
        #expect(!editor.dirty && editor.values.inputs == saved)
    }
}
