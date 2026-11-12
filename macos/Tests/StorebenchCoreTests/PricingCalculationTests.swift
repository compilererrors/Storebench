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
        var sources = PricingSources(); sources.configuration.protocolClasses = [StubProtocol.self]
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
        #expect(first.failed.isEmpty && second.failed.isEmpty && second.points.count == 2 && StubProtocol.requests(host).count == 1)
        _ = try await session.previewPricePoints(.app("1000000002"), territories: ["USA"], client: client, now: now)
        #expect(StubProtocol.requests(host).count == 2, "Another product never reuses the first product's price point IDs")
        _ = try await session.previewPricePoints(.app("1000000001"), territories: ["USA"], client: client, now: now.addingTimeInterval(86_401))
        #expect(StubProtocol.requests(host).count == 3)
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
            #expect(Set(codes) == ["USA", "SWE", "GBR"], "A country without an index observation must not cause a catalog download")
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
        #expect(StubProtocol.requests(host).count == 1 && StubProtocol.requests(sourceHost).count == 2, "Changing only the guide amount is a local calculation")
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
}
