import Foundation
import Testing
@testable import StorebenchCore

/// Saved release status between sessions: only for the same saved plan and connected app, newest wins, malformed rows are no status.
@Suite(.serialized) struct ReleaseStatusStoreTests {
    init() throws { _ = try TestIsolation.require() }
    private func plan(_ appId: String, account: String = "synthetic-account", target: String = "2.0") throws -> ReleasePlan {
        try #require(ReleasePlan(.object([("accountId", .string(account)), ("appId", .string(appId)),
            ("sourceRevisionId", .string("00000000-0000-4000-8000-000000000002")), ("baseVersionId", .string("synthetic-base")), ("platform", .string("MAC_OS")),
            ("targetVersion", .string(target)), ("releaseType", .string("MANUAL")), ("updatedAt", .string("2026-01-01T00:00:00.000Z"))])))
    }
    private func snapshot(_ plan: ReleasePlan, accountId: String, state: String) throws -> ReleaseReadinessSnapshot {
        let value = try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/release-readiness.json")))
        guard case .array(let cases)? = value["cases"], let input = cases.first?["input"] else { throw ReleaseReadiness.Failure.invalid }
        let fixture = try RecoveryGuidance.Scope(accountId: "synthetic-account", appId: "1000000001"), scope = try RecoveryGuidance.Scope(accountId: accountId, appId: plan.appId)
        return .init(scope: scope, plan: plan, steps: try ReleaseReadiness.steps(input, scope: fixture), materialSignature: "synthetic-saved-material", targetVersionId: "synthetic-version", targetState: state)
    }

    @Test func savedStatusRoundTripsAndKeepsOnlyTheNewestConfirmation() throws {
        let saved = try plan("1000000001"), value = try snapshot(saved, accountId: "synthetic-account", state: "WAITING_FOR_REVIEW"), checked = Date(timeIntervalSince1970: 1_900_000_000)
        let restored = try ReleaseReadinessSnapshot.saved(value.json(checkedAt: checked), accountId: "synthetic-account", appId: "1000000001", planToken: saved.token)
        #expect(restored.checkedAt == checked && restored.snapshot.targetState == "WAITING_FOR_REVIEW" && restored.snapshot.plan == saved)
        #expect(restored.snapshot.steps.map(\.json) == value.steps.map(\.json))
        #expect(throws: ReleaseReadiness.Failure.self) { try ReleaseReadinessSnapshot.saved(value.json(checkedAt: checked), accountId: "synthetic-account", appId: "1000000001", planToken: self.plan("1000000001", target: "3.0").token) }
        #expect(throws: ReleaseReadiness.Failure.self) { try ReleaseReadinessSnapshot.saved(value.json(checkedAt: checked), accountId: "synthetic-other", appId: "1000000001", planToken: saved.token) }
        let broken = value.json(checkedAt: checked).setting("steps", .array([.object([("id", .string("plan")), ("state", .string("synthetic"))])]))
        #expect(throws: ReleaseReadiness.Failure.self) { try ReleaseReadinessSnapshot.saved(broken, accountId: "synthetic-account", appId: "1000000001", planToken: saved.token) }
    }

    @Test func aLaterSessionOpensWithTheSavedStatusForConnectedAppsOnly() async throws {
        let helper = try SalesJobTests(), (session, account, root) = try await helper.session(); defer { try? FileManager.default.removeItem(at: root) }
        let saved = try plan(helper.appId, account: account.id), key = "\(account.id):\(helper.appId)", store = try helper.store(root)
        let newer = Date(timeIntervalSince1970: 1_900_000_100), older = Date(timeIntervalSince1970: 1_900_000_000)
        let waiting = try snapshot(saved, accountId: account.id, state: "WAITING_FOR_REVIEW"), rejected = try snapshot(saved, accountId: account.id, state: "DEVELOPER_REJECTED")
        await session.rememberReleaseReadiness(waiting, checkedAt: newer)
        let mutex = try await session.releaseStatusMutex(accountId: account.id, appId: helper.appId)
        let inode = try #require(try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber)

        let second = try WorkspaceSession(workspace: Workspace(root: root), vault: await session.vault)
        #expect(await second.rememberedReleaseReadiness(accountId: account.id, appId: helper.appId, planToken: saved.token).map { ($0.snapshot.targetState, $0.checkedAt) } ?? (nil, .distantPast) == ("WAITING_FOR_REVIEW", newer))
        #expect(await second.rememberedReleaseReadiness(accountId: account.id, appId: helper.appId, planToken: try plan(helper.appId, account: account.id, target: "3.0").token) == nil)
        await second.rememberReleaseReadiness(rejected, checkedAt: older)
        let third = try WorkspaceSession(workspace: Workspace(root: root), vault: await session.vault)
        #expect(await third.rememberedReleaseReadiness(accountId: account.id, appId: helper.appId, planToken: saved.token)?.snapshot.targetState == "WAITING_FOR_REVIEW")
        #expect(try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber == inode)

        try store.transaction { _ in [.put(namespace: "release_status", key: key, json: JSONText.null.data)] }
        let fourth = try WorkspaceSession(workspace: Workspace(root: root), vault: await session.vault)
        #expect(await fourth.rememberedReleaseReadiness(accountId: account.id, appId: helper.appId, planToken: saved.token) == nil)

        let other = try plan("1000000099", account: account.id)
        await session.rememberReleaseReadiness(try snapshot(other, accountId: account.id, state: "WAITING_FOR_REVIEW"), checkedAt: newer)
        #expect(try store.document(namespace: "release_status", key: "\(account.id):1000000099") == nil)
    }
}
