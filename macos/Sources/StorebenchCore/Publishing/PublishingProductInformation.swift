import Foundation

/// What App Review needs on one in-app purchase or subscription, as Apple reports it now. Nil means Apple's answer could not be read.
public struct ProductReadiness: Sendable, Equatable, Identifiable {
    public let product: PriceProduct
    public let priced, available, screenshot: Bool?
    /// Languages with both a display name and a description on the product's current version, and with a display name on its
    /// Subscription Group's current version.
    public let locales, groupLocales: [String]?
    public var id: String { product.selectionKey }
    public init(product: PriceProduct, priced: Bool?, available: Bool?, screenshot: Bool?, locales: [String]?, groupLocales: [String]?) {
        self.product = product; self.priced = priced; self.available = available; self.screenshot = screenshot; self.locales = locales; self.groupLocales = groupLocales
    }
    /// A product whose requirements are all unknown, such as one from an earlier check whose family Apple did not list this time.
    public static func unknown(_ product: PriceProduct) -> ProductReadiness {
        ProductReadiness(product: product, priced: nil, available: nil, screenshot: nil, locales: nil, groupLocales: nil)
    }
    /// What is still missing, in App Store Connect's words; unknown answers are listed as unknown.
    public var missing: [String] {
        var items: [String] = []
        func check(_ value: Bool?, _ label: String) { if value == nil { items.append(label + " (unknown)") } else if value == false { items.append(label) } }
        check(priced, "Price")
        check(available, "Availability")
        check(locales.map { !$0.isEmpty }, "Display Name and Description")
        if product.kind == .subscription { check(groupLocales.map { !$0.isEmpty }, "Subscription Group Display Name") }
        check(screenshot, "Review Screenshot")
        return items
    }
    public var ready: Bool { missing.isEmpty }
    /// Whether any requirement could not be read, so the product's status is unknown rather than done or needed.
    public var uncertain: Bool { missing.contains { $0.hasSuffix("(unknown)") } }
    /// Whether nothing about the product could be read.
    public var unread: Bool { priced == nil && available == nil && screenshot == nil && locales == nil && (product.kind != .subscription || groupLocales == nil) }
}

/// One check of the products' requirements: the products it reached, those it did not reach yet and the product families Apple did not list.
public struct ProductReadinessCheck: Sendable, Equatable {
    /// How many products one check reads, so a large catalog is checked in parts the user asks for.
    public static let batch = 40
    public var products: [ProductReadiness]
    /// Products Apple listed that this check did not reach; Check More reads the next batch.
    public var unchecked: [PriceProduct]
    /// Product families Apple's catalog could not be read for.
    public var unread: [PriceProduct.Kind]
    public init(products: [ProductReadiness], unchecked: [PriceProduct] = [], unread: [PriceProduct.Kind] = []) {
        self.products = products; self.unchecked = unchecked; self.unread = unread
    }
    public var complete: Bool { unchecked.isEmpty && unread.isEmpty }
    /// App Store Connect's name for a product family.
    public static func family(_ kind: PriceProduct.Kind) -> String { kind == .subscription ? "Subscriptions" : "In-App Purchases" }
    /// This check, keeping the products an earlier check found in a family Apple did not list this time, now as unknown.
    public func keeping(_ previous: ProductReadinessCheck?) -> ProductReadinessCheck {
        guard let previous, !unread.isEmpty else { return self }
        let kinds = Set(unread), known = Set(products.map(\.id))
        var result = self
        result.products += previous.products.filter { kinds.contains($0.product.kind) && !known.contains($0.id) }.map { ProductReadiness.unknown($0.product) }
        return result
    }
}

