import Foundation

/// An in-app purchase or subscription of one app, as Apple's app-scoped collections list it.
public struct PriceProduct: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable { case purchase = "in-app purchase", subscription }
    public let id: String, kind: Kind, productId, name, state, type: String, group: String?
    public var selectionKey: String { (kind == .subscription ? "subscription:" : "purchase:") + id }
    public init(id: String, kind: Kind, productId: String, name: String, state: String, type: String, group: String?) {
        self.id = id; self.kind = kind; self.productId = productId; self.name = name; self.state = state; self.type = type; self.group = group
    }
    var json: JSONText {
        .object([("id", .string(id)), ("kind", .string(kind.rawValue)), ("productId", .string(productId)), ("name", .string(name)), ("state", .string(state)), ("type", .string(type)), ("group", group.map { .string($0) } ?? .null)])
    }
}

/// Both product families; nil means Apple did not return that family completely, which must not look like an empty list.
public struct ProductCatalog: Sendable { public let purchases: [PriceProduct]?, subscriptions: [PriceProduct]? }

public struct ProductPrice: Identifiable, Sendable, Equatable {
    public enum Source: String, Sendable { case manual, automatic, subscription }
    public let id, territory: String, currency, customerPrice, proceeds, startDate: String?, startKnown: Bool, endDate: String?, endKnown: Bool
    public let source: Source, pricePointId: String?, preserved: Bool?, planType: String?
    public init(id: String, territory: String, currency: String?, customerPrice: String?, proceeds: String?, startDate: String?, startKnown: Bool, endDate: String?, endKnown: Bool, source: Source, pricePointId: String?, preserved: Bool?, planType: String?) {
        self.id = id; self.territory = territory; self.currency = currency; self.customerPrice = customerPrice; self.proceeds = proceeds; self.startDate = startDate; self.startKnown = startKnown
        self.endDate = endDate; self.endKnown = endKnown; self.source = source; self.pricePointId = pricePointId; self.preserved = preserved; self.planType = planType
    }
    public var key: String { "\(source.rawValue):\(id)" }
    var json: JSONText {
        func optional(_ value: String?) -> JSONText { value.map { .string($0) } ?? .null }
        return .object([("id", .string(id)), ("territory", .string(territory)), ("currency", optional(currency)), ("customerPrice", optional(customerPrice)), ("proceeds", optional(proceeds)),
                        ("startDate", optional(startDate)), ("startKnown", .bool(startKnown)), ("endDate", optional(endDate)), ("endKnown", .bool(endKnown)), ("source", .string(source.rawValue)),
                        ("pricePointId", optional(pricePointId)), ("preserved", preserved.map { .bool($0) } ?? .null), ("planType", optional(planType))])
    }
}

public struct ProductPriceSchedule: Sendable, Equatable {
    public let baseTerritory: String?, rows: [ProductPrice], available: Bool, scheduleId: String?
    public init(baseTerritory: String?, rows: [ProductPrice], available: Bool, scheduleId: String?) {
        self.baseTerritory = baseTerritory; self.rows = rows; self.available = available; self.scheduleId = scheduleId
    }
    var json: JSONText {
        .object([("scheduleId", scheduleId.map { .string($0) } ?? .null), ("baseTerritory", baseTerritory.map { .string($0) } ?? .null), ("status", .string(available ? "available" : "missing")),
                 ("rows", .array(rows.sorted { ($0.id, $0.source.rawValue) < ($1.id, $1.source.rawValue) }.map(\.json)))])
    }
}

public struct ProductPricePoint: Identifiable, Sendable, Equatable {
    public let id, territory: String, currency, customerPrice: String?
    public init(id: String, territory: String, currency: String?, customerPrice: String?) {
        self.id = id; self.territory = territory; self.currency = currency; self.customerPrice = customerPrice
    }
    var json: JSONText { .object([("id", .string(id)), ("territory", .string(territory)), ("currency", currency.map { .string($0) } ?? .null), ("customerPrice", customerPrice.map { .string($0) } ?? .null)]) }
}

public struct SubscriptionPriceChange: Sendable, Equatable {
    public var productId, territory, pricePointId: String, startDate: String?, planType: String?, preserveCurrentPrice: Bool
    public init(productId: String, territory: String, pricePointId: String, startDate: String?, planType: String?, preserveCurrentPrice: Bool) {
        self.productId = productId; self.territory = territory; self.pricePointId = pricePointId; self.startDate = startDate; self.planType = planType; self.preserveCurrentPrice = preserveCurrentPrice
    }
    var json: JSONText {
        .object([("productId", .string(productId)), ("territory", .string(territory)), ("pricePointId", .string(pricePointId)), ("startDate", startDate.map { .string($0) } ?? .null),
                 ("planType", planType.map { .string($0) } ?? .null), ("preserveCurrentPrice", .bool(preserveCurrentPrice))])
    }
    init?(_ value: JSONText) {
        guard let product = value["productId"]?.text, let territory = value["territory"]?.text, let point = value["pricePointId"]?.text, case .bool(let preserve)? = value["preserveCurrentPrice"] else { return nil }
        self.init(productId: product, territory: territory, pricePointId: point, startDate: value["startDate"]?.text, planType: value["planType"]?.text, preserveCurrentPrice: preserve)
    }
    func validated() throws -> Self {
        guard ProductPricing.opaque(productId), ProductPricing.opaque(pricePointId), ProductPricing.territory(territory), startDate.map(ProductPricing.calendarDate) ?? true,
              planType.map({ ["MONTHLY", "UPFRONT"].contains($0) }) ?? true else { throw PublishFailure.invalid("Choose a valid subscription, territory, price level, date, plan and subscriber policy.") }
        return self
    }
}

