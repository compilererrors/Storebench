import Foundation

/// App Privacy in App Store Connect's words: whether the app collects data, and for each data type its purposes,
/// whether it is linked to the user and whether it is used for tracking.
public struct AppPrivacyAnswers: Sendable, Equatable {
    public struct Item: Sendable, Equatable, Identifiable {
        public var category: String
        public var purposes: [String]
        public var linked: Bool, tracking: Bool
        public var id: String { category }
        public init(category: String, purposes: [String] = [], linked: Bool = true, tracking: Bool = false) { self.category = category; self.purposes = purposes; self.linked = linked; self.tracking = tracking }
    }
    public var collects: Bool
    public var items: [Item]
    public init(collects: Bool, items: [Item] = []) { self.collects = collects; self.items = items }

    public static let notCollected = "DATA_NOT_COLLECTED", linked = "DATA_LINKED_TO_YOU", notLinked = "DATA_NOT_LINKED_TO_YOU", tracking = "DATA_USED_TO_TRACK_YOU"
    public static let purposes = [("APP_FUNCTIONALITY", "App Functionality"), ("ANALYTICS", "Analytics"), ("PRODUCT_PERSONALIZATION", "Product Personalization"),
                                  ("DEVELOPERS_ADVERTISING", "Developer's Advertising or Marketing"), ("THIRD_PARTY_ADVERTISING", "Third-Party Advertising"), ("OTHER_PURPOSES", "Other Purposes")]
    /// Apple's data types grouped as App Store Connect shows them.
    public static let groups: [(String, [(String, String)])] = [
        ("Contact Info", [("NAME", "Name"), ("EMAIL_ADDRESS", "Email Address"), ("PHONE_NUMBER", "Phone Number"), ("PHYSICAL_ADDRESS", "Physical Address"), ("OTHER_CONTACT_INFO", "Other User Contact Info")]),
        ("Health & Fitness", [("HEALTH", "Health"), ("FITNESS", "Fitness")]),
        ("Financial Info", [("PAYMENT_INFORMATION", "Payment Info"), ("CREDIT_AND_FINANCIAL_INFO", "Credit Info"), ("OTHER_FINANCIAL_INFO", "Other Financial Info")]),
        ("Location", [("PRECISE_LOCATION", "Precise Location"), ("COARSE_LOCATION", "Coarse Location")]),
        ("Sensitive Info", [("SENSITIVE_INFO", "Sensitive Info")]),
        ("Contacts", [("CONTACTS", "Contacts")]),
        ("User Content", [("EMAILS_OR_TEXT_MESSAGES", "Emails or Text Messages"), ("PHOTOS_OR_VIDEOS", "Photos or Videos"), ("AUDIO", "Audio Data"), ("GAMEPLAY_CONTENT", "Gameplay Content"),
                          ("CUSTOMER_SUPPORT", "Customer Support"), ("OTHER_USER_CONTENT", "Other User Content")]),
        ("Browsing History", [("BROWSING_HISTORY", "Browsing History")]),
        ("Search History", [("SEARCH_HISTORY", "Search History")]),
        ("Identifiers", [("USER_ID", "User ID"), ("DEVICE_ID", "Device ID")]),
        ("Purchases", [("PURCHASE_HISTORY", "Purchase History")]),
        ("Usage Data", [("PRODUCT_INTERACTION", "Product Interaction"), ("ADVERTISING_DATA", "Advertising Data"), ("OTHER_USAGE_DATA", "Other Usage Data")]),
        ("Diagnostics", [("CRASH_DATA", "Crash Data"), ("PERFORMANCE_DATA", "Performance Data"), ("OTHER_DIAGNOSTIC_DATA", "Other Diagnostic Data")]),
        ("Surroundings", [("ENVIRONMENT_SCANNING", "Environment Scanning")]),
        ("Body", [("HANDS", "Hands"), ("HEAD", "Head")]),
        ("Other Data", [("OTHER_DATA_TYPES", "Other Data Types")]),
    ]
    public static func label(_ code: String) -> String { groups.flatMap(\.1).first { $0.0 == code }?.1 ?? purposes.first { $0.0 == code }?.1 ?? code }

