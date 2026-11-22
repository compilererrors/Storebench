import Foundation
import Testing
@testable import StorebenchCore

/// A version still in progress at Apple, such as one Developer Rejected, stays a release in Storebench even without a plan made here.
@Suite(.serialized) struct ReleaseContinuationTests {
    init() throws { _ = try TestIsolation.require() }
    private let app = "1000000001", fixture = "00000000-0000-4000-8000-000000000002", rejected = "00000000-0000-4000-8000-0000000000aa"

    /// Saves a newer synthetic import in which the fixture's first version is in `state`, and returns that version's platform and number.
    private func importVersion(_ session: WorkspaceSession, account: String, state: String) async throws -> (id: String, platform: String, number: String) {
        let source = try JSONText.parse(try #require(try await session.storeAccess { try $0.document(namespace: "revisions", key: "\(account):\(app):\(fixture)") }).payload)
        guard case .array(var versions)? = source["versions"], let first = versions.first else { Issue.record("The fixture has no version"); throw CancellationError() }
        versions[0] = first.setting("fields", (first["fields"] ?? .object([])).setting("appVersionState", .string(state)))
        let revised = source.setting("id", .string(rejected)).setting("importedAt", .string("2030-01-01T00:00:00.000Z")).setting("versions", .array(versions))
        try await session.storeAccess { store in try store.transaction { _ in [.put(namespace: "revisions", key: "\(account):\(app):\(rejected)", json: revised.data)] } }
        return (try #require(first["id"]?.text), try #require(first["fields"]?["platform"]?.text), try #require(first["fields"]?["versionString"]?.text))
    }

    @Test func aDeveloperRejectedVersionBecomesTheReleaseToContinue() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first)
        #expect(try await session.releasePlan(accountId: account.id, appId: app) == nil)
        let version = try await importVersion(session, account: account.id, state: "DEVELOPER_REJECTED")
        let plan = try #require(try await session.continueReleaseInProgress(account: account, appId: app))
        #expect(plan.sourceRevisionId == rejected && plan.baseVersionId == version.id && plan.targetVersion == version.number && plan.platform == version.platform)
        #expect(try await session.releasePlan(accountId: account.id, appId: app)?.token == plan.token)
        // An app that already has a plan keeps it as it is.
        #expect(try await session.continueReleaseInProgress(account: account, appId: app) == nil)
    }

    @Test func aPlanThePersonRemovedIsNotBroughtBack() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first)
        _ = try await importVersion(session, account: account.id, state: "WAITING_FOR_REVIEW")
        let plan = try #require(try await session.continueReleaseInProgress(account: account, appId: app))
        try await session.dismissReleasePlan(accountId: account.id, appId: app, expected: plan.token)
        #expect(try await session.releasePlan(accountId: account.id, appId: app) == nil)
        #expect(try await session.continueReleaseInProgress(account: account, appId: app) == nil)
    }

    @Test func aVersionAppleHasReleasedSinceIsNotContinued() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first)
        let version = try await importVersion(session, account: account.id, state: "DEVELOPER_REJECTED")
        let live = [PublishingWorkspace.Version(id: version.id, platform: version.platform, number: version.number, state: "READY_FOR_SALE")]
        #expect(try await session.continueReleaseInProgress(account: account, appId: app, versions: live) == nil)
        #expect(try await session.releasePlan(accountId: account.id, appId: app) == nil)
    }
}
