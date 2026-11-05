import Foundation

/// Build access and automatic notification snapshots used by the publishing guard.
public enum TestFlightAccess {
    public typealias Resource = AppStoreConnectClient.Resource
    static func attribute(_ resource: Resource, _ key: String) -> JSONText { Planner.resource(resource)["attributes"]?[key] ?? .null }
    static func validEmail(_ email: String) -> Bool {
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        return email.utf16.count <= 254 && parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty
            && !email.unicodeScalars.contains(where: TextSemantics.whitespace.contains) && parts[1].utf8.dropFirst().dropLast().contains(46)
    }
    public static func individualDigest(_ build: Resource, testers: [Resource], testerId: String) throws -> String {
        guard build.type == "builds", !build.id.isEmpty, !testerId.isEmpty, testers.allSatisfy({ $0.type == "betaTesters" }), testers.filter({ $0.id == testerId }).count <= 1 else {
            throw PublishFailure.invalid("Apple did not confirm this TestFlight build access.")
        }
        return JSONText.object([("buildId", .string(build.id)), ("version", attribute(build, "version")), ("processingState", attribute(build, "processingState")),
                                ("expired", attribute(build, "expired")), ("audience", attribute(build, "buildAudienceType")), ("testerId", .string(testerId)),
                                ("present", .bool(testers.contains { $0.id == testerId }))]).sha256
    }
    public static func creationDigest(_ build: Resource, appId: String) throws -> String {
        guard build.type == "builds", !build.id.isEmpty, Apple.owned(build, "app", "apps", appId), let version = build.attributes?["version"]?.string, !TextSemantics.trim(version).isEmpty,
              build.attributes?["processingState"]?.string != nil, case .bool? = build.attributes?["expired"], build.attributes?["buildAudienceType"]?.string != nil else {
            throw PublishFailure.invalid("Apple did not confirm this individual TestFlight build.")
        }
        return JSONText.object([("appId", .string(appId)), ("buildId", .string(build.id)), ("version", .string(version)), ("processing", attribute(build, "processingState")),
                                ("expired", attribute(build, "expired")), ("audience", attribute(build, "buildAudienceType"))]).sha256
    }
    public static func identityDigest(_ tester: Resource) -> String {
        let email = attribute(tester, "email")
        let text = email.text ?? (email == .null ? (tester.attributes?["email"] == nil ? "undefined" : "null") : email.stringify())
        return Apple.sha(text.lowercased() + "\0" + tester.id)
    }
    public static func matchesDetail(_ build: Resource, _ detail: Resource?, verifiedAssociation: Bool = false) -> Bool {
        guard build.type == "builds", let detail, detail.type == "buildBetaDetails" else { return false }
        let forward = Planner.resource(build)["relationships"]?["buildBetaDetail"]?["data"], reverse = Planner.resource(detail)["relationships"]?["build"]?["data"]
        if let forward, forward != .null, (forward["type"]?.text != "buildBetaDetails" || forward["id"]?.text != detail.id) { return false }
        if let reverse, reverse != .null, (reverse["type"]?.text != "builds" || reverse["id"]?.text != build.id) { return false }
        return (forward != nil && forward != .null) || (reverse != nil && reverse != .null) || verifiedAssociation
    }
    public static func canSetAutomatic(_ build: Resource, _ detail: Resource?, verifiedAssociation: Bool = false) -> Bool {
        guard matchesDetail(build, detail, verifiedAssociation: verifiedAssociation), WorkspaceSession.processedUnexpired(build), build.attributes?["buildAudienceType"]?.string == "APP_STORE_ELIGIBLE",
              case .bool? = detail?.attributes?["autoNotifyEnabled"] else { return false }
        return ["READY_FOR_BETA_SUBMISSION", "WAITING_FOR_BETA_REVIEW", "IN_BETA_REVIEW"].contains(detail?.attributes?["externalBuildState"]?.string ?? "")
    }
    public static func canNotify(_ build: Resource, _ detail: Resource?, verifiedAssociation: Bool = false) -> Bool {
        matchesDetail(build, detail, verifiedAssociation: verifiedAssociation) && WorkspaceSession.processedUnexpired(build)
            && build.attributes?["buildAudienceType"]?.string == "APP_STORE_ELIGIBLE" && detail?.attributes?["autoNotifyEnabled"] == .bool(false)
            && detail?.attributes?["externalBuildState"]?.string == "READY_FOR_BETA_TESTING"
    }
    public static func automaticDigest(_ build: Resource, _ detail: Resource?, appId: String) throws -> String {
        guard Apple.owned(build, "app", "apps", appId), canSetAutomatic(build, detail, verifiedAssociation: true), let version = build.attributes?["version"]?.string,
              !TextSemantics.trim(version).isEmpty, let detail, !detail.id.isEmpty else { throw PublishFailure.invalid("Apple did not confirm this build's automatic notification state.") }
        return JSONText.object([("appId", .string(appId)), ("build", .object([("id", .string(build.id)), ("version", .string(version)), ("processing", attribute(build, "processingState")),
                                                                          ("expired", attribute(build, "expired")), ("audience", attribute(build, "buildAudienceType"))])),
                                ("detail", .object([("id", .string(detail.id)), ("automatic", attribute(detail, "autoNotifyEnabled")), ("externalState", attribute(detail, "externalBuildState"))]))]).sha256
    }
}