    /// Apple's answer rows: one per data type, purpose and protection, or one row saying no data is collected.
    struct Row: Hashable, Sendable { let category: String?, purpose: String?, protection: String }
    var rows: Set<Row> {
        guard collects else { return [Row(category: nil, purpose: nil, protection: Self.notCollected)] }
        var result = Set<Row>()
        for item in items { for purpose in item.purposes {
            result.insert(Row(category: item.category, purpose: purpose, protection: item.linked ? Self.linked : Self.notLinked))
            if item.tracking { result.insert(Row(category: item.category, purpose: purpose, protection: Self.tracking)) }
        } }
        return result
    }
    /// The answers Apple's rows describe; nil when they mix no-data with collected data or name a protection Storebench does not know.
    init?(rows: Set<Row>) {
        if rows.isEmpty { return nil }
        if rows.contains(where: { $0.protection == Self.notCollected }) { guard rows.count == 1 else { return nil }; self.init(collects: false); return }
        var items: [String: Item] = [:]
        for row in rows {
            guard let category = row.category, let purpose = row.purpose, [Self.linked, Self.notLinked, Self.tracking].contains(row.protection) else { return nil }
            var item = items[category] ?? Item(category: category, linked: false)
            if !item.purposes.contains(purpose) { item.purposes.append(purpose) }
            if row.protection == Self.linked { item.linked = true }
            if row.protection == Self.tracking { item.tracking = true }
            items[category] = item
        }
        let order = Self.groups.flatMap(\.1).map(\.0), purposes = Self.purposes.map(\.0)
        self.init(collects: true, items: items.values.map { item in var value = item; value.purposes.sort { (purposes.firstIndex(of: $0) ?? 99) < (purposes.firstIndex(of: $1) ?? 99) }; return value }
            .sorted { (order.firstIndex(of: $0.category) ?? 999, $0.category) < (order.firstIndex(of: $1.category) ?? 999, $1.category) })
    }

    var json: JSONText {
        .object([("collects", .bool(collects)), ("items", .array(items.map { .object([("category", .string($0.category)), ("purposes", .array($0.purposes.map { .string($0) })), ("linked", .bool($0.linked)), ("tracking", .bool($0.tracking))]) }))])
    }
    init?(_ value: JSONText) {
        guard case .bool(let collects)? = value["collects"], case .array(let items)? = value["items"], items.count <= 60 else { return nil }
        self.init(collects: collects, items: items.compactMap { item in
            guard let category = item["category"]?.text, case .array(let purposes)? = item["purposes"] else { return nil }
            return Item(category: category, purposes: purposes.compactMap(\.text), linked: item["linked"] == .bool(true), tracking: item["tracking"] == .bool(true))
        })
        guard self.items.count == items.count else { return nil }
    }
    /// The answers as App Store Connect sums them up, such as Data Not Collected or 2 data types.
    public var summary: String { collects ? "\(items.count) data \(items.count == 1 ? "type" : "types")" : "Data Not Collected" }
    func validated() throws -> Self {
        let codes = Set(Self.groups.flatMap(\.1).map(\.0)), purposes = Set(Self.purposes.map(\.0))
        guard collects ? !items.isEmpty : items.isEmpty else { throw PublishFailure.invalid(collects ? "Choose the data types the app collects." : "Data not collected has no data types.") }
        guard Set(items.map(\.category)).count == items.count, items.allSatisfy({ codes.contains($0.category) && !$0.purposes.isEmpty && Set($0.purposes).count == $0.purposes.count && $0.purposes.allSatisfy(purposes.contains) }) else {
            throw PublishFailure.invalid("Choose at least one purpose for each data type.")
        }
        return self
    }
}

