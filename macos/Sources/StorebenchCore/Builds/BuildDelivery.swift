import Foundation

public struct BuildDelivery: Sendable, Identifiable, Codable {
    public struct Detail: Sendable, Codable { public let kind, code, description: String }
    public let id, version, buildNumber, platform, state: String
    public let createdDate, uploadedDate, buildId: String?
    public let deletable: Bool
    public let details: [Detail]
    public let omittedDetails: Int

    static func state(_ resource: AppStoreConnectClient.Resource) throws -> [String: JSONValue]? {
        guard let value = resource.attributes?["state"], value != .null else { return nil }
        guard case .object(let state) = value else { throw PublishFailure.invalid("Unexpected Apple build upload state.") }
        return state
    }
    static func removable(_ resource: AppStoreConnectClient.Resource, failedOnly: Bool = false) throws -> Bool {
        guard resource.type == "buildUploads" else { return false }
        let state = try state(resource)?["state"]?.string ?? ""
        guard failedOnly ? state == "FAILED" : ["FAILED", "AWAITING_UPLOAD"].contains(state) else { return false }
        if let value = resource.relationships?["build"] {
            guard case .object(let relationship) = value else { throw PublishFailure.invalid("Unexpected Apple build relationship.") }
            if let data = relationship["data"] { return data == .null }
        }
        return true
    }
    static func removableDigest(_ resource: AppStoreConnectClient.Resource) throws -> String {
        guard try removable(resource) else { throw PublishFailure.invalid("Build upload is no longer removable.") }
        let attributes = Planner.resource(resource)["attributes"]
        return JSONText.array([.string(resource.id), attributes?["cfBundleShortVersionString"] ?? .null,
                               attributes?["cfBundleVersion"] ?? .null, attributes?["platform"] ?? .null,
                               try state(resource)?["state"]?.string.map(JSONText.string) ?? .null]).sha256
    }
    public static func summary(_ resource: AppStoreConnectClient.Resource) throws -> BuildDelivery {
        try summary(resource, plain: ISO8601DateFormatter(), fractional: ISO8601DateFormatter.storebench)
    }
    /// Date parsers belong to one batch, avoiding repeated formatter setup without sharing mutable state.
    public static func summaries(_ resources: [AppStoreConnectClient.Resource]) throws -> [BuildDelivery] {
        let plain = ISO8601DateFormatter(), fractional = ISO8601DateFormatter.storebench
        return try resources.map { try summary($0, plain: plain, fractional: fractional) }
    }
    private static func summary(_ resource: AppStoreConnectClient.Resource, plain: ISO8601DateFormatter, fractional: ISO8601DateFormatter) throws -> BuildDelivery {
        guard resource.type == "buildUploads" else { throw PublishFailure.invalid("Unexpected Apple build upload resource.") }
        let raw = try state(resource)
        func label(_ text: JSONValue?, _ fallback: String, _ maximum: Int = 200) -> String {
            guard let text = text?.string, !TextSemantics.trim(text).isEmpty else { return fallback }
            return String(decoding: text.utf16.prefix(maximum), as: UTF16.self)
        }
        func timestamp(_ text: JSONValue?) -> String? {
            guard let text = text?.string, (fractional.date(from: text) ?? plain.date(from: text)) != nil else { return nil }; return text
        }
        var details: [Detail] = [], omitted = 0
        for (key, kind) in [("errors", "Error"), ("warnings", "Warning"), ("infos", "Info")] {
            if let value = raw?[key] {
                guard case .array(let entries) = value, entries.count <= 100 else { throw PublishFailure.invalid("Unexpected Apple build upload details.") }
                for entry in entries {
                    guard case .object(let fields) = entry, fields["code"] == nil || fields["code"]?.string != nil, fields["description"] == nil || fields["description"]?.string != nil else { throw PublishFailure.invalid("Unexpected Apple build upload detail.") }
                    if details.count < 20 { details.append(Detail(kind: kind, code: label(fields["code"], ""), description: label(fields["description"], "No description from Apple", 2000))) }
                    else { omitted += 1 }
                }
            }
        }
        let states = ["AWAITING_UPLOAD": "Awaiting files", "PROCESSING": "Processing", "FAILED": "Failed", "COMPLETE": "Complete"]
        return BuildDelivery(id: resource.id, version: label(resource.attributes?["cfBundleShortVersionString"], "Version unavailable"), buildNumber: label(resource.attributes?["cfBundleVersion"], "Build number unavailable"),
                             platform: label(resource.attributes?["platform"], "Platform unavailable"), state: raw?["state"]?.string.map { states[$0] ?? "Other Apple state" } ?? "State unavailable",
                             createdDate: timestamp(resource.attributes?["createdDate"]), uploadedDate: timestamp(resource.attributes?["uploadedDate"]), buildId: Apple.owner(resource, "build").flatMap { $0.type == "builds" ? $0.id : nil },
                             deletable: try removable(resource), details: details, omittedDetails: omitted)
    }
    var json: JSONText { .object([("id", .string(id)), ("version", .string(version)), ("buildNumber", .string(buildNumber)), ("platform", .string(platform)), ("state", .string(state)),
                                 ("createdDate", createdDate.map(JSONText.string) ?? .null), ("uploadedDate", uploadedDate.map(JSONText.string) ?? .null), ("buildId", buildId.map(JSONText.string) ?? .null),
                                 ("deletable", .bool(deletable)), ("details", .array(details.map { .object([("kind", .string($0.kind)), ("code", .string($0.code)), ("description", .string($0.description))]) })), ("omittedDetails", .number(Double(omittedDetails)))]) }
    static func digest(appId: String, version: String, number: String, platform: String, package: StagedBuildPackage) throws -> String {
        try digest(appId: appId, version: version, number: number, platform: platform, fileName: package.fileName, fileSize: package.size, uti: package.uti, checksum: package.sha256)
    }
    static func digest(appId: String, version: String, number: String, platform: String, fileName: String, fileSize: Int, uti: String, checksum: String) throws -> String {
        guard !appId.isEmpty, version.range(of: "^[0-9]+(?:\\.[0-9]+){0,2}$", options: .regularExpression) != nil, number.range(of: "^[0-9]+(?:\\.[0-9]+){0,2}$", options: .regularExpression) != nil,
              ["IOS", "MAC_OS", "TV_OS", "VISION_OS"].contains(platform), uti == (platform == "MAC_OS" ? "com.apple.pkg" : "com.apple.ipa"), try StagedBuildPackage.type(fileName) == uti,
              fileSize >= 4, fileSize <= StagedBuildPackage.maximumBytes, checksum.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw PublishFailure.invalid("Choose the version, build number and platform matching the staged package.") }
        return JSONText.object([("appId", .string(appId)), ("version", .string(version)), ("number", .string(number)), ("platform", .string(platform)), ("fileName", .string(fileName)),
                                ("fileSize", .number(Double(fileSize))), ("uti", .string(uti)), ("checksum", .string(checksum))]).sha256
    }
}