public struct PurchasePriceChange: Sendable, Equatable {
    public var productId, territory, pricePointId: String, startDate: String?
    /// Prices in other countries or regions from the same date, such as from a pricing profile: territory code to the Apple price point.
    public var territoryPoints: [String: String]?
    public init(productId: String, territory: String, pricePointId: String, startDate: String?, territoryPoints: [String: String]? = nil) {
        self.productId = productId; self.territory = territory; self.pricePointId = pricePointId; self.startDate = startDate; self.territoryPoints = territoryPoints
    }
    var pointsJSON: JSONText? { territoryPoints.map { .object($0.sorted { $0.key < $1.key }.map { ($0.key, .string($0.value)) }) } }
    var json: JSONText {
        .object([("productId", .string(productId)), ("territory", .string(territory)), ("pricePointId", .string(pricePointId)), ("startDate", startDate.map { .string($0) } ?? .null)]
                + (pointsJSON.map { [("territoryPoints", $0)] } ?? []))
    }
    init?(_ value: JSONText) {
        guard let product = value["productId"]?.text, let territory = value["territory"]?.text, let point = value["pricePointId"]?.text else { return nil }
        var points: [String: String]?
        if case .object(let pairs)? = value["territoryPoints"] {
            guard pairs.count <= 200 else { return nil }
            points = [:]; for (code, item) in pairs { guard let id = item.text else { return nil }; points![code] = id }
        }
        self.init(productId: product, territory: territory, pricePointId: point, startDate: value["startDate"]?.text, territoryPoints: points)
    }
    func validated() throws -> Self {
        guard ProductPricing.opaque(productId), ProductPricing.opaque(pricePointId), ProductPricing.territory(territory), startDate.map(ProductPricing.calendarDate) ?? true else {
            throw PublishFailure.invalid("Choose a valid in-app purchase, territory, price level and effective date.")
        }
        if let territoryPoints {
            guard (1...200).contains(territoryPoints.count), territoryPoints[territory] == nil, territoryPoints.allSatisfy({ ProductPricing.territory($0.key) && ProductPricing.opaque($0.value) }) else {
                throw PublishFailure.invalid("Choose a valid Apple price for each other country or region.")
            }
        }
        return self
    }
}

/// Apple reads for product prices, through the planner (recorded as evidence) or directly before a write.
struct AppleReads: Sendable {
    let list: @Sendable (String) async throws -> [AppStoreConnectClient.Resource]
    let get: @Sendable (String) async throws -> [AppStoreConnectClient.Resource]
    let pages: @Sendable (String) async throws -> (data: [AppStoreConnectClient.Resource], included: [AppStoreConnectClient.Resource])
    /// Whether independent reads may run at the same time. A planner records its reads in order, so it reads one at a time.
    let concurrent: Bool
    init(_ client: AppStoreConnectClient) { list = { try await client.list($0) }; get = { try await client.get($0) }; pages = { try await client.listWithIncluded($0) }; concurrent = true }
    init(list: @escaping @Sendable (String) async throws -> [AppStoreConnectClient.Resource], get: @escaping @Sendable (String) async throws -> [AppStoreConnectClient.Resource],
         pages: @escaping @Sendable (String) async throws -> (data: [AppStoreConnectClient.Resource], included: [AppStoreConnectClient.Resource])) { self.list = list; self.get = get; self.pages = pages; concurrent = false }
    init(_ planner: Planner) { list = { try await planner.list($0) }; get = { try await planner.get($0) }; pages = { try await planner.listWithIncluded($0) }; concurrent = false }

    /// How many reads go at once; Apple answers several in parallel over one connection.
    static let width = 6
    private struct Done<T: Sendable>: Sendable { let index: Int; let value: T }
    /// `read` for each item, in the items' order: several at a time when the reads allow it, otherwise one after another.
    func each<Item: Sendable, T: Sendable>(_ items: [Item], _ read: @escaping @Sendable (Item) async throws -> T) async throws -> [T] {
        guard concurrent, items.count > 1 else {
            var values: [T] = []
            for item in items { values.append(try await read(item)) }
            return values
        }
        return try await withThrowingTaskGroup(of: Done<T>.self) { tasks in
            var values: [Int: T] = [:], next = 0
            while next < min(Self.width, items.count) { let index = next, item = items[index]; tasks.addTask { Done(index: index, value: try await read(item)) }; next += 1 }
            while let done = try await tasks.next() {
                values[done.index] = done.value
                if next < items.count { let index = next, item = items[index]; tasks.addTask { Done(index: index, value: try await read(item)) }; next += 1 }
            }
            return items.indices.map { values[$0]! }
        }
    }
}

public enum ProductPricing {
    public enum Phase: String, Sendable { case current, future, past, preserved, unknown }

