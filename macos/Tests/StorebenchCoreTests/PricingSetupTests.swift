import CryptoKit
import Foundation
import Testing
@testable import StorebenchCore

/// A synthetic App Store Connect for pricing setup: one app that starts with no price and no products. Synthetic resources only.
final class SyntheticPricingApple: @unchecked Sendable {
    let lock = NSLock()
    let app = "1000000001"
    static let currencies = ["USA": "USD", "FRA": "EUR"]
    static let appPoints: [String: [(String, String)]] = ["USA": [("app-pp-usa-0", "0.0"), ("app-pp-usa-099", "0.99"), ("app-pp-usa-499", "4.99")], "FRA": [("app-pp-fra-0", "0.0"), ("app-pp-fra-099", "0.99")]]
    static let subscriptionPoints: [String: [(String, String)]] = ["USA": [("sub-pp-usa-299", "2.99"), ("sub-pp-usa-499", "4.99")], "FRA": [("sub-pp-fra-299", "2.99"), ("sub-pp-fra-499", "4.99")]]
    var base = "USA"
    var manual: [(id: String, start: String?, end: String?, point: String)] = []
    var purchases: [[String: Any]] = []
    var groups: [[String: Any]] = []
    var subscriptions: [[String: Any]] = []
    var subscriptionPrices: [(subscription: String, resource: [String: Any])] = []
    var offers: [String: [[String: Any]]] = [:]
    var writes: [(method: String, path: String, body: [String: Any])] = []
    var counter = 0
    /// Product availability by product id, versions by owner id and localizations by version id.
    var availabilities: [String: [String: Any]] = [:]
    /// The countries or regions of each product availability, and whether the app itself has App Availability.
    var availableTerritories: [String: [String]] = [:]
    var appAvailable = false
    /// A subscription price point Apple refuses, to check how a review with several countries or regions stops.
    var refusedPoint: String?
    var versions: [String: [[String: Any]]] = [:]
    var localizations: [String: [[String: Any]]] = [:]

    func json(_ status: Int, _ object: Any) -> (Int, [String: String], Data) { (status, ["Content-Type": "application/json"], try! JSONSerialization.data(withJSONObject: object)) }
    func page(_ data: Any, included: [[String: Any]] = []) -> (Int, [String: String], Data) { json(200, ["data": data, "included": included, "links": [:]]) }
    func rel(_ type: String, _ id: String) -> [String: Any] { ["data": ["type": type, "id": id]] }
    func territory(_ code: String) -> [String: Any] { ["type": "territories", "id": code, "attributes": ["currency": Self.currencies[code]!]] }
    func next(_ prefix: String) -> String { counter += 1; return "\(prefix)-\(counter)" }
    static func territory(ofPoint id: String) -> String { id.contains("-fra-") ? "FRA" : "USA" }
    static func amount(_ points: [String: [(String, String)]], _ id: String) -> String { points.values.flatMap { $0 }.first { $0.0 == id }?.1 ?? "0" }