/// App Privacy as App Store Connect has it now: the answers, whether they are published, and the rows behind them.
public struct AppPrivacyState: Sendable, Equatable {
    public let answers: AppPrivacyAnswers?
    public let published: Bool?
    let rows: [(id: String, row: AppPrivacyAnswers.Row)]
    let publishStateId: String?
    public static func == (a: Self, b: Self) -> Bool { a.answers == b.answers && a.published == b.published && a.publishStateId == b.publishStateId && a.rows.map(\.id) == b.rows.map(\.id) }
    var digest: String { Apple.sha(rows.map { "\($0.id):\($0.row.category ?? "-"):\($0.row.purpose ?? "-"):\($0.row.protection)" }.sorted().joined(separator: "\n")) }
}

enum AppPrivacyReads {
    static func state(appId: String, reads: AppleReads) async throws -> AppPrivacyState {
        let page = try await reads.pages("/v1/apps/\(appId)/dataUsages?include=category%2Cpurpose%2CdataProtection&limit=500")
        let rows = try ProductPricing.unique(page.data, "appDataUsages").map { item -> (String, AppPrivacyAnswers.Row) in
            guard let protection = Apple.owner(item, "dataProtection"), protection.type == "appDataUsageDataProtections" else { throw PublishFailure.invalid("Apple returned an App Privacy answer without its protection.") }
            return (item.id, AppPrivacyAnswers.Row(category: Apple.owner(item, "category")?.id, purpose: Apple.owner(item, "purpose")?.id, protection: protection.id))
        }
        var publishedId: String?, published: Bool?
        if let state = try? await reads.get("/v1/apps/\(appId)/dataUsagePublishState").first, state.type == "appDataUsagesPublishState" {
            publishedId = state.id; if case .bool(let flag)? = state.attributes?["published"] { published = flag }
        }
        return AppPrivacyState(answers: AppPrivacyAnswers(rows: Set(rows.map(\.1))), published: published, rows: rows.map { (id: $0.0, row: $0.1) }, publishStateId: publishedId)
    }
}

extension WorkspaceSession {
    static func appleIDKey(_ accountId: String) -> String { "appleid:\(accountId)" }

    /// The Apple ID signed in for this account's App Privacy, if any. The session is kept in the chosen credential storage, like the API key.
    public func appleIDSession(accountId: String, writer: VaultWriter? = nil) throws -> AppleWebSession? {
        guard try accounts().contains(where: { $0.id == accountId }) else { throw AccountFailure.notFound }
        if let route = appleWebTestRoute { return route.session }
        return try credentialCapture(Self.appleIDKey(accountId), writer: writer, allowMissing: true).flatMap(AppleWebSession.init)
    }

    /// Keeps a signed-in Apple ID session for this account, replacing an earlier one.
    public func saveAppleIDSession(_ value: AppleWebSession, accountId: String, writer: VaultWriter) throws {
        guard try accounts().contains(where: { $0.id == accountId }) else { throw AccountFailure.notFound }
        let key = Self.appleIDKey(accountId), previous = try credentialCapture(key, writer: writer, allowMissing: true)
        let text = value.json.stringify()
        guard text.utf8.count <= 10 * 1024 else { throw AppleIDFailure.unreadable }
        acceptCredential(try writer.writeCredential(key, root: root, value: text, expected: previous, expectedVersion: credentialVersions[key], adding: previous == nil), key: key, writer: writer)
    }

    static func appleIDPasswordKey(_ accountId: String) -> String { "appleidpassword:\(accountId)" }

    /// The Apple ID and password saved for this account's sign-in when Save Password is on; nil otherwise.
    /// They live only in the chosen credential storage (Keychain or the password-protected vault), never in the workspace database, backups, logs or URLs.
    public func savedAppleIDPassword(accountId: String, writer: VaultWriter) throws -> (appleId: String, password: String)? {
        guard try accounts().contains(where: { $0.id == accountId }) else { throw AccountFailure.notFound }
        guard let text = try credentialCapture(Self.appleIDPasswordKey(accountId), writer: writer, allowMissing: true), let value = try? JSONText.parse(Data(text.utf8)),
              let appleId = value["appleId"]?.text, let password = value["password"]?.text, !appleId.isEmpty, !password.isEmpty else { return nil }
        return (appleId, password)
    }