extension WorkspaceSession {
    func scopedTesters(_ items: [TestFlightAccess.Resource], appId: String, list: (String) async throws -> [TestFlightAccess.Resource]) async throws -> [TestFlightAccess.Resource] {
        guard items.allSatisfy({ $0.type == "betaTesters" && !TextSemantics.trim($0.id).isEmpty }), Set(items.map { Data($0.id.utf8) }).count == items.count else { throw PublishFailure.invalid("Apple returned unexpected TestFlight testers.") }
        var result: [TestFlightAccess.Resource] = []
        for item in items {
            let apps: [JSONText]
            if let embedded = Planner.resource(item)["relationships"]?["apps"]?["data"] {
                guard case .array(let values) = embedded else { throw PublishFailure.invalid("Apple returned testers outside the selected app.") }; apps = values
            } else {
                let values = try await list("/v1/betaTesters/\(TextSemantics.pathComponent(item.id))/relationships/apps?limit=200")
                guard values.count <= 2000 else { throw PublishFailure.invalid("Apple did not confirm the tester belongs to this app.") }
                apps = values.map { .object([("type", .string($0.type)), ("id", .string($0.id))]) }
            }
            guard apps.allSatisfy({ $0["type"]?.text == "apps" && !TextSemantics.trim($0["id"]?.text ?? "").isEmpty }),
                  Set(apps.compactMap { $0["id"]?.text.map { Data($0.utf8) } }).count == apps.count, apps.contains(where: { $0["id"]?.text == appId }) else { throw PublishFailure.invalid("Apple returned testers outside the selected app.") }
            var relationships = item.relationships ?? [:]
            relationships["apps"] = .object(["data": .array(apps.map { .object(["type": .string($0["type"]!.text!), "id": .string($0["id"]!.text!)]) })])
            result.append(TestFlightAccess.Resource(type: item.type, id: item.id, attributes: item.attributes, relationships: relationships))
        }
        return result
    }
    func individualTesters(appId: String, buildId: String, client: AppStoreConnectClient) async throws -> [TestFlightAccess.Resource] {
        try await scopedTesters(client.list("/v1/builds/\(buildId)/individualTesters?limit=200"), appId: appId) { try await client.list($0) }
    }
    public func individualBuildTesters(appId: String, buildId: String, client: AppStoreConnectClient) async throws -> [TestFlightTester] {
        try requireFeedbackScope(appId: appId, client: client)
        guard try await appBuilds(appId: appId, client: client).contains(where: { $0.id == buildId }) else { throw PublishFailure.invalid("Choose a build belonging to this app.") }
        let testers = try await individualTesters(appId: appId, buildId: buildId, client: client)
        try requireFeedbackScope(appId: appId, client: client)
        return testers.map { TestFlightTester(id: $0.id, email: $0.attributes?["email"]?.string ?? "Tester", name: "", state: $0.attributes?["state"]?.string ?? "") }.sorted { $0.email.lowercased() < $1.email.lowercased() }
    }
    func exactTester(email: String, client: AppStoreConnectClient) async throws -> TestFlightAccess.Resource? {
        var query = URLComponents(); query.queryItems = [URLQueryItem(name: "filter[email]", value: email), URLQueryItem(name: "fields[betaTesters]", value: "email"), URLQueryItem(name: "limit", value: "200")]
        let testers = try await client.list("/v1/betaTesters?\(query.percentEncodedQuery!)")
        guard testers.count <= 1, testers.allSatisfy({ $0.type == "betaTesters" && TextSemantics.same($0.attributes?["email"]?.string?.lowercased(), email.lowercased()) }) else { throw PublishFailure.invalid("Apple did not return one exact beta tester for this email.") }
        return testers.first
    }
    func checkedBetaDetail(_ build: TestFlightAccess.Resource, client: AppStoreConnectClient, rejectBeta: Bool = false) async throws -> TestFlightAccess.Resource? {
        let values = try await client.get("/v1/builds/\(build.id)/buildBetaDetail"), detail = values.first
        guard values.count <= 1, detail == nil || (detail!.type == "buildBetaDetails" && !detail!.id.isEmpty && TestFlightAccess.matchesDetail(build, detail, verifiedAssociation: true)) else { throw PublishFailure.invalid("Apple returned inconsistent beta details for this build.") }
        let linked = Planner.resource(build)["relationships"]?["buildBetaDetail"]?["data"]
        if let linked { guard linked == .null ? detail == nil : detail?.id == linked["id"]?.text && linked["type"]?.text == "buildBetaDetails" else { throw PublishFailure.invalid("Apple returned inconsistent beta details for this build.") } }
        if rejectBeta && detail?.attributes?["externalBuildState"]?.string == "BETA_REJECTED" { throw PublishFailure.invalid("Apple rejected this build. Upload a new build to continue TestFlight testing.") }
        return detail
    }
    func requireAssignableBuild(_ build: TestFlightAccess.Resource, client: AppStoreConnectClient, externalOnly: Bool = false) async throws {
        guard Self.processedUnexpired(build), ["INTERNAL_ONLY", "APP_STORE_ELIGIBLE"].contains(build.attributes?["buildAudienceType"]?.string ?? ""), !externalOnly || build.attributes?["buildAudienceType"]?.string == "APP_STORE_ELIGIBLE" else { throw PublishFailure.invalid("Choose a processed, unexpired build with a confirmed testing audience.") }
        let reviews = try await client.list("/v1/betaAppReviewSubmissions?filter%5Bbuild%5D=\(build.id)&limit=200")
        guard reviews.allSatisfy({ $0.type == "betaAppReviewSubmissions" && Apple.within($0, "build", "builds", build.id) }) else { throw PublishFailure.invalid("Apple returned beta reviews outside the selected build.") }
        guard !reviews.contains(where: { $0.attributes?["betaReviewState"]?.string == "REJECTED" }) else { throw PublishFailure.invalid("Apple rejected this build. Upload a new build to continue TestFlight testing.") }
        _ = try await checkedBetaDetail(build, client: client, rejectBeta: true)
    }
    func requireInternalTester(email: String, appId: String, client: AppStoreConnectClient) async throws {
            guard TestFlightAccess.validEmail(email) else { throw PublishFailure.invalid("Apple did not provide an email for this internal tester.") }
            var query = URLComponents(); query.queryItems = [URLQueryItem(name: "filter[username]", value: email), URLQueryItem(name: "limit", value: "200")]
            let users = try await client.list("/v1/users?\(query.percentEncodedQuery!)"), matches = users.filter { TextSemantics.same($0.attributes?["username"]?.string?.lowercased(), email.lowercased()) }
            guard users.allSatisfy({ $0.type == "users" }), matches.count == 1, case .array(let roles)? = matches[0].attributes?["roles"], roles.contains(where: { ["ACCOUNT_HOLDER", "ADMIN", "APP_MANAGER", "DEVELOPER", "MARKETING"].contains($0.string ?? "") }) else { throw PublishFailure.invalid("This tester is not a confirmed eligible App Store Connect team user.") }
            if matches[0].attributes?["allAppsVisible"] != .bool(true) {
                let visible = try await client.list("/v1/users/\(TextSemantics.pathComponent(matches[0].id))/visibleApps?limit=200")
                guard visible.allSatisfy({ $0.type == "apps" }), visible.contains(where: { $0.id == appId }) else { throw PublishFailure.invalid("This team user does not have access to the selected app.") }
            }
    }
    func requireIndividualEligibility(_ tester: TestFlightAccess.Resource, build: TestFlightAccess.Resource, appId: String, client: AppStoreConnectClient) async throws {
        if build.attributes?["buildAudienceType"]?.string == "INTERNAL_ONLY" { try await requireInternalTester(email: tester.attributes?["email"]?.string ?? "", appId: appId, client: client) }
        let groups = try await appGroups(appId: appId, client: client), memberships = try await client.list("/v1/betaTesters/\(tester.id)/betaGroups?limit=200")
        guard memberships.allSatisfy({ $0.type == "betaGroups" }), !memberships.contains(where: { member in groups.contains { $0.id == member.id } }) else { throw PublishFailure.invalid("This tester belongs to a group for this app. Manage the group's build access instead.") }
    }
    func planBuildAccess(_ planner: Planner) async throws -> String? {
        let request = planner.request, appId = request.appId, client = planner.client, action = request.testflightAction ?? ""
        guard ["assign-individual-tester", "remove-individual-tester", "invite-individual-tester", "set-auto-notify"].contains(action) else { return nil }
        guard let build = try await appBuilds(appId: appId, client: client, planner: planner).first(where: { $0.id == request.buildId }) else { throw PublishFailure.invalid("Choose a build belonging to this app.") }
        let version = build.attributes?["version"]?.string ?? build.id
        if action == "set-auto-notify" {
            let detail = try await checkedBetaDetail(build, client: client)
            guard let detail, let flag = request.autoNotifyEnabled else { throw PublishFailure.invalid("Choose On or Off for automatic build notification.") }
            let digest = try TestFlightAccess.automaticDigest(build, detail, appId: appId), before = detail.attributes?["autoNotifyEnabled"] == .bool(true)
            if before != flag {
                planner.add(.api, method: "PATCH", path: [.string("buildBetaDetails"), .string(detail.id)], label: "Set automatic TestFlight notification", detail: "Build \(version) · \(build.id) · \(detail.attributes?["externalBuildState"]?.string ?? "Unknown beta review state")",
                            before: "Automatic tester notification \(before ? "on" : "off")", after: "Automatic tester notification \(flag ? "on" : "off")",
                            body: .object([("data", .object([("type", .string("buildBetaDetails")), ("id", .string(detail.id)), ("attributes", .object([("autoNotifyEnabled", .bool(flag))]))]))]),
                            guard: .object([("kind", .string("automatic-build-notification")), ("digest", .string(digest)), ("buildId", .string(build.id))]))
            }
            planner.notes.append("Apple can notify assigned testers automatically when this build is approved for external testing. Changing this setting does not itself start testing.")
            return "Automatic tester notification · build \(version)"
        }
        let assigned = try await individualTesters(appId: appId, buildId: build.id, client: client), removing = action == "remove-individual-tester", inviting = action == "invite-individual-tester"
        let testers = removing ? assigned : try await appTesters(appId: appId, client: client, planner: planner)
        let appTester = inviting ? testers.first { TextSemantics.same($0.attributes?["email"]?.string?.lowercased(), request.testerEmail) } : testers.first { $0.id == request.testerId }
        var tester = appTester
        if inviting && tester == nil { tester = try await exactTester(email: request.testerEmail!, client: client) }
        if action == "assign-individual-tester" && tester == nil { throw PublishFailure.invalid("This tester does not belong to the selected app.") }
        let display = tester?.attributes?["email"]?.string ?? request.testerEmail ?? request.testerId ?? "Tester", title = "\(removing ? "Remove" : inviting ? "Invite" : "Assign") individual tester · build \(version)"
        let present = tester.map { target in assigned.contains { $0.id == target.id } } ?? false
        if !removing { try await requireAssignableBuild(build, client: client, externalOnly: inviting) }
        if removing ? present : !present {
            if let tester {
                if !removing { try await requireIndividualEligibility(tester, build: build, appId: appId, client: client) }
                var guardFields: [(String, JSONText)] = [("kind", .string("individual-access")), ("digest", .string(try TestFlightAccess.individualDigest(build, testers: assigned, testerId: tester.id))),
                                                         ("testerDigest", .string(TestFlightAccess.identityDigest(tester))), ("buildId", .string(build.id))]
                if !removing && appTester == nil, let email = request.testerEmail { guardFields.append(("email", .string(email))) }
                planner.add(.api, method: removing ? "DELETE" : "POST", path: [.string("builds"), .string(build.id), .string("relationships"), .string("individualTesters")], label: removing ? "Remove individual build access" : "Assign individual build tester", detail: "Build \(version) · \(display)",
                            before: removing ? "Direct build access" : appTester == nil ? "Tester exists at Apple, outside this app" : "No direct build access", after: removing ? "Direct build access removed" : "Direct build access",
                            body: Self.linkages("betaTesters", tester.id), guard: .object(guardFields))
            } else if inviting {
                planner.add(.api, method: "POST", path: [.string("betaTesters")], label: "Invite individual build tester", detail: "Build \(version) · \(display)", before: "No tester with this email in this app", after: "Tester invited to build \(version) · \(build.id)\nAudience: App Store eligible",
                            body: .object([("data", .object([("type", .string("betaTesters")), ("attributes", .object([("email", .string(request.testerEmail!))])), ("relationships", .object([("builds", Self.linkages("builds", build.id))]))]))]),
                            guard: .object([("kind", .string("tester-build-target")), ("digest", .string(try TestFlightAccess.creationDigest(build, appId: appId))), ("buildId", .string(build.id))]))
            }
        }
        planner.notes.append(removing ? "Removing this direct assignment does not remove access granted through a TestFlight group." : "This grants access only to the selected build. Apple handles invitations, eligibility and any external beta review requirement.")
        return title
    }