    static func opaque(_ value: String) -> Bool { value.range(of: "^[A-Za-z0-9_-]{1,512}$", options: .regularExpression) != nil }
    static func territory(_ value: String) -> Bool { value.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil }
    static func calendarDate(_ value: String) -> Bool {
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil, let date = ReportTables.dayFormat.date(from: value) else { return false }
        return ReportTables.dayFormat.string(from: date) == value
    }
    static func text(_ value: JSONValue?, _ maximum: Int = 300) -> String {
        guard case .string(let text)? = value, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf16.count <= maximum,
              text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) else { return "" }
        return text
    }
    static func date(_ value: JSONValue?) -> String? { if case .string(let text)? = value, calendarDate(text) { return text }; return nil }
    static func unique(_ items: [AppStoreConnectClient.Resource], _ type: String) throws -> [AppStoreConnectClient.Resource] {
        guard items.allSatisfy({ $0.type == type && !$0.id.isEmpty && $0.id.count <= 512 }), Set(items.map(\.id)).count == items.count else { throw PublishFailure.invalid("Apple returned invalid or duplicate price product resources.") }
        return items
    }
    static func today() -> String { ReportTables.dayFormat.string(from: Date()) }
    /// Why a read of `what`, such as "this product's prices", got no answer, in a sentence that says what to do.
    public static func readProblem(_ error: Error, reading what: String) -> String {
        switch error {
        case AppStoreConnectClient.Failure.status(429): "Apple's hourly request limit for this API key is used up, so \(what) could not be read. Apple allows more requests within the hour; refresh then."
        case AppStoreConnectClient.Failure.status(let code) where code == 401 || code == 403: PricingFailure.access.message
        case AppStoreConnectClient.Failure.status(let code) where code >= 500: "App Store Connect had a temporary problem (error \(code)) while reading \(what). Refresh to try again."
        case AppStoreConnectClient.Failure.status(let code): "Apple answered the read of \(what) with error \(code)."
        case AppStoreConnectClient.Failure.agreement: "Apple needs the Account Holder to accept the latest agreements in App Store Connect before \(what) can be read."
        case AppStoreConnectClient.Failure.unreadableResponse, AppStoreConnectClient.Failure.invalidPagination, AppStoreConnectClient.Failure.paginationLimit: "Apple's answer for \(what) could not be read. Refresh to try again."
        case let failure as PublishFailure: failure.message
        case let failure as URLError where failure.code == .timedOut: "App Store Connect took too long to answer for \(what). Refresh to try again."
        case is URLError: "App Store Connect could not be reached while reading \(what). Check the connection and refresh."
        default: "\(what.prefix(1).uppercased() + what.dropFirst()) could not be read. Refresh to try again."
        }
    }
    /// A read that may come back empty; a cancelled read is passed on so the caller reads again instead of showing nothing.
    static func optional<T>(_ read: () async throws -> T) async throws -> T? {
        do { return try await read() } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
            return nil
        }
    }
    /// A calendar day in UTC, as Apple's price dates use.
    public static func day(_ date: Date) -> String { ReportTables.dayFormat.string(from: date) }

    static func product(_ item: AppStoreConnectClient.Resource, _ kind: PriceProduct.Kind, group: String?) throws -> PriceProduct {
        let productId = text(item.attributes?["productId"]), name = text(item.attributes?["name"])
        guard !productId.isEmpty else { throw PublishFailure.invalid("Apple returned a price product without a usable product ID.") }
        let type = kind == .subscription ? text(item.attributes?["subscriptionPeriod"], 100) : text(item.attributes?["inAppPurchaseType"], 100)
        return PriceProduct(id: item.id, kind: kind, productId: productId, name: name.isEmpty ? productId : name, state: text(item.attributes?["state"], 100).isEmpty ? "Unknown" : text(item.attributes?["state"], 100),
                            type: type.isEmpty ? (kind == .subscription ? "Auto-renewable" : "Unknown") : type, group: group)
    }

    /// Parent-scoped collections establish ownership; a family that fails stays unavailable while the other is kept.
    static func catalog(appId: String, reads: AppleReads) async throws -> ProductCatalog {
        guard appId.range(of: #"^\d{1,30}$"#, options: .regularExpression) != nil else { throw PublishFailure.invalid("Invalid app for price products.") }
        var purchases: [PriceProduct]?, subscriptions: [PriceProduct]?
        let families = try await reads.each(["/v1/apps/\(appId)/inAppPurchasesV2?limit=200", "/v1/apps/\(appId)/subscriptionGroups?limit=200"]) { path in try await optional { try await reads.list(path) } }
        if let items = families[0] { purchases = try? unique(items, "inAppPurchases").map { try product($0, .purchase, group: nil) } }
        if let groups = families[1], let valid = try? unique(groups, "subscriptionGroups") {
            // One group that fails leaves subscriptions unavailable.
            let lists = try await reads.each(valid) { group -> [PriceProduct]? in
                guard let read = try await optional({ try await reads.list("/v1/subscriptionGroups/\(group.id)/subscriptions?limit=200") }),
                      let items = try? unique(read, "subscriptions"), items.allSatisfy({ Apple.within($0, "group", "subscriptionGroups", group.id) }) else { return nil }
                let name = text(group.attributes?["referenceName"])
                return try? items.map { try product($0, .subscription, group: name.isEmpty ? group.id : name) }
            }
            if lists.allSatisfy({ $0 != nil }) {
                let result = lists.flatMap { $0! }
                if Set(result.map(\.id)).count == result.count { subscriptions = result }
            }
        }
        return ProductCatalog(purchases: purchases, subscriptions: subscriptions)
    }

    static func prices(_ page: (data: [AppStoreConnectClient.Resource], included: [AppStoreConnectClient.Resource]), source: ProductPrice.Source) throws -> [ProductPrice] {
        let kind = source == .subscription ? "subscriptionPrices" : "inAppPurchasePrices", pointKind = source == .subscription ? "subscriptionPricePoints" : "inAppPurchasePricePoints"
        let pointKey = source == .subscription ? "subscriptionPricePoint" : "inAppPurchasePricePoint"
        let included = Dictionary(page.included.map { ("\($0.type):\($0.id)", $0) }, uniquingKeysWith: { first, _ in first })
        return try unique(page.data, kind).map { item in
            let point = Apple.owner(item, pointKey)
            if let point, point.type != pointKind { throw PublishFailure.invalid("Apple returned a price with the wrong price point type.") }
            let pointResource = point.flatMap { included["\(pointKind):\($0.id)"] }
            let direct = Apple.owner(item, "territory"), linked = pointResource.flatMap { Apple.owner($0, "territory") }
            guard let territory = direct ?? linked, territory.type == "territories", Self.territory(territory.id), direct == nil || linked == nil || (direct! == linked!) else { throw PublishFailure.invalid("Apple returned a price without a consistent territory.") }
            let territoryResource = included["territories:\(territory.id)"]
            let start = date(item.attributes?["startDate"]), end = date(item.attributes?["endDate"])
            let startRaw = item.attributes?["startDate"], endRaw = item.attributes?["endDate"]
            let currency = text(territoryResource?.attributes?["currency"], 10)
            var preserved: Bool?; if case .bool(let flag)? = item.attributes?["preserved"] { preserved = flag }
            let plan = text(item.attributes?["planType"], 50)
            return ProductPrice(id: item.id, territory: territory.id, currency: currency.isEmpty ? nil : currency, customerPrice: Apple.text(pointResource?.attributes?["customerPrice"]),
                                proceeds: Apple.text(pointResource?.attributes?["proceeds"]), startDate: start, startKnown: startRaw == .null || start != nil, endDate: end,
                                endKnown: endRaw == nil || endRaw == .null || end != nil, source: source, pricePointId: point?.id, preserved: preserved, planType: plan.isEmpty ? nil : plan)
        }
    }

    /// The product must already be selected from the app-scoped catalog.
    static func schedule(_ product: PriceProduct, reads: AppleReads) async throws -> ProductPriceSchedule {
        if product.kind == .subscription {
            let rows = try prices(try await reads.pages("/v1/subscriptions/\(product.id)/prices?include=subscriptionPricePoint%2Cterritory&limit=200"), source: .subscription)
            return ProductPriceSchedule(baseTerritory: nil, rows: rows, available: !rows.isEmpty, scheduleId: nil)
        }
        let schedule: [AppStoreConnectClient.Resource]
        do { schedule = try await reads.get("/v2/inAppPurchases/\(product.id)/iapPriceSchedule") }
        catch AppStoreConnectClient.Failure.status(404) { return ProductPriceSchedule(baseTerritory: nil, rows: [], available: false, scheduleId: nil) }
        if schedule.isEmpty { return ProductPriceSchedule(baseTerritory: nil, rows: [], available: false, scheduleId: nil) }
        guard schedule.count == 1, schedule[0].type == "inAppPurchasePriceSchedules" else { throw PublishFailure.invalid("Apple returned an invalid purchase price schedule.") }
        let id = schedule[0].id
        let base = try? await reads.get("/v1/inAppPurchasePriceSchedules/\(id)/baseTerritory")
        let manual = try await reads.pages("/v1/inAppPurchasePriceSchedules/\(id)/manualPrices?include=inAppPurchasePricePoint%2Cterritory&limit=200")
        let automatic = try await reads.pages("/v1/inAppPurchasePriceSchedules/\(id)/automaticPrices?include=inAppPurchasePricePoint%2Cterritory&limit=200")
        let baseTerritory = base.flatMap { $0.count == 1 && $0[0].type == "territories" && territory($0[0].id) ? $0[0].id : nil }
        let rows = try prices(manual, source: .manual) + prices(automatic, source: .automatic)
        return ProductPriceSchedule(baseTerritory: baseTerritory, rows: rows, available: !rows.isEmpty, scheduleId: id)
    }

    static func points(_ product: PriceProduct, territory: String, reads: AppleReads) async throws -> [ProductPricePoint] {
        guard Self.territory(territory) else { throw PublishFailure.invalid("Choose one Apple territory.") }
        let kind = product.kind == .subscription ? "subscriptionPricePoints" : "inAppPurchasePricePoints"
        let path = product.kind == .subscription ? "/v1/subscriptions/\(product.id)/pricePoints" : "/v2/inAppPurchases/\(product.id)/pricePoints"
        let page = try await reads.pages("\(path)?filter%5Bterritory%5D=\(territory)&include=territory&limit=200")
        guard page.data.count <= 1200 else { throw PublishFailure.invalid("Too many price points for one territory.") }
        let currency = text(page.included.first { $0.type == "territories" && $0.id == territory }?.attributes?["currency"], 10)
        return try unique(page.data, kind).map { item in
            guard Apple.owned(item, "territory", "territories", territory) else { throw PublishFailure.invalid("Apple returned a price point for another territory.") }
            return ProductPricePoint(id: item.id, territory: territory, currency: currency.isEmpty ? nil : currency, customerPrice: Apple.text(item.attributes?["customerPrice"]))
        }
    }

    /// Classifies all rows together so old subscriber prices and overlapping Apple rows are not called the current price.
    public static func phases(_ rows: [ProductPrice], today: String) -> [String: Phase] {
        var phases: [String: Phase] = [:], groups: [String: [ProductPrice]] = [:], order: [String] = [], uncertain = Set<String>(), uncertainTerritories = Set<String>()
        for row in rows {
            let group = "\(row.territory):\(row.source == .subscription ? row.planType ?? "null" : "purchase")"
            if !row.startKnown || !row.endKnown || (row.source == .subscription && row.planType == nil) {
                phases[row.key] = .unknown; uncertain.insert(group)
                if row.source == .subscription && row.planType == nil { uncertainTerritories.insert(row.territory) }
                continue
            }
            if let start = row.startDate, start > today { phases[row.key] = .future; continue }
            if let end = row.endDate, end < today { phases[row.key] = .past; continue }
            if groups[group] == nil { order.append(group) }
            groups[group, default: []].append(row)
        }
        for group in order {
            let eligible = groups[group]!
            let latestDate = eligible.map { $0.startDate ?? "" }.max() ?? ""
            let latest = eligible.filter { ($0.startDate ?? "") == latestDate }
            let preferred = latest.contains { $0.source == .manual } ? latest.filter { $0.source == .manual } : latest
            let uncertainty = uncertain.contains(group) || (eligible[0].source == .subscription && uncertainTerritories.contains(eligible[0].territory))
            for row in eligible {
                if preferred.contains(row) { phases[row.key] = uncertainty || preferred.count != 1 ? .unknown : .current }
                else { phases[row.key] = row.source == .subscription && row.preserved == true ? .preserved : .past }
            }
        }
        return phases
    }

    static func subscriptionDigest(_ product: PriceProduct, _ schedule: ProductPriceSchedule, _ point: ProductPricePoint) -> String {
        Apple.sha(Apple.canonical(.object([("product", product.json), ("status", .string(schedule.available ? "available" : "missing")), ("rows", schedule.json["rows"]!), ("point", point.json)])))
    }
    static func purchaseDigest(_ product: PriceProduct, _ schedule: ProductPriceSchedule, _ point: ProductPricePoint) -> String {
        Apple.sha(Apple.canonical(.object([("product", product.json), ("schedule", schedule.json), ("point", point.json)])))
    }
    /// The in-app purchase's own Apple price points chosen per country or region, each checked to belong to that purchase and territory.
    static func chosenPurchasePoints(_ product: PriceProduct, _ chosen: [String: String], reads: AppleReads) async throws -> [PricePoint] {
        let codes = chosen.keys.sorted()
        var result: [PricePoint] = []
        for start in stride(from: 0, to: codes.count, by: PricePointCatalog.batchSize) {
            let batch = Array(codes[start..<min(start + PricePointCatalog.batchSize, codes.count)])
            let points = try await PricePointCatalog.read(.purchase(product.id), territories: batch, list: { try await reads.list($0) })
            for code in batch {
                guard let point = points.first(where: { $0.territory == code && $0.id == chosen[code] }) else {
                    throw PublishFailure.invalid("The chosen price for \(WorkspaceSession.countryName(code)) is not one of this in-app purchase's Apple prices. Preview the prices again.")
                }
                result.append(point)
            }
        }
        return result
    }
    static func initial(_ schedule: ProductPriceSchedule) -> Bool { !schedule.available && schedule.scheduleId == nil && schedule.baseTerritory == nil && schedule.rows.isEmpty }

    /// Creates the first base price, or keeps every observed manual price and adds one.
    static func purchasePayload(_ product: PriceProduct, _ schedule: ProductPriceSchedule, _ point: ProductPricePoint, _ choice: PurchasePriceChange) throws -> JSONText {
        let first = initial(schedule)
        guard product.kind == .purchase, product.id == choice.productId, point.id == choice.pricePointId, point.territory == choice.territory,
              first ? choice.startDate == nil : (schedule.scheduleId != nil && schedule.baseTerritory != nil && schedule.available && choice.startDate != nil) else {
            throw PublishFailure.invalid("A complete in-app purchase price schedule or a verified empty product is required.")
        }
        let manual = schedule.rows.filter { $0.source == .manual }.sorted { ($0.territory, $0.startDate ?? "", $0.id) < ($1.territory, $1.startDate ?? "", $1.id) }
        guard manual.allSatisfy({ $0.startKnown && $0.endKnown && $0.pricePointId != nil }) else { throw PublishFailure.invalid("Apple returned incomplete manual prices. Review the product's Price Schedule in App Store Connect (Apps → the app → In-App Purchases or Subscriptions).") }
        let others = (choice.territoryPoints ?? [:]).sorted { $0.key < $1.key }.map { ("new-price-\($0.key)", choice.startDate, nil as String?, $0.value) }
        let entries = manual.enumerated().map { ("existing-price-\($0.offset + 1)", $0.element.startDate, $0.element.endDate, $0.element.pricePointId!) } + [("new-price", choice.startDate, nil, point.id)] + others
        func link(_ type: String, _ id: String) -> JSONText { Apple.relationship(type, .string(id)) }
        return .object([
            ("data", .object([("type", .string("inAppPurchasePriceSchedules")), ("relationships", .object([
                ("inAppPurchase", link("inAppPurchases", product.id)), ("baseTerritory", link("territories", first ? choice.territory : schedule.baseTerritory!)),
                ("manualPrices", .object([("data", .array(entries.map { .object([("type", .string("inAppPurchasePrices")), ("id", .string($0.0))]) }))]))]))])),
            ("included", .array(entries.map { entry in
                .object([("type", .string("inAppPurchasePrices")), ("id", .string(entry.0)),
                         ("attributes", .object([("startDate", entry.1.map { .string($0) } ?? .null)] + (entry.2.map { [("endDate", JSONText.string($0))] } ?? []))),
                         ("relationships", .object([("inAppPurchaseV2", link("inAppPurchases", product.id)), ("inAppPurchasePricePoint", link("inAppPurchasePricePoints", entry.3))]))])
            }))])
    }
}

