import Foundation
import Testing
@testable import StorebenchCore

/// The Build step's Add Build: one review adds the chosen build to the Apple version and submits nothing.
@Suite(.serialized) struct VersionBuildTests {
    init() throws { _ = try TestIsolation.require() }
    let app = "1000000001"

    final class Versions: @unchecked Sendable {
        let apple = SyntheticApple()
        var attached: [String: Any]?
        var patches = 0
        init() {
            var version = apple.versions[0]["attributes"] as! [String: Any]; version["versionString"] = "2.0"; apple.versions[0]["attributes"] = version
        }
        func handle(_ request: URLRequest) -> (Int, [String: String], Data) {
            let path = request.url!.path, method = request.httpMethod ?? "GET"
            if method == "GET", path == "/v1/appStoreVersions/version-1/build" { return apple.lock.withLock { apple.page(attached ?? NSNull()) } }
            if method == "PATCH", path == "/v1/appStoreVersions/version-1" {
                return apple.lock.withLock {
                    let body = try! JSONSerialization.jsonObject(with: apple.body(request)) as! [String: Any], data = body["data"] as! [String: Any]
                    let relation = ((data["relationships"] as? [String: Any])?["build"] as? [String: Any])?["data"] as? [String: Any]
                    attached = apple.builds.first { $0["id"] as? String == relation?["id"] as? String }; patches += 1
                    return (200, [:], try! JSONSerialization.data(withJSONObject: ["data": apple.versions[0]]))
                }
            }
            return apple.handle(request)
        }
    }

    @Test func addBuildAttachesTheChosenBuildOnceWithoutSubmitting() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), synthetic = Versions(), host = "version-build.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        StubProtocol.handle(host) { synthetic.handle($0) }
        let request = PublishRequest(accountId: account.id, appId: app, scope: .versionBuild, versionId: "version-1", buildId: "build-7")
        #expect(try await session.versionBuildId(versionId: "version-1", appId: app, client: client) == nil)

        let review = try await session.preparePublishing(account: account, request: request, client: client)
        #expect(review.steps.map(\.label) == ["Select build 7"] && review.steps[0].before == "No build selected" && review.steps[0].after == "Build 7")
        #expect(synthetic.patches == 0)
        let done = try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: client)
        #expect(done.state == "complete", "\(done.error ?? "")")
        #expect(synthetic.patches == 1 && !synthetic.apple.writes.contains { $0.0 == "POST" || $0.1.contains("reviewSubmission") })
        #expect(try await session.versionBuildId(versionId: "version-1", appId: app, client: client) == "build-7")
        await #expect(throws: PublishFailure.used) { try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: client) }
        #expect(try await session.preparePublishing(account: account, request: request, client: client).steps.isEmpty)
    }

    @Test func addBuildIsRefusedWhenAppleChangesOrTheBuildDoesNotFit() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), synthetic = Versions(), host = "version-build-stale.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        StubProtocol.handle(host) { synthetic.handle($0) }
        let request = PublishRequest(accountId: account.id, appId: app, scope: .versionBuild, versionId: "version-1", buildId: "build-7")
        let review = try await session.preparePublishing(account: account, request: request, client: client)
        synthetic.apple.lock.withLock { synthetic.attached = ["type": "builds", "id": "build-other", "relationships": ["app": ["data": ["type": "apps", "id": "1000000001"]]]] }
        await #expect(throws: PublishFailure.conflict) { try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: client) }
        #expect(synthetic.patches == 0)

        synthetic.apple.lock.withLock { synthetic.attached = nil }
        var version = synthetic.apple.versions[0]["attributes"] as! [String: Any]; version["versionString"] = "3.0"; synthetic.apple.versions[0]["attributes"] = version
        await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: request, client: client) }
        #expect(throws: PublishFailure.self) { try PublishRequest(accountId: account.id, appId: app, scope: .versionBuild, versionId: "version-1").validated() }
        #expect(throws: PublishFailure.self) { try PublishRequest(accountId: account.id, appId: app, scope: .versionBuild, buildId: "build-7").validated() }
        #expect(synthetic.patches == 0)
    }

    @Test func theMissingBuildRowNamesAddBuildOnlyInTheWizard() {
        let missing = ReleaseReadiness.Step(id: "build", label: "App Store build", detail: "No build is attached to this Apple version. Choose an eligible build in the submission review.",
                                            href: "/synthetic/publish?scope=submit", action: "Choose build", state: .blocked, territories: nil, guideHref: nil)
        let shown = ReleaseWizard.presented(missing)
        #expect(shown.action == "Add Build" && shown.detail.contains("Add Build") && shown.href == missing.href && shown.state == .blocked)
        let ineligible = ReleaseReadiness.Step(id: "build", label: "App Store build", detail: "The attached build is not eligible for this platform and version.",
                                               href: missing.href, action: "Choose build", state: .blocked, territories: nil, guideHref: nil)
        #expect(ReleaseWizard.presented(ineligible).action == "Choose build")
    }
}
