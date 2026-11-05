import Foundation
import Testing
@testable import StorebenchCore

@Suite struct KeywordBulkTests {
    init() throws { _ = try TestIsolation.require() }
    @Test func combinationsAndSelectedIdeasMatchSyntheticReferenceResults() throws {
        let file = try TestIsolation.require().appendingPathComponent("native-fixtures/keyword-bulk.json"), vector = try JSONText.parse(Data(contentsOf: file))
        let notebook = try Keywords.decode(try #require(vector["notebook"])), terms = try #require(vector["terms"]?.text)
        var counter = 0
        let preview = try Keywords.previewBulk(notebook, terms: terms, locale: "en-US", territories: WorkspaceSession.strings(vector["territories"])) {
            defer { counter += 1 }; return String(format: "00000000-0000-4000-8000-%012d", counter)
        }
        let rows = preview.rows.map { row in JSONText.object([("key", .string(row.id)), ("candidate", row.candidate.json), ("duplicate", row.duplicate.map { .string($0.rawValue) } ?? .null)]) }
        #expect(JSONText.array(rows) == vector["preview"]?["rows"])
        #expect(vector["preview"]?["available"] == .number(Double(preview.available)))
        #expect(try Keywords.applyBulk(notebook, preview: preview, selected: WorkspaceSession.strings(vector["selected"])).json == vector["applied"])
        #expect(try Keywords.importText(Keywords.json(notebook), accountId: notebook.accountId, appId: notebook.appId) == notebook)
    }

    @Test func combinationsRejectDuplicatesLimitsAndInvalidSelections() throws {
        let notebook = KeywordNotebook(accountId: "synthetic-account", appId: "1000000001")
        let preview = try Keywords.previewBulk(notebook, terms: "synthetic, SYNTHETIC", locale: "en-US", territories: ["USA"])
        #expect(preview.rows[1].duplicate == .input)
        #expect(throws: KeywordFailure.format) { try Keywords.applyBulk(notebook, preview: preview, selected: ["1"]) }
        #expect(throws: KeywordFailure.format) { try Keywords.applyBulk(notebook, preview: preview, selected: ["missing"]) }
        #expect(throws: KeywordFailure.format) { try Keywords.applyBulk(notebook, preview: preview, selected: []) }
        #expect(throws: KeywordFailure.format) { try Keywords.previewBulk(notebook, terms: "synthetic", locale: "en-US", territories: []) }
        #expect(throws: KeywordFailure.format) { try Keywords.previewBulk(notebook, terms: "synthetic", locale: "xx", territories: ["USA"]) }
        #expect(throws: KeywordFailure.format) { try Keywords.previewBulk(notebook, terms: String(repeating: "🎉", count: 40_001), locale: "en-US", territories: ["USA"]) }
        #expect(throws: KeywordFailure.limit) { try Keywords.previewBulk(notebook, terms: (0..<2001).map { "Synthetic \($0)" }.joined(separator: ","), locale: "en-US", territories: ["USA", "SWE"]) }
        let tooMany = try Keywords.previewBulk(notebook, terms: (0..<2001).map { "Synthetic \($0)" }.joined(separator: ","), locale: "en-US", territories: ["USA"])
        #expect(throws: KeywordFailure.limit) { try Keywords.applyBulk(notebook, preview: tooMany, selected: tooMany.rows.map(\.id)) }
    }
}