    /// Saves the Apple ID and password in the chosen credential storage for the next sign-in, or removes them when `password` is nil.
    public func saveAppleIDPassword(_ password: String?, appleId: String, accountId: String, writer: VaultWriter) throws {
        guard try accounts().contains(where: { $0.id == accountId }) else { throw AccountFailure.notFound }
        let key = Self.appleIDPasswordKey(accountId), previous = try credentialCapture(key, writer: writer, allowMissing: true)
        guard let password else {
            if previous != nil { acceptCredential(try writer.removeCredential(key, root: root, expected: previous, expectedVersion: credentialVersions[key]), key: key, writer: writer) }
            return
        }
        guard !password.isEmpty, password.count <= 512, !appleId.isEmpty, appleId.count <= 200 else { throw AppleIDFailure.rejected }
        let text = JSONText.object([("appleId", .string(appleId)), ("password", .string(password))]).stringify()
        guard text != previous else { return }
        acceptCredential(try writer.writeCredential(key, root: root, value: text, expected: previous, expectedVersion: credentialVersions[key], adding: previous == nil), key: key, writer: writer)
    }

    /// Signs out: removes the stored Apple ID session. A password saved for the next sign-in stays until Save Password is turned off.
    public func signOutAppleID(accountId: String, writer: VaultWriter) throws {
        let key = Self.appleIDKey(accountId), previous = try credentialCapture(key, writer: writer, allowMissing: true)
        guard previous != nil else { return }
        acceptCredential(try writer.removeCredential(key, root: root, expected: previous, expectedVersion: credentialVersions[key]), key: key, writer: writer)
    }

    func appleWebClient(account: Account, appId: String, writer: VaultWriter? = nil) throws -> AppleWebClient {
        guard account.appIds.contains(appId), let session = try appleIDSession(accountId: account.id, writer: writer) else { throw PublishFailure.invalid("Sign in with an Apple ID in App Privacy first. The API key cannot answer App Privacy.") }
        return try AppleWebClient(session: session, appId: appId, configuration: appleWebConfiguration())
    }
    func appleWebConfiguration() -> URLSessionConfiguration { appleWebTestRoute?.configuration() ?? .ephemeral }
    func routeAppleWeb(_ session: AppleWebSession, configuration: @escaping @Sendable () -> URLSessionConfiguration) throws {
        _ = try TestIsolation.require(); appleWebTestRoute = (session, configuration)
    }

    /// App Privacy as App Store Connect has it, read with the signed-in Apple ID. Nothing is written to Apple; whether it is
    /// published is kept on this Mac for Release.
    public func appPrivacyState(account: Account, appId: String, writer: VaultWriter? = nil) async throws -> AppPrivacyState {
        try requireSessionAccess()
        let client = try appleWebClient(account: account, appId: appId, writer: writer)
        let state = try await AppPrivacyReads.state(appId: appId, reads: client.reads)
        if let published = state.published {
            try? recordSectionCheck(.privacy, answered: published, detail: published ? "Published" : state.answers == nil ? "Not answered" : "Not published", summary: state.answers?.summary ?? "Not answered", accountId: account.id, appId: appId)
        }
        return state
    }

