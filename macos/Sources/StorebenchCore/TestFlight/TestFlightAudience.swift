import Foundation

/// The exact group and direct audience reviewed for build expiry and manual notifications.
public enum TestFlightAudience {
    public typealias Resource = AppStoreConnectClient.Resource
    public struct Membership: Codable, Sendable {
        public let group: Resource, testers: [Resource]
        public init(group: Resource, testers: [Resource]) { self.group = group; self.testers = testers }
    }
    public struct Review: Sendable {
        public let before, digest: String
        public let uniqueAssignedTesters: Int
    }
    static func ordered<T>(_ values: [T], id: (T) -> String) -> [T] {
        values.enumerated().sorted { a, b in
            let order = id(a.element).compare(id(b.element), locale: Locale(identifier: "en"))
            return order == .orderedSame ? a.offset < b.offset : order == .orderedAscending
        }.map(\.element)
    }
    static func identities(_ testers: [Resource], appId: String) throws -> [JSONText] {
        guard testers.allSatisfy({ $0.type == "betaTesters" && !TextSemantics.trim($0.id).isEmpty }), Set(testers.map { Data($0.id.utf8) }).count == testers.count else { throw PublishFailure.invalid("Apple returned unexpected TestFlight testers.") }
        return try ordered(testers, id: { $0.id }).map { tester in
            guard case .array(let apps)? = Planner.resource(tester)["relationships"]?["apps"]?["data"],
                  apps.allSatisfy({ $0["type"]?.text == "apps" && !TextSemantics.trim($0["id"]?.text ?? "").isEmpty }),
                  Set(apps.compactMap { $0["id"]?.text.map { Data($0.utf8) } }).count == apps.count, apps.contains(where: { $0["id"]?.text == appId }),
                  tester.attributes?["email"] == nil || tester.attributes?["email"]?.string != nil else { throw PublishFailure.invalid("Apple returned build testers outside the selected app.") }
            return .object([("id", .string(tester.id)), ("email", tester.attributes?["email"]?.string.map(JSONText.string) ?? .null)])
        }
    }
    public static func review(appId: String, build: Resource, memberships: [Membership], direct: [Resource]) throws -> Review {
        guard build.type == "builds", !build.id.isEmpty, Apple.owned(build, "app", "apps", appId), let version = build.attributes?["version"]?.string,
              case .bool(let expired)? = build.attributes?["expired"] else { throw PublishFailure.invalid("Apple did not confirm the selected TestFlight build.") }
        guard memberships.allSatisfy({ $0.group.type == "betaGroups" && !TextSemantics.trim($0.group.id).isEmpty && Apple.owned($0.group, "app", "apps", appId) && $0.group.attributes?["name"]?.string != nil }),
              Set(memberships.map { Data($0.group.id.utf8) }).count == memberships.count else { throw PublishFailure.invalid("Apple returned testing groups outside the selected app or without names.") }
        let groups = try ordered(memberships, id: { $0.group.id }).map { item in
            JSONText.object([("id", .string(item.group.id)), ("name", .string(item.group.attributes!["name"]!.string!)), ("testers", .array(try identities(item.testers, appId: appId)))])
        }
        let direct = try identities(direct, appId: appId)
        var ids = Set<Data>()
        for group in groups { if case .array(let testers)? = group["testers"] { for tester in testers { ids.insert(Data(tester["id"]!.text!.utf8)) } } }
        for tester in direct { ids.insert(Data(tester["id"]!.text!.utf8)) }
        let names = groups.map { group -> String in
            let count: Int; if case .array(let testers)? = group["testers"] { count = testers.count } else { count = 0 }
            return "\(group["name"]!.text!) · \(group["id"]!.text!) · \(count) \(count == 1 ? "tester" : "testers")"
        }
        let visible = direct.prefix(25).map { tester -> String in let id = tester["id"]!.text!, email = tester["email"]?.text; return "\(email?.isEmpty == false ? email! : id) · \(id)" }
        let before = (["Build \(version) · \(build.id)", "", "Testing groups (\(groups.count)):"] + (names.isEmpty ? ["None"] : names) + ["", "Direct assignments (\(direct.count)):"]
                      + (visible.isEmpty ? ["None"] : visible) + (direct.count > 25 ? ["\(direct.count - 25) more direct assignments are checked before the Apple request."] : []) + ["", "Unique assigned testers: \(ids.count)."])
            .joined(separator: "\n")
        let digest = JSONText.object([("appId", .string(appId)), ("buildId", .string(build.id)), ("version", .string(version)), ("expired", .bool(expired)), ("memberships", .array(groups)), ("direct", .array(direct))]).sha256
        return Review(before: before, digest: digest, uniqueAssignedTesters: ids.count)
    }
}

