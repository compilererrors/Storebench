import Foundation
import Testing
@testable import StorebenchCore

@Suite struct AsoProgressOverlapTests {
    init() throws { _ = try TestIsolation.require() }

    func row(_ id: String, _ date: String, field: String = "keywords", locale: String = "en-US", baseline: Bool = false, dateKnown: Bool = true) -> AsoProgressRow {
        let change = AsoFieldChange(key: "version:IOS:\(locale):\(field)", section: "version", field: field, locale: locale, kind: .list, added: ["synthetic"], removed: [], segments: [])
        return AsoProgressRow(id: id, at: date + "T08:00:00.000Z", date: date, version: id, platform: "iOS", previousVersion: nil, isUpdate: false, dateKnown: dateKnown, baseline: baseline, changes: baseline ? [] : [change])
    }

    @Test func changesOnEitherSideOfTheWindowAreMixedInWhateverTheViewFilters() {
        let first = row("1.0", "2026-03-01", baseline: true), older = row("1.1", "2026-03-04", field: "subtitle", locale: "sv"), current = row("1.2", "2026-03-10")
        let newer = row("1.3", "2026-03-17"), later = row("1.4", "2026-03-30"), unknown = row("1.5", "2026-03-12", dateKnown: false)
        let all = [first, older, current, newer, later, unknown]
        // Six days before and seven days after are inside a seven-day window; the baseline and an undated change are not.
        #expect(AsoProgress.overlapping(current, among: all, days: 7).map(\.id) == ["1.1", "1.3"])
        #expect(AsoProgress.overlapping(current, among: all, days: 5).isEmpty)
        // A Keywords-only view hides the subtitle change, but it still moves the same measures.
        let shown = AsoProgress.filteredRows(all, locale: "en-US", fields: ["keywords"])
        #expect(AsoProgress.changedRows(shown, range: nil).contains { $0.id == "1.1" } == false)
        #expect(AsoProgress.overlapping(current, among: all, days: 7).contains { $0.id == "1.1" })
        #expect(AsoProgress.overlapping(unknown, among: all, days: 7).isEmpty)
    }

    @Test func searchMeasuresCountAppleSearchRowsWhateverTheirCapitalization() {
        func period(_ date: String, _ source: String) -> AnalyticsPeriod {
            AnalyticsPeriod(key: "engagement:standard:DAILY:\(date)", kind: "engagement", level: "standard", granularity: "DAILY", processingDate: date, date: date, endDate: date,
                            facts: [.init(territory: "SWE", source: source, device: "iPhone", metric: "impressions", count: 12),
                                    .init(territory: "SWE", source: "App Store Browse", device: "iPhone", metric: "impressions", count: 5)])
        }
        let points = AsoProgress.points("searchImpressions", analytics: [period("2026-03-01", "App Store Search"), period("2026-03-02", "App Store search")], sales: [])
        #expect(points == [AsoPoint(date: "2026-03-01", value: 12), AsoPoint(date: "2026-03-02", value: 12)])
        #expect(AsoProgress.points("impressions", analytics: [period("2026-03-01", "App Store Search")], sales: []) == [AsoPoint(date: "2026-03-01", value: 17)])
    }
}
