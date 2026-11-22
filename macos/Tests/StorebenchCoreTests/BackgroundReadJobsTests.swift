import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) @MainActor struct BackgroundReadJobsTests {
    init() throws { _ = try TestIsolation.require() }
    private actor Probe {
        var checks = 0, reads = 0, preparations = 0, indexes = 0, cancellations = 0, releases = 0
        var due = true, hold = false
        var priorities: [AppleReadPriority] = []
        var order: [String] = []
        func check() -> Bool { checks += 1; order.append("catalog"); return due }
        func read() async throws -> AppCatalogRefresh {
            reads += 1; priorities.append(AppleReadPriority.current)
            if hold {
                do { while hold { try await Task.sleep(for: .milliseconds(10)) } }
                catch { cancellations += 1; throw error }
            }
            due = false
            return .init(accounts: 0, refreshedAccounts: 0, appCount: 0, issues: [], sample: false)
        }
        func prepare() { preparations += 1; priorities.append(AppleReadPriority.current) }
        func prepareIndexes() { indexes += 1; priorities.append(AppleReadPriority.current) }
        func releaseStates() { releases += 1; order.append("release"); priorities.append(AppleReadPriority.current) }
        func setHold(_ hold: Bool) { self.hold = hold }
    }
    private func fixture(_ probe: Probe, delay: Duration? = .milliseconds(20), poll: Duration = .milliseconds(30), preparation: Duration = .seconds(600)) throws -> (WorkspaceController, URL) {
        let root = try TestIsolation.require().appendingPathComponent("synthetic-background-\(UUID().uuidString)")
        let model = WorkspaceController(workspace: Workspace(root: root), writer: VaultWriter(dataRoot: root, storage: MemoryVaultStorage()),
            backupDelay: .seconds(3600), availabilityDelay: .seconds(3600), releaseWarmDelay: delay, backgroundReadInterval: poll, preparationInterval: preparation)
        model.backgroundReads = .init(releaseStates: { _ in await probe.releaseStates() }, catalogDue: { _ in await probe.check() }, catalog: { _ in try await probe.read() }, preparation: { _ in await probe.prepare() }, pricingIndexes: { _ in await probe.prepareIndexes() })
        return (model, root)
    }
    private func wait(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw FileMutex.Failure.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func unlockStartsSmallReadsAndLaterTicksReuseFreshResultsAndStopOnLock() async throws {
        let probe = Probe(), (model, root) = try fixture(probe); defer { try? FileManager.default.removeItem(at: root) }
        await model.start(); await model.setUp(password: nil)
        try await wait { await probe.preparations == 1 }
        try await wait { await probe.checks >= 3 }
        #expect(await probe.reads == 1)
        #expect(await probe.preparations == 1)
        #expect(await probe.indexes >= 1)
        #expect(await probe.releases >= 1)
        #expect(await probe.priorities.allSatisfy { $0 == .background })
        await model.signOut()
        let checks = await probe.checks
        try await Task.sleep(for: .milliseconds(90))
        #expect(await probe.checks == checks)
        #expect(model.session == nil && !model.refreshingApps)
    }

    @Test func multipleWindowActivationsJoinOneReadAndDoNotAccumulateJobs() async throws {
        let probe = Probe(); await probe.setHold(true)
        let (model, root) = try fixture(probe, delay: .seconds(3600)); defer { try? FileManager.default.removeItem(at: root) }
        await model.start(); await model.setUp(password: nil)
        let first = Task { await model.refreshBackgroundReads() }
        try await wait { await probe.reads == 1 }
        let others = (0..<10).map { _ in Task { await model.refreshBackgroundReads() } }
        try await Task.sleep(for: .milliseconds(30))
        #expect(await probe.reads == 1)
        await model.signOut()
        await first.value; for task in others { await task.value }
        #expect(await probe.cancellations == 1)
        #expect(await probe.preparations == 0)
        #expect(model.session == nil && !model.refreshingApps && model.appRefreshMessage.isEmpty)
    }

    @Test func preparationHasItsOwnCadenceAndActivationChecksItWithoutWaitingForATick() async throws {
        let probe = Probe(), (model, root) = try fixture(probe, delay: .seconds(3600), preparation: .milliseconds(30))
        defer { try? FileManager.default.removeItem(at: root) }
        await model.start(); await model.setUp(password: nil)
        await model.refreshBackgroundReads()
        #expect(await probe.preparations == 1)
        try await Task.sleep(for: .milliseconds(50))
        await model.refreshBackgroundReads()
        #expect(await probe.preparations == 2)
        #expect(await probe.reads == 1)
        await model.signOut()
    }

    @Test func disabledAndSampleSessionsNeverScheduleRemoteJobs() async throws {
        let disabled = Probe(), (model, root) = try fixture(disabled, delay: nil); defer { try? FileManager.default.removeItem(at: root) }
        await model.start(); await model.setUp(password: nil); await model.refreshBackgroundReads()
        #expect(await disabled.checks == 0)
        await model.signOut()
        let sample = Probe(), (sampleModel, sampleRoot) = try fixture(sample); defer { try? FileManager.default.removeItem(at: sampleRoot) }
        await sampleModel.start(); await sampleModel.openSampleData(); await sampleModel.refreshBackgroundReads()
        try await Task.sleep(for: .milliseconds(50))
        #expect(await sample.checks == 0)
        #expect(await sample.reads == 0)
        #expect(await sample.preparations == 0)
        #expect(await sample.indexes == 0)
        await sampleModel.prepareToTerminate()
    }

    @Test func explicitRefreshWaitsForTheAutomaticReadThenForcesItsOwnFullDiscovery() async throws {
        let probe = Probe(); await probe.setHold(true)
        let (model, root) = try fixture(probe, delay: .seconds(3600)); defer { try? FileManager.default.removeItem(at: root) }
        await model.start(); await model.setUp(password: nil)
        let automatic = Task { try await model.refreshApps(using: { _ in try await probe.read() }, automatic: true) }
        try await wait { await probe.reads == 1 }
        var joined = false
        let manual = Task { joined = true; return try await model.refreshApps(using: { _ in try await probe.read() }) }
        try await wait { joined }
        #expect(await probe.reads == 1)
        await probe.setHold(false)
        let automaticResult = try await automatic.value, manualResult = try await manual.value
        #expect(automaticResult == manualResult)
        #expect(await probe.reads == 2)
        await model.signOut()
    }

    @Test func catalogReplacementWaitsForEditsAndLaterAdoptsTheAlreadyFetchedResult() async throws {
        let probe = Probe(), (model, root) = try fixture(probe, delay: .seconds(3600)); defer { try? FileManager.default.removeItem(at: root) }
        await model.start(); await model.setUp(password: nil)
        var safe = false
        model.allowsAutomaticCatalogUpdates = { safe }
        let account = Account(id: "synthetic-auto-edit", name: "Synthetic Edited Account", keyId: "AUTOEDIT01", keyType: "individual", issuerId: nil, appIds: ["1000000001"], appNames: [:])
        model.backgroundReads.catalog = { session in
            _ = try await probe.read()
            try await session.storeAccess { store in
                try FileMutex.withLock(store.directory.appendingPathComponent("accounts.mutex")) {
                    try store.transaction { _ in [.put(namespace: "accounts", key: "all", json: JSONText.array([WorkspaceSession.json(account)]).data)] }
                }
            }
            return .init(accounts: 1, refreshedAccounts: 1, appCount: 1, issues: [], sample: false)
        }
        await model.refreshBackgroundReads()
        #expect(model.state == .unlocked([]), "Publishing a new catalog must not unmount an editor")
        #expect(try await model.session?.accounts() == [account])
        safe = true
        await model.refreshBackgroundReads()
        #expect(model.state == .unlocked([account]))
        #expect(await probe.reads == 1, "Adopting the deferred catalog does not spend another request")
        await model.signOut()
    }

    @Test func releaseStatusIsCheckedBeforeTheAppListAndSoonAfterOpening() async throws {
        let probe = Probe(), (model, root) = try fixture(probe, delay: .milliseconds(20), poll: .seconds(3600)); defer { try? FileManager.default.removeItem(at: root) }
        await model.start(); await model.setUp(password: nil)
        try await wait { let releases = await probe.releases, checks = await probe.checks; return releases == 1 && checks == 1 }
        #expect(await probe.order.prefix(2) == ["release", "catalog"])
    }
}
