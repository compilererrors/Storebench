import Foundation
import Testing
@testable import StorebenchCore

@Suite struct CachePolicyTests {
    init() throws { _ = try TestIsolation.require() }
    private static let gigabyte: UInt64 = 1_073_741_824

    @Test func automaticKeepsMoreAndLongerOnMacsWithMoreMemory() {
        let automatic = CachePolicy()
        #expect(automatic.resolved(physicalMemory: 8 * Self.gigabyte) == .balanced)
        #expect(automatic.resolved(physicalMemory: 16 * Self.gigabyte) == .responsive)
        #expect(automatic.resolved(physicalMemory: 36 * Self.gigabyte) == .performance)
        #expect(automatic.resolved(physicalMemory: 128 * Self.gigabyte) == .maximum)
        let small = automatic.budget(physicalMemory: 8 * Self.gigabyte), large = automatic.budget(physicalMemory: 128 * Self.gigabyte)
        #expect(small.appleReads.bytes < large.appleReads.bytes && small.appleReadLifetime < large.appleReadLifetime)
        #expect(small.windowReads.count < large.windowReads.count && small.windowReads.bytes < large.windowReads.bytes && small.decodedRevisions.count < large.decodedRevisions.count)
    }

    @Test func customValuesAreClampedAndUnknownStoredValuesFallBack() throws {
        let policy = CachePolicy(level: .custom, customMemoryMB: 1, customLifetimeMinutes: 999)
        #expect(policy.memoryMB() == CachePolicy.memoryRange.lowerBound && policy.lifetimeMinutes() == CachePolicy.lifetimeRange.upperBound)
        #expect(try JSONDecoder().decode(CachePolicy.self, from: JSONEncoder().encode(policy)) == policy)
        let unknown = try JSONDecoder().decode(CachePolicy.self, from: Data(#"{"level":"synthetic","customMemoryMB":100000}"#.utf8))
        #expect(unknown.level == .automatic && unknown.customMemoryMB == CachePolicy.memoryRange.upperBound)
    }

    @Test func aSmallerBudgetEvictsTheLeastRecentlyUsedEntriesAtOnce() {
        var cache = BoundedMemoryCache<String, Int>(capacity: 4, byteLimit: 400)
        for index in 0..<4 { cache.insert(index, for: "synthetic-\(index)", cost: 100) }
        _ = cache.value(for: "synthetic-0")
        cache.resize(CachePolicy.Limit(count: 4, bytes: 200))
        #expect(cache.count == 2 && cache.cost == 200)
        #expect(cache.value(for: "synthetic-0") == 0 && cache.value(for: "synthetic-3") == 3 && cache.value(for: "synthetic-1") == nil)
        cache.resize(CachePolicy.Limit(count: 1, bytes: 200))
        #expect(cache.count == 1 && cache.value(for: "synthetic-3") == 3)
    }

    @Test func aShorterLifetimeAppliesToResponsesAlreadyKept() async throws {
        let cache = AppStoreReadCache(lifetime: .seconds(3_600))
        let calls = Calls()
        _ = try await cache.read("synthetic") { await calls.next() }
        _ = try await cache.read("synthetic") { await calls.next() }
        let kept = await cache.retainedBytes
        #expect(await calls.count == 1 && kept > 0)
        await cache.configure(limit: CachePolicy.Limit(count: 8, bytes: 1_024), lifetime: .zero)
        let cleared = await cache.retainedBytes
        #expect(cleared == 0)
        _ = try await cache.read("synthetic") { await calls.next() }
        #expect(await calls.count == 2)
    }

    @Test func memoryPressureAndClearingFreeTheSessionCaches() async throws {
        let f = try await AccountLifecycleTests().fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        await f.session.applyCachePolicy(CachePolicy(level: .conservative))
        #expect(await f.session.appleReadLifetime == .seconds(60))
        await f.session.clearCachedReads()
        #expect(await f.session.cachedMemoryBytes() == 0)
    }

    private actor Calls {
        private(set) var count = 0
        func next() -> Data { count += 1; return Data("synthetic response \(count)".utf8) }
    }
}
