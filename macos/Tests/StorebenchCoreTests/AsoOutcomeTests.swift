import Foundation
import Testing
@testable import StorebenchCore

@Suite struct AsoOutcomeTests {
    init() throws { _ = try TestIsolation.require() }
    func golden() throws -> JSONText { try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/aso-outcome.json"))) }
    func items(_ value: JSONText?) throws -> [JSONText] { guard case .array(let values)? = value else { throw AsoOutcome.Failure.malformed }; return values }
    func input(_ value: JSONText) throws -> (JournalEvent, [JournalEvent], [AnalyticsPeriod], [SalesPresentation.Period]) {
        let decoder = JSONDecoder(), event = try decoder.decode(JournalEvent.self, from: value["selected"]!.data)
        let events = try decoder.decode([JournalEvent].self, from: value["events"]!.data), analytics = try decoder.decode([AnalyticsPeriod].self, from: value["analytics"]!.data)
        let records = try decoder.decode([SalesRecord].self, from: value["records"]!.data)
        let sales = try records.flatMap { try SalesPresentation.prepare([$0], accountId: "synthetic-account", appId: "1000000001") }
        return (event, events, analytics, sales)
    }
    func analyze(_ value: JSONText, choice: JSONText) throws -> AsoOutcome.Review {
        let (event, events, analytics, sales) = try input(value)
        let days: Int = if case .number(let value)? = choice["days"] { Int(value) } else { 7 }
        return try AsoOutcome.analyze(event, events: events, analytics: analytics, sales: sales, metric: choice["metric"]?.text ?? "views", days: days, territory: choice["territory"]?.text ?? "", comparison: choice["comparisonTerritory"]?.text ?? "")
    }
    @Test func exactWindowsSourcesReasonsTerritoriesAndEvidenceMatchEveryWebCase() throws {
        let fixture = try golden(), datasets = try items(fixture["datasets"]), cases = try items(fixture["cases"])
        #expect(cases.count >= 100)
        var invalid = 0
        for vector in cases {
            let dataset = try #require(datasets.first { $0["id"] == vector["dataset"] }), choice = vector["choice"]!
            if vector["invalid"] == .bool(true) { #expect(throws: (any Error).self) { try analyze(dataset, choice: choice) }; invalid += 1; continue }
            let review = try analyze(dataset, choice: choice), parsed = try input(dataset)
            #expect(review.json.data == vector["expected"]?.data, "Synthetic outcome: \(vector["dataset"]!.text!) / \(choice)")
            #expect(review.evidenceFingerprint(for: parsed.0) == vector["fingerprint"]?.text)
            let territories = JSONText.array(AsoOutcome.territories(review.metric, analytics: parsed.2, sales: parsed.3).map { .string($0) })
            #expect(territories.data == vector["territories"]?.data)
        }
        #expect(invalid > 0)
    }
    @Test func changedHiddenOverlapsAndCorrectedReportsInvalidateTheSameNoteWithoutReplacingItsText() throws {
        let datasets = try items(golden()["datasets"]), choice = JSONText.object([("metric", .string("views")), ("days", .number(1)), ("territory", .string("USA")), ("comparisonTerritory", .string("SWE"))])
        let base = try #require(datasets.first { $0["id"] == .string("base") }), corrected = try #require(datasets.first { $0["id"] == .string("corrected-count") })
        let event = try input(base).0, original = try analyze(base, choice: choice), later = try analyze(corrected, choice: choice)
        var saved = try JournalNoteBaseline.initial(event: event, saved: nil, metric: original.metric, evidence: original.evidenceFingerprint(for: event))
        saved.conclusion = "Synthetic interpretation retained while reading corrected reports."
        let current = try JournalNoteBaseline.initial(event: event, saved: saved, metric: later.metric, evidence: later.evidenceFingerprint(for: event))
        #expect(current == saved && !JournalNoteBaseline.canSave(current, event: event, evidence: later.evidenceFingerprint(for: event)))
        let accepted = try JournalNoteBaseline.usingCurrentEvidence(current, fingerprint: later.evidenceFingerprint(for: event))
        #expect(accepted.conclusion == saved.conclusion && accepted.basis == saved.basis && accepted.updatedAt == saved.updatedAt)
        #expect(JournalNoteBaseline.canSave(accepted, event: event, evidence: later.evidenceFingerprint(for: event)))
        let all = try #require(datasets.first { $0["id"] == .string("large-overlap") }), changed = try #require(datasets.first { $0["id"] == .string("changed-hidden-overlap") })
        let a = try analyze(all, choice: choice), b = try analyze(changed, choice: choice)
        #expect(a.otherEvents.count == 50 && a.otherEventsTotal == 75 && b.otherEventsTotal == 75)
        #expect(a.otherEvents.map(\.title) == b.otherEvents.map(\.title) && a.otherEventsDigest != b.otherEventsDigest)
        #expect(a.evidenceFingerprint(for: event) != b.evidenceFingerprint(for: event))
    }
    @Test func staleChangeSetsAndUnrelatedEntriesRequireSeparateExplicitBaselineChoices() throws {
        let datasets = try items(golden()["datasets"]), base = try #require(datasets.first { $0["id"] == .string("base") }), event = try input(base).0
        var saved = JournalNote(eventId: event.id, basis: String(repeating: "0", count: 64), intent: "Synthetic unsaved text", evidenceFingerprint: String(repeating: "1", count: 64))
        let currentEvidence = String(repeating: "2", count: 64), read = try JournalNoteBaseline.initial(event: event, saved: saved, evidence: currentEvidence)
        #expect(read == saved && !JournalNoteBaseline.canSave(read, event: event, evidence: currentEvidence))
        let acceptedChanges = try JournalNoteBaseline.usingCurrentChanges(read, event: event)
        #expect(acceptedChanges.intent == saved.intent && acceptedChanges.evidenceFingerprint == saved.evidenceFingerprint)
        #expect(!JournalNoteBaseline.canSave(acceptedChanges, event: event, evidence: currentEvidence))
        let acceptedReports = try JournalNoteBaseline.usingCurrentEvidence(acceptedChanges, fingerprint: currentEvidence)
        #expect(JournalNoteBaseline.canSave(acceptedReports, event: event, evidence: currentEvidence))
        saved.eventId = "draft:00000000-0000-4000-8000-000000000099"
        #expect(throws: JournalFailure.invalid) { try JournalNoteBaseline.initial(event: event, saved: saved) }
        #expect(throws: JournalFailure.invalid) { try JournalNoteBaseline.usingCurrentChanges(saved, event: event) }
        #expect(throws: JournalFailure.invalid) { try JournalNoteBaseline.usingCurrentEvidence(read, fingerprint: "invalid") }
    }
    @Test func untrustedCountsCannotOverflowTrapOrBecomeZeroActivity() throws {
        for value in [Double.nan, .infinity, -.infinity, -1, 0.5, 9_007_199_254_740_992] { #expect(throws: AsoOutcome.Failure.overflow) { try AsoOutcome.total([value]) } }
        #expect(throws: AsoOutcome.Failure.overflow) { try AsoOutcome.total([9_007_199_254_740_991, 1]) }
        #expect(try AsoOutcome.total([0, 9_007_199_254_740_990, 1]) == 9_007_199_254_740_991)
    }
    @Test func savedEvidenceRoundTripsThroughEncryptedNotesAndStaleSavesKeepTheEditorsInputs() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), app = try #require(account.appIds.first)
        let events = try await session.changeJournal(accountId: account.id, appId: app), event = try #require(events.first { $0.source == "import" && $0.occurrenceAfter != nil })
        let datasets = try items(golden()["datasets"]), base = try #require(datasets.first { $0["id"] == .string("base") }), corrected = try #require(datasets.first { $0["id"] == .string("corrected-count") })
        let original = try input(base), later = try input(corrected)
        let review = try AsoOutcome.analyze(event, events: events, analytics: original.2, sales: original.3, days: 1, territory: "USA")
        var note = try JournalNoteBaseline.initial(event: event, saved: nil, metric: review.metric, evidence: review.evidenceFingerprint(for: event))
        note.conclusion = "Synthetic interpretation."
        let saved = try await session.saveJournalNote(accountId: account.id, appId: app, note: note, expected: 0)
        let read = try await session.journalNote(accountId: account.id, appId: app, eventId: event.id)
        #expect(read.note?.evidenceFingerprint == note.evidenceFingerprint && read.note?.conclusion == note.conclusion)
        let correctedReview = try AsoOutcome.analyze(event, events: events, analytics: later.2, sales: later.3, days: 1, territory: "USA")
        let retained = try JournalNoteBaseline.initial(event: event, saved: read.note, evidence: correctedReview.evidenceFingerprint(for: event))
        #expect(!JournalNoteBaseline.canSave(retained, event: event, evidence: correctedReview.evidenceFingerprint(for: event)))
        var other = saved.note; other.conclusion = "A newer synthetic note in another editor."
        _ = try await session.saveJournalNote(accountId: account.id, appId: app, note: other, expected: saved.revision)
        let edited = try JournalNoteBaseline.usingCurrentEvidence(retained, fingerprint: correctedReview.evidenceFingerprint(for: event))
        await #expect(throws: JournalFailure.stale) { try await session.saveJournalNote(accountId: account.id, appId: app, note: edited, expected: saved.revision) }
        #expect(edited.conclusion == note.conclusion)
        let latest = try await session.journalNote(accountId: account.id, appId: app, eventId: event.id)
        let acknowledged = try await session.saveJournalNote(accountId: account.id, appId: app, note: edited, expected: latest.revision)
        #expect(acknowledged.note.evidenceFingerprint == correctedReview.evidenceFingerprint(for: event) && acknowledged.note.conclusion == note.conclusion)
        var unicode = acknowledged.note; unicode.conclusion = "é"
        var literal = unicode; literal.conclusion = "e\u{0301}"
        #expect(JournalNoteBaseline.hasChanges(literal, from: unicode))
        literal.conclusion = String(repeating: "😀", count: 501)
        #expect(!JournalNoteBaseline.canSave(literal, event: event, evidence: literal.evidenceFingerprint))
    }
}
