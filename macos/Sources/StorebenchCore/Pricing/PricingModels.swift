import Foundation

public struct PricingProfile: Equatable, Sendable, Identifiable {
    public var id, name, guideTerritory, rounding, method: String
    public var percentages: [String: Double]

    public static let methods = [("custom", "Your country percentages"), ("same", "Same for all"), ("fx", "Currency conversion"), ("ppp", "World Bank purchasing power"), ("bigmac", "Big Mac Index")]
    public static let roundings = [("nearest", "Nearest Apple price"), ("up", "Round up"), ("down", "Round down"), ("exact", "Exact amount only")]
    /// The method's name for a Price Strategy choice; World Bank purchasing power is also known as PPP.
    public static func name(_ method: String) -> String { method == "ppp" ? "World Bank purchasing power (PPP)" : methods.first { $0.0 == method }?.1 ?? method }
    /// What a method does with the guide price, in one plain sentence.
    public static func explanation(_ method: String) -> String {
        switch method {
        case "custom": "Converts the guide price with current exchange rates, then scales each country by the percentage you set for it in the profile."
        case "same": "Uses the same number in every currency, without converting it, such as 4.99 everywhere."
        case "fx": "Converts the guide price with current exchange rates, so the price is about the same everywhere in your own currency."
        case "ppp": "Scales the guide price by the World Bank's purchasing power data, so countries with lower price levels pay less."
        case "bigmac": "Scales the guide price by the local price of a Big Mac from The Economist's Big Mac Index, so prices follow what things cost locally."
        default: "Applies the profile to the guide price."
        }
    }
    /// The same explanation for Apple's own comparable prices, which need no profile.
    public static let appleExplanation = "Apple sets every other country's price from the one price you choose in the Base Country or Region, with exchange rates and local taxes, and keeps them updated."

    var json: JSONText {
        .object([("id", .string(id)), ("name", .string(name)), ("guideTerritory", .string(guideTerritory)), ("rounding", .string(rounding)), ("method", .string(method)),
                 ("percentages", .object(percentages.sorted { $0.key < $1.key }.map { ($0.key, .number($0.value)) }))])
    }

    public init(id: String, name: String, guideTerritory: String, rounding: String, method: String, percentages: [String: Double]) {
        self.id = id; self.name = name; self.guideTerritory = guideTerritory; self.rounding = rounding; self.method = method; self.percentages = percentages
    }

    init?(_ value: JSONText) {
        guard let id = value["id"]?.text, let name = value["name"]?.text, let guide = value["guideTerritory"]?.text, let rounding = value["rounding"]?.text else { return nil }
        var percentages: [String: Double] = [:]
        if case .object(let pairs)? = value["percentages"] { for (code, item) in pairs { if case .number(let number) = item { percentages[code] = number } } }
        self.init(id: id, name: name, guideTerritory: guide, rounding: rounding, method: value["method"]?.text ?? "custom", percentages: percentages)
    }

    public func validated() throws -> PricingProfile {
        guard id.range(of: "^[a-zA-Z0-9_-]{1,80}$", options: .regularExpression) != nil else { throw PricingFailure.invalid("Invalid pricing profile ID.") }
        let trimmed = TextSemantics.trim(name)
        guard !trimmed.isEmpty, trimmed.utf16.count <= 80 else { throw PricingFailure.invalid("A profile name is required (up to 80 characters).") }
        let guide = TextSemantics.trim(guideTerritory).uppercased()
        guard guide.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil else { throw PricingFailure.invalid("Choose a guide country.") }
        guard Self.roundings.contains(where: { $0.0 == rounding }) else { throw PricingFailure.invalid("Choose a valid rounding rule.") }
        guard Self.methods.contains(where: { $0.0 == method }) else { throw PricingFailure.invalid("Choose a valid pricing method.") }
        guard percentages.count <= 250 else { throw PricingFailure.invalid("A profile can contain at most 250 territory overrides.") }
        var clean: [String: Double] = [:]
        for (raw, value) in percentages {
            let code = TextSemantics.trim(raw).uppercased()
            guard code.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil else { throw PricingFailure.invalid("Choose a country for each country percentage.") }
            guard code != guide else { throw PricingFailure.invalid("The guide territory is always 100%.") }
            guard value.isFinite, value >= 0, value <= 1000, Swift.abs(value * 100 - (value * 100).rounded()) <= 1e-8 else { throw PricingFailure.invalid("A territory percentage must be between 0 and 1,000 with at most two decimals.") }
            clean[code] = value
        }
        return PricingProfile(id: id, name: trimmed, guideTerritory: guide, rounding: method == "same" ? "exact" : rounding, method: method, percentages: clean)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.json == rhs.json }
}

/// The app's saved guide price, and optionally its own model, for one profile.
public struct PricingTarget: Equatable, Sendable {
    public let profileId, guideTerritory, currency, amount, updatedAt: String
    public let model: (method: String, rounding: String, percentages: [String: Double])?
    public static func == (a: PricingTarget, b: PricingTarget) -> Bool { a.profileId == b.profileId && a.amount == b.amount && a.updatedAt == b.updatedAt && a.currency == b.currency }
}

