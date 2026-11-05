import Foundation

public enum PricingFailure: Error, Equatable {
    case invalid(String), stale, selection, scheduled, points, unavailable, read, access

    public var message: String {
        switch self {
        case .invalid(let text): text
        case .stale: "Saved prices or drafts changed in another window or import. Reload and compare again before saving. Nothing was saved."
        case .selection: "The selection has changed or contains protected countries. Refresh and review it again. Nothing was saved."
        case .scheduled: "A selected country already has an Apple price scheduled for these dates. Nothing was saved."
        case .points: "Apple price points could not be matched. Retry the preview or change the rounding rule. Nothing was saved."
        case .unavailable: "The current Apple price is unavailable. Refresh prices and retry."
        case .read: "Saved pricing could not be read. Your saved prices and drafts are unchanged."
        case .access: "Apple did not allow this key to read prices. In App Store Connect, check the key's role under Users and Access → Integrations and your app access under Users and Access → People."
        }
    }
}

/// One Apple price for a territory, manual or automatic.
public struct PriceRow: Equatable, Sendable, Identifiable, Codable {
    public let id, territory, currency, customerPrice, proceeds: String
    public let startDate, endDate: String?
    public let source: String

    var json: JSONText {
        .object([("id", .string(id)), ("territory", .string(territory)), ("currency", .string(currency)), ("customerPrice", .string(customerPrice)), ("proceeds", .string(proceeds)),
                 ("startDate", startDate.map { .string($0) } ?? .null), ("endDate", endDate.map { .string($0) } ?? .null), ("source", .string(source))])
    }

    public init(id: String, territory: String, currency: String, customerPrice: String, proceeds: String, startDate: String?, endDate: String?, source: String) {
        self.id = id; self.territory = territory; self.currency = currency; self.customerPrice = customerPrice; self.proceeds = proceeds; self.startDate = startDate; self.endDate = endDate; self.source = source
    }

    init?(_ value: JSONText) {
        guard let id = value["id"]?.text, let territory = value["territory"]?.text, let currency = value["currency"]?.text, let price = value["customerPrice"]?.text,
              let proceeds = value["proceeds"]?.text, let source = value["source"]?.text, ["manual", "automatic"].contains(source) else { return nil }
        self.init(id: id, territory: territory, currency: currency, customerPrice: price, proceeds: proceeds, startDate: value["startDate"]?.text, endDate: value["endDate"]?.text, source: source)
    }
}

public struct PricingSnapshot: Equatable, Sendable, Codable {
    public let baseTerritory, baseCurrency, fetchedAt: String
    public let rows: [PriceRow]
}

public struct SavedPricing: Equatable, Sendable, Codable { public let checkedAt: String; public let snapshot: PricingSnapshot?; public let code: String? }
public struct PricePoint: Equatable, Sendable {
    public let id, territory, customerPrice: String
    public init(id: String, territory: String, customerPrice: String) { self.id = id; self.territory = territory; self.customerPrice = customerPrice }
}
public struct Territory: Equatable, Sendable, Identifiable { public let code, name, currency: String; public var id: String { code } }

public struct PriceProtection: Equatable, Sendable, Codable { public let territory, customerPrice, currency, protectedAt: String }

public struct PricingDraft: Equatable, Sendable, Identifiable, Codable {
    public let id, accountId, appId, territory, currency, amount, createdAt: String
    public let startDate, endDate: String?
    var json: JSONText {
        .object([("id", .string(id)), ("accountId", .string(accountId)), ("appId", .string(appId)), ("territory", .string(territory)), ("currency", .string(currency)), ("amount", .string(amount)),
                 ("startDate", startDate.map { .string($0) } ?? .null), ("endDate", endDate.map { .string($0) } ?? .null), ("createdAt", .string(createdAt))])
    }
    init(id: String, accountId: String, appId: String, territory: String, currency: String, amount: String, startDate: String?, endDate: String?, createdAt: String) {
        self.id = id; self.accountId = accountId; self.appId = appId; self.territory = territory; self.currency = currency; self.amount = amount; self.startDate = startDate; self.endDate = endDate; self.createdAt = createdAt
    }
    init?(_ value: JSONText) {
        guard let id = value["id"]?.text, let account = value["accountId"]?.text, let app = value["appId"]?.text, let territory = value["territory"]?.text,
              let currency = value["currency"]?.text, let amount = value["amount"]?.text, let created = value["createdAt"]?.text else { return nil }
        self.init(id: id, accountId: account, appId: app, territory: territory, currency: currency, amount: amount, startDate: value["startDate"]?.text, endDate: value["endDate"]?.text, createdAt: created)
    }
}

