import Foundation
import Testing
@testable import StorebenchCore

final class SyntheticBuildAccess: @unchecked Sendable {
    let apple = SyntheticApple(), lock = NSLock()
    var assigned: [String] = []
    var external: [[String: Any]] = []
    var automatic = false
    var betaState = "READY_FOR_BETA_SUBMISSION"
    var foreignOwner = false
    var ambiguousLookup = false
    var internalRole = "DEVELOPER"
    var visible = true
    var allVisible = false
    var membershipReads = 0
    var joinOnRead: Int?
    var detailReads = 0
    var approveOnRead: Int?
    var writes: [(String, String)] = []
    init() { apple.groupTesters = ["group-1": []] }
    func detail() -> [String: Any] {
        ["type": "buildBetaDetails", "id": "detail-7", "attributes": ["autoNotifyEnabled": automatic, "externalBuildState": betaState],
         "relationships": ["build": ["data": ["type": "builds", "id": "build-7"]]]]
    }
    func handle(_ request: URLRequest) -> (Int, [String: String], Data) {
        lock.withLock {
            let path = request.url!.path, method = request.httpMethod ?? "GET", query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
            if method != "GET" {
                let body = try! JSONSerialization.jsonObject(with: apple.body(request)) as! [String: Any]
                if path == "/v1/builds/build-7/relationships/individualTesters" {
                    let ids = (body["data"] as! [[String: Any]]).map { $0["id"] as! String }
                    if method == "POST" { assigned += ids; for tester in external where ids.contains(tester["id"] as! String) { apple.testers.append(tester) }; external.removeAll { ids.contains($0["id"] as! String) } }
                    else { assigned.removeAll { ids.contains($0) } }
                    writes.append((method, path)); return (204, [:], Data())
                }
                if path == "/v1/betaTesters", let item = body["data"] as? [String: Any], let relationships = item["relationships"] as? [String: Any], relationships["builds"] != nil {
                    let tester: [String: Any] = ["type": "betaTesters", "id": "tester-created", "attributes": ["email": (item["attributes"] as! [String: Any])["email"]!, "state": "INVITED"]]
                    apple.testers.append(tester); assigned.append("tester-created"); writes.append((method, path)); return apple.page(tester)
                }
                if path == "/v1/buildBetaDetails/detail-7" {
                    let item = body["data"] as! [String: Any]; automatic = (item["attributes"] as! [String: Any])["autoNotifyEnabled"] as! Bool
                    writes.append((method, path)); return apple.page(detail())
                }
                return (400, [:], Data())
            }
            switch path {
            case "/v1/builds":
                return (200, [:], try! JSONSerialization.data(withJSONObject: ["data": apple.builds, "included": [detail(), ["type": "preReleaseVersions", "id": "pre-1", "attributes": ["version": "2.0", "platform": "IOS"]]], "links": [:]]))
            case "/v1/builds/build-7/individualTesters": return apple.page(apple.testers.filter { assigned.contains($0["id"] as! String) })
            case "/v1/builds/build-7/buildBetaDetail", "/v1/buildBetaDetails/detail-7":
                detailReads += 1
                if detailReads == approveOnRead { betaState = "READY_FOR_BETA_TESTING" }
                return apple.page(detail())
            case "/v1/buildBetaDetails/detail-7/relationships/build": return apple.page(["type": "builds", "id": "build-7"])
            case "/v1/betaTesters":
                if let email = query.first(where: { $0.name == "filter[email]" })?.value {
                    let values = (apple.testers + external).filter { (($0["attributes"] as! [String: Any])["email"] as! String).lowercased() == email.lowercased() }
                    return apple.page(ambiguousLookup && !values.isEmpty ? values + values : values)
                }
                return apple.page(apple.testers)
            case let target where target.hasPrefix("/v1/betaTesters/") && target.hasSuffix("/relationships/apps"):
                return apple.page([["type": "apps", "id": foreignOwner ? "1000000002" : "1000000001"]])
            case let target where target.hasPrefix("/v1/betaTesters/") && target.hasSuffix("/betaGroups"):
                membershipReads += 1
                let id = target.split(separator: "/")[2].description
                if membershipReads == joinOnRead { apple.groupTesters["group-1", default: []].append(id) }
                return apple.page(apple.groups.filter { (apple.groupTesters[$0["id"] as! String] ?? []).contains(id) })
            case "/v1/users": return apple.page([["type": "users", "id": "user-synthetic", "attributes": ["username": "tester@example.com", "roles": [internalRole], "allAppsVisible": allVisible]]])
            case "/v1/users/user-synthetic/visibleApps": return apple.page(visible ? [["type": "apps", "id": "1000000001"]] : [])
            default: return apple.handle(request)
            }
        }
    }
}

