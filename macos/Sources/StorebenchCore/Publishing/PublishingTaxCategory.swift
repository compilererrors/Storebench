import Foundation

/// App Store Connect's tax categories for apps: each category with its subcategories and the conditions that can apply to it.
public struct TaxCategoryCatalog: Sendable, Equatable {
    public struct Category: Sendable, Equatable, Identifiable {
        public let id, name: String
        public let subcategoryRequired: Bool
        public let subcategories: [String], conditions: [String]
    }
    public let categories: [Category]
    public let conditionNames: [String: String]

    /// The categories App Store Connect lists first; their subcategories follow under them.
    public var top: [Category] { categories.filter { item in !categories.contains { $0.subcategories.contains(item.id) } } }
    public func category(_ id: String) -> Category? { categories.first { $0.id == id } }
    public func parent(of id: String) -> Category? { categories.first { $0.subcategories.contains(id) } }
    /// A category Apple accepts for an app: one without subcategories, or one whose subcategory is optional.
    public func selectable(_ id: String) -> Bool { category(id).map { $0.subcategories.isEmpty || !$0.subcategoryRequired } ?? false }
    /// The conditions that can apply to a category: its own and those of the categories above it.
    public func conditions(for id: String) -> [String] {
        var result: [String] = [], current = category(id), seen = Set<String>()
        while let item = current, seen.insert(item.id).inserted {
            for condition in item.conditions where !result.contains(condition) { result.append(condition) }
            current = parent(of: item.id)
        }
        return result
    }
    /// The category as App Store Connect names it, with the category above it.
    public func name(_ id: String) -> String {
        guard let item = category(id) else { return id }
        return parent(of: id).map { "\($0.name) · \(item.name)" } ?? item.name
    }
    /// The category Apple applies to an app until another is chosen.
    public var defaultName: String { categories.first { $0.name.lowercased() == "app store software" }?.name ?? "App Store software" }
}

/// The tax category to save for the app and the conditions that apply to it.
public struct TaxCategoryChoice: Sendable, Equatable {
    public var category: String
    public var conditions: [String]
    public init(category: String, conditions: [String] = []) { self.category = category; self.conditions = conditions }

    var json: JSONText { .object([("category", .string(category)), ("conditions", .array(conditions.map { .string($0) }))]) }
    init?(_ value: JSONText) {
        guard let category = value["category"]?.text, case .array(let items)? = value["conditions"], items.count <= 100 else { return nil }
        let conditions = items.compactMap(\.text)
        guard conditions.count == items.count else { return nil }
        self.init(category: category, conditions: conditions)
    }
    func validated() throws -> Self {
        let pattern = #"\A[A-Za-z0-9_.-]{1,100}\z"#
        guard category.range(of: pattern, options: .regularExpression) != nil, conditions.allSatisfy({ $0.range(of: pattern, options: .regularExpression) != nil }), Set(conditions).count == conditions.count else {
            throw PublishFailure.invalid("Choose a tax category App Store Connect offers.")
        }
        return self
    }
}

/// The app's tax category as App Store Connect has it now. Without a chosen category Apple applies its default.
public struct AppTaxCategoryState: Sendable, Equatable {
    public let configured: Bool
    public let category: String?
    public let conditions: [String]
    public let catalog: TaxCategoryCatalog
    /// The category in App Store Connect's words, or its default when none is chosen.
    public var label: String { category.map(catalog.name) ?? "Default · \(catalog.defaultName)" }
    /// The enabled conditions in App Store Connect's words, or None.
    public var conditionsLabel: String { conditions.isEmpty ? "None" : conditions.map { catalog.conditionNames[$0] ?? $0 }.joined(separator: ", ") }
    var digest: String { Apple.sha("\(configured):\(category ?? "-"):\(conditions.sorted().joined(separator: ","))") }
}

enum TaxCategoryReads {
    static let catalogPath = "/v1/taxCategories?filter%5BproductType%5D=APPLICATION&include=subcategories%2Cconditions&limit=200&limit%5Bsubcategories%5D=100&limit%5Bconditions%5D=100"
    static func path(_ appId: String) -> String { "/v1/appTaxCategories/\(appId)?include=category%2CenabledConditions&limit%5BenabledConditions%5D=100" }