public enum PricingMath {
    static let posix = Locale(identifier: "en_US_POSIX")
    public static func decimal(_ text: String) -> Decimal? {
        guard text.range(of: #"^-?\d+(?:\.\d+)?$"#, options: .regularExpression) != nil else { return nil }
        return Decimal(string: text, locale: posix)
    }
    public static func text(_ value: Decimal) -> String { NSDecimalNumber(decimal: value).stringValue }

    /// A positive guide price with up to four decimals.
    public static func desired(_ value: String) throws -> Decimal {
        guard value.range(of: #"^(?:0|[1-9]\d{0,6})(?:\.\d{1,4})?$"#, options: .regularExpression) != nil, let amount = decimal(value), amount > 0 else {
            throw PricingFailure.invalid("Enter a positive guide-country selling price with up to four decimals.")
        }
        return amount
    }

    /// One rounding rule for model prices and country overrides. Ties choose the higher point.
    public static func select(territory: String, calculated: Decimal, rounding: String, points: [PricePoint]) -> (selected: PricePoint?, exact: PricePoint?) {
        var candidates: [(PricePoint, Decimal)] = []
        for point in points where point.territory == territory { if let amount = decimal(point.customerPrice) { candidates.append((point, amount)) } }
        candidates.sort { (left: (PricePoint, Decimal), right: (PricePoint, Decimal)) -> Bool in left.1 != right.1 ? left.1 < right.1 : left.0.id < right.0.id }
        let exact = candidates.first { $0.1 == calculated }
        switch rounding {
        case "exact": return (exact?.0, exact?.0)
        case "up": return (candidates.first { $0.1 >= calculated }?.0, exact?.0)
        case "down": return (candidates.last { $0.1 <= calculated }?.0, exact?.0)
        default:
            var best: (PricePoint, Decimal)?
            for candidate in candidates {
                guard let current = best else { best = candidate; continue }
                let difference = abs(candidate.1 - calculated), bestDifference = abs(current.1 - calculated)
                if difference < bestDifference || (difference == bestDifference && candidate.1 > current.1) { best = candidate }
            }
            return (best?.0, exact?.0)
        }
    }

    static func abs(_ value: Decimal) -> Decimal { value < 0 ? -value : value }

    /// A percentage of the current price, rounded half up to four decimals.
    public static func percentOf(_ current: String, percent: String) throws -> String {
        let base = try desired(current)
        guard percent.range(of: #"^\d+(?:\.\d{1,2})?$"#, options: .regularExpression) != nil, let ratio = decimal(percent), ratio > 0, ratio <= 1000 else {
            throw PricingFailure.invalid("Enter a percentage above 0 and up to 1000.")
        }
        var raw = base * ratio / 100, rounded = Decimal()
        NSDecimalRound(&rounded, &raw, 4, .plain)
        let amount = text(rounded)
        _ = try desired(amount)
        return amount
    }

    public static func roundedPercent(_ current: String, percent: String, territory: String, rounding: String, points: [PricePoint]) throws -> String {
        let calculated = try percentOf(current, percent: percent)
        if rounding == "exact" { return calculated }
        guard let selected = select(territory: territory, calculated: decimal(calculated)!, rounding: rounding, points: points).selected else {
            throw PricingFailure.invalid("No available Apple price point matches this rounding rule. Change the rule or retry the preview.")
        }
        return selected.customerPrice
    }

    /// The price in effect today per territory; a manual price wins a tie with an automatic one.
    public static func current(_ rows: [PriceRow], today: String) -> [String: PriceRow] {
        var selected: [String: PriceRow] = [:]
        for row in rows {
            guard !row.territory.isEmpty, row.startDate.map({ $0 <= today }) ?? true, row.endDate.map({ $0 >= today }) ?? true else { continue }
            let previous = selected[row.territory]
            if previous == nil || (row.startDate ?? "") > (previous!.startDate ?? "") || ((row.startDate ?? "") == (previous!.startDate ?? "") && row.source == "manual" && previous!.source != "manual") { selected[row.territory] = row }
        }
        return selected
    }

    public static func scheduledConflict(_ rows: [PriceRow], territory: String, start: String, end: String, today: String) -> Bool {
        rows.contains { $0.territory == territory && ($0.startDate.map { $0 > today && $0 <= end } ?? false) && ($0.endDate.map { $0 >= start } ?? true) }
    }

    static var today: String { ReportTables.dayFormat.string(from: Date()) }
}

extension WorkspaceSession {
    static func linked(_ resource: AppStoreConnectClient.Resource, _ name: String) -> String? {
        guard case .object(let relation)? = resource.relationships?[name], case .object(let data)? = relation["data"], case .string(let id)? = data["id"] else { return nil }
        return id
    }