/// Apple reads for a product's availability, versions and localizations, shared by the readiness read, the planner and the write checks.
enum ProductInformationReads {
    static let editable: Set<String> = ["PREPARE_FOR_SUBMISSION", "REJECTED", "DEVELOPER_REJECTED"]
    static func optional(_ reads: AppleReads, _ path: String) async throws -> [AppStoreConnectClient.Resource] {
        do { return try await reads.get(path) } catch AppStoreConnectClient.Failure.status(404) { return [] }
    }
    static func availability(_ product: PriceProduct, reads: AppleReads) async throws -> AppStoreConnectClient.Resource? {
        let subscription = product.kind == .subscription
        let items = try await optional(reads, subscription ? "/v1/subscriptions/\(product.id)/subscriptionAvailability" : "/v2/inAppPurchases/\(product.id)/inAppPurchaseAvailability")
        guard items.count <= 1, items.allSatisfy({ $0.type == (subscription ? "subscriptionAvailabilities" : "inAppPurchaseAvailabilities") }) else { throw PublishFailure.invalid("Apple returned an unexpected product availability.") }
        return items.first
    }
    static func versions(_ product: PriceProduct, reads: AppleReads) async throws -> [AppStoreConnectClient.Resource] {
        let subscription = product.kind == .subscription
        return try ProductPricing.unique(try await reads.list(subscription ? "/v1/subscriptions/\(product.id)/versions?limit=200" : "/v2/inAppPurchases/\(product.id)/versions?limit=200"),
                                         subscription ? "subscriptionVersions" : "inAppPurchaseVersions")
    }
    static func groupVersions(_ group: String, reads: AppleReads) async throws -> [AppStoreConnectClient.Resource] {
        try ProductPricing.unique(try await reads.list("/v1/subscriptionGroups/\(group)/versions?limit=200"), "subscriptionGroupVersions")
    }
    /// The newest version by Apple's version number.
    static func latest(_ versions: [AppStoreConnectClient.Resource]) -> AppStoreConnectClient.Resource? {
        versions.max { (number($0), $0.id) < (number($1), $1.id) }
    }
    static func number(_ item: AppStoreConnectClient.Resource) -> Double { if case .number(let value)? = item.attributes?["version"] { value } else { -1 } }
    static func state(_ item: AppStoreConnectClient.Resource) -> String { item.attributes?["state"]?.string ?? "" }
    static func localizations(_ version: AppStoreConnectClient.Resource, reads: AppleReads) async throws -> [AppStoreConnectClient.Resource] {
        let type = version.type == "subscriptionVersions" ? "subscriptionLocalizations" : version.type == "inAppPurchaseVersions" ? "inAppPurchaseLocalizations" : "subscriptionGroupLocalizations"
        return try ProductPricing.unique(try await reads.list("/v1/\(version.type)/\(version.id)/localizations?limit=200"), type)
    }
    /// Languages whose localization has every `required` attribute filled in: a product needs its display name and description,
    /// a Subscription Group only its display name.
    static func locales(_ items: [AppStoreConnectClient.Resource], required: [String]) -> [String] {
        items.filter { item in required.allSatisfy { !ProductPricing.text(item.attributes?[$0]).isEmpty } }.compactMap { $0.attributes?["locale"]?.string }.sorted()
    }
    static func required(_ version: AppStoreConnectClient.Resource) -> [String] { version.type == "subscriptionGroupVersions" ? ["name"] : ["name", "description"] }
    /// A product localization's written attributes, in App Store Connect's words.
    static func productFields(name: String, description: String) -> [(key: String, label: String, value: String)] {
        [("name", "Display Name", name), ("description", "Description", description)]
    }
    static func groupFields(name: String) -> [(key: String, label: String, value: String)] { [("name", "Subscription Group Display Name", name)] }
    /// The language and each field with its text, one per line, as a review shows them before and after.
    static func listing(locale: String, _ fields: [(String, String)]) -> String {
        (["Language: \(StoreLocales.name(locale)) (\(locale))"] + fields.map { "\($0.0): \($0.1.isEmpty ? "(empty)" : $0.1)" }).joined(separator: "\n")
    }
    static func groupId(_ product: PriceProduct, appId: String, reads: AppleReads) async throws -> String {
        for group in try await PricingSetupReads.groups(appId: appId, reads: reads) {
            let items = try ProductPricing.unique(try await reads.list("/v1/subscriptionGroups/\(group.id)/subscriptions?limit=200"), "subscriptions")
            if items.contains(where: { $0.id == product.id }) { return group.id }
        }
        throw PublishFailure.invalid("The subscription's group could not be found at Apple.")
    }
    static func screenshot(_ product: PriceProduct, latest: AppStoreConnectClient.Resource?, reads: AppleReads) async throws -> Bool {
        if product.kind == .subscription { return !(try await optional(reads, "/v1/subscriptions/\(product.id)/appStoreReviewScreenshot")).isEmpty }
        if let latest, !(try await optional(reads, "/v1/inAppPurchaseVersions/\(latest.id)/image")).isEmpty { return true }
        return !(try await optional(reads, "/v2/inAppPurchases/\(product.id)/appStoreReviewScreenshot")).isEmpty
    }
}

