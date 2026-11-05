import Foundation

public enum NoSalesFailure: Error, Equatable {
    case invalid, coverage, stale, selection, points, model, read
    public var message: String {
        switch self {
        case .invalid: "Choose a supported period, a sales limit from 0 to 1,000, and a positive reduction. Nothing was saved."
        case .coverage: "The full period needs saved reports for this app. Add the missing days in Sales, then restart the guide. Missing reports are not zero sales."
        case .stale: "Reports, prices, the shared profile or drafts changed. Reload saved data and restart the guide. Nothing was saved."
        case .selection: "The selection contains protected countries, scheduled drafts or prices that cannot be lowered. Review it again. Nothing was saved."
        case .points: "Apple price points could not be checked. Retry the preview. Nothing was saved."
        case .model: "This method could not calculate available prices. Choose another base country, method or smaller selection. Nothing was saved."
        case .read: "Saved reports or pricing could not be verified. Existing reports and drafts are unchanged."
        }
    }
}

public struct NoSalesReview: Equatable, Sendable {
    public let days: Int, beginDate, endDate: String, coveredDays: Int, complete: Bool, revision: String
    public let unitsByTerritory: [String: Double]
    private let units: JSONText
    public init(history: JSONText?, days: Int, endDate: String) throws {
        guard (1...365).contains(days), let last = PeriodDates.number(endDate) else { throw NoSalesFailure.invalid }
        self.days = days; self.endDate = endDate
        let firstDate = String(PeriodDates.text(last - days + 1).prefix(10)); beginDate = firstDate
        let reports = WorkspaceSession.items(history?["reports"])
        var valid = true, covered = 0, previousEnd = last - days
        var totals: [(String, JSONText)] = []
        let included = reports.enumerated().filter { _, item in
            guard let begin = item["beginDate"]?.text.flatMap(PeriodDates.number), let end = item["endDate"]?.text.flatMap(PeriodDates.number) else { valid = false; return false }
            return begin >= last - days + 1 && end <= last
        }.sorted { a, b in
            let left = a.element["beginDate"]?.text ?? "", right = b.element["beginDate"]?.text ?? ""
            return left != right ? left < right : a.offset < b.offset
        }
        for (_, report) in included {
            guard let first = report["beginDate"]?.text.flatMap(PeriodDates.number), let end = report["endDate"]?.text.flatMap(PeriodDates.number), first <= end, first > previousEnd else { valid = false; continue }
            covered += end - first + 1; previousEnd = end
            guard case .object(let pairs)? = report["unitsByTerritory"] else { valid = false; continue }
            for (code, value) in pairs {
                guard case .number(let count) = value, count.isFinite, count.rounded() == count, count >= 0, count <= 9_007_199_254_740_991 else { valid = false; continue }
                let index = totals.firstIndex { $0.0.utf8.elementsEqual(code.utf8) }
                let previous: Double = index.flatMap { if case .number(let n) = totals[$0].1 { n } else { nil } } ?? 0
                let sum = previous + count
                if let index { totals[index].1 = .number(sum) } else { totals.append((code, .number(sum))) }
                if !sum.isFinite || sum > 9_007_199_254_740_991 { valid = false }
            }
        }
        coveredDays = covered; complete = valid && covered == days; units = .object(totals)
        unitsByTerritory = Dictionary(totals.compactMap { code, value in if case .number(let n) = value { (code, n) } else { nil } }, uniquingKeysWith: { _, last in last })
        let english = Locale(identifier: "en")
        let overlaps = reports.enumerated().filter { _, item in (item["endDate"]?.text ?? "") >= firstDate && (item["beginDate"]?.text ?? "") <= endDate }
            .sorted { a, b in
                let order = (a.element["beginDate"]?.text ?? "").compare(b.element["beginDate"]?.text ?? "", locale: english)
                return order == .orderedSame ? a.offset < b.offset : order == .orderedAscending
            }.map { _, report -> JSONText in
                let pairs: [(String, JSONText)] = { if case .object(let pairs)? = report["unitsByTerritory"] { return pairs }; return [] }()
                return .array([report["beginDate"] ?? .null, report["endDate"] ?? .null, report["importedAt"] ?? .null,
                               .array(pairs.sorted { $0.0.compare($1.0, locale: english) == .orderedAscending }.map { .array([.string($0.0), $0.1]) })])
            }
        revision = JSONText.array([history?["accountId"] ?? .null, history?["appId"] ?? .null, .number(Double(days)), .string(endDate), .array(overlaps)]).sha256
    }
    public var json: JSONText { .object([("days", .number(Double(days))), ("beginDate", .string(beginDate)), ("endDate", .string(endDate)), ("coveredDays", .number(Double(coveredDays))), ("complete", .bool(complete)), ("unitsByTerritory", units), ("revision", .string(revision))]) }
}

