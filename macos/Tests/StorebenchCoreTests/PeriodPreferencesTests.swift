import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct PeriodPreferencesTests {
    init() throws { _ = try TestIsolation.require() }
    func fixtures() throws -> JSONText { try JSONText.parse(Data(contentsOf: try TestIsolation.require().appendingPathComponent("native-fixtures/period-preferences.json"))) }
    func key(_ value: JSONText) throws -> PeriodKey {
        let name = try #require(value["key"]?.text)
        return try #require(PeriodKey(rawValue: name))
    }

    @Test func normalizationAndAllNineInitialChoicesMatchTheWeb() throws {
        let fixture = try fixtures()
        for item in WorkspaceSession.items(fixture["preferences"]) {
            let input = try #require(item["input"])
            if item["rejected"] == .bool(true) { #expect(throws: PeriodFailure.invalid) { try PeriodPreferences(input) } }
            else { #expect(try PeriodPreferences(input).json == item["expected"]) }
        }
        for item in WorkspaceSession.items(fixture["values"]) {
            let key = try key(item), input = try #require(item["input"])
            if item["rejected"] == .bool(true) { #expect(throws: PeriodFailure.invalid) { try PeriodValue(key: key, value: input) } }
            else { #expect(try PeriodValue(key: key, value: input).json == item["expected"]) }
        }
        for item in WorkspaceSession.items(fixture["initialValues"]) {
            let preferences = try PeriodPreferences(#require(item["preferences"]))
            #expect(preferences.value(try key(item)).json == item["value"])
            #expect(JSONText.number(Double(preferences.syncReach)) == item["syncReach"])
        }
        #expect(PeriodKey.allCases.count == 9)
        #expect(try PeriodPreferences().days(.financePeriods) == 1)
        #expect(try PeriodPreferences().days(.noSalesDays) == 30)
    }

    @Test func gregorianUTCDateBoundariesAndRelativeRangesMatchTheWeb() throws {
        let fixture = try fixtures()
        for item in WorkspaceSession.items(fixture["ranges"]) {
            if item["rejected"] == .bool(true) { #expect(throws: PeriodFailure.invalid) { try PeriodRangeChoice(#require(item["input"])) } }
            else { #expect(try PeriodRangeChoice(#require(item["input"])).json == item["expected"]) }
        }
        for item in WorkspaceSession.items(fixture["resolved"]) {
            let choice = try PeriodRangeChoice(#require(item["input"])), latest = try #require(item["latest"]?.text)
            if item["rejected"] == .bool(true) { #expect(throws: PeriodFailure.invalid) { try choice.resolve(latest: latest) } }
            else {
                let actual = try choice.resolve(latest: latest)?.json ?? .null
                #expect(actual == item["expected"], "Synthetic \(choice.json.stringify()) ending \(latest)")
            }
        }
        for item in WorkspaceSession.items(fixture["choices"]) {
            let input = try #require(item["input"])
            let range = input == .null ? nil : try PeriodDateRange(from: #require(input["from"]?.text), to: #require(input["to"]?.text))
            #expect(PeriodRangeChoice.choice(range, latest: try #require(item["latest"]?.text)).json == item["expected"])
        }
        for item in WorkspaceSession.items(fixture["dateNumbers"]) {
            let date = try #require(item["date"]?.text), number = try #require(PeriodDates.number(date))
            #expect(JSONText.number(Double(number)) == item["number"])
            #expect(PeriodDates.text(number) == date)
            #expect(PeriodDates.text(try #require(PeriodDates.date(date))) == date)
        }
        #expect(PeriodDates.text(Date(timeIntervalSince1970: -0.1)) == "1969-12-31")
        #expect(PeriodDates.number("２０２６-01-01") == nil && PeriodDates.number("2026-01-01\n") == nil)
    }

    @Test func storedUpdatesPreserveOtherViewsAndSyncDefaults() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        #expect(try await session.periodPreferences() == PeriodPreferences())
        for item in WorkspaceSession.items(try fixtures()["operations"]) {
            let input = try #require(item["input"])
            switch item["action"]?.text {
            case "remember": try await session.rememberPeriod(try key(input), value: PeriodValue(key: key(input), value: #require(input["value"])))
            case "sync": try await session.setSyncDays(PeriodValue.days(input["days"], maximum: 365))
            case "forget": try await session.forgetPeriods()
            case "defaults":
                try await session.savePeriodDefaults(remember: input["remember"] == .bool(true), compareDays: PeriodValue.days(input["compareDays"], maximum: 365), downloadDays: PeriodValue.days(input["downloadDays"], maximum: 365), range: PeriodRangeChoice(#require(input["range"])), syncDays: input["syncDays"].map { try PeriodValue.days($0, maximum: 365) })
            default: Issue.record("Unknown synthetic period operation")
            }
            #expect(try await session.periodPreferences().json == item["expected"])
            let saved = try #require(try await session.storeAccess { try $0.document(namespace: "period_preferences", key: "current") })
            #expect(try JSONText.parse(saved.payload) == item["expected"])
        }
    }

    @Test func concurrentSessionsKeepEveryIndependentChoiceUnderThePermanentMutex() async throws {
        let (first, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let second = try WorkspaceSession(workspace: Workspace(root: root), vault: await first.vault)
        try await first.setSyncDays(30)
        let mutex = root.appendingPathComponent("state-v2/period_preferences.mutex")
        let inode = try #require(FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, key) in PeriodKey.allCases.enumerated() {
                let session = index % 2 == 0 ? first : second
                group.addTask { for _ in 0..<3 { try await session.rememberPeriod(key, value: key.isRange ? .range(.latest(14)) : .days(key == .financePeriods ? 3 : 14)) } }
            }
            group.addTask { try await second.savePeriodDefaults(remember: true, compareDays: 28, downloadDays: 60, range: .latest(90)) }
            group.addTask { try await first.setSyncDays(90) }
            try await group.waitForAll()
        }
        let final = try await first.periodPreferences()
        #expect(final.compareDays == 28 && final.downloadDays == 60 && final.syncDays == 90 && final.defaultRange == .latest(90))
        #expect(final.rememberedCount == 9)
        for key in PeriodKey.allCases { #expect(final.value(key) == (key.isRange ? .range(.latest(14)) : .days(key == .financePeriods ? 3 : 14))) }
        #expect(try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber == inode)
        #expect(try Data(contentsOf: mutex).isEmpty)
    }

    @Test func corruptStateCannotSilentlyBecomeDefaultsOrBeOverwritten() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let corrupt = [#"{"schemaVersion":1,"remember":true,"defaults":{"compareDays":7,"downloadDays":7,"range":{"kind":"all"},"syncDays":1e100},"remembered":{}}"#,
                       #"{"schemaVersion":1,"remember":true,"defaults":{"compareDays":7,"downloadDays":7,"range":{"kind":"all"}},"remembered":[]}"#]
        for raw in corrupt {
            try await session.storeAccess { store in try store.transaction { _ in [.put(namespace: "period_preferences", key: "current", json: Data(raw.utf8))] } }
            let before = try await session.storeAccess { try $0.document(namespace: "period_preferences", key: "current")?.revision }
            await #expect(throws: PeriodFailure.invalid) { try await session.periodPreferences() }
            await #expect(throws: PeriodFailure.invalid) { try await session.syncDays() }
            await #expect(throws: PeriodFailure.invalid) { try await session.setSyncDays(30) }
            await #expect(throws: PeriodFailure.invalid) { try await session.rememberPeriod(.salesDownload, value: .days(7)) }
            await #expect(throws: PeriodFailure.invalid) { try await session.forgetPeriods() }
            await #expect(throws: PeriodFailure.invalid) { try await session.savePeriodDefaults(remember: true, compareDays: 7, downloadDays: 7, range: .all) }
            await #expect(throws: PeriodFailure.invalid) { try await session.salesSyncDays(accountId: "synthetic-account", appId: "1000000001") }
            await #expect(throws: PeriodFailure.invalid) { try await session.analyticsSyncDays(accountId: "synthetic-account", appId: "1000000001", kind: "downloads") }
            await #expect(throws: PeriodFailure.invalid) { try await session.financialSyncPeriods() }
            #expect(try await session.storeAccess { try $0.document(namespace: "period_preferences", key: "current")?.revision } == before)
        }
    }

    @Test func invalidSelectionsNeverWriteAndDisablingRememberForgetsEarlierChoices() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        for (key, value) in [(PeriodKey.financePeriods, PeriodValue.days(25)), (.salesDownload, .days(0)), (.salesRange, .days(7)), (.analyticsRange, .range(.latest(366)))] {
            await #expect(throws: PeriodFailure.invalid) { try await session.rememberPeriod(key, value: value) }
        }
        #expect(try await session.storeAccess { try $0.document(namespace: "period_preferences", key: "current") } == nil)
        try await session.rememberPeriod(.salesDownload, value: .days(30))
        try await session.setSyncDays(90)
        try await session.savePeriodDefaults(remember: false, compareDays: 14, downloadDays: 7, range: .latest(30))
        try await session.rememberPeriod(.salesDownload, value: .days(60))
        let saved = try await session.periodPreferences()
        #expect(!saved.remember && saved.rememberedCount == 0 && saved.syncDays == 90 && saved.value(.salesDownload) == .days(7))
    }

    @MainActor func waitUntil(_ check: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(try await check()) {
            guard ContinuousClock.now < deadline else { Issue.record("Synthetic period choice did not finish"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    @Test @MainActor func viewChoicesDebounceIndependentlyAndLatestRangesFollowNewData() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let view = PeriodSelection(); await view.load(session)
        view.choose(.salesDownload, .days(14), session: session)
        view.choose(.salesDownload, .days(28), session: session)
        view.choose(.financePeriods, .days(3), session: session)
        view.choose(.salesRange, .range(.latest(7)), session: session)
        view.choose(.salesDownload, .days(0), session: session)
        #expect(view.days(.salesDownload) == 28 && view.days(.financePeriods) == 3)
        try await Task.sleep(for: .milliseconds(80))
        #expect(try await session.periodPreferences().rememberedCount == 0)
        try await waitUntil { try await session.periodPreferences().rememberedCount == 3 }
        let next = PeriodSelection(); await next.load(session)
        #expect(next.days(.salesDownload) == 28 && next.days(.financePeriods) == 3)
        #expect(try next.range(.salesRange).resolve(latest: "2026-02-01")?.from == "2026-01-26")
        #expect(try next.range(.salesRange).resolve(latest: "2026-02-03")?.from == "2026-01-28")
        let custom = try PeriodDateRange(from: "2026-01-01", to: "2026-01-07")
        #expect(try PeriodRangeChoice.custom(custom).resolve(latest: "2026-02-03") == custom)
        try await session.savePeriodDefaults(remember: false, compareDays: 7, downloadDays: 7, range: .all)
        next.choose(.salesDownload, .days(90), session: session)
        try await Task.sleep(for: .milliseconds(450))
        #expect(try await session.periodPreferences().rememberedCount == 0)
        #expect(next.days(.salesDownload) == 90)
    }

    @Test func rangeFilteringIncludesWholePeriodsWithoutInventingMissingDays() throws {
        let range = try #require(try PeriodRangeChoice.latest(7).resolve(latest: "2026-02-01"))
        #expect(range.contains("2026-01-26") && range.contains("2026-02-01"))
        #expect(!range.contains("2026-01-25") && !range.contains("2026-02-02"))
        #expect(range.contains("2026-01-26", end: "2026-02-01"))
        #expect(!range.contains("2026-01-25", end: "2026-01-26"))
        #expect(!range.contains("2026-02-01", end: "2026-02-02"))
        #expect(try PeriodRangeChoice.latest(7).resolve(latest: "") == nil)
    }

    @Test @MainActor func appAndViewChoicesSurviveReopeningWithoutCrossingScopes() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try PeriodScope(accountId: "synthetic-account", appId: "1000000001")
        let second = try PeriodScope(accountId: "synthetic-account", appId: "1000000002")
        let otherAccount = try PeriodScope(accountId: "synthetic-other", appId: "1000000001")
        try await session.rememberPeriod(.salesRange, value: .range(.latest(180)))
        let view = PeriodSelection(); await view.load(session, scope: first)
        #expect(view.range(.salesRange) == .all)
        view.choose(.salesRange, .range(.latest(30)), session: session)
        await view.load(session, scope: second)
        #expect(view.range(.salesRange) == .all)
        view.choose(.salesRange, .range(.latest(90)), session: session)
        view.choose(.analyticsRange, .range(.latest(7)), session: session)
        try await waitUntil { try await session.periodPreferences().rememberedCount == 4 }
        let persisted = try await session.periodPreferences()
        let restored = try PeriodPreferences(JSONText.parse(persisted.json.data))
        #expect(restored.value(.salesRange, scope: first) == .range(.latest(30)))
        #expect(restored.value(.salesRange, scope: second) == .range(.latest(90)))
        #expect(restored.value(.analyticsRange, scope: second) == .range(.latest(7)))
        #expect(restored.value(.analyticsRange, scope: first) == .range(.all))
        #expect(restored.value(.salesRange, scope: otherAccount) == .range(.all))
        let reopened = PeriodSelection(); await reopened.load(session, scope: first)
        #expect(reopened.range(.salesRange) == .latest(30))
        try await session.forgetPeriods()
        #expect(try await session.periodPreferences().rememberedCount == 0)
        #expect(try await session.periodPreferences().value(.salesRange, scope: first) == .range(.all))
    }

    @Test func scopedChoicesAreBoundedValidatedAndDisabledTogether() throws {
        var saved = PeriodPreferences()
        for number in 1...140 {
            saved = try saved.remembering(.salesRange, value: .range(.latest(30)), scope: PeriodScope(accountId: "synthetic-account", appId: String(number)))
        }
        #expect(saved.rememberedCount == 128)
        #expect(saved.value(.salesRange, scope: try PeriodScope(accountId: "synthetic-account", appId: "1")) == .range(.all))
        #expect(saved.value(.salesRange, scope: try PeriodScope(accountId: "synthetic-account", appId: "140")) == .range(.latest(30)))
        let disabled = try saved.changingDefaults(remember: false, compareDays: 7, downloadDays: 7, range: .all)
        #expect(disabled.rememberedCount == 0)
        #expect(throws: PeriodFailure.invalid) { try PeriodScope(accountId: "../invalid", appId: "1") }
        #expect(throws: PeriodFailure.invalid) { try PeriodPreferences(saved.json.setting("scoped", .object([]))) }
    }
}