@Suite(.serialized) struct TestFlightAccessTests {
    init() throws { _ = try TestIsolation.require() }
    let app = "1000000001"
    func vector() throws -> JSONText { try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/testflight-access.json"))) }
    func resource(_ value: JSONText) throws -> AppStoreConnectClient.Resource { try JSONDecoder().decode(AppStoreConnectClient.Resource.self, from: value.data) }
    func request(_ account: Account, _ action: String, tester: String? = nil, email: String? = nil, automatic: Bool? = nil) -> PublishRequest {
        var value = PublishRequest(accountId: account.id, appId: app, scope: .testflight, buildId: "build-7")
        value.testflightAction = action; value.testerId = tester; value.testerEmail = email; value.autoNotifyEnabled = automatic; return value
    }
    func prepare(_ session: WorkspaceSession, _ account: Account, _ client: AppStoreConnectClient, _ action: String, tester: String? = nil, email: String? = nil, automatic: Bool? = nil) async throws -> PublishReview {
        try await session.preparePublishing(account: account, request: request(account, action, tester: tester, email: email, automatic: automatic), client: client)
    }
    func approve(_ session: WorkspaceSession, _ account: Account, _ client: AppStoreConnectClient, _ review: PublishReview) async throws -> PublishReview {
        try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: client)
    }