    /// Plans App Privacy: removes answer rows that no longer apply and adds the new ones, as Save does; Publish then also publishes them. Read with the signed-in Apple ID.
    func planAppPrivacy(_ planner: Planner, account: Account) async throws -> String {
        guard let answers = planner.request.appPrivacy else { throw PublishFailure.invalid("Choose the App Privacy answers.") }
        let appId = planner.request.appId, client = try appleWebClient(account: account, appId: appId)
        let current = try await AppPrivacyReads.state(appId: appId, reads: client.reads(recording: planner))
        guard let stateId = current.publishStateId else { throw PublishFailure.invalid("Apple did not return App Privacy's publish state. Sign in again with an Account Holder or Admin.") }
        let wanted = answers.rows, existing = Set(current.rows.map(\.row))
        func describe(_ row: AppPrivacyAnswers.Row) -> String {
            row.protection == AppPrivacyAnswers.notCollected ? "Data Not Collected" : "\(AppPrivacyAnswers.label(row.category ?? "")) · \(AppPrivacyAnswers.label(row.purpose ?? "")) · \(row.protection == AppPrivacyAnswers.linked ? "Linked to the user" : row.protection == AppPrivacyAnswers.tracking ? "Used for tracking" : "Not linked to the user")"
        }
        func privacyGuard(_ extra: [(String, JSONText)]) -> JSONText { .object([("kind", .string("app-privacy")), ("digest", .string(current.digest))] + extra) }
        for item in current.rows where !wanted.contains(item.row) {
            planner.add(.api, method: "DELETE", path: [.string("appDataUsages"), .string(item.id)], label: "Remove · \(describe(item.row))", detail: "Remove this answer from App Privacy.", before: describe(item.row), after: "Removed",
                        guard: privacyGuard([("part", .string("remove")), ("row", .string(item.id))]), group: "Answers")
        }
        for row in wanted.sorted(by: { describe($0) < describe($1) }) where !existing.contains(row) {
            var relationships: [(String, JSONText)] = [("app", Apple.relationship("apps", .string(appId))), ("dataProtection", Apple.relationship("appDataUsageDataProtections", .string(row.protection)))]
            if let category = row.category { relationships.append(("category", Apple.relationship("appDataUsageCategories", .string(category)))) }
            if let purpose = row.purpose { relationships.append(("purpose", Apple.relationship("appDataUsagePurposes", .string(purpose)))) }
            planner.add(.api, method: "POST", path: [.string("appDataUsages")], label: "Add · \(describe(row))", detail: "Add this answer to App Privacy.", before: "Not answered", after: describe(row),
                        body: .object([("data", .object([("type", .string("appDataUsages")), ("relationships", .object(relationships))]))]), guard: privacyGuard([("part", .string("add"))]), group: "Answers")
        }
        planner.notes.append("App Privacy uses your Apple ID session, because Apple's API key cannot answer it. The answers apply to the app on the App Store, not only to this version.")
        guard planner.request.appPrivacyPublish == true else {
            if planner.steps.isEmpty { planner.notes.append("App Store Connect already has these answers saved."); return "App Privacy already saved" }
            planner.notes.append("Save keeps the answers in App Store Connect without changing the product page. Publish shows them on the App Store.")
            return "Save App Privacy"
        }
        if planner.steps.isEmpty, current.published == true { planner.notes.append("App Privacy at Apple already has these answers and they are published."); return "App Privacy already published" }
        planner.add(.api, method: "PATCH", path: [.string("appDataUsagesPublishState"), .string(stateId)], label: "Publish App Privacy", detail: "Publish the answers on the App Store product page.",
                    before: current.published == true ? "Published" : "Not published", after: "Published",
                    body: .object([("data", .object([("type", .string("appDataUsagesPublishState")), ("id", .string(stateId)), ("attributes", .object([("published", .bool(true))]))]))]),
                    guard: privacyGuard([("part", .string("publish")), ("wanted", .string(Apple.sha(wanted.map { "\($0.category ?? "-"):\($0.purpose ?? "-"):\($0.protection)" }.sorted().joined(separator: "\n"))))]))
        return "Publish App Privacy"
    }