    static func priceRows(_ page: (data: [AppStoreConnectClient.Resource], included: [AppStoreConnectClient.Resource]), source: String) -> [PriceRow] {
        let included = Dictionary(page.included.map { ("\($0.type):\($0.id)", $0) }, uniquingKeysWith: { first, _ in first })
        func value(_ item: JSONValue?) -> String { switch item { case .string(let text)?: text; case .number(let number)?: JSONText.number(number); default: "" } }
        return page.data.filter { $0.type == "appPrices" }.map { item in
            let territory = linked(item, "territory") ?? "", point = linked(item, "appPricePoint").flatMap { included["appPricePoints:\($0)"] }
            return PriceRow(id: item.id, territory: territory, currency: value(included["territories:\(territory)"]?.attributes?["currency"]),
                            customerPrice: value(point?.attributes?["customerPrice"]), proceeds: value(point?.attributes?["proceeds"]),
                            startDate: item.attributes?["startDate"]?.string, endDate: item.attributes?["endDate"]?.string, source: source)
        }
    }

    /// Reads the app's price schedule from App Store Connect and saves it with its outcome; a failed read keeps the last prices.
    public func refreshPricing(account: Account, appId: String, client: AppStoreConnectClient, now: Date = Date()) async throws -> PricingSnapshot {
        _ = try currentAccount(account, client: client); try reviewsScope(account, appId: appId); try Task.checkCancellation()
        guard account.appIds.contains(appId) else { throw PricingFailure.invalid("App is not configured for this account.") }
        do {
            guard let schedule = try await client.get("/v1/apps/\(appId)/appPriceSchedule").first, schedule.type == "appPriceSchedules" else { throw PricingFailure.unavailable }
            guard let base = try await client.get("/v1/appPriceSchedules/\(schedule.id)/baseTerritory").first, base.type == "territories" else { throw PricingFailure.unavailable }
            let query = "?limit=200&include=appPricePoint%2Cterritory"
            async let manual = client.listWithIncluded("/v1/appPriceSchedules/\(schedule.id)/manualPrices\(query)")
            async let automatic = client.listWithIncluded("/v1/appPriceSchedules/\(schedule.id)/automaticPrices\(query)")
            let rows = (Self.priceRows(try await manual, source: "manual") + Self.priceRows(try await automatic, source: "automatic"))
                .sorted { ($0.territory, $0.startDate ?? "") < ($1.territory, $1.startDate ?? "") }
            let snapshot = PricingSnapshot(baseTerritory: base.id, baseCurrency: base.attributes?["currency"]?.string ?? "", fetchedAt: CustomerReview.isoString(now), rows: rows)
            try Task.checkCancellation(); _ = try currentAccount(account, client: client); try reviewsScope(account, appId: appId)
            try savePricing(accountId: account.id, appId: appId, checkedAt: snapshot.fetchedAt, snapshot: snapshot, code: nil)
            return snapshot
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
            _ = try currentAccount(account, client: client); try reviewsScope(account, appId: appId)
            let code: String
            switch error { case AppStoreConnectClient.Failure.agreement, AccountFailure.agreement: code = "SB-APPLE-AGREEMENT"; case AppStoreConnectClient.Failure.status(401): code = "SB-APPLE-AUTH"; case AppStoreConnectClient.Failure.status(403): code = "SB-APPLE-ACCESS"; default: code = "SB-SYNC-PRICING" }
            try? savePricing(accountId: account.id, appId: appId, checkedAt: CustomerReview.isoString(Date()), snapshot: nil, code: code)
            throw error
        }
    }