    @Test func accessSnapshotsAndNotificationEligibilityMatchWebContracts() throws {
        let vector = try vector(), build = try resource(#require(vector["build"])), tester = try resource(#require(vector["tester"]))
        guard case .array(let emails)? = vector["emails"] else { throw JSONText.ParseFailure.invalid }
        for value in emails { #expect(TestFlightAccess.validEmail(try #require(value["email"]?.text)) == (value["valid"] == .bool(true))) }
        #expect(try TestFlightAccess.individualDigest(build, testers: [], testerId: tester.id) == vector["absent"]?.text)
        #expect(try TestFlightAccess.individualDigest(build, testers: [tester], testerId: tester.id) == vector["present"]?.text)
        #expect(TestFlightAccess.identityDigest(tester) == vector["identity"]?.text)
        #expect(try TestFlightAccess.creationDigest(build, appId: app) == vector["creation"]?.text)
        #expect(throws: PublishFailure.self) { try TestFlightAccess.individualDigest(build, testers: [tester, tester], testerId: tester.id) }
        guard case .array(let cases)? = vector["automaticCases"], case .array(let links)? = vector["linkageCases"] else { throw JSONText.ParseFailure.invalid }
        #expect(cases.count == 144)
        for value in cases {
            let candidate = try resource(#require(value["build"])), detail = try resource(#require(value["detail"])), eligible = value["eligible"] == .bool(true)
            #expect(TestFlightAccess.canSetAutomatic(candidate, detail, verifiedAssociation: true) == eligible)
            if eligible { #expect(try TestFlightAccess.automaticDigest(candidate, detail, appId: app) == value["digest"]?.text) }
            else { #expect(throws: PublishFailure.self) { try TestFlightAccess.automaticDigest(candidate, detail, appId: app) } }
        }
        for value in links {
            let candidate = try resource(#require(value["build"])), detail = try resource(#require(value["detail"]))
            #expect(TestFlightAccess.matchesDetail(candidate, detail) == (value["unverified"] == .bool(true)))
            #expect(TestFlightAccess.matchesDetail(candidate, detail, verifiedAssociation: true) == (value["verified"] == .bool(true)))
        }
    }

    @Test func directAssignmentRemovalAndInvitationRequireApprovalOnce() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), double = SyntheticBuildAccess(), host = "individual-access.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        StubProtocol.handle(host) { double.handle($0) }
        let add = try await prepare(session, account, client, "assign-individual-tester", tester: "tester-1")
        #expect(double.writes.isEmpty && add.steps.count == 1)
        #expect(try await approve(session, account, client, add).state == "complete")
        await #expect(throws: PublishFailure.used) { try await approve(session, account, client, add) }
        #expect(try await session.individualBuildTesters(appId: app, buildId: "build-7", client: client).map(\.id) == ["tester-1"])
        #expect(try await prepare(session, account, client, "assign-individual-tester", tester: "tester-1").steps.isEmpty)
        double.apple.lock.withLock {
            var attrs = double.apple.builds[0]["attributes"] as! [String: Any]; attrs["expired"] = true; double.apple.builds[0]["attributes"] = attrs
            double.apple.groupTesters["group-1"] = ["tester-1"]
        }
        let remove = try await prepare(session, account, client, "remove-individual-tester", tester: "tester-1")
        #expect(try await approve(session, account, client, remove).state == "complete")
        #expect(double.assigned.isEmpty && double.apple.groupTesters["group-1"] == ["tester-1"])
        double.apple.lock.withLock { var attrs = double.apple.builds[0]["attributes"] as! [String: Any]; attrs["expired"] = false; double.apple.builds[0]["attributes"] = attrs }
        let invitation = try await prepare(session, account, client, "invite-individual-tester", email: " NEW.SYNTHETIC@example.com ")
        #expect(invitation.request.testerEmail == "new.synthetic@example.com")
        #expect(try await approve(session, account, client, invitation).state == "complete")
        #expect(double.assigned == ["tester-created"] && double.writes.count == 3)
    }

    @Test func accountWideEmailLookupAssignsTheExactTesterWithoutCreatingAnother() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), double = SyntheticBuildAccess(), host = "individual-email.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        double.external = [["type": "betaTesters", "id": "tester-external", "attributes": ["email": "external.synthetic@example.com", "state": "INVITED"]]]
        StubProtocol.handle(host) { double.handle($0) }
        let review = try await prepare(session, account, client, "invite-individual-tester", email: "external.synthetic@example.com")
        #expect(review.steps.first?.path == [.string("builds"), .string("build-7"), .string("relationships"), .string("individualTesters")])
        #expect(try await approve(session, account, client, review).state == "complete")
        #expect(double.assigned == ["tester-external"] && double.apple.testers.count == 2)
        double.lock.withLock { double.ambiguousLookup = true }
        await #expect(throws: PublishFailure.self) { try await session.exactTester(email: "external.synthetic@example.com", client: client) }
        double.lock.withLock { double.ambiguousLookup = false; double.external = [["type": "betaTesters", "id": "tester-unicode", "attributes": ["email": "synthetic.e\u{0301}@example.com"]]] }
        // Canonically equivalent Unicode spellings are distinct identities in the publishing guard.
        await #expect(throws: PublishFailure.self) { try await session.exactTester(email: "synthetic.é@example.com", client: client) }
    }

    @Test func changedIdentityAccessAndLastMomentGroupMembershipBlockWrites() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), double = SyntheticBuildAccess(), host = "individual-stale.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        StubProtocol.handle(host) { double.handle($0) }
        let stale = try await prepare(session, account, client, "assign-individual-tester", tester: "tester-1")
        double.apple.lock.withLock { var attrs = double.apple.testers[0]["attributes"] as! [String: Any]; attrs["email"] = "changed.synthetic@example.com"; double.apple.testers[0]["attributes"] = attrs }
        await #expect(throws: PublishFailure.conflict) { try await approve(session, account, client, stale) }
        #expect(double.writes.isEmpty)
        let fresh = try await prepare(session, account, client, "assign-individual-tester", tester: "tester-1")
        double.lock.withLock { double.joinOnRead = double.membershipReads + 2 }
        #expect(try await approve(session, account, client, fresh).state == "failed")
        #expect(double.writes.isEmpty && double.assigned.isEmpty)
        await #expect(throws: PublishFailure.used) { try await approve(session, account, client, fresh) }
    }

