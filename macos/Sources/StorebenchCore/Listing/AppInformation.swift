import Foundation

public enum AppInformation {
    public static let categoryFields = ["primaryCategory", "primarySubcategoryOne", "primarySubcategoryTwo", "secondaryCategory", "secondarySubcategoryOne", "secondarySubcategoryTwo"]

    /// A read failure with Apple's status code; Apple's own error text is never shown.
    public static func loadMessage(_ error: Error, subject: String) -> String {
        switch error {
        case let failure as PublishFailure: return failure.message
        case AppStoreConnectClient.Failure.agreement: return ReportingMessages.appleAgreement
        case AppStoreConnectClient.Failure.status(401): return "App Store Connect did not accept the API key (status 401). Check the key in Settings, then refresh."
        case AppStoreConnectClient.Failure.status(403): return "The API key is not allowed to read \(subject) (status 403). Use an App Manager or Admin key, then refresh."
        case AppStoreConnectClient.Failure.status(let code): return "App Store Connect could not return \(subject) (status \(code)). Refresh to retry."
        default: return "App Store Connect could not return \(subject). Check the connection, then refresh."
        }
    }

    /// Validates the category selection: a primary category, distinct choices, subcategories under their parent.
    static func validate(_ selection: [String: String?]) throws {
        guard Set(selection.keys) == Set(categoryFields) else { throw PublishFailure.invalid("Choose a valid category selection.") }
        for field in categoryFields { if let id = selection[field] ?? nil, id.range(of: "^[A-Z][A-Z0-9_]{0,127}$", options: .regularExpression) == nil { throw PublishFailure.invalid("Choose a valid \(field) from Apple's category catalog.") } }
        let value = { (field: String) -> String? in selection[field] ?? nil }
        guard let primary = value("primaryCategory"), value("secondaryCategory") != primary,
              value("secondaryCategory") != nil || (value("secondarySubcategoryOne") == nil && value("secondarySubcategoryTwo") == nil),
              value("primarySubcategoryOne") != nil || value("primarySubcategoryTwo") == nil, value("secondarySubcategoryOne") != nil || value("secondarySubcategoryTwo") == nil,
              value("primarySubcategoryOne") == nil || value("primarySubcategoryOne") != value("primarySubcategoryTwo"),
              value("secondarySubcategoryOne") == nil || value("secondarySubcategoryOne") != value("secondarySubcategoryTwo") else { throw PublishFailure.invalid("Choose distinct categories and subcategories under their selected parent.") }
    }

    static func snapshot(_ info: AppStoreConnectClient.Resource) -> [String: String?] {
        Dictionary(uniqueKeysWithValues: categoryFields.map { ($0, Apple.owner(info, $0)?.id) })
    }

    /// Reject an incomplete catalog rather than presenting a shortened list as Apple's choices.
    public static func catalog(_ resources: [AppStoreConnectClient.Resource]) throws -> [AppCategory] {
        guard !resources.isEmpty, resources.count <= 500 else { throw PublishFailure.invalid("Apple's category catalog is unavailable.") }
        var seen = Set<String>()
        return try resources.map { item in
            guard item.type == "appCategories", item.id.range(of: "^[A-Z][A-Z0-9_]{0,127}$", options: .regularExpression) != nil,
                  seen.insert(item.id).inserted, case .array(let values)? = item.attributes?["platforms"], !values.isEmpty,
                  values.allSatisfy({ $0.string.map(["IOS", "MAC_OS", "TV_OS", "VISION_OS"].contains) == true }) else {
                throw PublishFailure.invalid("Apple returned an invalid category catalog.")
            }
            let parent: String?
            if let relationship = item.relationships?["parent"] {
                guard case .object(let relation) = relationship else { throw PublishFailure.invalid("Apple returned an invalid category catalog.") }
                if let data = relation["data"], data != .null {
                    guard let owner = Apple.owner(item, "parent"), owner.type == "appCategories" else { throw PublishFailure.invalid("Apple returned an invalid category catalog.") }
                    parent = owner.id.isEmpty ? nil : owner.id
                } else { parent = nil }
            } else { parent = nil }
            return AppCategory(id: item.id, parentId: parent, platforms: values.compactMap(\.string))
        }
    }

