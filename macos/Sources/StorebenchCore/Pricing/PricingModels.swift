import Foundation

/// A second method mixed into a recipe, with its share of the price in percent.
public struct PricingMix: Equatable, Sendable {
    public var method: String, share: Double
    public init(method: String, share: Double) { self.method = method; self.share = share }
}

/// A pricing recipe with its guide country. The method sets every country's price from the guide price; a recipe can mix in a
/// second method, adjust countries by percentage, keep prices between a lowest and highest price, and use its own index values.
/// Old profiles without these parts load and save exactly as before.
public struct PricingProfile: Equatable, Sendable, Identifiable {
    public var id, name, guideTerritory, rounding, method: String
    /// For Your country percentages, the countries it prices and their percentages; for other methods except Same for all, a
    /// percentage applied to the country's price.
    public var percentages: [String: Double]
    public var mix: PricingMix?
    /// The lowest and highest price, each in percent of the guide price converted at current exchange rates.
    public var floor: Double?, ceiling: Double?
    /// Your own index: a value per country in its own currency, used by Your own index.
    public var index: [String: Double]

    /// The profile's method; nil only for a stored key Storebench does not know, which validation refuses.
    public var pricingMethod: PricingMethod? { PricingMethod(rawValue: method) }
    public var mixMethod: PricingMethod? { mix.flatMap { PricingMethod(rawValue: $0.method) } }
    /// Every method the recipe calculates with.
    public var methods: [PricingMethod] { [pricingMethod, mixMethod].compactMap { $0 } }
    /// True when the recipe keeps prices between a lowest and highest price.
    public var limited: Bool { pricingMethod?.exactOnly != true && (floor != nil || ceiling != nil) }
    /// Exchange rates are needed for a converting method or for the lowest and highest price.
    public var needsExchangeRates: Bool { methods.contains { $0.usesExchangeRates } || limited }

    /// The recipe in one plain sentence: its method's explanation, then what the recipe adds to it.
    public var summary: String {
        guard let kind = pricingMethod else { return "Applies the profile to the guide price." }
        var parts: [String] = []
        if let mix, let other = mixMethod { parts.append("\(JSONText.number(mix.share))% comes from \(other.name)") }
        if !kind.exactOnly && !kind.usesCountryPercentages && !percentages.isEmpty { parts.append("\(percentages.count) \(percentages.count == 1 ? "country has" : "countries have") its own percentage") }
        if limited {
            let range = [floor.map { "at least \(JSONText.number($0))%" }, ceiling.map { "at most \(JSONText.number($0))%" }].compactMap { $0 }.joined(separator: " and ")
            parts.append("every price is \(range) of the converted guide price")
        }
        return kind.explanation + (parts.isEmpty ? "" : " " + parts.joined(separator: "; ").prefix(1).uppercased() + parts.joined(separator: "; ").dropFirst() + ".")
    }

    static func numbers(_ value: JSONText?) -> [String: Double] {
        var result: [String: Double] = [:]
        if case .object(let pairs)? = value { for (code, item) in pairs { if case .number(let number) = item { result[code] = number } } }
        return result
    }
    static func object(_ values: [String: Double]) -> JSONText { .object(values.sorted { $0.key < $1.key }.map { ($0.key, .number($0.value)) }) }

    /// The recipe without its identity: what an app's own model saves.
    var recipeJSON: JSONText {
        var pairs: [(String, JSONText)] = [("method", .string(method)), ("rounding", .string(rounding)), ("percentages", Self.object(percentages))]
        if let mix { pairs.append(("mix", .object([("method", .string(mix.method)), ("share", .number(mix.share))]))) }
        if let floor { pairs.append(("floor", .number(floor))) }
        if let ceiling { pairs.append(("ceiling", .number(ceiling))) }
        if !index.isEmpty { pairs.append(("index", Self.object(index))) }
        return .object(pairs)
    }
    var json: JSONText {
        guard case .object(let recipe) = recipeJSON else { return .null }
        return .object([("id", .string(id)), ("name", .string(name)), ("guideTerritory", .string(guideTerritory))] + recipe)
    }

