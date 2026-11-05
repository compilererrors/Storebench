import Foundation

/// Exact recipient and app-wide access snapshots for reviewed TestFlight tester changes.
public enum TestFlightAppTesters {
    public typealias Resource = AppStoreConnectClient.Resource
    public struct RemovalReview: Sendable { public let before, digest: String }
    public struct Page: Sendable { public let testers: [TestFlightTester], next: String? }
    public static func emailFilter(_ value: String) throws -> String {
        let value = TextSemantics.trim(value).lowercased()
        guard value.isEmpty || TestFlightAccess.validEmail(value) else { throw PublishFailure.invalid("Enter a complete tester email of at most 254 characters, or clear the filter.") }
        return value
    }
    static func model(_ tester: Resource) -> TestFlightTester {
        TestFlightTester(id: tester.id, email: tester.attributes?["email"]?.string ?? "Tester", name: [tester.attributes?["firstName"]?.string, tester.attributes?["lastName"]?.string].compactMap { $0 }.joined(separator: " "),
                         state: tester.attributes?["state"]?.string ?? "", inviteType: tester.attributes?["inviteType"]?.string)
    }
    static func canSendInvitation(email: String, inviteType: String?, state: String) -> Bool {
        TestFlightAccess.validEmail(email) && inviteType != "PUBLIC_LINK" && ["NOT_INVITED", "INVITED"].contains(state)
    }
    public static func canSendInvitation(_ tester: Resource) -> Bool {
        guard tester.type == "betaTesters", let email = tester.attributes?["email"]?.string else { return false }
        return canSendInvitation(email: email, inviteType: tester.attributes?["inviteType"]?.string, state: tester.attributes?["state"]?.string ?? "")
    }
    public static func invitationDigest(_ tester: Resource, appId: String) throws -> String {
        try TestFlightGroups.owned([tester], type: "betaTesters", appId: appId)
        guard canSendInvitation(tester) else { throw PublishFailure.invalid("Apple did not confirm this app's invitation recipient.") }
        return JSONText.object([("appId", .string(appId)), ("testerId", .string(tester.id)), ("email", TestFlightAccess.attribute(tester, "email")),
                                ("state", TestFlightAccess.attribute(tester, "state")), ("inviteType", TestFlightAccess.attribute(tester, "inviteType"))]).sha256
    }
    public static func removalReview(appId: String, tester: Resource, appGroups: [Resource], appBuilds: [Resource], testerGroups: [Resource], testerBuilds: [Resource]) throws -> RemovalReview {
        guard !appId.isEmpty, let email = tester.attributes?["email"]?.string, !TextSemantics.trim(email).isEmpty else { throw PublishFailure.invalid("Apple did not confirm this app's TestFlight tester.") }
        try TestFlightGroups.owned([tester], type: "betaTesters", appId: appId)
        try TestFlightGroups.owned(appGroups, type: "betaGroups", appId: appId); try TestFlightGroups.owned(appBuilds, type: "builds", appId: appId)
        try TestFlightGroups.unique(testerGroups, type: "betaGroups"); try TestFlightGroups.unique(testerBuilds, type: "builds")
        let groupIds = Set(testerGroups.map { Data($0.id.utf8) }), buildIds = Set(testerBuilds.map { Data($0.id.utf8) })
        func selected(_ catalog: [Resource], ids: Set<Data>, label: String) throws -> [JSONText] {
            try TestFlightAudience.ordered(catalog.filter { ids.contains(Data($0.id.utf8)) }, id: { $0.id }).map { item in
                let value = TestFlightAccess.attribute(item, label)
                guard value == .null || value.text != nil else { throw PublishFailure.invalid("Apple did not confirm the reviewed TestFlight access labels.") }
                return .object([("id", .string(item.id)), (label, value)])
            }
        }
        let groups = try selected(appGroups, ids: groupIds, label: "name"), builds = try selected(appBuilds, ids: buildIds, label: "version")
        func lines(_ items: [JSONText], label: String) -> [String] {
            items.map { item in let id = item["id"]!.text!, text = item[label]?.text; return "\(text?.isEmpty == false ? text! : id) · \(id)" }
        }
        let before = (["Tester: \(email) · \(tester.id)", "", "Groups in this app (\(groups.count)):"] + (groups.isEmpty ? ["None"] : lines(groups, label: "name"))
                      + ["", "Direct builds in this app (\(builds.count)):"] + (builds.isEmpty ? ["None"] : lines(builds, label: "version"))).joined(separator: "\n")
        let digest = JSONText.object([("appId", .string(appId)), ("testerId", .string(tester.id)), ("email", .string(email)), ("groups", .array(groups)), ("builds", .array(builds))]).sha256
        return RemovalReview(before: before, digest: digest)
    }
}