    func handle(_ request: URLRequest) -> (Int, [String: String], Data) {
        lock.lock(); defer { lock.unlock() }
        let url = request.url!, path = url.path, method = request.httpMethod ?? "GET"
        let filter = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "filter[territory]" }?.value
        if method != "GET" { return write(method, path, (try? JSONSerialization.jsonObject(with: StubProtocol.body(request))) as? [String: Any] ?? [:]) }
        let parts = path.split(separator: "/").map(String.init)
        switch path {
        case "/v1/apps/1000000001": return page(["type": "apps", "id": app])
        case "/v1/apps/1000000001/appPriceSchedule":
            return manual.isEmpty ? json(404, ["errors": [["status": "404", "code": "NOT_FOUND"]]]) : page(["type": "appPriceSchedules", "id": "schedule-1", "relationships": ["app": rel("apps", app)]])
        case "/v1/appPriceSchedules/schedule-1/manualPrices":
            let rows: [[String: Any]] = manual.map { ["type": "appPrices", "id": $0.id, "attributes": ["startDate": $0.start.map { $0 as Any } ?? NSNull(), "endDate": $0.end.map { $0 as Any } ?? NSNull()],
                                                       "relationships": ["appPricePoint": rel("appPricePoints", $0.point), "territory": rel("territories", Self.territory(ofPoint: $0.point))]] }
            let points: [[String: Any]] = Set(manual.map(\.point)).sorted().map { ["type": "appPricePoints", "id": $0, "attributes": ["customerPrice": Self.amount(Self.appPoints, $0), "proceeds": "0.5"]] }
            return page(rows, included: points + Set(manual.map { Self.territory(ofPoint: $0.point) }).sorted().map(territory))
        case "/v1/appPriceSchedules/schedule-1/automaticPrices": return page([])
        case "/v1/appPriceSchedules/schedule-1/baseTerritory": return page(territory(base))
        case "/v1/territories": return page(["USA", "FRA"].map(territory))
        case "/v1/apps/1000000001/appPricePoints":
            let code = filter ?? "USA"
            return page((Self.appPoints[code] ?? []).map { ["type": "appPricePoints", "id": $0.0, "attributes": ["customerPrice": $0.1], "relationships": ["territory": rel("territories", code)]] }, included: [territory(code)])
        case "/v1/apps/1000000001/inAppPurchasesV2": return page(purchases)
        case "/v1/apps/1000000001/subscriptionGroups": return page(groups)
        case "/v1/apps/1000000001/appAvailabilityV2":
            return appAvailable ? page(["type": "appAvailabilities", "id": "app-availability-1", "attributes": ["availableInNewTerritories": true]]) : json(404, ["errors": [["status": "404", "code": "NOT_FOUND"]]])
        default: break
        }
        // A subscription that already has prices is available where it has them, as Apple requires.
        if parts.count == 4, ["subscriptionAvailability", "inAppPurchaseAvailability"].contains(parts[3]) {
            if let stored = availabilities[parts[2]] { return page(stored) }
            if subscriptionPrices.contains(where: { $0.subscription == parts[2] }) { return page(["type": "subscriptionAvailabilities", "id": "priced-\(parts[2])", "attributes": ["availableInNewTerritories": true]]) }
            return json(404, ["errors": [["status": "404", "code": "NOT_FOUND"]]])
        }
        if parts.count == 4, ["subscriptionAvailabilities", "inAppPurchaseAvailabilities"].contains(parts[1]), parts[3] == "availableTerritories" {
            return page((availableTerritories[parts[2]] ?? ["FRA", "USA"]).map(territory))
        }
        if parts.count == 4, parts[3] == "versions" { return page(versions[parts[2]] ?? []) }
        if parts.count == 4, parts[3] == "localizations" { return page(localizations[parts[2]] ?? []) }
        if parts.count == 4, ["appStoreReviewScreenshot", "image"].contains(parts[3]) { return json(404, ["errors": [["status": "404", "code": "NOT_FOUND"]]]) }
        if parts.count == 4, parts[1] == "subscriptionGroups", parts[3] == "subscriptions" {
            return page(subscriptions.filter { (($0["relationships"] as? [String: Any])?["group"] as? [String: Any]).flatMap { $0["data"] as? [String: Any] }?["id"] as? String == parts[2] })
        }
        if parts.count == 4, parts[0] == "v2", parts[3] == "iapPriceSchedule" { return json(404, ["errors": [["status": "404", "code": "NOT_FOUND"]]]) }
        if parts.count == 4, parts[1] == "subscriptions", parts[3] == "prices" {
            let rows = subscriptionPrices.filter { $0.subscription == parts[2] }.map(\.resource).filter { row in
                filter == nil || ((row["relationships"] as? [String: Any])?["territory"] as? [String: Any]).flatMap { $0["data"] as? [String: Any] }?["id"] as? String == filter
            }
            let points = rows.compactMap { (($0["relationships"] as? [String: Any])?["subscriptionPricePoint"] as? [String: Any]).flatMap { $0["data"] as? [String: Any] }?["id"] as? String }
            return page(rows, included: Set(points).sorted().map { ["type": "subscriptionPricePoints", "id": $0, "attributes": ["customerPrice": Self.amount(Self.subscriptionPoints, $0), "proceeds": "2.0"], "relationships": ["territory": rel("territories", Self.territory(ofPoint: $0))]] } + ["USA", "FRA"].map(territory))
        }
        if parts.count == 4, parts[1] == "subscriptions", parts[3] == "pricePoints" {
            let codes = (filter ?? "USA").split(separator: ",").map(String.init)
            return page(codes.flatMap { code in (Self.subscriptionPoints[code] ?? []).map { ["type": "subscriptionPricePoints", "id": $0.0, "attributes": ["customerPrice": $0.1], "relationships": ["territory": rel("territories", code)]] } },
                        included: codes.filter { Self.currencies[$0] != nil }.map(territory))
        }
        if parts.count == 4, parts[1] == "subscriptionPricePoints", parts[3] == "equalizations" {
            let suffix = parts[2].split(separator: "-").last.map(String.init) ?? ""
            let others = Self.subscriptionPoints.filter { $0.key != Self.territory(ofPoint: parts[2]) }.flatMap { code, points in points.filter { $0.0.hasSuffix("-" + suffix) }.map { (code, $0) } }
            return page(others.map { ["type": "subscriptionPricePoints", "id": $0.1.0, "attributes": ["customerPrice": $0.1.1], "relationships": ["territory": rel("territories", $0.0)]] }, included: others.map { territory($0.0) })
        }
        if parts.count == 4, parts[1] == "subscriptions" {
            let roots = ["introductoryOffers": "subscriptionIntroductoryOffers", "promotionalOffers": "subscriptionPromotionalOffers", "offerCodes": "subscriptionOfferCodes", "winBackOffers": "winBackOffers"]
            guard let root = roots[parts[3]] else { return json(404, [:]) }
            return page((offers[root] ?? []).filter { (($0["relationships"] as? [String: Any])?["subscription"] as? [String: Any]).flatMap { $0["data"] as? [String: Any] }?["id"] as? String == parts[2] })
        }
        return json(404, ["errors": [["status": "404", "code": "NOT_FOUND"]]])
    }

    private func write(_ method: String, _ path: String, _ body: [String: Any]) -> (Int, [String: String], Data) {
        writes.append((method, path, body))
        let data = body["data"] as? [String: Any] ?? [:], attributes = data["attributes"] as? [String: Any] ?? [:], relationships = data["relationships"] as? [String: Any] ?? [:]
        func linked(_ name: String) -> String? { ((relationships[name] as? [String: Any])?["data"] as? [String: Any])?["id"] as? String }
        switch (method, path) {
        case ("POST", "/v1/appPriceSchedules"):
            base = linked("baseTerritory") ?? base
            manual = ((body["included"] as? [[String: Any]]) ?? []).map { item in
                let fields = item["attributes"] as? [String: Any] ?? [:], point = (((item["relationships"] as? [String: Any])?["appPricePoint"] as? [String: Any])?["data"] as? [String: Any])?["id"] as? String ?? ""
                return (next("app-price"), fields["startDate"] as? String, fields["endDate"] as? String, point)
            }
            return json(201, ["data": ["type": "appPriceSchedules", "id": "schedule-1"]])
        case ("POST", "/v2/inAppPurchases"):
            var fields = attributes; fields["state"] = "MISSING_METADATA"
            let created: [String: Any] = ["type": "inAppPurchases", "id": next("iap"), "attributes": fields]; purchases.append(created)
            return json(201, ["data": created])
        case ("POST", "/v1/subscriptionGroups"):
            let created: [String: Any] = ["type": "subscriptionGroups", "id": next("group"), "attributes": attributes]; groups.append(created)
            return json(201, ["data": created])
        case ("POST", "/v1/subscriptions"):
            var fields = attributes; fields["state"] = "MISSING_METADATA"
            let created: [String: Any] = ["type": "subscriptions", "id": next("sub"), "attributes": fields, "relationships": ["group": rel("subscriptionGroups", linked("group") ?? "")]]; subscriptions.append(created)
            return json(201, ["data": created])
        case ("POST", "/v1/subscriptionPrices"):
            let point = linked("subscriptionPricePoint") ?? ""
            if point == refusedPoint { return json(409, ["errors": [["status": "409", "code": "ENTITY_ERROR.ATTRIBUTE.INVALID", "title": "Invalid", "detail": "This price is not allowed."]]]) }
            let created: [String: Any] = ["type": "subscriptionPrices", "id": next("sub-price"), "attributes": ["startDate": attributes["startDate"] ?? NSNull(), "preserved": false],
                                          "relationships": ["subscriptionPricePoint": rel("subscriptionPricePoints", point), "territory": rel("territories", Self.territory(ofPoint: point))]]
            subscriptionPrices.append((linked("subscription") ?? "", created))
            return json(201, ["data": created])
        case ("POST", "/v1/subscriptionAvailabilities"), ("POST", "/v1/inAppPurchaseAvailabilities"):
            let owner = linked("subscription") ?? linked("inAppPurchase") ?? ""
            let created: [String: Any] = ["type": String(path.dropFirst(4)), "id": next("availability"), "attributes": attributes]; availabilities[owner] = created
            availableTerritories[created["id"] as! String] = ((relationships["availableTerritories"] as? [String: Any])?["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            return json(201, ["data": created])
        case ("POST", "/v2/appAvailabilities"):
            appAvailable = true
            return json(201, ["data": ["type": "appAvailabilities", "id": "app-availability-1"]])
        case ("POST", "/v1/subscriptionVersions"), ("POST", "/v1/inAppPurchaseVersions"), ("POST", "/v1/subscriptionGroupVersions"):
            let owner = linked("subscription") ?? linked("inAppPurchase") ?? linked("subscriptionGroup") ?? ""
            let created: [String: Any] = ["type": String(path.dropFirst(4)), "id": next("version"), "attributes": ["version": (versions[owner]?.count ?? 0) + 1, "state": "PREPARE_FOR_SUBMISSION"]]
            versions[owner, default: []].append(created)
            return json(201, ["data": created])
        case ("POST", let target) where target.hasPrefix("/v2/") && target.hasSuffix("Localizations"):
            let created: [String: Any] = ["type": String(target.dropFirst(4)), "id": next("localization"), "attributes": attributes]
            localizations[linked("version") ?? "", default: []].append(created)
            return json(201, ["data": created])
        case ("PATCH", let target) where target.hasPrefix("/v2/") && target.contains("Localizations/"):
            let id = String(target.split(separator: "/").last ?? "")
            for (version, items) in localizations { if let index = items.firstIndex(where: { $0["id"] as? String == id }) {
                var fields = items[index]["attributes"] as? [String: Any] ?? [:]; for (key, value) in attributes { fields[key] = value }
                localizations[version]![index]["attributes"] = fields; return json(200, ["data": localizations[version]![index]])
            } }
            return json(404, [:])
        case ("PATCH", let target) where target.hasPrefix("/v1/subscriptions/"):
            let id = String(target.dropFirst("/v1/subscriptions/".count))
            for item in (body["included"] as? [[String: Any]]) ?? [] {
                let links = item["relationships"] as? [String: Any] ?? [:]
                func link(_ name: String) -> String? { ((links[name] as? [String: Any])?["data"] as? [String: Any])?["id"] as? String }
                if item["type"] as? String == "subscriptionPrices", let point = link("subscriptionPricePoint") {
                    let fields = item["attributes"] as? [String: Any] ?? [:]
                    subscriptionPrices.append((id, ["type": "subscriptionPrices", "id": next("sub-price"), "attributes": ["startDate": fields["startDate"] ?? NSNull(), "preserved": fields["preserveCurrentPrice"] ?? false],
                                                    "relationships": ["subscriptionPricePoint": rel("subscriptionPricePoints", point), "territory": rel("territories", Self.territory(ofPoint: point))]]))
                } else if item["type"] as? String == "subscriptionIntroductoryOffers", let code = link("territory") {
                    offers["subscriptionIntroductoryOffers", default: []].append(["type": "subscriptionIntroductoryOffers", "id": next("offer"), "attributes": item["attributes"] ?? [:],
                                                                                   "relationships": ["subscription": rel("subscriptions", id), "territory": rel("territories", code)]])
                }
            }
            return json(200, ["data": subscriptions.first { $0["id"] as? String == id } ?? [:]])
        case ("POST", let root) where ["/v1/subscriptionIntroductoryOffers", "/v1/subscriptionPromotionalOffers", "/v1/subscriptionOfferCodes", "/v1/winBackOffers"].contains(root):
            let type = String(root.dropFirst(4))
            var links: [String: Any] = ["subscription": rel("subscriptions", linked("subscription") ?? "")]
            if let code = linked("territory") { links["territory"] = rel("territories", code) }
            let created: [String: Any] = ["type": type, "id": next("offer"), "attributes": attributes, "relationships": links]; offers[type, default: []].append(created)
            return json(201, ["data": created])
        default: return json(404, [:])
        }
    }
}

@Suite(.serialized) struct PricingSetupTests {
    init() throws { _ = try TestIsolation.require() }
    let app = "1000000001"
    func client(_ account: Account, host: String) throws -> AppStoreConnectClient {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubProtocol.self]
        return AppStoreConnectClient(token: try AppleToken(account: account, privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation), origin: URL(string: "https://\(host)")!, configuration: configuration)
    }
    func day(_ offset: Int) -> String { ReportTables.dayFormat.string(from: Date().addingTimeInterval(Double(offset) * 86_400)) }
    func request(_ account: Account, _ change: PricingSetupChange) -> PublishRequest {
        var value = PublishRequest(accountId: account.id, appId: app, scope: .pricingSetup); value.pricingSetup = change; return value
    }

    @Test func modelsAreDetectedFromAppleAndTheGuideFollowsTheChosenModel() {
        let product = PriceProduct(id: "sub-1", kind: .subscription, productId: "com.example.monthly", name: "Monthly", state: "MISSING_METADATA", type: "ONE_MONTH", group: "Premium")
        let empty = PricingSetupState(appPrice: .none, purchases: [], subscriptions: [], groups: [], priced: [])
        #expect(empty.empty && PricingSetup.detect(empty) == nil && PricingSetup.shown(chosen: nil, state: empty) == nil)
        #expect(PricingSetup.detect(PricingSetupState(appPrice: .paid(territory: "USA", amount: "4.99", currency: "USD"), purchases: [], subscriptions: [], groups: [], priced: [])) == .paid)
        #expect(PricingSetup.detect(PricingSetupState(appPrice: .free(territory: "USA"), purchases: [], subscriptions: [], groups: [], priced: [])) == .free)
        let subscribed = PricingSetupState(appPrice: .free(territory: "USA"), purchases: [], subscriptions: [product], groups: [.init(id: "group-1", referenceName: "Premium")], priced: [])
        #expect(PricingSetup.detect(subscribed) == .subscriptions)
        #expect(PricingSetup.detect(PricingSetupState(appPrice: .unknown, purchases: [], subscriptions: [], groups: [], priced: [])) == nil)
        #expect(PricingSetup.nextStep(.subscriptions, state: empty)?.task == .createSubscription)
        #expect(PricingSetup.done(.freePrice, state: PricingSetupState(appPrice: .paid(territory: "USA", amount: "4.99", currency: "USD"), purchases: [], subscriptions: [], groups: [], priced: [])))
        #expect(PricingSetup.nextStep(.subscriptions, state: subscribed)?.task == .createSubscription)
        let priced = PricingSetupState(appPrice: .free(territory: "USA"), purchases: [], subscriptions: [product], groups: [.init(id: "group-1", referenceName: "Premium")], priced: ["sub-1"])
        #expect(PricingSetup.nextStep(.subscriptions, state: priced) == nil)
        #expect(PricingSetup.steps(.paidWithInAppPurchases).map(\.task) == [.appPrice, .createPurchase])
        #expect(PricingSetup.steps(.subscriptions).map(\.task) == [.createSubscription, .freePrice, .introductoryOffer])
        let change = PricingSetup.changes(from: .paid, to: .free, state: PricingSetupState(appPrice: .paid(territory: "USA", amount: "4.99", currency: "USD"), purchases: [], subscriptions: [], groups: [], priced: []))
        #expect(change.first?.contains("Free") == true && change.last?.contains("Nothing is sent to Apple") == true)
    }

    @Test func requestsAcceptOnlyTheFieldsOfTheirPricingChange() throws {
        var purchase = PricingSetupChange(action: .createInAppPurchase); purchase.name = "  Coins  "; purchase.productId = "com.example.coins"; purchase.productType = "CONSUMABLE"
        #expect(try purchase.validated().name == "Coins")
        var extra = purchase; extra.pricePointId = "app-pp-usa-099"
        #expect(throws: PublishFailure.self) { try extra.validated() }
        var badId = purchase; badId.productId = "com example coins"
        #expect(throws: PublishFailure.self) { try badId.validated() }
        var trial = PricingSetupChange(action: .introductoryOffer); trial.subscriptionId = "sub-1"; trial.territory = "USA"; trial.allTerritories = true; trial.offerMode = "FREE_TRIAL"; trial.duration = "ONE_WEEK"; trial.periods = 1
        _ = try trial.validated()
        var pricedTrial = trial; pricedTrial.pricePointId = "sub-pp-usa-299"
        #expect(throws: PublishFailure.self) { try pricedTrial.validated() }
        var plan = SubscriptionPlan(); plan.name = "Monthly"; plan.productId = "com.example.monthly"
        var both = PricingSetupChange(action: .createSubscription); both.plans = [plan]; both.groupId = "group-1"; both.groupName = "Premium"
        #expect(throws: PublishFailure.self) { try both.validated() }
        var twice = PricingSetupChange(action: .createSubscription); twice.plans = [plan, plan]; twice.groupName = "Premium"
        #expect(throws: PublishFailure.self) { try twice.validated() }
        var family = purchase; family.familySharing = true
        #expect(throws: PublishFailure.self) { try family.validated() }
        family.productType = "NON_CONSUMABLE"; _ = try family.validated()
        var sale = PricingSetupChange(action: .appPrice); sale.territory = "USA"; sale.pricePointId = "app-pp-usa-499"; sale.salePointId = "app-pp-usa-099"; sale.startDate = day(1)
        #expect(throws: PublishFailure.self) { try sale.validated() }
        sale.endDate = day(5); sale.changePointId = "app-pp-usa-099"; sale.changeDate = day(4)
        #expect(throws: PublishFailure.self) { try sale.validated() }
        sale.changeDate = day(6); _ = try sale.validated()
        var setup = PricingSetupChange(action: .subscriptionSetup); setup.territory = "USA"; setup.allTerritories = true
        var priced = plan; priced.subscriptionId = "sub-1"; priced.amount = "2.99"; priced.offerMode = "PAY_UP_FRONT"; priced.offerDuration = "ONE_MONTH"; priced.offerPeriods = 1
        setup.plans = [priced]
        #expect(throws: PublishFailure.self) { try setup.validated() }
        setup.plans![0].offerAmount = "0.99"; _ = try setup.validated()
        var mixed = PublishRequest(accountId: "synthetic-account", appId: app, scope: .productPricing); mixed.pricingSetup = purchase
        #expect(throws: PublishFailure.self) { try mixed.validated() }
        let stored = try #require(PublishRequest(PublishRequest(accountId: "synthetic-account", appId: app, scope: .pricingSetup).with(trial).json))
        #expect(stored.pricingSetup == trial)
    }

    @Test func aNewSubscriptionAppIsSetUpThroughApprovedReviewsOnly() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticPricingApple(), host = "pricing-setup.appstoreconnect.test"
        StubProtocol.handle(host) { apple.handle($0) }
        let client = try client(account, host: host)
        func publish(_ change: PricingSetupChange) async throws -> PublishReview {
            let review = try await session.preparePublishing(account: account, request: request(account, change), client: client)
            return try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: client)
        }

        let empty = try await session.pricingSetupState(account: account, appId: app, client: client)
        #expect(empty.empty && PricingSetup.detect(empty) == nil)
        try await session.choosePricingModel(.subscriptions, accountId: account.id, appId: app)
        #expect(try await session.chosenPricingModel(accountId: account.id, appId: app) == .subscriptions)

        var free = PricingSetupChange(action: .appPrice); free.territory = "USA"; free.pricePointId = "app-pp-usa-0"
        let prepared = try await session.preparePublishing(account: account, request: request(account, free), client: client)
        #expect(prepared.steps.count == 1 && apple.writes.isEmpty)
        #expect(try await session.approvePublishing(account: account, appId: app, id: prepared.id, fingerprint: prepared.fingerprint, client: client).state == "complete")
        #expect(try await session.pricingSetupState(account: account, appId: app, client: client).appPrice == .free(territory: "USA"))

        var draft = SubscriptionSetupDraft(); draft.groupName = "Premium"; draft.territory = "USA"
        draft.plans[0].name = "Monthly"; draft.plans[0].productId = "com.example.monthly"; draft.plans[0].amount = "2.99"
        draft.plans[0].offerMode = "FREE_TRIAL"; draft.plans[0].offerDuration = "ONE_WEEK"; draft.plans[0].offerPeriods = 1
        var yearly = SubscriptionPlan(); yearly.name = "Yearly"; yearly.productId = "com.example.yearly"; yearly.duration = "ONE_YEAR"; yearly.familySharing = true; yearly.amount = "4.99"
        draft.plans.append(yearly)
        try await session.saveSubscriptionSetupDraft(draft, accountId: account.id, appId: app)
        #expect(try await session.subscriptionSetupDraft(accountId: account.id, appId: app) == draft)
        #expect(try await session.chosenPricingModel(accountId: account.id, appId: app) == .subscriptions)
        let creation = try #require(draft.createRequest(accountId: account.id, appId: app, existing: []))
        #expect(draft.setupRequest(accountId: account.id, appId: app, subscriptions: [], priced: []) == nil)
        let createdReview = try await session.preparePublishing(account: account, request: creation, client: client)
        let created = try await session.approvePublishing(account: account, appId: app, id: createdReview.id, fingerprint: createdReview.fingerprint, client: client)
        #expect(created.state == "complete" && created.steps.count == 3)
        #expect(apple.writes.suffix(3).map(\.path) == ["/v1/subscriptionGroups", "/v1/subscriptions", "/v1/subscriptions"])
        #expect((apple.writes.last?.body["data"] as? [String: Any]).flatMap { $0["attributes"] as? [String: Any] }?["familySharable"] as? Bool == true)
        let state = try await session.pricingSetupState(account: account, appId: app, client: client)
        let product = try #require(state.subscriptions?.first { $0.productId == "com.example.monthly" }), annual = try #require(state.subscriptions?.first { $0.productId == "com.example.yearly" })
        #expect(product.group == "Premium" && state.groups?.map(\.referenceName) == ["Premium"] && PricingSetup.nextStep(.subscriptions, state: state)?.task == .createSubscription)
        #expect(draft.createRequest(accountId: account.id, appId: app, existing: state.subscriptions ?? []) == nil)
        await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: creation, client: client) }

        let setup = try #require(draft.setupRequest(accountId: account.id, appId: app, subscriptions: state.subscriptions ?? [], priced: state.priced ?? []))
        let setupReview = try await session.preparePublishing(account: account, request: setup, client: client)
        #expect(setupReview.steps.map(\.label) == ["Monthly · 2.99 USD · Free Trial", "Yearly · 4.99 USD"])
        #expect(try await session.approvePublishing(account: account, appId: app, id: setupReview.id, fingerprint: setupReview.fingerprint, client: client).state == "complete")
        #expect(apple.writes.suffix(2).map(\.method) == ["PATCH", "PATCH"])
        #expect(apple.writes.suffix(2).map { ($0.body["included"] as? [[String: Any]])?.count } == [4, 2])
        #expect(Set(apple.subscriptionPrices.filter { $0.subscription == product.id }.compactMap { (($0.resource["relationships"] as? [String: Any])?["subscriptionPricePoint"] as? [String: Any]).flatMap { $0["data"] as? [String: Any] }?["id"] as? String }) == ["sub-pp-usa-299", "sub-pp-fra-299"])
        let finished = try await session.pricingSetupState(account: account, appId: app, client: client)
        #expect(PricingSetup.nextStep(.subscriptions, state: finished) == nil)
        #expect(draft.setupRequest(accountId: account.id, appId: app, subscriptions: finished.subscriptions ?? [], priced: finished.priced ?? []) == nil)
        await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: setup, client: client) }

        var prices = PricingSetupChange(action: .subscriptionPrices); prices.subscriptionId = product.id; prices.territory = "USA"; prices.pricePointId = "sub-pp-usa-299"; prices.allTerritories = true; prices.preserveCurrentPrice = false
        var increase = prices; increase.pricePointId = "sub-pp-usa-499"
        await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: request(account, increase), client: client) }
        increase.startDate = day(3); increase.preserveCurrentPrice = true
        let increased = try await publish(increase)
        #expect(increased.state == "complete" && increased.steps.map(\.state) == ["done", "done"])
        #expect(apple.writes.suffix(2).allSatisfy { $0.method == "POST" && $0.path == "/v1/subscriptionPrices" })
        #expect(apple.writes.last?.body["data"].flatMap { ($0 as? [String: Any])?["attributes"] as? [String: Any] }?["preserveCurrentPrice"] as? Bool == true)

        // A pricing profile's prices, one Apple price point per country or region; a point from another country is refused before any write.
        var profiled = PricingSetupChange(action: .subscriptionPrices); profiled.subscriptionId = annual.id; profiled.territory = "USA"; profiled.pricePointId = "sub-pp-usa-499"
        profiled.allTerritories = false; profiled.preserveCurrentPrice = true; profiled.startDate = day(5); profiled.territoryPoints = ["USA": "sub-pp-usa-499", "FRA": "sub-pp-fra-299"]
        var wrong = profiled; wrong.territoryPoints = ["USA": "sub-pp-usa-499", "FRA": "sub-pp-usa-299"]
        let before = apple.writes.count
        await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: request(account, wrong), client: client) }
        var everywhere = profiled; everywhere.allTerritories = true
        await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: request(account, everywhere), client: client) }
        #expect(apple.writes.count == before)
        // Typed prices round to the nearest of the subscription's own Apple prices in each country or region.
        let countries = [Territory(code: "USA", name: "United States", currency: "USD"), Territory(code: "FRA", name: "France", currency: "EUR")]
        let typed = try await session.subscriptionManualPrices(subscriptionId: annual.id, amounts: ["USA": "4.5", "FRA": "3"], countries: countries, client: client)
        #expect(typed.points == ["USA": "sub-pp-usa-499", "FRA": "sub-pp-fra-299"] && typed.rows.map(\.territory) == ["FRA", "USA"] && typed.rows.map(\.amount) == ["2.99", "4.99"])
        await #expect(throws: PricingFailure.self) { try await session.subscriptionManualPrices(subscriptionId: annual.id, amounts: ["USA": "0"], countries: countries, client: client) }
        let byCountry = try await publish(profiled)
        #expect(byCountry.state == "complete" && byCountry.steps.map(\.label).sorted() == ["France · 2.99 EUR", "United States · 4.99 USD"])
        // A refused country or region fails only its own step; the others sent with it are done, and the review stops.
        var refused = profiled; refused.startDate = day(7); refused.pricePointId = "sub-pp-usa-299"; refused.territoryPoints = ["USA": "sub-pp-usa-299", "FRA": "sub-pp-fra-499"]
        apple.lock.withLock { apple.refusedPoint = "sub-pp-fra-499" }
        let partial = try await publish(refused)
        apple.lock.withLock { apple.refusedPoint = nil }
        #expect(partial.state == "failed" && partial.steps.map(\.state).sorted() == ["done", "failed"] && partial.steps.first { $0.state == "failed" }?.label == "France · 4.99 EUR")

        var trial = PricingSetupChange(action: .introductoryOffer); trial.subscriptionId = annual.id; trial.territory = "USA"; trial.allTerritories = true; trial.offerMode = "FREE_TRIAL"; trial.duration = "ONE_WEEK"; trial.periods = 1
        // The first introductory offer goes to every country or region in one subscription update.
        #expect(try await publish(trial).steps.count == 1)
        #expect(apple.writes.last?.method == "PATCH" && (apple.writes.last?.body["included"] as? [[String: Any]])?.count == 2)
        let again = try await session.preparePublishing(account: account, request: request(account, trial), client: client)
        #expect(again.steps.isEmpty && again.notes.contains { $0.contains("already have an introductory offer") })

        var promotion = PricingSetupChange(action: .promotionalOffer); promotion.subscriptionId = product.id; promotion.territory = "USA"; promotion.allTerritories = false; promotion.offerMode = "PAY_UP_FRONT"
        promotion.duration = "THREE_MONTHS"; promotion.periods = 1; promotion.pricePointId = "sub-pp-usa-299"; promotion.name = "Loyalty"; promotion.offerId = "loyalty.three.months"
        #expect(try await publish(promotion).state == "complete")
        #expect((apple.writes.last?.body["included"] as? [[String: Any]])?.count == 1)
        await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: request(account, promotion), client: client) }

        var code = PricingSetupChange(action: .offerCode); code.subscriptionId = product.id; code.territory = "USA"; code.allTerritories = true; code.offerMode = "FREE_TRIAL"; code.duration = "ONE_MONTH"; code.periods = 1
        code.name = "Launch partners"; code.eligibilities = ["NEW", "EXPIRED"]; code.stacking = "STACK_WITH_INTRO_OFFERS"
        #expect(try await publish(code).state == "complete")
        #expect((apple.writes.last?.body["included"] as? [[String: Any]])?.count == 2)

        var winBack = PricingSetupChange(action: .winBackOffer); winBack.subscriptionId = product.id; winBack.territory = "USA"; winBack.allTerritories = true; winBack.offerMode = "PAY_AS_YOU_GO"; winBack.duration = "ONE_MONTH"
        winBack.periods = 3; winBack.pricePointId = "sub-pp-usa-299"; winBack.name = "Come back"; winBack.offerId = "come.back"; winBack.startDate = day(1); winBack.priority = "HIGH"
        winBack.paidMonths = 2; winBack.lapsedMinimum = 1; winBack.lapsedMaximum = 12
        #expect(try await publish(winBack).state == "complete")
        let sent = try #require(apple.writes.last?.body["data"] as? [String: Any])["attributes"] as? [String: Any]
        #expect(sent?["periodCount"] as? Int == 3 && (sent?["customerEligibilityTimeSinceLastSubscribedInMonths"] as? [String: Any])?["maximum"] as? Int == 12)

        // App Availability is created once, for every country or region, through an approved review.
        #expect(try await session.pricingSetupState(account: account, appId: app, client: client).appAvailable == false)
        var availability = PricingSetupChange(action: .appAvailability); availability.allTerritories = true
        let available = try await publish(availability)
        #expect(available.state == "complete" && apple.writes.last?.path == "/v2/appAvailabilities")
        #expect((apple.writes.last?.body["included"] as? [[String: Any]])?.count == 2)
        #expect(try await session.pricingSetupState(account: account, appId: app, client: client).appAvailable == true)
        #expect(try await session.preparePublishing(account: account, request: request(account, availability), client: client).steps.isEmpty)
    }

    @Test func paidAppsGetTemporaryPricesAndStaleReviewsSendNothing() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticPricingApple(), host = "pricing-setup-paid.appstoreconnect.test"
        StubProtocol.handle(host) { apple.handle($0) }
        let client = try client(account, host: host)
        func publish(_ change: PricingSetupChange) async throws -> PublishReview {
            let review = try await session.preparePublishing(account: account, request: request(account, change), client: client)
            return try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: client)
        }

        var sale = PricingSetupChange(action: .temporaryAppPrice); sale.territory = "USA"; sale.pricePointId = "app-pp-usa-099"; sale.startDate = day(2); sale.endDate = day(8)
        await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: request(account, sale), client: client) }
        var paid = PricingSetupChange(action: .appPrice); paid.territory = "USA"; paid.pricePointId = "app-pp-usa-499"
        #expect(try await publish(paid).state == "complete")
        #expect(try await session.pricingSetupState(account: account, appId: app, client: client).appPrice == .paid(territory: "USA", amount: "4.99", currency: "USD"))
        let same = try await session.preparePublishing(account: account, request: request(account, paid), client: client)
        #expect(same.steps.isEmpty)

        #expect(try await publish(sale).state == "complete")
        #expect(apple.manual.map { [$0.start ?? "now", $0.end ?? "open", $0.point] } == [["now", day(2), "app-pp-usa-499"], [day(2), day(9), "app-pp-usa-099"], [day(9), "open", "app-pp-usa-499"]])
        var overlap = sale; overlap.startDate = day(5); overlap.endDate = day(12)
        await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: request(account, overlap), client: client) }

        var purchase = PricingSetupChange(action: .createInAppPurchase); purchase.name = "Coins"; purchase.productId = "com.example.coins"; purchase.productType = "CONSUMABLE"
        let stale = try await session.preparePublishing(account: account, request: request(account, purchase), client: client)
        #expect(stale.steps.first?.label == "Create Consumable · Coins")
        apple.lock.withLock { apple.purchases.append(["type": "inAppPurchases", "id": "iap-elsewhere", "attributes": ["name": "Gems", "productId": "com.example.gems", "inAppPurchaseType": "CONSUMABLE", "state": "MISSING_METADATA"]]) }
        let writes = apple.writes.count
        await #expect(throws: PublishFailure.conflict) { try await session.approvePublishing(account: account, appId: app, id: stale.id, fingerprint: stale.fingerprint, client: client) }
        #expect(apple.writes.count == writes)
        #expect(try await publish(purchase).state == "complete")
        #expect(apple.writes.last?.path == "/v2/inAppPurchases" && apple.purchases.count == 2)
        #expect(PricingSetup.detect(try await session.pricingSetupState(account: account, appId: app, client: client)) == .paidWithInAppPurchases)

        var launch = paid; launch.salePointId = "app-pp-usa-099"; launch.startDate = day(0); launch.endDate = day(6); launch.changePointId = "app-pp-usa-099"; launch.changeDate = day(20)
        #expect(try await publish(launch).state == "complete")
        #expect(apple.manual.map { [$0.start ?? "now", $0.end ?? "open", $0.point] } == [["now", day(7), "app-pp-usa-099"], [day(7), day(20), "app-pp-usa-499"], [day(20), "open", "app-pp-usa-099"]])

        var free = paid; free.pricePointId = "app-pp-usa-0"
        let toFree = try await session.preparePublishing(account: account, request: request(account, free), client: client)
        #expect(toFree.notes.contains { $0.contains("removes the 3 manual prices") })

        var shared = PricingSetupChange(action: .createInAppPurchase); shared.name = "Pro"; shared.productId = "com.example.pro"; shared.productType = "NON_CONSUMABLE"; shared.familySharing = true
        #expect(try await publish(shared).state == "complete")
        #expect((apple.writes.last?.body["data"] as? [String: Any]).flatMap { $0["attributes"] as? [String: Any] }?["familySharable"] as? Bool == true)
    }
}

