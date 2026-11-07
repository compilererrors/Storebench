import CryptoKit
import Foundation
import Testing
@testable import StorebenchCore

/// Whether the synthetic Apple endpoint answers yet.
final class SyntheticSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var on: Bool { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
}

/// Release opened for an existing version where only the build changes and Export Compliance is answered in step 4.
/// Synthetic Apple endpoints only; nothing here reaches a real account.
@Suite(.serialized) struct ReleaseBuildStepPipelineTests {
    init() throws { _ = try TestIsolation.require() }
    let app = "1000000001"

    func client(_ account: Account, host: String) throws -> AppStoreConnectClient {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubProtocol.self]
        return AppStoreConnectClient(token: try AppleToken(account: account, privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation), origin: URL(string: "https://\(host)")!, configuration: configuration)
    }
    func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }
    func build(_ id: String, uploaded: String, pre: String, encryption: Bool?) -> [String: Any] {
        var attributes: [String: Any] = ["version": id.replacingOccurrences(of: "build-", with: ""), "processingState": "VALID", "expired": false, "uploadedDate": uploaded, "buildAudienceType": "APP_STORE_ELIGIBLE"]
        if let encryption { attributes["usesNonExemptEncryption"] = encryption }
        return ["type": "builds", "id": id, "attributes": attributes,
                "relationships": ["app": ["data": ["type": "apps", "id": app]], "preReleaseVersion": ["data": ["type": "preReleaseVersions", "id": pre]]]]
    }
    var preReleases: [[String: Any]] {
        [["type": "preReleaseVersions", "id": "pre-20", "attributes": ["version": "2.0", "platform": "IOS"]],
         ["type": "preReleaseVersions", "id": "pre-19", "attributes": ["version": "1.9", "platform": "IOS"]]]
    }

    /// Two pages of builds for iOS 2.0; Apple also sends a 1.9 build on the first page. The attached build is only on the second page.
    func handleBuilds(_ request: URLRequest) -> (Int, [String: String], Data) {
        let url = request.url!, items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard request.httpMethod == "GET" else { return (405, [:], Data()) }
        switch url.path {
        case "/v1/appStoreVersions/version-1/build":
            return (200, [:], json(["data": build("build-19", uploaded: "2026-03-01T10:00:00Z", pre: "pre-20", encryption: false), "links": [:]]))
        case "/v1/builds" where value("filter[id]") == "build-19":
            return (200, [:], json(["data": [build("build-19", uploaded: "2026-03-01T10:00:00Z", pre: "pre-20", encryption: false)], "included": preReleases, "links": [:]]))
        case "/v1/builds" where value("cursor") == "synthetic-page-2":
            return (200, [:], json(["data": [build("build-20", uploaded: "2026-03-02T10:00:00Z", pre: "pre-20", encryption: nil),
                                             build("build-19", uploaded: "2026-03-01T10:00:00Z", pre: "pre-20", encryption: false)], "included": preReleases, "links": [:]]))
        case "/v1/builds":
            var next = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            next.queryItems = items + [URLQueryItem(name: "cursor", value: "synthetic-page-2")]
            return (200, [:], json(["data": [build("build-21", uploaded: "2026-03-03T10:00:00Z", pre: "pre-20", encryption: nil),
                                             build("build-old", uploaded: "2026-02-01T10:00:00Z", pre: "pre-19", encryption: false)],
                                    "included": preReleases, "links": ["next": next.string!]]))
        default: return (404, [:], Data())
        }
    }

    @Test func theFirstBuildViewReadsOnlyTheVersionsFirstPageAndTheAttachedBuild() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), host = "release-build-first.appstoreconnect.test"
        StubProtocol.handle(host) { handleBuilds($0) }
        let client = try client(account, host: host)

        let first = try await session.releaseBuildPage(appId: app, versionId: "version-1", platform: "IOS", version: "2.0", all: false, client: client)
        // A first page is partial: it never claims that a build it does not list is missing.
        #expect(!first.complete)
        // The attached build is read on its own, so it shows although it is not on the first page; a build of another version never shows.
        #expect(first.attachedId == "build-19")
        #expect(first.builds.map(\.id) == ["build-21", "build-19"])
        // Its export compliance answer comes with the build: unanswered for the newest, answered for the attached one.
        #expect(first.builds.first { $0.id == "build-21" }?.missingCompliance == true)
        #expect(first.builds.first { $0.id == "build-19" }?.usesNonExemptEncryption == false)

        let requests = StubProtocol.requests(host)
        #expect(requests.allSatisfy { $0.httpMethod == "GET" })
        let lists = requests.filter { $0.url?.path == "/v1/builds" }.compactMap { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems }
        let listing = try #require(lists.first { items in !items.contains { $0.name == "filter[id]" } })
        func value(_ name: String) -> String? { listing.first { $0.name == name }?.value }
        #expect(value("filter[app]") == app && value("filter[preReleaseVersion.platform]") == "IOS" && value("filter[preReleaseVersion.version]") == "2.0")
        #expect(value("sort") == "-uploadedDate" && value("limit") == "\(WorkspaceSession.releaseBuildPageSize)" && value("include") == "app,preReleaseVersion")
        // Build history and TestFlight details are not part of the first view.
        #expect(!lists.contains { $0.contains { $0.name == "cursor" } })
        #expect(!requests.contains { request in ["buildBetaDetail", "betaAppReviewSubmission", "appEncryptionDeclarations"].contains { request.url!.absoluteString.contains($0) } })

        // The rest of the version's builds follow on request, and only then is the list complete.
        let every = try await session.releaseBuildPage(appId: app, versionId: "version-1", platform: "IOS", version: "2.0", all: true, client: client)
        #expect(every.complete && every.attachedId == "build-19" && every.builds.map(\.id) == ["build-21", "build-20", "build-19"])
        #expect(StubProtocol.requests(host).allSatisfy { $0.httpMethod == "GET" })

        // A pre-release version repeated on each page counts once; two copies that differ stay ambiguous, so no version is confirmed from them.
        func version(_ name: String) -> AppStoreConnectClient.Resource { .init(type: "preReleaseVersions", id: "pre-20", attributes: ["version": .string(name), "platform": .string("IOS")], relationships: nil) }
        #expect(WorkspaceSession.mergedIncluded([version("2.0"), version("2.0")]).count == 1)
        #expect(WorkspaceSession.mergedIncluded([version("2.0"), version("2.1"), version("2.0")]).count == 3)
    }

    @Test func aFailedBuildContinuationLeavesTheOlderChoicePending() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), host = "release-build-continuation.appstoreconnect.test"
        StubProtocol.handle(host) { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if query.contains(where: { $0.name == "cursor" }) { return (404, [:], Data()) }
            return handleBuilds(request)
        }
        let client = try client(account, host: host)
        let first = try await session.releaseBuildPage(appId: app, versionId: "version-1", platform: "IOS", version: "2.0", all: false, client: client)
        let chosen = ReleaseWizard.chosenBuild("build-20", matching: first.builds, attachedId: first.attachedId, complete: first.complete)
        #expect(chosen == "build-20")
        await #expect(throws: AppStoreConnectClient.Failure.status(404)) {
            _ = try await session.releaseBuildPage(appId: app, versionId: "version-1", platform: "IOS", version: "2.0", all: true, client: client)
        }
        #expect(ReleaseWizard.chosenBuild(chosen, matching: first.builds, attachedId: first.attachedId, complete: first.complete) == "build-20")
        #expect(StubProtocol.requests(host).allSatisfy { $0.httpMethod == "GET" })
    }

    func plan() throws -> ReleasePlan {
        try #require(ReleasePlan(.object([("accountId", .string("synthetic-account")), ("appId", .string(app)), ("sourceRevisionId", .string("synthetic-revision")),
            ("baseVersionId", .string("version-1")), ("platform", .string("IOS")), ("targetVersion", .string("2.0")), ("releaseType", .string("MANUAL")),
            ("updatedAt", .string("2026-01-01T00:00:00.000Z"))])))
    }
    func step(_ id: String, _ state: ReleaseReadiness.State, _ detail: String = "Synthetic check") -> ReleaseReadiness.Step {
        ReleaseReadiness.Step(id: id, label: id, detail: detail, href: "/synthetic", action: "Open", state: state, territories: nil, guideHref: nil)
    }
    /// An existing version: text and screenshots saved, the build attached, its export compliance not answered yet.
    func steps(compliance: ReleaseReadiness.State, language: ReleaseReadiness.State = .ready) -> [ReleaseReadiness.Step] {
        [step("local:en-US", language), step("version", .ready), step("copyright", .ready), step("build", .ready), step("export-compliance", compliance),
         step("review-info", .unknown), step("age-rating", .unknown), step("accessibility", .blocked), step("territories", .ready), step("submission", .unknown)]
    }

    @Test func step4DoesNotWaitForListingEditorsAndReadsAddForReviewsOtherPrerequisites() throws {
        // Only the steps that show the listing read every language and its media; Build and the steps after it never wait for them.
        #expect(ReleaseWizard.needsListing("listing") && ReleaseWizard.needsListing("plan"))
        for phase in ["send", "build", "review-information", "submit", "release"] { #expect(!ReleaseWizard.needsListing(phase)) }
        #expect(ReleaseWizard.reads("build") == [.versions, .build])

        // While compliance is unanswered, what Add for Review verifies apart from the build is read: from its planner, from the step's own checks and its price.
        let guide = ReleaseGuide.guide(steps(compliance: .blocked), appleState: "PREPARE_FOR_SUBMISSION")
        #expect(ReleaseWizard.unfinished(before: "submit", in: guide) != nil)
        let ahead = ReleaseWizard.submissionAhead(guide)
        #expect(ahead.isSuperset(of: [.reviewInformation, .ageRating, .accessibility, .pricing]))
        #expect(ahead.isDisjoint(with: [.build, .exportCompliance, .listing, .copyright, .version]))
        let planned = Set(WorkspaceSession.submissionChecks).subtracting(WorkspaceSession.submissionBuildChecks).subtracting([.listing, .copyright])
        #expect(ahead.isSuperset(of: planned))
    }

    @Test func aConfirmedComplianceAnswerChangesTheBasisOfAPreparedSubmission() throws {
        let scope = try RecoveryGuidance.Scope(accountId: "synthetic-account", appId: app), plan = try plan()
        func snapshot(_ steps: [ReleaseReadiness.Step]) -> ReleaseReadinessSnapshot {
            ReleaseReadinessSnapshot(scope: scope, plan: plan, steps: steps, materialSignature: "synthetic", targetVersionId: "version-1", targetState: "PREPARE_FOR_SUBMISSION")
        }
        let unanswered = ReleaseWizard.submissionBasis(snapshot(steps(compliance: .blocked)))
        // Apple's state stays Prepare for Submission; the answered build still gives a new basis.
        #expect(unanswered != ReleaseWizard.submissionBasis(snapshot(steps(compliance: .ready))))
        // A local listing check is not part of Add for Review's basis.
        #expect(unanswered == ReleaseWizard.submissionBasis(snapshot(steps(compliance: .blocked, language: .blocked))))
    }

    @Test func aFailedOrOutdatedReviewAheadIsReplacedAndAnApprovalDiscardsIt() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "release-review-ahead.appstoreconnect.test"
        let reachable = SyntheticSwitch()
        StubProtocol.handle(host) { request in reachable.on ? apple.handle(request) : (404, [:], Data()) }
        let client = try client(account, host: host)
        let request = PublishRequest(accountId: account.id, appId: app, scope: .versionCopyright, versionId: "version-1", copyright: "2026 Synthetic Studio")

        // A preparation that fails leaves at once, so the next request prepares again instead of waiting for the old task.
        await session.preparePublishingAhead(account: account, request: request, basis: "unanswered", client: client)
        let failed = try #require(await session.reviewsAhead.first)
        _ = try? await failed.task.value
        #expect(await session.reviewsAhead.isEmpty)

        reachable.on = true
        await session.preparePublishingAhead(account: account, request: request, basis: "unanswered", client: client)
        let first = try #require(await session.reviewsAhead.first)
        _ = try await first.task.value
        // The same basis keeps the preparation; a confirmed change at Apple replaces it.
        await session.preparePublishingAhead(account: account, request: request, basis: "unanswered", client: client)
        #expect(await session.reviewsAhead.map(\.id) == [first.id])
        await session.preparePublishingAhead(account: account, request: request, basis: "answered", client: client)
        let replaced = try #require(await session.reviewsAhead.first)
        #expect(replaced.id != first.id && replaced.basis == "answered")
        let ready = try await replaced.task.value
        #expect(ready.state == "prepared" && apple.writes.isEmpty)

        // Approving any review for the app makes the remaining preparations out of date; none is offered afterwards.
        let other = try await session.preparePublishing(account: account, request: PublishRequest(accountId: account.id, appId: app, scope: .versionCopyright, versionId: "version-1", copyright: "2026 Synthetic Example"), client: client)
        _ = try await session.approvePublishing(account: account, appId: app, id: other.id, fingerprint: other.fingerprint, client: client)
        #expect(await session.reviewsAhead.isEmpty)
        #expect(await session.reviewPreparedAhead(request) == nil)
    }
}
