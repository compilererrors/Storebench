import Foundation
import Testing
@testable import StorebenchCore

struct AsoProgressTests {
    init() throws { _ = try TestIsolation.require() }
    @Test func rowsAndDiffsMatchSyntheticReferenceResults() throws {
        let data = try Data(contentsOf: try #require(Bundle.module.url(forResource: "synthetic-progress", withExtension: "json", subdirectory: nil)))
        let revisions = try WorkspaceSession.items(try JSONText.parse(data)["revisions"]).map { try JSONDecoder().decode(Revision.self, from: $0.data) }
        let rows = AsoProgress.rows(revisions)
        #expect(rows.map(\.id) == ["11111111-1111-4111-8111-111111111111:version-1", "22222222-2222-4222-8222-222222222222:version-1", "33333333-3333-4333-8333-333333333333:version-2"])
        #expect(rows.map(\.at) == ["2026-03-01T10:00:00.000Z", "2026-03-05T10:00:00.000Z", "2026-04-01T10:00:00.000Z"])
        #expect(rows.map(\.isUpdate) == [false, true, false] && rows.map(\.baseline) == [true, false, false] && rows.map(\.previousVersion) == [nil, "iOS 1.0", "iOS 1.0"])
        #expect(rows[1].changes.map(\.field) == ["description", "subtitle"])
        #expect(rows[1].changes[0].added == ["Second", "with a line"] && rows[1].changes[0].removed == ["First"])
        #expect(rows[1].changes[1].segments == [.init(kind: .removed, text: "First"), .init(kind: .added, text: "Second"), .init(kind: .same, text: " "), .init(kind: .removed, text: "subtitle"), .init(kind: .added, text: "\"subtitle\" ✓")])
        #expect(rows[2].changes.map(\.field) == ["description", "keywords"] && rows[2].changes[1].added == ["fresh"] && rows[2].changes[1].removed.isEmpty)
        #expect(AsoProgress.wordDiff("Fast  notes for\nteams", "Fast shared notes for\nsmall teams") == [.init(kind: .same, text: "Fast"), .init(kind: .removed, text: "  "), .init(kind: .added, text: " shared "),
                                                                                                         .init(kind: .same, text: "notes for\n"), .init(kind: .added, text: "small "), .init(kind: .same, text: "teams")])
    }

    @Test func missingDaysAreNeverZero() {
        let points = (1...20).map { AsoPoint(date: String(format: "2026-05-%02d", $0), value: Double(($0 - 1) * 3)) }.filter { $0.date != "2026-05-12" }
        let week = AsoProgress.impact(points, date: "2026-05-10", days: 7, today: "2026-06-01")
        #expect(week.basis == .daily && week.before == 15 && week.after == 40 && week.beforeDays == 7 && week.afterDays == 6 && !week.future)
        let short = AsoProgress.impact(points, date: "2026-05-10", days: 3, today: "2026-06-01")
        #expect(short.before == 21 && short.after == 33)
        let late = AsoProgress.impact(points, date: "2026-05-15", days: 7, today: "2026-05-20")
        #expect(late.before == 29.5 && late.after == 51 && late.future)
        #expect(AsoProgress.impact([], date: "2026-05-10", days: 7, today: "2026-06-01").basis == .missing)
    }
}