    static func many(_ item: AppStoreConnectClient.Resource, _ name: String, _ type: String) -> [String] {
        guard case .object(let relation)? = item.relationships?[name], case .array(let items)? = relation["data"] else { return [] }
        return items.compactMap { value in
            guard case .object(let data) = value, data["type"] == .string(type), case .string(let id)? = data["id"] else { return nil }
            return id
        }
    }

    static func catalog(reads: AppleReads) async throws -> TaxCategoryCatalog {
        let page = try await reads.pages(catalogPath)
        var categories: [TaxCategoryCatalog.Category] = [], names: [String: String] = [:]
        for item in page.data + page.included {
            switch item.type {
            case "taxCategories" where !categories.contains(where: { $0.id == item.id }):
                categories.append(.init(id: item.id, name: item.attributes?["name"]?.string ?? item.id, subcategoryRequired: item.attributes?["subcategoryRequired"] == .bool(true),
                                        subcategories: many(item, "subcategories", "taxCategories"), conditions: many(item, "conditions", "taxConditions")))
            case "taxConditions": names[item.id] = item.attributes?["name"]?.string ?? item.id
            default: continue
            }
        }
        guard !categories.isEmpty else { throw PublishFailure.invalid("Apple did not return its tax categories. Sign in again with an Account Holder or Admin.") }
        return TaxCategoryCatalog(categories: categories, conditionNames: names)
    }

    static func state(appId: String, reads: AppleReads) async throws -> AppTaxCategoryState {
        let catalog = try await catalog(reads: reads)
        let item: AppStoreConnectClient.Resource?
        // Apple has no tax category resource for an app that still uses the default.
        do { item = try await reads.pages(path(appId)).data.first }
        catch AppStoreConnectClient.Failure.status(404) { item = nil }
        guard let item else { return AppTaxCategoryState(configured: false, category: nil, conditions: [], catalog: catalog) }
        guard item.type == "appTaxCategories", let category = Apple.owner(item, "category"), category.type == "taxCategories" else {
            throw PublishFailure.invalid("Apple returned a tax category Storebench cannot read.")
        }
        return AppTaxCategoryState(configured: true, category: category.id, conditions: many(item, "enabledConditions", "taxConditions"), catalog: catalog)
    }
}

extension AppleWebClient {
    /// Reads that also keep each answer as the review's evidence.
    func reads(recording planner: Planner) -> AppleReads {
        AppleReads(list: { path in let value = try await self.get(path); planner.evidence.append(.object([("path", .string(path)), ("result", .array(value.map(Planner.resource)))])); return value },
                   get: { path in let value = try await self.get(path); planner.evidence.append(.object([("path", .string(path)), ("result", .array(value.map(Planner.resource)))])); return value },
                   pages: { path in let value = try await self.pages(path); planner.evidence.append(.object([("path", .string(path)), ("result", .array(value.data.map(Planner.resource))), ("included", .array(value.included.map(Planner.resource)))])); return value })
    }
}

extension WorkspaceSession {
    /// The app's tax category and Apple's choices, read with the signed-in Apple ID. Nothing is written to Apple; the category is kept
    /// on this Mac for Release.
    public func taxCategoryState(account: Account, appId: String, writer: VaultWriter? = nil) async throws -> AppTaxCategoryState {
        try requireSessionAccess()
        let client = try appleWebClient(account: account, appId: appId, writer: writer)
        let state = try await TaxCategoryReads.state(appId: appId, reads: client.reads)
        try? recordSectionCheck(.tax, answered: true, detail: state.label, summary: state.conditionsLabel, accountId: account.id, appId: appId)
        return state
    }

