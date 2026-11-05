import Foundation
import Testing
@testable import StorebenchCore

final class SyntheticAppTesterAccess: @unchecked Sendable {
    let lock = NSLock(), apple = SyntheticApple()
    var testers: [[String: Any]], groups: [[String: Any]], builds: [[String: Any]]
    var memberships = ["group-1", "foreign-group"], assignments = ["build-7", "foreign-build"]
    var testerOwner = "owned", groupOwner = "owned", buildOwner = "owned", resolvedOwner = "1000000001"
    var testerReads = 0, mutationOnRead: Int?, mutation = "email", memberType = "betaGroups", assignmentType = "builds"
    var writes: [(String, String, [String: Any])] = []
    init() {
        var recipient = SyntheticTestFlightGroups.tester("tester-1")
        recipient["attributes"] = ["email": "tester-1@example.com", "state": "INVITED", "inviteType": "EMAIL"]
        recipient["relationships"] = ["apps": ["data": [["type": "apps", "id": "1000000001"], ["type": "apps", "id": "1000000002"]]]]
        testers = [recipient, SyntheticTestFlightGroups.tester("tester-unrelated")]
        groups = [SyntheticTestFlightGroups.group("group-1"), SyntheticTestFlightGroups.group("group-2")]
        builds = []
        builds = apple.builds
        var second = builds[0]; second["id"] = "build-8"
        var attributes = second["attributes"] as! [String: Any]; attributes["version"] = "8"; second["attributes"] = attributes; builds.append(second)
    }
    func recipient(_ field: String, _ value: Any) { var fields = testers[0]["attributes"] as! [String: Any]; fields[field] = value; testers[0]["attributes"] = fields }
    func mutate() {
        switch mutation {
        case "email": recipient("email", "changed@example.com")
        case "state": recipient("state", "INSTALLED")
        case "invite-type": recipient("inviteType", "PUBLIC_LINK")
        case "invite-type-other": recipient("inviteType", "OTHER_EMAIL")
        case "member": memberships.append("group-2")
        case "assignment": assignments.append("build-8")
        case "group-name": var fields = groups[0]["attributes"] as! [String: Any]; fields["name"] = "Changed synthetic group"; groups[0]["attributes"] = fields
        case "build-version": var fields = builds[0]["attributes"] as! [String: Any]; fields["version"] = "Changed synthetic version"; builds[0]["attributes"] = fields
        case "unrelated": var fields = testers[1]["attributes"] as! [String: Any]; fields["email"] = "unrelated-changed@example.com"; testers[1]["attributes"] = fields
        case "foreign-access": memberships.append("foreign-group-two"); assignments.append("foreign-build-two")
        case "foreign": testerOwner = "foreign"
        default: testers.removeFirst()
        }
    }
    func ownership(_ items: [[String: Any]], relation: String, mode: String) -> [[String: Any]] {
        items.map { original in
            var item = original
            if mode == "omitted" { item.removeValue(forKey: "relationships") }
            if mode == "null" { item["relationships"] = [relation: ["data": NSNull()]] }
            if mode == "foreign" { let value: Any = relation == "apps" ? [["type": "apps", "id": "1000000002"]] : ["type": "apps", "id": "1000000002"]; item["relationships"] = [relation: ["data": value]] }
            return item
        }
    }
    func handle(_ request: URLRequest) -> (Int, [String: String], Data) {
        lock.withLock {
            let path = request.url!.path, method = request.httpMethod ?? "GET", query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
            if method != "GET" {
                guard let body = (try? JSONSerialization.jsonObject(with: apple.body(request))) as? [String: Any], body.count == 1 else { return (400, [:], Data()) }
                if method == "POST", path == "/v1/betaTesterInvitations", let data = body["data"] as? [String: Any], data.count == 2, data["type"] as? String == "betaTesterInvitations",
                   let relations = data["relationships"] as? [String: Any], relations.count == 2, let recipient = relations["betaTester"] as? [String: Any], let link = recipient["data"] as? [String: Any], link["id"] as? String == "tester-1",
                   let app = relations["app"] as? [String: Any], let owner = app["data"] as? [String: Any], owner["id"] as? String == "1000000001" {
                    writes.append((method, path, body)); return apple.page(["type": "betaTesterInvitations", "id": "invitation-synthetic"])
                }
                if method == "DELETE", path == "/v1/apps/1000000001/relationships/betaTesters", let data = body["data"] as? [[String: Any]], data.count == 1, data[0].count == 2, data[0]["type"] as? String == "betaTesters", data[0]["id"] as? String == "tester-1" {
                    writes.append((method, path, body)); memberships.removeAll { $0.hasPrefix("group-") }; assignments.removeAll { $0.hasPrefix("build-") }
                    testers.removeFirst(); return (204, [:], Data())
                }
                return (400, [:], Data())
            }
            switch path {
            case "/v1/apps/1000000001": return apple.page(["type": "apps", "id": "1000000001", "attributes": ["name": "Synthetic app"]])
            case "/v1/betaTesters":
                guard query.count == 2, value("filter[apps]") == "1000000001", value("limit") == "200" else { return (400, [:], Data()) }
                testerReads += 1; if testerReads == mutationOnRead { mutate() }; return apple.page(ownership(testers, relation: "apps", mode: testerOwner))
            case "/v1/betaGroups":
                guard query.count == 3, value("filter[app]") == "1000000001", value("include") == "app", value("limit") == "200" else { return (400, [:], Data()) }
                return apple.page(ownership(groups, relation: "app", mode: groupOwner))
            case "/v1/apps/1000000001/builds": return apple.page(ownership(builds, relation: "app", mode: buildOwner))
            case "/v1/betaTesters/tester-1/betaGroups":
                guard query.count == 1, value("limit") == "200" else { return (400, [:], Data()) }
                return apple.page(memberships.map { ["type": memberType, "id": $0] })
            case "/v1/betaTesters/tester-1/builds":
                guard query.count == 1, value("limit") == "200" else { return (400, [:], Data()) }
                return apple.page(assignments.map { ["type": assignmentType, "id": $0] })
            default:
                for item in testers where path == "/v1/betaTesters/\(item["id"] as! String)/relationships/apps" { return apple.page([["type": "apps", "id": resolvedOwner]]) }
                for item in groups + builds where path == "/v1/\(item["type"] as! String)/\(item["id"] as! String)/relationships/app" { return apple.page(["type": "apps", "id": resolvedOwner]) }
                return (404, [:], Data())
            }
        }
    }
}