extension WorkspaceSession {
    /// BuildUpload omits an app owner. The explicit app relationship must confirm the complete ID set.
    func appBuildUploads(appId: String, client: AppStoreConnectClient, planner: Planner? = nil) async throws -> [AppStoreConnectClient.Resource] {
        guard client.token.account.appIds.contains(appId) else { throw PublishFailure.invalid("App is not configured for this account.") }
        let path = "/v1/apps/\(appId)/buildUploads?limit=200", relationship = "/v1/apps/\(appId)/relationships/buildUploads?limit=200"
        let items = planner != nil ? try await planner!.list(path) : try await client.list(path)
        let linked = planner != nil ? try await planner!.list(relationship) : try await client.list(relationship)
        func ids(_ values: [AppStoreConnectClient.Resource]) throws -> Set<String> {
            guard values.allSatisfy({ $0.type == "buildUploads" && !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }), Set(values.map(\.id)).count == values.count else { throw PublishFailure.invalid("Apple returned unexpected build upload records.") }
            return Set(values.map(\.id))
        }
        guard try ids(items) == ids(linked) else { throw PublishFailure.invalid("Apple returned build uploads outside the selected app or an incomplete list.") }
        return items
    }
    public func buildDeliveries(appId: String, client: AppStoreConnectClient) async throws -> [BuildDelivery] {
        try BuildDelivery.summaries(await appBuildUploads(appId: appId, client: client))
    }
}
