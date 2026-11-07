import CryptoKit
import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct PricingTests {
    init() throws { _ = try TestIsolation.require() }
    @Test func revisionsAndRoundingMatchSyntheticReferenceResults() throws {
        let standard = PricingProfile(id: "standard", name: "Standard", guideTerritory: "USA", rounding: "nearest", method: "custom", percentages: [:])
        #expect(PricingModels.profileRevision(standard) == "b39b7d04f735db8c8eb39a34d84f9848edc09528920e1b2d3c50ae5dbedd7951")
        var custom = standard; custom.percentages = ["SWE": 85.5, "GBR": 90]
        #expect(PricingModels.profileRevision(custom) == "0c68a31009246c4d01eea00abdbf14cb54b8d0d77f064b0f4e7c8cd8cd54cfe5")
        let target = JSONText.object([("accountId", .string("acc-1")), ("appId", .string("1000000001")), ("profileId", .string("standard")), ("guideTerritory", .string("USA")),
                                      ("currency", .string("USD")), ("amount", .string("4.99")), ("updatedAt", .string("2026-01-01T00:00:00.000Z"))])
        #expect(WorkspaceSession.modelRevision(accountId: "acc-1", appId: "1000000001", profile: standard, target: target) == "eb2cadc087a4d0ea252f4e20986bfdb941a378401f967b4b00e0181808ddf662")
        #expect(try PricingMath.percentOf("9.99", percent: "85.5") == "8.5415")
        #expect(try PricingMath.percentOf("1.2345", percent: "33.33") == "0.4115")

        let points = ["8.49", "8.99", "9.49"].enumerated().map { PricePoint(id: "p\($0.offset)", territory: "SWE", customerPrice: $0.element) }
        #expect(PricingMath.select(territory: "SWE", calculated: Decimal(string: "8.74")!, rounding: "nearest", points: points).selected?.customerPrice == "8.99")
        #expect(PricingMath.select(territory: "SWE", calculated: Decimal(string: "8.74")!, rounding: "down", points: points).selected?.customerPrice == "8.49")
        #expect(PricingMath.select(territory: "SWE", calculated: Decimal(string: "8.74")!, rounding: "exact", points: points).selected == nil)

        // Your country percentages: 10 USD at 85.5 % and 10.5 SEK per USD gives 89.775 SEK, rounded to the nearest point.
        let rows = try PricingModels.calculate(custom, base: "10", countries: [Territory(code: "USA", name: "United States", currency: "USD"), Territory(code: "SWE", name: "Sweden", currency: "SEK"), Territory(code: "NOR", name: "Norway", currency: "NOK")],
                                               guideCurrency: "USD", rates: ["SEK": FxRate(rate: "10.5", date: "2026-03-01", source: "frankfurter", providers: nil, fetchedAt: nil)],
                                               points: [PricePoint(id: "a", territory: "SWE", customerPrice: "89"), PricePoint(id: "b", territory: "SWE", customerPrice: "99"), PricePoint(id: "c", territory: "USA", customerPrice: "9.99"), PricePoint(id: "d", territory: "USA", customerPrice: "10.99")], indexes: [])
        #expect(rows.map(\.territory) == ["USA", "SWE"])
        #expect(rows[1].calculated == "89.775" && rows[1].amount == "89" && rows[0].amount == "9.99")
    }

    func stubbedClient(_ host: String, _ account: Account) throws -> AppStoreConnectClient {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubProtocol.self]
        return AppStoreConnectClient(token: try AppleToken(account: account, privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation), origin: URL(string: "https://\(host)")!, configuration: configuration)
    }

    @Test func pricesAreReadAndCountryDraftsRespectProtection() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), app = "1000000001", host = "pricing.appstoreconnect.test"
        func page(_ data: Any, included: [Any] = []) -> (Int, [String: String], Data) { (200, [:], try! JSONSerialization.data(withJSONObject: ["data": data, "included": included, "links": [:]])) }
        StubProtocol.handle(host) { request in
            switch request.url!.path {
            case "/v1/apps/1000000001/appPriceSchedule": return page(["type": "appPriceSchedules", "id": "schedule-1"])
            case "/v1/appPriceSchedules/schedule-1/baseTerritory": return page(["type": "territories", "id": "USA", "attributes": ["currency": "USD"]])
            case "/v1/appPriceSchedules/schedule-1/manualPrices":
                return page([["type": "appPrices", "id": "price-usa", "attributes": ["startDate": NSNull(), "endDate": NSNull()], "relationships": ["territory": ["data": ["type": "territories", "id": "USA"]], "appPricePoint": ["data": ["type": "appPricePoints", "id": "pp-usa"]]]]],
                            included: [["type": "territories", "id": "USA", "attributes": ["currency": "USD"]], ["type": "appPricePoints", "id": "pp-usa", "attributes": ["customerPrice": "4.99", "proceeds": "3.49"]]])
            case "/v1/appPriceSchedules/schedule-1/automaticPrices":
                return page([["type": "appPrices", "id": "price-swe", "attributes": [:], "relationships": ["territory": ["data": ["type": "territories", "id": "SWE"]], "appPricePoint": ["data": ["type": "appPricePoints", "id": "pp-swe"]]]]],
                            included: [["type": "territories", "id": "SWE", "attributes": ["currency": "SEK"]], ["type": "appPricePoints", "id": "pp-swe", "attributes": ["customerPrice": 55, "proceeds": "33.6"]]])
            case "/v1/apps/1000000001/appPricePoints":
                return page([["type": "appPricePoints", "id": "a", "attributes": ["customerPrice": "45"], "relationships": ["territory": ["data": ["type": "territories", "id": "SWE"]]]],
                             ["type": "appPricePoints", "id": "b", "attributes": ["customerPrice": "49"], "relationships": ["territory": ["data": ["type": "territories", "id": "SWE"]]]]])
            default: Issue.record("Unexpected \(request.url!.path)"); return (404, [:], Data())
            }
        }
        let client = try stubbedClient(host, account)
        let snapshot = try await session.refreshPricing(account: account, appId: app, client: client)
        #expect(snapshot.baseCurrency == "USD" && snapshot.rows.map(\.territory) == ["SWE", "USA"] && snapshot.rows[0].customerPrice == "55" && snapshot.rows[0].source == "automatic")
        #expect(try await session.savedPricing(accountId: account.id, appId: app)?.snapshot == snapshot)
        let current = PricingMath.current(snapshot.rows, today: "2026-03-01")

        let points = try await session.pricePoints(appId: app, territories: ["SWE"], client: client)
        let reduced = try PricingMath.roundedPercent(current["SWE"]!.customerPrice, percent: "85", territory: "SWE", rounding: "nearest", points: points)
        #expect(reduced == "45")
        _ = try await session.saveCountryDrafts(accountId: account.id, appId: app, amounts: [("SWE", "SEK", reduced)], startDate: nil, endDate: nil)
        _ = try await session.saveCountryDrafts(accountId: account.id, appId: app, amounts: [("SWE", "SEK", "49")], startDate: nil, endDate: nil)
        #expect(try await session.pricingDrafts(accountId: account.id, appId: app).map(\.amount) == ["49"])
        _ = try await session.saveCountryDrafts(accountId: account.id, appId: app, amounts: [("SWE", "SEK", "45")], startDate: "2026-04-01", endDate: "2026-04-07")
        await #expect(throws: PricingFailure.invalid("Temporary price dates overlap for a country.")) {
            try await session.saveCountryDrafts(accountId: account.id, appId: app, amounts: [("SWE", "SEK", "45")], startDate: "2026-04-05", endDate: "2026-04-10")
        }
        try await session.protectPrices(accountId: account.id, appId: app, prices: [("USA", "4.99", "USD")])
        await #expect(throws: PricingFailure.selection) { try await session.saveCountryDrafts(accountId: account.id, appId: app, amounts: [("USA", "USD", "3.99")], startDate: nil, endDate: nil) }
        try await session.unprotectPrice(accountId: account.id, appId: app, territory: "USA")
        #expect(try await session.priceProtection(accountId: account.id, appId: app).isEmpty)
        let draft = try #require(try await session.pricingDrafts(accountId: account.id, appId: app).first)
        try await session.removePricingDraft(accountId: account.id, appId: app, id: draft.id)
        #expect(try await session.pricingDrafts(accountId: account.id, appId: app).count == 1)
    }

    @Test func profilesTargetsAndRatesFollowTheirRevisions() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), app = "1000000001"
        let (defaultId, profiles) = try await session.pricingProfiles()
        #expect(defaultId == "standard" && profiles.map(\.name) == ["Standard"])
        var edited = profiles[0]; edited.percentages = ["swe": 80]; edited.method = "custom"
        try await session.updatePricingProfile("save", id: "standard", profile: edited, revision: PricingModels.profileRevision(profiles[0]))
        await #expect(throws: PricingFailure.stale) { try await session.updatePricingProfile("save", id: "standard", profile: edited, revision: PricingModels.profileRevision(profiles[0])) }
        let saved = try #require(try await session.pricingProfiles().profiles.first)
        #expect(saved.percentages == ["SWE": 80])

        let model = try #require(try await session.appPricingModel(accountId: account.id, appId: app, profileId: "standard", currency: "USD"))
        #expect(model.base == "")
        var own = model.profile; own.method = "fx"
        let revision = try await session.savePricingTarget(accountId: account.id, appId: app, profileId: "standard", currency: "USD", amount: "4.99", model: own, revision: model.revision)
        let reloaded = try #require(try await session.appPricingModel(accountId: account.id, appId: app, profileId: "standard", currency: "USD"))
        #expect(reloaded.base == "4.99" && reloaded.profile.method == "fx" && reloaded.revision == revision)
        await #expect(throws: PricingFailure.stale) { try await session.savePricingTarget(accountId: account.id, appId: app, profileId: "standard", currency: "USD", amount: "5.99", model: nil, revision: model.revision) }

        var sources = PricingSources()
        sources.frankfurter = URL(string: "https://rates.pricing.test/v2/rates")!; sources.exchangeRates = URL(string: "https://backup.pricing.test/v6/latest/")!
        sources.configuration.protocolClasses = [StubProtocol.self]
        StubProtocol.handle("rates.pricing.test") { request in
            #expect(request.url!.query?.contains("base=USD") == true)
            return (200, [:], try! JSONSerialization.data(withJSONObject: [["base": "USD", "quote": "SEK", "date": "2026-03-01", "rate": 10.5, "providers": ["ecb"]], ["base": "USD", "quote": "EUR", "date": "2026-03-01", "rate": 0.92]]))
        }
        StubProtocol.handle("backup.pricing.test") { _ in (500, [:], Data()) }
        let now = Date(timeIntervalSince1970: 1_772_400_000)
        let first = try await session.fxRates(base: "USD", quotes: ["SEK", "USD"], sources: sources, now: now)
        #expect(first.rates["SEK"]?.rate == "10.5" && first.missing.isEmpty)
        let second = try await session.fxRates(base: "USD", quotes: ["EUR"], sources: sources, now: now.addingTimeInterval(60))
        #expect(second.rates["EUR"]?.rate == "0.92" && StubProtocol.requests("rates.pricing.test").count == 1)
    }

    @Test func indexDataParsesSyntheticCSVValues() throws {
        let csv = "date,iso_a3,currency_code,local_price,dollar_ex\n2025-07-01,SWE,SEK,62,9.5\n2026-01-01,SWE,SEK,64,9.6\n2026-01-01,USA,USD,5.79,1\n2026-01-01,XXX,EUR,4,1\n"
        let index = try PricingModels.bigMac(csv, currencies: ["SWE": "SEK", "USA": "USD"])
        #expect(index.date == "2026-01-01" && index.values == ["SWE": "64", "USA": "5.79"])
    }
}
