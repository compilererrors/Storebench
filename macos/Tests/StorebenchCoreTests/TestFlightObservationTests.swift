import Foundation
import Testing
@testable import StorebenchCore

final class SyntheticBuildObservation: @unchecked Sendable {
    let lock = NSLock(), apple = SyntheticApple()
    var builds: [[String: Any]], included: [[String: Any]], declarations: [[String: Any]]
    var declarationStatus = 200, resolvedOwner = "1000000001"
    var requests: [URLRequest] = []
    init() throws {
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/testflight-observation.json"))) as! [String: Any]
        builds = [value["baseline"] as! [String: Any]]; included = value["included"] as! [[String: Any]]; declarations = value["declarations"] as! [[String: Any]]
    }
    func handle(_ request: URLRequest) -> (Int, [String: String], Data) {
        lock.withLock {
            requests.append(request)
            guard request.httpMethod == "GET" else { return (400, [:], Data()) }
            let path = request.url!.path, query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
            switch path {
            case "/v1/builds":
                guard query.count == 3, value("filter[app]") == "1000000001", value("include") == "app,preReleaseVersion,betaAppReviewSubmission,buildBetaDetail", value("limit") == "200" else { return (400, [:], Data()) }
                return (200, [:], try! JSONSerialization.data(withJSONObject: ["data": builds, "included": included]))
            case "/v1/apps/1000000001/appEncryptionDeclarations":
                guard query.count == 1, value("limit") == "200" else { return (400, [:], Data()) }
                return declarationStatus == 200 ? apple.page(declarations) : (declarationStatus, [:], Data())
            case "/v1/builds/build-synthetic/relationships/app": return apple.page(["type": "apps", "id": resolvedOwner])
            default: return (404, [:], Data())
            }
        }
    }
}

