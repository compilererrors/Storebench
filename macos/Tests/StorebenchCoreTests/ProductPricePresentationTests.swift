import Foundation
import Testing
@testable import StorebenchCore

struct ProductPriceFixture {
    enum Failure: Error { case invalid }
    static func array(_ value: JSONText?) throws -> [JSONText] { guard case .array(let values)? = value else { throw Failure.invalid }; return values }
    static func flag(_ value: JSONText?) throws -> Bool { guard case .bool(let result)? = value else { throw Failure.invalid }; return result }
    static func product(_ value: JSONText) throws -> PriceProduct {
        let name = try #require(value["kind"]?.text), kind = try #require(PriceProduct.Kind(rawValue: name))
        return .init(id: try #require(value["id"]?.text), kind: kind,
            productId: try #require(value["productId"]?.text), name: try #require(value["name"]?.text), state: try #require(value["state"]?.text), type: try #require(value["type"]?.text), group: value["group"]?.text)
    }
    static func projection(_ input: JSONText) throws -> ProductPricePresentation {
        let schedule: ProductPriceSchedule?
        if let value = input["schedule"], value != .null {
            let rows = try array(value["rows"]).map { row in
                let name = try #require(row["source"]?.text), source = try #require(ProductPrice.Source(rawValue: name))
                return ProductPrice(id: try #require(row["id"]?.text), territory: try #require(row["territory"]?.text), currency: row["currency"]?.text, customerPrice: row["customerPrice"]?.text, proceeds: row["proceeds"]?.text,
                    startDate: row["startDate"]?.text, startKnown: try flag(row["startKnown"]), endDate: row["endDate"]?.text, endKnown: try flag(row["endKnown"]), source: source,
                    pricePointId: row["pricePointId"]?.text, preserved: row["preserved"] == .null ? nil : try flag(row["preserved"]), planType: row["planType"]?.text)
            }
            schedule = .init(baseTerritory: value["baseTerritory"]?.text, rows: rows, available: value["status"]?.text == "available", scheduleId: value["scheduleId"]?.text)
        } else { schedule = nil }
        let points = input["points"] == .null ? nil : try array(input["points"]).map { point in
            ProductPricePoint(id: try #require(point["id"]?.text), territory: try #require(point["territory"]?.text), currency: point["currency"]?.text, customerPrice: point["customerPrice"]?.text)
        }
        let active = input["activeTerritories"] == .null ? nil : try array(input["activeTerritories"]).map { try #require($0.text) }
        let kind = input["product"]?["kind"]?.text.flatMap { PriceProduct.Kind(rawValue: $0) }
        return .init(kind: kind, schedule: schedule, today: try #require(input["today"]?.text), activeTerritories: active, points: points, amount: try #require(input["amount"]?.text))
    }
}

@Suite struct ProductPricePresentationTests {
    init() throws { _ = try TestIsolation.require() }
    private func fixture() throws -> JSONText { try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/product-price-presentation.json"))) }
    @Test func completeRowsPhasesDatesUnknownsAndAmountSearchMatchThePrimaryPage() throws {
        let cases = try ProductPriceFixture.array(fixture()["cases"]); #expect(cases.count > 50)
        for value in cases {
            let projection = try ProductPriceFixture.projection(#require(value["input"]))
            #expect(projection.json == value["expected"], "Synthetic product price case: \(value["name"]?.text ?? "Unknown")")
            #expect(projection.current + projection.future + projection.other == projection.rows.count)
            #expect(projection.shownPoints.count <= 50)
        }
    }
    @Test func fullLargeSchedulesAreNeverLimitedToTheFirstTwoHundredPrices() throws {
        for value in try ProductPriceFixture.array(fixture()["benchmarks"]) {
            let projection = try ProductPriceFixture.projection(#require(value["input"]))
            #expect(projection.rows.count > 600)
            #expect(projection.json == value["expected"])
            #expect(projection.phases.count == 1200)
            #expect(projection.rows.allSatisfy { projection.phases[$0.key] != .past })
        }
    }
    @Test func equalResourceIdsInDifferentProductFamiliesHaveIndependentSelections() throws {
        let values = try ProductPriceFixture.array(fixture()["keys"])
        for value in values { #expect(try ProductPriceFixture.product(#require(value["product"])).selectionKey == value["key"]?.text) }
        #expect(values[0]["key"] != values[1]["key"])
    }
}