public enum NoSalesStrategy: Equatable, Sendable {
    case percent(String), reduce(amount: String, base: String), model(method: String, price: String, base: String)
    public func validate() throws {
        switch self {
        case .percent(let reduction):
            guard reduction.range(of: #"^\d{1,2}(?:\.\d{1,2})?$"#, options: .regularExpression) != nil, let value = PricingMath.decimal(reduction), value > 0, value < 100 else { throw NoSalesFailure.invalid }
        case .reduce(let amount, let base):
            guard amount.range(of: #"^\d+(?:\.\d{1,2})?$"#, options: .regularExpression) != nil, let value = PricingMath.decimal(amount), !value.isNaN, value > 0, Self.code(base) else { throw NoSalesFailure.invalid }
        case .model(let method, let price, let base):
            guard ["fx", "same", "ppp", "bigmac"].contains(method), Self.code(base), (try? PricingMath.desired(price)) != nil else { throw NoSalesFailure.invalid }
        }
    }
    static func code(_ text: String) -> Bool { text.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil }
    var base: String? { switch self { case .percent: nil; case .reduce(_, let base), .model(_, _, let base): base } }
}

public struct NoSalesContext: Equatable, Sendable {
    public let accountId, appId: String, profile: PricingProfile, coverage: NoSalesReview, prices: [PriceRow], protected: [String], drafts: [PricingDraft], initialBase: String
    public init(accountId: String, appId: String, profile: PricingProfile, coverage: NoSalesReview, prices: [PriceRow], protected: [String], drafts: [PricingDraft], initialBase: String) {
        self.accountId = accountId; self.appId = appId; self.profile = profile; self.coverage = coverage; self.prices = prices; self.protected = protected; self.drafts = drafts; self.initialBase = initialBase
    }
    public var profileRevision: String { PricingModels.profileRevision(profile) }
    public var countries: [Territory] { prices.map { Territory(code: $0.territory, name: WorkspaceSession.countryName($0.territory), currency: $0.currency) } }
    public func eligible(maxSales: Int) -> [PriceRow] {
        guard (0...1000).contains(maxSales), coverage.complete else { return [] }
        return prices.filter { row in
            (coverage.unitsByTerritory[row.territory] ?? 0) <= Double(maxSales) && !protected.contains(row.territory)
                && !row.currency.isEmpty && (PricingMath.decimal(row.customerPrice).map { !$0.isNaN && $0 > 0 } ?? false)
                && !drafts.contains { $0.territory == row.territory && $0.startDate != nil }
        }
    }
    public func pricesSignature(_ codes: [String]) -> JSONText {
        .array(codes.sorted().map { code in let row = prices.first { $0.territory == code }; return .array([.string(code), .string(row?.currency ?? ""), .string(row?.customerPrice ?? "")]) })
    }
    public func draftsSignature(_ codes: [String]) -> JSONText {
        let english = Locale(identifier: "en")
        return .array(drafts.filter { codes.contains($0.territory) }.sorted { $0.id.compare($1.id, locale: english) == .orderedAscending }.map { row in
            .object([("id", .string(row.id)), ("territory", .string(row.territory)), ("currency", .string(row.currency)), ("amount", .string(row.amount)), ("startDate", row.startDate.map { .string($0) } ?? .null), ("endDate", row.endDate.map { .string($0) } ?? .null)])
        })
    }
    func verify(_ previous: Self, codes: [String], maxSales: Int) throws {
        guard accountId == previous.accountId, appId == previous.appId, profile.id == previous.profile.id,
              profileRevision == previous.profileRevision, coverage.complete, coverage.revision == previous.coverage.revision,
              pricesSignature(codes) == previous.pricesSignature(codes), draftsSignature(codes) == previous.draftsSignature(codes) else { throw NoSalesFailure.stale }
        let available = Set(eligible(maxSales: maxSales).map(\.territory))
        guard codes.allSatisfy(available.contains) else { throw NoSalesFailure.selection }
    }
}

public struct NoSalesReduction: Equatable, Sendable, Identifiable {
    public let territory, currency, before, amount, detail: String
    public var id: String { territory }
}
public struct NoSalesSkipped: Equatable, Sendable, Identifiable { public let territory, reason: String; public var id: String { territory } }
public struct NoSalesProposal: Equatable, Sendable {
    public let context: NoSalesContext, strategy: NoSalesStrategy, maxSales: Int, rows: [NoSalesReduction], skipped: [NoSalesSkipped], warnings: [String]
}

private struct NoSalesStoredReport: Decodable {
    let record: SalesRecord
    enum CodingKeys: CodingKey { case schemaVersion, noSales, source, appSku, productScope }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .schemaVersion) == 1 else { throw NoSalesFailure.read }
        for key in [CodingKeys.noSales, .source, .appSku, .productScope] where values.contains(key) {
            if try values.decodeNil(forKey: key) { throw NoSalesFailure.read }
        }
        record = try SalesRecord(from: decoder)
    }
}

