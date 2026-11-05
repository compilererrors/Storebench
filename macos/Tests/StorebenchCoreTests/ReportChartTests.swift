import Foundation
import Testing
@testable import StorebenchCore

@Suite struct ReportChartTests {
    init() throws { _ = try TestIsolation.require() }
    func fixture() throws -> JSONText { try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/report-charts.json"))) }
    func items(_ value: JSONText?) throws -> [JSONText] { guard case .array(let result)? = value else { throw AnalyticsFailure.format }; return result }
    func numbers(_ value: JSONText?) throws -> [Double] { try items(value).map { guard case .number(let number) = $0 else { throw AnalyticsFailure.format }; return number } }
    func equal(_ actual: JSONText, _ expected: JSONText) -> Bool {
        switch (actual, expected) {
        case (.number(let a), .number(let b)): return abs(a - b) <= max(1e-9, abs(b) * 1e-12)
        case (.array(let a), .array(let b)): return a.count == b.count && zip(a, b).allSatisfy { equal($0, $1) }
        case (.object(let a), .object(let b)): return a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && equal($0.1, $1.1) }
        default: return actual == expected
        }
    }
    func contract(_ series: [SavedTimeSeries.Series], markers: [SavedTimeSeries.Marker], probes: [Double]) -> JSONText {
        guard let layout = SavedTimeSeries.layout(series, markers: markers) else { return .null }
        return .object([("layout", layout.json), ("domain", .array([.number(Double(layout.startDay)), .number(Double(layout.endDay + 1))])), ("scale", layout.scale.json),
                        ("markerActivity", .array(layout.markers.map { .bool($0.active) })), ("nearest", .array(probes.map { layout.nearest($0).map { .number(Double($0)) } ?? .null }))])
    }
    @Test func analyticsOriginalPeriodsAllSelectedMeasuresAndIndexedValuesMatchPrimary() throws {
        let datasets = try items(fixture()["analytics"]); #expect(datasets.count == 10)
        for dataset in datasets {
            let periods = try JSONDecoder().decode([AnalyticsPeriod].self, from: dataset["periods"]!.data)
            let cases = try items(dataset["cases"]); #expect(cases.count == 14)
            for vector in cases {
                let metrics = try JSONDecoder().decode([String].self, from: vector["metrics"]!.data)
                let series = try ReportCharts.analytics(Array(periods.reversed()), metrics: metrics, indexed: vector["indexed"] == .bool(true))
                #expect(series.map(\.key) == metrics)
                #expect(equal(.array(series.map(\.json)), vector["series"]!), "Analytics chart values: \(dataset["id"]!.text!) / \(metrics)")
                #expect(equal(contract(series, markers: [], probes: try numbers(vector["probes"])), vector["expected"]!), "Analytics chart inspection: \(dataset["id"]!.text!) / \(metrics)")
            }
        }
    }
    @Test func salesUnknownLeadingTrailingAndInteriorDetailsRemainInspectableWithoutInventedZeros() throws {
        let value = try fixture(), account = value["accountId"]!.text!, app = value["appId"]!.text!, datasets = try items(value["sales"])
        #expect(datasets.count == 12 && ReportCharts.salesMeasures.map(\.rawValue) == ["paid", "free", "inAppPurchases", "refunds"])
        for dataset in datasets {
            let records = try JSONDecoder().decode([SalesRecord].self, from: dataset["records"]!.data)
            let periods = try SalesPresentation.prepare(records, accountId: account, appId: app), analysis = try SalesPresentation.analyze(periods)
            for vector in try items(dataset["cases"]) {
                let chart = ReportCharts.sales(analysis, measure: SalesPresentation.Measure(rawValue: vector["measure"]!.text!))
                #expect(equal(chart.json, vector["chart"]!), "Sales chart totals and details: \(dataset["id"]!.text!) / \(vector["measure"]!.text!)")
                #expect(equal(contract(chart.series, markers: [], probes: try numbers(vector["probes"])), vector["expected"]!), "Sales chart inspection: \(dataset["id"]!.text!) / \(vector["measure"]!.text!)")
                #expect(chart.series[0].points.count == analysis.trend.count)
            }
        }
    }
    @Test func intervalUnionDuplicatesOverlapsLongGapsAndFullBenchmarkInspectionMatchPrimary() throws {
        let value = try fixture(), vectors = try items(value["generic"]) + [value["benchmark"]!]
        for vector in vectors {
            let decoder = JSONDecoder(), series = try decoder.decode([SavedTimeSeries.Series].self, from: vector["series"]!.data)
            let markers = try vector["markers"].map { try decoder.decode([SavedTimeSeries.Marker].self, from: $0.data) } ?? []
            #expect(equal(contract(series, markers: markers, probes: try numbers(vector["probes"])), vector["expected"]!))
            if let layout = SavedTimeSeries.layout(series, markers: markers) {
                #expect(layout.domain.lowerBound.timeIntervalSince1970 == Double(layout.startDay) * 86_400)
                #expect(layout.domain.upperBound.timeIntervalSince1970 == Double(layout.endDay + 1) * 86_400)
                #expect(layout.nearest(.nan) == nil && layout.nearest(.infinity) == nil)
            }
        }
    }
    @Test func keyboardInspectionStartsAtEitherEndClampsAndCanBeClearedForUnknownPeriods() throws {
        let series = [SavedTimeSeries.Series(key: "free", label: "Free downloads", points: [.init(start: "2026-02-01", end: "2026-02-01", value: nil), .init(start: "2026-02-03", end: "2026-02-03", value: 0), .init(start: "2026-02-04", end: "2026-02-04", value: nil)])]
        let layout = try #require(SavedTimeSeries.layout(series))
        #expect(layout.selection(nil, key: "ArrowLeft") == 2 && layout.selection(nil, key: "ArrowRight") == 0)
        #expect(layout.selection(0, key: "ArrowLeft") == 0 && layout.selection(2, key: "ArrowRight") == 2)
        #expect(layout.selection(100, key: "ArrowLeft") == 1 && layout.selection(-5, key: "ArrowRight") == 1)
        #expect(layout.selection(2, key: "Home") == 0 && layout.selection(0, key: "End") == 2)
        #expect(layout.selection(1, key: "Escape") == nil && layout.selection(1, key: "Enter") == 1)
        #expect(layout.slots[0].values == [nil] && layout.slots[1].values == [0] && layout.slots[2].values == [nil])
        #expect(layout.gaps == [.init(start: "2026-02-02", end: "2026-02-02")])
    }
    @Test func binaryInspectionMatchesFullScanForOverlappingIntervalsAndEqualCenters() throws {
        let points = [
            SavedTimeSeries.Point(start: "2026-01-01", end: "2026-12-31", value: 3),
            .init(start: "2026-01-02", end: "2026-01-02", value: nil),
            .init(start: "2026-01-03", end: "2026-01-03", value: 0),
            .init(start: "2026-07-01", end: "2026-07-01", value: 7)
        ]
        let layout = try #require(SavedTimeSeries.layout([.init(key: "test", label: "Synthetic reports", points: points)]))
        for day in stride(from: Double(layout.startDay) - 2, through: Double(layout.endDay) + 2, by: 0.25) {
            let expected = layout.slots.enumerated().min { a, b in
                let left = abs(a.element.middle - day), right = abs(b.element.middle - day)
                return left == right ? a.offset < b.offset : left < right
            }?.offset
            #expect(layout.nearest(day) == expected)
        }
    }
    @Test func drawingEnvelopeRetainsExtremaUnknownBreaksAndEveryExactInspectableValue() throws {
        let first = PeriodDates.number("2026-01-01")!
        let points = (0..<3000).map { index in
            SavedTimeSeries.Point(start: PeriodDates.text(first + index), end: PeriodDates.text(first + index), value: index == 1500 ? nil : index == 27 ? -12 : index == 2700 ? 1234 : Double(index % 17))
        }
        let layout = try #require(SavedTimeSeries.layout([.init(key: "synthetic", label: "Synthetic amounts", points: points)]))
        let drawing = layout.drawingRuns(maximumPerRun: 64)[0]
        #expect(layout.series[0].points == points && layout.slots.count == 3000)
        #expect(layout.runs[0].count == 2 && drawing.count == 2 && drawing.allSatisfy { $0.count <= 64 })
        #expect(drawing.flatMap { $0 }.contains { $0.value == -12 } && drawing.flatMap { $0 }.contains { $0.value == 1234 })
        #expect(layout.scale.minimum <= -12 && layout.scale.maximum >= 1234)
        #expect(layout.slots[1500].values == [nil] && layout.slots[0].values == [0])
        for run in drawing { #expect(zip(run, run.dropFirst()).allSatisfy { $0.start < $1.start }) }
    }
    @Test func financialChartsReconcileWithOriginalFiscalFactsAndNeverMixCurrencies() throws {
        let helper = try FinancialPresentationTests(), fixture = try helper.golden()
        for vector in try items(fixture["cases"]) {
            let periods = try helper.periods(vector["periods"]!)
            let groups = Dictionary(grouping: periods, by: \.dateKey)
            let currencies = Set(periods.flatMap { $0.rows.flatMap { $0.proceeds.map(\.currency) } })
            for metric in ["paid", "returned", "net", "other"] {
                let chart = try ReportCharts.financial(periods, metric: metric)[0]
                #expect(chart.points.count == groups.count)
                for point in chart.points {
                    let summary = try FinancialPresentation.summary(groups[point.start + ":" + point.end]!)
                    let expected = metric == "paid" ? summary.paid : metric == "returned" ? summary.returned : metric == "net" ? summary.net : summary.other
                    #expect(point.value == Double(expected))
                }
            }
            for currency in currencies {
                let chart = try ReportCharts.financial(periods, metric: "proceeds", currency: currency)[0]
                for point in chart.points {
                    let amount = try FinancialPresentation.summary(groups[point.start + ":" + point.end]!).proceeds.first { $0.currency == currency }
                    #expect(point.exactLabel == amount.map { $0.amount + " " + currency })
                    #expect((point.value == nil) == (amount == nil))
                    if let layout = SavedTimeSeries.layout([chart]) {
                        #expect(layout.series[0].points == chart.points)
                    }
                }
            }
        }
        let invalid = try helper.periods(fixture["periods"]!)
        #expect(throws: FinanceFailure.overlap) { try ReportCharts.financial(invalid, metric: "paid") }
    }
    @Test func salesProceedsRetainExactAmountsAndLeaveIncompleteSourceDetailsUnknown() throws {
        let value = try fixture(), account = value["accountId"]!.text!, app = value["appId"]!.text!
        for dataset in try items(value["sales"]) {
            let records = try JSONDecoder().decode([SalesRecord].self, from: dataset["records"]!.data)
            let periods = try SalesPresentation.prepare(records, accountId: account, appId: app)
            let currencies = Set(periods.flatMap { $0.rows.flatMap { $0.proceeds.map(\.currency) } })
            for currency in currencies {
                let chart = try ReportCharts.salesProceeds(periods, currency: currency)[0]
                for point in chart.points {
                    let period = try #require(periods.first { $0.beginDate == point.start && $0.endDate == point.end })
                    if !period.moneyComplete || !period.productsComplete { #expect(point.value == nil && point.exactLabel == nil) }
                    else {
                        let amount = try SalesPresentation.analyze([period]).proceeds.first { $0.currency == currency }
                        #expect(point.exactLabel == amount.map { $0.amount + " " + currency })
                    }
                }
            }
        }
    }
}
