import Foundation
import Testing
@testable import StorebenchCore

@Suite struct AsoProgressContractTests {
    init() throws { _ = try TestIsolation.require() }
    func fixture() throws -> JSONText { try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/aso-progress.json"))) }
    func items(_ value: JSONText?) throws -> [JSONText] { guard case .array(let values)? = value else { throw AsoOutcome.Failure.malformed }; return values }
    func number(_ value: JSONText?) throws -> Double { guard case .number(let number)? = value else { throw AsoOutcome.Failure.malformed }; return number }
    func points(_ value: JSONText?) throws -> [AsoPoint] { try items(value).map { AsoPoint(date: $0["date"]!.text!, value: try number($0["value"])) } }
    @Test func fullVersionHistoryLanguageAndFieldFiltersMatchPrimaryIncludingUnknownDates() throws {
        let histories = try items(fixture()["histories"]); #expect(histories.count >= 10)
        for history in histories {
            let revisions = try JSONDecoder().decode([Revision].self, from: history["revisions"]!.data), all = AsoProgress.rows(revisions), locales = AsoProgress.locales(revisions)
            #expect(JSONText.array(locales.map(JSONText.string)).data == history["locales"]?.data)
            for row in all {
                let comparison = AsoProgress.comparison([], row: row, days: 7, today: "2026-10-01")
                #expect((comparison == nil) == (!row.dateKnown || row.baseline))
            }
            for value in try items(history["initialLocales"]) { #expect(AsoProgress.initialLocale(locales, primary: value["primary"]!.text!) == value["value"]?.text) }
            for vector in try items(history["cases"]) {
                let fields = try items(vector["fields"]).map { $0.text! }, locale = vector["locale"]!.text!, generated = AsoProgress.rows(revisions, locale: locale, fields: fields)
                #expect(JSONText.array(generated.map(\.json)).data == vector["rows"]?.data, "History: \(history["id"]!.text!) / \(locale) / \(fields)")
                #expect(AsoProgress.filteredRows(all, locale: locale, fields: fields) == generated)
                let range = try PeriodDateRange(from: vector["range"]!["from"]!.text!, to: vector["range"]!["to"]!.text!), changed = AsoProgress.changedRows(generated, range: range)
                #expect(JSONText.array(changed.map { .string($0.id) }).data == vector["changed"]?.data)
                let expected = try items(vector["overlaps"])
                for (index, row) in changed.enumerated() { #expect(JSONText.bool(AsoProgress.overlaps(row, newer: index > 0 ? changed[index - 1] : nil, days: 7)) == expected[index]["value"]) }
            }
        }
    }
    @Test func allMeasuresCoverageStatusAndSameDayRatesMatchPrimary() throws {
        let datasets = try items(fixture()["datasets"]); #expect(datasets.count >= 10 && AsoProgress.metrics.count == 9)
        for dataset in datasets {
            let decoder = JSONDecoder(), analytics = try decoder.decode([AnalyticsPeriod].self, from: dataset["analytics"]!.data), records = try decoder.decode([SalesRecord].self, from: dataset["records"]!.data)
            let sales = try records.flatMap { try SalesPresentation.prepare([$0], accountId: "synthetic-account", appId: "1000000001") }
            let measured = Dictionary(uniqueKeysWithValues: AsoProgress.metrics.map { ($0.key, AsoProgress.points($0.key, analytics: analytics, sales: sales)) })
            let reports = AsoProgress.Reports(measured)
            for metric in AsoProgress.metrics { #expect(JSONText.array(measured[metric.key]!.map(\.json)).data == dataset["points"]?[metric.key]?.data, "Report selection: \(dataset["id"]!.text!) / \(metric.key)") }
            #expect(JSONText.array(AsoProgress.initialMeasures(measured).map(JSONText.string)).data == dataset["initialMeasures"]?.data)
            for vector in try items(dataset["cases"]) {
                let days = Int(try number(vector["days"])), today = vector["today"]!.text!, impacts = try items(vector["impacts"]), rates = try items(vector["rates"])
                for (index, metric) in AsoProgress.metrics.enumerated() {
                    let value = AsoProgress.impact(measured[metric.key]!, date: "2026-03-11", days: days, today: today)
                    #expect(reports.impact(metric.key, date: "2026-03-11", days: days, today: today).json.data == impacts[index]["impact"]?.data)
                    #expect(value.json.data == impacts[index]["impact"]?.data, "Impact: \(dataset["id"]!.text!) / \(metric.key) / \(days)")
                    #expect(AsoProgress.describe(value, label: metric.title).json.data == impacts[index]["description"]?.data)
                }
                for (index, rate) in AsoProgress.rates.enumerated() { #expect(reports.rate(rate.numerator, rate.denominator, date: "2026-03-11", days: days).json.data == rates[index]["value"]?.data); #expect(AsoProgress.rateImpact(measured[rate.numerator]!, measured[rate.denominator]!, date: "2026-03-11", days: days).json.data == rates[index]["value"]?.data) }
            }
        }
    }
    @Test func dailyWeeklyMonthlyAveragesAndIndexedScalesMatchPrimary() throws {
        for vector in try items(fixture()["bucketVectors"]) {
            let granularity = try #require(AsoProgress.Granularity(rawValue: vector["granularity"]!.text!)), generated = AsoProgress.buckets(try points(vector["points"]), granularity: granularity)
            #expect(JSONText.array(generated.map(\.json)).data == vector["buckets"]?.data)
            #expect(JSONText.array(AsoProgress.indexed(generated.map(\.value)).map(JSONText.number)).data == vector["indexed"]?.data)
        }
    }
    @Test func chartPeriodsGapsIsolatedPointsMarkersAndInspectionMatchPrimary() throws {
        for vector in try items(fixture()["chartVectors"]) {
            let decoder = JSONDecoder(), series = try decoder.decode([SavedTimeSeries.Series].self, from: vector["series"]!.data), markers = try decoder.decode([SavedTimeSeries.Marker].self, from: vector["markers"]!.data)
            let layout = SavedTimeSeries.layout(series, markers: markers)
            #expect((layout?.json ?? .null).data == vector["layout"]?.data)
            guard let layout else { continue }
            for value in try items(vector["nearest"]) { let day = try number(value["day"]), index = Int(try number(value["index"])); #expect(layout.nearest(day) == index) }
            #expect(layout.selection(nil, key: "ArrowLeft") == layout.slots.count - 1)
            #expect(layout.selection(nil, key: "ArrowRight") == 0)
            #expect(layout.selection(nil, key: "Home") == 0)
            #expect(layout.selection(0, key: "End") == layout.slots.count - 1)
            #expect(layout.selection(0, key: "ArrowLeft") == 0)
            #expect(layout.selection(layout.slots.count - 1, key: "ArrowRight") == layout.slots.count - 1)
            #expect(layout.selection(0, key: "Escape") == nil)
        }
    }
}
