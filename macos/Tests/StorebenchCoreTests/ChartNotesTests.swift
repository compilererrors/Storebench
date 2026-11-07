import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct ChartNotesTests {
    init() throws { _ = try TestIsolation.require() }

    func row(_ id: String, _ date: String, fields: [String], update: Bool = false, dateKnown: Bool = true) -> AsoProgressRow {
        let changes = fields.map { AsoFieldChange(key: "version:IOS:en-US:\($0)", section: "version", field: $0, locale: "en-US", kind: .text, added: [], removed: [], segments: []) }
        return AsoProgressRow(id: id, at: date + "T08:00:00.000Z", date: date, version: id, platform: "iOS", previousVersion: "1.0", isUpdate: update, dateKnown: dateKnown, baseline: false, changes: changes)
    }

    @Test func thisYearRunsFromJanuaryFirstThroughTheNewestSavedDate() throws {
        #expect(try PeriodRangeChoice.year.resolve(latest: "2026-03-14") == PeriodDateRange(from: "2026-01-01", to: "2026-03-14"))
        #expect(try PeriodRangeChoice.year.resolve(latest: "") == nil)
        #expect(try PeriodRangeChoice(PeriodRangeChoice.year.json) == .year)
    }

    @Test func markersAreColoredByTheMostSearchRelevantFieldAndOpenTheirVersionOrNote() throws {
        let rows = [row("2.0", "2026-03-01", fields: ["description", "subtitle"]), row("2.1", "2026-03-08", fields: ["description", "keywords"], update: true),
                    row("2.2", "2026-03-15", fields: ["screenshots · APP_IPHONE_67"]), row("2.3", "2026-03-20", fields: ["promotionalText"]), row("2.4", "2026-03-22", fields: ["keywords"], dateKnown: false)]
        #expect(rows.map { AsoProgress.markerKind($0) } == [.names, .keywords, .screenshots, .text, .keywords])
        let notes = [ChartNote(id: "n1", date: "2026-03-10", text: "Spring campaign", createdAt: "2026-03-10T09:00:00.000Z"),
                     ChartNote(id: "n2", date: "2026-04-02", text: "Outside the range", createdAt: "2026-04-02T09:00:00.000Z")]
        let markers = AsoProgress.markers(rows, notes: notes, range: try PeriodDateRange(from: "2026-03-01", to: "2026-03-31"))
        #expect(markers.map(\.target) == ["2.0", "2.1", "note:n1", "2.2", "2.3"])
        #expect(markers.map(\.kind) == ["names", "keywords", "note", "screenshots", "text"])
        #expect(markers[0].label == "2.0 release observed: Description, Subtitle" && markers[1].label.hasPrefix("2.1 update:") && markers[2].label == "Note: Spring campaign")
        #expect(markers[3].label.hasSuffix(": Screenshots"))
        #expect(ChartNotes.within(notes, date: "2026-03-08", days: 7).map(\.id) == ["n1"] && ChartNotes.within(notes, date: "2026-03-01", days: 7).isEmpty)
    }

    @Test func notesAreSavedPerAppValidatedAndKeptWhenAddedTogether() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), app = "1000000001"
        #expect(try await session.chartNotes(accountId: account.id, appId: app).isEmpty)
        let first = try await session.addChartNote(accountId: account.id, appId: app, date: "2026-03-10", text: "  Spring campaign  ")
        #expect(first.text == "Spring campaign")
        for (date, text) in [("2026-02-30", "Bad date"), ("2026-03-10", "   "), ("2026-03-10", String(repeating: "x", count: ChartNotes.textLimit + 1)), ("2026-03-10", "Two\nlines")] {
            await #expect(throws: ChartNoteFailure.self) { try await session.addChartNote(accountId: account.id, appId: app, date: date, text: text) }
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<8 { group.addTask { _ = try await session.addChartNote(accountId: account.id, appId: app, date: "2026-03-0\(index + 1)", text: "Synthetic note \(index)") } }
            try await group.waitForAll()
        }
        let saved = try await session.chartNotes(accountId: account.id, appId: app)
        #expect(saved.count == 9 && saved.map(\.date) == saved.map(\.date).sorted() && saved.last?.id == first.id)
        #expect(try await session.chartNotes(accountId: account.id, appId: "1000000002").isEmpty)
        try await session.removeChartNote(accountId: account.id, appId: app, id: first.id)
        await #expect(throws: ChartNoteFailure.notFound) { try await session.removeChartNote(accountId: account.id, appId: app, id: first.id) }
        #expect(try await session.chartNotes(accountId: account.id, appId: app).count == 8)
    }

    @Test func thePreparedPresentationMatchesThePagesFiltersMarkersAndSeries() throws {
        let rows = [row("2.0", "2026-03-01", fields: ["description", "subtitle"]), row("2.1", "2026-03-08", fields: ["keywords"], update: true), row("2.2", "2026-04-02", fields: ["keywords"])]
        let notes = [ChartNote(id: "n1", date: "2026-03-10", text: "Spring campaign", createdAt: "2026-03-10T09:00:00.000Z")]
        let range = try PeriodDateRange(from: "2026-03-01", to: "2026-03-31")
        let points: [String: [AsoPoint]] = ["impressions": (1...31).map { AsoPoint(date: String(format: "2026-03-%02d", $0), value: Double($0)) }]
        let shown = AsoProgress.presentation(baseRows: rows, locale: "en-US", fields: .all, range: range, notes: notes, measures: ["impressions"], points: points, granularity: .week, indexed: true)
        let filtered = AsoProgress.filteredRows(rows, locale: "en-US", fields: AsoProgress.FieldFilter.all.fields), changed = AsoProgress.changedRows(filtered, range: range)
        #expect(shown.rows == filtered && shown.changed == changed && shown.markers == AsoProgress.markers(changed, notes: notes, range: range))
        #expect(shown.changed.map(\.id) == ["2.1", "2.0"] && shown.series.map(\.key) == ["impressions"])
        let weeks = AsoProgress.buckets(points["impressions"]!, granularity: .week)
        #expect(shown.series[0].points.map(\.value) == AsoProgress.indexed(weeks.map(\.value)) && shown.series[0].label == AsoProgress.metrics.first { $0.key == "impressions" }?.title)
    }
}
