import Foundation
import Testing
@testable import StorebenchCore

/// Which activity days a saved Analytics selection covers. Everything here is synthetic.
struct AnalyticsCoverageTests {
    init() throws { _ = try TestIsolation.require() }

    @Test func coverageCountsSavedActivityDaysInsideTheChosenRange() throws {
        func period(_ date: String) -> AnalyticsPeriod {
            AnalyticsPeriod(key: "downloads:standard:DAILY:\(date)", kind: "downloads", level: "standard", granularity: "DAILY", processingDate: date, date: date, endDate: date, facts: [])
        }
        let saved = ["2026-03-03", "2026-03-04", "2026-03-06"].map(period)
        #expect(AnalyticsPresentation.coverage(saved) == .init(from: "2026-03-03", to: "2026-03-06", savedDays: 3, requestedDays: 4))
        let range = try PeriodDateRange(from: "2026-03-01", to: "2026-03-05")
        let chosen = try #require(AnalyticsPresentation.coverage(saved, range: range))
        #expect(chosen == .init(from: "2026-03-01", to: "2026-03-05", savedDays: 2, requestedDays: 5) && !chosen.complete)
        #expect(AnalyticsPresentation.coverage([]) == nil)
    }
}