final class SyntheticTesterPage: @unchecked Sendable {
    let lock = NSLock(), apple = SyntheticApple()
    var items = [SyntheticTestFlightGroups.tester("tester-1")]
    var next: String? = "?cursor=synthetic-next"
    var resolveOwner = "1000000001"
    var requests: [URLRequest] = []
    func handle(_ request: URLRequest) -> (Int, [String: String], Data) {
        lock.withLock {
            requests.append(request)
            guard request.httpMethod == "GET" else { return (400, [:], Data()) }
            if request.url!.path.hasSuffix("/relationships/apps") { return apple.page([["type": "apps", "id": resolveOwner]]) }
            guard request.url!.path == "/v1/betaTesters" else { return (404, [:], Data()) }
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard query.first(where: { $0.name == "filter[apps]" })?.value == "1000000001", query.first(where: { $0.name == "limit" })?.value == "200" else { return (400, [:], Data()) }
            let cursor = query.first { $0.name == "cursor" }?.value
            let body: [String: Any] = ["data": cursor == "synthetic-next" ? [] : items, "links": cursor == "synthetic-next" || next == nil ? [:] : ["next": next!]]
            return (200, [:], try! JSONSerialization.data(withJSONObject: body))
        }
    }
}

@Suite(.serialized) struct TestFlightAppTesterTests {
    init() throws { _ = try TestIsolation.require() }
    let app = "1000000001"
    func resources(_ value: JSONText) throws -> [AppStoreConnectClient.Resource] { try JSONDecoder().decode([AppStoreConnectClient.Resource].self, from: value.data) }
    func resource(_ value: JSONText) throws -> AppStoreConnectClient.Resource { try JSONDecoder().decode(AppStoreConnectClient.Resource.self, from: value.data) }
    func request(_ account: Account, invitation: Bool) -> PublishRequest {
        var value = PublishRequest(accountId: account.id, appId: app, scope: .testflight); value.testflightAction = invitation ? "send-invitation" : "remove-app-tester"; value.testerId = "tester-1"; return value
    }
    func approve(_ session: WorkspaceSession, _ account: Account, _ client: AppStoreConnectClient, _ review: PublishReview) async throws -> PublishReview {
        try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: client)
    }
    @Test func invitationEligibilityAndRemovalSnapshotsMatchWebContracts() throws {
        let vector = try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/testflight-app-testers.json")))
        guard case .array(let invitationCases)? = vector["invitationCases"], case .array(let removalCases)? = vector["removalCases"] else { throw JSONText.ParseFailure.invalid }
        for value in invitationCases {
            let tester = try resource(#require(value["tester"]))
            #expect(TestFlightAppTesters.canSendInvitation(tester) == (value["eligible"] == .bool(true)))
            if value["eligible"] == .bool(true) { #expect(try TestFlightAppTesters.invitationDigest(tester, appId: app) == value["digest"]?.text) }
            else { #expect(throws: PublishFailure.self) { try TestFlightAppTesters.invitationDigest(tester, appId: app) } }
        }
        for value in removalCases {
            func calculate() throws -> TestFlightAppTesters.RemovalReview {
                try TestFlightAppTesters.removalReview(appId: app, tester: resource(#require(value["tester"])), appGroups: resources(#require(value["appGroups"])), appBuilds: resources(#require(value["appBuilds"])),
                                                      testerGroups: resources(#require(value["testerGroups"])), testerBuilds: resources(#require(value["testerBuilds"])))
            }
            if value["valid"] == .bool(true) { let result = try calculate(); #expect(result.digest == value["digest"]?.text && result.before == value["before"]?.text) }
            else { #expect(throws: PublishFailure.self) { try calculate() } }
        }
        #expect(invitationCases.count == 175 && removalCases.count == 18)
        #expect(removalCases[0]["digest"] == removalCases[1]["digest"] && removalCases[2]["digest"] == removalCases[3]["digest"])
    }
    @Test func nativeTesterModelHidesPublicLinkAndAcceptedInvitationActions() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), model = SyntheticAppTesterAccess(), host = "app-tester-view-model.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        StubProtocol.handle(host) { model.handle($0) }
        #expect(try await session.allTesters(appId: app, client: client).first(where: { $0.id == "tester-1" })?.canSendInvitation == true)
        model.recipient("inviteType", "PUBLIC_LINK")
        let publicLink = try #require(try await session.allTesters(appId: app, client: client).first(where: { $0.id == "tester-1" }))
        #expect(publicLink.inviteType == "PUBLIC_LINK" && !publicLink.canSendInvitation)
        model.recipient("inviteType", "EMAIL"); model.recipient("state", "INSTALLED")
        #expect(try await session.allTesters(appId: app, client: client).first(where: { $0.id == "tester-1" })?.canSendInvitation == false)
    }
    @Test func sendAndResendPinTheExactRecipientAndConsumeOneApproval() async throws {
        for state in ["INVITED", "NOT_INVITED"] {
            let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
            let account = try #require(try await session.accounts().first), model = SyntheticAppTesterAccess(), host = "app-tester-invitation-\(state.lowercased()).appstoreconnect.test", client = try PublishingTests().client(account, host: host)
            model.recipient("state", state); StubProtocol.handle(host) { model.handle($0) }
            let review = try await session.preparePublishing(account: account, request: request(account, invitation: true), client: client)
            #expect(review.steps.count == 1 && model.writes.isEmpty && review.steps[0].before?.contains("tester-1@example.com · tester-1") == true)
            #expect(try await approve(session, account, client, review).state == "complete" && model.writes.count == 1)
            await #expect(throws: PublishFailure.used) { try await approve(session, account, client, review) }
        }
    }
    @Test func removalReviewsEveryAffectedAppAssignmentAndPreservesOtherApps() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), model = SyntheticAppTesterAccess(), host = "app-tester-removal.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        StubProtocol.handle(host) { model.handle($0) }
        let review = try await session.preparePublishing(account: account, request: request(account, invitation: false), client: client)
        #expect(review.steps[0].before?.contains("Groups in this app (1)") == true && review.steps[0].before?.contains("Direct builds in this app (1)") == true)
        #expect(review.steps[0].before?.contains("foreign-") == false && model.writes.isEmpty)
        #expect(try await approve(session, account, client, review).state == "complete")
        #expect(model.memberships == ["foreign-group"] && model.assignments == ["foreign-build"] && model.writes.count == 1)
        #expect(model.writes[0].1 == "/v1/apps/1000000001/relationships/betaTesters")
        await #expect(throws: PublishFailure.used) { try await approve(session, account, client, review) }
    }
    @Test func lateRecipientAndReviewedAccessChangesStopTheWrite() async throws {
        for invitation in [false, true] {
            let mutations = invitation ? ["email", "state", "invite-type", "invite-type-other", "foreign", "removed"] : ["email", "member", "assignment", "group-name", "build-version", "foreign", "removed"]
            for mutation in mutations {
                let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
                let account = try #require(try await session.accounts().first), model = SyntheticAppTesterAccess(), host = "app-tester-race-\(invitation)-\(mutation).appstoreconnect.test", client = try PublishingTests().client(account, host: host)
                StubProtocol.handle(host) { model.handle($0) }
                let review = try await session.preparePublishing(account: account, request: request(account, invitation: invitation), client: client)
                model.mutation = mutation; model.mutationOnRead = model.testerReads + 2
                #expect(try await approve(session, account, client, review).state == "failed" && model.writes.isEmpty)
                await #expect(throws: PublishFailure.used) { try await approve(session, account, client, review) }
            }
        }
    }
    @Test func accessChangedAtApprovalRequiresANewReview() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), model = SyntheticAppTesterAccess(), host = "app-tester-review-conflict.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        StubProtocol.handle(host) { model.handle($0) }
        let review = try await session.preparePublishing(account: account, request: request(account, invitation: false), client: client)
        model.mutation = "member"; model.mutationOnRead = model.testerReads + 1
        await #expect(throws: PublishFailure.conflict) { try await approve(session, account, client, review) }
        #expect(model.writes.isEmpty)
    }
    @Test func unrelatedTestersAndForeignAppAssignmentsDoNotAlterTheFinalGuard() async throws {
        for invitation in [false, true] {
            let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
            let account = try #require(try await session.accounts().first), model = SyntheticAppTesterAccess(), host = "app-tester-unrelated-\(invitation).appstoreconnect.test", client = try PublishingTests().client(account, host: host)
            StubProtocol.handle(host) { model.handle($0) }
            let review = try await session.preparePublishing(account: account, request: request(account, invitation: invitation), client: client)
            model.mutation = invitation ? "unrelated" : "foreign-access"; model.mutationOnRead = model.testerReads + 2
            #expect(try await approve(session, account, client, review).state == "complete" && model.writes.count == 1)
        }
    }
    @Test func invalidRecipientAndAmbiguousMembershipDataFailClosed() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), model = SyntheticAppTesterAccess(), host = "app-tester-invalid-data.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        StubProtocol.handle(host) { model.handle($0) }
        for email in ["", "invalid", "tester@example", String(repeating: "a", count: 255) + "@example.com"] {
            model.recipient("email", email)
            await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: request(account, invitation: true), client: client) }
        }
        model.recipient("email", "tester-1@example.com"); model.recipient("inviteType", "PUBLIC_LINK")
        await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: request(account, invitation: true), client: client) }
        model.recipient("inviteType", "EMAIL"); model.memberships.append("group-1")
        await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: request(account, invitation: false), client: client) }
        model.memberships = ["group-1"]; model.assignments = ["build-7", "build-7"]
        await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: request(account, invitation: false), client: client) }
        model.assignments = ["build-7"]; model.assignmentType = "apps"
        await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: request(account, invitation: false), client: client) }
        #expect(model.writes.isEmpty)
    }
    @Test func omittedOwnersResolveButExplicitForeignAndNullOwnersCannotFallback() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), model = SyntheticAppTesterAccess(), host = "app-tester-owner-resolution.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        StubProtocol.handle(host) { model.handle($0) }; model.testerOwner = "omitted"; model.groupOwner = "omitted"; model.buildOwner = "omitted"
        let valid = try await session.preparePublishing(account: account, request: request(account, invitation: false), client: client)
        #expect(valid.steps.count == 1)
        for mode in ["null", "foreign"] {
            model.testerOwner = mode
            await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: request(account, invitation: false), client: client) }
        }
        model.testerOwner = "omitted"; model.resolvedOwner = "1000000002"
        await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: request(account, invitation: false), client: client) }
        #expect(model.writes.isEmpty)
    }
    @Test func extraFieldsForeignTargetsAndLegacyGuardsAreRejectedBeforeWriting() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), model = SyntheticAppTesterAccess(), host = "app-tester-malformed-write.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        StubProtocol.handle(host) { model.handle($0) }
        for invitation in [false, true] {
            let review = try await session.preparePublishing(account: account, request: request(account, invitation: invitation), client: client), step = review.steps[0]
            let parts = invitation ? ["betaTesterInvitations"] : ["apps", app, "relationships", "betaTesters"], method = invitation ? "POST" : "DELETE"
            let extra = JSONText.object([("data", step.body!["data"]!), ("extra", .bool(true))])
            await #expect(throws: PublishFailure.self) { try await session.verifyAppTesterChange(method: method, parts: parts, body: extra, guardValue: step.guardValue, appId: app, client: client) }
            let legacy = JSONText.object([("kind", .string("app-testers")), ("digest", step.guardValue!["digest"]!)])
            await #expect(throws: PublishFailure.self) { try await session.verifyWrite(method: method, path: "/v1/" + parts.joined(separator: "/"), body: step.body, guardValue: legacy, appId: app, client: client) }
            if !invitation {
                let duplicate = JSONText.object([("data", .array([.object([("type", .string("betaTesters")), ("id", .string("tester-1"))]), .object([("type", .string("betaTesters")), ("id", .string("tester-1"))])]))])
                await #expect(throws: PublishFailure.self) { try await session.verifyAppTesterChange(method: method, parts: parts, body: duplicate, guardValue: step.guardValue, appId: app, client: client) }
                await #expect(throws: PublishFailure.self) { try await session.verifyAppTesterChange(method: method, parts: ["apps", "1000000002", "relationships", "betaTesters"], body: step.body, guardValue: step.guardValue, appId: app, client: client) }
            }
        }
        #expect(model.writes.isEmpty)
    }
    @Test func pagedTesterSearchKeepsTheAppEmailAndOpaqueCursorPinned() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), model = SyntheticTesterPage(), host = "app-tester-search-page.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        StubProtocol.handle(host) { model.handle($0) }
        let first = try await session.testFlightTesterPage(appId: app, email: "\u{feff} TESTER-1@EXAMPLE.COM \u{feff}", client: client)
        #expect(first.testers.map(\.id) == ["tester-1"] && first.next == "synthetic-next" && model.requests.count == 1)
        let second = try await session.testFlightTesterPage(appId: app, email: "tester-1@example.com", cursor: first.next, client: client)
        #expect(second.testers.isEmpty && second.next == nil && model.requests.count == 2)
        for request in model.requests {
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            #expect(request.httpMethod == "GET" && query.first(where: { $0.name == "filter[email]" })?.value == "tester-1@example.com")
            #expect(query.count == (request == model.requests.first ? 3 : 4))
        }
        model.next = "?cursor=synthetic%2Fopaque%2B%25"
        #expect(try await session.testFlightTesterPage(appId: app, client: client).next == "synthetic/opaque+%")
        #expect(try TestFlightAppTesters.emailFilter("\u{feff} \u{feff}").isEmpty)
        let clear = try #require(model.requests.last), query = URLComponents(url: clear.url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(!query.contains { $0.name == "filter[email]" })
    }
    @Test func invalidSearchAndCursorInputsFailBeforeAnyRequest() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), model = SyntheticTesterPage(), host = "app-tester-invalid-page-input.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        StubProtocol.handle(host) { model.handle($0) }
        for email in ["invalid", "tester@example", String(repeating: "a", count: 255) + "@example.com"] { await #expect(throws: PublishFailure.self) { try await session.testFlightTesterPage(appId: app, email: email, client: client) } }
        for cursor in ["", "\n", "synthetic\u{7f}", String(repeating: "a", count: 2049)] { await #expect(throws: AppStoreConnectClient.Failure.invalidPagination) { try await session.testFlightTesterPage(appId: app, cursor: cursor, client: client) } }
        await #expect(throws: TestFlightFeedback.Failure.selection) { try await session.testFlightTesterPage(appId: "999", client: client) }
        #expect(model.requests.isEmpty)
    }
    @Test func testerPagesRejectOversizeDuplicateForeignAndMismatchedFilterData() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), model = SyntheticTesterPage(), host = "app-tester-page-data.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        StubProtocol.handle(host) { model.handle($0) }; model.next = nil
        model.items = (0..<201).map { SyntheticTestFlightGroups.tester("tester-\($0)") }
        await #expect(throws: AppStoreConnectClient.Failure.invalidPagination) { try await session.testFlightTesterPage(appId: app, client: client) }
        model.items = [SyntheticTestFlightGroups.tester("tester-1"), SyntheticTestFlightGroups.tester("tester-1")]
        await #expect(throws: PublishFailure.self) { try await session.testFlightTesterPage(appId: app, client: client) }
        for invalid in [NSNull() as Any, [["type": "apps", "id": "1000000002"]] as Any] {
            var item = SyntheticTestFlightGroups.tester("tester-1"); item["relationships"] = ["apps": ["data": invalid]]; model.items = [item]
            await #expect(throws: PublishFailure.self) { try await session.testFlightTesterPage(appId: app, client: client) }
        }
        var omitted = SyntheticTestFlightGroups.tester("tester-1"); omitted.removeValue(forKey: "relationships"); model.items = [omitted]
        #expect(try await session.testFlightTesterPage(appId: app, client: client).testers.count == 1)
        model.resolveOwner = "1000000002"
        await #expect(throws: PublishFailure.self) { try await session.testFlightTesterPage(appId: app, client: client) }
        model.items = [SyntheticTestFlightGroups.tester("tester-1")]
        await #expect(throws: PublishFailure.self) { try await session.testFlightTesterPage(appId: app, email: "other@example.com", client: client) }
        #expect(model.requests.allSatisfy { $0.httpMethod == "GET" })
    }
    @Test func testerPaginationRejectsChangedScopeRepeatedCursorsAndEmptyContinuationPages() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), model = SyntheticTesterPage(), host = "app-tester-page-cursors.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        StubProtocol.handle(host) { model.handle($0) }
        for next in ["https://example.invalid/v1/betaTesters?cursor=other", "?filter%5Bapps%5D=1000000002&cursor=other", "?filter%5Bemail%5D=other%40example.com&cursor=other", "?limit=201&cursor=other",
                     "?cursor=other&cursor=duplicate", "?cursor=%0a", "?cursor=current", "?cursor=other#fragment", "/v1/betaGroups?cursor=other"] {
            model.next = next
            await #expect(throws: AppStoreConnectClient.Failure.invalidPagination) { try await session.testFlightTesterPage(appId: app, email: "tester-1@example.com", cursor: "current", client: client) }
        }
        model.next = "?cursor=other"; model.items = []
        await #expect(throws: AppStoreConnectClient.Failure.invalidPagination) { try await session.testFlightTesterPage(appId: app, client: client) }
        #expect(model.requests.allSatisfy { $0.httpMethod == "GET" })
    }
    @Test func testerPageRejectsCredentialsChangedDuringTheRead() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), model = SyntheticTesterPage(), host = "app-tester-page-account-change.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        model.next = nil
        StubProtocol.handle(host) { request in
            let result = model.handle(request)
            let store = try! EncryptedDocumentStore(url: EncryptedDocumentStore.databaseURL(root: root), key: Data(0..<32), writable: true)
            try! store.transaction { read in
                let document = try read("accounts", "all")!, items = WorkspaceSession.items(try JSONText.parse(document.payload))
                return [.put(namespace: "accounts", key: "all", json: JSONText.array(items.map { $0["id"]?.text == account.id ? $0.setting("keyId", .string("SAMPLE0002")) : $0 }).data)]
            }
            return result
        }
        await #expect(throws: PublishFailure.self) { try await session.testFlightTesterPage(appId: app, client: client) }
        #expect(model.requests.count == 1 && model.requests[0].httpMethod == "GET")
    }
}