    /// Plans the tax category: creates the app's category when it uses Apple's default, otherwise changes it. Read with the signed-in Apple ID.
    func planTaxCategory(_ planner: Planner, account: Account) async throws -> String {
        guard let choice = planner.request.taxCategory else { throw PublishFailure.invalid("Choose a tax category.") }
        let appId = planner.request.appId, client = try appleWebClient(account: account, appId: appId)
        let current = try await TaxCategoryReads.state(appId: appId, reads: client.reads(recording: planner)), catalog = current.catalog
        guard catalog.selectable(choice.category) else { throw PublishFailure.invalid("Choose a tax category App Store Connect offers for apps, including its subcategory where one is required.") }
        guard Set(choice.conditions).isSubset(of: catalog.conditions(for: choice.category)) else { throw PublishFailure.invalid("Choose only conditions App Store Connect offers for this tax category.") }
        planner.notes.append("Tax Category uses your Apple ID session, because Apple's API key cannot set it. It applies to the app, not only to this version, and choosing the category that fits the app is your responsibility.")
        if current.configured, current.category == choice.category, Set(current.conditions) == Set(choice.conditions) {
            planner.notes.append("App Store Connect already has this tax category."); return "Tax Category already saved"
        }
        var relationships: [(String, JSONText)] = [("category", Apple.relationship("taxCategories", .string(choice.category))),
                                                   ("enabledConditions", .object([("data", .array(choice.conditions.map { .object([("type", .string("taxConditions")), ("id", .string($0))]) }))]))]
        var data: [(String, JSONText)] = [("type", .string("appTaxCategories"))]
        if current.configured { data.append(("id", .string(appId))) } else { relationships.append(("app", Apple.relationship("apps", .string(appId)))) }
        data.append(("relationships", .object(relationships)))
        let after = catalog.name(choice.category) + (choice.conditions.isEmpty ? "" : " · " + choice.conditions.map { catalog.conditionNames[$0] ?? $0 }.joined(separator: ", "))
        planner.add(.api, method: current.configured ? "PATCH" : "POST", path: current.configured ? [.string("appTaxCategories"), .string(appId)] : [.string("appTaxCategories")],
                    label: "Tax Category · \(catalog.name(choice.category))", detail: "Save the app's tax category in App Store Connect.", before: current.label, after: after,
                    body: .object([("data", .object(data))]),
                    guard: .object([("kind", .string("tax-category")), ("configured", .bool(current.configured)), ("digest", .string(current.digest)),
                                    ("label", .string(catalog.name(choice.category))), ("conditions", .string(choice.conditions.isEmpty ? "None" : choice.conditions.map { catalog.conditionNames[$0] ?? $0 }.joined(separator: ", ")))]))
        return "Save Tax Category"
    }

    /// Tax category write check with fresh reads: only this app, a category and conditions Apple offers, and the category as reviewed.
    func verifyTaxCategoryWrite(method: String, parts: [String], body: JSONText?, guardValue: JSONText?, account: Account, appId: String) async throws {
        let client = try appleWebClient(account: account, appId: appId), current = try await TaxCategoryReads.state(appId: appId, reads: client.reads)
        let refuse = PublishFailure.write("Unsupported Tax Category change.")
        let data = body?["data"], links = data?["relationships"]
        guard data?["type"]?.text == "appTaxCategories", data?["attributes"] == nil, case .object(let fields)? = links,
              links?["category"]?["data"]?["type"]?.text == "taxCategories", let category = links?["category"]?["data"]?["id"]?.text, current.catalog.selectable(category),
              case .array(let items)? = links?["enabledConditions"]?["data"], items.allSatisfy({ $0["type"]?.text == "taxConditions" }),
              Set(items.compactMap { $0["id"]?.text }).isSubset(of: current.catalog.conditions(for: category)), items.count == items.compactMap({ $0["id"]?.text }).count,
              case .bool(let configured)? = guardValue?["configured"] else { throw refuse }
        switch method {
        case "POST":
            guard !configured, parts == ["appTaxCategories"], data?["id"] == nil, Set(fields.map(\.0)) == ["category", "enabledConditions", "app"],
                  links?["app"]?["data"]?["type"]?.text == "apps", links?["app"]?["data"]?["id"]?.text == appId else { throw refuse }
        case "PATCH":
            guard configured, parts == ["appTaxCategories", appId], data?["id"]?.text == appId, Set(fields.map(\.0)) == ["category", "enabledConditions"] else { throw refuse }
        default: throw refuse
        }
        guard current.configured == configured, current.digest == guardValue?["digest"]?.text else { throw PublishFailure.write("The tax category changed at Apple after approval. Prepare a new review.") }
    }
}
