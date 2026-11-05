import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct LibraryOverviewTests {
    init() throws { _ = try TestIsolation.require() }
    func list(_ value: JSONText?) throws -> [JSONText] { guard case .array(let rows)? = value else { throw ConnectedApps.Failure.changed }; return rows }
    func fixture() throws -> JSONText { try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/library-overview.json"))) }
    func integer(_ value: JSONText?) throws -> Int { guard case .number(let number)? = value, let result = Int(exactly: number) else { throw ConnectedApps.Failure.changed }; return result }
    func rows(_ values: [JSONText]) throws -> [ConnectedApps.Row] {
        let ids = Set(try values.map { try #require($0["accountId"]?.text) })
        let accounts = try Dictionary(uniqueKeysWithValues: ids.map { id in
            let apps = try values.filter { $0["accountId"]?.text == id }.map { try #require($0["appId"]?.text) }
            return (id, Account(id: id, name: "Synthetic library account", keyId: "SYNTHKEY01", keyType: "individual", issuerId: nil, appIds: apps, appNames: nil))
        })
        return try values.map { value in
            let accountId = try #require(value["accountId"]?.text), appId = try #require(value["appId"]?.text)
            let account = try #require(accounts[accountId])
            return try ConnectedApps.Row(account: account, app: #require(account.apps.first { $0.id == appId }), savedName: "Synthetic saved app", revisionCount: integer(value["revisionCount"]))
        }
    }
    func savePlans(_ values: [JSONText], session: WorkspaceSession) async throws {
        try await session.storeAccess { store in
            let value = JSONText.object([("schemaVersion", .number(1)), ("plans", .array(values))])
            try store.transaction { _ in [.put(namespace: "release_plans", key: "all", json: value.data)] }
        }
    }
    @Test func completePortfolioCountersScopeAndStablePlanOrderingMatchTheActualPrimary() throws {
        let cases = try list(fixture()["projections"]); #expect(cases.count == 6)
        for item in cases {
            let snapshot = try LibraryOverview.Snapshot(apps: rows(list(item["apps"])), plans: LibraryOverview.plans(list(item["plans"])), accountCount: integer(item["accounts"]))
            let expected = try #require(item["expected"])
            #expect(try snapshot.apps.count == integer(expected["configuredApps"]) && snapshot.accountCount == integer(expected["accountCount"]))
            #expect(try snapshot.materialApps == integer(expected["materialApps"]) && snapshot.awaitingMaterialApps == integer(expected["awaitingMaterialApps"]))
            #expect(try snapshot.releaseCount == integer(expected["releaseCount"]))
            let plans = try list(expected["releases"])
            #expect(snapshot.releases.count == plans.count)
            for (release, plan) in zip(snapshot.releases, plans) { #expect(try JSONText.parse(Data(release.plan.token.utf8)) == plan) }
        }
    }
    @Test func storedPlanValidationAndUtcLabelsUseActualPrimaryGoldens() throws {
        let fixture = try fixture(), cases = try list(fixture["validation"]), times = try list(fixture["times"])
        #expect(cases.count == 32 && times.count == 977)
        for item in cases {
            let value = try #require(item["value"])
            if item["rejected"] == .bool(true) { #expect(throws: ConnectedApps.Failure.self) { try LibraryOverview.plans([value]) } }
            else { #expect(try LibraryOverview.plans([value]).count == 1) }
        }
        for item in times {
            let value = try #require(item["value"]?.text), expected = try #require(item["expected"]?.text)
            let actual = LibraryOverview.timestamp(value)
            #expect(actual == expected, "Synthetic timestamp: \(value)")
            if case .number(let milliseconds)? = item["epochMilliseconds"] {
                let date = try #require(ReportTimestamps.date(value))
                #expect(abs(date.timeIntervalSince1970 * 1000 - milliseconds) < 0.01, "Synthetic epoch: \(value)")
            } else { #expect(ReportTimestamps.date(value) == nil) }
        }
    }
    @Test func globalLibraryNavigationPreservesSkippedOnboardingAndProtectsScopedDestinations() throws {
        for section in LibraryOverview.Section.allCases {
            #expect(LibraryOverview.content(selection: section.selection, connecting: false, hasApp: false) == .library(section))
            #expect(LibraryOverview.content(selection: section.selection, connecting: true, hasApp: false) == .connection)
        }
        #expect(LibraryOverview.content(selection: nil, connecting: false, hasApp: false) == .library(.overview))
        #expect(LibraryOverview.content(selection: "synthetic-library/1000000001", connecting: false, hasApp: true) == .app)
        #expect(LibraryOverview.content(selection: "synthetic-unknown", connecting: false, hasApp: false) == .empty)
        let cases = try list(fixture()["destinations"]); #expect(cases.count == 9)
        for item in cases {
            let row = try #require(rows([item]).first), key = try #require(item["section"]?.text)
            let section = try #require(AppNavigation.Section(key: key))
            let destination = try LibraryOverview.Destination(row: row, section: section)
            #expect(destination.href == item["expected"]?.text)
            #expect(destination.allowed(accounts: [row.account], decision: .ready))
            #expect(!destination.allowed(accounts: [row.account], decision: .wait, discardConfirmed: true))
            #expect(!destination.allowed(accounts: [row.account], decision: .confirmDiscard))
            #expect(destination.allowed(accounts: [row.account], decision: .confirmDiscard, discardConfirmed: true))
            #expect(!destination.allowed(accounts: [], decision: .ready))
        }
    }
    @Test func unavailableHistoryAndPlansNeverBecomeKnownEmptyTotals() throws {
        let descriptor = try #require(list(fixture()["destinations"]).first), known = try #require(rows([descriptor]).first)
        let unknown = try ConnectedApps.Row(account: known.account, app: known.app, savedName: nil, revisionCount: nil)
        let snapshot = try LibraryOverview.Snapshot(apps: [unknown], plans: [], accountCount: 1, plansUnavailable: true)
        #expect(snapshot.materialApps == nil && snapshot.awaitingMaterialApps == nil && snapshot.releaseCount == nil)
        #expect(throws: ConnectedApps.Failure.self) { try LibraryOverview.Snapshot(apps: [known, known], plans: [], accountCount: 1) }
        #expect(throws: ConnectedApps.Failure.self) { try LibraryOverview.Snapshot(apps: [known], plans: [], accountCount: 0) }
        let value = try #require(list(fixture()["validation"]).first?["value"]), plan = try #require(LibraryOverview.plans([value]).first)
        #expect(throws: ConnectedApps.Failure.self) { try LibraryOverview.plans(Array(repeating: JSONText.parse(Data(plan.token.utf8)), count: 2001)) }
        #expect(throws: ConnectedApps.Failure.self) { try LibraryOverview.Snapshot(apps: [known], plans: [plan, plan], accountCount: 1) }
        #expect(throws: ConnectedApps.Failure.self) { try LibraryOverview.Snapshot(apps: [known], plans: [plan], accountCount: 1, plansUnavailable: true) }
        #expect(throws: ConnectedApps.Failure.self) { try LibraryOverview.Destination(row: known, section: .history, plan: plan) }
        #expect(throws: ConnectedApps.Failure.self) { try LibraryOverview.Destination(row: known, section: .sales) }
    }
    @Test func encryptedOverviewReadsScopedPlansAndRejectsAChangedPlanBeforeNavigation() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let row = try #require(try await session.connectedApps().first)
        let history = try await session.archivedHistory(accountId: row.account.id, appId: row.app.id)
        let plan = JSONText.object([("accountId", .string(row.account.id)), ("appId", .string(row.app.id)), ("sourceRevisionId", .string(try #require(history.first).id)), ("baseVersionId", .string("synthetic-base")), ("platform", .string("IOS")), ("targetVersion", .string("2.0")), ("updatedAt", .string("2026-01-01T00:00:00Z"))])
        let foreign = JSONText.object([("accountId", .string("synthetic-foreign")), ("appId", .string(row.app.id)), ("sourceRevisionId", .string(try #require(history.first).id)), ("baseVersionId", .string("synthetic-base")), ("platform", .string("IOS")), ("targetVersion", .string("3.0")), ("updatedAt", .string("2026-01-02T00:00:00Z"))])
        try await savePlans([foreign, plan], session: session)
        let snapshot = try await session.libraryOverview(), release = try #require(snapshot.releases.first)
        #expect(snapshot.releases.count == 1 && !snapshot.plansUnavailable && snapshot.releaseCount == 1)
        #expect(release.app.latestImportedAt == history.first?.importedAt && release.title == row.name + " · 2.0")
        let destination = try LibraryOverview.Destination(row: release.app, section: .release, plan: release.plan)
        try await session.validateLibraryDestination(destination)
        try await savePlans([foreign], session: session)
        await #expect(throws: ConnectedApps.Failure.self) { try await session.validateLibraryDestination(destination) }
        let historyAction = try LibraryOverview.Destination(row: row, section: .history)
        try await session.validateLibraryDestination(historyAction)
        try await savePlans([plan, plan], session: session)
        let unknown = try await session.libraryOverview()
        #expect(unknown.plansUnavailable && unknown.releaseCount == nil && !unknown.apps.isEmpty && unknown.releases.isEmpty)
        try Setup.replaceGeneration(root.appendingPathComponent("state-v2"))
        await #expect(throws: SessionFailure.changed) { try await session.libraryOverview() }
        await #expect(throws: SessionFailure.changed) { try await session.validateLibraryDestination(historyAction) }
    }
    @Test func emptyOwnedWorkspaceRemainsUsableAndCanceledReadsFailClosed() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        try await session.storeAccess { store in
            try store.transaction { _ in [.put(namespace: "accounts", key: "all", json: JSONText.array([]).data)] }
        }
        let empty = try await session.libraryOverview()
        #expect(empty.apps.isEmpty && empty.accountCount == 0 && empty.materialApps == 0 && empty.awaitingMaterialApps == 0 && empty.releaseCount == 0)
        let read = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await session.libraryOverview() }
        await #expect(throws: CancellationError.self) { try await read.value }
    }
    @Test func aPlanShowsItsVersionStateAtAppleAndIsFinishedOnceReleased() throws {
        let plan = try #require(ReleasePlan(.object([("accountId", .string("synthetic-account")), ("appId", .string("1000000001")), ("sourceRevisionId", .string("synthetic-revision")),
            ("baseVersionId", .string("version-1")), ("platform", .string("MAC_OS")), ("targetVersion", .string("1.7")), ("updatedAt", .string("2026-01-02T03:04:05Z"))])))
        let other = PublishingWorkspace.Version(id: "version-0", platform: "MAC_OS", number: "1.6", state: "READY_FOR_DISTRIBUTION")
        #expect(LibraryOverview.planDescription(plan, state: nil) == "macOS · Local draft · Checking App Store Connect…")
        let missing = LibraryOverview.planState(plan, versions: [other])
        #expect(missing.state.isEmpty && !missing.released && LibraryOverview.planDescription(plan, state: missing) == "macOS · Not in App Store Connect yet")
        let preparing = LibraryOverview.planState(plan, versions: [other, .init(id: "version-2", platform: "MAC_OS", number: "1.7", state: "PREPARE_FOR_SUBMISSION")])
        #expect(!preparing.released && LibraryOverview.planDescription(plan, state: preparing) == "macOS · Prepare for Submission")
        for state in ["READY_FOR_DISTRIBUTION", "READY_FOR_SALE"] {
            #expect(LibraryOverview.planState(plan, versions: [.init(id: "version-2", platform: "MAC_OS", number: "1.7", state: state)]).released)
        }
        #expect(!LibraryOverview.planState(plan, versions: [.init(id: "version-2", platform: "IOS", number: "1.7", state: "READY_FOR_DISTRIBUTION")]).released)
        #expect(LibraryOverview.planDescription(plan, state: .init(planToken: "synthetic-older-plan", state: "PREPARE_FOR_SUBMISSION")).hasSuffix("Checking App Store Connect…"))
    }
}
