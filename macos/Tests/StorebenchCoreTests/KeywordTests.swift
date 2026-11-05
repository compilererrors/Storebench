import Foundation
import Testing
@testable import StorebenchCore

struct KeywordTests {
    init() throws { _ = try TestIsolation.require() }
    static let notebook = KeywordNotebook(accountId: "synthetic-account", appId: "1000000001", items: [
        KeywordIdea(id: "b0000000-0000-4000-8000-000000000002", term: "  note   taking ", locale: "en-US", territory: "USA", status: "ready", source: "research", reference: "=SUM(A1)", observedOn: "2026-05-01", notes: "Line one\nline \"two\""),
        KeywordIdea(id: "a0000000-0000-4000-8000-000000000001", term: "anteckningar", locale: "sv")])

    @Test func revisionCSVAndImportedIdsMatchSyntheticReferenceResults() throws {
        let notebook = try Keywords.normalize(Self.notebook)
        #expect(Keywords.revision(notebook) == "c5acc62a39683eb6a053bfa6f98d1c3345bbdf48298fe8b9c4770be41e572891" && Keywords.revision(nil) == "74234e98afe7498fb5daf1f36ac2d78acc339464f950703b8c019892f982b90b")
        let csv = Keywords.csv(notebook)
        #expect(csv == "account_id,app_id,keyword_id,term,locale,territory,status,source,reference,observed_on,notes\r\nsynthetic-account,1000000001,a0000000-0000-4000-8000-000000000001,anteckningar,sv,,idea,manual,,,\r\nsynthetic-account,1000000001,b0000000-0000-4000-8000-000000000002,note taking,en-US,USA,ready,research,'=SUM(A1),2026-05-01,\"Line one\nline \"\"two\"\"\"\r\n")
        #expect(try Keywords.importText(csv, accountId: "synthetic-account", appId: "1000000001") == notebook)
        #expect(Keywords.importedId("synthetic-account", "1000000001", KeywordIdea(id: "", term: "Planner", locale: "de-DE", territory: "DEU").identity) == "595f57a7-63c9-8aa2-b6bc-960101193456")
        #expect(throws: KeywordFailure.scope) { try Keywords.importText(csv, accountId: "other-account", appId: "1000000001") }
        var duplicate = notebook; duplicate.items.append(KeywordIdea(term: "Note Taking", locale: "en-US", territory: "USA"))
        #expect(throws: KeywordFailure.duplicate) { try Keywords.normalize(duplicate) }
        #expect(Keywords.keywordField(notebook.items + [KeywordIdea(term: "Anteckningar", locale: "sv")]) == "anteckningar,note taking")
    }

    @Test func notebooksAreSavedOnlyOntoTheLoadedRevision() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let loaded = try await session.keywordNotebook(accountId: "synthetic-account", appId: "1000000001")
        #expect(loaded.notebook.items.isEmpty)
        let revision = try await session.saveKeywordNotebook(Self.notebook, revision: loaded.revision)
        #expect(try await session.keywordNotebook(accountId: "synthetic-account", appId: "1000000001").notebook.items.map(\.term) == ["anteckningar", "note taking"])
        await #expect(throws: KeywordFailure.stale) { try await session.saveKeywordNotebook(Self.notebook, revision: loaded.revision) }
        #expect(try await session.saveKeywordNotebook(Self.notebook, revision: revision) == revision)
    }
}