    public static func choices(_ catalog: [AppCategory], platforms: [String]) -> [AppCategory] {
        catalog.filter { category in platforms.allSatisfy(category.platforms.contains) }.sorted { $0.id < $1.id }
    }

    static func platforms(_ versions: [AppStoreConnectClient.Resource], appId: String) throws -> [String] {
        guard versions.allSatisfy({ $0.type == "appStoreVersions" && Apple.owned($0, "app", "apps", appId) }) else { throw PublishFailure.invalid("Apple returned versions outside the selected app.") }
        guard versions.allSatisfy({ $0.attributes?["platform"]?.string.map(["IOS", "MAC_OS", "TV_OS", "VISION_OS"].contains) == true }) else { throw PublishFailure.invalid("Apple did not confirm all of this app's platforms.") }
        return Array(Set(versions.compactMap { $0.attributes?["platform"]?.string })).sorted()
    }

    /// The category snapshot as JSON in field order, for `appInformationDigest`.
    static func snapshotJSON(_ info: AppStoreConnectClient.Resource) -> JSONText {
        .object(categoryFields.map { field in (field, Apple.owner(info, field).map { .string($0.id) } ?? .null) })
    }

    public static func categoryName(_ id: String?) -> String {
        guard let id else { return "None" }
        return id.replacingOccurrences(of: "_", with: " ").lowercased().split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

public struct AppCategory: Identifiable, Sendable, Equatable { public let id: String; public let parentId: String?; public let platforms: [String] }

public struct TerritoryAvailability: Identifiable, Sendable, Equatable {
    public let id, resourceId: String
    public let available: Bool
    public let preOrderEnabled: Bool?
    public let releaseDate, preOrderPublishDate: String?
    public let contentStatuses: [String]
    public init(id: String, resourceId: String, available: Bool, preOrderEnabled: Bool?, releaseDate: String? = nil, preOrderPublishDate: String? = nil, contentStatuses: [String] = []) {
        self.id = id; self.resourceId = resourceId; self.available = available; self.preOrderEnabled = preOrderEnabled
        self.releaseDate = releaseDate; self.preOrderPublishDate = preOrderPublishDate; self.contentStatuses = contentStatuses
    }
    public var supportsOrdinaryChange: Bool {
        preOrderEnabled == false && preOrderPublishDate == nil && !contentStatuses.contains { $0.contains("PREORDER") || $0.contains("PRE_ORDER") }
    }
    var json: JSONText {
        .object([("id", .string(id)), ("resourceId", .string(resourceId)), ("available", .bool(available)), ("preOrderEnabled", preOrderEnabled.map { .bool($0) } ?? .null),
                 ("releaseDate", releaseDate.map { .string($0) } ?? .null), ("preOrderPublishDate", preOrderPublishDate.map { .string($0) } ?? .null), ("contentStatuses", .array(contentStatuses.map { .string($0) }))])
    }
}

public struct AppInformationState: Sendable {
    public let contentRights: String?
    public let categories: [String: String?]?
    public let catalog: [AppCategory]
    public let territories: [TerritoryAvailability]
    public let platforms: [String]
    public let categoryError, availabilityError: String?
    public let availableInNewTerritories: Bool?

    public init(contentRights: String?, categories: [String: String?]?, catalog: [AppCategory], territories: [TerritoryAvailability], platforms: [String] = [],
                categoryError: String? = nil, availabilityError: String? = nil, availableInNewTerritories: Bool? = nil) {
        self.contentRights = contentRights; self.categories = categories; self.catalog = catalog; self.territories = territories; self.platforms = platforms
        self.categoryError = categoryError; self.availabilityError = availabilityError; self.availableInNewTerritories = availableInNewTerritories
    }
}

extension WorkspaceSession {
    /// The app's availability record and every territory, with its digest.
    func availabilitySnapshot(appId: String, client: AppStoreConnectClient, planner: Planner? = nil) async throws -> (territories: [TerritoryAvailability], digest: String, availableInNewTerritories: Bool?) {
        let get = { (path: String) in planner != nil ? try await planner!.get(path) : try await client.get(path) }
        let list = { (path: String) in planner != nil ? try await planner!.list(path) : try await client.list(path) }
        let response: [AppStoreConnectClient.Resource]
        do { response = try await get("/v1/apps/\(appId)/appAvailabilityV2?include=app") }
        catch AppStoreConnectClient.Failure.status(404) { throw PublishFailure.invalid("Countries or regions are not set up for this app at Apple yet. In App Store Connect, open Apps, select the app, click Pricing and Availability in the sidebar and choose Set Up Availability under App Availability. Then refresh.") }
        let validId = { (id: String) in id.range(of: "^[A-Za-z0-9_-]{1,256}$", options: .regularExpression) != nil }
        guard response.count == 1, let availability = response.first, availability.type == "appAvailabilities", validId(availability.id) else { throw PublishFailure.invalid("Apple did not confirm this app's availability record.") }
        if availability.relationships?["app"] != nil, !Apple.owned(availability, "app", "apps", appId) { throw PublishFailure.invalid("Apple returned availability outside the selected app.") }
        let future: JSONText
        switch availability.attributes?["availableInNewTerritories"] { case .bool(let flag)?: future = .bool(flag); case nil, .null?: future = .null; default: throw PublishFailure.invalid("Apple returned an invalid future territory setting.") }
        let resources = try await list("/v2/appAvailabilities/\(availability.id)/territoryAvailabilities?fields%5BterritoryAvailabilities%5D=available%2Cterritory%2CpreOrderEnabled%2CreleaseDate%2CpreOrderPublishDate%2CcontentStatuses&include=territory&limit=200")
        guard !resources.isEmpty, resources.count <= 300 else { throw PublishFailure.invalid("Apple did not return a complete territory availability list.") }
        var seen = Set<String>(), resourceIds = Set<String>()
        func date(_ value: JSONValue?) throws -> String? {
            guard let value, value != .null else { return nil }
            guard let text = value.string, ReportTables.validDate(text) else { throw PublishFailure.invalid("Apple returned an invalid territory availability date.") }
            return text
        }
        let territories = try resources.map { item -> TerritoryAvailability in
            guard item.type == "territoryAvailabilities", validId(item.id), resourceIds.insert(item.id).inserted,
                  item.relationships?["appAvailability"] == nil || Apple.owned(item, "appAvailability", "appAvailabilities", availability.id),
                  let territory = Apple.owner(item, "territory"), territory.type == "territories", territory.id.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil,
                  seen.insert(territory.id).inserted, case .bool(let available)? = item.attributes?["available"] else { throw PublishFailure.invalid("Apple returned incomplete, duplicate or unrelated territory availability.") }
            var preorder: Bool?
            switch item.attributes?["preOrderEnabled"] {
            case .bool(let flag)?: preorder = flag
            case nil, .null?: break
            default: throw PublishFailure.invalid("Apple returned invalid territory availability settings.")
            }
            var statuses: [String] = []
            if let value = item.attributes?["contentStatuses"] {
                guard case .array(let values) = value, values.allSatisfy({ $0.string != nil }), Set(values.compactMap(\.string)).count == values.count else {
                    throw PublishFailure.invalid("Apple returned invalid territory availability settings.")
                }
                statuses = values.compactMap(\.string).sorted()
            }
            return TerritoryAvailability(id: territory.id, resourceId: item.id, available: available, preOrderEnabled: preorder, releaseDate: try date(item.attributes?["releaseDate"]),
                                         preOrderPublishDate: try date(item.attributes?["preOrderPublishDate"]), contentStatuses: statuses)
        }.sorted { $0.id < $1.id }
        let digest = JSONText.object([("appId", .string(appId)), ("availabilityId", .string(availability.id)), ("availableInNewTerritories", future), ("territories", .array(territories.map(\.json)))]).sha256
        return (territories, digest, { if case .bool(let flag) = future { return flag }; return nil }())
    }

    /// Current app information for the editor: content rights, categories with Apple's catalog, and region availability.
    /// A view that shows only some of them reads only those: `categories` covers content rights, categories, the catalog and the app's platforms.
    public func appInformationState(appId: String, categories includeCategories: Bool = true, availability includeAvailability: Bool = true, client: AppStoreConnectClient) async throws -> AppInformationState {
        var rights: String?, categories: [String: String?]?
        var catalog: [AppCategory] = [], platforms: [String] = [], categoryError: String?
        if includeCategories {
            let apps = try await client.get("/v1/apps/\(appId)")
            guard apps.count == 1, let app = apps.first, app.type == "apps", app.id == appId else { throw PublishFailure.invalid("Apple returned a different app for content rights.") }
            rights = app.attributes?["contentRightsDeclaration"]?.string
            do {
                let infos = try await client.list("/v1/apps/\(appId)/appInfos?include=app&limit=200")
                guard infos.allSatisfy({ $0.type == "appInfos" && Apple.owned($0, "app", "apps", appId) }) else { throw PublishFailure.invalid("Apple returned app information outside the selected app.") }
                let editable = infos.filter { Apple.editable.contains(Apple.state($0)) }
                guard editable.count == 1 else { throw PublishFailure.invalid("Choose one editable app information record at Apple before changing categories.") }
                let records = try await client.get("/v1/appInfos/\(editable[0].id)?include=app,\(AppInformation.categoryFields.joined(separator: ","))")
                guard records.count == 1, let info = records.first, info.type == "appInfos", info.id == editable[0].id, Apple.owned(info, "app", "apps", appId) else { throw PublishFailure.invalid("Apple returned categories outside the selected app.") }
                let choices = try AppInformation.catalog(await client.list("/v1/appCategories?include=parent&limit=200"))
                let versions = try await client.list("/v1/apps/\(appId)/appStoreVersions?include=app&limit=200")
                let confirmedPlatforms = try AppInformation.platforms(versions, appId: appId)
                categories = AppInformation.snapshot(info); catalog = choices; platforms = confirmedPlatforms
            } catch {
                try Task.checkCancellation()
                categoryError = AppInformation.loadMessage(error, subject: "categories")
            }
        }
        var territories: [TerritoryAvailability] = [], future: Bool?, availabilityError: String?
        if includeAvailability {
            do { let snapshot = try await availabilitySnapshot(appId: appId, client: client); territories = snapshot.territories; future = snapshot.availableInNewTerritories }
            catch { try Task.checkCancellation(); availabilityError = AppInformation.loadMessage(error, subject: "countries and regions") }
        }
        return AppInformationState(contentRights: rights, categories: categories, catalog: catalog, territories: territories, platforms: platforms,
                                   categoryError: categoryError, availabilityError: availabilityError, availableInNewTerritories: future)
    }

    func planAppInformation(_ planner: Planner) async throws -> String {
        let request = planner.request
        if let rights = request.contentRightsDeclaration {
            guard let app = try await planner.get("/v1/apps/\(request.appId)").first, app.type == "apps", app.id == request.appId else { throw PublishFailure.invalid("Apple returned a different app for content rights.") }
            let current = app.attributes?["contentRightsDeclaration"]?.string
            let label = { (value: String?) in value == "USES_THIRD_PARTY_CONTENT" ? "Uses third-party content" : value == "DOES_NOT_USE_THIRD_PARTY_CONTENT" ? "Does not use third-party content" : "No declaration at Apple" }
            if current != rights {
                planner.add(.api, method: "PATCH", path: [.string("apps"), .string(request.appId)], label: "Update content rights declaration", detail: "Declare whether the app uses third-party content and has the necessary rights.",
                            before: label(current), after: label(rights), body: .object([("data", .object([("type", .string("apps")), ("id", .string(request.appId)), ("attributes", .object([("contentRightsDeclaration", .string(rights))]))]))]),
                            guard: .object([("kind", .string("app-content-rights")), ("digest", .string(Apple.jsonDigest(current.map { .string($0) } ?? .null)))]))
            }
        }
        if let selection = request.categorySelection {
            let infos = try await planner.list("/v1/apps/\(request.appId)/appInfos?include=app&limit=200")
            guard infos.allSatisfy({ $0.type == "appInfos" && Apple.owned($0, "app", "apps", request.appId) }) else { throw PublishFailure.invalid("Apple returned app information outside the selected app.") }
            let editable = infos.filter { Apple.editable.contains(Apple.state($0)) }
            guard editable.count == 1 else { throw PublishFailure.invalid("Choose one editable app information record at Apple before changing categories.") }
            guard let info = try await planner.get("/v1/appInfos/\(editable[0].id)?include=app,\(AppInformation.categoryFields.joined(separator: ","))").first, info.type == "appInfos", info.id == editable[0].id, Apple.owned(info, "app", "apps", request.appId) else {
                throw PublishFailure.invalid("Apple returned categories outside the selected app.")
            }
            let current = AppInformation.snapshot(info)
            let changed = AppInformation.categoryFields.filter { (current[$0] ?? nil) != (selection[$0] ?? nil) }
            if !changed.isEmpty {
                let catalog = try AppInformation.catalog(await planner.list("/v1/appCategories?include=parent&limit=200"))
                let platforms = try AppInformation.platforms(await appVersions(planner), appId: request.appId)
                for field in AppInformation.categoryFields {
                    guard let id = selection[field] ?? nil else { continue }
                    guard let category = catalog.first(where: { $0.id == id }), platforms.allSatisfy(category.platforms.contains) else { throw PublishFailure.invalid("The selected \(field) is not available for this app's platforms.") }
                    let parent = field.hasPrefix("primary") ? selection["primaryCategory"] ?? nil : selection["secondaryCategory"] ?? nil
                    guard field.hasSuffix("Category") ? category.parentId == nil : category.parentId == parent else { throw PublishFailure.invalid("The selected \(field) is not in its parent category.") }
                }
                let label = { (field: String) in field.replacingOccurrences(of: "([A-Z])", with: " $1", options: .regularExpression).lowercased().capitalizedFirst }
                let describe = { (value: [String: String?]) in changed.map { "\(label($0)): \(AppInformation.categoryName(value[$0] ?? nil))" }.joined(separator: "\n") }
                planner.add(.api, method: "PATCH", path: [.string("appInfos"), .string(info.id)], label: "Update App Store categories", detail: "\(changed.count) category \(changed.count == 1 ? "choice" : "choices"). Apple validates the category hierarchy.",
                            before: describe(current), after: describe(selection),
                            body: .object([("data", .object([("type", .string("appInfos")), ("id", .string(info.id)), ("relationships", .object(changed.map { field in (field, .object([("data", (selection[field] ?? nil).map { .object([("type", .string("appCategories")), ("id", .string($0))]) } ?? .null)])) }))]))]),
                            guard: .object([("kind", .string("app-categories")), ("digest", .string(Apple.jsonDigest(AppInformation.snapshotJSON(info))))]))
            }
        }
        planner.notes.append("Only the reviewed app information changes are sent. Category choices come from Apple's current catalog.")
        return "Update app information"
    }

    func planAvailability(_ planner: Planner) async throws -> String {
        let request = planner.request
        guard let id = request.territoryId, let available = request.territoryAvailable else { throw PublishFailure.invalid("Choose one country or region and its availability.") }
        let snapshot = try await availabilitySnapshot(appId: request.appId, client: planner.client, planner: planner)
        guard let territory = snapshot.territories.first(where: { $0.id == id }) else { throw PublishFailure.invalid("Choose a country or region returned for this app.") }
        guard territory.supportsOrdinaryChange else {
            throw PublishFailure.invalid("This region's normal availability could not be confirmed. Manage pre-orders and unknown pre-order settings under Pricing and Availability → App Availability in App Store Connect.")
        }
        let label = Self.countryName(id)
        if territory.available != available {
            planner.add(.api, method: "PATCH", path: [.string("territoryAvailabilities"), .string(territory.resourceId)], label: "Update region selection · \(label)",
                        detail: "Changes only this app's selected region. Apple controls regional restrictions and when distribution becomes available.",
                        before: territory.available ? "Selected for distribution" : "Not selected for distribution", after: available ? "Selected for distribution" : "Not selected for distribution",
                        body: .object([("data", .object([("type", .string("territoryAvailabilities")), ("id", .string(territory.resourceId)), ("attributes", .object([("available", .bool(available))]))]))]),
                        guard: .object([("kind", .string("app-territory-availability")), ("digest", .string(snapshot.digest)), ("territoryId", .string(id))]))
        }
        planner.notes.append("This review updates one existing region setting. It does not create a pre-order, change a release date, or confirm public availability. Review each additional region separately.")
        return "Region availability · \(label)"
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