extension WorkspaceSession {
    /// What App Review still needs on the first `limit` in-app purchases and subscriptions, with the products not reached yet and the
    /// product families that could not be read. Answers warmed earlier in this session are used unless `fresh`. Nothing is written.
    public func productReadiness(account: Account, appId: String, fresh: Bool, limit: Int = ProductReadinessCheck.batch) async throws -> ProductReadinessCheck {
        return try await AppStoreReadCache.$refreshedSince.withValue(fresh ? .now : AppStoreReadCache.refreshedSince) {
            let client = try readClient(for: account)
            return try await AppStoreReadCache.rereadingAfterInvalidation { try await productReadiness(account: account, appId: appId, client: client, limit: limit) }
        }
    }
    public func productReadiness(account: Account, appId: String, client: AppStoreConnectClient, limit: Int = ProductReadinessCheck.batch) async throws -> ProductReadinessCheck {
        try requirePublishingAccount(account, appId: appId, client: client)
        let reads = AppleReads(client), catalog = try await ProductPricing.catalog(appId: appId, reads: reads)
        let all = (catalog.purchases ?? []) + (catalog.subscriptions ?? []), reached = all.prefix(max(0, limit))
        var result: [ProductReadiness] = []
        for product in reached {
            let priced = try? await ProductPricing.schedule(product, reads: reads).available
            var available: Bool?
            do { available = try await ProductInformationReads.availability(product, reads: reads) != nil } catch { try Task.checkCancellation() }
            var locales: [String]?, latest: AppStoreConnectClient.Resource?
            if let versions = try? await ProductInformationReads.versions(product, reads: reads) {
                latest = ProductInformationReads.latest(versions)
                if let latest { locales = (try? await ProductInformationReads.localizations(latest, reads: reads)).map { ProductInformationReads.locales($0, required: ProductInformationReads.required(latest)) } } else { locales = [] }
            }
            let screenshot = try? await ProductInformationReads.screenshot(product, latest: latest, reads: reads)
            var groupLocales: [String]?
            if product.kind == .subscription, let group = try? await ProductInformationReads.groupId(product, appId: appId, reads: reads),
               let versions = try? await ProductInformationReads.groupVersions(group, reads: reads) {
                if let version = ProductInformationReads.latest(versions) { groupLocales = (try? await ProductInformationReads.localizations(version, reads: reads)).map { ProductInformationReads.locales($0, required: ProductInformationReads.required(version)) } } else { groupLocales = [] }
            }
            result.append(ProductReadiness(product: product, priced: priced, available: available, screenshot: screenshot, locales: locales, groupLocales: groupLocales))
        }
        try Task.checkCancellation(); try requirePublishingAccount(account, appId: appId, client: client)
        let unread = [(catalog.purchases, PriceProduct.Kind.purchase), (catalog.subscriptions, .subscription)].filter { $0.0 == nil }.map(\.1)
        return ProductReadinessCheck(products: result, unchecked: Array(all.dropFirst(reached.count)), unread: unread)
    }

