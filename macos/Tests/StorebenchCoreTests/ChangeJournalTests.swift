import Foundation
import Testing
@testable import StorebenchCore

struct ChangeJournalTests {
    init() throws { _ = try TestIsolation.require() }
    /// The same synthetic listings give the frozen entry IDs and bases, so saved notes stay attached.
    @Test func journalEntriesMatchSyntheticReferenceResults() throws {
        let data = try Data(contentsOf: try #require(Bundle.module.url(forResource: "synthetic-journal", withExtension: "json", subdirectory: nil)))
        let input = try JSONText.parse(data)
        let revisions = try WorkspaceSession.items(input["revisions"]).map { try JSONDecoder().decode(Revision.self, from: $0.data) }
        let draft = try #require(input["draft"])
        let changes = ASO.draftChanges(revisions[1], draft: draft)
        #expect(changes.map(\.field) == ["keywords", "screenshots · APP_IPHONE_67"])
        let events = try WorkspaceSession.journalEvents(accountId: "synthetic-account", appId: "1000000001", revisions: revisions, drafts: [(revisions[1].id, changes)], plan: nil, reviews: [])
        #expect(events.map(\.id) == ["import:22222222-2222-4222-8222-222222222222:25bb6cf87ad491d6521a5ff63d7dda65", "import:11111111-1111-4111-8111-111111111111:25bb6cf87ad491d6521a5ff63d7dda65",
                                     "draft:22222222-2222-4222-8222-222222222222"])
        #expect(events.map(\.basis) == ["7e20e4c8954e33c1ec3aef821aa242e3e2230c720375970d02daa0f5cdaf7cbd", "3927430409531b8fd6f8c7e16ebdb585238c951533eda6669b7068b13519992b",
                                        "992f0318e4887149dc359d847c06bc20ae0852c095c01a73a95d6a2181fd4193"])
        #expect(events.map(\.changes.count) == [2, 5, 2] && events.allSatisfy { $0.locales == ["en-US"] })
    }

    @Test func notesAreSavedOnlyOntoTheLoadedEntryAndRevision() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), app = try #require(account.appIds.first)
        let events = try await session.changeJournal(accountId: account.id, appId: app)
        let event = try #require(events.first)
        #expect(try await session.journalNote(accountId: account.id, appId: app, eventId: event.id).revision == 0)
        var note = JournalNote(eventId: event.id, basis: event.basis, attribution: "storebench", intent: "Clearer subtitle", primaryMetric: "views")
        let saved = try await session.saveJournalNote(accountId: account.id, appId: app, note: note, expected: 0)
        #expect(try await session.journalNote(accountId: account.id, appId: app, eventId: event.id).note?.intent == "Clearer subtitle")
        await #expect(throws: JournalFailure.stale) { try await session.saveJournalNote(accountId: account.id, appId: app, note: note, expected: 0) }
        note.basis = String(repeating: "0", count: 64)
        await #expect(throws: JournalFailure.stale) { try await session.saveJournalNote(accountId: account.id, appId: app, note: note, expected: saved.revision) }
        note.basis = event.basis; note.conclusion = String(repeating: "x", count: 1001)
        await #expect(throws: JournalFailure.invalid) { try await session.saveJournalNote(accountId: account.id, appId: app, note: note, expected: saved.revision) }
    }
}