    @Test func internalAccessRequiresAnEligibleTeamRoleAndVisibleApp() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), double = SyntheticBuildAccess(), host = "individual-internal.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        double.apple.lock.withLock { var attrs = double.apple.builds[0]["attributes"] as! [String: Any]; attrs["buildAudienceType"] = "INTERNAL_ONLY"; double.apple.builds[0]["attributes"] = attrs }
        StubProtocol.handle(host) { double.handle($0) }
        double.internalRole = "FINANCE"
        await #expect(throws: PublishFailure.self) { try await prepare(session, account, client, "assign-individual-tester", tester: "tester-1") }
        double.internalRole = "DEVELOPER"; double.visible = false
        await #expect(throws: PublishFailure.self) { try await prepare(session, account, client, "assign-individual-tester", tester: "tester-1") }
        double.visible = true
        let review = try await prepare(session, account, client, "assign-individual-tester", tester: "tester-1")
        double.visible = false
        await #expect(throws: PublishFailure.self) { try await approve(session, account, client, review) }
        #expect(double.writes.isEmpty)
        double.allVisible = true
        let unrestricted = try await prepare(session, account, client, "assign-individual-tester", tester: "tester-1")
        #expect(try await approve(session, account, client, unrestricted).state == "complete")
        await #expect(throws: PublishFailure.self) { try await prepare(session, account, client, "invite-individual-tester", email: "new.synthetic@example.com") }
    }

    @Test func foreignTestersRejectedBetaAndConcurrentTesterCreationFailClosed() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), double = SyntheticBuildAccess(), host = "individual-ownership.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        StubProtocol.handle(host) { double.handle($0) }
        double.foreignOwner = true
        await #expect(throws: PublishFailure.self) { try await prepare(session, account, client, "assign-individual-tester", tester: "tester-1") }
        double.foreignOwner = false; double.betaState = "BETA_REJECTED"
        await #expect(throws: PublishFailure.self) { try await prepare(session, account, client, "invite-individual-tester", email: "new.synthetic@example.com") }
        double.betaState = "READY_FOR_BETA_SUBMISSION"
        let review = try await prepare(session, account, client, "invite-individual-tester", email: "new.synthetic@example.com")
        double.external = [["type": "betaTesters", "id": "tester-concurrent", "attributes": ["email": "new.synthetic@example.com"]]]
        await #expect(throws: PublishFailure.conflict) { try await approve(session, account, client, review) }
        #expect(double.writes.isEmpty)
    }

    @Test func automaticNotificationShowsTheExplicitBaselineAndRejectsBetaApprovalRace() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), double = SyntheticBuildAccess(), host = "automatic-notify.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        StubProtocol.handle(host) { double.handle($0) }
        let initial = try #require(try await session.testFlightBuilds(appId: app, client: client).first)
        #expect(initial.autoNotifyEnabled == false && initial.canSetAutomaticNotification)
        let review = try await prepare(session, account, client, "set-auto-notify", automatic: true)
        #expect(double.writes.isEmpty && review.steps.first?.before == "Automatic tester notification off" && review.steps.first?.after == "Automatic tester notification on")
        #expect(try await approve(session, account, client, review).state == "complete")
        #expect(double.automatic && double.writes.count == 1)
        #expect(try await session.testFlightBuilds(appId: app, client: client).first?.autoNotifyEnabled == true)
        #expect(try await prepare(session, account, client, "set-auto-notify", automatic: true).steps.isEmpty)
        let off = try await prepare(session, account, client, "set-auto-notify", automatic: false)
        double.lock.withLock { double.approveOnRead = double.detailReads + 2 }
        #expect(try await approve(session, account, client, off).state == "failed")
        #expect(double.automatic && double.writes.count == 1)
    }

    @Test func malformedExplicitOwnershipCannotFallBackToAConflictingRelationship() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        for data in [JSONText.null, .array([.object([("type", .string("apps")), ("id", .string(app))])]), .object([("type", .string("apps")), ("id", .string("1000000002"))])] {
            let build = try resource(.object([("type", .string("builds")), ("id", .string("build-synthetic")), ("relationships", .object([("app", .object([("data", data)]))]))]))
            await #expect(throws: PublishFailure.self) {
                try await session.scopedOwners([build], type: "builds", appId: app) { _ in Issue.record("An explicit malformed owner must not cause a fallback read."); return [] }
            }
        }
    }

    @Test func malformedSelectionsAndUnapprovedRouteShapesAreRefused() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), double = SyntheticBuildAccess(), host = "access-route-shapes.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        StubProtocol.handle(host) { double.handle($0) }
        for value in [request(account, "set-auto-notify"), request(account, "invite-individual-tester", email: "invalid"), request(account, "assign-individual-tester"), request(account, "assign-individual-tester", tester: "tester-1", automatic: true)] {
            #expect(throws: PublishFailure.self) { try value.validated() }
        }
        let review = try await prepare(session, account, client, "set-auto-notify", automatic: true), step = try #require(review.steps.first)
        let extra = JSONText.object([("type", .string("buildBetaDetails")), ("id", .string("detail-7")), ("attributes", .object([("autoNotifyEnabled", .bool(true)), ("externalBuildState", .string("READY_FOR_BETA_TESTING"))]))])
        await #expect(throws: PublishFailure.self) { try await session.verifyBuildAccess(method: "PATCH", parts: ["buildBetaDetails", "detail-7"], data: extra, guardValue: step.guardValue, appId: app, client: client) }
        await #expect(throws: PublishFailure.self) { try await session.verifyBuildAccess(method: "PATCH", parts: ["buildBetaDetails", "foreign-detail"], data: step.body?["data"], guardValue: step.guardValue, appId: app, client: client) }
        #expect(double.writes.isEmpty)
    }
}
