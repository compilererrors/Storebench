import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct ReleaseOverviewTests {
    init() throws { _ = try TestIsolation.require() }
    private let appId = "1000000001"
    private func account() -> Account { Account(id: "synthetic-account", name: "Synthetic Account", keyId: "SYNTHKEY01", keyType: "individual", issuerId: nil, appIds: [appId], appNames: nil) }
    private func plan(account: Account? = nil) throws -> ReleasePlan {
        let account = account ?? self.account()
        return try #require(ReleasePlan(.object([("accountId", .string(account.id)), ("appId", .string(appId)),
            ("sourceRevisionId", .string("00000000-0000-4000-8000-000000000002")), ("baseVersionId", .string("version-1")),
            ("platform", .string("MAC_OS")), ("targetVersion", .string("2.0")), ("releaseType", .string("MANUAL")), ("updatedAt", .string("2026-01-01T00:00:00.000Z"))])))
    }
    private func snapshot(_ plan: ReleasePlan, state: String = "PREPARE_FOR_SUBMISSION") throws -> ReleaseReadinessSnapshot {
        func step(_ id: String, _ label: String, _ state: ReleaseReadiness.State) -> ReleaseReadiness.Step {
            .init(id: id, label: label, detail: "Synthetic release requirement", href: "", action: "Open Release", state: state, territories: nil, guideHref: nil)
        }
        var language = step("local:sv", "Swedish Text and Screenshots", .blocked)
        language.issues = ["supportUrl", "description", "screenshots"].map { .init(field: $0, message: $0 + ": add text", section: $0 == "screenshots" ? "screenshots" : "text") }
        return .init(scope: try RecoveryGuidance.Scope(accountId: plan.accountId, appId: plan.appId), plan: plan,
            steps: [step("plan", "New Version", .ready), language, step("copyright", "Copyright", .blocked),
                    step("privacy", "App Privacy", .manual), step("build", "Build", .unknown), step("submission", "Add for Review", .blocked)],
            materialSignature: "synthetic-material", targetVersionId: "version-2", targetState: state)
    }

    @Test func threeSpecificRequirementsAndTheRestStaySeparateFromUnconfirmedChecks() throws {
        let plan = try plan(), summary = ReleaseOverview(plan: plan, snapshot: try snapshot(plan), status: nil)
        #expect(summary.preview.count == 3 && summary.moreCount == summary.items.count - 3)
        #expect(summary.items.filter { $0.kind == "blocked" }.count == 4)
        #expect(summary.items.contains { $0.title == "Swedish · Support URL" })
        #expect(summary.items.contains { $0.id == "checks" && $0.kind == "unknown" })
        #expect(!summary.items.contains { $0.id == "submission" })
        #expect(summary.status == "Prepare for Submission" && summary.action == "Continue Release")
    }

    @Test func submittedAndRejectedStatesDoNotReuseOldPreparationErrors() throws {
        let plan = try plan()
        for state in ["WAITING_FOR_REVIEW", "IN_REVIEW", "PENDING_DEVELOPER_RELEASE", "READY_FOR_DISTRIBUTION"] {
            let value = ReleaseOverview(plan: plan, snapshot: try snapshot(plan, state: state), status: nil)
            #expect(value.items.isEmpty && value.status == AppStoreNames.state(state))
        }
        let rejected = ReleaseOverview(plan: plan, snapshot: try snapshot(plan, state: "REJECTED"), status: nil)
        #expect(rejected.status == "Rejected" && rejected.preview.first?.id == "app-review-feedback")
        let unknown = ReleaseOverview(plan: plan, snapshot: nil, status: nil)
        #expect(unknown.items.count == 1 && unknown.items[0].kind == "unknown" && unknown.checkedAt == nil)
    }

    @Test func aForeignChecklistCannotSupplyTheDisplayedState() throws {
        let own = try plan(), foreign = Account(id: "synthetic-other", name: "Synthetic Other Account", keyId: "SYNTHKEY02", keyType: "individual", issuerId: nil, appIds: [appId], appNames: nil)
        let value = ReleaseOverview(plan: own, snapshot: try snapshot(plan(account: foreign), state: "WAITING_FOR_REVIEW"), status: nil)
        #expect(value.appleState == nil && value.preview.first?.kind == "unknown")
        let facts = AppReleaseStatus(account: foreign, appId: appId, versions: [.init(id: "version-2", platform: "MAC_OS", number: "2.0", state: "IN_REVIEW")], previous: nil, at: Date())
        #expect(facts.version(for: own) == nil && !facts.valid(account: account(), appId: appId))
    }

    @Test func theLatestVersionOnEachPlatformTakesPrecedenceOverAnOldRejection() {
        let status = AppReleaseStatus(account: account(), appId: appId, versions: [
            .init(id: "old-version", platform: "MAC_OS", number: "1.9", state: "REJECTED"),
            .init(id: "current-version", platform: "MAC_OS", number: "1.10", state: "READY_FOR_DISTRIBUTION")], previous: nil, at: Date())
        #expect(status.version(for: nil)?.id == "current-version")
        let value = ReleaseOverview(plan: nil, snapshot: nil, status: status)
        #expect(value.version == "1.10" && value.status == "Ready for Distribution" && value.items.isEmpty)
    }

    @Test func persistedStatusKeepsTheNewestConfirmationAcrossSessionsAndFailures() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), newer = Date(), older = newer.addingTimeInterval(-100)
        let waiting = PublishingWorkspace.Version(id: "version-2", platform: "MAC_OS", number: "2.0", state: "WAITING_FOR_REVIEW")
        await session.rememberAppReleaseStatus(account: account, appId: appId, versions: [waiting], at: newer)
        let second = try WorkspaceSession(workspace: Workspace(root: root), vault: await session.vault)
        #expect(await second.appReleaseStatus(account: account, appId: appId)?.version(for: nil)?.state == "WAITING_FOR_REVIEW")
        await second.rememberAppReleaseStatus(account: account, appId: appId, versions: [], at: older)
        #expect(await second.appReleaseStatus(account: account, appId: appId)?.versions.count == 1)
        await second.rememberAppReleaseStatus(account: account, appId: appId, versions: nil, at: newer.addingTimeInterval(10))
        let failed = try #require(await second.appReleaseStatus(account: account, appId: appId))
        #expect(failed.failed && failed.checkedAt == newer && failed.versions.first?.state == "WAITING_FOR_REVIEW")
        await second.rememberAppReleaseStatus(account: account, appId: "1000000099", versions: [waiting], at: newer)
        #expect(try await second.storeAccess { try $0.document(namespace: "app_release_status", key: account.id + ":1000000099") } == nil)
        let rows = try await second.connectedApps()
        #expect(rows.first?.release?.status == "Waiting for Review" && rows.first?.release?.failed == true)
    }

    @Test func startupChecksAreSmallFreshOncePerSessionAndReuseRecentResults() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let initial = try #require(try await session.accounts().first), host = "release-overview.appstoreconnect.test", apple = SyntheticApple()
        let account = Account(id: initial.id, name: initial.name, keyId: "SYNTHRLS01", keyType: initial.keyType, issuerId: initial.issuerId, appIds: initial.appIds, appNames: initial.appNames)
        try await session.storeAccess { store in try store.transaction { _ in [.put(namespace: "accounts", key: "all", json: JSONText.array([WorkspaceSession.json(account)]).data)] } }
        StubProtocol.handle(host) { request in
            guard request.httpMethod == "GET", let appId = account.appIds.first(where: { request.url?.path == "/v1/apps/\($0)/appStoreVersions" }) else {
                Issue.record("Unexpected synthetic release request: \(request.httpMethod ?? "") \(request.url?.path ?? "")"); return (404, [:], Data())
            }
            return apple.page([["type": "appStoreVersions", "id": "version-" + appId,
                "attributes": ["platform": "MAC_OS", "versionString": "2.0", "appVersionState": "WAITING_FOR_REVIEW"],
                "relationships": ["app": ["data": ["type": "apps", "id": appId]]]]])
        }
        let clients: @Sendable (Account) async throws -> AppStoreConnectClient = { try PublishingTests().client($0, host: host) }
        await session.refreshReleaseOverviews(clients: clients)
        let first = StubProtocol.requests(host).count
        let checked = await session.appReleaseStatus(account: account, appId: appId)?.checkedAt
        #expect(first == account.appIds.count && checked != nil)
        await session.refreshReleaseOverviews(clients: clients)
        #expect(StubProtocol.requests(host).count == first)
        await session.refreshReleaseOverviews(maxAge: 0, clients: clients)
        #expect(StubProtocol.requests(host).count == first * 2)
        let reopened = try WorkspaceSession(workspace: Workspace(root: root), vault: await session.vault)
        await reopened.refreshReleaseOverviews(clients: clients)
        #expect(StubProtocol.requests(host).count == first * 3)
        #expect(StubProtocol.requests(host).allSatisfy { $0.httpMethod == "GET" })
        let scope = try RecoveryGuidance.Scope(accountId: account.id, appId: appId)
        #expect(try ConnectedApps.Destination(scope: scope, source: "release").section == .release)
    }

    @Test func aSavedChecklistShowsItsConfirmedStateBeforeAnyStartupRequest() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first)
        let plan = try await session.saveReleasePlan(account: account, appId: appId, start: .reuse,
            sourceRevisionId: "00000000-0000-4000-8000-000000000002", baseVersionId: "version-1", targetVersion: "2.0", releaseType: "MANUAL", earliestReleaseDate: nil, expected: "null")
        let confirmed = try snapshot(plan, state: "WAITING_FOR_REVIEW"), checked = Date().addingTimeInterval(-300)
        await session.rememberReleaseReadiness(confirmed, checkedAt: checked)
        let saved = try #require(await session.releaseOverview(account: account, appId: appId))
        #expect(saved.status == "Waiting for Review" && saved.items.isEmpty && saved.checkedAt != nil)
        let reopened = try WorkspaceSession(workspace: Workspace(root: root), vault: await session.vault)
        let again = try #require(await reopened.releaseOverview(account: account, appId: appId))
        #expect(again.status == "Waiting for Review" && again.items.isEmpty)
    }
}