public struct FxRate: Equatable, Sendable { public let rate, date, source: String; public let providers: [String]?; public let fetchedAt: String? }
public struct IndexSnapshot: Equatable, Sendable { public let method, date, source: String; public let values: [String: String] }

/// One country's model price: the calculated target and the Apple price point it rounds to.
public struct ModelPrice: Equatable, Sendable, Identifiable {
    public let territory, currency: String
    public let calculated: String?, amount: String?, detail: String, problem: String?
    public let pointStatus: String?
    public var id: String { territory }
}

public enum PricingModels {
    static func canonical(_ value: JSONText) -> JSONText {
        let english = Locale(identifier: "en")
        switch value {
        case .object(let pairs): return .object(pairs.sorted { $0.0.compare($1.0, locale: english) == .orderedAscending }.map { ($0.0, canonical($0.1)) })
        case .array(let items): return .array(items.map(canonical))
        default: return value
        }
    }
    /// The pricing revision: SHA-256 of the value with object keys sorted.
    static func revision(_ value: JSONText) -> String { canonical(value).sha256 }
    public static func profileRevision(_ profile: PricingProfile?) -> String { revision(profile?.json ?? .null) }

    static func initialProfiles() -> JSONText {
        .object([("schemaVersion", .number(1)), ("defaultProfileId", .string("standard")), ("profiles", .array([PricingProfile(id: "standard", name: "Standard", guideTerritory: "USA", rounding: "nearest", method: "custom", percentages: [:]).json]))])
    }

    /// The suggested price: the guide price scaled by the country's percentage and rate, then rounded to an Apple price point.
    static func suggest(_ profile: PricingProfile, territory: String, guide: String, rate rawRate: String, points: [PricePoint]) throws -> (calculated: Decimal, selected: PricePoint?) {
        let base = try PricingMath.desired(guide)
        let percent: Double
        if profile.method == "same" || profile.method == "fx" || territory == profile.guideTerritory { percent = 100 }
        else if let value = profile.percentages[territory] { percent = value } else { throw PricingFailure.invalid("This country has no percentage in the selected profile.") }
        let rate = profile.method == "same" ? "1" : rawRate
        guard let decimalRate = PricingMath.decimal(rate), decimalRate > 0, let decimalPercent = PricingMath.decimal(JSONText.number(percent)) else { throw PricingFailure.invalid("A valid exchange rate is required.") }
        let calculated = base * decimalPercent / 100 * decimalRate
        return (calculated, PricingMath.select(territory: territory, calculated: calculated, rounding: profile.method == "same" ? "exact" : profile.rounding, points: points).selected)
    }

    /// Model prices for the profile's countries.
    public static func calculate(_ profile: PricingProfile, base: String, countries: [Territory], guideCurrency: String, rates: [String: FxRate], points: [PricePoint], index: IndexSnapshot?, pointsUnavailable: Set<String> = []) throws -> [ModelPrice] {
        _ = try PricingMath.desired(base)
        let indexed = profile.method == "ppp" || profile.method == "bigmac", usesFx = profile.method == "custom" || profile.method == "fx"
        return try countries.filter { $0.code == profile.guideTerritory || profile.method != "custom" || profile.percentages[$0.code] != nil }.map { country in
            func empty(_ problem: String) -> ModelPrice { ModelPrice(territory: country.code, currency: country.currency, calculated: nil, amount: nil, detail: "", problem: problem, pointStatus: nil) }
            guard !country.currency.isEmpty, !guideCurrency.isEmpty else { return empty("Currency unavailable. No price was estimated.") }
            var ratio: String?
            if country.code == profile.guideTerritory { ratio = "1" }
            else if let local = index?.values[country.code].flatMap(PricingMath.decimal), let guide = index?.values[profile.guideTerritory].flatMap(PricingMath.decimal), guide > 0 {
                var value = local / guide, rounded = Decimal(); NSDecimalRound(&rounded, &value, 18, .plain); ratio = PricingMath.text(rounded)
            }
            let fx = profile.method == "same" ? "1" : usesFx ? (country.currency == guideCurrency ? "1" : rates[country.currency]?.rate) : ratio
            guard let fx else { return empty(indexed ? "Index data unavailable for this country or guide country." : "Exchange rate unavailable. No price was estimated.") }
            var effective = profile
            if indexed { effective.percentages = [country.code: 100] }
            let suggestion = try suggest(effective, territory: country.code, guide: base, rate: fx, points: points)
            let rate = rates[country.currency]
            let basis = profile.method == "same" ? "Same amount · No currency conversion" : indexed ? "\(index?.source ?? "Index") · \(index?.date ?? "") · Local price ratio: \(fx)"
                : country.currency == guideCurrency ? "Same currency" : "Exchange rate: \(fx) \(country.currency) per \(guideCurrency) · \(rate?.date ?? "") · \(rate?.source == "exchange-rate-api" ? "ExchangeRate-API" : "Frankfurter")"
            let unknown = pointsUnavailable.contains(country.code), exactOnly = profile.rounding == "exact" || profile.method == "same"
            let availability = unknown ? "Apple price points unavailable" : suggestion.selected.map { "Apple price point: \($0.customerPrice) \(country.currency)" } ?? (exactOnly ? "No exact Apple price point" : "No Apple price point matches this rounding rule")
            var calculated = suggestion.calculated, shown = Decimal(); NSDecimalRound(&shown, &calculated, 4, .plain)
            let amount = suggestion.selected?.customerPrice ?? (exactOnly ? PricingMath.text(suggestion.calculated) : nil)
            return ModelPrice(territory: country.code, currency: country.currency, calculated: PricingMath.text(suggestion.calculated), amount: amount,
                              detail: "\(basis). Calculated target: \(PricingMath.text(shown)) \(country.currency) · \(availability)",
                              problem: amount == nil ? "No Apple price point matches this rounding rule." : nil, pointStatus: unknown ? "unknown" : suggestion.selected == nil ? "unavailable" : "available")
        }
    }

