import Foundation
import Testing
@testable import StorebenchCore

/// Session and window caches with synthetic content: byte accounting, immediate shrinking, Clear Cache, memory pressure and
/// saved-read retention without a restart.
@Suite(.serialized) struct CacheMemoryTests {
    init() throws { _ = try TestIsolation.require() }
    struct Value: Codable, Equatable, Sendable { let text: String }
    private static func value(_ bytes: Int, _ tag: String = "x") -> Value { Value(text: String(repeating: tag, count: bytes)) }

    @MainActor private static func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while await !condition() {
            guard ContinuousClock.now < deadline else { Issue.record("Timed out waiting for the synthetic cache."); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func filledSessionCachesAreFreedByMemoryPressureAndClearing() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first(where: { !$0.appIds.isEmpty })), appId = try #require(account.appIds.first)
        _ = try await session.revisions(accountId: account.id, appId: appId)
        try await session.fillSyntheticCaches(accountId: account.id, appId: appId)
        let filled = await session.cacheCosts()
        #expect(filled.decoded > 0 && filled.release > 0 && filled.library > 0 && filled.apple > 0)
        #expect(await session.cachedMemoryBytes() == filled.decoded + filled.release + filled.library + filled.apple + filled.other)

        // A smaller budget shrinks what is already kept.
        await session.applyCachePolicy(CachePolicy(level: .custom, customMemoryMB: CachePolicy.memoryRange.lowerBound, customLifetimeMinutes: 1))
        let budget = CachePolicy(level: .custom, customMemoryMB: CachePolicy.memoryRange.lowerBound, customLifetimeMinutes: 1).budget()
        let shrunk = await session.cacheCosts()
        #expect(shrunk.decoded <= budget.decodedRevisions.bytes && shrunk.release <= budget.releaseStatus.bytes && shrunk.apple <= budget.appleReads.bytes)

        await session.trimCachedMemory()
        let trimmed = await session.cacheCosts()
        #expect(trimmed.decoded == 0 && trimmed.release == 0 && trimmed.library == 0 && trimmed.apple == 0)

        try await session.fillSyntheticCaches(accountId: account.id, appId: appId)
        #expect(await session.cachedMemoryBytes() > 0)
        await session.clearCachedReads()
        #expect(await session.cachedMemoryBytes() == 0)
        // Saved work stays.
        #expect(try await !session.revisions(accountId: account.id, appId: appId).isEmpty)
    }

    @MainActor @Test func aWindowCountsDecodedAndSavedReadsAndShrinksAtOnce() async throws {
        let window = NavigationPresentation()
        window.readCapacity = CachePolicy.Limit(count: 16, bytes: 1_000_000)
        window.preload(["synthetic/saved-old": (Data(count: 40_000), Date(timeIntervalSince1970: 1_000)), "synthetic/saved-new": (Data(count: 40_000), Date(timeIntervalSince1970: 2_000))], epoch: 0, clearCount: window.clearCount)
        #expect(window.retainedReadBytes == 80_000 && window.rememberedReadCount == 2)
        for index in 0..<4 { window.remember(Self.value(30_000), read: "synthetic/read-\(index)") }
        // Encoded size × the decoded factor replaces the first estimate once known.
        let encoded = try JSONEncoder().encode(Self.value(30_000)).count * NavigationPresentation.decodedFactor
        try await Self.waitUntil { window.retainedReadBytes == 80_000 + 4 * encoded }
        _ = window.remembered(read: "synthetic/read-0", as: Value.self)

        // A lower budget drops the unused saved reads first, oldest first, then the least recently used reads.
        window.readCapacity = CachePolicy.Limit(count: 16, bytes: 4 * encoded + 40_000)
        #expect(window.remembered(read: "synthetic/saved-old", as: Data.self) == nil && window.retainedReadBytes == 4 * encoded + 40_000)
        window.readCapacity = CachePolicy.Limit(count: 16, bytes: 2 * encoded)
        #expect(window.rememberedReadCount == 2 && window.retainedReadBytes == 2 * encoded)
        #expect(window.remembered(read: "synthetic/read-0", as: Value.self) != nil && window.remembered(read: "synthetic/read-3", as: Value.self) != nil)
        #expect(window.remembered(read: "synthetic/read-1", as: Value.self) == nil)
        window.readCapacity = CachePolicy.Limit(count: 1, bytes: 2 * encoded)
        #expect(window.rememberedReadCount == 1 && window.remembered(read: "synthetic/read-3", as: Value.self) != nil)

        window.releaseReads()
        #expect(window.rememberedReadCount == 0 && window.retainedReadBytes == 0)
    }

    @MainActor @Test func clearCacheReachesWindowsAndNothingFromBeforeItIsSavedAgain() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let window = NavigationPresentation(), saved = SavedKeys()
        window.persist = { key, data, date, epoch in Task { saved.add(key); await session.saveViewRead(key: key, data: data, readAt: date, epoch: epoch) } }
        window.preload([:], epoch: await session.viewReadEpoch, clearCount: window.clearCount)
        window.remember(Self.value(100), read: "synthetic/kept")
        try await Self.waitUntil { await session.savedViewReads().keys.contains("synthetic/kept") }

