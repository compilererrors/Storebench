import Foundation
import Testing
@testable import StorebenchCore

final class SyntheticTestFlightGroups: @unchecked Sendable {
    let lock = NSLock(), apple = SyntheticApple()
    var groups: [[String: Any]], builds: [[String: Any]], testers: [[String: Any]]
    var assignedBuilds = ["build-7"], assignedTesters = ["tester-1"]
    var globalTester: [String: Any]?
    var userRoles = ["DEVELOPER"], allAppsVisible = true, visibleApp = "1000000001", duplicateUser = false
    var groupOwner = "owned", buildOwner = "owned", testerOwner = "owned", resolvedOwner = "1000000001"
    var betaState = "READY_FOR_BETA_TESTING", rejectedReview = false
    var groupReads = 0, mutationOnRead: Int?, mutation = "rename"
    var writes: [(String, String, [String: Any]?)] = []
    init() {
        groups = [Self.group("group-1", internalGroup: false), Self.group("group-internal", internalGroup: true)]
        builds = apple.builds
        var extra = apple.builds[0]; extra["id"] = "build-8"
        var attributes = extra["attributes"] as! [String: Any]; attributes["version"] = "8"; extra["attributes"] = attributes
        extra["relationships"] = ["app": ["data": ["type": "apps", "id": "1000000001"]]]
        builds.append(extra)
        testers = [Self.tester("tester-1"), Self.tester("tester-2")]
    }
    static func group(_ id: String, internalGroup: Bool = false) -> [String: Any] {
        ["type": "betaGroups", "id": id, "attributes": ["name": internalGroup ? "Synthetic internal group" : "Synthetic group", "isInternalGroup": internalGroup,
          "feedbackEnabled": true, "hasAccessToAllBuilds": false, "publicLinkEnabled": !internalGroup, "publicLinkLimitEnabled": !internalGroup, "publicLinkLimit": 200],
         "relationships": ["app": ["data": ["type": "apps", "id": "1000000001"]]]]
    }
    static func tester(_ id: String, email: String? = nil) -> [String: Any] {
        ["type": "betaTesters", "id": id, "attributes": ["email": email ?? "\(id)@example.com", "state": "INSTALLED"], "relationships": ["apps": ["data": [["type": "apps", "id": "1000000001"]]]]]
    }
    func setGroup(_ field: String, _ value: Any) { var fields = groups[0]["attributes"] as! [String: Any]; fields[field] = value; groups[0]["attributes"] = fields }
    func setBuild(_ field: String, _ value: Any) { var fields = builds[1]["attributes"] as! [String: Any]; fields[field] = value; builds[1]["attributes"] = fields }
    func mutate() {
        switch mutation {
        case "rename": setGroup("name", "Changed synthetic group")
        case "type": setGroup("isInternalGroup", true)
        case "feedback": setGroup("feedbackEnabled", false)
        case "limit": setGroup("publicLinkLimit", 201)
        case "automatic": setGroup("hasAccessToAllBuilds", true)
        case "member": assignedTesters.append("tester-2")
        case "tester-email": var fields = testers[0]["attributes"] as! [String: Any]; fields["email"] = "changed@example.com"; testers[0]["attributes"] = fields
        case "tester-state": var fields = testers[0]["attributes"] as! [String: Any]; fields["state"] = "INVITED"; testers[0]["attributes"] = fields
        case "build-member": assignedBuilds.append("build-8")
        case "build-version": var fields = builds[0]["attributes"] as! [String: Any]; fields["version"] = "Changed"; builds[0]["attributes"] = fields
        case "target-expired": setBuild("expired", true)
        case "target-audience": setBuild("buildAudienceType", "INTERNAL_ONLY")
        case "rejected": rejectedReview = true
        case "beta-rejected": betaState = "BETA_REJECTED"
        case "global-created": globalTester = Self.tester("tester-global", email: "new@example.com")
        case "global-id": globalTester?["id"] = "tester-global-changed"
        case "target-removed": testers.removeAll { $0["id"] as? String == "tester-2" }
        case "roles": userRoles = ["FINANCE"]
        case "visible": allAppsVisible = false; visibleApp = "1000000002"
        case "duplicate-name": groups.append(Self.group("group-new")); var fields = groups[2]["attributes"] as! [String: Any]; fields["name"] = "New synthetic group"; groups[2]["attributes"] = fields
        case "internal-removed": groups.removeAll { ($0["attributes"] as? [String: Any])?["isInternalGroup"] as? Bool == true }
        case "foreign": testerOwner = "foreign"
        default: groups.removeFirst()
        }
    }
    func owned(_ values: [[String: Any]], relation: String, mode: String) -> [[String: Any]] {
        values.map { original in
            var value = original
            if mode == "omitted" { value.removeValue(forKey: "relationships") }
            if mode == "null" { value["relationships"] = [relation: ["data": NSNull()]] }
            if mode == "foreign" { let data: Any = relation == "apps" ? [["type": "apps", "id": "1000000002"]] : ["type": "apps", "id": "1000000002"]; value["relationships"] = [relation: ["data": data]] }
            return value
        }
    }
    func handle(_ request: URLRequest) -> (Int, [String: String], Data) {
        lock.withLock {
            let path = request.url!.path, method = request.httpMethod ?? "GET", query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
            if method != "GET" {
                let body = (try? JSONSerialization.jsonObject(with: apple.body(request))) as? [String: Any]
                let data = body?["data"] as? [String: Any]
                if method == "POST", path == "/v1/betaGroups", body?.count == 1, data?.count == 3, data?["type"] as? String == "betaGroups", let fields = data?["attributes"] as? [String: Any], fields.count == 2 {
                    var group = Self.group("group-created", internalGroup: fields["isInternalGroup"] as? Bool ?? false); group["attributes"] = fields; groups.append(group); writes.append((method, path, body)); return apple.page(group)
                }
                if path == "/v1/betaGroups/group-1", method == "PATCH", body?.count == 1, data?.count == 3, data?["type"] as? String == "betaGroups", data?["id"] as? String == "group-1", let fields = data?["attributes"] as? [String: Any], !fields.isEmpty, fields.keys.allSatisfy(TestFlightGroups.editable.contains) {
                    for (key, value) in fields { setGroup(key, value) }; writes.append((method, path, body)); return apple.page(groups[0])
                }
                if path == "/v1/betaGroups/group-1", method == "DELETE", body == nil { groups.removeFirst(); writes.append((method, path, nil)); return (204, [:], Data()) }
                if ["POST", "DELETE"].contains(method), body?.count == 1, let links = body?["data"] as? [[String: Any]], links.count == 1, links[0].count == 2, let id = links[0]["id"] as? String {
                    let build = path.hasSuffix("/relationships/builds"), relation = build ? "builds" : "betaTesters"
                    if path == "/v1/betaGroups/group-1/relationships/\(relation)", links[0]["type"] as? String == relation {
                        if build { assignedBuilds = method == "POST" ? assignedBuilds + [id] : assignedBuilds.filter { $0 != id } }
                        else { assignedTesters = method == "POST" ? assignedTesters + [id] : assignedTesters.filter { $0 != id } }
                        writes.append((method, path, body)); return (204, [:], Data())
                    }
                }
                if method == "POST", path == "/v1/betaTesters", body?.count == 1, data?.count == 3, data?["type"] as? String == "betaTesters", let fields = data?["attributes"] as? [String: Any], fields.count == 1, let email = fields["email"] as? String,
                   let relations = data?["relationships"] as? [String: Any], relations.count == 1, let target = relations["betaGroups"] as? [String: Any], let links = target["data"] as? [[String: Any]], links.count == 1, links[0]["id"] as? String == "group-1" {
                    let tester = Self.tester("tester-created", email: email); testers.append(tester); assignedTesters.append("tester-created"); writes.append((method, path, body)); return apple.page(tester)
                }
                return (400, [:], Data())
            }
            switch path {
            case "/v1/apps/1000000001": return apple.page(["type": "apps", "id": "1000000001", "attributes": ["name": "Synthetic app"]])
            case "/v1/betaGroups":
                guard query.count == 3, value("filter[app]") == "1000000001", value("include") == "app", value("limit") == "200" else { return (400, [:], Data()) }
                groupReads += 1; if groupReads == mutationOnRead { mutate() }; return apple.page(owned(groups, relation: "app", mode: groupOwner))
            case "/v1/apps/1000000001/builds": return apple.page(owned(builds, relation: "app", mode: buildOwner))
            case "/v1/betaGroups/group-1/builds": return apple.page(owned(builds.filter { assignedBuilds.contains($0["id"] as! String) }, relation: "app", mode: buildOwner))
            case "/v1/betaGroups/group-internal/builds": return apple.page([])
            case "/v1/betaGroups/group-1/betaTesters": return apple.page(owned(testers.filter { assignedTesters.contains($0["id"] as! String) }, relation: "apps", mode: testerOwner))
            case "/v1/betaGroups/group-internal/betaTesters": return apple.page([])
            case "/v1/betaTesters":
                if let email = value("filter[email]") { return apple.page((testers + (globalTester.map { [$0] } ?? [])).filter { (($0["attributes"] as? [String: Any])?["email"] as? String)?.lowercased() == email.lowercased() }) }
                guard query.count == 2, value("filter[apps]") == "1000000001", value("limit") == "200" else { return (400, [:], Data()) }
                return apple.page(owned(testers, relation: "apps", mode: testerOwner))
            case "/v1/users":
                guard let email = value("filter[username]") else { return (400, [:], Data()) }
                let user: [String: Any] = ["type": "users", "id": "user-synthetic", "attributes": ["username": email, "roles": userRoles, "allAppsVisible": allAppsVisible]]
                return apple.page(duplicateUser ? [user, user] : [user])
            case "/v1/users/user-synthetic/visibleApps": return apple.page([["type": "apps", "id": visibleApp]])
            case "/v1/betaAppReviewSubmissions":
                guard let buildId = value("filter[build]") else { return (400, [:], Data()) }
                return apple.page(rejectedReview ? [["type": "betaAppReviewSubmissions", "id": "beta-review-synthetic", "attributes": ["betaReviewState": "REJECTED"], "relationships": ["build": ["data": ["type": "builds", "id": buildId]]]]] : [])
            case "/v1/builds/build-7/buildBetaDetail", "/v1/builds/build-8/buildBetaDetail":
                let id = path.contains("build-8") ? "build-8" : "build-7"
                return apple.page(["type": "buildBetaDetails", "id": id == "build-7" ? "detail-7" : "detail-8", "attributes": ["externalBuildState": betaState], "relationships": ["build": ["data": ["type": "builds", "id": id]]]])
            default:
                for item in groups + builds where path == "/v1/\(item["type"] as! String)/\(item["id"] as! String)/relationships/app" { return apple.page(["type": "apps", "id": resolvedOwner]) }
                for item in testers where path == "/v1/betaTesters/\(item["id"] as! String)/relationships/apps" { return apple.page([["type": "apps", "id": resolvedOwner]]) }
                return (404, [:], Data())
            }
        }
    }
}