    /// Whether the product's newest version, and its Subscription Group's when the change names the group, already has the change's
    /// text in its language. Read again from Apple, so a version Apple has just started is compared with the text that was asked for.
    public func productInformationMatches(account: Account, appId: String, change: PricingSetupChange) async throws -> Bool {
        try await productInformationMatches(account: account, appId: appId, change: change, client: try client(for: account))
    }
    public func productInformationMatches(account: Account, appId: String, change: PricingSetupChange, client: AppStoreConnectClient) async throws -> Bool {
        let change = try change.validated()
        try requirePublishingAccount(account, appId: appId, client: client)
        let reads = AppleReads(client), subscription = change.itemKind == "subscription", catalog = try await ProductPricing.catalog(appId: appId, reads: reads)
        guard let locale = change.locale, let product = (subscription ? catalog.subscriptions : catalog.purchases)?.first(where: { $0.id == change.itemId }) else {
            throw PublishFailure.invalid("The product is unavailable or no longer belongs to this app.")
        }
        func matches(_ versions: [AppStoreConnectClient.Resource], _ fields: [(key: String, label: String, value: String)]) async throws -> Bool {
            guard let latest = ProductInformationReads.latest(versions),
                  let item = try await ProductInformationReads.localizations(latest, reads: reads).first(where: { $0.attributes?["locale"]?.string == locale }) else { return false }
            return fields.allSatisfy { ProductPricing.text(item.attributes?[$0.key]) == $0.value }
        }
        if let name = change.displayName, let details = change.details,
           !(try await matches(try await ProductInformationReads.versions(product, reads: reads), ProductInformationReads.productFields(name: name, description: details))) { return false }
        if subscription, let name = change.groupDisplayName {
            let group = try await ProductInformationReads.groupId(product, appId: appId, reads: reads)
            if !(try await matches(try await ProductInformationReads.groupVersions(group, reads: reads), ProductInformationReads.groupFields(name: name))) { return false }
        }
        try Task.checkCancellation(); try requirePublishingAccount(account, appId: appId, client: client)
        return true
    }