public enum NoSalesGuide {
    static func selection(_ codes: [String], maxSales: Int) throws {
        guard !codes.isEmpty, codes.count <= 200, Set(codes).count == codes.count, codes.allSatisfy(NoSalesStrategy.code), (0...1000).contains(maxSales) else { throw NoSalesFailure.invalid }
    }
    /// Six strategies with downward Apple price-point selection.
    public static func calculate(context: NoSalesContext, codes: [String], maxSales: Int, strategy: NoSalesStrategy, countries: [Territory], points: [PricePoint], rates: [String: FxRate] = [:], index: IndexSnapshot? = nil, pointsUnavailable: Set<String> = []) throws -> (rows: [NoSalesReduction], skipped: [NoSalesSkipped]) {
        try selection(codes, maxSales: maxSales); try strategy.validate()
        guard context.coverage.complete else { throw NoSalesFailure.coverage }
        guard Set(codes).isSubset(of: Set(context.eligible(maxSales: maxSales).map(\.territory))) else { throw NoSalesFailure.selection }
        var models: [ModelPrice] = []
        if case .model(let method, let price, let base) = strategy {
            var profile = context.profile; profile.method = method; profile.guideTerritory = base; profile.rounding = "down"; profile.percentages = [:]
            let currency = countries.first { $0.code == base }?.currency ?? context.prices.first { $0.territory == base }?.currency ?? ""
            guard !currency.isEmpty else { throw NoSalesFailure.model }
            models = try PricingModels.calculate(profile, base: price, countries: countries, guideCurrency: currency, rates: rates, points: points, index: index, pointsUnavailable: pointsUnavailable)
        }
        var rows: [NoSalesReduction] = [], skipped: [NoSalesSkipped] = []
        for code in codes {
            let row = context.prices.first { $0.territory == code }!
            var amount: String?, detail = "", reason = "No positive, lower Apple price point is available."
            switch strategy {
            case .percent(let reduction):
                amount = try? PricingMath.roundedPercent(row.customerPrice, percent: PricingMath.text(100 - PricingMath.decimal(reduction)!), territory: code, rounding: "down", points: points)
                detail = "\(reduction)% reduction, rounded down to an Apple price point."
            case .reduce(let reduction, let base):
                let currency = countries.first { $0.code == base }?.currency ?? context.prices.first { $0.territory == base }?.currency ?? ""
                let rate = row.currency == currency ? "1" : rates[row.currency]?.rate
                if let rate = rate.flatMap(PricingMath.decimal), rate > 0, let current = PricingMath.decimal(row.customerPrice) {
                    let target = current - PricingMath.decimal(reduction)! * rate
                    if target > 0 { amount = PricingMath.select(territory: code, calculated: target, rounding: "down", points: points).selected?.customerPrice }
                    detail = "Reduction of \(reduction) \(currency). \(row.currency == currency ? "Same currency." : "Rate \(PricingMath.text(rate)) · \(rates[row.currency]?.date ?? "") · \(rates[row.currency]?.source ?? "")") Rounded down to an Apple price point."
                } else { reason = "The base currency or dated exchange rate is unavailable." }
            case .model:
                if let model = models.first(where: { $0.territory == code }), model.currency == row.currency, model.pointStatus == "available" { amount = model.amount; detail = model.detail }
                else { reason = models.first { $0.territory == code }?.problem ?? "The model or Apple price-point match is unavailable." }
            }
            guard let amount, let value = PricingMath.decimal(amount), !value.isNaN, value > 0, value < PricingMath.decimal(row.customerPrice)! else { skipped.append(.init(territory: code, reason: reason)); continue }
            guard context.drafts.filter({ $0.territory == code }).allSatisfy({ $0.startDate == nil && PricingMath.decimal($0.amount).map { value < $0 } == true }) else {
                skipped.append(.init(territory: code, reason: "The result must be lower than every existing permanent draft.")); continue
            }
            rows.append(.init(territory: code, currency: row.currency, before: row.customerPrice, amount: amount, detail: detail))
        }
        return (rows, skipped)
    }
}