extension WorkspaceSession {
    /// The app's in-app purchases and subscriptions that can be priced.
    public func priceProducts(appId: String, client: AppStoreConnectClient) async throws -> ProductCatalog { try await ProductPricing.catalog(appId: appId, reads: AppleReads(client)) }

    public func productPriceSchedule(appId: String, productId: String, kind: PriceProduct.Kind? = nil, client: AppStoreConnectClient) async throws -> (product: PriceProduct, schedule: ProductPriceSchedule) {
        let catalog = try await priceProducts(appId: appId, client: client)
        let products = kind == .purchase ? catalog.purchases ?? [] : kind == .subscription ? catalog.subscriptions ?? [] : (catalog.purchases ?? []) + (catalog.subscriptions ?? [])
        let matches = products.filter { $0.id == productId }
        guard matches.count == 1, let product = matches.first else { throw PublishFailure.invalid("This product is unavailable, ambiguous or no longer belongs to this app.") }
        return (product, try await ProductPricing.schedule(product, reads: AppleReads(client)))
    }

    /// Apple's comparable prices in the other countries and regions for one subscription price point.
    public func comparableSubscriptionPrices(pricePointId: String, client: AppStoreConnectClient) async throws -> [ProductPricePoint] {
        try await PricingSetupReads.equalized(pricePointId, reads: AppleReads(client))
    }