    /// Plans a product's availability in every country or region, its display name and description, and its Subscription Group's display name.
    /// A product whose metadata has to start a new version gets only the version first; the same change prepared again then adds the text.
    func planProductInformation(_ planner: Planner, _ change: PricingSetupChange) async throws -> String {
        let appId = planner.request.appId, reads = AppleReads(planner), subscription = change.itemKind == "subscription"
        let catalog = try await ProductPricing.catalog(appId: appId, reads: reads)
        guard let product = (subscription ? catalog.subscriptions : catalog.purchases)?.first(where: { $0.id == change.itemId }) else { throw PublishFailure.invalid("The product is unavailable or no longer belongs to this app.") }
        let link = subscription ? ("subscription", "subscriptions") : ("inAppPurchase", "inAppPurchases")
        func setupGuard(_ part: String, _ digest: String, _ extra: [(String, JSONText)] = []) -> JSONText {
            .object([("kind", .string("pricing-setup")), ("action", .string("product-information")), ("part", .string(part)), ("itemId", .string(product.id)), ("itemKind", .string(change.itemKind!)), ("digest", .string(digest))] + extra)
        }
        if change.allTerritories == true {
            if try await ProductInformationReads.availability(product, reads: reads) != nil {
                planner.notes.append("\(product.name) already has its availability at Apple. Change its countries or regions in App Store Connect.")
            } else {
                let territories = try await PricingSetupReads.territories(reads: reads), root = subscription ? "subscriptionAvailabilities" : "inAppPurchaseAvailabilities"
                planner.add(.api, method: "POST", path: [.string(root)], label: "Availability · \(product.name) · All countries and regions", detail: "Make the product available in every country or region where the app is, and in new ones Apple adds.",
                            before: "No availability", after: "\(territories.count) countries and regions · new countries and regions included",
                            body: .object([("data", .object([("type", .string(root)), ("attributes", .object([("availableInNewTerritories", .bool(true))])),
                                ("relationships", .object([(link.0, Apple.relationship(link.1, .string(product.id))), ("availableTerritories", .object([("data", .array(territories.map { .object([("type", .string("territories")), ("id", .string($0))]) }))]))]))]))]),
                            guard: setupGuard("availability", "none"), group: "Availability")
            }
        }
        /// Text on the product's or group's draft version: adds the version first when Apple has none to edit.
        /// `fields` are the attribute, App Store Connect's field name and the new text; the review lists each of them with its language.
        func text(versions: [AppStoreConnectClient.Resource], versionType: String, owner: (String, String, String), localizationType: String, fields: [(key: String, label: String, value: String)], label: String, part: String) async throws {
            let latest = ProductInformationReads.latest(versions), locale = change.locale!
            let attributes: [(String, JSONText)] = fields.map { ($0.key, .string($0.value)) } + [("locale", .string(locale))]
            let after = ProductInformationReads.listing(locale: locale, fields.map { ($0.label, $0.value) })
            if let latest, ProductInformationReads.editable.contains(ProductInformationReads.state(latest)) {
                let current = try await ProductInformationReads.localizations(latest, reads: reads), digest = PricingSetupWrites.digest(current)
                if let existing = current.first(where: { $0.attributes?["locale"]?.string == locale }) {
                    let now = fields.map { ($0.label, ProductPricing.text(existing.attributes?[$0.key])) }
                    if zip(now, fields).allSatisfy({ $0.0.1 == $0.1.value }) { planner.notes.append("\(label) already matches at Apple."); return }
                    planner.add(.api, method: "PATCH", path: [.string("v2"), .string(localizationType), .string(existing.id)], label: "\(label) · \(locale)", detail: "Change the text on the draft version.",
                                before: ProductInformationReads.listing(locale: locale, now),
                                after: ProductInformationReads.listing(locale: locale, zip(now, fields).map { ($0.1.label, $0.1.value + ($0.0.1 == $0.1.value ? " (unchanged)" : "")) }),
                                body: .object([("data", .object([("type", .string(localizationType)), ("id", .string(existing.id)), ("attributes", .object(attributes.filter { $0.0 != "locale" }))]))]),
                                guard: setupGuard(part, digest, [("version", .string(latest.id))]), group: "Text")
                } else {
                    planner.add(.api, method: "POST", path: [.string("v2"), .string(localizationType)], label: "\(label) · \(locale)", detail: "Add the text to the draft version.", before: "No text in \(StoreLocales.name(locale))", after: after,
                                body: .object([("data", .object([("type", .string(localizationType)), ("attributes", .object(attributes)), ("relationships", .object([("version", Apple.relationship(versionType, .string(latest.id)))]))]))]),
                                guard: setupGuard(part, digest, [("version", .string(latest.id))]), group: "Text")
                }
                return
            }
            let key = planner.add(.api, method: "POST", path: [.string(versionType)], label: "New version · \(label)", detail: "Start a draft version that holds the text App Review reads.",
                                  before: latest.map { "Version \(Int(ProductInformationReads.number($0))) · \(AppStoreNames.state(ProductInformationReads.state($0)))" } ?? "No version", after: "Draft version",
                                  body: .object([("data", .object([("type", .string(versionType)), ("relationships", .object([(owner.0, Apple.relationship(owner.1, .string(owner.2)))]))]))]),
                                  guard: setupGuard(part + "-version", PricingSetupWrites.digest(versions)), group: "Text")
            if latest == nil {
                planner.add(.api, method: "POST", path: [.string("v2"), .string(localizationType)], label: "\(label) · \(locale)", detail: "Add the text to the new draft version.", before: "No text in \(StoreLocales.name(locale))", after: after,
                            body: .object([("data", .object([("type", .string(localizationType)), ("attributes", .object(attributes)), ("relationships", .object([("version", Apple.relationship(versionType, Apple.ref(key)))]))]))]),
                            guard: setupGuard(part, PricingSetupWrites.digest([]), [("version", .string("new"))]), group: "Text")
            } else {
                planner.notes.append("Apple copies the current text into the new draft version. After this review, Storebench compares the text on it with yours and prepares the text change as its own review.")
            }
        }
        if let name = change.displayName, let details = change.details {
            try await text(versions: try await ProductInformationReads.versions(product, reads: reads), versionType: subscription ? "subscriptionVersions" : "inAppPurchaseVersions", owner: (link.0, link.1, product.id),
                           localizationType: subscription ? "subscriptionLocalizations" : "inAppPurchaseLocalizations",
                           fields: ProductInformationReads.productFields(name: name, description: details), label: "Display Name and Description · \(product.name)", part: "localization")
        }
        if let name = change.groupDisplayName, subscription {
            let group = try await ProductInformationReads.groupId(product, appId: appId, reads: reads)
            try await text(versions: try await ProductInformationReads.groupVersions(group, reads: reads), versionType: "subscriptionGroupVersions", owner: ("subscriptionGroup", "subscriptionGroups", group),
                           localizationType: "subscriptionGroupLocalizations", fields: ProductInformationReads.groupFields(name: name), label: "Subscription Group Display Name", part: "group-localization")
        }
        planner.notes.append("Upload the review screenshot in App Store Connect under Monetization → \(subscription ? "Subscriptions" : "In-App Purchases") → \(product.name) → Review Information.")
        return "Product information · \(product.name)"
    }