@Suite(.serialized) struct TestFlightGroupTests {
    init() throws { _ = try TestIsolation.require() }
    let app = "1000000001"
    func request(_ account: Account, _ action: String) -> PublishRequest {
        var value = PublishRequest(accountId: account.id, appId: app, scope: .testflight)
        value.testflightAction = action
        if action == "create-group" { value.groupName = "New synthetic group"; value.internalGroup = false }
        else { value.groupId = "group-1" }
        if action == "rename-group" { value.groupName = "New synthetic group" }
        if action == "set-group-setting" { value.groupSetting = "public-link-limit"; value.groupSettingValue = .number(500) }
        if ["add-build", "remove-build"].contains(action) { value.buildId = action == "add-build" ? "build-8" : "build-7" }
        if ["add-tester", "remove-tester"].contains(action) { value.testerId = action == "add-tester" ? "tester-2" : "tester-1" }
        if action == "invite-tester" { value.testerEmail = "new@example.com" }
        return value
    }
    func resource(_ value: JSONText) throws -> AppStoreConnectClient.Resource { try JSONDecoder().decode(AppStoreConnectClient.Resource.self, from: value.data) }
    func resources(_ value: JSONText) throws -> [AppStoreConnectClient.Resource] { try JSONDecoder().decode([AppStoreConnectClient.Resource].self, from: value.data) }
    func approve(_ session: WorkspaceSession, _ account: Account, _ client: AppStoreConnectClient, _ review: PublishReview) async throws -> PublishReview {
        try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: client)
    }
    @Test func snapshotsAndBoundedAudienceTextMatchTheWeb() throws {
        let vector = try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/testflight-groups.json")))
        guard case .array(let cases)? = vector["groupCases"], case .array(let audiences)? = vector["groupAudienceCases"] else { throw JSONText.ParseFailure.invalid }
        for value in cases {
            func calculate() throws -> String {
                switch value["kind"]?.text {
                case "creation": return try TestFlightGroups.creationDigest(appId: app, groups: resources(#require(value["groups"])))
                case "attributes": return try TestFlightGroups.attributesDigest(resource(#require(value["group"])), changes: #require(value["changes"]))
                case "deletion": return try TestFlightGroups.deletionDigest(appId: app, group: resource(#require(value["group"])), builds: resources(#require(value["builds"])), testers: resources(#require(value["testers"])))
                case "testerCreation": return try TestFlightGroups.testerCreationDigest(group: resource(#require(value["group"])), builds: resources(#require(value["builds"])), appId: app)
                case "access": return try TestFlightGroups.accessDigest(group: resource(#require(value["group"])), members: resources(#require(value["members"])), peers: resources(#require(value["peers"])), relation: #require(value["relation"]?.text), target: resource(#require(value["target"])))
                default: throw JSONText.ParseFailure.invalid
                }
            }
            if value["valid"] == .bool(true) { #expect(try calculate() == value["digest"]?.text) }
            else { #expect(throws: PublishFailure.self) { try calculate() } }
        }
        for value in audiences { #expect(try TestFlightGroups.audience(resources(#require(value["peers"])), relation: #require(value["relation"]?.text)) == value["text"]?.text) }
        #expect(cases.count == 48 && audiences.count == 5)
    }
    @Test func everyGroupActionRequiresExplicitApprovalAndIsConsumedOnce() async throws {
        for action in ["create-group", "rename-group", "set-group-setting", "delete-group", "invite-tester", "add-tester", "remove-tester", "add-build", "remove-build"] {
            let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
            let account = try #require(try await session.accounts().first), model = SyntheticTestFlightGroups(), host = "group-action-\(action).appstoreconnect.test", client = try PublishingTests().client(account, host: host)
            StubProtocol.handle(host) { model.handle($0) }
            let review = try await session.preparePublishing(account: account, request: request(account, action), client: client)
            #expect(review.steps.count == 1 && model.writes.isEmpty)
            if action == "add-build" { #expect(review.steps[0].after?.contains("tester-1@example.com") == true) }
            if action == "add-tester" { #expect(review.steps[0].after?.contains("Build 7") == true) }
            if action == "delete-group" { #expect(review.steps[0].before?.contains("tester-1@example.com") == true && review.steps[0].before?.contains("7 · build-7") == true) }
            #expect(try await approve(session, account, client, review).state == "complete" && model.writes.count == 1)
            await #expect(throws: PublishFailure.used) { try await approve(session, account, client, review) }
        }
    }
    @Test func groupChangesBeforeApprovalRequireANewReview() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), model = SyntheticTestFlightGroups(), host = "group-approval-conflict.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        StubProtocol.handle(host) { model.handle($0) }
        let review = try await session.preparePublishing(account: account, request: request(account, "delete-group"), client: client)
        model.mutation = "tester-email"; model.mutationOnRead = model.groupReads + 1
        await #expect(throws: PublishFailure.conflict) { try await approve(session, account, client, review) }
        #expect(model.writes.isEmpty)
    }
    @Test func allRelevantLateGroupAudienceAndTargetChangesBlockTheWrite() async throws {
        let scenarios: [(String, [String])] = [
            ("create-group", ["rename", "duplicate-name", "internal-removed"]), ("rename-group", ["rename", "type"]), ("set-group-setting", ["limit", "rename", "type"]),
            ("delete-group", ["rename", "feedback", "automatic", "member", "tester-email", "build-member", "build-version", "foreign"]),
            ("add-build", ["rename", "automatic", "member", "tester-email", "tester-state", "target-expired", "target-audience", "rejected", "beta-rejected"]),
            ("add-tester", ["rename", "automatic", "build-member", "build-version", "target-removed"]),
            ("invite-tester", ["rename", "automatic", "build-member", "build-version", "global-created"])]
        for (action, mutations) in scenarios { for mutation in mutations {
            let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
            let account = try #require(try await session.accounts().first), model = SyntheticTestFlightGroups(), host = "group-late-\(action)-\(mutation).appstoreconnect.test", client = try PublishingTests().client(account, host: host)
            StubProtocol.handle(host) { model.handle($0) }
            let review = try await session.preparePublishing(account: account, request: request(account, action), client: client)
            model.mutation = mutation; model.mutationOnRead = model.groupReads + 2
            #expect(try await approve(session, account, client, review).state == "failed" && model.writes.isEmpty)
            await #expect(throws: PublishFailure.used) { try await approve(session, account, client, review) }
        } }
    }
    @Test func settingsGuardChecksOnlyEditedFieldsAndBothLimitFields() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), model = SyntheticTestFlightGroups(), host = "group-unrelated-setting.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        StubProtocol.handle(host) { model.handle($0) }
        let review = try await session.preparePublishing(account: account, request: request(account, "rename-group"), client: client)
        model.mutation = "feedback"; model.mutationOnRead = model.groupReads + 2
        #expect(try await approve(session, account, client, review).state == "complete" && model.writes.count == 1)
    }
    @Test func existingAccountWideTesterIsAssignedWithoutCreatingADuplicate() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), model = SyntheticTestFlightGroups(), host = "group-global-tester.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        model.globalTester = SyntheticTestFlightGroups.tester("tester-global", email: "new@example.com")
        StubProtocol.handle(host) { model.handle($0) }
        let review = try await session.preparePublishing(account: account, request: request(account, "invite-tester"), client: client)
        #expect(review.steps[0].before == "Tester exists at Apple, outside this app" && review.steps[0].guardValue?["testerDigest"] != nil)
        #expect(try await approve(session, account, client, review).state == "complete")
        #expect(model.writes.count == 1 && model.writes[0].1 == "/v1/betaGroups/group-1/relationships/betaTesters")
    }
    @Test func changedGlobalTesterIdentityIsRejectedAtTheFinalCheck() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), model = SyntheticTestFlightGroups(), host = "group-global-identity.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        model.globalTester = SyntheticTestFlightGroups.tester("tester-global", email: "new@example.com")
        StubProtocol.handle(host) { model.handle($0) }
        let review = try await session.preparePublishing(account: account, request: request(account, "invite-tester"), client: client)
        model.mutation = "global-id"; model.mutationOnRead = model.groupReads + 2
        #expect(try await approve(session, account, client, review).state == "failed" && model.writes.isEmpty)
    }
    @Test func internalGroupAddsRequireEligibleTeamRoleAndAppAccess() async throws {
        for action in ["invite-tester", "add-tester"] { for mutation in ["roles", "visible"] {
            let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
            let account = try #require(try await session.accounts().first), model = SyntheticTestFlightGroups(), host = "group-internal-\(action)-\(mutation).appstoreconnect.test", client = try PublishingTests().client(account, host: host)
            model.setGroup("isInternalGroup", true); StubProtocol.handle(host) { model.handle($0) }
            let review = try await session.preparePublishing(account: account, request: request(account, action), client: client)
            model.mutation = mutation; model.mutationOnRead = model.groupReads + 2
            #expect(try await approve(session, account, client, review).state == "failed" && model.writes.isEmpty)
        } }
    }
    @Test func invalidInternalTeamUsersFailDuringPreparation() async throws {
        for failure in ["roles", "visible", "duplicate"] {
            let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
            let account = try #require(try await session.accounts().first), model = SyntheticTestFlightGroups(), host = "group-invalid-internal-\(failure).appstoreconnect.test", client = try PublishingTests().client(account, host: host)
            model.setGroup("isInternalGroup", true)
            if failure == "duplicate" { model.duplicateUser = true } else { model.mutation = failure; model.mutate() }
            StubProtocol.handle(host) { model.handle($0) }
            await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: request(account, "invite-tester"), client: client) }
            #expect(model.writes.isEmpty)
        }
    }
    @Test func initialBuildEligibilityAndUnchangedMembershipsAreHandledExplicitly() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), model = SyntheticTestFlightGroups(), host = "group-build-eligibility.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        StubProtocol.handle(host) { model.handle($0) }
        for (key, value) in [("expired", true as Any), ("processingState", "PROCESSING" as Any), ("buildAudienceType", "INTERNAL_ONLY" as Any)] {
            let original = model.builds[1]; model.setBuild(key, value)
            await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: request(account, "add-build"), client: client) }
            model.builds[1] = original
        }
        model.setGroup("isInternalGroup", true); model.setBuild("buildAudienceType", "INTERNAL_ONLY")
        let internalBuild = try await session.preparePublishing(account: account, request: request(account, "add-build"), client: client)
        #expect(try await approve(session, account, client, internalBuild).state == "complete")
        #expect(try await session.preparePublishing(account: account, request: request(account, "add-build"), client: client).steps.isEmpty)
        var tester = request(account, "add-tester"); tester.testerId = "tester-1"
        #expect(try await session.preparePublishing(account: account, request: tester, client: client).steps.isEmpty)
        #expect(model.writes.count == 1)
    }
    @Test func membershipReadsResolveOmittedOwnershipButRejectExplicitInvalidOwners() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), model = SyntheticTestFlightGroups(), host = "group-members-ownership.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        StubProtocol.handle(host) { model.handle($0) }; model.groupOwner = "omitted"; model.buildOwner = "omitted"; model.testerOwner = "omitted"
        let members = try await session.groupMembers(appId: app, groupId: "group-1", client: client)
        #expect(members.builds == ["build-7"] && members.testers.count == 1)
        for invalid in ["null", "foreign"] {
            model.testerOwner = invalid
            await #expect(throws: PublishFailure.self) { try await session.groupMembers(appId: app, groupId: "group-1", client: client) }
        }
        model.testerOwner = "omitted"; model.resolvedOwner = "1000000002"
        await #expect(throws: PublishFailure.self) { try await session.groupMembers(appId: app, groupId: "group-1", client: client) }
        #expect(model.writes.isEmpty)
    }
    @Test func requestValidationUsesWebTextLengthsAndRejectsFractionalLimits() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), model = SyntheticTestFlightGroups(), host = "group-invalid-input.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        StubProtocol.handle(host) { model.handle($0) }
        #expect(try TestFlightGroups.name("\u{feff}Synthetic\u{feff}") == "Synthetic")
        #expect(try TestFlightGroups.name(String(repeating: "😀", count: 50)).utf16.count == 100)
        for name in [String(repeating: "😀", count: 51), "Synthetic\nname", "Synthetic\u{7f}", "\u{feff}"] { #expect(throws: PublishFailure.self) { try TestFlightGroups.name(name) } }
        for limit in [0.5, -1, 10_001] {
            var value = request(account, "set-group-setting"); value.groupSettingValue = .number(limit)
            await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: value, client: client) }
        }
        var normalized = request(account, "invite-tester"); normalized.testerEmail = "\u{feff} NEW@EXAMPLE.COM \u{feff}"
        #expect(try normalized.validated().testerEmail == "new@example.com")
        #expect(model.writes.isEmpty)
    }
    @Test func forgedPayloadsAndLegacyGroupGuardsCannotReachApple() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), model = SyntheticTestFlightGroups(), host = "group-forged-payload.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        StubProtocol.handle(host) { model.handle($0) }
        let rename = try await session.preparePublishing(account: account, request: request(account, "rename-group"), client: client).steps[0]
        var bodies = [JSONText.object([("data", rename.body!["data"]!), ("unexpected", .bool(true))]), .object([("data", .object([("type", .string("betaGroups")), ("id", .string("group-1")), ("attributes", .object([("name", .string("\ninvalid"))]))]))])]
        bodies.append(.object([("data", .object([("type", .string("betaGroups")), ("id", .string("group-1")), ("attributes", .object([("publicLinkLimitEnabled", .bool(true))]))]))]))
        for body in bodies { await #expect(throws: PublishFailure.self) { try await session.verifyTestFlightGroup(method: "PATCH", parts: ["betaGroups", "group-1"], body: body, guardValue: rename.guardValue, appId: app, client: client) } }
        let link = WorkspaceSession.linkages("builds", "build-8")
        await #expect(throws: PublishFailure.self) { try await session.verifyWrite(method: "POST", path: "/v1/betaGroups/group-1/relationships/builds", body: link, guardValue: .object([("kind", .string("group-builds")), ("digest", .string(String(repeating: "0", count: 64)))]), appId: app, client: client) }
        await #expect(throws: PublishFailure.self) { try await session.verifyTestFlightGroup(method: "DELETE", parts: ["betaGroups", "group-1"], body: .object([("data", .null)]), guardValue: .object([("kind", .string("group-members")), ("digest", .string(String(repeating: "0", count: 64)))]), appId: app, client: client) }
        #expect(model.writes.isEmpty)
    }
}
