import Foundation
import Testing
@testable import StorebenchCore

final class SyntheticBuildAudience: @unchecked Sendable {
    let lock = NSLock(), apple = SyntheticApple()
    var groups: [[String: Any]], members: [String: [[String: Any]]], direct: [[String: Any]]
    var automatic: Any = false, externalState = "READY_FOR_BETA_TESTING"
    var detailOwner = "owned", detailAbsent = false, detailDuplicate = false
    var groupOwner = "owned", testerOwner = "owned", resolvedOwner = "owned"
    var audienceReads = 0, buildReads = 0, detailReads = 0
    var changeAudienceOnRead: Int?, changeDetailOnRead: Int?, changeBuildOnRead: Int?
    var mutation = "rename", changedDetail = "automatic", changedBuild = "expired"
    var writes: [(String, String, [String: Any])] = []
    init() throws {
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/testflight-audience.json"))) as! [String: Any]
        let baseline = (value["audienceCases"] as! [[String: Any]])[0], memberships = baseline["memberships"] as! [[String: Any]]
        groups = memberships.map { $0["group"] as! [String: Any] }
        members = Dictionary(uniqueKeysWithValues: memberships.map { (($0["group"] as! [String: Any])["id"] as! String, $0["testers"] as! [[String: Any]]) })
        direct = baseline["direct"] as! [[String: Any]]
    }
    static func tester(_ id: String) -> [String: Any] {
        ["type": "betaTesters", "id": id, "attributes": ["email": "\(id)@example.com"], "relationships": ["apps": ["data": [["type": "apps", "id": "1000000001"]]]]]
    }
    func detail() -> [String: Any] {
        var value: [String: Any] = ["type": "buildBetaDetails", "id": "detail-7", "attributes": ["autoNotifyEnabled": automatic, "externalBuildState": externalState]]
        if detailOwner != "omitted" { value["relationships"] = ["build": ["data": ["type": "builds", "id": detailOwner == "owned" ? "build-7" : "build-other"]]] }
        return value
    }
    func ownership(_ items: [[String: Any]], relation: String, mode: String) -> [[String: Any]] {
        items.map { original in
            var value = original
            switch mode {
            case "omitted": value.removeValue(forKey: "relationships")
            case "null": value["relationships"] = [relation: ["data": NSNull()]]
            case "foreign":
                let data: Any = relation == "app" ? ["type": "apps", "id": "1000000002"] : [["type": "apps", "id": "1000000002"]]
                value["relationships"] = [relation: ["data": data]]
            case "array": value["relationships"] = [relation: ["data": [["type": "apps", "id": "1000000001"]]]]
            default: break
            }
            return value
        }
    }
    func changeAudience() {
        switch mutation {
        case "rename": var fields = groups[0]["attributes"] as! [String: Any]; fields["name"] = "Renamed synthetic group"; groups[0]["attributes"] = fields
        case "member": members["group-1"]!.append(Self.tester("tester-new-member"))
        case "member-email": var fields = members["group-1"]![0]["attributes"] as! [String: Any]; fields["email"] = "changed-group@example.com"; members["group-1"]![0]["attributes"] = fields
        case "direct": direct.append(Self.tester("tester-new-direct"))
        case "hidden-email": var fields = direct[direct.count - 1]["attributes"] as! [String: Any]; fields["email"] = "hidden-changed@example.com"; direct[direct.count - 1]["attributes"] = fields
        case "foreign": testerOwner = "foreign"
        default: groups = []
        }
    }
    func handle(_ request: URLRequest) -> (Int, [String: String], Data) {
        lock.withLock {
            let path = request.url!.path, method = request.httpMethod ?? "GET", query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if method != "GET" {
                guard let body = (try? JSONSerialization.jsonObject(with: apple.body(request))) as? [String: Any], body.count == 1, let data = body["data"] as? [String: Any] else { return (400, [:], Data()) }
                if method == "POST", path == "/v1/buildBetaNotifications", data.count == 2, data["type"] as? String == "buildBetaNotifications", let relations = data["relationships"] as? [String: Any], relations.count == 1,
                   let build = relations["build"] as? [String: Any], let link = build["data"] as? [String: Any], link["type"] as? String == "builds", link["id"] as? String == "build-7", automatic as? Bool == false, externalState == "READY_FOR_BETA_TESTING" {
                    writes.append((method, path, body)); return apple.page(["type": "buildBetaNotifications", "id": "synthetic-notice-1"])
                }
                if method == "PATCH", path == "/v1/builds/build-7", data.count == 3, data["type"] as? String == "builds", data["id"] as? String == "build-7", let fields = data["attributes"] as? [String: Any], fields.count == 1, fields["expired"] as? Bool == true {
                    var attributes = apple.builds[0]["attributes"] as! [String: Any]; attributes["expired"] = true; apple.builds[0]["attributes"] = attributes
                    writes.append((method, path, body)); return apple.page(apple.builds[0])
                }
                return (400, [:], Data())
            }
            if path == "/v1/betaGroups" {
                guard query.count == 3, query.first(where: { $0.name == "filter[app]" })?.value == "1000000001", query.first(where: { $0.name == "filter[builds]" })?.value == "build-7", query.first(where: { $0.name == "limit" })?.value == "200" else { return (400, [:], Data()) }
                audienceReads += 1; if audienceReads == changeAudienceOnRead { changeAudience() }
                return apple.page(ownership(groups, relation: "app", mode: groupOwner))
            }
            if path == "/v1/apps/1000000001/builds" {
                buildReads += 1
                if buildReads == changeBuildOnRead {
                    if changedBuild == "owner" { apple.builds[0]["relationships"] = ["app": ["data": ["type": "apps", "id": "1000000002"]]] }
                    else { var fields = apple.builds[0]["attributes"] as! [String: Any]; fields[changedBuild] = changedBuild == "expired" ? true : "Changed synthetic build"; apple.builds[0]["attributes"] = fields }
                }
                return apple.page(apple.builds)
            }
            if path == "/v1/builds" { return (200, [:], try! JSONSerialization.data(withJSONObject: ["data": apple.builds, "included": [detail(), ["type": "preReleaseVersions", "id": "pre-1", "attributes": ["version": "2.0", "platform": "IOS"]]], "links": [:]])) }
            if path == "/v1/builds/build-7/buildBetaDetail" {
                detailReads += 1
                if detailReads == changeDetailOnRead { if changedDetail == "automatic" { automatic = true } else { externalState = changedDetail } }
                return apple.page(detailAbsent ? NSNull() : detailDuplicate ? [detail(), detail()] : detail())
            }
            if path == "/v1/builds/build-7/individualTesters" {
                guard query.count == 1, query[0].name == "limit", query[0].value == "200" else { return (400, [:], Data()) }
                return apple.page(ownership(direct, relation: "apps", mode: testerOwner))
            }
            for group in groups {
                let id = group["id"] as! String
                if path == "/v1/betaGroups/\(id)/betaTesters", query.count == 1, query[0].name == "limit", query[0].value == "200" { return apple.page(ownership(members[id] ?? [], relation: "apps", mode: testerOwner)) }
                if path == "/v1/betaGroups/\(id)/relationships/app" { return apple.page(resolvedOwner == "missing" ? NSNull() : ["type": "apps", "id": resolvedOwner == "owned" ? "1000000001" : "1000000002"]) }
            }
            let allTesters = direct + members.values.flatMap { $0 }
            for tester in allTesters {
                let id = tester["id"] as! String
                if path == "/v1/betaTesters/\(id)/relationships/apps", query.count == 1, query[0].name == "limit", query[0].value == "200" { return apple.page([["type": "apps", "id": resolvedOwner == "owned" ? "1000000001" : "1000000002"]]) }
            }
            return apple.handle(request)
        }
    }
}

