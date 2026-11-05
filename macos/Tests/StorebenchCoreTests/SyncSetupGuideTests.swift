import Foundation
import Testing
@testable import StorebenchCore

struct SyncSetupGuideTests {
    init() throws { _ = try TestIsolation.require() }

    private func item(_ key: String, _ state: SyncItem.State, code: String? = nil) -> SyncItem {
        SyncItem(key: key, state: state, detail: "Synthetic detail", checkedAt: "2026-10-19T08:00:00.000Z", code: code)
    }

    @Test func beforeAnyCheckTheGuideStartsWithTheSetupCheck() throws {
        let steps = try #require(SyncSetupGuide.steps(nil))
        #expect(steps.map(\.id) == ["check", "reports", "analytics", "fiscal", "sync"])
        #expect(steps.first?.state == .todo && steps.dropFirst().allSatisfy { $0.state == .unknown })
        #expect(try #require(SyncSetupGuide.steps(AppSync.pending())).first?.id == "check")
    }

    @Test func missingSetupNamesWhatToDoAndWhereToDoIt() throws {
        let steps = try #require(SyncSetupGuide.steps([
            item("sales", .attention, code: "SB-SYNC-CONNECTION"), item("finance", .attention, code: "SB-SYNC-FISCAL-PERIOD"),
            item("downloads", .ready), item("engagement", .waiting),
        ]))
        let state = Dictionary(uniqueKeysWithValues: steps.map { ($0.id, $0.state) })
        #expect(state == ["reports": .todo, "analytics": .done, "fiscal": .todo, "sync": .todo])
        #expect(steps.first { $0.id == "reports" }?.source == "sales" && steps.first { $0.id == "fiscal" }?.source == "finance")
        let analytics = try #require(SyncSetupGuide.steps([item("downloads", .attention, code: "SB-ANALYTICS-SETUP"), item("sales", .synced)]))
        #expect(analytics.first { $0.id == "analytics" }?.state == .todo && analytics.first { $0.id == "sync" }?.state == .done)
    }

    @Test func aCompleteSetupHidesTheGuide() {
        #expect(SyncSetupGuide.steps([item("sales", .synced), item("downloads", .synced), item("engagement", .partial), item("finance", .ready)]) == nil)
        #expect(SyncSetupGuide.steps([item("sales", .attention, code: "SB-REPORT-SERVICE")]) == nil)
    }
}
