import Foundation
import Testing
@testable import StorebenchCore

/// Several measures in one chart: the saved choice, indexing and bar placement. Everything here is synthetic.
struct ChartOverlayTests {
    init() throws { _ = try TestIsolation.require() }

    @Test func chosenMeasuresKeepTheirOrderDropUnknownNamesAndStopAtTheLimit() {
        let allowed = ["a", "b", "c", "d", "e"]
        #expect(ChartMeasures.chosen("auto", allowed: allowed, fallback: ["b"]) == ["b"])
        #expect(ChartMeasures.chosen("b,x,a,b", allowed: allowed, fallback: ["c"]) == ["b", "a"])
        #expect(ChartMeasures.chosen("a,b,c,d,e", allowed: allowed, fallback: []) == ["a", "b", "c", "d"])
        #expect(ChartMeasures.chosen("", allowed: allowed, fallback: ["z"]).isEmpty)
        #expect(ChartMeasures.toggled("c", on: true, in: ["a", "b"]) == "a,b,c")
        #expect(ChartMeasures.toggled("e", on: true, in: ["a", "b", "c", "d"]) == "a,b,c,d")
        let cleared = ChartMeasures.toggled("a", on: false, in: ["a"])
        #expect(ChartMeasures.chosen(cleared, allowed: allowed, fallback: ["b"]).isEmpty)
    }

    @Test func indexingAppliesOnlyWhereTheScaleChoiceIsShown() {
        // Indexed was chosen for proceeds in two currencies; switching to paid units or a single currency draws reported values.
        #expect(ChartMeasures.indexed(true, metric: "proceeds", currencies: 2) && ChartMeasures.scaleOffered(metric: "proceeds", currencies: 2))
        #expect(!ChartMeasures.indexed(true, metric: "paid", currencies: 2) && !ChartMeasures.scaleOffered(metric: "paid", currencies: 2))
        #expect(!ChartMeasures.indexed(true, metric: "proceeds", currencies: 1) && !ChartMeasures.indexed(false, metric: "proceeds", currencies: 3))
    }

    @Test func indexedSeriesAverageOneHundredAndKeepUnknownValuesUnknown() {
        func point(_ day: Int, _ value: Double?) -> SavedTimeSeries.Point { .init(start: "2026-03-0\(day)", end: "2026-03-0\(day)", value: value, exactLabel: value.map { "\($0) EUR" }) }
        let reported = [SavedTimeSeries.Series(key: "units", label: "Synthetic units", points: [point(1, 1), point(2, nil), point(3, 3)]),
                        SavedTimeSeries.Series(key: "quiet", label: "Synthetic quiet", points: [point(1, 0), point(2, 0)])]
        let indexed = SavedTimeSeries.indexed(reported)
        #expect(indexed[0].points.map(\.value) == [50, nil, 150])
        #expect(indexed[0].points.allSatisfy { $0.exactLabel == nil })
        #expect(indexed[1] == reported[1])
    }

    @Test func barsOfOverlaidSeriesShareTheReportPeriodWithoutOverlapping() throws {
        let day = SavedTimeSeries.Point(start: "2026-03-01", end: "2026-03-01", value: 1), first = Double(try #require(PeriodDates.number("2026-03-01")))
        let left = try #require(SavedTimeSeries.barSpan(day, index: 0, count: 2)), right = try #require(SavedTimeSeries.barSpan(day, index: 1, count: 2))
        #expect(abs(left.start - (first + 0.1)) < 1e-9 && abs(left.end - right.start) < 1e-9 && abs(right.end - (first + 0.9)) < 1e-9)
        let week = SavedTimeSeries.Point(start: "2026-03-01", end: "2026-03-07", value: 1)
        let whole = try #require(SavedTimeSeries.barSpan(week, index: 0, count: 1))
        #expect(abs(whole.start - (first + 0.7)) < 1e-9 && abs(whole.end - (first + 6.3)) < 1e-9)
        #expect(SavedTimeSeries.barSpan(day, index: 2, count: 2) == nil && SavedTimeSeries.barSpan(day, index: 0, count: 0) == nil)
    }
}
