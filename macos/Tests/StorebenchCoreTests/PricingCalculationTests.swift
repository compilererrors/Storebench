import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct PricingCalculationTests {
    init() throws { _ = try TestIsolation.require() }
    let now = Date(timeIntervalSince1970: 1_780_272_000)
    let countries = [Territory(code: "USA", name: "United States", currency: "USD"), Territory(code: "SWE", name: "Sweden", currency: "SEK"), Territory(code: "GBR", name: "United Kingdom", currency: "GBP")]
    func json(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value) }
    func observations(pages: Int = 1) -> Data {
        json([["page": 1, "pages": pages], [["countryiso3code": "USA", "date": "2025", "value": 1], ["countryiso3code": "SWE", "date": "2025", "value": 4], ["countryiso3code": "GBR", "date": "2025", "value": 0.5]]] as [Any])
    }
    func units() -> Data {
        let values = [("USA", "U.S. dollar"), ("SWE", "Swedish krona"), ("GBR", "Pound sterling")].map { code, unit in ["id": code, "metatype": [["id": "CurrencyUnit", "value": unit]]] as [String: Any] }
        return json(["page": 1, "pages": 1, "source": [["concept": [["variable": values]]]]])
    }
    func source(_ host: String) -> PricingSources {
        var sources = PricingSources(); sources.configuration.protocolClasses = [StubProtocol.self]; sources.builtIn = false
        sources.worldBank = URL(string: "https://\(host)/ppp")!; sources.worldBankCurrencies = URL(string: "https://\(host)/units")!
        sources.bigMac = URL(string: "https://\(host)/bigmac")!
        let observations = observations(), units = units()
        StubProtocol.handle(host) { request in
            #expect(request.httpMethod == "GET" && request.timeoutInterval == 6)
            if request.url!.path == "/ppp" { return (200, [:], observations) }
            if request.url!.path == "/units" { return (200, [:], units) }
            if request.url!.path == "/bigmac" { return (200, [:], Data("date,iso_a3,currency_code,local_price\n2026-01-01,USA,USD,2\n2026-01-01,SWE,SEK,8\n2026-01-01,GBR,GBP,1\n".utf8)) }
            Issue.record("Unexpected synthetic pricing source"); return (404, [:], Data())
        }
        return sources
    }

    @Test func backgroundWarmupPersistsBothIndexesAndCalculationsReuseThemWithoutNetworking() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let host = "warm-\(UUID().uuidString.lowercased()).pricing.test", sources = source(host)
        await session.preparePricingIndexes(sources: sources, now: now)
        #expect(StubProtocol.requests(host).count == 3)
        for method in [PricingMethod.ppp, .bigmac] {
            let snapshot = try await session.pricingIndex(method: method, catalog: countries, sources: sources, now: now.addingTimeInterval(60))
            #expect(snapshot.values.count == 3 && snapshot.cached && snapshot.fetchedAt != nil)
        }
        await session.preparePricingIndexes(sources: sources, now: now.addingTimeInterval(60))
        #expect(StubProtocol.requests(host).count == 3)
        let second = try WorkspaceSession(workspace: Workspace(root: root), vault: await session.vault)
        let snapshot = try await second.pricingIndex(method: .ppp, catalog: countries, sources: sources, now: now.addingTimeInterval(120))
        #expect(snapshot.cached && snapshot.values["SWE"] == "4")
        #expect(StubProtocol.requests(host).count == 3, "A restarted process reuses the encrypted index, not only an in-memory response")
    }

    @Test func failuresKeepValidatedDataAndBackOffWhileExpiredOrPartialDataIsRefused() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let host = "fallback-\(UUID().uuidString.lowercased()).pricing.test", sources = source(host)
        await session.preparePricingIndexes(sources: sources, now: now)
        StubProtocol.handle(host) { _ in (-1001, [:], Data()) }
        let later = now.addingTimeInterval(8 * 86_400)
        await session.preparePricingIndexes(sources: sources, now: later)
        let failed = StubProtocol.requests(host).count
        #expect(failed >= 2)
        await session.preparePricingIndexes(sources: sources, now: later.addingTimeInterval(60))
        let saved = try await session.pricingIndex(method: .ppp, catalog: countries, sources: sources, now: later)
        #expect(saved.cached && saved.values["USA"] == "1" && StubProtocol.requests(host).count == failed)
        await #expect(throws: PricingFailure.self) { try await session.pricingIndex(method: .ppp, catalog: countries, sources: sources, now: now.addingTimeInterval(367 * 86_400)) }
        #expect(throws: PricingFailure.self) { try PricingModels.worldBank(data: observations(pages: 2), metadata: units(), currencies: ["USA": "USD"]) }
    }

    @Test func oneOwnedIndexDownloadIsSharedByConcurrentReaders() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let host = "joined-\(UUID().uuidString.lowercased()).pricing.test", sources = source(host), catalog = countries, now = now
        let snapshots = try await withThrowingTaskGroup(of: IndexSnapshot.self) { group in
            for _ in 0..<8 { group.addTask { try await session.pricingIndex(method: .ppp, catalog: catalog, sources: sources, now: now) } }
            var values: [IndexSnapshot] = []; for try await value in group { values.append(value) }; return values
        }
        #expect(snapshots.count == 8 && snapshots.allSatisfy { $0.values["SWE"] == "4" })
        #expect(StubProtocol.requests(host).count == 2)
    }

    @Test func previewRequestsTerritoryRelationshipsAndReusesOnlyCompleteScopedPriceCatalogs() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), host = "points-\(UUID().uuidString.lowercased()).appstoreconnect.test"
        StubProtocol.handle(host) { request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            #expect(items.first { $0.name == "include" }?.value == "territory")
            #expect(items.first { $0.name == "fields[appPricePoints]" }?.value == "customerPrice,territory")
            #expect(request.httpMethod == "GET")
            let codes = items.first { $0.name == "filter[territory]" }!.value!.components(separatedBy: ",")
            let rows = codes.map { code in ["type": "appPricePoints", "id": "synthetic-\(code)", "attributes": ["customerPrice": "3.99"], "relationships": ["territory": ["data": ["type": "territories", "id": code]]]] as [String: Any] }
            return (200, [:], self.json(["data": rows, "links": [:]]))
        }
        let client = try PricingTests().stubbedClient(host, account)
        let first = try await session.previewPricePoints(.app("1000000001"), territories: ["USA", "SWE"], client: client, now: now)
        let second = try await session.previewPricePoints(.app("1000000001"), territories: ["SWE", "USA"], client: client, now: now.addingTimeInterval(60))
        #expect(first.failed.isEmpty && second.failed.isEmpty && second.points.count == 2 && StubProtocol.requests(host).count == 2, "Each country is read once, on its own")
        _ = try await session.previewPricePoints(.app("1000000002"), territories: ["USA"], client: client, now: now)
        #expect(StubProtocol.requests(host).count == 3, "Another product never reuses the first product's price point IDs")
        _ = try await session.previewPricePoints(.app("1000000001"), territories: ["USA"], client: client, now: now.addingTimeInterval(86_401))
        #expect(StubProtocol.requests(host).count == 4)
    }

    @Test func failedIndexStopsBeforeAnyAppleCatalogReadAndDeadlineCancelsTheOperation() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), host = "failed-index-\(UUID().uuidString.lowercased()).pricing.test", sources = source(host)
        StubProtocol.handle(host) { _ in (500, [:], Data()) }
        let appleHost = "no-catalog-\(UUID().uuidString.lowercased()).appstoreconnect.test", client = try PricingTests().stubbedClient(appleHost, account)
        StubProtocol.handle(appleHost) { _ in Issue.record("A failed index must not start Apple's full catalog download"); return (500, [:], Data()) }
        let profile = PricingProfile(id: "synthetic", name: "Synthetic PPP", guideTerritory: "USA", rounding: "nearest", method: "ppp", percentages: [:])
        await #expect(throws: PricingFailure.self) { try await session.modelPrices(.app("1000000001"), profile: profile, base: "4.99", countries: countries, guideCurrency: "USD", client: client, sources: sources) }
        #expect(StubProtocol.requests(appleHost).isEmpty)
        actor Probe { var cancelled = false; func record() { cancelled = true } }
        let probe = Probe(), start = ContinuousClock.now
        await #expect(throws: PricingFailure.self) {
            try await PricingCalculation.run(timeout: .milliseconds(30)) {
                do { try await Task.sleep(for: .seconds(30)); return 1 }
                catch { await probe.record(); throw error }
            }
        }
        #expect(await probe.cancelled && ContinuousClock.now - start < .seconds(2))
    }

    @Test func modelAmountsAppearBeforeAppleMatchingAndOnlyCountriesWithAnEstimateAreDownloaded() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), sourceHost = "model-\(UUID().uuidString.lowercased()).pricing.test", sources = source(sourceHost)
        let host = "model-\(UUID().uuidString.lowercased()).appstoreconnect.test", client = try PricingTests().stubbedClient(host, account)
        final class Probe: @unchecked Sendable {
            let lock = NSLock(); var estimates: [ModelPrice] = []
            func remember(_ rows: [ModelPrice]) { lock.withLock { estimates = rows } }
            var ready: Bool { lock.withLock { estimates.count == 4 } }
        }
        let probe = Probe()
        StubProtocol.handle(host) { request in
            #expect(probe.ready, "Local model amounts must be delivered before waiting for Apple's catalog")
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!, codes = items.first { $0.name == "filter[territory]" }!.value!.components(separatedBy: ",")
            #expect(codes.count == 1 && ["USA", "SWE", "GBR"].contains(codes[0]), "A country without an index observation must not cause a catalog download")
            let amounts = ["USA": "4.99", "SWE": "19.99", "GBR": "2.49"]
            let rows = codes.map { code in ["type": "appPricePoints", "id": "synthetic-\(code)", "attributes": ["customerPrice": amounts[code]!], "relationships": ["territory": ["data": ["type": "territories", "id": code]]]] as [String: Any] }
            return (200, [:], self.json(["data": rows, "links": [:]]))
        }
        let profile = PricingProfile(id: "synthetic-model", name: "Synthetic PPP", guideTerritory: "USA", rounding: "nearest", method: "ppp", percentages: [:])
        let catalog = countries + [Territory(code: "ALB", name: "Albania", currency: "EUR")]
        let result = try await session.modelPrices(.app("1000000001"), profile: profile, base: "4.99", countries: catalog, guideCurrency: "USD", client: client, sources: sources, estimated: { probe.remember($0) })
        #expect(result.points.count == 3 && result.rows.first { $0.territory == "SWE" }?.calculated == "19.96")
        #expect(result.rows.first { $0.territory == "ALB" }?.amount == nil)
        #expect(result.rows.first { $0.territory == "ALB" }?.problem?.contains("Index data unavailable") == true)
        _ = try await session.modelPrices(.app("1000000001"), profile: profile, base: "5.99", countries: catalog, guideCurrency: "USD", client: client, sources: sources)
        #expect(StubProtocol.requests(host).count == 3 && StubProtocol.requests(sourceHost).count == 2, "Changing only the guide amount is a local calculation")
    }

    @Test func dollarBillingUsesTheSameYearsOfficialConversionFactorWithoutMixingOtherIndicatorsOrYears() throws {
        let ppp = ["id": "PA.NUS.PPP"], market = ["id": "PA.NUS.FCRF"]
        let rows: [[String: Any]] = [
            ["indicator": ppp, "countryiso3code": "USA", "date": "2025", "value": 1],
            ["indicator": ppp, "countryiso3code": "SWE", "date": "2025", "value": 4],
            ["indicator": market, "countryiso3code": "SWE", "date": "2025", "value": 8],
            ["indicator": market, "countryiso3code": "USA", "date": "2025", "value": 1],
            ["indicator": ppp, "countryiso3code": "GBR", "date": "2025", "value": 0.5],
            ["indicator": market, "countryiso3code": "GBR", "date": "2024", "value": 0.8]]
        let data = json([["page": 1, "pages": 1], rows] as [Any])
        let converted = try PricingModels.worldBank(data: data, metadata: units(), currencies: ["USA": "USD", "SWE": "USD", "GBR": "USD"])
        #expect(converted.values == ["USA": "1", "SWE": "0.5"] && converted.source.contains("PA.NUS.FCRF"))
        let native = try PricingModels.worldBank(data: data, metadata: units(), currencies: ["USA": "USD", "SWE": "SEK", "GBR": "GBP"])
        #expect(native.values == ["USA": "1", "SWE": "4", "GBR": "0.5"], "Market factors must not replace PPP observations or change countries already using their national currency")
        let unsupported = try PricingModels.worldBank(data: data, metadata: units(), currencies: ["USA": "USD", "SWE": "EUR"])
        #expect(unsupported.values == ["USA": "1"], "A foreign currency without a supported conversion stays unavailable")
    }

    /// Synthetic pages of one country's rising price list, 200 points each, with Apple's cursor between them.
    func ladderPages(_ amounts: [String], territory: String = "SWE") -> (String, String?) async throws -> (resources: [AppStoreConnectClient.Resource], next: String?) {
        let pages = stride(from: 0, to: amounts.count, by: 200).map { Array(amounts[$0..<min($0 + 200, amounts.count)]) }
        return { _, cursor in
            let index = cursor.flatMap(Int.init) ?? 0
            let rows = pages[index].enumerated().map { offset, amount in
                AppStoreConnectClient.Resource(type: "appPricePoints", id: "synthetic-\(territory)-\(index)-\(offset)", attributes: ["customerPrice": .string(amount)],
                    relationships: ["territory": .object(["data": .object(["type": .string("territories"), "id": .string(territory)])])])
            }
            return (rows, index + 1 < pages.count ? String(index + 1) : nil)
        }
    }

    @Test func aRisingPriceListStopsOnceItReachesTheNeededAmountAndOtherwiseReadsEveryPage() async throws {
        let rising = (1...800).map { PricingMath.text(Decimal($0) / 10) }
        final class Count: @unchecked Sendable { let lock = NSLock(); var pages = 0; func add() { lock.withLock { pages += 1 } }; var value: Int { lock.withLock { pages } } }
        let count = Count(), source = ladderPages(rising)
        let early = try await PricePointCatalog.ladder(.app("1000000001"), territory: "SWE", through: 25, page: { count.add(); return try await source($0, $1) })
        #expect(!early.complete && count.value == 2 && early.points.count == 400, "25.00 is on the second page, so the third and fourth are never read")
        let nearest = PricingMath.select(territory: "SWE", calculated: Decimal(string: "24.96")!, rounding: "nearest", points: early.points).selected
        let up = PricingMath.select(territory: "SWE", calculated: Decimal(string: "24.96")!, rounding: "up", points: early.points).selected
        #expect(nearest?.customerPrice == "25" && up?.customerPrice == "25")
        let complete = try await PricePointCatalog.ladder(.app("1000000001"), territory: "SWE", through: nil, page: source)
        #expect(complete.complete && complete.points.count == 800)
        var shuffled = rising; shuffled.swapAt(10, 300)
        let unordered = try await PricePointCatalog.ladder(.app("1000000001"), territory: "SWE", through: 2, page: ladderPages(shuffled))
        #expect(unordered.complete && unordered.points.count == 800, "Pages that do not rise in price are read to the end")
    }

    @Test func aSavedPartialPriceListIsReusedOnlyWhenItReachesTheNeededAmount() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), host = "partial-\(UUID().uuidString.lowercased()).appstoreconnect.test"
        let amounts = (1...400).map { PricingMath.text(Decimal($0) / 10) }
        StubProtocol.handle(host) { request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let page = items.first { $0.name == "cursor" }?.value.flatMap(Int.init) ?? 0
            let rows = amounts[(page * 200)..<((page + 1) * 200)].enumerated().map { offset, amount in
                ["type": "appPricePoints", "id": "synthetic-swe-\(page)-\(offset)", "attributes": ["customerPrice": amount], "relationships": ["territory": ["data": ["type": "territories", "id": "SWE"]]]] as [String: Any]
            }
            var links: [String: Any] = [:]
            if page == 0 { links["next"] = "https://\(host)\(request.url!.path)?\(request.url!.query!)&cursor=1" }
            return (200, [:], self.json(["data": rows, "links": links]))
        }
        let client = try PricingTests().stubbedClient(host, account)
        let first = try await session.previewPricePoints(.app("1000000001"), territories: ["SWE"], needs: ["SWE": 5], client: client, now: now)
        #expect(first.points.count == 200 && StubProtocol.requests(host).count == 1)
        let again = try await session.previewPricePoints(.app("1000000001"), territories: ["SWE"], needs: ["SWE": 19], client: client, now: now.addingTimeInterval(60))
        #expect(again.points.count == 200 && StubProtocol.requests(host).count == 1, "The saved list reaches 20.00, so 19.00 needs no new read")
        let higher = try await session.previewPricePoints(.app("1000000001"), territories: ["SWE"], needs: ["SWE": 30], client: client, now: now.addingTimeInterval(120))
        #expect(higher.points.count == 400 && StubProtocol.requests(host).count == 3, "A higher amount reads the list again, past 20.00")
        let whole = try await session.previewPricePoints(.app("1000000001"), territories: ["SWE"], client: client, now: now.addingTimeInterval(180))
        #expect(whole.points.count == 400 && StubProtocol.requests(host).count == 3, "The last read was complete, so it serves any amount")
    }

    @Test func purchasingPowerUsesEachCountrysNewestYearAndPricesOtherBillingCurrenciesByPriceLevel() throws {
        let ppp = ["id": "PA.NUS.PPP"], market = ["id": "PA.NUS.FCRF"]
        let rows: [[String: Any]] = [
            ["indicator": ppp, "countryiso3code": "USA", "date": "2025", "value": 1], ["indicator": market, "countryiso3code": "USA", "date": "2025", "value": 1],
            ["indicator": ppp, "countryiso3code": "SWE", "date": "2025", "value": 4], ["indicator": market, "countryiso3code": "SWE", "date": "2025", "value": 10],
            ["indicator": ppp, "countryiso3code": "GBR", "date": "2022", "value": 0.5], ["indicator": ppp, "countryiso3code": "GBR", "date": "2025", "value": NSNull()]]
        let data = json([["page": 1, "pages": 1], rows] as [Any])
        let index = try PricingModels.worldBank(data: data, metadata: units(), currencies: ["USA": "USD", "SWE": "EUR", "GBR": "GBP"])
        #expect(index.date == "2025" && index.values["GBR"] == "0.5" && index.years == ["GBR": "2022"], "A country without this year's figure keeps its newest one")
        #expect(index.values["SWE"] == nil && index.levels["SWE"] == "0.4" && index.levels["USA"] == "1")
        let profile = PricingProfile(id: "synthetic", name: "Synthetic PPP", guideTerritory: "USA", rounding: "nearest", method: "ppp", percentages: [:])
        let catalog = [Territory(code: "USA", name: "United States", currency: "USD"), Territory(code: "SWE", name: "Sweden", currency: "EUR"),
                       Territory(code: "GBR", name: "United Kingdom", currency: "GBP"), Territory(code: "AIA", name: "Anguilla", currency: "USD"), Territory(code: "TWN", name: "Taiwan", currency: "TWD")]
        let rates = ["EUR": FxRate(rate: "0.9", date: "2026-06-01", source: "frankfurter", providers: nil, fetchedAt: nil)]
        let prices = try PricingModels.calculate(profile, base: "10", countries: catalog, guideCurrency: "USD", rates: rates, points: [], indexes: [index], convertsUncovered: true)
        func row(_ code: String) -> ModelPrice? { prices.first { $0.territory == code } }
        #expect(row("SWE")?.calculated == "3.6" && row("SWE")?.detail.contains("Price level: 0.4") == true, "Billed in euros: 10 × 0.4 price level × 0.9 EUR per USD")
        #expect(row("GBR")?.calculated == "5" && row("GBR")?.detail.contains("2022") == true)
        #expect(row("AIA")?.calculated == "10" && row("AIA")?.detail.contains("Converted at the exchange rate") == true, "A country the index does not cover keeps the guide value at the exchange rate")
        #expect(row("TWN")?.calculated == nil && row("TWN")?.problem?.contains("Index data unavailable") == true, "Without an exchange rate nothing is estimated")
        let strict = try PricingModels.calculate(profile, base: "10", countries: catalog, guideCurrency: "USD", rates: rates, points: [], indexes: [index])
        #expect(strict.first { $0.territory == "AIA" }?.calculated == nil, "Without the fallback, an uncovered country stays unavailable")
    }

    @Test func calculatedAmountsAreShownWithTheCurrencysUsualDecimals() {
        #expect(PricingMath.shown("2.2983320447971001511", currency: "USD") == "2.30")
        #expect(PricingMath.shown("349.6", currency: "JPY") == "350")
        #expect(PricingMath.shown("6.98072557", currency: "AUD") == "6.98")
        #expect(PricingMath.shown("12", currency: "SEK") == "12.00")
    }

    @Test func builtInObservationsPriceEveryCoveredCountryWhenNoDownloadOrSavedCopyCanBeRead() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let host = "offline-\(UUID().uuidString.lowercased()).pricing.test"
        var sources = source(host); sources.builtIn = true
        StubProtocol.handle(host) { _ in (-1009, [:], Data()) }
        let catalog = [Territory(code: "USA", name: "United States", currency: "USD"), Territory(code: "SWE", name: "Sweden", currency: "SEK"),
                       Territory(code: "IND", name: "India", currency: "INR"), Territory(code: "JPN", name: "Japan", currency: "JPY"), Territory(code: "DEU", name: "Germany", currency: "EUR")]
        for method in [PricingMethod.ppp, .bigmac] {
            let index = try await session.pricingIndex(method: method, catalog: catalog, sources: sources, now: now)
            #expect(index.builtIn && catalog.allSatisfy { index.values[$0.code] != nil }, "\(method.name) covers each large market from the built-in data")
        }
        sources.builtIn = false
        await #expect(throws: PricingFailure.self) { try await session.pricingIndex(method: .ppp, catalog: catalog, sources: sources, now: now) }
        let parsed = try #require(BuiltInPricingIndexes.data(.ppp)).snapshot(catalog: [], cached: true)
        #expect(parsed.values.count >= 150 && parsed.levels.count >= 150 && parsed.values["USA"] == "1")
    }

    @Test func bigMacUsesEachCountrysRecentObservationTheEuroAreaPriceAndDollarPrices() throws {
        let csv = """
        date,iso_a3,currency_code,local_price,dollar_ex
        2026-01-01,USA,USD,6,1
        2026-01-01,EUZ,EUR,5.4,0.9
        2026-01-01,ARG,ARS,3000,1000
        2025-01-01,SWE,SEK,60,10
        2023-01-01,NOR,NOK,70,10
        2026-01-01,FRA,EUR,6.3,0.9
        """
        let currencies = ["USA": "USD", "DEU": "EUR", "FRA": "EUR", "ARG": "USD", "SWE": "SEK", "NOR": "NOK"]
        let index = try PricingModels.bigMac(csv, currencies: currencies)
        #expect(index.date == "2026-01-01" && index.values["DEU"] == "5.4" && index.values["FRA"] == "6.3", "Euro members without their own row use the euro area price")
        #expect(index.values["SWE"] == "60" && index.years["SWE"] == "2025-01-01" && index.values["NOR"] == nil, "A country keeps its newest observation from the last two years")
        #expect(index.values["ARG"] == nil && index.levels["ARG"] == "3" && index.values["EUZ"] == nil)
        let profile = PricingProfile(id: "synthetic", name: "Synthetic Big Mac", guideTerritory: "USA", rounding: "nearest", method: "bigmac", percentages: [:])
        let catalog = ["USA", "DEU", "ARG", "SWE"].map { Territory(code: $0, name: $0, currency: currencies[$0]!) }
        let prices = try PricingModels.calculate(profile, base: "6", countries: catalog, guideCurrency: "USD", rates: [:], points: [], indexes: [index], convertsUncovered: true)
        #expect(prices.first { $0.territory == "DEU" }?.calculated == "5.4" && prices.first { $0.territory == "ARG" }?.calculated == "3", "Billed in dollars: the burger costs half as much in dollars, so the price is halved")
    }
}