    func verifyBuildAccess(method: String, parts: [String], data: JSONText?, guardValue: JSONText?, appId: String, client: AppStoreConnectClient) async throws {
        guard let buildId = guardValue?["buildId"]?.text, let build = try await appBuilds(appId: appId, client: client).first(where: { $0.id == buildId }) else { throw PublishFailure.write("TestFlight build no longer belongs to this app.") }
        func keys(_ value: JSONText?, _ expected: Set<String>) -> Bool { guard case .object(let fields)? = value else { return false }; return Set(fields.map(\.0)) == expected && fields.count == expected.count }
        switch guardValue?["kind"]?.text {
        case "automatic-build-notification":
            guard method == "PATCH", parts.count == 2, parts[0] == "buildBetaDetails", keys(data, ["type", "id", "attributes"]), data?["type"]?.text == "buildBetaDetails", data?["id"]?.text == parts[1], keys(data?["attributes"], ["autoNotifyEnabled"]), case .bool(let flag)? = data?["attributes"]?["autoNotifyEnabled"] else { throw PublishFailure.write("Unsupported TestFlight automatic notification change.") }
            let current = try await client.get("/v1/buildBetaDetails/\(parts[1])"), owners = try await client.get("/v1/buildBetaDetails/\(parts[1])/relationships/build")
            guard current.count == 1, current[0].id == parts[1], owners.count == 1, owners[0].type == "builds", owners[0].id == buildId,
                  current[0].attributes?["autoNotifyEnabled"] != .bool(flag), try TestFlightAccess.automaticDigest(build, current[0], appId: appId) == guardValue?["digest"]?.text else { throw PublishFailure.write("Automatic notification state changed after review. Prepare a new review.") }
        case "individual-access":
            guard ["POST", "DELETE"].contains(method), parts == ["builds", buildId, "relationships", "individualTesters"], case .array(let links)? = data, links.count == 1, keys(links[0], ["type", "id"]), links[0]["type"]?.text == "betaTesters", let testerId = links[0]["id"]?.text else { throw PublishFailure.write("Unsupported individual TestFlight tester change.") }
            let adding = method == "POST"
            if adding { try await requireAssignableBuild(build, client: client) }
            let assigned = try await individualTesters(appId: appId, buildId: buildId, client: client), testers = adding ? try await appTesters(appId: appId, client: client) : assigned
            var tester = testers.first { $0.id == testerId }
            if let email = guardValue?["email"]?.text {
                guard adding, build.attributes?["buildAudienceType"]?.string == "APP_STORE_ELIGIBLE", TestFlightAccess.validEmail(email), tester == nil else { throw PublishFailure.write("This individual assignment changed after review.") }
                tester = try await exactTester(email: email, client: client)
            }
            guard let tester, tester.id == testerId, TestFlightAccess.identityDigest(tester) == guardValue?["testerDigest"]?.text,
                  try TestFlightAccess.individualDigest(build, testers: assigned, testerId: testerId) == guardValue?["digest"]?.text,
                  adding != assigned.contains(where: { $0.id == testerId }) else { throw PublishFailure.write("Individual build access changed after review. Prepare a new review.") }
            if adding { try await requireIndividualEligibility(tester, build: build, appId: appId, client: client) }
        case "tester-build-target":
            guard method == "POST", parts == ["betaTesters"], keys(data, ["type", "attributes", "relationships"]), data?["type"]?.text == "betaTesters", keys(data?["attributes"], ["email"]),
                  let email = data?["attributes"]?["email"]?.text, TestFlightAccess.validEmail(email), keys(data?["relationships"], ["builds"]), data?["relationships"]?["builds"] == Self.linkages("builds", buildId),
                  try TestFlightAccess.creationDigest(build, appId: appId) == guardValue?["digest"]?.text else { throw PublishFailure.write("Unsupported individual tester invitation.") }
            try await requireAssignableBuild(build, client: client, externalOnly: true)
            guard try await exactTester(email: email, client: client) == nil else { throw PublishFailure.write("This tester now exists at Apple. Prepare an individual assignment instead.") }
        default: throw PublishFailure.write("Unsupported TestFlight build access change.")
        }
    }
}