@Suite(.serialized) struct TestFlightObservationTests {
    init() throws { _ = try TestIsolation.require() }
    let app = "1000000001"
    func fixture() throws -> JSONText { try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/testflight-observation.json"))) }
    func resource(_ value: JSONText) throws -> AppStoreConnectClient.Resource { try JSONDecoder().decode(AppStoreConnectClient.Resource.self, from: value.data) }
    func resources(_ value: JSONText) throws -> [AppStoreConnectClient.Resource] { try JSONDecoder().decode([AppStoreConnectClient.Resource].self, from: value.data) }
    func replacing(_ value: AppStoreConnectClient.Resource, relationship: String, data: JSONValue?) -> AppStoreConnectClient.Resource {
        var relations = value.relationships ?? [:]; relations[relationship] = data.map { .object(["data": $0]) }
        return .init(type: value.type, id: value.id, attributes: value.attributes, relationships: relations)
    }
    @Test func observationsMatchTheWebForForwardReverseMissingAndAmbiguousRecords() throws {
        let vector = try fixture()
        guard case .array(let reviewCases)? = vector["reviewCases"], case .array(let detailCases)? = vector["detailCases"] else { throw JSONText.ParseFailure.invalid }
        for value in reviewCases {
            let build = try resource(#require(value["build"])), index = try TestFlightObservation.Index(included: resources(#require(value["included"])))
            let observation = index.review(build)
            #expect(observation.state.rawValue == value["state"]?.text && observation.resource?.id == value["reviewId"]?.text)
            #expect(observation.resource?.attributes?["betaReviewState"]?.string == value["betaReviewState"]?.text)
            #expect((observation.resource?.attributes?["betaReviewState"]?.string == "REJECTED") == (value["rejected"] == .bool(true)))
        }
        for value in detailCases {
            let build = try resource(#require(value["build"])), index = try TestFlightObservation.Index(included: resources(#require(value["included"])))
            #expect(index.detail(build)?.id == value["detailId"]?.text)
            #expect((index.detail(build)?.attributes?["externalBuildState"]?.string == "BETA_REJECTED") == (value["rejected"] == .bool(true)))
        }
        #expect(reviewCases.count == 88 && detailCases.count == 56)
    }
    @Test func exportDeclarationsMatchTheWebForAnswersLinksPlatformsAndCatalogs() throws {
        let vector = try fixture()
        guard case .array(let cases)? = vector["exportCases"] else { throw JSONText.ParseFailure.invalid }
        for value in cases {
            func classify() throws -> TestFlightObservation.ExportState {
                try TestFlightObservation.listedExportCompliance(build: resource(#require(value["build"])), versions: resources(#require(value["versions"])), declarations: value["declarations"] == .null ? nil : resources(#require(value["declarations"])), appId: app)
            }
            if value["valid"] == .bool(true) { #expect(try classify().rawValue == value["kind"]?.text) }
            else { #expect(throws: PublishFailure.self) { try classify() } }
        }
        #expect(cases.count == 1680)
    }
    @Test func buildActionsDistinguishExplicitAbsenceUnknownAndSiblingReview() throws {
        let vector = try fixture(), build = try resource(#require(vector["baseline"])), included = try resources(#require(vector["included"]))
        func model(_ build: AppStoreConnectClient.Resource, others: [AppStoreConnectClient.Resource] = [], extra: [AppStoreConnectClient.Resource] = []) throws -> TestFlightBuild {
            try #require(TestFlightObservation.models(appId: app, builds: [build] + others, included: included + extra, declarations: []).first { $0.id == build.id })
        }
        let none = try model(build)
        #expect(none.reviewObservation == .none && none.canSubmitForBetaReview && none.canCheckBetaReview && none.betaReviewDescription.contains("Not submitted"))
        let omitted = replacing(build, relationship: "betaAppReviewSubmission", data: nil), unknown = try model(omitted)
        #expect(unknown.reviewObservation == .unknown && !unknown.canSubmitForBetaReview && unknown.canCheckBetaReview && unknown.betaReviewDescription.contains("Status unavailable"))
        let review = try resource(.object([("type", .string("betaAppReviewSubmissions")), ("id", .string("review-sibling")), ("attributes", .object([("betaReviewState", .string("IN_REVIEW"))])), ("relationships", .object([("build", Apple.relationship("builds", .string("build-sibling")))]))]))
        let sibling = replacing(AppStoreConnectClient.Resource(type: build.type, id: "build-sibling", attributes: build.attributes, relationships: build.relationships), relationship: "betaAppReviewSubmission", data: .object(["type": .string("betaAppReviewSubmissions"), "id": .string("review-sibling")]))
        let blocked = try model(omitted, others: [sibling], extra: [review])
        #expect(blocked.otherBuildInBetaReview && !blocked.canCheckBetaReview && blocked.betaReviewDescription.contains("Another build"))
        let otherVersion = replacing(sibling, relationship: "preReleaseVersion", data: .object(["type": .string("preReleaseVersions"), "id": .string("other-version")]))
        #expect(try model(omitted, others: [otherVersion], extra: [review]).canCheckBetaReview)
        let noVersion = try model(replacing(build, relationship: "preReleaseVersion", data: nil))
        #expect(!noVersion.canCheckBetaReview && noVersion.betaReviewDescription.contains("Build version unavailable"))
    }
    @Test func includedRejectionsDuplicatesAndForeignDetailsNeverEnableManagement() throws {
        let vector = try fixture(), build = try resource(#require(vector["baseline"])), baselineIncluded = try resources(#require(vector["included"]))
        let detail = try #require(baselineIncluded.first { $0.type == "buildBetaDetails" })
        var attributes = detail.attributes!; attributes["externalBuildState"] = .string("BETA_REJECTED")
        let rejectedDetail = AppStoreConnectClient.Resource(type: detail.type, id: detail.id, attributes: attributes, relationships: detail.relationships)
        let rejected = try #require(TestFlightObservation.models(appId: app, builds: [build], included: baselineIncluded.filter { $0.type != "buildBetaDetails" } + [rejectedDetail], declarations: []).first)
        #expect(rejected.rejected && !rejected.canManage && !rejected.canCheckBetaReview && rejected.betaReviewDescription.contains("Upload a new build"))
        let duplicate = try #require(TestFlightObservation.models(appId: app, builds: [build], included: baselineIncluded + [detail], declarations: []).first)
        #expect(!duplicate.betaDetailConfirmed && duplicate.autoNotifyEnabled == nil && !duplicate.canNotifyTesters && !duplicate.canSetAutomaticNotification && !duplicate.canSubmitForBetaReview)
        let foreignDetail = replacing(detail, relationship: "build", data: .object(["type": .string("builds"), "id": .string("foreign-build")]))
        let foreign = try #require(TestFlightObservation.models(appId: app, builds: [build], included: baselineIncluded.filter { $0.type != "buildBetaDetails" } + [foreignDetail], declarations: []).first)
        #expect(!foreign.betaDetailConfirmed && foreign.externalState == nil)
        var encryptedAttributes = build.attributes!; encryptedAttributes["usesNonExemptEncryption"] = .bool(true)
        let encrypted = replacing(.init(type: build.type, id: build.id, attributes: encryptedAttributes, relationships: build.relationships), relationship: "appEncryptionDeclaration", data: .object(["type": .string("appEncryptionDeclarations"), "id": .string("declaration-synthetic")]))
        let declaration = try resources(#require(vector["declarations"]))
        #expect(try TestFlightObservation.models(appId: app, builds: [encrypted], included: baselineIncluded, declarations: declaration).first?.exportState == .approved)
        let version = try #require(baselineIncluded.first { $0.type == "preReleaseVersions" })
        let ambiguous = try #require(TestFlightObservation.models(appId: app, builds: [encrypted], included: baselineIncluded + [version], declarations: declaration).first)
        #expect(ambiguous.exportState == .unknown && ambiguous.platform.isEmpty && !ambiguous.canCheckBetaReview)
    }
    @Test func unavailableDeclarationsKeepBuildsReadableAndRequireConfirmedEncryptionForReview() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), model = try SyntheticBuildObservation(), host = "observation-declarations.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        StubProtocol.handle(host) { model.handle($0) }; model.declarationStatus = 403
        let plain = try #require(try await session.testFlightBuilds(appId: app, client: client).first)
        #expect(plain.exportState == .noNonexempt && plain.canCheckBetaReview)
        var attributes = model.builds[0]["attributes"] as! [String: Any]; attributes["usesNonExemptEncryption"] = true; model.builds[0]["attributes"] = attributes
        var relations = model.builds[0]["relationships"] as! [String: Any]; relations["appEncryptionDeclaration"] = ["data": ["type": "appEncryptionDeclarations", "id": "declaration-synthetic"]]; model.builds[0]["relationships"] = relations
        let unknown = try #require(try await session.testFlightBuilds(appId: app, client: client).first)
        #expect(unknown.exportState == .unknown && !unknown.canCheckBetaReview)
        model.declarationStatus = 200
        #expect(try await session.testFlightBuilds(appId: app, client: client).first?.exportState == .approved)
        model.declarations[0]["relationships"] = ["app": ["data": NSNull()]]
        #expect(try await session.testFlightBuilds(appId: app, client: client).first?.exportState == .unknown)
        #expect(model.requests.allSatisfy { $0.httpMethod == "GET" })
    }
    @Test func buildReadsResolveOmittedOwnersAndRejectExplicitInvalidAndDuplicateBuilds() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), model = try SyntheticBuildObservation(), host = "observation-ownership.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        StubProtocol.handle(host) { model.handle($0) }; let baseline = model.builds
        var relations = model.builds[0]["relationships"] as! [String: Any]; relations.removeValue(forKey: "app"); model.builds[0]["relationships"] = relations
        #expect(try await session.testFlightBuilds(appId: app, client: client).count == 1)
        model.resolvedOwner = "1000000002"
        await #expect(throws: PublishFailure.self) { try await session.testFlightBuilds(appId: app, client: client) }
        model.builds = baseline; model.builds[0]["relationships"] = ["app": ["data": NSNull()]]
        await #expect(throws: PublishFailure.self) { try await session.testFlightBuilds(appId: app, client: client) }
        model.builds = baseline + baseline
        await #expect(throws: PublishFailure.self) { try await session.testFlightBuilds(appId: app, client: client) }
        #expect(model.requests.allSatisfy { $0.httpMethod == "GET" })
    }
    @Test func credentialsChangedDuringDeclarationReadDiscardTheCompleteList() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), model = try SyntheticBuildObservation(), host = "observation-account-change.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        StubProtocol.handle(host) { request in
            let result = model.handle(request)
            if request.url!.path.hasSuffix("/appEncryptionDeclarations") {
                let store = try! EncryptedDocumentStore(url: EncryptedDocumentStore.databaseURL(root: root), key: Data(0..<32), writable: true)
                try! store.transaction { read in
                    let document = try read("accounts", "all")!, items = WorkspaceSession.items(try JSONText.parse(document.payload))
                    return [.put(namespace: "accounts", key: "all", json: JSONText.array(items.map { $0["id"]?.text == account.id ? $0.setting("keyId", .string("SAMPLE0002")) : $0 }).data)]
                }
            }
            return result
        }
        await #expect(throws: PublishFailure.self) { try await session.testFlightBuilds(appId: app, client: client) }
        #expect(model.requests.count == 2 && model.requests.allSatisfy { $0.httpMethod == "GET" })
    }
}