    public func productPricePoints(product: PriceProduct, territory: String, client: AppStoreConnectClient) async throws -> [ProductPricePoint] {
        try await ProductPricing.points(product, territory: territory, reads: AppleReads(client))
    }

    private func selectedPrice(_ kind: PriceProduct.Kind, appId: String, productId: String, territory: String, pricePointId: String, reads: AppleReads) async throws -> (PriceProduct, ProductPriceSchedule, ProductPricePoint) {
        let catalog = try await ProductPricing.catalog(appId: appId, reads: reads)
        guard let product = (kind == .subscription ? catalog.subscriptions : catalog.purchases)?.first(where: { $0.id == productId }) else { throw PublishFailure.invalid("The \(kind.rawValue) is unavailable or no longer belongs to this app.") }
        let schedule = try await ProductPricing.schedule(product, reads: reads), points = try await ProductPricing.points(product, territory: territory, reads: reads)
        guard let point = points.first(where: { $0.id == pricePointId }), point.customerPrice != nil, point.currency != nil else { throw PublishFailure.invalid("The selected Apple price level is no longer available with a known amount and currency.") }
        return (product, schedule, point)
    }

    private func activeTerritory(_ code: String, currency: String?, reads: AppleReads) async throws -> Bool {
        let items = try ProductPricing.unique(try await reads.list("/v1/territories?limit=200"), "territories")
        guard items.allSatisfy({ ProductPricing.territory($0.id) && ProductPricing.territory($0.attributes?["currency"]?.string ?? "") }) else { throw PublishFailure.invalid("Apple returned an incomplete territory catalog.") }
        return items.contains { $0.id == code && $0.attributes?["currency"]?.string == currency }
    }

