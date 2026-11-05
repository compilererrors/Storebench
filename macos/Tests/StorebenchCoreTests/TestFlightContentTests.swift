import Foundation
import Testing
@testable import StorebenchCore

final class SyntheticBetaDeclarations: @unchecked Sendable {
    let lock = NSLock(), apple = SyntheticApple()
    var betaAttributes: [String: Any]
    var ownerMode = "omitted"
    var betaAbsent = false
    var betaDuplicate = false
    var betaReads = 0
    var changeBetaOnRead: Int?
    var declarations: [[String: Any]]
    var declarationReads = 0
    var revokeOnRead: Int?
    var linkedPage: Any = NSNull()
    var platform = "IOS"
    var wrongVersionID = false
    var writes: [(String, String, [String: Any])] = []
    init() throws {
        let root = try TestIsolation.require(), vector = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("native-fixtures/testflight-review-content.json"))) as! [String: Any]
        betaAttributes = (vector["betaDetail"] as! [String: Any])["attributes"] as! [String: Any]
        declarations = [["type": "appEncryptionDeclarations", "id": "decl-synthetic", "attributes": ["appEncryptionDeclarationState": "APPROVED", "platform": "IOS", "appDescription": "Synthetic encryption declaration"],
                         "relationships": ["app": ["data": ["type": "apps", "id": "1000000001"]]]]]
        var attributes = apple.builds[0]["attributes"] as! [String: Any]; attributes["usesNonExemptEncryption"] = true; apple.builds[0]["attributes"] = attributes
    }
    func detail() -> [String: Any] {
        var item: [String: Any] = ["type": "betaAppReviewDetails", "id": "beta-detail-1", "attributes": betaAttributes]
        switch ownerMode {
        case "owned": item["relationships"] = ["app": ["data": ["type": "apps", "id": "1000000001"]]]
        case "foreign": item["relationships"] = ["app": ["data": ["type": "apps", "id": "1000000002"]]]
        case "null": item["relationships"] = ["app": ["data": NSNull()]]
        case "array": item["relationships"] = ["app": ["data": [["type": "apps", "id": "1000000001"]]]]
        default: break
        }
        return item
    }
    func handle(_ request: URLRequest) -> (Int, [String: String], Data) {
        lock.withLock {
            let path = request.url!.path, method = request.httpMethod ?? "GET"
            if method != "GET" {
                let body = try! JSONSerialization.jsonObject(with: apple.body(request)) as! [String: Any]
                if method == "PATCH", path == "/v1/betaAppReviewDetails/beta-detail-1" {
                    let item = body["data"] as! [String: Any]
                    for (key, value) in item["attributes"] as! [String: Any] { betaAttributes[key] = value }
                    writes.append((method, path, body)); return apple.page(detail())
                }
                if method == "PATCH", path == "/v1/builds/build-7", let answer = ((body["data"] as? [String: Any])?["attributes"] as? [String: Any])?["usesNonExemptEncryption"] {
                    var attributes = apple.builds[0]["attributes"] as! [String: Any]; attributes["usesNonExemptEncryption"] = answer; apple.builds[0]["attributes"] = attributes
                    writes.append((method, path, body)); return apple.page(apple.builds[0])
                }
                if method == "PATCH", path == "/v1/builds/build-7" {
                    let item = body["data"] as! [String: Any], relationships = item["relationships"] as! [String: Any]
                    let relationship = relationships["appEncryptionDeclaration"] as! [String: Any]
                    linkedPage = relationship["data"]!; writes.append((method, path, body)); return apple.page(apple.builds[0])
                }
                return (400, [:], Data())
            }
            switch path {
            case "/v1/apps/1000000001/betaAppReviewDetail":
                betaReads += 1
                if betaReads == changeBetaOnRead { betaAttributes["demoAccountPassword"] = "synthetic-changed-password" }
                return apple.page(betaAbsent ? NSNull() : betaDuplicate ? [detail(), detail()] : detail())
            case "/v1/betaAppReviewDetails/beta-detail-1/relationships/app": return apple.page(["type": "apps", "id": "1000000001"])
            case "/v1/apps/1000000001/appEncryptionDeclarations":
                declarationReads += 1
                if declarationReads == revokeOnRead { var attributes = declarations[0]["attributes"] as! [String: Any]; attributes["appEncryptionDeclarationState"] = "EXPIRED"; declarations[0]["attributes"] = attributes }
                return apple.page(declarations)
            case "/v1/preReleaseVersions/pre-1": return apple.page(["type": "preReleaseVersions", "id": wrongVersionID ? "pre-other" : "pre-1", "attributes": ["platform": platform]])
            case "/v1/builds/build-7/relationships/appEncryptionDeclaration": return apple.page(linkedPage)
            default: return apple.handle(request)
            }
        }
    }
}