extension WorkspaceSession {
    func buildAudience(_ build: AppStoreConnectClient.Resource, appId: String, client: AppStoreConnectClient, planner: Planner? = nil) async throws -> TestFlightAudience.Review {
        _ = try TestFlightAudience.review(appId: appId, build: build, memberships: [], direct: [])
        let list = { (path: String) in planner != nil ? try await planner!.list(path) : try await client.list(path) }
        var query = URLComponents(); query.queryItems = [URLQueryItem(name: "filter[app]", value: appId), URLQueryItem(name: "filter[builds]", value: build.id), URLQueryItem(name: "limit", value: "200")]
        let groups = try await scopedOwners(list("/v1/betaGroups?\(query.percentEncodedQuery!)"), type: "betaGroups", appId: appId, list: list)
        guard groups.allSatisfy({ $0.attributes?["name"]?.string != nil }) else { throw PublishFailure.invalid("Apple returned testing groups without names.") }
        var memberships: [TestFlightAudience.Membership] = []
        for group in groups {
            let testers = try await scopedTesters(list("/v1/betaGroups/\(TextSemantics.pathComponent(group.id))/betaTesters?limit=200"), appId: appId, list: list)
            memberships.append(TestFlightAudience.Membership(group: group, testers: testers))
        }
        let direct = try await scopedTesters(list("/v1/builds/\(TextSemantics.pathComponent(build.id))/individualTesters?limit=200"), appId: appId, list: list)
        return try TestFlightAudience.review(appId: appId, build: build, memberships: memberships, direct: direct)
    }
    func planBuildAudience(_ planner: Planner) async throws -> String? {
        let request = planner.request, notifying = request.testflightAction == "notify-build-testers"
        guard notifying || request.testflightAction == "expire-build" else { return nil }
        guard let build = try await appBuilds(appId: request.appId, client: planner.client, planner: planner).first(where: { $0.id == request.buildId }) else { throw PublishFailure.invalid("Choose a build belonging to this app.") }
        let version = build.attributes?["version"]?.string ?? build.id
        if notifying {
            guard TestFlightAccess.canNotify(build, try await checkedBetaDetail(build, client: planner.client), verifiedAssociation: true) else { throw PublishFailure.invalid("Choose an unexpired build ready for manual external tester notification.") }
        } else {
            guard case .bool(let expired)? = build.attributes?["expired"] else { throw PublishFailure.invalid("Apple did not confirm this build's expiry status. Refresh before expiring it.") }
            if expired { planner.notes.append("This build is already expired; there is no change to publish."); return "Expire build \(version)" }
        }
        let audience = try await buildAudience(build, appId: request.appId, client: planner.client, planner: planner)
        let body: JSONText = notifying ? .object([("data", .object([("type", .string("buildBetaNotifications")), ("relationships", .object([("build", Apple.relationship("builds", .string(build.id)))]))]))])
            : .object([("data", .object([("type", .string("builds")), ("id", .string(build.id)), ("attributes", .object([("expired", .bool(true))]))]))])
        planner.add(.api, method: notifying ? "POST" : "PATCH", path: notifying ? [.string("buildBetaNotifications")] : [.string("builds"), .string(build.id)],
                    label: notifying ? "Notify TestFlight build testers" : "Expire TestFlight build", detail: notifying ? "Build \(version) · all eligible assigned testers" : "Build \(version) · testers will lose access",
                    before: (notifying ? "Manual notification pending" : "Available until its Apple expiration date") + "\n\n" + audience.before,
                    after: notifying ? "Notification requested from Apple" : "Expired for all testing groups and testers", body: body,
                    guard: .object([("kind", .string(notifying ? "build-notification-audience" : "build-expiry-audience")), ("digest", .string(audience.digest)), ("buildId", .string(build.id))]))
        planner.notes.append(notifying ? "Apple notifies all eligible testers assigned to this build. Delivery and tester acceptance are controlled by Apple; refresh TestFlight to confirm the build's state." : "Expiring a build stops testing for every group and tester. Apple does not offer an undo action for this build.")
        return notifying ? "Notify testers · build \(version)" : "Expire build \(version)"
    }
    func verifyBuildAudience(method: String, parts: [String], body: JSONText?, guardValue: JSONText?, appId: String, client: AppStoreConnectClient) async throws {
        func keys(_ value: JSONText?, _ expected: Set<String>) -> Bool { guard case .object(let fields)? = value else { return false }; return fields.count == expected.count && Set(fields.map(\.0)) == expected }
        let data = body?["data"]
        guard keys(body, ["data"]), let buildId = guardValue?["buildId"]?.text, buildId.range(of: "^[A-Za-z0-9_-]{1,256}$", options: .regularExpression) != nil,
              let digest = guardValue?["digest"]?.text, digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { throw PublishFailure.write("Unsupported TestFlight build audience guard.") }
        let notifying = guardValue?["kind"]?.text == "build-notification-audience"
        if notifying {
            guard method == "POST", parts == ["buildBetaNotifications"], keys(data, ["type", "relationships"]), data?["type"]?.text == "buildBetaNotifications",
                  data?["relationships"] == .object([("build", Apple.relationship("builds", .string(buildId)))]) else { throw PublishFailure.write("Unsupported TestFlight build notification request.") }
        } else {
            guard guardValue?["kind"]?.text == "build-expiry-audience", method == "PATCH", parts == ["builds", buildId], keys(data, ["type", "id", "attributes"]),
                  data?["type"]?.text == "builds", data?["id"]?.text == buildId, data?["attributes"] == .object([("expired", .bool(true))]) else { throw PublishFailure.write("Unsupported TestFlight build expiry request.") }
        }
        guard let build = try await appBuilds(appId: appId, client: client).first(where: { $0.id == buildId }) else { throw PublishFailure.write("TestFlight build no longer belongs to this app.") }
        if notifying {
            guard TestFlightAccess.canNotify(build, try await checkedBetaDetail(build, client: client), verifiedAssociation: true) else { throw PublishFailure.write("TestFlight build is no longer ready for manual notification.") }
        } else { guard build.attributes?["expired"] == .bool(false) else { throw PublishFailure.write("Build expiry status changed or could not be confirmed.") } }
        guard try await buildAudience(build, appId: appId, client: client).digest == digest else { throw PublishFailure.write("The TestFlight build audience changed after review. Prepare a new review.") }
    }
}