    // MARK: Index data

    public static func bigMac(_ csv: String, currencies: [String: String]) throws -> IndexSnapshot {
        func row(_ line: String) throws -> [String] {
            var cells: [String] = [], cell = "", quoted = false, characters = Array(line), index = 0
            while index < characters.count {
                let char = characters[index]
                if char == "\"" && quoted && index + 1 < characters.count && characters[index + 1] == "\"" { cell.append("\""); index += 1 }
                else if char == "\"" { quoted.toggle() } else if char == "," && !quoted { cells.append(cell); cell = "" } else { cell.append(char) }
                index += 1
            }
            guard !quoted else { throw PricingFailure.invalid("Incomplete Big Mac data row.") }
            characters = []; cells.append(cell); return cells
        }
        var lines = csv.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard !lines.isEmpty else { throw PricingFailure.invalid("Big Mac data columns changed.") }
        let header = try row(lines.removeFirst()), keys = ["date", "iso_a3", "currency_code", "local_price"].map { header.firstIndex(of: $0) }
        guard keys.allSatisfy({ $0 != nil }) else { throw PricingFailure.invalid("Big Mac data columns changed.") }
        let positions = keys.map { $0! }
        var rows: [(String, String, String)] = []
        for line in lines {
            let cells = try row(line)
            guard positions.allSatisfy({ $0 < cells.count }) else { continue }
            let date = cells[positions[0]], code = cells[positions[1]], currency = cells[positions[2]], value = cells[positions[3]]
            guard ReportTables.validDate(date) || date.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil, code.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil,
                  let number = Double(value), number > 0, currencies[code] == currency else { continue }
            rows.append((date, code, value))
        }
        guard let date = rows.map(\.0).max() else { throw PricingFailure.invalid("No usable Big Mac observations.") }
        return IndexSnapshot(method: "bigmac", date: date, source: "The Economist Big Mac Index", values: Dictionary(rows.filter { $0.0 == date }.map { ($0.1, $0.2) }, uniquingKeysWith: { _, last in last }))
    }

    public static func worldBank(data: Data, metadata: Data, currencies: [String: String]) throws -> IndexSnapshot {
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [Any], rows.count > 1, let observations = rows[1] as? [[String: Any]],
              let meta = (try? JSONSerialization.jsonObject(with: metadata)) as? [String: Any] else { throw PricingFailure.invalid("World Bank response format changed.") }
        func normalized(_ text: String) -> String { text.lowercased().filter { $0.isLetter && $0.isASCII } }
        var countryCurrencies: [String: String] = [:]
        for source in meta["source"] as? [[String: Any]] ?? [] {
            for concept in source["concept"] as? [[String: Any]] ?? [] {
                for variable in concept["variable"] as? [[String: Any]] ?? [] {
                    if let id = variable["id"] as? String, let unit = (variable["metatype"] as? [[String: Any]])?.first(where: { $0["id"] as? String == "CurrencyUnit" })?["value"] as? String { countryCurrencies[id] = normalized(unit) }
                }
            }
        }
        guard !countryCurrencies.isEmpty else { throw PricingFailure.invalid("World Bank currency metadata is unavailable.") }
        let names = Locale(identifier: "en")
        var byYear: [String: [String: String]] = [:]
        for row in observations {
            guard let code = row["countryiso3code"] as? String, code.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil, let currency = currencies[code],
                  let year = row["date"] as? String, year.range(of: #"^\d{4}$"#, options: .regularExpression) != nil else { continue }
            let value: String
            if let number = row["value"] as? Double, number > 0 { value = JSONText.number(number) } else if let text = row["value"] as? String, let number = Double(text), number > 0 { value = text } else { continue }
            let expected = normalized(names.localizedString(forCurrencyCode: currency) ?? "")
            guard let actual = countryCurrencies[code], actual == expected || (currency == "GBP" && actual == "poundsterling") else { continue }
            byYear[year, default: [:]][code] = value
        }
        let minimum = min(20, currencies.count)
        guard let date = byYear.keys.sorted(by: >).first(where: { byYear[$0]!.count >= minimum }) else { throw PricingFailure.invalid("No usable purchasing power observations.") }
        return IndexSnapshot(method: "ppp", date: date, source: "World Bank PA.NUS.PPP", values: byYear[date]!)
    }
}

/// Where pricing data comes from. Tests point these at synthetic hosts; the app uses the public sources.
public struct PricingSources: Sendable {
    public var frankfurter = URL(string: "https://api.frankfurter.dev/v2/rates")!
    public var exchangeRates = URL(string: "https://open.er-api.com/v6/latest/")!
    public var bigMac = URL(string: "https://raw.githubusercontent.com/TheEconomist/big-mac-data/master/output-data/big-mac-full-index.csv")!
    public var worldBank = URL(string: "https://api.worldbank.org/v2/country/all/indicator/PA.NUS.PPP?format=json&per_page=20000")!
    public var worldBankCurrencies = URL(string: "https://api.worldbank.org/v2/sources/2/country/all/metatypes/CurrencyUnit/metadata?format=json&per_page=5000")!
    public var configuration: URLSessionConfiguration = .ephemeral
    public init() {}