    public init(id: String, name: String, guideTerritory: String, rounding: String, method: String, percentages: [String: Double],
                mix: PricingMix? = nil, floor: Double? = nil, ceiling: Double? = nil, index: [String: Double] = [:]) {
        self.id = id; self.name = name; self.guideTerritory = guideTerritory; self.rounding = rounding; self.method = method; self.percentages = percentages
        self.mix = mix; self.floor = floor; self.ceiling = ceiling; self.index = index
    }

    init?(_ value: JSONText) {
        guard let id = value["id"]?.text, let name = value["name"]?.text, let guide = value["guideTerritory"]?.text, value["rounding"]?.text != nil else { return nil }
        self.init(id: id, name: name, guideTerritory: guide, rounding: "", method: "", percentages: [:])
        guard let recipe = applying(recipe: value) else { return nil }
        self = recipe
    }

    /// This profile with another saved recipe; nil when the recipe has no rounding.
    func applying(recipe value: JSONText) -> PricingProfile? {
        guard let rounding = value["rounding"]?.text else { return nil }
        var copy = self
        copy.rounding = rounding; copy.method = value["method"]?.text ?? PricingMethod.custom.rawValue; copy.percentages = Self.numbers(value["percentages"])
        if let mix = value["mix"], let method = mix["method"]?.text, case .number(let share)? = mix["share"] { copy.mix = PricingMix(method: method, share: share) } else { copy.mix = nil }
        if case .number(let floor)? = value["floor"] { copy.floor = floor } else { copy.floor = nil }
        if case .number(let ceiling)? = value["ceiling"] { copy.ceiling = ceiling } else { copy.ceiling = nil }
        copy.index = Self.numbers(value["index"])
        return copy
    }

    static func twoDecimals(_ value: Double) -> Bool { Swift.abs(value * 100 - (value * 100).rounded()) <= 1e-8 }

    public func validated() throws -> PricingProfile {
        guard id.range(of: "^[a-zA-Z0-9_-]{1,80}$", options: .regularExpression) != nil else { throw PricingFailure.invalid("Invalid pricing profile ID.") }
        let trimmed = TextSemantics.trim(name)
        guard !trimmed.isEmpty, trimmed.utf16.count <= 80 else { throw PricingFailure.invalid("A profile name is required (up to 80 characters).") }
        let guide = TextSemantics.trim(guideTerritory).uppercased()
        guard guide.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil else { throw PricingFailure.invalid("Choose a guide country.") }
        guard PricingRounding(rawValue: rounding) != nil else { throw PricingFailure.invalid("Choose a valid rounding rule.") }
        guard let kind = pricingMethod else { throw PricingFailure.invalid("Choose a valid pricing method.") }
        func codes(_ values: [String: Double], _ problem: String) throws -> [String: String] {
            var result: [String: String] = [:]
            for raw in values.keys {
                let code = TextSemantics.trim(raw).uppercased()
                guard code.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil, result.values.contains(code) == false else { throw PricingFailure.invalid(problem) }
                result[raw] = code
            }
            return result
        }
        guard percentages.count <= 250 else { throw PricingFailure.invalid("A profile can contain at most 250 territory overrides.") }
        var clean: [String: Double] = [:]
        for (raw, code) in try codes(percentages, "Choose a country for each country percentage.") {
            let value = percentages[raw]!
            guard code != guide else { throw PricingFailure.invalid("The guide territory is always 100%.") }
            guard value.isFinite, value >= 0, value <= 1000, Self.twoDecimals(value) else { throw PricingFailure.invalid("A territory percentage must be between 0 and 1,000 with at most two decimals.") }
            clean[code] = value
        }
        var checkedMix: PricingMix?
        if let mix {
            guard let other = PricingMethod(rawValue: mix.method), other != kind, other.mixes, kind.mixes else {
                throw PricingFailure.invalid("Mix two different methods. \(PricingMethod.same.name) and \(PricingMethod.custom.name) cannot be mixed.")
            }
            guard mix.share.isFinite, mix.share > 0, mix.share < 100, Self.twoDecimals(mix.share) else { throw PricingFailure.invalid("The mixed-in share must be above 0% and below 100%, with at most two decimals.") }
            checkedMix = PricingMix(method: other.rawValue, share: mix.share)
        }
        for limit in [floor, ceiling].compactMap({ $0 }) {
            guard !kind.exactOnly else { throw PricingFailure.invalid("\(PricingMethod.same.name) keeps one number everywhere, so it has no lowest or highest price.") }
            guard limit.isFinite, limit > 0, limit <= 1000, Self.twoDecimals(limit) else { throw PricingFailure.invalid("The lowest and highest price must be above 0% and at most 1,000% of the guide price, with at most two decimals.") }
        }
        if let floor, let ceiling, floor > ceiling { throw PricingFailure.invalid("The lowest price cannot be above the highest price.") }
        guard index.count <= 250 else { throw PricingFailure.invalid("Your own index can contain at most 250 countries.") }
        var values: [String: Double] = [:]
        for (raw, code) in try codes(index, "Use one Apple country code, such as USA, for each value in your own index.") {
            let value = index[raw]!
            guard value.isFinite, value > 0, value <= 1_000_000_000 else { throw PricingFailure.invalid("Each value in your own index must be above zero.") }
            values[code] = value
        }
        if kind == .own || checkedMix?.method == PricingMethod.own.rawValue {
            guard values[guide] != nil else { throw PricingFailure.invalid("Your own index needs a value for the guide country, \(WorkspaceSession.countryName(guide)).") }
        }
        return PricingProfile(id: id, name: trimmed, guideTerritory: guide, rounding: kind.rounding(rounding), method: method, percentages: clean,
                              mix: checkedMix, floor: floor, ceiling: ceiling, index: values)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.json == rhs.json }
}