extension PricingSetupTests {
    @Test func productInformationIsSetThroughVersionsAndAvailabilityOnlyAfterApproval() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticPricingApple(), host = "product-information.appstoreconnect.test"
        apple.groups = [["type": "subscriptionGroups", "id": "group-1", "attributes": ["referenceName": "Premium"]]]
        apple.subscriptions = [["type": "subscriptions", "id": "sub-1", "attributes": ["name": "Monthly", "productId": "com.example.monthly", "subscriptionPeriod": "ONE_MONTH", "state": "MISSING_METADATA"],
                                "relationships": ["group": ["data": ["type": "subscriptionGroups", "id": "group-1"]]]]]
        StubProtocol.handle(host) { apple.handle($0) }
        let client = try client(account, host: host)
        func publish(_ change: PricingSetupChange) async throws -> PublishReview {
            let review = try await session.preparePublishing(account: account, request: request(account, change), client: client)
            return try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: client)
        }
        let before = try #require(try await session.productReadiness(account: account, appId: app, client: client).products.first)
        #expect(before.missing == ["Price", "Availability", "Display Name and Description", "Subscription Group Display Name", "Review Screenshot"])

        // A subscription without availability gets it first in the same review, because Apple refuses prices where it is not available.
        var firstPrices = PricingSetupChange(action: .subscriptionPrices); firstPrices.subscriptionId = "sub-1"; firstPrices.territory = "USA"; firstPrices.pricePointId = "sub-pp-usa-299"
        firstPrices.allTerritories = true; firstPrices.preserveCurrentPrice = false
        let pricing = try await session.preparePublishing(account: account, request: request(account, firstPrices), client: client)
        #expect(pricing.steps.map { $0.path.compactMap(\.text) } == [["subscriptionAvailabilities"], ["subscriptions", "sub-1"]] && apple.writes.isEmpty)
        #expect((pricing.steps.last?.body?["included"]).map { if case .array(let items) = $0 { items.count } else { 0 } } == 2)

        var change = PricingSetupChange(action: .productInformation); change.itemId = "sub-1"; change.itemKind = "subscription"; change.locale = "en-US"
        change.displayName = "Premium Monthly"; change.details = "All features, billed monthly"; change.groupDisplayName = "Premium"; change.allTerritories = true
        let prepared = try await session.preparePublishing(account: account, request: request(account, change), client: client)
        #expect(prepared.steps.map(\.path).map { $0.compactMap(\.text) } == [["subscriptionAvailabilities"], ["subscriptionVersions"], ["v2", "subscriptionLocalizations"], ["subscriptionGroupVersions"], ["v2", "subscriptionGroupLocalizations"]])
        #expect(apple.writes.isEmpty)
        #expect(try await session.approvePublishing(account: account, appId: app, id: prepared.id, fingerprint: prepared.fingerprint, client: client).state == "complete")
        #expect(apple.writes.map(\.path) == ["/v1/subscriptionAvailabilities", "/v1/subscriptionVersions", "/v2/subscriptionLocalizations", "/v1/subscriptionGroupVersions", "/v2/subscriptionGroupLocalizations"])
        let after = try #require(try await session.productReadiness(account: account, appId: app, client: client).products.first)
        #expect(after.available == true && after.locales == ["en-US"] && after.groupLocales == ["en-US"] && after.missing == ["Price", "Review Screenshot"])

        var renamed = PricingSetupChange(action: .productInformation); renamed.itemId = "sub-1"; renamed.itemKind = "subscription"; renamed.locale = "en-US"
        renamed.displayName = "Premium Plus"; renamed.details = "All features, billed monthly"
        #expect(try await publish(renamed).state == "complete")
        #expect(apple.writes.last?.method == "PATCH" && apple.writes.last?.path.hasPrefix("/v2/subscriptionLocalizations/") == true)
        let same = try await session.preparePublishing(account: account, request: request(account, renamed), client: client)
        #expect(same.steps.isEmpty && same.notes.contains { $0.contains("already matches") })
        var tooLong = renamed; tooLong.displayName = String(repeating: "A", count: 36)
        await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: request(account, tooLong), client: client) }
    }
}