    func fetch(_ url: URL, limit: Int, timeout: TimeInterval) async throws -> Data {
        configuration.timeoutIntervalForRequest = timeout
        configuration.httpShouldSetCookies = false
        let (data, response) = try await URLSession(configuration: Network.guarded(configuration)).data(for: URLRequest(url: url), delegate: RefuseRedirects())
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), data.count <= limit else { throw PricingFailure.unavailable }
        return data
    }
}

extension WorkspaceSession {
    // MARK: Profiles and targets

    func profilesState(_ store: EncryptedDocumentStore) throws -> (EncryptedDocumentStore.Document?, JSONText) {
        let (document, value) = try stateDocument(store, "pricing_profiles")
        return (document, value ?? PricingModels.initialProfiles())
    }

    public func pricingProfiles() throws -> (defaultId: String, profiles: [PricingProfile]) {
        try storeAccess { store in
            let value = try profilesState(store).1
            return (value["defaultProfileId"]?.text ?? "standard", Self.items(value["profiles"]).compactMap(PricingProfile.init))
        }
    }

    /// Changes shared profiles only when the profile and default the editor loaded are still current.
    public func updatePricingProfile(_ action: String, id: String, profile: PricingProfile? = nil, revision: String, expectedDefault: String? = nil) throws {
        try storeAccess { store in
            try FileMutex.withLock(store.directory.appendingPathComponent("pricing_profiles.mutex")) {
                let (document, value) = try profilesState(store)
                var profiles = Self.items(value["profiles"]).compactMap(PricingProfile.init), defaultId = value["defaultProfileId"]?.text ?? "standard"
                guard PricingModels.profileRevision(profiles.first { $0.id == id }) == revision else { throw PricingFailure.stale }
                if action == "default" || action == "delete" { guard expectedDefault == defaultId else { throw PricingFailure.stale } }
                switch action {
                case "save":
                    guard let profile, profile.id == id, let index = profiles.firstIndex(where: { $0.id == id }) else { throw PricingFailure.invalid("Pricing profile was not found.") }
                    profiles[index] = try profile.validated()
                case "duplicate":
                    guard profiles.count < 30, let source = profiles.first(where: { $0.id == id }) else { throw PricingFailure.invalid("At most 30 pricing profiles are supported.") }
                    var copy = source; copy.id = UUID().uuidString.lowercased(); copy.name = String("Copy of \(source.name)".prefix(80))
                    profiles.append(try copy.validated())
                case "default":
                    guard profiles.contains(where: { $0.id == id }) else { throw PricingFailure.invalid("Pricing profile was not found.") }
                    defaultId = id
                case "delete":
                    guard id != defaultId else { throw PricingFailure.invalid("Choose another default profile before deleting this one.") }
                    profiles.removeAll { $0.id == id }
                default: throw PricingFailure.invalid("Unknown profile action.")
                }
                try writeState(store, "pricing_profiles", previous: document, value: .object([("schemaVersion", .number(1)), ("defaultProfileId", .string(defaultId)), ("profiles", .array(profiles.map(\.json)))]))
            }
        }
    }

    static func target(_ value: JSONText) -> PricingTarget? {
        guard let profile = value["profileId"]?.text, let guide = value["guideTerritory"]?.text, let currency = value["currency"]?.text, let amount = value["amount"]?.text, let updated = value["updatedAt"]?.text else { return nil }
        var model: (String, String, [String: Double])?
        if let saved = value["model"], let method = saved["method"]?.text, let rounding = saved["rounding"]?.text {
            var percentages: [String: Double] = [:]
            if case .object(let pairs)? = saved["percentages"] { for (code, item) in pairs { if case .number(let number) = item { percentages[code] = number } } }
            model = (method, rounding, percentages)
        }
        return PricingTarget(profileId: profile, guideTerritory: guide, currency: currency, amount: amount, updatedAt: updated, model: model)
    }