@Suite(.serialized) struct TestFlightContentTests {
    init() throws { _ = try TestIsolation.require() }
    let app = "1000000001"
    func vector() throws -> JSONText { try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/testflight-review-content.json"))) }
    func resource(_ value: JSONText) throws -> AppStoreConnectClient.Resource { try JSONDecoder().decode(AppStoreConnectClient.Resource.self, from: value.data) }
    func request(_ account: Account, declaration: Bool = false) -> PublishRequest {
        var value = PublishRequest(accountId: account.id, appId: app, scope: .testflight, buildId: declaration ? "build-7" : nil)
        value.testflightAction = declaration ? "assign-encryption-declaration" : "save-beta-review-details"
        value.declarationId = declaration ? "decl-synthetic" : nil; return value
    }
    func approve(_ session: WorkspaceSession, _ account: Account, _ client: AppStoreConnectClient, _ review: PublishReview) async throws -> PublishReview {
        try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: client)
    }
    @Test func betaFieldsDigestsAndDeclarationLinkageMatchWebContracts() throws {
        let value = try vector(), detail = try resource(#require(value["betaDetail"]))
        #expect(try WorkspaceSession.betaReviewDetailsDigest(appId: app, detail: detail) == value["betaDigest"]?.text)
        #expect(ReviewInformation(Planner.resource(detail)["attributes"]).appleJSON == value["betaRemote"])
        guard case .array(let cases)? = value["betaValidation"], case .array(let declarations)? = value["declarationCases"] else { throw JSONText.ParseFailure.invalid }
        for item in cases {
            let input = try #require(item["input"])
            if item["valid"] == .bool(true) { #expect(try ReviewInformation.savedBetaFields(input).json == item["fields"]) }
            else { #expect(throws: PublishFailure.self) { try ReviewInformation.savedBetaFields(input) } }
        }
        for item in declarations {
            let resources = try JSONDecoder().decode([AppStoreConnectClient.Resource].self, from: #require(item["resources"]).data)
            if item["valid"] == .bool(true) {
                let id = try TestFlightEncryption.observedDeclaration(resources)
                #expect(id.map(JSONText.string) ?? .null == item["id"])
                #expect(TestFlightEncryption.declarationDigest(id) == item["digest"]?.text)
            } else { #expect(throws: PublishFailure.self) { try TestFlightEncryption.observedDeclaration(resources) } }
        }
    }
    @Test func encryptedWebDraftIsReadAndSeparateSessionsCompareUnderOneMutex() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), second = try WorkspaceSession(workspace: Workspace(root: root), vault: await session.vault), value = try vector()
        let saved = try await session.testFlightReviewInformationDraft(accountId: account.id, appId: app)
        #expect(saved.revision == 1 && saved.fields.json == value["betaSaved"]?["fields"])
        #expect(try await session.testFlightReviewInformationDraft(accountId: account.id, appId: "1000000002").revision == 0)
        var firstFields = saved.fields, secondFields = saved.fields; firstFields.notes = "First synthetic editor"; secondFields.notes = "Second synthetic editor"
        let a = firstFields, b = secondFields
        let outcomes = await withTaskGroup(of: Bool.self) { group in
            group.addTask { do { _ = try await session.saveTestFlightReviewInformationDraft(accountId: account.id, appId: app, fields: a, expectedRevision: 1); return true } catch { return false } }
            group.addTask { do { _ = try await second.saveTestFlightReviewInformationDraft(accountId: account.id, appId: app, fields: b, expectedRevision: 1); return true } catch { return false } }
            var result: [Bool] = []; for await item in group { result.append(item) }; return result
        }
        #expect(outcomes.filter { $0 }.count == 1)
        let current = try await second.testFlightReviewInformationDraft(accountId: account.id, appId: app)
        #expect(current.revision == 2 && [a.notes, b.notes].contains(current.fields.notes))
        await #expect(throws: PublishFailure.self) { try await session.saveTestFlightReviewInformationDraft(accountId: account.id, appId: app, fields: a, expectedRevision: 1) }
        let mutex = root.appendingPathComponent("state-v2/testflight_review_info_\(Apple.sha("\(account.id):\(app)").prefix(40)).mutex")
        #expect(FileManager.default.fileExists(atPath: mutex.path))
        #expect(try Data(contentsOf: mutex).isEmpty)
    }
    @Test func betaReviewPublishesOnlyDifferencesAfterOneApprovalAndHidesPasswords() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), model = try SyntheticBetaDeclarations(), host = "beta-details.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        StubProtocol.handle(host) { model.handle($0) }
        let review = try await session.preparePublishing(account: account, request: request(account), client: client)
        #expect(model.writes.isEmpty && review.steps.count == 1)
        #expect(review.steps[0].body?["data"]?["attributes"] == .object([("notes", .string("Saved synthetic beta notes"))]))
        #expect(!(review.steps[0].before ?? "").contains("synthetic-password-one") && !(review.steps[0].after ?? "").contains("synthetic-password-one"))
        #expect(try await approve(session, account, client, review).state == "complete")
        await #expect(throws: PublishFailure.used) { try await approve(session, account, client, review) }
        #expect(try await session.preparePublishing(account: account, request: request(account), client: client).steps.isEmpty)
        let draft = try await session.testFlightReviewInformationDraft(accountId: account.id, appId: app)
        var noDemo = draft.fields; noDemo.demoAccountRequired = false
        let clear = try await session.saveTestFlightReviewInformationDraft(accountId: account.id, appId: app, fields: noDemo, expectedRevision: draft.revision)
        #expect(clear.fields.demoAccountPassword.isEmpty && clear.fields.demoAccountName.isEmpty)
        let clearing = try await session.preparePublishing(account: account, request: request(account), client: client)
        #expect(clearing.steps.first?.body?["data"]?["attributes"]?["demoAccountPassword"] == .string(""))
        #expect(try await approve(session, account, client, clearing).state == "complete")
        #expect(model.betaAttributes["demoAccountPassword"] as? String == "" && model.writes.count == 2)
    }
    @Test func changedDraftAndRemotePasswordInvalidateAnEarlierBetaReview() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), model = try SyntheticBetaDeclarations(), host = "beta-details-stale.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        StubProtocol.handle(host) { model.handle($0) }
        let local = try await session.preparePublishing(account: account, request: request(account), client: client), saved = try await session.testFlightReviewInformationDraft(accountId: account.id, appId: app)
        var edited = saved.fields; edited.notes = "Changed synthetic draft"
        _ = try await session.saveTestFlightReviewInformationDraft(accountId: account.id, appId: app, fields: edited, expectedRevision: saved.revision)
        await #expect(throws: PublishFailure.conflict) { try await approve(session, account, client, local) }
        let fresh = try await session.preparePublishing(account: account, request: request(account), client: client)
        model.lock.withLock { model.changeBetaOnRead = model.betaReads + 2 }
        #expect(try await approve(session, account, client, fresh).state == "failed")
        #expect(model.writes.isEmpty)
        await #expect(throws: PublishFailure.used) { try await approve(session, account, client, fresh) }
    }
    @Test func betaOwnerAbsenceAmbiguityAndMalformedFieldsFailClosed() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), model = try SyntheticBetaDeclarations(), host = "beta-details-owners.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        StubProtocol.handle(host) { model.handle($0) }
        for owner in ["foreign", "null", "array"] {
            model.ownerMode = owner
            await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: request(account), client: client) }
        }
        model.ownerMode = "owned"; model.betaDuplicate = true
        await #expect(throws: PublishFailure.self) { try await session.testFlightReviewInformationFromApple(appId: app, client: client) }
        model.betaDuplicate = false; model.betaAbsent = true
        #expect(try await session.testFlightReviewInformationFromApple(appId: app, client: client) == nil)
        await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: request(account), client: client) }
        let initial = try await session.testFlightReviewInformationDraft(accountId: account.id, appId: app)
        await #expect(throws: PublishFailure.self) { try await session.saveTestFlightReviewInformationDraft(accountId: account.id, appId: app, fields: initial.fields, expectedRevision: -1) }
        try await session.storeAccess { store in try store.transaction { _ in [.put(namespace: "testflight_review_information_drafts", key: "\(account.id):\(app)", json: JSONText.object([("demoAccountRequired", .string("false"))]).data)] } }
        await #expect(throws: PublishFailure.self) { try await session.testFlightReviewInformationDraft(accountId: account.id, appId: app) }
        #expect(model.writes.isEmpty)
    }
    @Test func approvedDeclarationAssignmentHandlesNullAndConsumesReviewOnce() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), model = try SyntheticBetaDeclarations(), host = "build-declaration.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        StubProtocol.handle(host) { model.handle($0) }
        #expect(try await session.buildEncryptionDeclaration(appId: app, buildId: "build-7", client: client) == nil)
        let review = try await session.preparePublishing(account: account, request: request(account, declaration: true), client: client)
        #expect(model.writes.isEmpty && review.steps.count == 1 && review.steps[0].before == "No declaration assigned")
        #expect(try await approve(session, account, client, review).state == "complete")
        #expect(try await session.buildEncryptionDeclaration(appId: app, buildId: "build-7", client: client) == "decl-synthetic")
        await #expect(throws: PublishFailure.used) { try await approve(session, account, client, review) }
        #expect(try await session.preparePublishing(account: account, request: request(account, declaration: true), client: client).steps.isEmpty)
        #expect(model.writes.count == 1)
    }
    @Test func platformApprovalClassificationAndForeignDeclarationsAreRechecked() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), model = try SyntheticBetaDeclarations(), host = "build-declaration-ineligible.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        StubProtocol.handle(host) { model.handle($0) }
        for platform in ["MAC_OS", "UNKNOWN"] {
            model.platform = platform
            await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: request(account, declaration: true), client: client) }
        }
        model.platform = "IOS"; model.wrongVersionID = true
        await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: request(account, declaration: true), client: client) }
        model.wrongVersionID = false
        let approved = model.declarations[0]
        for owner in [NSNull(), ["type": "apps", "id": "1000000002"], [["type": "apps", "id": app]]] as [Any] {
            model.declarations[0]["relationships"] = ["app": ["data": owner]]
            await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: request(account, declaration: true), client: client) }
        }
        model.declarations = [approved]
        let review = try await session.preparePublishing(account: account, request: request(account, declaration: true), client: client)
        model.lock.withLock { model.revokeOnRead = model.declarationReads + 2 }
        #expect(try await approve(session, account, client, review).state == "failed")
        #expect(model.writes.isEmpty)
    }
    @Test func changedDeclarationLinkageAndUnsupportedWriteShapesAreRefused() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), model = try SyntheticBetaDeclarations(), host = "build-declaration-stale.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        StubProtocol.handle(host) { model.handle($0) }
        let review = try await session.preparePublishing(account: account, request: request(account, declaration: true), client: client)
        model.linkedPage = ["type": "appEncryptionDeclarations", "id": "decl-other"]
        await #expect(throws: PublishFailure.conflict) { try await approve(session, account, client, review) }
        model.linkedPage = NSNull()
        let step = try #require(review.steps.first), unsupported = JSONText.object([("type", .string("builds")), ("id", .string("build-7")), ("attributes", .object([("expired", .bool(true))])), ("relationships", step.body?["data"]?["relationships"] ?? .null)])
        await #expect(throws: PublishFailure.self) { try await session.verifyBuildDeclaration(method: "PATCH", parts: ["builds", "build-7"], data: unsupported, guardValue: step.guardValue, appId: app, client: client) }
        model.linkedPage = [["type": "appEncryptionDeclarations", "id": "decl-other"], ["type": "appEncryptionDeclarations", "id": "decl-synthetic"]]
        await #expect(throws: PublishFailure.self) { try await session.buildEncryptionDeclaration(appId: app, buildId: "build-7", client: client) }
        #expect(model.writes.isEmpty)
    }
    @Test func betaReviewAndDeclarationSelectionsRejectUnrelatedFieldsBeforeReads() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first)
        var beta = request(account); beta.usesNonExemptEncryption = false
        #expect(throws: PublishFailure.self) { try beta.validated() }
        beta = request(account); beta.buildId = "build-7"
        #expect(throws: PublishFailure.self) { try beta.validated() }
        var declaration = request(account, declaration: true); declaration.profileId = "profile-synthetic"
        #expect(throws: PublishFailure.self) { try declaration.validated() }
        declaration = request(account, declaration: true); declaration.declarationId = "../invalid"
        #expect(throws: PublishFailure.self) { try declaration.validated() }
        declaration = request(account, declaration: true); declaration.usesNonExemptEncryption = true
        #expect(throws: PublishFailure.self) { try declaration.validated() }
        #expect(try request(account).validated() == request(account))
        #expect(try request(account, declaration: true).validated() == request(account, declaration: true))
    }
}