    /// Product information write check: only the reviewed product, version or group of the approved app, and Apple's state as reviewed.
    func verifyProductInformation(root: String, method: String, path: String, parts: [String], body: JSONText?, guardValue: JSONText?, appId: String, reads: AppleReads) async throws {
        func refuse() -> PublishFailure { .write("Unsupported product information change.") }
        func changed() -> PublishFailure { .write("The product changed at Apple after approval. Prepare a new review.") }
        func keys(_ value: JSONText?) -> Set<String> { if case .object(let pairs)? = value { Set(pairs.map(\.0)) } else { [] } }
        let data = body?["data"], subscription = guardValue?["itemKind"]?.text == "subscription", part = guardValue?["part"]?.text ?? ""
        func linked(_ name: String) -> (type: String, id: String)? {
            guard let item = data?["relationships"]?[name]?["data"], let type = item["type"]?.text, let id = item["id"]?.text else { return nil }
            return (type, id)
        }
        guard let itemId = guardValue?["itemId"]?.text, keys(body) == ["data"], data?["type"]?.text == root, (path.hasPrefix("/v2/")) == PricingSetupWrites.version2.contains(root) else { throw refuse() }
        let catalog = try await ProductPricing.catalog(appId: appId, reads: reads)
        guard let product = (subscription ? catalog.subscriptions : catalog.purchases)?.first(where: { $0.id == itemId }) else { throw refuse() }
        let link = subscription ? ("subscription", "subscriptions") : ("inAppPurchase", "inAppPurchases")
        switch root {
        case "subscriptionAvailabilities", "inAppPurchaseAvailabilities":
            guard part == "availability", method == "POST", parts == [root], root == (subscription ? "subscriptionAvailabilities" : "inAppPurchaseAvailabilities"), linked(link.0).map({ $0 == (link.1, product.id) }) == true,
                  keys(data?["attributes"]) == ["availableInNewTerritories"], keys(data?["relationships"]) == [link.0, "availableTerritories"],
                  case .array(let territories)? = data?["relationships"]?["availableTerritories"]?["data"], !territories.isEmpty, territories.allSatisfy({ $0["type"]?.text == "territories" }) else { throw refuse() }
            guard try await ProductInformationReads.availability(product, reads: reads) == nil else { throw changed() }
        case "subscriptionVersions", "inAppPurchaseVersions", "subscriptionGroupVersions":
            guard method == "POST", parts == [root], data?["attributes"] == nil else { throw refuse() }
            let versions: [AppStoreConnectClient.Resource]
            if root == "subscriptionGroupVersions" {
                let group = try await ProductInformationReads.groupId(product, appId: appId, reads: reads)
                guard part == "group-localization-version", subscription, keys(data?["relationships"]) == ["subscriptionGroup"], linked("subscriptionGroup").map({ $0 == ("subscriptionGroups", group) }) == true else { throw refuse() }
                versions = try await ProductInformationReads.groupVersions(group, reads: reads)
            } else {
                guard part == "localization-version", root == (subscription ? "subscriptionVersions" : "inAppPurchaseVersions"), keys(data?["relationships"]) == [link.0], linked(link.0).map({ $0 == (link.1, product.id) }) == true else { throw refuse() }
                versions = try await ProductInformationReads.versions(product, reads: reads)
            }
            guard PricingSetupWrites.digest(versions) == guardValue?["digest"]?.text else { throw changed() }
        case "subscriptionLocalizations", "inAppPurchaseLocalizations", "subscriptionGroupLocalizations":
            let group = root == "subscriptionGroupLocalizations"
            guard part == (group ? "group-localization" : "localization"), group ? subscription : root == (subscription ? "subscriptionLocalizations" : "inAppPurchaseLocalizations"),
                  keys(data?["attributes"]).isSubset(of: group ? ["name", "locale"] : ["name", "locale", "description"]) else { throw refuse() }
            let versions = group ? try await ProductInformationReads.groupVersions(try await ProductInformationReads.groupId(product, appId: appId, reads: reads), reads: reads)
                                 : try await ProductInformationReads.versions(product, reads: reads)
            let versionId: String
            if method == "POST" {
                guard parts == [root], keys(data?["relationships"]) == ["version"], let version = linked("version"), version.type == (group ? "subscriptionGroupVersions" : subscription ? "subscriptionVersions" : "inAppPurchaseVersions"),
                      guardValue?["version"]?.text == "new" || guardValue?["version"]?.text == version.id, data?["attributes"]?["locale"]?.text.map(StoreLocales.codes.contains) == true else { throw refuse() }
                versionId = version.id
            } else {
                guard method == "PATCH", parts.count == 2, parts[0] == root, data?["id"]?.text == parts[1], data?["relationships"] == nil, let version = guardValue?["version"]?.text else { throw refuse() }
                versionId = version
            }
            guard let version = versions.first(where: { $0.id == versionId }), ProductInformationReads.editable.contains(ProductInformationReads.state(version)) else { throw changed() }
            let current = try await ProductInformationReads.localizations(version, reads: reads)
            if method == "PATCH" { guard current.contains(where: { $0.id == parts[1] }) else { throw refuse() } }
            guard PricingSetupWrites.digest(current) == guardValue?["digest"]?.text else { throw changed() }
        default: throw refuse()
        }
    }
}