    func targetJSON(store: EncryptedDocumentStore, accountId: String, appId: String, profileId: String) throws -> JSONText? {
        Self.items(try stateDocument(store, "pricing_targets").1?["targets"]).first { $0["accountId"]?.text == accountId && $0["appId"]?.text == appId && $0["profileId"]?.text == profileId }
    }

    static func modelRevision(accountId: String, appId: String, profile: PricingProfile, target: JSONText?) -> String {
        PricingModels.revision(.object([("accountId", .string(accountId)), ("appId", .string(appId)), ("profile", profile.json), ("target", target ?? .null)]))
    }

    /// The app's model for a profile: its saved guide price and own model when the guide country and currency still match.
    public func appPricingModel(accountId: String, appId: String, profileId: String, currency: String) throws -> (profile: PricingProfile, base: String, revision: String)? {
        try storeAccess { store in
            try FileMutex.withLock(store.directory.appendingPathComponent("pricing_profiles.mutex")) {
                guard var profile = Self.items(try profilesState(store).1["profiles"]).compactMap(PricingProfile.init).first(where: { $0.id == profileId }) else { return nil }
                let saved = try targetJSON(store: store, accountId: accountId, appId: appId, profileId: profileId)
                let revision = Self.modelRevision(accountId: accountId, appId: appId, profile: profile, target: saved)
                let target = saved.flatMap(Self.target)
                let matches = target?.guideTerritory == profile.guideTerritory && target?.currency == currency
                if matches, let model = target?.model { profile.method = model.method; profile.rounding = model.rounding; profile.percentages = model.percentages }
                return (profile, matches ? target!.amount : "", revision)
            }
        }
    }

    /// Saves the app's guide price and model: shared profiles are locked before targets, and both must match the editor's revision.
    public func savePricingTarget(accountId: String, appId: String, profileId: String, currency: String, amount: String, model: PricingProfile?, revision: String, now: Date = Date()) throws -> String {
        let base = try PricingMath.desired(amount.trimmingCharacters(in: .whitespaces))
        guard currency.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil else { throw PricingFailure.invalid("The guide country's currency is unavailable.") }
        return try storeAccess { store in
            try FileMutex.withLock(store.directory.appendingPathComponent("pricing_profiles.mutex")) {
                guard let profile = Self.items(try profilesState(store).1["profiles"]).compactMap(PricingProfile.init).first(where: { $0.id == profileId }) else { throw PricingFailure.stale }
                return try FileMutex.withLock(store.directory.appendingPathComponent("pricing_targets.mutex")) {
                    let (document, value) = try stateDocument(store, "pricing_targets")
                    let targets = Self.items(value?["targets"])
                    let previous = targets.first { $0["accountId"]?.text == accountId && $0["appId"]?.text == appId && $0["profileId"]?.text == profileId }
                    guard Self.modelRevision(accountId: accountId, appId: appId, profile: profile, target: previous) == revision else { throw PricingFailure.stale }
                    var fields: [(String, JSONText)] = [("accountId", .string(accountId)), ("appId", .string(appId)), ("profileId", .string(profileId)), ("guideTerritory", .string(profile.guideTerritory)),
                                                        ("currency", .string(currency)), ("amount", .string(PricingMath.text(base)))]
                    if let model {
                        var checked = model; checked.guideTerritory = profile.guideTerritory; checked = try checked.validated()
                        fields.append(("model", .object([("method", .string(checked.method)), ("rounding", .string(checked.rounding)), ("percentages", checked.json["percentages"]!)])))
                    }
                    fields.append(("updatedAt", .string(CustomerReview.isoString(now))))
                    let target = JSONText.object(fields)
                    let others = targets.filter { !($0["accountId"]?.text == accountId && $0["appId"]?.text == appId && $0["profileId"]?.text == profileId) }
                    try writeState(store, "pricing_targets", previous: document, value: .object([("schemaVersion", .number(1)), ("targets", .array(others + [target]))]))
                    return Self.modelRevision(accountId: accountId, appId: appId, profile: profile, target: target)
                }
            }
        }
    }

    // MARK: Exchange rates and index data

