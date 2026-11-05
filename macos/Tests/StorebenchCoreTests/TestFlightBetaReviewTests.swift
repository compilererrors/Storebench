import Foundation
import Testing
@testable import StorebenchCore

final class SyntheticBetaSubmission: @unchecked Sendable {
    let lock = NSLock(), apple = SyntheticApple()
    var input: [String: Any]
    var buildReads = 0, mutateOnRead = 0, mutation = ""
    var active: [[String: Any]] = [], activeState = "WAITING_FOR_REVIEW"
    var submissions: [[String: Any]] = [], writes: [[String: Any]] = []
    var resolvedOwner = "1000000001"
    init() throws {
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/testflight-beta-review.json"))) as! [String: Any]
        input = (value["cases"] as! [[String: Any]])[0]
    }
    func resources(_ name: String) -> [[String: Any]] { input[name] as! [[String: Any]] }
    func change(_ name: String, key: String, value: Any?) {
        var item = name == "build" ? input[name] as! [String: Any] : resources(name)[0]
        var attributes = item["attributes"] as! [String: Any]; attributes[key] = value; item["attributes"] = attributes
        if name == "build" { input[name] = item } else { var items = resources(name); items[0] = item; input[name] = items }
    }
    func relationship(_ name: String, key: String, value: Any?) {
        var item = name == "build" ? input[name] as! [String: Any] : resources(name)[0]
        var relations = item["relationships"] as? [String: Any] ?? [:]; relations[key] = value; item["relationships"] = relations
        if name == "build" { input[name] = item } else { var items = resources(name); items[0] = item; input[name] = items }
    }
    func encrypted() {
        change("build", key: "usesNonExemptEncryption", value: true)
        relationship("build", key: "appEncryptionDeclaration", value: ["data": ["type": "appEncryptionDeclarations", "id": "declaration-synthetic"]])
    }
    func mutate() {
        switch mutation {
        case "processing": change("build", key: "processingState", value: "PROCESSING")
        case "expired": change("build", key: "expired", value: true)
        case "audience": change("build", key: "buildAudienceType", value: "INTERNAL_ONLY")
        case "encryption": change("build", key: "usesNonExemptEncryption", value: nil)
        case "build-version": change("build", key: "version", value: "43")
        case "release": relationship("build", key: "preReleaseVersion", value: ["data": ["type": "preReleaseVersions", "id": "changed-version"]])
        case "build-owner": relationship("build", key: "app", value: ["data": NSNull()])
        case "beta-state": change("betaDetails", key: "externalBuildState", value: "READY_FOR_BETA_TESTING")
        case "automatic": change("betaDetails", key: "autoNotifyEnabled", value: true)
        case "beta-owner": relationship("betaDetails", key: "build", value: ["data": NSNull()])
        case "beta-link": relationship("build", key: "buildBetaDetail", value: ["data": NSNull()])
        case "description": change("localizations", key: "description", value: "Changed synthetic description")
        case "feedback": change("localizations", key: "feedbackEmail", value: "changed@example.com")
        case "privacy": change("localizations", key: "privacyPolicyUrl", value: "https://example.com/changed")
        case "marketing": change("localizations", key: "marketingUrl", value: "https://example.com/changed")
        case "tv-privacy": change("localizations", key: "tvOsPrivacyPolicy", value: "Changed synthetic privacy")
        case "locale": change("localizations", key: "locale", value: "fr-FR")
        case "locale-owner": relationship("localizations", key: "app", value: ["data": NSNull()])
        case "contact": change("reviewDetails", key: "contactEmail", value: "changed@example.com")
        case "password": change("reviewDetails", key: "demoAccountPassword", value: "changed-synthetic-password")
        case "notes": change("reviewDetails", key: "notes", value: "Changed synthetic review notes")
        case "review-owner": relationship("reviewDetails", key: "app", value: ["data": NSNull()])
        case "declaration-state": change("declarations", key: "appEncryptionDeclarationState", value: "REJECTED")
        case "declaration-platform": change("declarations", key: "platform", value: "MAC_OS")
        case "version-platform": change("versions", key: "platform", value: "MAC_OS")
        case "declaration-link": relationship("build", key: "appEncryptionDeclaration", value: ["data": ["type": "appEncryptionDeclarations", "id": "changed-declaration"]])
        case "submission": submissions = [["type": "betaAppReviewSubmissions", "id": "late-submission", "relationships": ["build": ["data": ["type": "builds", "id": "build-synthetic"]]]]]
        case "foreign-submission": submissions = [["type": "betaAppReviewSubmissions", "id": "foreign-submission", "relationships": ["build": ["data": ["type": "builds", "id": "foreign-build"]]]]]
        case "active": active = [input["build"] as! [String: Any]]
        default: break
        }
    }
    func handle(_ request: URLRequest) -> (Int, [String: String], Data) {
        lock.withLock {
            let path = request.url!.path, query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
            guard request.httpMethod == "GET" else {
                guard request.httpMethod == "POST", path == "/v1/betaAppReviewSubmissions", query.isEmpty,
                      let body = (try? JSONSerialization.jsonObject(with: apple.body(request))) as? [String: Any], body.count == 1,
                      let data = body["data"] as? [String: Any], data.count == 2, data["type"] as? String == "betaAppReviewSubmissions",
                      let relationships = data["relationships"] as? [String: Any], relationships.count == 1,
                      let build = relationships["build"] as? [String: Any], build.count == 1, let target = build["data"] as? [String: Any], target.count == 2,
                      target["type"] as? String == "builds", target["id"] as? String == "build-synthetic", submissions.isEmpty else { return (400, [:], Data()) }
                writes.append(body); submissions = [["type": "betaAppReviewSubmissions", "id": "review-submission-synthetic", "attributes": ["betaReviewState": "WAITING_FOR_REVIEW"], "relationships": relationships]]
                return apple.page(submissions[0])
            }
            switch path {
            case "/v1/apps/1000000001": return apple.page(["type": "apps", "id": "1000000001", "attributes": ["name": "Synthetic app"]])
            case "/v1/apps/1000000001/builds":
                guard query.count == 1, value("limit") == "200" else { return (400, [:], Data()) }
                buildReads += 1; if buildReads == mutateOnRead { mutate() }; return apple.page([input["build"]!])
            case "/v1/builds":
                guard value("filter[app]") == "1000000001", value("limit") == "200", query.count == 3 else { return (400, [:], Data()) }
                if let state = value("filter[betaAppReviewSubmission.betaReviewState]"), ["WAITING_FOR_REVIEW", "IN_REVIEW"].contains(state) { return apple.page(state == activeState ? active : []) }
                if value("include") == "app,preReleaseVersion,betaAppReviewSubmission,buildBetaDetail" {
                    return (200, [:], try! JSONSerialization.data(withJSONObject: ["data": [input["build"]!], "included": resources("versions") + resources("betaDetails")]))
                }
                return (400, [:], Data())
            case "/v1/betaAppReviewSubmissions":
                guard query.count == 2, value("filter[build]") == "build-synthetic", value("limit") == "200" else { return (400, [:], Data()) }; return apple.page(submissions)
            case "/v1/builds/build-synthetic/buildBetaDetail": return apple.page(resources("betaDetails"))
            case "/v1/apps/1000000001/appEncryptionDeclarations": return apple.page(resources("declarations"))
            case "/v1/preReleaseVersions/pre-synthetic": return apple.page(resources("versions"))
            case "/v1/betaAppLocalizations":
                guard query.count == 2, value("filter[app]") == "1000000001", value("limit") == "200" else { return (400, [:], Data()) }; return apple.page(resources("localizations"))
            case "/v1/apps/1000000001/betaAppReviewDetail": return apple.page(resources("reviewDetails"))
            case "/v1/builds/build-synthetic/relationships/app", "/v1/betaAppReviewDetails/review-synthetic/relationships/app", "/v1/betaAppLocalizations/locale-0/relationships/app", "/v1/betaAppLocalizations/locale-1/relationships/app": return apple.page(["type": "apps", "id": resolvedOwner])
            default: return (404, [:], Data())
            }
        }
    }
}