extension WorkspaceSession {
    /// Apple accepts a subscription's or in-app purchase's prices only in the countries or regions where it is available. A product with no
    /// availability yet gets it first, in the same review, for `territories`; one that has it returns where prices can be set now.
    func availabilityForPrices(_ product: PriceProduct, territories: [String], newTerritories: Bool, planner: Planner, reads: AppleReads) async throws -> Set<String>? {
        let subscription = product.kind == .subscription, root = subscription ? "subscriptionAvailabilities" : "inAppPurchaseAvailabilities"
        if let existing = try await ProductInformationReads.availability(product, reads: reads) {
            let items = try ProductPricing.unique(try await reads.list("/v1/\(root)/\(existing.id)/availableTerritories?limit=200"), "territories")
            return Set(items.map(\.id))
        }
        let link = subscription ? ("subscription", "subscriptions") : ("inAppPurchase", "inAppPurchases"), codes = Array(Set(territories)).sorted()
        planner.add(.api, method: "POST", path: [.string(root)], label: "Availability · \(product.name) · \(codes.count) \(codes.count == 1 ? "country or region" : "countries and regions")",
                    detail: "Apple sets prices only where the product is available, so it becomes available in the countries or regions that get a price\(newTerritories ? ", and in new ones Apple adds" : "").",
                    before: "No availability", after: "\(codes.count) \(codes.count == 1 ? "country or region" : "countries and regions")\(newTerritories ? " · new countries and regions included" : "")",
                    body: .object([("data", .object([("type", .string(root)), ("attributes", .object([("availableInNewTerritories", .bool(newTerritories))])),
                        ("relationships", .object([(link.0, Apple.relationship(link.1, .string(product.id))), ("availableTerritories", .object([("data", .array(codes.map { .object([("type", .string("territories")), ("id", .string($0))]) }))]))]))]))]),
                    guard: .object([("kind", .string("pricing-setup")), ("action", .string("product-information")), ("part", .string("availability")), ("itemId", .string(product.id)),
                                    ("itemKind", .string(subscription ? "subscription" : "purchase")), ("digest", .string("none"))]), group: "Availability")
        return nil
    }
}
