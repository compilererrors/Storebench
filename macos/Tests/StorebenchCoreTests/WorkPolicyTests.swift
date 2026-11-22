import Foundation
import Testing
@testable import StorebenchCore

@Suite struct WorkPolicyTests {
    init() throws { _ = try TestIsolation.require() }

    @Test func automaticLowersActivityInLowPowerModeAndOnAWarmMac() {
        let automatic = WorkPolicy()
        #expect(automatic.resolved(.init()) == .full)
        #expect(automatic.resolved(.init(thermal: .fair)) == .balanced)
        #expect(automatic.resolved(.init(thermal: .serious)) == .light && automatic.resolved(.init(thermal: .critical)) == .light)
        #expect(automatic.resolved(.init(lowPower: true)) == .light)
        // A chosen level does not follow the Mac.
        #expect(WorkPolicy(level: .full).resolved(.init(lowPower: true, thermal: .critical)) == .full)
        #expect(WorkPolicy(level: .light).resolved(.init()) == .light)
    }

    @Test func eachLowerLevelSendsFewerRequestsAndReadsAheadLess() {
        let full = WorkPolicy(level: .full).plan(), balanced = WorkPolicy(level: .balanced).plan(), light = WorkPolicy(level: .light).plan()
        #expect(full == .full && full.requests == AppleReadAdmission.Limits() && full.preparedApps == nil && full.readsWhileInactive && full.animations)
        #expect(full.requests.active > balanced.requests.active && balanced.requests.active > light.requests.active)
        #expect(full.requests.backgroundActive > balanced.requests.backgroundActive && balanced.requests.backgroundActive > light.requests.backgroundActive)
        #expect(full.backgroundIntervalFactor < balanced.backgroundIntervalFactor && balanced.backgroundIntervalFactor < light.backgroundIntervalFactor)
        for plan in [full, balanced, light] {
            // A slot always stays free for what the open screen asks for.
            #expect(plan.requests.active > plan.requests.nextActive && plan.requests.nextActive >= plan.requests.backgroundActive && plan.requests.backgroundActive >= 1)
        }
        #expect(!balanced.readsWhileInactive && balanced.preparedApps == 3 && balanced.preparesOnSchedule && balanced.animations)
        #expect(!light.readsWhileInactive && light.preparedApps == 1 && !light.preparesOnSchedule && !light.animations)
    }

    @Test func theChoiceIsStoredAndAnUnknownStoredLevelFallsBackToAutomatic() throws {
        let policy = WorkPolicy(level: .light)
        #expect(try JSONDecoder().decode(WorkPolicy.self, from: JSONEncoder().encode(policy)) == policy)
        #expect(try JSONDecoder().decode(WorkPolicy.self, from: Data(#"{"level":"synthetic"}"#.utf8)).level == .automatic)
    }

    @Test func aLowerRequestLimitAppliesToAQueueAlreadyInUse() async throws {
        let queue = AppleReadAdmission()
        var limits = AppleReadAdmission.Limits(); limits.active = 1; limits.nextActive = 0; limits.backgroundActive = 0
        await queue.configure(limits)
        // A read behind the open screen has no slot under these limits and waits; a visible read still runs.
        let waiting = Task { try await queue.run(.background) { 1 } }
        for _ in 0..<10_000 where await queue.snapshot.waiting[.background] != 1 { await Task.yield() }
        #expect(await queue.snapshot.waiting[.background] == 1)
        #expect(try await queue.run(.visible) { 2 } == 2)
        #expect(await queue.snapshot.waiting[.background] == 1)
        await queue.configure(AppleReadAdmission.Limits())
        #expect(try await waiting.value == 1)
    }
}
