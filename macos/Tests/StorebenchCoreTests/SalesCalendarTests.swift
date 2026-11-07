import Foundation
import Testing
@testable import StorebenchCore

@Suite struct SalesCalendarTests {
    init() throws { _ = try TestIsolation.require() }
    func golden() throws -> JSONText { try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/sales-calendar.json"))) }
    func number(_ value: JSONText?) throws -> Double { guard case .number(let value)? = value else { throw SalesPresentationFailure.format }; return value }
    func strings(_ value: JSONText?) throws -> [String] { guard case .array(let values)? = value else { throw SalesPresentationFailure.format }; return try values.map { try #require($0.text) } }
    @Test func pacificMorningInstantsAndEveryAvailabilityBoundaryMatchWebIncludingDSTAndYearZero() throws {
        guard case .array(let cases)? = try golden()["cases"] else { throw SalesPresentationFailure.format }
        #expect(cases.count == 70)
        for vector in cases {
            let day = try #require(vector["day"]?.text), window = try SalesCalendar.publicationWindow(day)
            let expectedFrom = try number(vector["from"]), expectedTo = try number(vector["to"])
            #expect(window.from.timeIntervalSince1970 * 1000 == expectedFrom && window.to.timeIntervalSince1970 * 1000 == expectedTo, "Synthetic Pacific day: \(day)")
            guard case .array(let clocks)? = vector["clocks"] else { throw SalesPresentationFailure.format }
            for clock in clocks { #expect(try SalesCalendar.availability(day, now: Date(timeIntervalSince1970: number(clock["now"]) / 1000)).rawValue == clock["expected"]?.text) }
        }
    }
    @Test func groupedMissingDayGuidanceUsesOneSnapshotAndNeverCreatesReportActivity() throws {
        guard case .array(let groups)? = try golden()["groups"] else { throw SalesPresentationFailure.format }
        for vector in groups {
            let days = try strings(vector["days"]), now = Date(timeIntervalSince1970: try number(vector["readAt"]) / 1000)
            let guidance = try SalesCalendar.guidance(Array(days.reversed()), now: now)
            let waiting = try strings(vector["waiting"]), late = try strings(vector["late"]), missing = try strings(vector["missing"])
            #expect(guidance.waiting.map(\.date) == waiting && guidance.late.map(\.date) == late && guidance.missing.map(\.date) == missing)
            #expect([guidance.waiting, guidance.late, guidance.missing].map(SalesCalendar.label) == (try strings(vector["labels"])))
            let range = try SalesPresentation.Range(beginDate: days[0], endDate: days.last!)
            let empty = try SalesPresentation.select([], range: range)
            #expect(empty.analysis.paid == 0 && empty.analysis.coverage == nil && empty.coveredDays == 0 && !empty.complete && empty.missingDays == days)
        }
    }
    @Test func separateRunsOfMissingDaysAreNeverJoinedIntoOneRange() throws {
        let days = ["2026-03-01", "2026-03-02", "2026-03-03", "2026-03-04", "2026-03-09", "2026-03-12", "2026-03-13"]
        let guidance = try SalesCalendar.guidance(days, now: Date(timeIntervalSince1970: 1_780_000_000))
        #expect(guidance.missing.count == days.count)
        #expect(SalesCalendar.label(guidance.missing) == "Mar 1 – Mar 4 (4 days), Mar 9, Mar 12 – Mar 13 (2 days)")
        let scattered = try SalesCalendar.guidance(["2026-03-01", "2026-03-03", "2026-03-05", "2026-03-07", "2026-03-09", "2026-03-11", "2026-03-12"], now: Date(timeIntervalSince1970: 1_780_000_000))
        #expect(SalesCalendar.label(scattered.missing) == "Mar 1, Mar 3, Mar 5, Mar 7, and 3 more days")
    }
    @Test func boundedGuidanceRejectsInvalidDatesDuplicateDaysAndInvalidClocks() throws {
        let clock = Date(timeIntervalSince1970: 1_772_975_000), day = "2026-03-07"
        #expect(try SalesCalendar.guidance([], now: clock).waiting.isEmpty)
        for invalid in ["2026-02-30", "2026-2-01", "2026-01-01\n", ""] { #expect(throws: SalesPresentationFailure.range) { try SalesCalendar.publicationWindow(invalid) } }
        #expect(throws: SalesPresentationFailure.range) { try SalesCalendar.availability(day, now: Date(timeIntervalSince1970: .nan)) }
        #expect(throws: SalesPresentationFailure.range) { try SalesCalendar.guidance([day, day], now: clock) }
        let first = PeriodDates.number("2025-01-01")!
        #expect(try SalesCalendar.guidance((0..<401).map { PeriodDates.text(first + $0) }, now: clock).missing.count > 0)
        #expect(throws: SalesPresentationFailure.range) { try SalesCalendar.guidance((0..<402).map { PeriodDates.text(first + $0) }, now: clock) }
    }
}