    func savePricing(accountId: String, appId: String, checkedAt: String, snapshot: PricingSnapshot?, code: String?) throws {
        try storeAccess { store in
            try store.transaction { current in
                let previous = try current("apple_prices", "\(accountId):\(appId)").map { try JSONText.parse($0.payload) }
                if let saved = previous?["checkedAt"]?.text, saved > checkedAt { return [] }
                var fields: [(String, JSONText)] = [("checkedAt", .string(checkedAt))]
                if let snapshot {
                    fields.append(("snapshot", .object([("baseTerritory", .string(snapshot.baseTerritory)), ("baseCurrency", .string(snapshot.baseCurrency)), ("rows", .array(snapshot.rows.map(\.json))), ("fetchedAt", .string(snapshot.fetchedAt))])))
                }
                if let code { fields.append(("code", .string(code))) }
                // A failed read keeps the last prices Apple returned.
                if snapshot == nil, let kept = previous?["snapshot"] { fields.append(("snapshot", kept)) }
                return [.put(namespace: "apple_prices", key: "\(accountId):\(appId)", json: JSONText.object(fields).data)]
            }
        }
    }

    public func savedPricing(accountId: String, appId: String) throws -> SavedPricing? {
        try storeAccess { store in
            guard let document = try store.document(namespace: "apple_prices", key: "\(accountId):\(appId)") else { return nil }
            let value = try JSONText.parse(document.payload)
            guard let checked = value["checkedAt"]?.text, ReportTimestamps.valid(checked), value["code"].map({ $0.text.map { ReportingMessages.values[$0] != nil } ?? false }) ?? true else { throw PricingFailure.read }
            let snapshot: PricingSnapshot?
            if let raw = value["snapshot"] {
                guard let base = raw["baseTerritory"]?.text, let currency = raw["baseCurrency"]?.text, let fetched = raw["fetchedAt"]?.text, ReportTimestamps.valid(fetched), case .array(let rows)? = raw["rows"] else { throw PricingFailure.read }
                let prices = try rows.map { row -> PriceRow in
                    guard ["manual", "automatic"].contains(row["source"]?.text ?? ""), ["startDate", "endDate"].allSatisfy({ row[$0] == .null || row[$0]?.text != nil }), let price = PriceRow(row) else { throw PricingFailure.read }; return price
                }
                snapshot = PricingSnapshot(baseTerritory: base, baseCurrency: currency, fetchedAt: fetched, rows: prices)
            } else { snapshot = nil }
            guard snapshot != nil || value["code"] != nil else { throw PricingFailure.read }
            return SavedPricing(checkedAt: checked, snapshot: snapshot, code: value["code"]?.text)
        }
    }

    /// Apple's territories with their currencies, read once per day per account.
    public func territories(account: Account, client: AppStoreConnectClient, now: Date = Date()) async throws -> [Territory] {
        if let cached = pricingCaches.territories(account: account.id, now: now) { return cached }
        let english = Locale(identifier: "en_US")
        var unique: [String: Territory] = [:]
        for item in try await client.list("/v1/territories?fields%5Bterritories%5D=currency&limit=200") where item.type == "territories" && item.id.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil {
            guard let currency = item.attributes?["currency"]?.string, currency.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil else { continue }
            unique[item.id] = Territory(code: item.id, name: Self.countryName(item.id, locale: english), currency: currency)
        }
        let value = unique.values.sorted { ($0.name, $0.code) < ($1.name, $1.code) }
        guard !value.isEmpty else { throw PricingFailure.unavailable }
        pricingCaches.rememberTerritories(value, account: account.id, now: now)
        return value
    }

    public static func countryName(_ alpha3: String, locale: Locale = Locale(identifier: "en_US")) -> String {
        let alpha2 = Territories.alpha3.first { $0.value == alpha3 }?.key
        return alpha2.flatMap { locale.localizedString(forRegionCode: $0) } ?? alpha3
    }

    /// Apple's price points for up to 25 territories.
    public func pricePoints(appId: String, territories: [String], client: AppStoreConnectClient) async throws -> [PricePoint] {
        try await PricePointCatalog.read(appId: appId, territories: territories, client: client)
    }

    // MARK: Protection and country drafts

    func stateDocument(_ store: EncryptedDocumentStore, _ namespace: String) throws -> (EncryptedDocumentStore.Document?, JSONText?) {
        try PricingState.read(store, namespace)
    }