@Suite(.serialized) struct TestFlightAudienceTests {
    init() throws { _ = try TestIsolation.require() }
    let app = "1000000001"
    func vector() throws -> JSONText { try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/testflight-audience.json"))) }
    func request(_ account: Account, expiry: Bool = false) -> PublishRequest {
        var value = PublishRequest(accountId: account.id, appId: app, scope: .testflight, buildId: "build-7")
        value.testflightAction = expiry ? "expire-build" : "notify-build-testers"; return value
    }
    func approve(_ session: WorkspaceSession, _ account: Account, _ client: AppStoreConnectClient, _ review: PublishReview) async throws -> PublishReview {
        try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: client)
    }
    @Test func fullAudienceSnapshotsAndVisibleTextMatchWebContracts() throws {
        let value = try vector(); guard case .array(let cases)? = value["audienceCases"] else { throw JSONText.ParseFailure.invalid }
        for item in cases {
            let build = try JSONDecoder().decode(AppStoreConnectClient.Resource.self, from: #require(item["build"]).data)
            let memberships = try JSONDecoder().decode([TestFlightAudience.Membership].self, from: #require(item["memberships"]).data)
            let direct = try JSONDecoder().decode([AppStoreConnectClient.Resource].self, from: #require(item["direct"]).data)
            if item["valid"] == .bool(true) {
                let result = try TestFlightAudience.review(appId: app, build: build, memberships: memberships, direct: direct)
                #expect(result.digest == item["digest"]?.text && result.before == item["before"]?.text)
            } else { #expect(throws: PublishFailure.self) { try TestFlightAudience.review(appId: app, build: build, memberships: memberships, direct: direct) } }
        }
        #expect(cases[0]["digest"] == cases[1]["digest"] && cases[5]["digest"] != cases[6]["digest"])
        #expect(cases[0]["before"]?.text?.contains("Unique assigned testers: 3.") == true)
        #expect(cases[5]["before"]?.text?.contains("tester-direct-25@example.com") == false)
    }
    @Test func manualNotificationEligibilityMatchesWebAcrossEveryStateAndFlag() throws {
        let value = try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/testflight-access.json")))
        guard case .array(let cases)? = value["automaticCases"] else { throw JSONText.ParseFailure.invalid }
        for item in cases {
            let build = try JSONDecoder().decode(AppStoreConnectClient.Resource.self, from: #require(item["build"]).data)
            let detail = try JSONDecoder().decode(AppStoreConnectClient.Resource.self, from: #require(item["detail"]).data)
            #expect(TestFlightAccess.canNotify(build, detail, verifiedAssociation: true) == (item["notify"] == .bool(true)))
        }
    }
    @Test func ownershipResolversEncodeTheExactOpaqueIdentifierAndNormalizeTesterApps() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let value = try vector(); guard case .array(let probes)? = value["ownershipPathProbes"] else { throw JSONText.ParseFailure.invalid }
        let owner = AppStoreConnectClient.Resource(type: "apps", id: app, attributes: nil, relationships: nil)
        for probe in probes {
            let id = try #require(probe["id"]?.text), encoded = try #require(probe["encoded"]?.text)
            #expect(TextSemantics.pathComponent(id) == encoded)
            let group = AppStoreConnectClient.Resource(type: "betaGroups", id: id, attributes: ["name": .string("Synthetic opaque group")], relationships: nil)
            let groups = try await session.scopedOwners([group], type: "betaGroups", appId: app) { path in
                #expect(path == "/v1/betaGroups/\(encoded)/relationships/app"); return [owner]
            }
            let tester = AppStoreConnectClient.Resource(type: "betaTesters", id: id, attributes: nil, relationships: nil)
            let testers = try await session.scopedTesters([tester], appId: app) { path in
                #expect(path == "/v1/betaTesters/\(encoded)/relationships/apps?limit=200"); return [owner]
            }
            #expect(Apple.owned(groups[0], "app", "apps", app))
            #expect(try TestFlightAudience.identities(testers, appId: app).first?["id"]?.text == id)
        }
    }
    @Test func manualNotificationShowsTheAffectedAudienceAndConsumesApprovalOnce() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), model = try SyntheticBuildAudience(), host = "build-audience-notify.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        StubProtocol.handle(host) { model.handle($0) }
        let build = try #require(try await session.testFlightBuilds(appId: app, client: client).first)
        #expect(build.canNotifyTesters && !build.canSetAutomaticNotification)
        let review = try await session.preparePublishing(account: account, request: request(account), client: client)
        #expect(model.writes.isEmpty && review.steps.count == 1)
        #expect(review.steps[0].before?.contains("Synthetic testers · group-1 · 2 testers") == true && review.steps[0].before?.contains("Unique assigned testers: 3.") == true)
        #expect(try await approve(session, account, client, review).state == "complete" && model.writes.count == 1)
        await #expect(throws: PublishFailure.used) { try await approve(session, account, client, review) }
    }
    @Test func expiryReviewsEveryAssignmentAndAlreadyExpiredBuildsHaveNoChange() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), model = try SyntheticBuildAudience(), host = "build-audience-expire.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        StubProtocol.handle(host) { model.handle($0) }
        model.externalState = "PROCESSING"; model.automatic = true
        let review = try await session.preparePublishing(account: account, request: request(account, expiry: true), client: client)
        #expect(model.detailReads == 0 && model.writes.isEmpty && review.steps[0].before?.contains("Direct assignments (2)") == true)
        #expect(try await approve(session, account, client, review).state == "complete")
        #expect((model.apple.builds[0]["attributes"] as? [String: Any])?["expired"] as? Bool == true)
        #expect(try await session.preparePublishing(account: account, request: request(account, expiry: true), client: client).steps.isEmpty)
        #expect(model.writes.count == 1)
    }
    @Test func changedGroupDirectAndHiddenAssignmentsStopEachReviewedWrite() async throws {
        for expiry in [false, true] { for mutation in ["rename", "member", "member-email", "direct", "hidden-email", "foreign"] {
            let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
            let account = try #require(try await session.accounts().first), model = try SyntheticBuildAudience(), host = "build-audience-race-\(expiry)-\(mutation).appstoreconnect.test", client = try PublishingTests().client(account, host: host)
            StubProtocol.handle(host) { model.handle($0) }
            if mutation == "hidden-email" { model.direct = (0..<26).map { SyntheticBuildAudience.tester(String(format: "tester-direct-%02d", $0)) } }
            let review = try await session.preparePublishing(account: account, request: request(account, expiry: expiry), client: client)
            model.mutation = mutation; model.changeAudienceOnRead = model.audienceReads + 2
            let result = try await approve(session, account, client, review)
            #expect(result.state == "failed" && model.writes.isEmpty)
            await #expect(throws: PublishFailure.used) { try await approve(session, account, client, review) }
        } }
    }
    @Test func changedAudienceAtApprovalRequiresANewReview() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), model = try SyntheticBuildAudience(), host = "build-audience-approval-conflict.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        StubProtocol.handle(host) { model.handle($0) }
        let review = try await session.preparePublishing(account: account, request: request(account), client: client)
        model.mutation = "member"; model.changeAudienceOnRead = model.audienceReads + 1
        await #expect(throws: PublishFailure.conflict) { try await approve(session, account, client, review) }
        #expect(model.writes.isEmpty)
    }
    @Test func automaticNotificationAndBetaStateChangesStopManualDelivery() async throws {
        for state in ["automatic", "IN_BETA_REVIEW", "BETA_REJECTED"] {
            let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
            let account = try #require(try await session.accounts().first), model = try SyntheticBuildAudience(), host = "build-audience-state-\(state.lowercased()).appstoreconnect.test", client = try PublishingTests().client(account, host: host)
            StubProtocol.handle(host) { model.handle($0) }
            let review = try await session.preparePublishing(account: account, request: request(account), client: client)
            model.changedDetail = state; model.changeDetailOnRead = model.detailReads + 2
            #expect(try await approve(session, account, client, review).state == "failed" && model.writes.isEmpty)
        }
    }
    @Test func invalidBetaDetailsAndUnconfirmedExpiryFailBeforeAudienceReads() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), model = try SyntheticBuildAudience(), host = "build-audience-eligibility.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        StubProtocol.handle(host) { model.handle($0) }
        for state in ["READY_FOR_BETA_SUBMISSION", "IN_BETA_REVIEW", "UNKNOWN"] {
            model.externalState = state
            await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: request(account), client: client) }
        }
        model.externalState = "READY_FOR_BETA_TESTING"
        for value in [true, NSNull(), "false"] as [Any] {
            model.automatic = value
            await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: request(account), client: client) }
        }
        model.automatic = false
        for mode in ["absent", "duplicate", "foreign"] {
            model.detailAbsent = mode == "absent"; model.detailDuplicate = mode == "duplicate"; model.detailOwner = mode == "foreign" ? "foreign" : "owned"
            await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: request(account), client: client) }
        }
        var fields = model.apple.builds[0]["attributes"] as! [String: Any]; fields["expired"] = NSNull(); model.apple.builds[0]["attributes"] = fields
        await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: request(account, expiry: true), client: client) }
        #expect(model.audienceReads == 0 && model.writes.isEmpty)
    }
    @Test func omittedOwnersAreResolvedAndMalformedOwnersCannotUseThatFallback() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), model = try SyntheticBuildAudience(), host = "build-audience-scope.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        StubProtocol.handle(host) { model.handle($0) }
        model.groupOwner = "omitted"; model.testerOwner = "omitted"
        let review = try await session.preparePublishing(account: account, request: request(account), client: client)
        #expect(review.steps[0].before?.contains("Unique assigned testers: 3.") == true)
        for owner in ["foreign", "missing"] {
            model.resolvedOwner = owner
            await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: request(account), client: client) }
        }
        model.resolvedOwner = "owned"; model.testerOwner = "owned"
        for owner in ["foreign", "null", "array"] { model.groupOwner = owner; await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: request(account), client: client) } }
        model.groupOwner = "owned"
        for owner in ["foreign", "null"] { model.testerOwner = owner; await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: request(account), client: client) } }
        #expect(model.writes.isEmpty)
    }
    @Test func changedBuildVersionExpiryAndOwnerStopReviewedExpiry() async throws {
        for field in ["version", "expired", "owner"] {
            let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
            let account = try #require(try await session.accounts().first), model = try SyntheticBuildAudience(), host = "build-audience-build-\(field).appstoreconnect.test", client = try PublishingTests().client(account, host: host)
            StubProtocol.handle(host) { model.handle($0) }
            let review = try await session.preparePublishing(account: account, request: request(account, expiry: true), client: client)
            model.changedBuild = field; model.changeBuildOnRead = model.buildReads + 2
            #expect(try await approve(session, account, client, review).state == "failed" && model.writes.isEmpty)
        }
    }
    @Test func malformedEnvelopeExtraFieldsAndLegacyGuardsAreRefused() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), model = try SyntheticBuildAudience(), host = "build-audience-write-shapes.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        StubProtocol.handle(host) { model.handle($0) }
        let notify = try await session.preparePublishing(account: account, request: request(account), client: client), expiry = try await session.preparePublishing(account: account, request: request(account, expiry: true), client: client)
        let step = try #require(notify.steps.first), body = try #require(step.body), guardValue = try #require(step.guardValue)
        let invalidBodies = [body.setting("extra", .bool(true)), body.setting("data", body["data"]!.setting("attributes", .object([]))), body.setting("data", body["data"]!.setting("relationships", .object([("build", Apple.relationship("builds", .string("build-other")))])))]
        for value in invalidBodies { await #expect(throws: PublishFailure.self) { try await session.verifyWrite(method: "POST", path: "/v1/buildBetaNotifications", body: value, guardValue: guardValue, appId: app, client: client) } }
        await #expect(throws: PublishFailure.self) { try await session.verifyWrite(method: "POST", path: "/v1/buildBetaNotifications", body: body, guardValue: guardValue.setting("kind", .string("build-notification")), appId: app, client: client) }
        let expiryStep = try #require(expiry.steps.first)
        await #expect(throws: PublishFailure.self) { try await session.verifyWrite(method: "PATCH", path: "/v1/builds/build-7", body: expiryStep.body, guardValue: expiryStep.guardValue?.setting("kind", .string("build-expiry")), appId: app, client: client) }
        #expect(model.writes.isEmpty)
    }
}