extension PricingSetupTests {
    func purchase(_ id: String, _ name: String) -> [String: Any] {
        ["type": "inAppPurchases", "id": id, "attributes": ["name": name, "productId": "com.example.\(id)", "inAppPurchaseType": "CONSUMABLE", "state": "MISSING_METADATA"]]
    }
    func localization(_ type: String, _ id: String, _ attributes: [String: Any]) -> [String: Any] { ["type": type, "id": id, "attributes": attributes] }

    @Test func productTextReviewShowsEveryWrittenFieldWithItsLanguageBeforeApproval() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticPricingApple(), host = "product-text-review.appstoreconnect.test"
        apple.purchases = [purchase("iap-1", "Coins")]
        StubProtocol.handle(host) { apple.handle($0) }
        let client = try client(account, host: host)
        var change = PricingSetupChange(action: .productInformation); change.itemId = "iap-1"; change.itemKind = "purchase"; change.locale = "en-US"
        change.displayName = "Coins"; change.details = "A pile of coins"
        let created = try await session.preparePublishing(account: account, request: request(account, change), client: client)
        let added = try #require(created.steps.last)
        #expect(added.before == "No text in \(StoreLocales.name("en-US"))")
        #expect(added.after == "Language: \(StoreLocales.name("en-US")) (en-US)\nDisplay Name: Coins\nDescription: A pile of coins")
        #expect(apple.writes.isEmpty)
        #expect(try await session.approvePublishing(account: account, appId: app, id: created.id, fingerprint: created.fingerprint, client: client).state == "complete")