    /// Dated exchange rates: fresh cached rates first, then Frankfurter, then ExchangeRate-API, then a dated cache no older than a week.
    public func fxRates(base: String, quotes requested: [String], sources: PricingSources = PricingSources(), now: Date = Date()) async throws -> (rates: [String: FxRate], missing: [String], stale: [String]) {
        guard base.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil, requested.count <= 250, requested.allSatisfy({ $0.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil }) else { throw PricingFailure.invalid("Invalid currency request.") }
        let quotes = Array(Set(requested.filter { $0 != base })).sorted()
        guard !quotes.isEmpty else { return ([:], [], []) }
        let cache: [String: FxRate] = try storeAccess { store in
            guard let value = try store.document(namespace: "fx_cache", key: base).flatMap({ try? JSONText.parse($0.payload) }), value["schemaVersion"] == .number(2), value["base"]?.text == base, case .object(let pairs)? = value["rates"] else { return [:] }
            return Dictionary(pairs.compactMap { pair in Self.fxRate(pair.1).map { (pair.0, $0) } }, uniquingKeysWith: { _, last in last })
        }
        let nowTime = now.timeIntervalSince1970
        func recent(_ rate: FxRate?) -> Bool {
            guard let rate, let day = ReportTables.dayFormat.date(from: rate.date)?.timeIntervalSince1970 else { return false }
            return day <= nowTime + 86_400 && nowTime - day <= 7 * 86_400
        }
        func fresh(_ rate: FxRate?) -> Bool {
            guard recent(rate), let fetched = rate?.fetchedAt.flatMap({ ISO8601DateFormatter.storebench.date(from: $0) })?.timeIntervalSince1970 else { return false }
            return fetched <= nowTime + 60 && nowTime - fetched < (rate?.source == "exchange-rate-api" ? 86_400 : 6 * 3_600)
        }
        var rates: [String: FxRate] = [:], updates: [String: FxRate] = [:], changed = false
        for quote in quotes where fresh(cache[quote]) { rates[quote] = cache[quote] }
        let stamp = CustomerReview.isoString(now)
        for provider in ["primary", "backup"] where quotes.contains(where: { rates[$0] == nil }) {
            let loaded: [String: FxRate]
            do {
                if provider == "primary" {
                    var url = URLComponents(url: sources.frankfurter, resolvingAgainstBaseURL: false)!
                    url.queryItems = [URLQueryItem(name: "base", value: base), URLQueryItem(name: "expand", value: "providers")]
                    loaded = try Self.frankfurter(try await sources.fetch(url.url!, limit: 256_000, timeout: 4), base: base)
                } else {
                    loaded = try Self.openExchange(try await sources.fetch(sources.exchangeRates.appendingPathComponent(base), limit: 256_000, timeout: 4), base: base)
                }
            } catch { continue }
            for (quote, rate) in loaded where recent(rate) && (updates[quote] ?? cache[quote]).map({ rate.date >= $0.date }) ?? true {
                updates[quote] = FxRate(rate: rate.rate, date: rate.date, source: rate.source, providers: rate.providers, fetchedAt: stamp)
            }
            for quote in quotes where rates[quote] == nil && recent(loaded[quote]) { rates[quote] = updates[quote] ?? loaded[quote]; changed = true }
        }
        var stale: [String] = []
        for quote in quotes where rates[quote] == nil && recent(cache[quote]) { rates[quote] = cache[quote]; stale.append(quote) }
        // Providers return every quote; keeping them avoids another download for a different selection.
        if changed {
            var merged = cache; for (quote, rate) in updates { merged[quote] = rate }; for (quote, rate) in rates { merged[quote] = rate }
            let value = JSONText.object([("schemaVersion", .number(2)), ("base", .string(base)), ("rates", .object(merged.sorted { $0.key < $1.key }.map { ($0.key, Self.fxJSON($0.value)) }))])
            if value.data.count <= 300_000 { try? storeAccess { store in try store.transaction { _ in [.put(namespace: "fx_cache", key: base, json: value.data)] } } }
        }
        return (rates, quotes.filter { rates[$0] == nil }, stale)
    }

    static func fxRate(_ value: JSONText) -> FxRate? {
        guard let rate = value["rate"]?.text, rate.range(of: #"^\d+(?:\.\d+)?$"#, options: .regularExpression) != nil, let date = value["date"]?.text, ReportTables.validDate(date),
              let source = value["source"]?.text, ["frankfurter", "exchange-rate-api"].contains(source) else { return nil }
        return FxRate(rate: rate, date: date, source: source, providers: Self.strings(value["providers"]).isEmpty ? nil : Self.strings(value["providers"]), fetchedAt: value["fetchedAt"]?.text)
    }

    static func fxJSON(_ rate: FxRate) -> JSONText {
        var fields: [(String, JSONText)] = [("rate", .string(rate.rate)), ("date", .string(rate.date)), ("source", .string(rate.source))]
        if let providers = rate.providers { fields.append(("providers", .array(providers.map { .string($0) }))) }
        if let fetched = rate.fetchedAt { fields.append(("fetchedAt", .string(fetched))) }
        return .object(fields)
    }

    static func frankfurter(_ data: Data, base: String) throws -> [String: FxRate] {
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw PricingFailure.invalid("Unexpected currency rate response.") }
        var rates: [String: FxRate] = [:]
        for item in items {
            guard item["base"] as? String == base, let quote = item["quote"] as? String, quote.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil,
                  let date = item["date"] as? String, ReportTables.validDate(date), let rate = item["rate"] as? Double, rate > 0, rate <= 1_000_000_000 else { throw PricingFailure.invalid("Unexpected currency rate response.") }
            let providers = item["providers"] as? [String]
            rates[quote] = FxRate(rate: JSONText.number(rate), date: date, source: "frankfurter", providers: providers, fetchedAt: nil)
        }
        return rates
    }

