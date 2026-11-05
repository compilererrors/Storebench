import Foundation

/// Immutable app material uses the imported baseline; editing overlays remain separate.
public enum AppOverviewMaterial {
    public static let pageSize = 5
    public struct Information: Sendable, Codable {
        public let locale, name, subtitle: String
    }
    public struct Snapshot: Sendable, Codable {
        public let accountId, appId: String
        public let history: [ArchivedRevision], latest: ArchivedRevision?, plan: ReleasePlan?
        public let information: [Information]
        public init(accountId: String, appId: String, history: [ArchivedRevision], plan: ReleasePlan?) throws {
            _ = try RecoveryGuidance.Scope(accountId: accountId, appId: appId)
            guard history.allSatisfy({ $0.value["account"]?["id"]?.text == accountId && $0.value["app"]?["id"]?.text == appId }),
                  plan.map({ $0.accountId == accountId && $0.appId == appId }) ?? true else { throw RevisionHistoryFailure.invalid }
            self.accountId = accountId; self.appId = appId; self.history = history; self.plan = plan
            latest = history.first { !$0.local } ?? history.first
            var rows: [Information] = []
            if let latest {
                for info in try array(latest.value["appInfos"]) {
                    for locale in try array(info["localizations"]) {
                        let fields = try fieldObject(locale["fields"])
                        rows.append(try .init(locale: text(fields["locale"]), name: text(fields["name"]), subtitle: text(fields["subtitle"])))
                    }
                }
            }
            information = rows
        }
        public func name(configured: String?) -> String { ConnectedApps.name(saved: latest?.value["app"]?["name"]?.text, configured: configured, appId: appId) }
        public var bundleId: String { latest?.value["app"]?["bundleId"]?.text ?? "" }
        public var primaryLocale: String { latest?.value["app"]?["primaryLocale"]?.text ?? "" }
    }
    public struct Summary: Identifiable, Sendable {
        public let id, platform, number, state: String
        public let languages: Int
        public var json: JSONText { .object([("id", .string(id)), ("platform", .string(platform)), ("number", .string(number)), ("state", .string(state)), ("languages", .number(Double(languages)))]) }
    }
    public static func summaries(_ revision: ArchivedRevision) throws -> [Summary] {
        let initial = try Page(revision); try initial.validateReceipt()
        let result = try array(revision.value["versions"]).map { version in
            let fields = try fieldObject(version["fields"])
            return try Summary(id: required(version["id"]), platform: truthyText(fields["platform"]), number: truthyText(fields["versionString"]),
                state: revision.local ? "Saved locally" : AppStoreNames.primaryState(truthyText(truthy(fields["appVersionState"]) ? fields["appVersionState"] : fields["appStoreState"])),
                languages: array(version["localizations"]).count)
        }
        guard Set(result.map(\.id)).count == result.count, result.allSatisfy({ identifier($0.id) && [$0.platform, $0.number, $0.state].allSatisfy { $0.utf16.count <= 200 } }) else { throw RevisionHistoryFailure.invalid }
        return result
    }
    public struct Page: Sendable {
        public let accountId, appId, revisionId: String
        public let documentRevision, page, pages, total: Int
        public let local: Bool, versions: [Summary]
        public init(_ revision: ArchivedRevision, requested: Double = 1) throws {
            accountId = try required(revision.value["account"]?["id"]); appId = try required(revision.value["app"]?["id"])
            revisionId = revision.id; documentRevision = revision.documentRevision; let isLocal = revision.local; local = isLocal
            let values = try array(revision.value["versions"])
            total = values.count; pages = max(1, (total + pageSize - 1) / pageSize)
            let chosen = requested.isFinite && requested.rounded() == requested && abs(requested) <= 9_007_199_254_740_991 ? requested : 1
            page = Int(min(Double(pages), max(1, chosen)))
            versions = try values.dropFirst((page - 1) * pageSize).prefix(pageSize).map { version in
                let fields = try fieldObject(version["fields"])
                return try Summary(id: required(version["id"]), platform: truthyText(fields["platform"]), number: truthyText(fields["versionString"]),
                                   state: isLocal ? "Saved locally" : AppStoreNames.primaryState(truthyText(truthy(fields["appVersionState"]) ? fields["appVersionState"] : fields["appStoreState"])),
                                   languages: array(version["localizations"]).count)
            }
        }
        public var json: JSONText { .object([("accountId", .string(accountId)), ("appId", .string(appId)), ("revisionId", .string(revisionId)), ("page", .number(Double(page))), ("pages", .number(Double(pages))), ("total", .number(Double(total))), ("local", .bool(local)), ("versions", .array(versions.map(\.json)))]) }
        public func validateReceipt() throws {
            guard documentRevision > 0, Set(versions.map(\.id)).count == versions.count,
                  versions.allSatisfy({ identifier($0.id) && [$0.platform, $0.number, $0.state].allSatisfy { $0.utf16.count <= 200 } }) else { throw RevisionHistoryFailure.invalid }
        }
    }
    public struct TextField: Sendable { public let key, label, value: String }
    public struct ScreenshotGroup: Sendable { public let displayType: String; public let screenshots: [LibraryChooser.Shot] }
    public struct Language: Sendable {
        public let id, label: String
        public let fields: [TextField], screenshotSets: [ScreenshotGroup]
    }
    public struct Detail: Sendable {
        public let revisionId, versionId: String
        public let documentRevision: Int
        public let value: JSONText, languages: [Language]
        public init(_ revision: ArchivedRevision, versionId: String) throws {
            guard identifier(versionId), let value = try array(revision.value["versions"]).first(where: { $0["id"]?.text == versionId }) else { throw RevisionHistoryFailure.missing }
            try validateVersion(value, id: versionId)
            self.value = value; self.versionId = versionId; revisionId = revision.id; documentRevision = revision.documentRevision
            let shots = try LibraryChooser.images(revision)
            var offset = 0
            for version in try array(revision.value["versions"]) {
                if version["id"]?.text == versionId { break }
                for locale in try array(version["localizations"]) { for set in try array(locale["screenshotSets"]) { offset += try array(set["screenshots"]).count } }
            }
            var rows: [Language] = []
            for locale in try array(value["localizations"]) {
                let fields = try fieldObject(locale["fields"]), label = try truthyText(fields["locale"], fallback: "Saved language")
                var sets: [ScreenshotGroup] = []
                for set in try array(locale["screenshotSets"]) {
                    let count = try array(set["screenshots"]).count
                    guard offset + count <= shots.count else { throw RevisionHistoryFailure.invalid }
                    sets.append(.init(displayType: try required(set["displayType"]), screenshots: Array(shots[offset..<offset + count]))); offset += count
                }
                let text = try textFields.compactMap { key, title -> TextField? in
                    guard truthy(fields[key]) else { return nil }; return try .init(key: key, label: title, value: AppOverviewMaterial.text(fields[key]))
                }
                rows.append(try .init(id: required(locale["id"]), label: label, fields: text, screenshotSets: sets))
            }
            languages = rows
        }
    }
    public static let textFields = [("description", "Description"), ("keywords", "Keywords"), ("promotionalText", "Promotional text"), ("whatsNew", "What’s new"), ("supportUrl", "Support URL"), ("marketingUrl", "Marketing URL")]
    static func identifier(_ value: String) -> Bool { value.range(of: #"\A[A-Za-z0-9_-]{1,256}\z"#, options: .regularExpression) != nil }
    static func array(_ value: JSONText?) throws -> [JSONText] { guard case .array(let values)? = value else { throw RevisionHistoryFailure.invalid }; return values }
    static func required(_ value: JSONText?) throws -> String { guard let value = value?.text else { throw RevisionHistoryFailure.invalid }; return value }
    static func fieldObject(_ value: JSONText?) throws -> JSONText {
        guard let value, case .object(let fields) = value else { throw RevisionHistoryFailure.invalid }
        for (_, field) in fields { _ = try text(field) }; return value
    }
    static func text(_ value: JSONText?) throws -> String { try value.map(RevisionComparison.text) ?? "" }
    static func truthy(_ value: JSONText?) -> Bool { value != nil && value != .null && value != .string("") && value != .number(0) }
    static func truthyText(_ value: JSONText?, fallback: String = "") throws -> String { if truthy(value) { return try text(value) }; return fallback }
    public static func validateVersion(_ version: JSONText, id: String) throws {
        guard version["id"]?.text == id else { throw RevisionHistoryFailure.invalid }; _ = try fieldObject(version["fields"])
        for locale in try array(version["localizations"]) {
            guard identifier(try required(locale["id"])) else { throw RevisionHistoryFailure.invalid }; _ = try fieldObject(locale["fields"])
            for set in try array(locale["screenshotSets"]) {
                guard identifier(try required(set["id"])) else { throw RevisionHistoryFailure.invalid }; _ = try required(set["displayType"])
                for image in try array(set["screenshots"]) {
                    guard identifier(try required(image["id"])), (try required(image["sha256"])).range(of: #"\A[a-f0-9]{64}\z"#, options: .regularExpression) != nil,
                          image["contentType"] == .string("image/png") || image["contentType"] == .string("image/jpeg") else { throw RevisionHistoryFailure.invalid }
                    _ = try required(image["fileName"])
                    for field in ["width", "height"] { if let raw = image[field] { guard case .number(let value) = raw, value >= 1, value <= 9_007_199_254_740_991, value.rounded() == value else { throw RevisionHistoryFailure.invalid } } }
                }
            }
        }
    }
}

extension WorkspaceSession {
    public func appOverviewMaterial(accountId: String, appId: String) throws -> AppOverviewMaterial.Snapshot {
        try requireHistoryScope(accountId: accountId, appId: appId); try Task.checkCancellation()
        let history = try connectedAppHistory(accountId: accountId, appId: appId), plan = try releasePlan(accountId: accountId, appId: appId)
        let result = try AppOverviewMaterial.Snapshot(accountId: accountId, appId: appId, history: history, plan: plan)
        try requireHistoryScope(accountId: accountId, appId: appId); try requireSessionAccess(); try Task.checkCancellation(); return result
    }
    public func savedVersionPage(accountId: String, appId: String, revisionId: String, documentRevision: Int, page: Int) throws -> AppOverviewMaterial.Page {
        let source = try overviewArchive(accountId: accountId, appId: appId, revisionId: revisionId, documentRevision: documentRevision)
        let result = try AppOverviewMaterial.Page(source, requested: Double(page)); try result.validateReceipt()
        try requireHistoryScope(accountId: accountId, appId: appId); try requireSessionAccess(); try Task.checkCancellation(); return result
    }
    public func savedVersionDetail(accountId: String, appId: String, revisionId: String, documentRevision: Int, versionId: String) throws -> AppOverviewMaterial.Detail {
        let source = try overviewArchive(accountId: accountId, appId: appId, revisionId: revisionId, documentRevision: documentRevision)
        let result = try AppOverviewMaterial.Detail(source, versionId: versionId)
        try requireHistoryScope(accountId: accountId, appId: appId); try requireSessionAccess(); try Task.checkCancellation(); return result
    }
    private func overviewArchive(accountId: String, appId: String, revisionId: String, documentRevision: Int) throws -> ArchivedRevision {
        try requireHistoryScope(accountId: accountId, appId: appId); try Task.checkCancellation()
        let source = try storeAccess { try archivedRevision(accountId: accountId, appId: appId, id: revisionId, store: $0) }
        guard documentRevision > 0, source.documentRevision == documentRevision else { throw RevisionHistoryFailure.stale }; return source
    }
}