/// The app's saved guide price, and optionally its own recipe, for one profile.
public struct PricingTarget: Equatable, Sendable {
    public let profileId, guideTerritory, currency, amount, updatedAt: String
    let model: JSONText?
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
        .object([("schemaVersion", .number(1)), ("defaultProfileId", .string("standard")), ("profiles", .array([PricingProfile(id: "standard", name: "Standard", guideTerritory: "USA", rounding: PricingRounding.nearest.rawValue, method: PricingMethod.custom.rawValue, percentages: [:]).json]))])
    }

    /// Model prices for the recipe's countries. Each method gives a factor on the guide price: the exchange rate, or the ratio of the
    /// country's index value to the guide country's. A mix blends two factors by share, a country percentage scales the result, and
    /// the lowest and highest price keep it within a percentage of the converted guide price before it is rounded to an Apple price.
    public static func calculate(_ profile: PricingProfile, base: String, countries: [Territory], guideCurrency: String, rates: [String: FxRate], points: [PricePoint], indexes: [IndexSnapshot], pointsUnavailable: Set<String> = []) throws -> [ModelPrice] {
        let guidePrice = try PricingMath.desired(base)
        guard let method = profile.pricingMethod else { throw PricingFailure.invalid("Choose a valid pricing method.") }
        let mix = profile.mixMethod.flatMap { other in profile.mix.map { (other, $0.share) } }
        let rounding = method.rounding(profile.rounding), exactOnly = rounding == PricingRounding.exact.rawValue
        func decimal(_ number: Double) -> Decimal? { PricingMath.decimal(JSONText.number(number)) }
        func indexValue(_ kind: PricingMethod, _ code: String) -> Decimal? {
            kind == .own ? profile.index[code].flatMap(decimal) : indexes.first { $0.method == kind.rawValue }?.values[code].flatMap(PricingMath.decimal)
        }
        return try countries.filter { $0.code == profile.guideTerritory || !method.usesCountryPercentages || profile.percentages[$0.code] != nil }.map { country in
            func empty(_ problem: String) -> ModelPrice { ModelPrice(territory: country.code, currency: country.currency, calculated: nil, amount: nil, detail: "", problem: problem, pointStatus: nil) }
            guard !country.currency.isEmpty, !guideCurrency.isEmpty else { return empty("Currency unavailable. No price was estimated.") }
            let guide = country.code == profile.guideTerritory
            let rate = rates[country.currency], rateText = country.currency == guideCurrency ? "1" : rate?.rate
            let exchange = rateText.flatMap(PricingMath.decimal).flatMap { $0 > 0 ? $0 : nil }
            /// One method's factor on the guide price and how it was found, or the reason there is none.
            func factor(_ kind: PricingMethod) -> (value: Decimal, basis: String)? {
                switch kind {
                case .same: return (1, "Same amount · No currency conversion")
                case .fx, .custom:
                    guard let exchange else { return nil }
                    return (exchange, country.currency == guideCurrency ? "Same currency" : "Exchange rate: \(rateText!) \(country.currency) per \(guideCurrency) · \(rate?.date ?? "") · \(rate?.source == "exchange-rate-api" ? "ExchangeRate-API" : "Frankfurter")")
                case .ppp, .bigmac, .own:
                    var ratio: Decimal
                    if guide { ratio = 1 }
                    else if let local = indexValue(kind, country.code), let anchor = indexValue(kind, profile.guideTerritory), anchor > 0 {
                        var value = local / anchor; ratio = Decimal(); NSDecimalRound(&ratio, &value, 18, .plain)
                    } else { return nil }
                    let snapshot = indexes.first { $0.method == kind.rawValue }
                    let source = kind == .own ? kind.name : "\(snapshot?.source ?? "Index") · \(snapshot?.date ?? "")"
                    return (ratio, "\(source) · Local price ratio: \(PricingMath.text(ratio))")
                }
            }
            func missing(_ kind: PricingMethod) -> ModelPrice {
                empty(kind.scalesByIndex ? "Index data unavailable for this country or guide country." : "Exchange rate unavailable. No price was estimated.")
            }
            guard let primary = factor(method) else { return missing(method) }
            var value = guidePrice * primary.value, basis = [primary.basis]
            if let (other, share) = mix, let percent = decimal(share) {
                guard let second = factor(other) else { return missing(other) }
                value = value * (100 - percent) / 100 + guidePrice * second.value * percent / 100
                basis.append("Mixed \(PricingMath.text(percent))% \(other.name): \(second.basis)")
            }
            if !guide, !method.exactOnly, let percentage = profile.percentages[country.code], let percent = decimal(percentage) {
                value = value * percent / 100
                basis.append("Country percentage: \(PricingMath.text(percent))%")
            }
            var low: Decimal?, high: Decimal?
            if profile.limited, !guide {
                guard let exchange else { return empty("Exchange rate unavailable, so the lowest and highest price could not be checked.") }
                let converted = guidePrice * exchange
                if let floor = profile.floor, let percent = decimal(floor) {
                    let limit = converted * percent / 100; low = limit
                    if value < limit { value = limit; basis.append("Raised to the lowest price, \(PricingMath.text(percent))% of the guide price") }
                }
                if let ceiling = profile.ceiling, let percent = decimal(ceiling) {
                    let limit = converted * percent / 100; high = limit
                    if value > limit { value = limit; basis.append("Lowered to the highest price, \(PricingMath.text(percent))% of the guide price") }
                }
            }
            // Rounding picks only among Apple price points inside the limits, so the chosen point never breaks them.
            let allowed = low == nil && high == nil ? points : points.filter { point in
                guard point.territory == country.code, let amount = PricingMath.decimal(point.customerPrice) else { return false }
                return (low.map { amount >= $0 } ?? true) && (high.map { amount <= $0 } ?? true)
            }
            let selected = PricingMath.select(territory: country.code, calculated: value, rounding: rounding, points: allowed).selected
            let limitedOut = selected == nil && (low != nil || high != nil) && PricingMath.select(territory: country.code, calculated: value, rounding: rounding, points: points).selected != nil
            let unknown = pointsUnavailable.contains(country.code)
            let availability = unknown ? "Apple price points unavailable" : selected.map { "Apple price point: \($0.customerPrice) \(country.currency)" }
                ?? (limitedOut ? "No Apple price point lies between the lowest and highest price" : exactOnly ? "No exact Apple price point" : "No Apple price point matches this rounding rule")
            var calculated = value, shown = Decimal(); NSDecimalRound(&shown, &calculated, 4, .plain)
            let amount = selected?.customerPrice ?? (exactOnly ? PricingMath.text(value) : nil)
            return ModelPrice(territory: country.code, currency: country.currency, calculated: PricingMath.text(value), amount: amount,
                              detail: "\(basis.joined(separator: " · ")). Calculated target: \(PricingMath.text(shown)) \(country.currency) · \(availability)",
                              problem: amount == nil ? (limitedOut ? "No Apple price point lies between the lowest and highest price." : "No Apple price point matches this rounding rule.") : nil, pointStatus: unknown ? "unknown" : selected == nil ? "unavailable" : "available")
        }
    }

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
        return IndexSnapshot(method: PricingMethod.bigmac.rawValue, date: date, source: "The Economist Big Mac Index", values: Dictionary(rows.filter { $0.0 == date }.map { ($0.1, $0.2) }, uniquingKeysWith: { _, last in last }))
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
        return IndexSnapshot(method: PricingMethod.ppp.rawValue, date: date, source: "World Bank PA.NUS.PPP", values: byYear[date]!)
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
        let model = value["model"].flatMap { $0["method"]?.text != nil && $0["rounding"]?.text != nil ? $0 : nil }
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
                if matches, let model = target?.model, let recipe = profile.applying(recipe: model) { profile = recipe }
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
                        fields.append(("model", checked.recipeJSON))
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

    public func pricingIndex(method: PricingMethod, catalog: [Territory], sources: PricingSources = PricingSources()) async throws -> IndexSnapshot {
        let currencies = Dictionary(catalog.map { ($0.code, $0.currency) }, uniquingKeysWith: { first, _ in first })
        if method == .bigmac {
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
        let method = profile.pricingMethod
        var complete = countries
        for code in [profile.guideTerritory] + (method?.usesCountryPercentages == true ? Array(profile.percentages.keys) : []) where !complete.contains(where: { $0.code == code }) {
            complete.append(Territory(code: code, name: code, currency: ""))
        }
        let selected = complete.filter { $0.code == profile.guideTerritory || method?.usesCountryPercentages != true || profile.percentages[$0.code] != nil }
        var warnings: [String] = []
        var rates: [String: FxRate] = [:], indexes: [IndexSnapshot] = []
        if profile.needsExchangeRates {
            let loaded = try? await fxRates(base: guideCurrency, quotes: Array(Set(selected.map(\.currency).filter { !$0.isEmpty && $0 != guideCurrency })), sources: sources)
            rates = loaded?.rates ?? [:]
            if loaded == nil || !(loaded?.missing.isEmpty ?? true) { warnings.append("Some exchange rates are unavailable. Affected countries have no model price.") }
            if !(loaded?.stale.isEmpty ?? true) { warnings.append("Some exchange rates came from a dated local cache. Check country details.") }
        }
        for kind in profile.methods where kind.usesIndex {
            let index = try? await pricingIndex(method: kind, catalog: countries, sources: sources)
            if let index { indexes.append(index) }
            if index?.values[profile.guideTerritory] == nil { warnings.append("\(kind.name) has no observation for the guide country. Choose another pricing method or guide country.") }
        }
        let codes = selected.filter { !$0.currency.isEmpty }.map(\.code)
        let (points, failed) = try await PricePointCatalog.readAll(owner, territories: codes, client: client)
        if !failed.isEmpty { warnings.append("Some Apple price points could not be checked. Calculated amounts are shown without a price-point match.") }
        let rows = try PricingModels.calculate(profile, base: base, countries: selected, guideCurrency: guideCurrency, rates: rates, points: points, indexes: indexes, pointsUnavailable: failed)
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