extension WorkspaceSession {
    /// One Apple page with the app and optional email pinned across cursor changes.
    public func testFlightTesterPage(appId: String, email: String = "", cursor: String? = nil, client: AppStoreConnectClient) async throws -> TestFlightAppTesters.Page {
        try requireFeedbackScope(appId: appId, client: client)
        let email = try TestFlightAppTesters.emailFilter(email)
        if let cursor { guard !cursor.isEmpty, cursor.utf16.count <= 2048, !cursor.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw AppStoreConnectClient.Failure.invalidPagination } }
        var path = URLComponents(string: "/v1/betaTesters")!
        path.queryItems = [URLQueryItem(name: "filter[apps]", value: appId), URLQueryItem(name: "limit", value: "200")]
        if !email.isEmpty { path.queryItems!.append(URLQueryItem(name: "filter[email]", value: email)) }
        if let cursor { path.queryItems!.append(URLQueryItem(name: "cursor", value: cursor)) }
        let page = try await client.page(path.string!, currentCursor: cursor)
        guard page.resources.count <= 200, page.next == nil || !page.resources.isEmpty else { throw AppStoreConnectClient.Failure.invalidPagination }
        let testers = try await scopedTesters(page.resources, appId: appId) { try await client.list($0) }
        guard email.isEmpty || testers.allSatisfy({ TextSemantics.same($0.attributes?["email"]?.string?.lowercased(), email) }) else { throw PublishFailure.invalid("Apple returned testers outside the requested email filter.") }
        try requireFeedbackScope(appId: appId, client: client)
        return TestFlightAppTesters.Page(testers: testers.map(TestFlightAppTesters.model), next: page.next)
    }
    func appTesterRemoval(_ tester: AppStoreConnectClient.Resource, appId: String, client: AppStoreConnectClient, planner: Planner? = nil) async throws -> TestFlightAppTesters.RemovalReview {
        let list = { (path: String) in planner != nil ? try await planner!.list(path) : try await client.list(path) }
        let groups = try await appGroups(appId: appId, client: client, planner: planner), builds = try await appBuilds(appId: appId, client: client, planner: planner)
        let prefix = "/v1/betaTesters/\(TextSemantics.pathComponent(tester.id))"
        let memberships = try await list("\(prefix)/betaGroups?limit=200"), assignments = try await list("\(prefix)/builds?limit=200")
        return try TestFlightAppTesters.removalReview(appId: appId, tester: tester, appGroups: groups, appBuilds: builds, testerGroups: memberships, testerBuilds: assignments)
    }
    func planAppTesterChange(_ planner: Planner) async throws -> String? {
        let request = planner.request, appId = request.appId, action = request.testflightAction ?? ""
        guard ["send-invitation", "remove-app-tester"].contains(action) else { return nil }
        guard let tester = try await appTesters(appId: appId, client: planner.client, planner: planner).first(where: { TextSemantics.same($0.id, request.testerId) }) else { throw PublishFailure.invalid("This tester does not belong to the selected app.") }
        if action == "send-invitation" {
            let digest = try TestFlightAppTesters.invitationDigest(tester, appId: appId), email = tester.attributes!["email"]!.string!, pending = tester.attributes?["state"]?.string == "INVITED"
            planner.add(.api, method: "POST", path: [.string("betaTesterInvitations")], label: pending ? "Resend TestFlight invitation" : "Send TestFlight invitation", detail: email,
                        before: "Tester: \(email) · \(tester.id)\n\(pending ? "Invitation pending acceptance" : "Invitation not yet sent")", after: "Invitation email requested from Apple",
                        body: .object([("data", .object([("type", .string("betaTesterInvitations")), ("relationships", .object([("app", Apple.relationship("apps", .string(appId))), ("betaTester", Apple.relationship("betaTesters", .string(tester.id)))]))]))]),
                        guard: .object([("kind", .string("tester-invitation")), ("digest", .string(digest))]))
            planner.notes.append("Apple sends the email for this app. Delivery and acceptance are not guaranteed; refresh TestFlight to check the tester's status.")
            return "\(pending ? "Resend" : "Send") TestFlight invitation · \(email)"
        }
        let access = try await appTesterRemoval(tester, appId: appId, client: planner.client, planner: planner), email = tester.attributes!["email"]!.string!
        planner.add(.api, method: "DELETE", path: [.string("apps"), .string(appId), .string("relationships"), .string("betaTesters")], label: "Remove tester from this app", detail: email, before: access.before,
                    after: "App-wide access removal requested", body: Self.linkages("betaTesters", tester.id), guard: .object([("kind", .string("app-tester-access")), ("digest", .string(access.digest))]))
        planner.notes.append("This removes the tester from every group and build of this app. Other apps remain unchanged. Installed builds may stay usable until they expire. Apple may accept the request before it finishes processing; refresh TestFlight to confirm the result.")
        return "Remove TestFlight tester · \(email)"
    }
    func verifyAppTesterChange(method: String, parts: [String], body: JSONText?, guardValue: JSONText?, appId: String, client: AppStoreConnectClient) async throws {
        func keys(_ value: JSONText?, _ expected: Set<String>) -> Bool { guard case .object(let fields)? = value else { return false }; return fields.count == expected.count && Set(fields.map(\.0)) == expected }
        guard keys(body, ["data"]), keys(guardValue, ["kind", "digest"]), let digest = guardValue?["digest"]?.text, digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { throw PublishFailure.write("Unsupported TestFlight tester approval guard.") }
        let data = body?["data"], inviting = parts == ["betaTesterInvitations"], testerId: String
        if inviting {
            guard method == "POST", guardValue?["kind"]?.text == "tester-invitation", keys(data, ["type", "relationships"]), data?["type"]?.text == "betaTesterInvitations",
                  keys(data?["relationships"], ["app", "betaTester"]), data?["relationships"]?["app"] == Apple.relationship("apps", .string(appId)),
                  keys(data?["relationships"]?["betaTester"], ["data"]), keys(data?["relationships"]?["betaTester"]?["data"], ["type", "id"]),
                  data?["relationships"]?["betaTester"]?["data"]?["type"]?.text == "betaTesters", let id = data?["relationships"]?["betaTester"]?["data"]?["id"]?.text else { throw PublishFailure.write("Unsupported TestFlight invitation request.") }
            testerId = id
        } else {
            guard method == "DELETE", parts == ["apps", appId, "relationships", "betaTesters"], guardValue?["kind"]?.text == "app-tester-access", case .array(let links)? = data,
                  links.count == 1, keys(links[0], ["type", "id"]), links[0]["type"]?.text == "betaTesters", let id = links[0]["id"]?.text else { throw PublishFailure.write("Unsupported app TestFlight tester removal.") }
            testerId = id
        }
        guard let tester = try await appTesters(appId: appId, client: client).first(where: { TextSemantics.same($0.id, testerId) }) else { throw PublishFailure.write("TestFlight tester no longer belongs to this app.") }
        let current = inviting ? try TestFlightAppTesters.invitationDigest(tester, appId: appId) : try await appTesterRemoval(tester, appId: appId, client: client).digest
        guard current == digest else { throw PublishFailure.write("The TestFlight tester identity or app access changed after review. Prepare a new review.") }
    }
}
