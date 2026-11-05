import Foundation
import Testing
@testable import StorebenchCore

@Suite struct AnalyticsPresentationTests {
    init() throws { _ = try TestIsolation.require() }
    func golden() throws -> JSONText { try AnalyticsFileTests().golden() }
    func summaryJSON(_ summary: AnalyticsPresentation.Summary) -> JSONText {
        func rows(_ values: [AnalyticsPresentation.Activity]) -> JSONText { .array(values.map { .object([("key", .string($0.key)), ("count", .number($0.count))]) }) }
        return .object([("totals", .object(AnalyticsPresentation.metrics.map { ($0, .number(summary.totals[$0]!)) })), ("territories", rows(summary.territories)), ("sources", rows(summary.sources)), ("devices", rows(summary.devices))])
    }
    @Test func summariesAndLiteralUnicodeGroupsMatchWebPresentation() throws {
        guard case .array(let vectors)? = try golden()["vectors"] else { throw AnalyticsFailure.format }
        for vector in vectors where vector["invalid"] != .bool(true) {
            let periods = try JSONDecoder().decode([AnalyticsPeriod].self, from: vector["view"]!.data), metric = vector["summaryMetric"]!.text!
            let summary = try AnalyticsPresentation.summary(periods, metric: metric)
            #expect(summaryJSON(summary).data == vector["summary"]!.data, "Synthetic Analytics summary: \(vector["id"]!.text!)")
            if vector["id"] == .string("distinct-unicode-facts") { #expect(summary.sources.count == 2 && Set(summary.sources.map(\.id)).count == 2) }
        }
    }
    @Test func leadingDownloadGuidanceMatchesThresholdUnknownTiesAndMetricScopeWithoutChangingFacts() throws {
        guard case .array(let cases)? = try golden()["guidanceCases"] else { throw AnalyticsFailure.format }
        #expect(cases.count == 32)
        for vector in cases {
            let periods = try JSONDecoder().decode([AnalyticsPeriod].self, from: vector["periods"]!.data), metric = vector["metric"]!.text!
            let summary = try AnalyticsPresentation.summary(periods, metric: metric), before = summaryJSON(summary)
            let observation = AnalyticsPresentation.leadingTerritory(summary, metric: metric)
            let actual = observation.map { JSONText.object([("code", .string($0.code)), ("name", .string($0.name)), ("count", .number(Double($0.count))), ("total", .number(Double($0.total))), ("share", .string($0.share))]) } ?? .null
            #expect(actual.data == vector["expected"]?.data, "Synthetic guidance: \(vector["id"]!.text!) / \(metric)")
            #expect(summaryJSON(summary).data == before.data)
        }
    }
    @Test func dailyWeeklyMonthlyGapsAndFourIndexedMeasuresMatchWebCharts() throws {
        guard case .array(let vectors)? = try golden()["chartCases"] else { throw AnalyticsFailure.format }
        for vector in vectors {
            let periods = try JSONDecoder().decode([AnalyticsPeriod].self, from: vector["periods"]!.data)
            let metrics = try JSONDecoder().decode([String].self, from: vector["metrics"]!.data)
            let absolute = try AnalyticsPresentation.points(Array(periods.reversed()), metrics: metrics, indexed: false), indexed = try AnalyticsPresentation.points(periods, metrics: metrics, indexed: true)
            let expected = try JSONDecoder().decode([Double].self, from: vector["absolute"]!.data), expectedIndexed = try JSONDecoder().decode([Double].self, from: vector["indexed"]!.data)
            #expect(absolute.map(\.value) == expected)
            for (point, value) in zip(indexed, expectedIndexed) { #expect(abs(point.value - value) < 0.000000001) }
            let runs = metrics.map { metric in Set(absolute.filter { $0.metric == metric }.map(\.run)).count }
            #expect(runs == [2, 2, 2, 2])
            let lines = metrics.map { metric in Dictionary(grouping: absolute.filter { $0.metric == metric }, by: \.run).values.filter { $0.count >= 2 }.count }
            let expectedLines = try JSONDecoder().decode([Int].self, from: vector["runs"]!.data)
            #expect(lines == expectedLines)
            #expect(absolute.count == 12 && Set(absolute.map(\.id)).count == 12)
            for point in absolute {
                let start = ReportTables.dayFormat.date(from: point.start)!, end = ReportTables.dayFormat.date(from: point.end)!.addingTimeInterval(86_400)
                #expect(point.position.timeIntervalSince1970 == (start.timeIntervalSince1970 + end.timeIntervalSince1970) / 2)
            }
            #expect(absolute.filter { $0.metric == "first" }.map(\.start) == periods.map(\.date))
        }
        #expect(AnalyticsPresentation.indexed([0, 0]) == [0, 0] && AnalyticsPresentation.indexed([]).isEmpty)
        #expect(try AnalyticsPresentation.points([], metrics: ["first"], indexed: true).isEmpty)
    }
    @Test func independentStreamsMalformedFactsAndRepeatedPeriodsCannotBecomeChartsOrTotals() throws {
        let fixture = try AnalyticsFileTests()
        let daily = try JSONDecoder().decode([AnalyticsPeriod].self, from: fixture.vector("apple-csv")["view"]!.data), weekly = try JSONDecoder().decode([AnalyticsPeriod].self, from: fixture.vector("weekly")["view"]!.data)
        #expect(throws: AnalyticsFailure.format) { try AnalyticsPresentation.points(daily + weekly, metrics: ["first"], indexed: false) }
        #expect(throws: AnalyticsFailure.format) { try AnalyticsPresentation.summary(daily + daily, metric: "first") }
        #expect(throws: AnalyticsFailure.format) { try AnalyticsPresentation.points(daily, metrics: ["first", "first"], indexed: false) }
        #expect(throws: AnalyticsFailure.format) { try AnalyticsPresentation.points(daily, metrics: ["synthetic-invalid"], indexed: false) }
        let original = try #require(try fixture.vector("apple-csv")["view"])
        guard case .array(let periods) = original, case .object(let fields) = periods[0] else { throw AnalyticsFailure.format }
        for count in [-1.0, 0.5, 9_007_199_254_740_992.0] {
            let facts = JSONText.array([.object([("territory", .string("USA")), ("source", .string("Synthetic")), ("device", .string("Synthetic")), ("metric", .string("first")), ("count", .number(count))])])
            let changed = JSONText.array([.object(fields.map { ($0.0, $0.0 == "facts" ? facts : $0.1) })])
            let invalid = try JSONDecoder().decode([AnalyticsPeriod].self, from: changed.data)
            #expect(throws: AnalyticsFailure.format) { try AnalyticsPresentation.summary(invalid, metric: "first") }
        }
    }
    @Test func wholePeriodBreakdownRetainsZerosAndEveryDateWithoutDailyEstimates() throws {
        guard case .array(let vectors)? = try golden()["chartCases"] else { throw AnalyticsFailure.format }
        for vector in vectors {
            let periods = try JSONDecoder().decode([AnalyticsPeriod].self, from: vector["periods"]!.data)
            let activity = try AnalyticsPresentation.periodActivity(periods, metric: "first")
            #expect(activity.map(\.key) == periods.map(\.key) && activity.map(\.count) == periods.map { $0.total("first") })
        }
    }
    @Test func activityQueriesSortingSharesAndCountryNamesMatchWebPresentation() throws {
        let fixture = try golden()
        guard case .array(let countries)? = fixture["countries"], case .array(let cases)? = fixture["breakdownCases"] else { throw AnalyticsFailure.format }
        #expect(countries.count == 249 && cases.count > 300)
        for country in countries {
            #expect(Territories.name(country["alpha2"]!.text!) == country["name"]!.text! && Territories.name(country["alpha3"]!.text!) == country["name"]!.text!)
        }
        #expect(AnalyticsPresentation.territoryName("UNKNOWN") == "Unspecified territory")
        for vector in cases {
            let periods = try JSONDecoder().decode([AnalyticsPeriod].self, from: vector["periods"]!.data), metric = vector["metric"]!.text!
            let summary = try AnalyticsPresentation.summary(periods, metric: metric)
            let rows = try AnalyticsPresentation.breakdown(periods, summary: summary, metric: metric, dimension: AnalyticsPresentation.Dimension(rawValue: vector["dimension"]!.text!)!, query: vector["query"]!.text!, order: AnalyticsPresentation.Order(rawValue: vector["order"]!.text!)!)
            let actual = JSONText.array(rows.map { .object([("key", .string($0.key)), ("name", .string($0.name)), ("count", .number($0.count)), ("share", $0.share.map(JSONText.number) ?? .null)]) })
            #expect(actual.data == vector["expected"]!.data, "Synthetic activity query: \(vector["id"]!.text!) · \(vector["dimension"]!.text!) · \(vector["order"]!.text!)")
        }
    }
}
