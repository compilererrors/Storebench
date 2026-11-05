import Foundation
import Testing
@testable import StorebenchCore

@Suite struct SyncDateCacheTests {
    init() throws { _ = try TestIsolation.require() }
    @Test func projectionReusesValidDatesWithoutChangingLegacyComparisonRules() {
        var reads: [String: Int] = [:]
        var cache = SyncDateCache { text in reads[text, default: 0] += 1; return AppSync.date(text) }
        let values = ["2026-02-03T12:34:56.000Z", "2026-02-03T14:34:56+02:00", "2026-02-04", "Tue, 03 Feb 2026 12:34:56 GMT", "invalid"]
        for _ in 0..<3 { for value in values {
            #expect(cache.date(value) == AppSync.date(value))
            for baseline in values { #expect(cache.newer(value, than: baseline) == AppSync.newer(value, than: baseline)) }
        } }
        for value in values where AppSync.date(value) != nil { #expect(reads[value] == 1) }
        #expect((reads["invalid"] ?? 0) > 1)
    }
}