    static func openExchange(_ data: Data, base: String) throws -> [String: FxRate] {
        guard let item = try? JSONSerialization.jsonObject(with: data) as? [String: Any], item["result"] as? String == "success", item["base_code"] as? String == base,
              let time = item["time_last_update_unix"] as? Int, time >= 0, let values = item["rates"] as? [String: Any] else { throw PricingFailure.invalid("Unexpected backup currency rate response.") }
        let date = ReportTables.dayFormat.string(from: Date(timeIntervalSince1970: TimeInterval(time)))
        var rates: [String: FxRate] = [:]
        for (quote, value) in values {
            guard quote.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil, let rate = value as? Double, rate > 0, rate <= 1_000_000_000 else { throw PricingFailure.invalid("Unexpected backup currency rate response.") }
            rates[quote] = FxRate(rate: JSONText.number(rate), date: date, source: "exchange-rate-api", providers: nil, fetchedAt: nil)
        }
        return rates
    }

    public func pricingIndex(method: String, catalog: [Territory], sources: PricingSources = PricingSources()) async throws -> IndexSnapshot {
        let currencies = Dictionary(catalog.map { ($0.code, $0.currency) }, uniquingKeysWith: { first, _ in first })
        if method == "bigmac" {
            guard let text = String(data: try await sources.fetch(sources.bigMac, limit: 8_000_000, timeout: 12), encoding: .utf8) else { throw PricingFailure.unavailable }
            return try PricingModels.bigMac(text, currencies: currencies)
        }
        async let data = sources.fetch(sources.worldBank, limit: 8_000_000, timeout: 12)
        async let metadata = sources.fetch(sources.worldBankCurrencies, limit: 8_000_000, timeout: 12)
        return try PricingModels.worldBank(data: try await data, metadata: try await metadata, currencies: currencies)
    }

    /// The model preview: rates or index data and Apple price points, then the model prices with their warnings.
    public func modelPreview(appId: String, profile: PricingProfile, base: String, countries: [Territory], guideCurrency: String, client: AppStoreConnectClient,
                             sources: PricingSources = PricingSources()) async throws -> (rows: [ModelPrice], warnings: [String]) {
        let result = try await modelPrices(.app(appId), profile: profile, base: base, countries: countries, guideCurrency: guideCurrency, client: client, sources: sources)
        return (result.rows, result.warnings)
    }

    /// The model prices for one subscription: the profile applied to the guide price, each rounded to one of the subscription's own
    /// Apple price points, with the price point chosen in each country or region. Nothing is written.
    public func subscriptionModelPrices(subscriptionId: String, profile: PricingProfile, base: String, countries: [Territory], guideCurrency: String, client: AppStoreConnectClient,
                                        sources: PricingSources = PricingSources()) async throws -> (rows: [ModelPrice], warnings: [String], points: [String: String]) {
        try await modelPrices(.subscription(subscriptionId), profile: profile, base: base, countries: countries, guideCurrency: guideCurrency, client: client, sources: sources)
    }