        // Only the description changes: the review still shows the unchanged name and both descriptions in full.
        let writes = apple.writes.count
        change.details = "A bigger pile of coins"
        let updated = try await session.preparePublishing(account: account, request: request(account, change), client: client)
        let patch = try #require(updated.steps.first)
        #expect(patch.method == "PATCH")
        #expect(patch.before == "Language: \(StoreLocales.name("en-US")) (en-US)\nDisplay Name: Coins\nDescription: A pile of coins")
        #expect(patch.after == "Language: \(StoreLocales.name("en-US")) (en-US)\nDisplay Name: Coins (unchanged)\nDescription: A bigger pile of coins")
        #expect(apple.writes.count == writes)
    }

    @Test func productTextNeedsDescriptionWhileTheGroupNeedsOnlyItsName() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticPricingApple(), host = "product-text-status.appstoreconnect.test"
        apple.groups = [["type": "subscriptionGroups", "id": "group-1", "attributes": ["referenceName": "Premium"]]]
        apple.subscriptions = [["type": "subscriptions", "id": "sub-1", "attributes": ["name": "Monthly", "productId": "com.example.monthly", "subscriptionPeriod": "ONE_MONTH", "state": "MISSING_METADATA"],
                                "relationships": ["group": ["data": ["type": "subscriptionGroups", "id": "group-1"]]]]]
        apple.versions = ["sub-1": [["type": "subscriptionVersions", "id": "version-sub", "attributes": ["version": 1, "state": "PREPARE_FOR_SUBMISSION"]]],
                          "group-1": [["type": "subscriptionGroupVersions", "id": "version-group", "attributes": ["version": 1, "state": "PREPARE_FOR_SUBMISSION"]]]]
        apple.localizations = ["version-sub": [localization("subscriptionLocalizations", "l-1", ["locale": "en-US", "name": "Monthly", "description": NSNull()]),
                                               localization("subscriptionLocalizations", "l-2", ["locale": "sv", "name": "Månadsvis", "description": "  "])],
                               "version-group": [localization("subscriptionGroupLocalizations", "g-1", ["locale": "en-US", "name": "Premium"])]]
        StubProtocol.handle(host) { apple.handle($0) }
        let client = try client(account, host: host)
        let missing = try #require(try await session.productReadiness(account: account, appId: app, client: client).products.first)
        #expect(missing.locales == [] && missing.groupLocales == ["en-US"])
        #expect(missing.missing.contains("Display Name and Description") && !missing.missing.contains("Subscription Group Display Name"))

        apple.lock.withLock { apple.localizations["version-sub"]!.append(localization("subscriptionLocalizations", "l-3", ["locale": "de-DE", "name": "Monatlich", "description": "Alles, monatlich"])) }
        let complete = try #require(try await session.productReadiness(account: account, appId: app, client: client).products.first)
        #expect(complete.locales == ["de-DE"] && !complete.missing.contains("Display Name and Description"))
    }

    @Test func productStatusReportsProductsNotCheckedYetAndFamiliesThatCouldNotBeRead() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticPricingApple(), host = "product-status-coverage.appstoreconnect.test"
        apple.purchases = (1...41).map { purchase("iap-\($0)", "Pack \($0)") }
        apple.groups = [["type": "subscriptionGroups", "id": "group-1", "attributes": ["referenceName": "Premium"]]]
        let monthly: [String: Any] = ["type": "subscriptions", "id": "sub-1", "attributes": ["name": "Monthly", "productId": "com.example.monthly", "subscriptionPeriod": "ONE_MONTH", "state": "MISSING_METADATA"],
                                      "relationships": ["group": ["data": ["type": "subscriptionGroups", "id": "group-1"]]]]
        apple.subscriptions = [monthly]
        StubProtocol.handle(host) { apple.handle($0) }
        let client = try client(account, host: host)

        let first = try await session.productReadiness(account: account, appId: app, client: client)
        #expect(first.products.count == ProductReadinessCheck.batch && first.unread.isEmpty && !first.complete)
        #expect(first.unchecked.map(\.id) == ["iap-41", "sub-1"])
        let all = try await session.productReadiness(account: account, appId: app, client: client, limit: ProductReadinessCheck.batch * 2)
        #expect(all.products.count == 42 && all.complete && all.products.last?.product.kind == .subscription)

        // Apple lists the same subscription twice, so the subscriptions cannot be read: the earlier one stays, as unknown.
        apple.lock.withLock { apple.subscriptions.append(monthly) }
        let failed = try await session.productReadiness(account: account, appId: app, client: client, limit: ProductReadinessCheck.batch * 2)
        #expect(failed.unread == [.subscription] && failed.products.count == 41)
        let shown = failed.keeping(all)
        let kept = try #require(shown.products.first { $0.product.id == "sub-1" })
        #expect(shown.products.count == 42 && kept.unread && kept.uncertain && !kept.ready)
        #expect(all.keeping(first) == all)
    }

    @Test func textChangeFollowsOnTheNewVersionUntilAppleHasIt() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticPricingApple(), host = "product-text-follow-up.appstoreconnect.test"
        apple.groups = [["type": "subscriptionGroups", "id": "group-1", "attributes": ["referenceName": "Premium"]]]
        apple.subscriptions = [["type": "subscriptions", "id": "sub-1", "attributes": ["name": "Monthly", "productId": "com.example.monthly", "subscriptionPeriod": "ONE_MONTH", "state": "APPROVED"],
                                "relationships": ["group": ["data": ["type": "subscriptionGroups", "id": "group-1"]]]]]
        apple.versions = ["sub-1": [["type": "subscriptionVersions", "id": "published-version", "attributes": ["version": 1, "state": "APPROVED"]]],
                          "group-1": [["type": "subscriptionGroupVersions", "id": "group-draft", "attributes": ["version": 1, "state": "PREPARE_FOR_SUBMISSION"]]]]
        apple.localizations = ["published-version": [localization("subscriptionLocalizations", "l-1", ["locale": "en-US", "name": "Monthly", "description": "Billed monthly"])],
                               "group-draft": [localization("subscriptionGroupLocalizations", "g-1", ["locale": "en-US", "name": "Premium"])]]
        StubProtocol.handle(host) { apple.handle($0) }
        let client = try client(account, host: host)
        var change = PricingSetupChange(action: .productInformation); change.itemId = "sub-1"; change.itemKind = "subscription"; change.locale = "en-US"
        change.displayName = "Monthly"; change.details = "Every feature, billed monthly"
        #expect(try await session.productInformationMatches(account: account, appId: app, change: change, client: client) == false)

        // The published version is not editable, so the first review only starts a draft version, which Apple fills with the current text.
        let versionOnly = try await session.preparePublishing(account: account, request: request(account, change), client: client)
        #expect(versionOnly.steps.map(\.method) == ["POST"] && versionOnly.steps.first?.path.compactMap(\.text) == ["subscriptionVersions"])
        #expect(try await session.approvePublishing(account: account, appId: app, id: versionOnly.id, fingerprint: versionOnly.fingerprint, client: client).state == "complete")
        let draft = try #require(apple.lock.withLock { apple.versions["sub-1"]?.last?["id"] as? String })
        apple.lock.withLock { apple.localizations[draft] = [localization("subscriptionLocalizations", "l-copy", ["locale": "en-US", "name": "Monthly", "description": "Billed monthly"])] }
        // The copied language exists, but its text is not the one asked for, so the change is not done.
        #expect(try await session.productInformationMatches(account: account, appId: app, change: change, client: client) == false)

        let writes = apple.writes.count
        let text = try await session.preparePublishing(account: account, request: request(account, change), client: client)
        #expect(text.steps.map(\.method) == ["PATCH"] && apple.writes.count == writes)
        #expect(try await session.approvePublishing(account: account, appId: app, id: text.id, fingerprint: text.fingerprint, client: client).state == "complete")
        #expect(try await session.productInformationMatches(account: account, appId: app, change: change, client: client))

        // A language the draft version does not have yet, and a new group name, each still need their own approved review.
        var swedish = change; swedish.locale = "sv"; swedish.displayName = "Månadsvis"; swedish.details = "Allt, varje månad"
        #expect(try await session.productInformationMatches(account: account, appId: app, change: swedish, client: client) == false)
        var group = change; group.groupDisplayName = "Premium Plus"
        #expect(try await session.productInformationMatches(account: account, appId: app, change: group, client: client) == false)
        let groupReview = try await session.preparePublishing(account: account, request: request(account, group), client: client)
        #expect(groupReview.steps.map { $0.path.compactMap(\.text) } == [["v2", "subscriptionGroupLocalizations", "g-1"]] && apple.writes.count == writes + 1)
        #expect(groupReview.steps.first?.after?.contains("Subscription Group Display Name: Premium Plus") == true)
    }
}