@Suite(.serialized) struct TestFlightBetaReviewTests {
    init() throws { _ = try TestIsolation.require() }
    let app = "1000000001"
    func resources(_ value: JSONText) throws -> [AppStoreConnectClient.Resource] { try JSONDecoder().decode([AppStoreConnectClient.Resource].self, from: value.data) }
    func resource(_ value: JSONText) throws -> AppStoreConnectClient.Resource { try JSONDecoder().decode(AppStoreConnectClient.Resource.self, from: value.data) }
    func request(_ account: Account) -> PublishRequest {
        var request = PublishRequest(accountId: account.id, appId: app, scope: .testflight, buildId: "build-synthetic"); request.testflightAction = "submit-beta-review"; return request
    }
    func approve(_ session: WorkspaceSession, _ account: Account, _ client: AppStoreConnectClient, _ review: PublishReview) async throws -> PublishReview {
        try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: client)
    }
    @Test func completePrerequisiteDigestsAndActiveVersionsMatchWebContracts() throws {
        let vector = try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/testflight-beta-review.json")))
        guard case .array(let cases)? = vector["cases"], case .array(let activeCases)? = vector["activeCases"] else { throw JSONText.ParseFailure.invalid }
        for value in cases {
            func calculate() throws -> TestFlightBetaReview.Readiness {
                try TestFlightBetaReview.readiness(appId: app, build: resource(#require(value["build"])), betaDetails: resources(#require(value["betaDetails"])), declarations: resources(#require(value["declarations"])), versions: resources(#require(value["versions"])), localizations: resources(#require(value["localizations"])), reviewDetails: resources(#require(value["reviewDetails"])))
            }
            if value["valid"] == .bool(true) { let result = try calculate(); #expect(result.digest == value["digest"]?.text && result.autoNotifyEnabled == (value["autoNotifyEnabled"] == .bool(true))) }
            else { #expect(throws: PublishFailure.self) { try calculate() } }
        }
        #expect(cases.count >= 60 && cases[0]["digest"] == cases[1]["digest"] && activeCases.count == 7)
        let selected = try resource(#require(cases[0]["build"]))
        for value in activeCases {
            if value["valid"] == .bool(true) { try TestFlightBetaReview.assertNoActiveReview(appId: app, selected: selected, active: resources(#require(value["active"]))) }
            else { #expect(throws: PublishFailure.self) { try TestFlightBetaReview.assertNoActiveReview(appId: app, selected: selected, active: resources(#require(value["active"]))) } }
        }
    }
    @Test func approvedSubmissionsWithAndWithoutEncryptionAreConsumedOnce() async throws {
        for encryption in [false, true] {
            let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
            let account = try #require(try await session.accounts().first), model = try SyntheticBetaSubmission(), host = "beta-submission-approved-\(encryption).appstoreconnect.test", client = try PublishingTests().client(account, host: host)
            if encryption { model.encrypted() }; StubProtocol.handle(host) { model.handle($0) }
            let review = try await session.preparePublishing(account: account, request: request(account), client: client)
            #expect(review.steps.count == 1 && review.steps[0].guardValue?["kind"]?.text == "beta-review-final" && model.writes.isEmpty)
            #expect(review.steps[0].detail.contains("Automatic tester notification: Off") && !review.steps[0].detail.contains("synthetic-password"))
            #expect(try await approve(session, account, client, review).state == "complete" && model.writes.count == 1)
            await #expect(throws: PublishFailure.used) { try await approve(session, account, client, review) }
            #expect(try await session.preparePublishing(account: account, request: request(account), client: client).steps.isEmpty)
        }
    }
    @Test func everyLatePrerequisiteChangeStopsTheConsumedReviewBeforeWriting() async throws {
        let mutations = ["processing", "expired", "audience", "encryption", "build-version", "release", "build-owner", "beta-state", "automatic", "beta-owner", "beta-link", "description", "feedback", "privacy", "marketing", "tv-privacy", "locale", "locale-owner", "contact", "password", "notes", "review-owner", "declaration-state", "declaration-platform", "version-platform", "declaration-link", "submission", "foreign-submission", "active"]
        for mutation in mutations {
            let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
            let account = try #require(try await session.accounts().first), model = try SyntheticBetaSubmission(), host = "beta-submission-late-\(mutation).appstoreconnect.test", client = try PublishingTests().client(account, host: host)
            if mutation.hasPrefix("declaration") || mutation == "version-platform" { model.encrypted() }; StubProtocol.handle(host) { model.handle($0) }
            let review = try await session.preparePublishing(account: account, request: request(account), client: client)
            model.mutation = mutation; model.mutateOnRead = model.buildReads + 2
            #expect(try await approve(session, account, client, review).state == "failed" && model.writes.isEmpty)
            await #expect(throws: PublishFailure.used) { try await approve(session, account, client, review) }
        }
    }
    @Test func changesBeforeApprovalRequireANewReview() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), model = try SyntheticBetaSubmission(), host = "beta-submission-stale.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        StubProtocol.handle(host) { model.handle($0) }
        let review = try await session.preparePublishing(account: account, request: request(account), client: client)
        model.change("localizations", key: "description", value: "Changed synthetic description")
        await #expect(throws: PublishFailure.conflict) { try await approve(session, account, client, review) }
        #expect(model.writes.isEmpty)
    }
    @Test func bothActiveReviewStatesBlockTheSameVersionAndAllowOtherVersions() async throws {
        for state in ["WAITING_FOR_REVIEW", "IN_REVIEW"] {
            let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
            let account = try #require(try await session.accounts().first), model = try SyntheticBetaSubmission(), host = "beta-submission-active-\(state.lowercased()).appstoreconnect.test", client = try PublishingTests().client(account, host: host)
            StubProtocol.handle(host) { model.handle($0) }; model.activeState = state
            var sibling = model.input["build"] as! [String: Any]; sibling["id"] = "other-build"; model.active = [sibling]
            await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: request(account), client: client) }
            sibling["relationships"] = ["app": ["data": ["type": "apps", "id": app]], "preReleaseVersion": ["data": ["type": "preReleaseVersions", "id": "another-version"]]]; model.active = [sibling]
            let review = try await session.preparePublishing(account: account, request: request(account), client: client)
            model.mutation = "active"; model.mutateOnRead = model.buildReads + 2
            #expect(try await approve(session, account, client, review).state == "failed" && model.writes.isEmpty)
        }
    }
    @Test func malformedReadinessResponsesAndForeignExistingSubmissionsAreRejected() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), model = try SyntheticBetaSubmission(), host = "beta-submission-invalid.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        StubProtocol.handle(host) { model.handle($0) }; let baseline = model.input
        for name in ["betaDetails", "reviewDetails", "localizations"] {
            model.input = baseline; model.input[name] = model.resources(name) + [model.resources(name)[0]]
            await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: request(account), client: client) }
        }
        model.input = baseline; model.submissions = [["type": "betaAppReviewSubmissions", "id": "foreign-review", "relationships": ["build": ["data": ["type": "builds", "id": "foreign-build"]]]]]
        await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: request(account), client: client) }
        #expect(model.writes.isEmpty)
    }
    @Test func omittedOwnersResolveWhileExplicitInvalidOwnersCannotFallback() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), model = try SyntheticBetaSubmission(), host = "beta-submission-owner.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        StubProtocol.handle(host) { model.handle($0) }; let baseline = model.input
        for name in ["build", "localizations", "reviewDetails"] { model.relationship(name, key: "app", value: nil) }
        #expect(try await session.preparePublishing(account: account, request: request(account), client: client).steps.count == 1)
        for name in ["build", "localizations", "reviewDetails"] {
            model.input = baseline; model.relationship(name, key: "app", value: ["data": NSNull()])
            await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: request(account), client: client) }
        }
        model.input = baseline; model.relationship("reviewDetails", key: "app", value: nil); model.resolvedOwner = "1000000002"
        await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: request(account), client: client) }
        #expect(model.writes.isEmpty)
    }
    @Test func changedRoutesExtraFieldsAndLegacyGuardsCannotUseTheSubmissionBoundary() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), model = try SyntheticBetaSubmission(), host = "beta-submission-forged.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        StubProtocol.handle(host) { model.handle($0) }
        let step = try await session.preparePublishing(account: account, request: request(account), client: client).steps[0], body = try #require(step.body), guardValue = try #require(step.guardValue)
        let data = try #require(body["data"]), relation = try #require(data["relationships"])
        let extraBodies: [JSONText] = [.object([("data", data), ("extra", .bool(true))]), .object([("data", .object([("type", .string("betaAppReviewSubmissions")), ("relationships", relation), ("attributes", .object([]))]))]),
            .object([("data", .object([("type", .string("betaAppReviewSubmissions")), ("relationships", .object([("build", Apple.relationship("builds", .string("build-synthetic"))), ("app", Apple.relationship("apps", .string(app)))]))]))]),
            .object([("data", .object([("type", .string("betaAppReviewSubmissions")), ("relationships", .object([("build", Apple.relationship("builds", .string("foreign-build")))]))]))])]
        for malformed in extraBodies { await #expect(throws: PublishFailure.self) { try await session.verifyWrite(method: "POST", path: "/v1/betaAppReviewSubmissions", body: malformed, guardValue: guardValue, appId: app, client: client) } }
        for kind in ["beta-review", "app-testers", "beta-review-final"] {
            let badGuard: JSONText = .object([("kind", .string(kind)), ("digest", guardValue["digest"]!), ("buildId", .string("build-synthetic"))])
            await #expect(throws: PublishFailure.self) { try await session.verifyWrite(method: "POST", path: "/v1/betaAppReviewSubmissions", body: body, guardValue: badGuard, appId: app, client: client) }
        }
        for method in ["PATCH", "DELETE"] { await #expect(throws: PublishFailure.self) { try await session.verifyWrite(method: method, path: "/v1/betaAppReviewSubmissions", body: body, guardValue: guardValue, appId: app, client: client) } }
        await #expect(throws: PublishFailure.self) { try await session.verifyWrite(method: "POST", path: "/v1/betaAppReviewSubmissions/extra", body: body, guardValue: guardValue, appId: app, client: client) }
        #expect(model.writes.isEmpty)
    }
    @Test func nativeBuildActionRequiresConfirmedSubmissionStateAndNotification() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), model = try SyntheticBetaSubmission(), host = "beta-submission-ui-model.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        model.relationship("build", key: "betaAppReviewSubmission", value: ["data": NSNull()])
        StubProtocol.handle(host) { model.handle($0) }
        #expect(try await session.testFlightBuilds(appId: app, client: client).first?.canSubmitForBetaReview == true)
        model.change("betaDetails", key: "autoNotifyEnabled", value: nil)
        #expect(try await session.testFlightBuilds(appId: app, client: client).first?.canSubmitForBetaReview == false)
        model.change("betaDetails", key: "autoNotifyEnabled", value: false); model.change("betaDetails", key: "externalBuildState", value: "READY_FOR_BETA_TESTING")
        #expect(try await session.testFlightBuilds(appId: app, client: client).first?.canSubmitForBetaReview == false)
    }
}