    /// Prices typed for each country or region, each rounded to the nearest of the subscription's own Apple price points there.
    /// Nothing is written.
    public func subscriptionManualPrices(subscriptionId: String, amounts: [String: String], countries: [Territory], client: AppStoreConnectClient) async throws -> (rows: [ModelPrice], warnings: [String], points: [String: String]) {
        try await manualPrices(.subscription(subscriptionId), amounts: amounts, countries: countries, client: client)
    }
    /// The same for the app's own price points.
    public func appManualPrices(appId: String, amounts: [String: String], countries: [Territory], client: AppStoreConnectClient) async throws -> (rows: [ModelPrice], warnings: [String], points: [String: String]) {
        try await manualPrices(.app(appId), amounts: amounts, countries: countries, client: client)
    }
    /// Model and typed prices for one in-app purchase, rounded to its own Apple price points.
    public func purchaseModelPrices(purchaseId: String, profile: PricingProfile, base: String, countries: [Territory], guideCurrency: String, client: AppStoreConnectClient) async throws -> (rows: [ModelPrice], warnings: [String], points: [String: String]) {
        try await modelPrices(.purchase(purchaseId), profile: profile, base: base, countries: countries, guideCurrency: guideCurrency, client: client, sources: PricingSources())
    }
    public func purchaseManualPrices(purchaseId: String, amounts: [String: String], countries: [Territory], client: AppStoreConnectClient) async throws -> (rows: [ModelPrice], warnings: [String], points: [String: String]) {
        try await manualPrices(.purchase(purchaseId), amounts: amounts, countries: countries, client: client)
    }
    /// The model prices for the app with any model, including a built-in one that has no saved profile, with each chosen price point.
    public func appModelPrices(appId: String, profile: PricingProfile, base: String, countries: [Territory], guideCurrency: String, client: AppStoreConnectClient) async throws -> (rows: [ModelPrice], warnings: [String], points: [String: String]) {
        try await modelPrices(.app(appId), profile: profile, base: base, countries: countries, guideCurrency: guideCurrency, client: client, sources: PricingSources())
    }
    /// Prices typed per country or region for any owner, each rounded to the nearest of its own Apple price points. Nothing is written.
    public func manualPrices(_ owner: PriceOwner, amounts: [String: String], countries: [Territory], client: AppStoreConnectClient) async throws -> (rows: [ModelPrice], warnings: [String], points: [String: String]) {
        let typed = amounts.compactMapValues { value -> Decimal? in PricingMath.decimal(value.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil } }
        guard !typed.isEmpty else { throw PricingFailure.invalid("Type a price above zero for at least one country or region.") }
        guard typed.count <= 200, typed.keys.allSatisfy({ $0.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil }) else { throw PricingFailure.invalid("Invalid territory selection.") }
        let codes = typed.keys.sorted()
        let (points, failed) = try await PricePointCatalog.readAll(owner, territories: codes, client: client)
        var rows: [ModelPrice] = [], chosen: [String: String] = [:]
        for code in codes {
            let currency = countries.first { $0.code == code }?.currency ?? "", amount = typed[code]!
            let selected = PricingMath.select(territory: code, calculated: amount, rounding: "nearest", points: points).selected
            if let selected { chosen[code] = selected.id }
            rows.append(ModelPrice(territory: code, currency: currency, calculated: PricingMath.text(amount), amount: selected?.customerPrice,
                                   detail: "Typed \(PricingMath.text(amount)) \(currency) · " + (selected.map { "Nearest Apple price: \($0.customerPrice) \(currency)" } ?? "No Apple price"),
                                   problem: selected == nil ? (failed.contains(code) ? "Apple's prices could not be read." : "No Apple price is near this amount.") : nil,
                                   pointStatus: failed.contains(code) ? "unknown" : selected == nil ? "unavailable" : "available"))
        }
        return (rows, failed.isEmpty ? [] : ["Some Apple prices could not be read. Those countries or regions keep what Apple has."], chosen)
    }

    /// A model's prices for any owner: the profile applied to the guide price, rounded to the owner's own Apple price points, with the
    /// price point chosen in each country or region. Nothing is written.
    public func modelPrices(_ owner: PriceOwner, profile: PricingProfile, base: String, countries: [Territory], guideCurrency: String, client: AppStoreConnectClient,
                            sources: PricingSources = PricingSources()) async throws -> (rows: [ModelPrice], warnings: [String], points: [String: String]) {
        var complete = countries
        for code in [profile.guideTerritory] + (profile.method == "custom" ? Array(profile.percentages.keys) : []) where !complete.contains(where: { $0.code == code }) {
            complete.append(Territory(code: code, name: code, currency: ""))
        }
        let selected = complete.filter { $0.code == profile.guideTerritory || profile.method != "custom" || profile.percentages[$0.code] != nil }
        var warnings: [String] = []
        var rates: [String: FxRate] = [:], index: IndexSnapshot?
        if profile.method == "custom" || profile.method == "fx" {
            let loaded = try? await fxRates(base: guideCurrency, quotes: Array(Set(selected.map(\.currency).filter { !$0.isEmpty && $0 != guideCurrency })), sources: sources)
            rates = loaded?.rates ?? [:]
            if loaded == nil || !(loaded?.missing.isEmpty ?? true) { warnings.append("Some exchange rates are unavailable. Affected countries have no model price.") }
            if !(loaded?.stale.isEmpty ?? true) { warnings.append("Some exchange rates came from a dated local cache. Check country details.") }
        }
        if profile.method == "ppp" || profile.method == "bigmac" {
            index = try? await pricingIndex(method: profile.method, catalog: countries, sources: sources)
            if index?.values[profile.guideTerritory] == nil { warnings.append("The selected index has no observation for the guide country. Choose another pricing method or guide country.") }
        }
        let codes = selected.filter { !$0.currency.isEmpty }.map(\.code)
        let (points, failed) = try await PricePointCatalog.readAll(owner, territories: codes, client: client)
        if !failed.isEmpty { warnings.append("Some Apple price points could not be checked. Calculated amounts are shown without a price-point match.") }
        let rows = try PricingModels.calculate(profile, base: base, countries: selected, guideCurrency: guideCurrency, rates: rates, points: points, index: index, pointsUnavailable: failed)
        // The Apple price point each country or region rounds to, by its amount among that country's own price points.
        var chosen: [String: String] = [:]
        for row in rows where row.pointStatus == "available" {
            if let amount = row.amount, let point = points.first(where: { $0.territory == row.territory && PricingMath.decimal($0.customerPrice) == PricingMath.decimal(amount) }) { chosen[row.territory] = point.id }
        }
        return (rows, warnings, chosen)
    }
}

extension ISO8601DateFormatter {
    static var storebench: ISO8601DateFormatter { let format = ISO8601DateFormatter(); format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return format }
}