extension WorkspaceSession {
    private func noSalesSnapshot(accountId: String, appId: String, profileId: String, days: Int, now: Date) throws -> NoSalesContext {
        guard try accounts().contains(where: { $0.id == accountId && $0.appIds.contains(appId) }) else { throw NoSalesFailure.stale }
        let state = try pricingProfiles()
        guard let profile = state.profiles.first(where: { $0.id == profileId }) else { throw NoSalesFailure.stale }
        let records = try storeAccess { store -> [SalesRecord] in
            let scope = "\(accountId):\(appId)"
            if try store.document(namespace: "sales_index", key: scope) == nil, let legacy = try store.document(namespace: "sales", key: scope) {
                let value = try JSONText.parse(legacy.payload)
                guard value["accountId"]?.text == accountId, value["appId"]?.text == appId else { throw NoSalesFailure.read }
                if value["schemaVersion"] == .number(1) { return [try JSONDecoder().decode(NoSalesStoredReport.self, from: legacy.payload).record] }
                guard value["schemaVersion"] == .number(2), case .array? = value["reports"] else { throw NoSalesFailure.read }
            }
            return try PartitionedReports.items(NoSalesStoredReport.self, family: "sales", legacyKey: "reports", accountId: accountId, appId: appId, store: store).map(\.record)
        }
        // Imports and pricing use one source, overlap and safe-total validator, including literal Unicode semantics.
        try SalesFileFormats.validate(records, accountId: accountId, appId: appId)
        let exists = try storeAccess { try PartitionedReports.revision(family: "sales", accountId: accountId, appId: appId, store: $0) }
        let history: JSONText? = exists.index == nil && exists.legacy == nil ? nil : .object([("accountId", .string(accountId)), ("appId", .string(appId)), ("reports", .array(records.map(\.json)))])
        let coverage = try NoSalesReview(history: history, days: days, endDate: SalesReports.latestCompletedDay(now: now))
        guard let snapshot = try savedPricing(accountId: accountId, appId: appId)?.snapshot else { throw NoSalesFailure.read }
        let prices = PricingMath.current(snapshot.rows, today: PeriodDates.text(now)).values.sorted { $0.territory < $1.territory }
        // Shape errors must not silently drop a protection or scheduled draft.
        let rawProtection = try storeAccess { try stateDocument($0, "price_protection").1 }, rawDrafts = try storeAccess { try stateDocument($0, "pricing_drafts").1 }
        if let rawProtection { guard rawProtection["schemaVersion"] == .number(1), case .array? = rawProtection["locks"] else { throw NoSalesFailure.read } }
        if let rawDrafts { guard rawDrafts["schemaVersion"] == .number(1), case .array? = rawDrafts["drafts"] else { throw NoSalesFailure.read } }
        let locks = Self.items(rawProtection?["locks"])
        func matches(_ text: String?, _ pattern: String) -> Bool { text?.range(of: pattern, options: .regularExpression) != nil }
        guard locks.count <= 5000, locks.allSatisfy({ matches($0["accountId"]?.text, "^[A-Za-z0-9_-]+$") && matches($0["appId"]?.text, "^[0-9]+$") && $0["priceProduct"]?.text == "paid-app" && $0["territory"]?.text.map(NoSalesStrategy.code) == true && $0["currency"]?.text.map(NoSalesStrategy.code) == true && matches($0["customerPrice"]?.text, #"^(?:0|[1-9][0-9]*)(?:\.[0-9]{1,4})?$"#) && $0["protectedAt"]?.text.flatMap({ try? CustomerReview.isoDate($0) }) != nil }),
              Set(locks.map { "\($0["accountId"]!.text!):\($0["appId"]!.text!):\($0["territory"]!.text!)" }).count == locks.count else { throw NoSalesFailure.read }
        let all = Self.items(rawDrafts?["drafts"]), parsed = all.compactMap(PricingDraft.init)
        guard all.count <= 2000, parsed.count == all.count, Set(parsed.map(\.id)).count == all.count, zip(all, parsed).allSatisfy({ raw, draft in
            func date(_ key: String) -> Bool { raw[key] == .null || raw[key]?.text.flatMap(PeriodDates.number) != nil }
            return matches(draft.id, "^[a-f0-9-]{36}$") && matches(draft.accountId, "^[A-Za-z0-9_-]+$") && matches(draft.appId, "^[0-9]+$") && date("startDate") && date("endDate") && (draft.startDate == nil) == (draft.endDate == nil) && (draft.startDate ?? "") <= (draft.endDate ?? "") && NoSalesStrategy.code(draft.territory) && NoSalesStrategy.code(draft.currency) && ((try? PricingMath.desired(draft.amount)) != nil || matches(draft.amount, #"^0(?:\.0{1,4})?$"#))
        }) else { throw NoSalesFailure.read }
        var scheduled: [String: [PricingDraft]] = [:]
        for draft in parsed where draft.startDate != nil {
            let key = "\(draft.accountId):\(draft.appId):\(draft.territory)"
            guard !(scheduled[key] ?? []).contains(where: { $0.startDate! <= draft.endDate! && draft.startDate! <= $0.endDate! }) else { throw NoSalesFailure.read }
            scheduled[key, default: []].append(draft)
        }
        let drafts = parsed.filter { $0.accountId == accountId && $0.appId == appId }
        let protected = locks.filter { $0["accountId"]?.text == accountId && $0["appId"]?.text == appId && $0["priceProduct"]?.text == "paid-app" }.compactMap { $0["territory"]?.text }
        let currency = prices.first { $0.territory == profile.guideTerritory }?.currency ?? ""
        let target = try storeAccess { store in Self.items(try stateDocument(store, "pricing_targets").1?["targets"]).first { $0["accountId"]?.text == accountId && $0["appId"]?.text == appId && $0["profileId"]?.text == profileId && $0["guideTerritory"]?.text == profile.guideTerritory && $0["currency"]?.text == currency }?["amount"]?.text }
        return NoSalesContext(accountId: accountId, appId: appId, profile: profile, coverage: coverage, prices: prices, protected: protected, drafts: drafts, initialBase: target ?? prices.first { $0.territory == profile.guideTerritory }?.customerPrice ?? "")
    }
    public func noSalesContext(accountId: String, appId: String, profileId: String, days: Int, now: Date = Date()) throws -> NoSalesContext {
        do { return try noSalesSnapshot(accountId: accountId, appId: appId, profileId: profileId, days: days, now: now) }
        catch let failure as NoSalesFailure { throw failure } catch { throw NoSalesFailure.read }
    }
    /// Profile, protection and drafts follow the existing lock order. A single SQL transaction
    /// keeps the report/current-price recheck and draft replacement on the same database snapshot.
    private func reviewNoSales<T>(account: Account, previous: NoSalesContext, codes: [String], maxSales: Int, client: AppStoreConnectClient, now: @Sendable () -> Date, change: (EncryptedDocumentStore, NoSalesContext) throws -> (T, [EncryptedDocumentStore.Write])) throws -> T {
        try storeAccess { store in
            try PricingLock.holding([.profiles, .protection, .drafts], in: store) {
                var result: T?
                try store.transaction { _ in
                    try requirePublishingAccount(account, appId: previous.appId, client: client)
                    let current = try noSalesSnapshot(accountId: account.id, appId: previous.appId, profileId: previous.profile.id, days: previous.coverage.days, now: now())
                    try current.verify(previous, codes: codes, maxSales: maxSales)
                    let updated = try change(store, current); result = updated.0; return updated.1
                }
                return result!
            }
        }
    }
    /// All Apple/catalog/rate downloads finish before review locks are acquired. No Apple writes occur.
    private func prepareNoSales(account: Account, previous: NoSalesContext, codes: [String], maxSales: Int, strategy: NoSalesStrategy, client: AppStoreConnectClient, sources: PricingSources, now: @Sendable () -> Date) async throws -> NoSalesProposal {
        try NoSalesGuide.selection(codes, maxSales: maxSales); try strategy.validate()
        guard previous.accountId == account.id else { throw NoSalesFailure.stale }
        try requirePublishingAccount(account, appId: previous.appId, client: client)
        guard previous.coverage.complete else { throw NoSalesFailure.coverage }
        _ = try await refreshPricing(account: account, appId: previous.appId, client: client, now: now())
        let context = try noSalesContext(accountId: account.id, appId: previous.appId, profileId: previous.profile.id, days: previous.coverage.days, now: now())
        try context.verify(previous, codes: codes, maxSales: maxSales)
        var catalog: [Territory] = [], points: [PricePoint] = [], rates: [String: FxRate] = [:], index: IndexSnapshot?, failed = Set<String>(), warnings: [String] = []
        if strategy.base != nil {
            catalog = (try? await territories(account: account, client: client, now: now())) ?? []
            let needed = codes + [strategy.base!]
            catalog = catalog.filter { needed.contains($0.code) }
            for code in needed where !catalog.contains(where: { $0.code == code }) { catalog.append(Territory(code: code, name: Self.countryName(code), currency: context.prices.first { $0.territory == code }?.currency ?? "")) }
        }
        switch strategy {
        case .percent: break
        case .reduce(_, let base), .model("fx", _, let base):
            guard let currency = catalog.first(where: { $0.code == base })?.currency, !currency.isEmpty else { throw NoSalesFailure.model }
            let quotes = Array(Set(codes.compactMap { code in
                if case .model = strategy { return catalog.first { $0.code == code }?.currency }
                return context.prices.first { $0.territory == code }?.currency
            }))
            guard let loaded = try? await fxRates(base: currency, quotes: quotes, sources: sources, now: now()) else { throw NoSalesFailure.model }
            rates = loaded.rates
            if !loaded.missing.isEmpty { warnings.append("Some exchange rates are unavailable; affected countries are skipped.") }
            if !loaded.stale.isEmpty { warnings.append("Some rates use a dated local cache. Check the country details.") }
        case .model(let method, _, _) where method == "ppp" || method == "bigmac":
            index = try? await pricingIndex(method: method, catalog: catalog, sources: sources)
            if index == nil { warnings.append("Index data is unavailable; affected countries are skipped.") }
        default: break
        }
        let pointCodes = strategy.base.map { Array(Set(codes + [$0])).sorted() } ?? codes
        let read = try await PricePointCatalog.readAll(appId: previous.appId, territories: pointCodes, client: client)
        if !read.failed.isEmpty { guard case .model = strategy else { throw NoSalesFailure.points }; failed.formUnion(read.failed) }
        points += read.points
        if !failed.isEmpty { warnings.append("Some Apple price points are unavailable; affected countries are skipped.") }
        let result = try NoSalesGuide.calculate(context: context, codes: codes, maxSales: maxSales, strategy: strategy, countries: catalog, points: points, rates: rates, index: index, pointsUnavailable: failed)
        return try reviewNoSales(account: account, previous: previous, codes: codes, maxSales: maxSales, client: client, now: now) { _, current in
            (NoSalesProposal(context: current, strategy: strategy, maxSales: maxSales, rows: result.rows, skipped: result.skipped, warnings: warnings), [])
        }
    }
    public func previewNoSales(account: Account, context: NoSalesContext, codes: [String], maxSales: Int, strategy: NoSalesStrategy, client: AppStoreConnectClient, sources: PricingSources = PricingSources(), now: @Sendable () -> Date = Date.init) async throws -> NoSalesProposal {
        try await prepareNoSales(account: account, previous: context, codes: codes, maxSales: maxSales, strategy: strategy, client: client, sources: sources, now: now)
    }
    /// Explicit local save redoes the proposal and compares the exact selected amounts before committing.
    /// Another save, changed reporting day or protected country invalidates the review; it is never retried.
    public func saveNoSales(account: Account, proposal: NoSalesProposal, codes: [String], client: AppStoreConnectClient, sources: PricingSources = PricingSources(), now: @Sendable () -> Date = Date.init) async throws -> [PricingDraft] {
        try NoSalesGuide.selection(codes, maxSales: proposal.maxSales)
        guard Set(codes).isSubset(of: Set(proposal.rows.map(\.territory))) else { throw NoSalesFailure.selection }
        let fresh = try await prepareNoSales(account: account, previous: proposal.context, codes: codes, maxSales: proposal.maxSales, strategy: proposal.strategy, client: client, sources: sources, now: now)
        guard fresh.rows.count == codes.count, fresh.rows.allSatisfy({ row in proposal.rows.contains { $0.territory == row.territory && $0.currency == row.currency && $0.amount.utf8.elementsEqual(row.amount.utf8) } }) else { throw NoSalesFailure.stale }
        return try reviewNoSales(account: account, previous: proposal.context, codes: codes, maxSales: proposal.maxSales, client: client, now: now) { store, _ in
            let created = CustomerReview.isoString(now())
            let drafts = fresh.rows.map { PricingDraft(id: UUID().uuidString.lowercased(), accountId: account.id, appId: proposal.context.appId, territory: $0.territory, currency: $0.currency, amount: $0.amount, startDate: nil, endDate: nil, createdAt: created) }
            let all = Self.items(try stateDocument(store, "pricing_drafts").1?["drafts"])
            let kept = all.filter { item in !(item["accountId"]?.text == account.id && item["appId"]?.text == proposal.context.appId && codes.contains(item["territory"]?.text ?? "") && item["startDate"]?.text == nil) }
            guard kept.count + drafts.count <= 2000 else { throw NoSalesFailure.invalid }
            return (drafts, [.put(namespace: "pricing_drafts", key: "current", json: JSONText.object([("schemaVersion", .number(1)), ("drafts", .array(kept + drafts.map(\.json)))]).data)])
        }
    }
}
