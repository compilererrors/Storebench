import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct ConnectedAppsTests {
    init() throws { _ = try TestIsolation.require() }
    private func fixture() throws -> JSONText { try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/connected-apps.json"))) }
    private func rows(_ value: JSONText?) throws -> [JSONText] { guard case .array(let rows)? = value else { throw ConnectedApps.Failure.changed }; return rows }
    private func account(id: String = "synthetic-library", appId: String = "1000000001", name: String? = "Synthetic configured app") -> Account {
        .init(id: id, name: "Synthetic account", keyId: "SYNTHKEY01", keyType: "individual", issuerId: nil, appIds: [appId], appNames: name.map { [appId: $0] })
    }
    @Test func savedNamesLiteralWhitespaceAndUnicodeMatchTheActualPrimary() throws {
        let cases = try rows(fixture()["names"]); #expect(cases.count == 98)
        for row in cases {
            let appId = try #require(row["appId"]?.text), account = account(appId: appId, name: row["configured"]?.text)
            let projected = try ConnectedApps.Row(account: account, app: #require(account.apps.first), savedName: row["saved"]?.text, revisionCount: 2)
            #expect(projected.name.utf8.elementsEqual(try #require(row["expected"]?.text).utf8))
            #expect(projected.historyLabel == "2 revisions" && projected.id == account.id + "/" + appId)
        }
    }
    @Test func everySyncSourceUsesThePrimaryDestinationWithoutEditorContext() throws {
        let cases = try rows(fixture()["destinations"]); #expect(cases.count == 28)
        for row in cases {
            let scope = try RecoveryGuidance.Scope(accountId: #require(row["accountId"]?.text), appId: #require(row["appId"]?.text))
            let key = try #require(row["key"]?.text), destination = try ConnectedApps.Destination(scope: scope, source: key)
            #expect(destination.href == row["expected"]?.text)
            #expect(destination.analyticsKind == (key == "downloads" || key == "engagement" ? key : nil))
            let configured = account(id: scope.accountId, appId: scope.appId)
            #expect(destination.allowed(accounts: [configured], decision: .ready))
            #expect(!destination.allowed(accounts: [configured], decision: .wait, discardConfirmed: true))
            #expect(!destination.allowed(accounts: [configured], decision: .confirmDiscard))
            #expect(destination.allowed(accounts: [configured], decision: .confirmDiscard, discardConfirmed: true))
            #expect(!destination.allowed(accounts: [account(id: "synthetic-foreign")], decision: .ready))
        }
        let scope = try RecoveryGuidance.Scope(accountId: "synthetic-library", appId: "1000000001")
        #expect(try ConnectedApps.Destination(scope: scope).section == .overview)
        #expect(throws: ConnectedApps.Failure.self) { try ConnectedApps.Destination(scope: scope, source: "../synthetic") }
    }

    @Test func immutableAccountSnapshotsKeepScopeAndInvalidateTokensAfterLiteralChanges() throws {
        let base = account()
        func named(_ name: String) -> Account {
            Account(id: base.id, name: name, keyId: base.keyId, keyType: base.keyType, issuerId: base.issuerId, appIds: base.appIds, appNames: base.appNames)
        }
        let configured = named("Synthetic é")
        let snapshot = ConnectedApps.AccountSnapshot(configured), app = try #require(configured.apps.first)
        let row = try ConnectedApps.Row(snapshot: snapshot, app: app, savedName: nil, revisionCount: 0)
        let original = try ConnectedApps.Row(account: configured, app: app, savedName: nil, revisionCount: 0)
        #expect(row.accountToken == original.accountToken && row.account == original.account)
        let changed = try ConnectedApps.Row(snapshot: .init(named("Synthetic e\u{301}")), app: app, savedName: nil, revisionCount: 0)
        #expect(changed.accountToken != row.accountToken)
        #expect(snapshot.account.name.utf8.elementsEqual("Synthetic é".utf8))
        #expect(throws: ConnectedApps.Failure.self) {
            try ConnectedApps.Row(snapshot: snapshot, app: .init(id: "1000000999", name: "Synthetic foreign app"), savedName: nil, revisionCount: 0)
        }
    }
    @Test func mixedPartialAndSetupStatusesUseActualPrimaryCountsAndRetryPolicy() throws {
        let cases = try rows(fixture()["statuses"]); #expect(cases.count == 46)
        let account = account(), app = try #require(account.apps.first)
        for row in cases {
            if row["rejected"] == .bool(true) { #expect(throws: SyncFailure.status) { try SyncJob(json: #require(row["job"])) }; continue }
            let job = try SyncJob(json: #require(row["job"])), projected = try ConnectedApps.Row(account: account, app: app, savedName: nil, revisionCount: 1, sync: job)
            #expect(projected.syncLabel == row["label"]?.text && projected.needsRetry == (row["retry"] == .bool(true)))
            #expect(projected.canSync == !job.isActive)
            #expect(job.canRetry == (row["canRetry"] == .bool(true)))
            #expect(JSONText.object([("total", .number(Double(job.counts.total))), ("synced", .number(Double(job.counts.synced))), ("checked", .number(Double(job.counts.checked))), ("attention", .number(Double(job.counts.attention)))]) == row["counts"])
        }
        let unknown = try ConnectedApps.Row(account: account, app: app, savedName: nil, revisionCount: nil, syncUnavailable: true, materialUnavailable: true)
        #expect(unknown.historyLabel == "Saved history unavailable" && unknown.syncLabel == "Sync status unavailable" && !unknown.canSync && !unknown.needsRetry)
        let empty = try ConnectedApps.Row(account: account, app: app, savedName: nil, revisionCount: 0)
        #expect(empty.historyLabel == "0 revisions" && empty.syncLabel == "No data synced yet" && empty.canSync)
    }
    @Test func feedbackShowsSavedResultsAndSeparatesWaitingFromAttention() throws {
        let account = account(), app = try #require(account.apps.first)
        let time = "2026-02-03T12:34:56.000Z", date = try #require(ReportTimestamps.date(time))
        let states: [SyncItem.State] = [.synced, .synced, .partial, .failed, .attention, .waiting, .synced]
        let items = zip(AppSync.sources, states).map { source, state in SyncItem(key: source.0, state: state, detail: "Synthetic result", checkedAt: time) }
        var job = SyncJob(id: "00000000-0000-4000-8000-000000000401", accountId: account.id, appId: app.id, items: items, now: date)
        job.state = .complete
        let row = try ConnectedApps.Row(account: account, app: app, savedName: nil, revisionCount: 1, sync: job)
        #expect(row.syncLabel == "3 of 7 sources synced")
        #expect(row.syncFeedback == "3 need attention · 1 waiting for reports · Last sync 2026-02-03 12:34 UTC")
        let source = SyncSourceSummary(job: job)
        #expect(source.synced == 3 && source.attention == 3 && source.waiting == 1 && source.total == 7)
        job.items = job.items.map { SyncItem(key: $0.key, state: .synced, detail: "Synthetic checked result", checkedAt: time) }
        let success = try ConnectedApps.Row(account: account, app: app, savedName: nil, revisionCount: 1, sync: job)
        #expect(success.syncFeedback == "0 need attention · Last sync 2026-02-03 12:34 UTC")
        #expect(SyncSourceSummary(job: job).text == "7 of 7 sources synced · 0 need attention")
    }
    @Test func queuedSetupOnlyAndUnreadableFeedbackCannotClaimSuccessfulDownloads() throws {
        let account = account(), app = try #require(account.apps.first)
        var job = SyncJob(id: "00000000-0000-4000-8000-000000000402", accountId: account.id, appId: app.id, items: AppSync.pending(), now: Date())
        job.items[0].state = .running; job.items[0].detail = AppSync.waitingForSlot
        let queued = try ConnectedApps.Row(account: account, app: app, savedName: nil, revisionCount: 1, sync: job)
        #expect(queued.syncFeedback == "Queued · 0 of 7 checked · 0 need attention · 6 not checked · 1 syncing")
        #expect(!queued.syncFeedback.contains("Last sync"))
        job.state = .complete; job.statusOnly = true
        job.items = job.items.map { SyncItem(key: $0.key, state: .ready, detail: "Synthetic setup", checkedAt: CustomerReview.isoString(Date())) }
        let setup = try ConnectedApps.Row(account: account, app: app, savedName: nil, revisionCount: 1, sync: job)
        #expect(setup.syncFeedback == "Setup checked · 0 need attention · 7 ready to sync · Data not synced")
        #expect(SyncSourceSummary(job: job).synced == 0)
        job.items[0].state = .synced
        #expect(SyncSourceSummary(job: job).synced == 0 && SyncSourceSummary(job: job).notChecked == 1)
        let unreadable = try ConnectedApps.Row(account: account, app: app, savedName: nil, revisionCount: nil, syncUnavailable: true)
        #expect(unreadable.syncFeedback == "Sync results unavailable. Refresh status to check this app.")
        let unknown = SyncSourceSummary(job: nil)
        #expect(unknown.synced == 0 && unknown.attention == 0 && unknown.notChecked == 7)
    }
    @Test func aggregateProgressCountsFinishedChecksWithoutCallingPartialOrFailedSourcesSynced() throws {
        let states: [SyncItem.State] = [.synced, .partial, .failed, .waiting, .ready, .pending, .running]
        let items = zip(AppSync.sources, states).map { source, state in SyncItem(key: source.0, state: state, detail: "Synthetic sync progress") }
        let job = SyncJob(id: "00000000-0000-4000-8000-000000000403", accountId: "synthetic-library", appId: "1000000001", items: items, now: Date(timeIntervalSince1970: 0))
        let sources = SyncSourceSummary(job: job)
        let progress = SyncActivitySummary(activeApps: 1, totalApps: 1, sources: sources, unavailableApps: 0)
        #expect(sources.checked == 4 && sources.synced == 1 && sources.notChecked == 1 && sources.running == 1 && sources.ready == 1)
        #expect(progress.fractionChecked == 4.0 / 7.0)
        #expect(progress.progressLabel == "4 of 7 sources checked")
        #expect(progress.text.contains("1 of 7 sources synced"))
        var incomplete = sources; incomplete.include(SyncSourceSummary(job: nil))
        let unknown = SyncActivitySummary(activeApps: 1, totalApps: 2, sources: incomplete, unavailableApps: 1)
        #expect(unknown.fractionChecked == 4.0 / 14.0 && unknown.progressLabel == "4 of 14 sources checked")
        #expect(unknown.sources.notChecked == 8 && unknown.unavailableApps == 1)
    }
    @Test func progressKeepsSetupAndUnknownSourcesAtZeroAndReportsCompletedFailuresSeparately() throws {
        let empty = SyncActivitySummary(activeApps: 0, totalApps: 0, sources: SyncSourceSummary(), unavailableApps: 0)
        #expect(empty.fractionChecked == nil && empty.text == "No apps connected.")
        let pending = SyncActivitySummary(activeApps: 1, totalApps: 1, sources: SyncSourceSummary(job: nil), unavailableApps: 0)
        #expect(pending.fractionChecked == 0 && pending.progressLabel == "0 of 7 sources checked")
        var job = SyncJob(id: "00000000-0000-4000-8000-000000000404", accountId: "synthetic-library", appId: "1000000001", items: AppSync.pending(), now: Date(timeIntervalSince1970: 0))
        job.state = .complete; job.statusOnly = true
        for state in [SyncItem.State.ready, .synced] {
            job.items = job.items.map { SyncItem(key: $0.key, state: state, detail: "Synthetic setup check") }
            let setup = SyncActivitySummary(activeApps: 0, totalApps: 1, sources: SyncSourceSummary(job: job), unavailableApps: 0)
            #expect(setup.fractionChecked == 0 && setup.sources.synced == 0)
        }
        job.statusOnly = false
        job.items = job.items.map { SyncItem(key: $0.key, state: .failed, detail: "Synthetic failed check") }
        let failed = SyncActivitySummary(activeApps: 0, totalApps: 1, sources: SyncSourceSummary(job: job), unavailableApps: 0)
        #expect(failed.fractionChecked == 1 && failed.sources.synced == 0 && failed.sources.attention == 7)
        #expect(failed.text.contains("0 of 7 sources synced") && failed.text.contains("7 need attention"))
    }
    @Test func workspaceResultsMatchCardsWithoutTreatingMissingOrCorruptJobsAsSynced() async throws {
        let (session, original, root) = try await SalesJobTests().session()
        defer { try? FileManager.default.removeItem(at: root) }
        let apps = ["1000000001", "1000000002", "1000000003", "1000000004"]
        let configured = Account(id: original.id, name: original.name, keyId: original.keyId, keyType: original.keyType, issuerId: original.issuerId, appIds: apps, appNames: nil)
        let checked = "2026-02-03T12:34:56.000Z", date = try #require(ReportTimestamps.date(checked))
        let states: [SyncItem.State] = [.synced, .synced, .partial, .failed, .attention, .attention, .synced]
        var first = SyncJob(id: "00000000-0000-4000-8000-000000000403", accountId: configured.id, appId: apps[0],
                            items: zip(AppSync.sources, states).map { .init(key: $0.0.0, state: $0.1, detail: "Synthetic saved result", checkedAt: checked) }, now: date)
        first.state = .complete
        var cancelled = SyncJob(id: "00000000-0000-4000-8000-000000000404", accountId: configured.id, appId: apps[1],
                                items: AppSync.sources.enumerated().map { .init(key: $0.element.0, state: $0.offset == 0 ? .synced : .attention, detail: "Synthetic cancelled result", checkedAt: checked) }, now: date)
        cancelled.state = .cancelled
        let firstData = first.json.data, cancelledData = cancelled.json.data
        try await session.storeAccess { store in
            try store.transaction { _ in [
                .put(namespace: "accounts", key: "all", json: JSONText.array([WorkspaceSession.json(configured)]).data),
                .put(namespace: "jobs", key: "sync:\(configured.id):\(apps[0])", json: firstData),
                .put(namespace: "jobs", key: "sync:\(configured.id):\(apps[1])", json: cancelledData),
                .put(namespace: "jobs", key: "sync:\(configured.id):\(apps[3])", json: Data("{}".utf8))
            ] }
        }
        for _ in 0..<5 {
            let cards = try await session.connectedApps(), summary = try await session.syncActivitySummary()
            let synced = cards.compactMap(\.sync).reduce(0) { $0 + $1.counts.synced }
            let attention = cards.compactMap(\.sync).reduce(0) { $0 + $1.counts.attention }
            #expect(summary.totalApps == 4 && summary.activeApps == 0 && summary.unavailableApps == 1)
            #expect(summary.sources.total == 28 && summary.sources.synced == synced && summary.sources.attention == attention)
            #expect(summary.sources.synced == 4 && summary.sources.attention == 10 && summary.sources.notChecked == 14)
            #expect(summary.sources.checked == 14 && summary.fractionChecked == 0.5 && summary.progressLabel == "14 of 28 sources checked")
            #expect(summary.text == "4 apps · 4 of 28 sources synced · 10 need attention · 14 not checked · 1 app status unavailable")
        }
        #expect(try await session.storeAccess { try $0.document(namespace: "jobs", key: "sync:\(configured.id):\(apps[3])")?.payload == Data("{}".utf8) })
        let cancelledRead = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await session.syncActivitySummary() }
        await #expect(throws: CancellationError.self) { try await cancelledRead.value }
        try await session.signOut()
        await #expect(throws: SessionFailure.closed) { try await session.syncActivitySummary() }
    }
    @Test func accountChangesReplaceTheScopeTokenAndForeignJobsCannotEnterACard() throws {
        let first = account(), app = try #require(first.apps.first)
        let row = try ConnectedApps.Row(account: first, app: app, savedName: "Saved name", revisionCount: 2)
        let renamed = account(name: "Changed configured name"), next = try ConnectedApps.Row(account: renamed, app: #require(renamed.apps.first), savedName: "Saved name", revisionCount: 2)
        #expect(row.accountToken != next.accountToken)
        let refreshed = try ConnectedApps.Row(account: first, app: app, savedName: "Other saved name", revisionCount: 3)
        #expect(row.accountToken == refreshed.accountToken)
        let foreign = SyncJob(id: "11111111-1111-4111-8111-111111111111", accountId: "synthetic-foreign", appId: app.id, items: AppSync.pending(), now: Date())
        #expect(throws: ConnectedApps.Failure.self) { try ConnectedApps.Row(account: first, app: app, savedName: nil, revisionCount: 0, sync: foreign) }
        #expect(throws: ConnectedApps.Failure.self) { try ConnectedApps.Row(account: first, app: app, savedName: nil, revisionCount: -1) }
    }
    @Test func libraryTotalsRequireTheCompleteActualPrimaryRevisionContract() throws {
        let cases = try rows(fixture()["revisions"]); #expect(cases.count == 18)
        for row in cases {
            let value = try #require(row["value"]), accountId = "synthetic-account", appId = "1000000001", id = "00000000-0000-4000-8000-000000000002"
            if row["rejected"] == .bool(true) {
                #expect(throws: RevisionHistoryFailure.self) { try ConnectedApps.savedRevision(value, accountId: accountId, appId: appId, id: id, documentRevision: 1) }
            } else {
                let saved = try ConnectedApps.savedRevision(value, accountId: accountId, appId: appId, id: id, documentRevision: 1)
                #expect(saved.id == id && saved.value == value)
            }
        }
    }
    @Test func libraryReadsOwnedHistoryIncludingLocalSourcesAndKeepsUnavailableJobsUnknown() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), appId = "1000000001"
        var rows = try await session.connectedApps()
        let first = try #require(rows.first { $0.account.id == account.id && $0.app.id == appId })
        let history = try await session.archivedHistory(accountId: account.id, appId: appId)
        #expect(first.revisionCount == history.count && first.name == history.first?.value["app"]?["name"]?.text)
        try await session.storeAccess { store in
            let original = try #require(history.first).value
            guard case .object(let fields) = original else { throw ConnectedApps.Failure.changed }
            let id = "33333333-3333-4333-8333-333333333333"
            let changed = JSONText.object(fields.filter { $0.0 != "origin" }.map { key, value in
                (key, key == "id" ? .string(id) : key == "importedAt" ? .string("2026-03-01T00:00:00.000Z") : value)
            } + [("origin", .string("local"))])
            guard case .object(let appFields)? = changed["app"], case .object(let changedFields) = changed else { throw ConnectedApps.Failure.changed }
            let local = JSONText.object(changedFields.map { ($0.0, $0.0 == "app" ? .object(appFields.map { ($0.0, $0.0 == "name" ? .string("Synthetic saved draft name") : $0.1) }) : $0.1) })
            try store.transaction { _ in [
                .put(namespace: "revisions", key: "\(account.id):\(appId):\(id)", json: local.data),
                .put(namespace: "jobs", key: "sync:\(account.id):\(appId)", json: Data("{}".utf8)),
                .put(namespace: "jobs", key: "import:\(account.id):\(appId)", json: Data("{}".utf8))
            ] }
        }
        rows = try await session.connectedApps()
        let newer = try #require(rows.first { $0.account.id == account.id && $0.app.id == appId })
        #expect(newer.name == "Synthetic saved draft name" && newer.revisionCount == history.count + 1 && newer.syncUnavailable && newer.materialUnavailable && !newer.canSync)
        #expect(newer.accountToken == first.accountToken)
        let unchanged = try await session.storeAccess { store in
            try store.document(namespace: "jobs", key: "import:\(account.id):\(appId)")?.payload == Data("{}".utf8)
        }
        #expect(unchanged)
        try await session.validateConnectedApp(newer)
        try await session.storeAccess { store in
            let foreignId = "44444444-4444-4444-8444-444444444444", foreign = try ImportJobTests().revision(foreignId, accountId: "synthetic-foreign")
            try store.transaction { _ in [.put(namespace: "revisions", key: "\(account.id):\(appId):\(foreignId)", json: foreign.data)] }
        }
        let incomplete = try #require(try await session.connectedApps().first { $0.account.id == account.id && $0.app.id == appId })
        #expect(incomplete.revisionCount == nil && incomplete.historyLabel == "Saved history unavailable" && incomplete.syncUnavailable && incomplete.materialUnavailable)
        #expect(incomplete.name == ConnectedApps.name(saved: nil, configured: account.appNames?[appId], appId: appId))
        try Setup.replaceGeneration(root.appendingPathComponent("state-v2"))
        await #expect(throws: SessionFailure.changed) { try await session.connectedApps() }
        await #expect(throws: SessionFailure.changed) { try await session.validateConnectedApp(newer) }
    }
    @Test func staleCatalogClosedAndCanceledReadsCannotOpenAnOlderAppScope() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let row = try #require(try await session.connectedApps().first)
        try await session.storeAccess { store in
            let changed = Account(id: row.account.id, name: row.account.name, keyId: "SYNTHKEY02", keyType: row.account.keyType, issuerId: row.account.issuerId, appIds: row.account.appIds, appNames: row.account.appNames)
            let saved = try #require(try store.document(namespace: "accounts", key: "all"))
            try store.transaction { current in
                guard try current("accounts", "all")?.revision == saved.revision else { throw ConnectedApps.Failure.changed }
                return [.put(namespace: "accounts", key: "all", json: JSONText.array([WorkspaceSession.json(changed)]).data)]
            }
        }
        await #expect(throws: AccountFailure.stale) { try await session.validateConnectedApp(row) }
        let task = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await session.connectedApps() }
        await #expect(throws: CancellationError.self) { try await task.value }
        _ = session.lifetime.beginClosing()
        await #expect(throws: SessionFailure.closed) { try await session.connectedApps() }
    }
}