extension PricingSetupTests {
    @Test func aPriceThatCannotBeReadNowIsUnknownAndKeepsTheEarlierCheckAsOlder() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticPricingApple(), host = "price-check-unknown.appstoreconnect.test"
        apple.manual = [("price-1", nil, nil, "app-pp-usa-499")]
        let failing = SyntheticFlag()
        StubProtocol.handle(host) { request in
            if failing.value, request.url?.path == "/v1/apps/1000000001/appPriceSchedule" { return apple.json(403, ["errors": [["status": "403", "code": "FORBIDDEN"]]]) }
            return apple.handle(request)
        }
        let client = try client(account, host: host)
        #expect(try await session.pricingSetupState(account: account, appId: app, client: client).appPrice.isPaid)
        let earlier = try #require(try await session.sectionChecks(accountId: account.id, appId: app)[.pricing])
        #expect(earlier.answered)

        failing.value = true
        let unread = try await session.pricingSetupState(account: account, appId: app, client: client)
        #expect(unread.appPrice == .unknown && unread.priceProblem?.isEmpty == false)
        // The failed read does not record a new check, so the earlier one keeps its own time and is shown as older information.
        #expect(try await session.sectionChecks(accountId: account.id, appId: app)[.pricing] == earlier)

        failing.value = false; apple.lock.withLock { apple.manual = [] }
        #expect(try await session.pricingSetupState(account: account, appId: app, client: client).appPrice == .none)
        #expect(try await session.sectionChecks(accountId: account.id, appId: app)[.pricing]?.answered == false)
    }
}

/// A switch a synthetic Apple handler reads while a test changes it.
final class SyntheticFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { get { lock.withLock { stored } } set { lock.withLock { stored = newValue } } }
}

private extension PublishRequest {
    func with(_ change: PricingSetupChange) -> PublishRequest { var copy = self; copy.pricingSetup = change; return copy }
}