    func planProductPrice(_ planner: Planner) async throws -> String {
        let request = planner.request, reads = AppleReads(planner), today = ProductPricing.today()
        if let choice = request.subscriptionPrice {
            let (product, schedule, point) = try await selectedPrice(.subscription, appId: request.appId, productId: choice.productId, territory: choice.territory, pricePointId: choice.pricePointId, reads: reads)
            if let start = choice.startDate, start < today { throw PublishFailure.invalid("Choose today or a future subscription price date.") }
            let relevant = schedule.rows.filter { $0.territory == choice.territory && $0.planType == choice.planType }
            guard relevant.allSatisfy({ $0.startKnown && $0.pricePointId != nil }) else { throw PublishFailure.invalid("Apple returned incomplete subscription prices for this territory and plan.") }
            if relevant.contains(where: { $0.startDate == choice.startDate }) {
                guard relevant.contains(where: { $0.startDate == choice.startDate && $0.pricePointId == choice.pricePointId }) else { throw PublishFailure.invalid("Apple already has a different price on this date and plan. Review that scheduled price before replacing it.") }
                planner.notes.append("Apple already has this price point on the selected date and plan. No write is needed.")
                return "Subscription price already set"
            }
            let before = relevant.sorted { ($0.startDate ?? "") < ($1.startDate ?? "") }.map { "\($0.startDate ?? "Now"): \($0.customerPrice ?? "Amount unknown") \($0.currency ?? "currency unknown")\($0.preserved == true ? " · preserved for existing subscribers" : "")" }.joined(separator: "\n")
            let after = "\(choice.startDate ?? "Now"): \(point.customerPrice!) \(point.currency!) · \(choice.planType ?? "standard plan") · \(choice.preserveCurrentPrice ? "request preserving the current price for existing subscribers" : "request applying the new price to existing subscribers")"
            var attributes: [(String, JSONText)] = [("startDate", choice.startDate.map { .string($0) } ?? .null), ("preserveCurrentPrice", .bool(choice.preserveCurrentPrice))]
            if let plan = choice.planType { attributes.append(("planType", .string(plan))) }
            planner.add(.api, method: "POST", path: [.string("subscriptionPrices")], label: "Set \(product.name) price in \(choice.territory)",
                        detail: "Create one reviewed subscription price change. Apple may require subscriber consent for an increase; the API response does not prove that effect.", before: before, after: after,
                        body: .object([("data", .object([("type", .string("subscriptionPrices")), ("attributes", .object(attributes)), ("relationships", .object([("subscription", Apple.relationship("subscriptions", .string(product.id))),
                                                                                                                                                                  ("subscriptionPricePoint", Apple.relationship("subscriptionPricePoints", .string(point.id)))]))]))]),
                        guard: .object([("kind", .string("subscription-price")), ("digest", .string(ProductPricing.subscriptionDigest(product, schedule, point))), ("productId", .string(product.id)), ("territory", .string(choice.territory)), ("pricePointId", .string(point.id))]))
            planner.notes.append("This review requests a specific price point, effective date and existing-subscriber policy. Apple decides whether consent or notifications are needed.")
            return "Subscription price · \(product.name) · \(choice.territory)"
        }
        guard var choice = request.purchasePrice else { throw PublishFailure.invalid("Choose one product price change.") }
        let (product, schedule, point) = try await selectedPrice(.purchase, appId: request.appId, productId: choice.productId, territory: choice.territory, pricePointId: choice.pricePointId, reads: reads)
        let lastAllowed = "\(Int(today.prefix(4))! + 1)-12-31", first = ProductPricing.initial(schedule)
        if first {
            guard choice.startDate == nil else { throw PublishFailure.invalid("The first in-app purchase price must take effect immediately.") }
            guard try await activeTerritory(choice.territory, currency: point.currency, reads: reads) else { throw PublishFailure.invalid("The selected base territory is no longer available with the expected currency.") }
        } else if choice.startDate == nil || choice.startDate! < today || choice.startDate! > lastAllowed { throw PublishFailure.invalid("Choose an in-app purchase price date from today through the end of next year.") }
        let manual = schedule.rows.filter { $0.source == .manual }
        guard manual.count <= 1000, manual.allSatisfy({ $0.startKnown && $0.endKnown && $0.pricePointId != nil && $0.customerPrice != nil && $0.currency != nil }) else {
            throw PublishFailure.invalid("Apple returned an incomplete or unusually large manual price schedule. Review the product's Price Schedule in App Store Connect (Apps → the app → In-App Purchases or Subscriptions).")
        }
        if let others = choice.territoryPoints {
            let checked = try await ProductPricing.chosenPurchasePoints(product, others, reads: reads)
            // A country that already has this price on this date needs nothing; another price on that date must be reviewed first.
            var remaining: [String: String] = [:]
            for (code, id) in others {
                if let same = manual.first(where: { $0.territory == code && $0.startDate == choice.startDate }) {
                    guard same.pricePointId == id else { throw PublishFailure.invalid("\(Self.countryName(code)) already has another manual price on this date. Review that scheduled price before replacing it.") }
                    continue
                }
                remaining[code] = id
            }
            choice.territoryPoints = remaining.isEmpty ? nil : remaining
            planner.notes.append("\(checked.count) other countries or regions get the price chosen for each, such as by a pricing profile.")
        }
        if let same = manual.first(where: { $0.territory == choice.territory && $0.startDate == choice.startDate }), choice.territoryPoints == nil {
            guard same.pricePointId == point.id else { throw PublishFailure.invalid("Apple already has another manual price on this date. Review that scheduled price before replacing it.") }
            planner.notes.append("Apple already has this price point on the selected date. No write is needed.")
            return "In-app purchase price already set"
        }
        // A base price alone gets Apple's comparable prices everywhere, so the purchase becomes available everywhere; chosen prices only where they are set.
        let priceTerritories: [String]
        if let others = choice.territoryPoints { priceTerritories = [choice.territory] + others.keys } else { priceTerritories = try await PricingSetupReads.territories(reads: reads) }
        if let available = try await availabilityForPrices(product, territories: priceTerritories, newTerritories: choice.territoryPoints == nil, planner: planner, reads: reads) {
            guard available.contains(choice.territory) else { throw PublishFailure.invalid("\(product.name) is not available in \(WorkspaceSession.countryName(choice.territory)). Add it under the in-app purchase's Availability in App Store Connect, or choose another country or region.") }
            if let others = choice.territoryPoints {
                let kept = others.filter { available.contains($0.key) }
                if kept.count < others.count { planner.notes.append("\(others.count - kept.count) countries or regions are not in the in-app purchase's Availability and get no price. Add them in App Store Connect under Availability first.") }
                choice.territoryPoints = kept.isEmpty ? nil : kept
            }
        }
        let payload = try ProductPricing.purchasePayload(product, schedule, point, choice)
        let before = manual.sorted { ($0.territory, $0.startDate ?? "") < ($1.territory, $1.startDate ?? "") }.map { "\($0.territory) · \($0.startDate ?? "Now")\($0.endDate.map { " to \($0)" } ?? "") · \($0.customerPrice!) \($0.currency!)" }.joined(separator: "\n")
        let after = "\(before)\(before.isEmpty ? "" : "\n")\(choice.territory) · \(choice.startDate ?? "Now") · \(point.customerPrice!) \(point.currency!) · \(first ? "first base price" : "new manual price")"
        planner.add(.api, method: "POST", path: [.string("inAppPurchasePriceSchedules")], label: "\(first ? "Set first" : "Schedule") \(product.name) price in \(choice.territory)",
                    detail: first ? "Create the first base territory price for this purchase. Apple sets automatically equalized prices for other territories." : "Send the full observed manual price schedule plus one new price. Apple can recalculate automatic prices when the base territory changes.",
                    before: before, after: after, body: payload,
                    guard: .object([("kind", .string("purchase-price")), ("digest", .string(ProductPricing.purchaseDigest(product, schedule, point))), ("productId", .string(product.id)), ("territory", .string(choice.territory)), ("pricePointId", .string(point.id))]
                                   + (choice.pointsJSON.map { [("territoryPoints", $0)] } ?? [])))
        planner.notes.append(first ? "Base territory \(choice.territory) and its immediate price are created. Apple may generate automatically equalized territory prices; check the result in App Store Connect after approval."
                             : "Base territory \(schedule.baseTerritory!) stays selected. All \(manual.count) observed manual price rows are included. Automatic territory prices may change at Apple and must be checked there after approval.")
        return "In-app purchase price · \(product.name) · \(choice.territory)"
    }