        // A load started before Clear Cache and a read remembered just before it neither fill the window nor reach the database.
        let staleClearCount = window.clearCount, staleEpoch = await session.viewReadEpoch
        window.remember(Self.value(100), read: "synthetic/before-clear")
        window.clearReads()
        let epoch = await session.clearCachedReads()
        window.resume(epoch: epoch)
        window.preload(["synthetic/late": (Data(count: 10), Date())], epoch: staleEpoch, clearCount: staleClearCount)
        #expect(window.rememberedReadCount == 0 && window.retainedReadBytes == 0)
        await session.saveViewRead(key: "synthetic/stale", data: Data("{}".utf8), readAt: Date(), epoch: staleEpoch)
        window.remember(Self.value(100), read: "synthetic/after-clear")
        try await Self.waitUntil { await session.savedViewReads().keys.contains("synthetic/after-clear") }
        try await Task.sleep(for: .milliseconds(200))
        #expect(await session.savedViewReads().keys.sorted() == ["synthetic/after-clear"])
        #expect(!saved.keys.contains("synthetic/before-clear"))
    }

    @Test func savedReadsStayWithinTheLimitsDuringALongSessionAndStartupReadsOnlyWhatFits() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let epoch = await session.viewReadEpoch, start = Date(timeIntervalSinceNow: -3_600)
        // An old read and a leftover value without its record from an earlier format are removed by the first cleanup.
        await session.saveViewRead(key: "synthetic/old", data: Data("1".utf8), readAt: Date(timeIntervalSinceNow: -(WorkspaceSession.viewReadAge + 60)), epoch: epoch)
        try await session.insertLegacyViewRead("synthetic/legacy")
        #expect(await session.savedViewReads()["synthetic/old"] == nil)
        #expect(try await session.viewReadKeys().values.contains("synthetic/legacy") == false)

        for index in 0..<(WorkspaceSession.viewReadKeep + 25) {
            await session.saveViewRead(key: "synthetic/read-\(index)", data: Data("\(index)".utf8), readAt: start.addingTimeInterval(Double(index)), epoch: epoch)
        }
        let keys = try await session.viewReadKeys()
        #expect(keys.values.count <= WorkspaceSession.viewReadKeep && keys.values.count == keys.records.count)
        #expect(keys.values.contains("synthetic/read-\(WorkspaceSession.viewReadKeep + 24)") && !keys.values.contains("synthetic/read-0"))

        // Startup takes the newest reads that fit the saved-read budget.
        await session.applyCachePolicy(CachePolicy(level: .custom, customMemoryMB: CachePolicy.memoryRange.lowerBound, customLifetimeMinutes: 1))
        let loaded = await session.savedViewReads(), budget = CachePolicy(level: .custom, customMemoryMB: CachePolicy.memoryRange.lowerBound, customLifetimeMinutes: 1).budget().savedReads
        #expect(loaded.count == min(budget.count, keys.values.count) && loaded["synthetic/read-\(WorkspaceSession.viewReadKeep + 24)"] != nil)
    }

    private final class SavedKeys: @unchecked Sendable {
        private let lock = NSLock(); private var values: [String] = []
        func add(_ key: String) { lock.withLock { values.append(key) } }
        var keys: [String] { lock.withLock { values } }
    }
}

extension WorkspaceSession {
    struct SyntheticCacheCosts { let decoded, release, library, apple, other: Int }
    func cacheCosts() async -> SyntheticCacheCosts {
        let apple = await appleReadCache.retainedBytes
        return SyntheticCacheCosts(decoded: decodedRevisions.cost, release: releaseStatusMemory.cost, library: libraryMetadataCache.cost, apple: apple,
                                   other: archivedRevisions.cost + pricingCaches.retainedBytes)
    }
    /// Fills the session caches with synthetic values through their own insert paths.
    func fillSyntheticCaches(accountId: String, appId: String) async throws {
        libraryMetadataCache.insert(ConnectedApps.Metadata(name: "Synthetic app", count: 1, importedAt: nil), for: "synthetic", cost: 512)
        _ = try await appleReadCache.read("synthetic-read") { Data(count: 64 * 1_024) }
        let value = try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/release-readiness.json")))
        guard case .array(let cases)? = value["cases"], let input = cases.first?["input"] else { throw SyntheticCacheFailure.fixture }
        let plan = try #require(ReleasePlan(.object([("accountId", .string(accountId)), ("appId", .string(appId)),
            ("sourceRevisionId", .string("00000000-0000-4000-8000-000000000002")), ("baseVersionId", .string("synthetic-base")), ("platform", .string("IOS")),
            ("targetVersion", .string("2.0")), ("releaseType", .string("MANUAL")), ("updatedAt", .string("2026-01-01T00:00:00.000Z"))])))
        let scope = try RecoveryGuidance.Scope(accountId: accountId, appId: appId)
        let snapshot = ReleaseReadinessSnapshot(scope: scope, plan: plan, steps: try ReleaseReadiness.steps(input, scope: scope), materialSignature: "synthetic", targetVersionId: "synthetic-version", targetState: nil)
        releaseStatusMemory.insert((snapshot, Date()), for: "synthetic-status", cost: 8_192)
        if decodedRevisions.cost == 0 { _ = try revisions(accountId: accountId, appId: appId) }
    }
    func insertLegacyViewRead(_ key: String) throws {
        let value = JSONText.object([("readAt", .string(ReportTimestamps.isoUtcText(Date()))), ("value", .string(Data("{}".utf8).base64EncodedString()))])
        try storeAccess { store in try store.transaction { _ in [.put(namespace: Self.viewReadsNamespace, key: key, json: value.data)] } }
    }
    func viewReadKeys() throws -> (values: [String], records: [String]) {
        try storeAccess { store in (try store.keys(namespace: Self.viewReadsNamespace), try store.keys(namespace: Self.viewReadMetaNamespace)) }
    }
}
enum SyntheticCacheFailure: Error { case fixture }