    /// App Privacy write check with fresh reads: only this app's rows, each change still needed, and the reviewed answers before publishing.
    func verifyAppPrivacyWrite(method: String, parts: [String], body: JSONText?, guardValue: JSONText?, account: Account, appId: String) async throws {
        let client = try appleWebClient(account: account, appId: appId), current = try await AppPrivacyReads.state(appId: appId, reads: client.reads)
        func refuse() -> PublishFailure { .write("Unsupported App Privacy change.") }
        func changed() -> PublishFailure { .write("App Privacy changed at Apple after approval. Prepare a new review.") }
        let data = body?["data"]
        switch guardValue?["part"]?.text {
        case "remove":
            guard method == "DELETE", parts.count == 2, parts[0] == "appDataUsages", body == nil, guardValue?["row"]?.text == parts[1] else { throw refuse() }
            guard current.rows.contains(where: { $0.id == parts[1] }) else { throw changed() }
        case "add":
            guard method == "POST", parts == ["appDataUsages"], data?["type"]?.text == "appDataUsages", data?["attributes"] == nil,
                  data?["relationships"]?["app"]?["data"]?["id"]?.text == appId, case .object(let links)? = data?["relationships"], Set(links.map(\.0)).isSubset(of: ["app", "dataProtection", "category", "purpose"]),
                  let protection = data?["relationships"]?["dataProtection"]?["data"]?["id"]?.text else { throw refuse() }
            let row = AppPrivacyAnswers.Row(category: data?["relationships"]?["category"]?["data"]?["id"]?.text, purpose: data?["relationships"]?["purpose"]?["data"]?["id"]?.text, protection: protection)
            guard !current.rows.contains(where: { $0.row == row }) else { throw changed() }
        case "publish":
            guard method == "PATCH", parts.count == 2, parts[0] == "appDataUsagesPublishState", parts[1] == current.publishStateId, data?["id"]?.text == parts[1], data?["attributes"]?["published"] == .bool(true) else { throw refuse() }
            let rows = Set(current.rows.map(\.row)).map { "\($0.category ?? "-"):\($0.purpose ?? "-"):\($0.protection)" }.sorted().joined(separator: "\n")
            guard Apple.sha(rows) == guardValue?["wanted"]?.text else { throw changed() }
        default: throw refuse()
        }
    }
}

/// The Privacy Policy links App Store Connect shows on App Privacy: the primary language of the app information being prepared.
public struct PrivacyPolicyLinks: Sendable, Equatable {
    public let locale: String, policyUrl: String, choicesUrl: String
}

extension WorkspaceSession {
    /// Reads the Privacy Policy URL and User Privacy Choices URL with the API key. Nothing is written; nil when Apple has no app information yet.
    /// The Privacy Policy links from answers warmed earlier in this session.
    public func privacyPolicyLinks(account: Account, appId: String) async throws -> PrivacyPolicyLinks? {
        let client = try readClient(for: account)
        return try await AppStoreReadCache.rereadingAfterInvalidation { try await privacyPolicyLinks(account: account, appId: appId, client: client) }
    }
    public func privacyPolicyLinks(account: Account, appId: String, client: AppStoreConnectClient) async throws -> PrivacyPolicyLinks? {
        try requirePublishingAccount(account, appId: appId, client: client)
        let reads = AppleReads(client)
        guard let primary = try await reads.get("/v1/apps/\(appId)").first?.attributes?["primaryLocale"]?.string else { return nil }
        let infos = try await reads.list("/v1/apps/\(appId)/appInfos?limit=20").filter { $0.type == "appInfos" && Apple.within($0, "app", "apps", appId) }
        let live = ["READY_FOR_DISTRIBUTION", "REPLACED_WITH_NEW_INFO"]
        guard let info = infos.first(where: { !live.contains($0.attributes?["state"]?.string ?? "") }) ?? infos.first else { return nil }
        let localizations = try await reads.list("/v1/appInfos/\(info.id)/appInfoLocalizations?limit=200").filter { $0.type == "appInfoLocalizations" }
        guard let item = localizations.first(where: { $0.attributes?["locale"]?.string == primary }) else { return PrivacyPolicyLinks(locale: primary, policyUrl: "", choicesUrl: "") }
        return PrivacyPolicyLinks(locale: primary, policyUrl: item.attributes?["privacyPolicyUrl"]?.string ?? "", choicesUrl: item.attributes?["privacyChoicesUrl"]?.string ?? "")
    }
}