    /// Product price write check: the body must be exactly what the reviewed schedule produces, and Apple's schedule must be unchanged.
    func verifyProductPriceWrite(root: String, method: String, parts: [String], body: JSONText?, guardValue: JSONText?, appId: String, client: AppStoreConnectClient) async throws {
        let reads = AppleReads(client), today = ProductPricing.today()
        guard method == "POST", parts.count == 1, let productId = guardValue?["productId"]?.text, let territory = guardValue?["territory"]?.text, let pointId = guardValue?["pricePointId"]?.text else { throw PublishFailure.write("Unsupported product price change.") }
        if root == "subscriptionPrices" {
            guard guardValue?["kind"]?.text == "subscription-price", case .object(let envelope)? = body, envelope.map(\.0) == ["data"], let data = body?["data"], case .object(let fields) = data,
                  Set(fields.map(\.0)) == ["type", "attributes", "relationships"], data["type"]?.text == "subscriptionPrices", case .object(let attributes)? = data["attributes"],
                  attributes.allSatisfy({ ["startDate", "planType", "preserveCurrentPrice"].contains($0.0) }), case .object(let relationships)? = data["relationships"], Set(relationships.map(\.0)) == ["subscription", "subscriptionPricePoint"],
                  data["relationships"]?["subscription"] == Apple.relationship("subscriptions", .string(productId)), data["relationships"]?["subscriptionPricePoint"] == Apple.relationship("subscriptionPricePoints", .string(pointId)),
                  case .bool(let preserve)? = data["attributes"]?["preserveCurrentPrice"] else { throw PublishFailure.write("Unsupported subscription price change.") }
            let choice = try SubscriptionPriceChange(productId: productId, territory: territory, pricePointId: pointId, startDate: data["attributes"]?["startDate"]?.text, planType: data["attributes"]?["planType"]?.text, preserveCurrentPrice: preserve).validated()
            if let start = choice.startDate, start < today { throw PublishFailure.write("The approved subscription price selection changed.") }
            let (product, schedule, point) = try await selectedPrice(.subscription, appId: appId, productId: productId, territory: territory, pricePointId: pointId, reads: reads)
            guard ProductPricing.subscriptionDigest(product, schedule, point) == guardValue?["digest"]?.text else { throw PublishFailure.write("The subscription price changed after approval. Prepare a new review.") }
            return
        }
        guard root == "inAppPurchasePriceSchedules", guardValue?["kind"]?.text == "purchase-price", case .object(let envelope)? = body, Set(envelope.map(\.0)) == ["data", "included"], case .array(let included)? = body?["included"] else { throw PublishFailure.write("Unsupported in-app purchase price schedule change.") }
        let startDate = included.first { $0["id"]?.text == "new-price" }?["attributes"]?["startDate"]?.text
        var reviewed = PurchasePriceChange(productId: productId, territory: territory, pricePointId: pointId, startDate: startDate)
        if let points = guardValue?["territoryPoints"] { guard let parsed = PurchasePriceChange(reviewed.json.setting("territoryPoints", points)) else { throw PublishFailure.write("Unsupported in-app purchase price schedule change.") }; reviewed = parsed }
        let choice = try reviewed.validated()
        if let start = choice.startDate, start < today || start > "\(Int(today.prefix(4))! + 1)-12-31" { throw PublishFailure.write("The approved in-app purchase price date is no longer available.") }
        let (product, schedule, point) = try await selectedPrice(.purchase, appId: appId, productId: productId, territory: territory, pricePointId: pointId, reads: reads)
        guard ProductPricing.purchaseDigest(product, schedule, point) == guardValue?["digest"]?.text else { throw PublishFailure.write("The in-app purchase price schedule changed after approval. Prepare a new review.") }
        if choice.startDate == nil { guard try await activeTerritory(territory, currency: point.currency, reads: reads) else { throw PublishFailure.write("The selected base territory changed after approval. Prepare a new review.") } }
        if let others = choice.territoryPoints { _ = try await ProductPricing.chosenPurchasePoints(product, others, reads: reads) }
        guard Apple.canonical(body!) == Apple.canonical(try ProductPricing.purchasePayload(product, schedule, point, choice)) else { throw PublishFailure.write("The approved in-app purchase price schedule payload changed.") }
    }
}