    func writeState(_ store: EncryptedDocumentStore, _ namespace: String, previous: EncryptedDocumentStore.Document?, value: JSONText) throws {
        try PricingState.replace(store, namespace, previous: previous, value: value)
    }

    public func priceProtection(accountId: String, appId: String) throws -> [PriceProtection] {
        try storeAccess { store in
            Self.items(try stateDocument(store, "price_protection").1?["locks"]).filter { $0["accountId"]?.text == accountId && $0["appId"]?.text == appId && $0["priceProduct"]?.text == "paid-app" }
                .compactMap { lock in
                    guard let territory = lock["territory"]?.text, let price = lock["customerPrice"]?.text, let currency = lock["currency"]?.text, let at = lock["protectedAt"]?.text else { return nil }
                    return PriceProtection(territory: territory, customerPrice: price, currency: currency, protectedAt: at)
                }
        }
    }

    /// Keeps the current Apple price for these countries: protected prices are never changed by drafts or models.
    public func protectPrices(accountId: String, appId: String, prices: [(territory: String, customerPrice: String, currency: String)], now: Date = Date()) throws {
        guard prices.allSatisfy({ $0.territory.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil && $0.currency.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil
            && $0.customerPrice.range(of: #"^(?:0|[1-9][0-9]*)(?:\.[0-9]{1,4})?$"#, options: .regularExpression) != nil }) else { throw PricingFailure.unavailable }
        try storeAccess { store in
            try PricingLock.holding([.protection], in: store) {
                let (document, value) = try stateDocument(store, "price_protection")
                var locks = Self.items(value?["locks"])
                for price in prices where !locks.contains(where: { $0["accountId"]?.text == accountId && $0["appId"]?.text == appId && $0["priceProduct"]?.text == "paid-app" && $0["territory"]?.text == price.territory }) {
                    locks.append(.object([("accountId", .string(accountId)), ("appId", .string(appId)), ("priceProduct", .string("paid-app")), ("territory", .string(price.territory)),
                                          ("customerPrice", .string(price.customerPrice)), ("currency", .string(price.currency)), ("protectedAt", .string(CustomerReview.isoString(now)))]))
                }
                try writeState(store, "price_protection", previous: document, value: .object([("schemaVersion", .number(1)), ("locks", .array(locks))]))
            }
        }
    }

    public func unprotectPrice(accountId: String, appId: String, territory: String) throws {
        try storeAccess { store in
            try PricingLock.holding([.protection], in: store) {
                let (document, value) = try stateDocument(store, "price_protection")
                let locks = Self.items(value?["locks"]).filter { !($0["accountId"]?.text == accountId && $0["appId"]?.text == appId && $0["priceProduct"]?.text == "paid-app" && $0["territory"]?.text == territory) }
                try writeState(store, "price_protection", previous: document, value: .object([("schemaVersion", .number(1)), ("locks", .array(locks))]))
            }
        }
    }

    public func pricingDrafts(accountId: String, appId: String) throws -> [PricingDraft] {
        try storeAccess { store in Self.items(try stateDocument(store, "pricing_drafts").1?["drafts"]).compactMap(PricingDraft.init).filter { $0.accountId == accountId && $0.appId == appId } }
    }

    /// Saves country price drafts through `SaveCountryDrafts`, on this session's connection and under its access checks.
    public func saveCountryDrafts(accountId: String, appId: String, amounts: [(territory: String, currency: String, amount: String)], startDate: String?, endDate: String?, now: Date = Date()) throws -> [PricingDraft] {
        let save = try SaveCountryDrafts(accountId: accountId, appId: appId, amounts: amounts, startDate: startDate, endDate: endDate, now: now)
        try storeAccess(save.write)
        return save.drafts
    }

    public func removePricingDraft(accountId: String, appId: String, id: String) throws {
        try storeAccess { store in
            try PricingLock.holding([.drafts], in: store) {
                let (document, value) = try stateDocument(store, "pricing_drafts")
                let drafts = Self.items(value?["drafts"]).filter { !($0["id"]?.text == id && $0["accountId"]?.text == accountId && $0["appId"]?.text == appId) }
                try writeState(store, "pricing_drafts", previous: document, value: .object([("schemaVersion", .number(1)), ("drafts", .array(drafts))]))
            }
        }
    }
}
