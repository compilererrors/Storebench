import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct SyncReceiptTests {
    init() throws { _ = try TestIsolation.require() }
    func fixture() throws -> JSONText { try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/sync-receipts.json"))) }
    func receipt(_ key: Int, checkedAt: String = "2026-02-04T12:00:00.000Z") -> SyncReceipt {
        SyncReceipt(key: JSONText.number(Double(key)).sha256, remote: JSONText.string("synthetic-remote").sha256, local: JSONText.null.sha256, checkedAt: checkedAt, outcome: .withApp)
    }
    @Test func modelsFreshnessAndFingerprintsMatchWeb() throws {
        let data = try fixture()
        guard case .array(let models)? = data["models"], case .array(let freshness)? = data["freshness"], case .array(let sales)? = data["sales"] else { throw SyncFailure.status }
        for row in models {
            let input = try #require(row["input"])
            if row["rejected"] == .bool(true) { #expect(throws: SyncFailure.status) { try SyncReceipts(json: input) } }
            else { #expect(try SyncReceipts(json: input).json == row["expected"], "Synthetic receipt model \(row["id"]?.stringify() ?? "unknown")") }
        }
        for row in freshness {
            let receipt = try SyncReceipt(json: #require(row["receipt"]))
            guard case .number(let now)? = row["now"] else { throw SyncFailure.status }
            #expect(receipt.freshSales(local: try #require(row["local"]?.text), day: try #require(row["day"]?.text), now: Date(timeIntervalSince1970: now / 1000)) == (row["expected"] == .bool(true)))
        }
        for row in sales {
            guard case .array(let ids)? = row["scope"]?["ids"] else { throw SyncFailure.status }
            #expect(SyncReceipt.salesKey(vendor: try #require(row["vendor"]?.text), reporterAccount: row["reporterAccount"]?.text, sku: row["sku"]?.text,
                                         scope: ProductScope(ids: ids.compactMap(\.text), complete: row["scope"]?["complete"] == .bool(true)), day: try #require(row["day"]?.text)) == row["expected"]?.text)
        }
        let analytics = try #require(data["analytics"])
        #expect(SyncReceipt.analyticsKey(kind: "downloads", level: "standard", granularity: "DAILY", instance: "synthetic-instance", processingDate: "2026-02-04") == analytics["key"]?.text)
        guard case .array(let buckets)? = analytics["buckets"] else { throw SyncFailure.status }
        let pairs = try buckets.map { value -> (String, String) in
            guard case .array(let pair) = value, pair.count == 2, let key = pair[0].text, let hash = pair[1].text else { throw SyncFailure.status }; return (key, hash)
        }
        #expect(SyncReceipt.analyticsLocal(pairs, kind: "downloads", level: "standard", granularity: "DAILY") == analytics["local"]?.text)
    }
    @Test func mergeIsBoundedReplacesKeysAndKeepsStableTies() throws {
        let old = SyncReceipts(accountId: "synthetic-account", appId: "1000000001", entries: (0..<1000).map { receipt($0) })
        let newer = receipt(500, checkedAt: "2026-02-05T00:00:00.000Z"), merged = try old.merging([newer, receipt(1000)])
        #expect(merged.entries.count == 1000 && merged.entries.first == newer)
        #expect(merged.entries[1] == receipt(0) && !merged.entries.contains { $0.key == receipt(1000).key })
        #expect(throws: SyncFailure.status) { try old.merging([newer, newer]) }
    }
    @Test func concurrentSessionsMergeWithoutLosingEntriesAndMalformedCachesStayDisposable() async throws {
        let helper = try SalesJobTests(), (session, account, root) = try await helper.session(); defer { try? FileManager.default.removeItem(at: root) }
        let second = try WorkspaceSession(workspace: Workspace(root: root), vault: await session.vault), store = try helper.store(root), appId = helper.appId
        async let firstWrite: Void = session.rememberSyncReceipts(account: account, appId: appId, entries: [receipt(1)])
        async let secondWrite: Void = second.rememberSyncReceipts(account: account, appId: appId, entries: [receipt(2)])
        _ = await (firstWrite, secondWrite)
        #expect(await session.syncReceipts(accountId: account.id, appId: appId)?.entries.count == 2)
        let mutex = try await session.syncReceiptMutex(accountId: account.id, appId: appId)
        let inode = try #require(try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber)
        await session.rememberSyncReceipts(account: account, appId: appId, entries: [receipt(3)])
        #expect(try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber == inode)
        let before = try await session.salesFileRecords(account: account, appId: appId).map(\.json), key = "\(account.id):\(appId)"
        for value in [JSONText.null, SyncReceipts(accountId: "synthetic-other", appId: appId, entries: [receipt(9)]).json] {
            try store.transaction { _ in [.put(namespace: "sync_receipts", key: key, json: value.data)] }
            #expect(await session.syncReceipts(accountId: account.id, appId: appId) == nil)
            await session.rememberSyncReceipts(account: account, appId: appId, entries: [receipt(4)])
            #expect(try store.document(namespace: "sync_receipts", key: key)?.payload == value.data)
        }
        #expect(try await session.salesFileRecords(account: account, appId: appId).map(\.json) == before)
        #expect(await session.syncReceipts(accountId: "invalid scope", appId: appId) == nil)
        await session.rememberSyncReceipts(account: account, appId: "1000000099", entries: [receipt(5)])
        #expect(try store.document(namespace: "sync_receipts", key: "\(account.id):1000000099") == nil)
    }
}

private final class ReceiptClock: @unchecked Sendable {
    private let lock = NSLock(); private var value = Date(timeIntervalSince1970: 1000)
    func now() -> Date { lock.withLock { value } }
    func advance(_ seconds: Double) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

@Suite(.serialized) struct SyncReceiptProcessTests {
    init() throws { _ = try TestIsolation.require() }
    @Test(arguments: [true, false]) func waitingCacheWritesRecheckCancellationAndScopeAfterOwnedProcessExit(cancel: Bool) async throws {
        let root = try TestIsolation.require().appendingPathComponent(cancel ? "sync-receipt-cancel-policy" : "sync-receipt-scope-policy")
        let helper = try SalesJobTests(), (session, account, _) = try await helper.session(directory: root), store = try helper.store(root)
        let appId = helper.appId, mutex = try await session.syncReceiptMutex(accountId: account.id, appId: appId)
        let inode = try #require(try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber)
        let entry = try SyncReceiptTests().receipt(100)
        let write = Task { await session.rememberSyncReceipts(account: account, appId: appId, entries: [entry]) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(try store.document(namespace: "sync_receipts", key: "\(account.id):\(appId)") == nil)
        if cancel { write.cancel() }
        else {
            let removed = Account(id: account.id, name: account.name, keyId: account.keyId, keyType: account.keyType, issuerId: account.issuerId, appIds: [], appNames: nil)
            try store.transaction { _ in [.put(namespace: "accounts", key: "all", json: JSONText.array([WorkspaceSession.json(removed)]).data)] }
        }
        try JobLock.exclusive(root.appendingPathComponent("lock-release"), "interrupt")
        await write.value
        #expect(try store.document(namespace: "sync_receipts", key: "\(account.id):\(appId)") == nil)
        #expect(try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber == inode)
        try store.transaction { _ in [.put(namespace: "accounts", key: "all", json: JSONText.array([WorkspaceSession.json(account)]).data)] }
        await session.rememberSyncReceipts(account: account, appId: appId, entries: [entry])
        #expect(await session.syncReceipts(accountId: account.id, appId: appId)?.entries == [entry])
    }
}
private actor ReceiptByteProbe {
    var calls = 0, cancelled = 0, released = false
    func release() { released = true }
    func matches(calls: Int, cancelled: Int) -> Bool { self.calls == calls && self.cancelled == cancelled }
    func load() async throws -> Data {
        calls += 1
        do { while !released { try await Task.sleep(for: .milliseconds(5)) }; try Task.checkCancellation(); return Data("synthetic-vendor-report".utf8) }
        catch { cancelled += 1; throw error }
    }
}
@Suite(.serialized) struct SharedReportBytesTests {
    init() throws { _ = try TestIsolation.require() }
    func wait(_ operation: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(try await operation()) { guard ContinuousClock.now < deadline else { throw FileMutex.Failure.timeout }; try await Task.sleep(for: .milliseconds(5)) }
    }
    @Test func aBorrowerCancelsItsWaitWithoutCancellingTheOwner() async throws {
        let cache = SharedReportBytes(), probe = ReceiptByteProbe()
        let owner = Task { try await cache.load(key: "synthetic-account:api:vendor:day") { try await probe.load() } }
        try await wait { await probe.calls == 1 }
        let borrower = Task { try await cache.load(key: "synthetic-account:api:vendor:day") { try await probe.load() } }
        try await Task.sleep(for: .milliseconds(20)); borrower.cancel()
        if case .success = await borrower.result { Issue.record("Cancelled borrower returned report bytes") }
        #expect(await probe.matches(calls: 1, cancelled: 0))
        await probe.release(); let data = try await owner.value
        #expect(try await cache.load(key: "synthetic-account:api:vendor:day") { throw SyncFailure.status } == data)
        #expect(await cache.status().bytes == data.count)
    }
    @Test func failedOrCancelledOwnerLetsBorrowersRetryTheirOwnDownload() async throws {
        let cache = SharedReportBytes(), probe = ReceiptByteProbe()
        let owner = Task { try await cache.load(key: "synthetic-shared") { try await probe.load() } }
        try await wait { await probe.calls == 1 }
        let follower = Task { try await cache.load(key: "synthetic-shared") { try await probe.load() } }
        try await Task.sleep(for: .milliseconds(20)); owner.cancel()
        if case .success = await owner.result { Issue.record("Cancelled owner returned report bytes") }
        try await wait { await probe.matches(calls: 2, cancelled: 1) }
        await probe.release(); #expect(try await follower.value == Data("synthetic-vendor-report".utf8))
        let failed = Task { try await cache.load(key: "synthetic-failure") { throw SyncFailure.status } }
        if case .success = await failed.result { Issue.record("Failed download returned bytes") }
        #expect(try await cache.load(key: "synthetic-failure") { Data([7]) } == Data([7]))
    }
    @Test func capacityExpiryClockRollbackAndScopeKeysPreventStaleSharing() async throws {
        let clock = ReceiptClock(), cache = SharedReportBytes(capacity: 3, lifetime: 10, clock: clock.now)
        #expect(try await cache.load(key: "synthetic-account:api") { Data([1, 2]) } == Data([1, 2]))
        #expect(try await cache.load(key: "synthetic-other-account:api") { Data([3, 4]) } == Data([3, 4]))
        #expect(await cache.status().bytes <= 3)
        #expect(try await cache.load(key: "synthetic-account:api") { Data([5]) } == Data([5]))
        clock.advance(10)
        #expect(try await cache.load(key: "synthetic-account:api") { Data([6]) } == Data([6]))
        clock.advance(-1)
        #expect(try await cache.load(key: "synthetic-account:api") { Data([7]) } == Data([7]))
        #expect(try await cache.load(key: "synthetic-account:reporter") { Data([8]) } == Data([8]))
    }
    @Test func lateCompletionOfAnExpiredLoadCannotRemoveItsReplacement() async throws {
        let clock = ReceiptClock(), cache = SharedReportBytes(lifetime: 1, clock: clock.now), probe = ReceiptByteProbe()
        let old = Task { try await cache.load(key: "synthetic-replaced") { try await probe.load() } }
        try await wait { await probe.calls == 1 }
        clock.advance(1)
        #expect(try await cache.load(key: "synthetic-replaced") { Data([9]) } == Data([9]))
        old.cancel()
        if case .success = await old.result { Issue.record("Cancelled old load returned bytes") }
        try await wait { await probe.cancelled == 1 }
        try await Task.sleep(for: .milliseconds(20))
        #expect(try await cache.load(key: "synthetic-replaced") { throw SyncFailure.status } == Data([9]))
    }
}
