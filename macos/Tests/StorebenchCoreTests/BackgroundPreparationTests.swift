import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct BackgroundPreparationTests {
    init() throws { _ = try TestIsolation.require() }
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let apps: [(accountId: String, appId: String)] = [("synthetic-account", "1001"), ("synthetic-account", "1002"), ("synthetic-account", "1003"), ("synthetic-other", "2001")]
    private func ids(_ ranked: [(accountId: String, appId: String)]) -> [String] { ranked.map(\.appId) }

    @Test func limitsAreValidatedAndStoredWithASchemaVersion() throws {
        #expect(try BackgroundPreparation().appLimit == BackgroundPreparation.standard)
        for limit in BackgroundPreparation.limits { #expect(try BackgroundPreparation(BackgroundPreparation(appLimit: limit).json).appLimit == limit) }
        #expect(throws: BackgroundPreparationFailure.self) { try BackgroundPreparation(appLimit: 2) }
        #expect(throws: BackgroundPreparationFailure.self) { try BackgroundPreparation(JSONText.object([("schemaVersion", .number(2)), ("appLimit", .number(3))])) }
        #expect(throws: BackgroundPreparationFailure.self) { try BackgroundPreparation(JSONText.object([("schemaVersion", .number(1)), ("appLimit", .number(3.5))])) }
    }

    @Test func theOpenAppComesFirstThenTheMostUsed() {
        var usage = AppUsage()
        for _ in 0..<3 { usage = usage.recording(accountId: "synthetic-account", appId: "1003", now: start) }
        usage = usage.recording(accountId: "synthetic-other", appId: "2001", now: start)
        #expect(ids(usage.ranked(apps, current: nil, limit: 2, now: start)) == ["1003", "2001"])
        #expect(ids(usage.ranked(apps, current: ("synthetic-account", "1002"), limit: 2, now: start)) == ["1002", "1003"])
        // With no more connected apps than the limit every app is prepared, unopened ones in their connected order.
        #expect(ids(usage.ranked(apps, current: nil, limit: 20, now: start)) == ["1003", "2001", "1001", "1002"])
        #expect(usage.ranked(apps, current: nil, limit: 0, now: start).isEmpty)
    }

    @Test func olderOpeningsCountForLessAndUnknownAppsAreIgnored() {
        var usage = AppUsage()
        for _ in 0..<4 { usage = usage.recording(accountId: "synthetic-account", appId: "1001", now: start) }
        let later = start.addingTimeInterval(8 * 7 * 86_400)
        usage = usage.recording(accountId: "synthetic-account", appId: "1002", now: later)
        // Four openings eight weeks ago are worth a quarter opening now.
        #expect(ids(usage.ranked(apps, current: nil, limit: 2, now: later)) == ["1002", "1001"])
        usage = usage.recording(accountId: "synthetic-removed", appId: "9999", now: later)
        #expect(!ids(usage.ranked(apps, current: nil, limit: 20, now: later)).contains("9999"))
    }

    @Test func aReleaseMarkDoesNotCountAsAnotherOpening() throws {
        var usage = AppUsage().recording(accountId: "synthetic-account", appId: "1001", now: start)
        usage = usage.recording(accountId: "synthetic-account", appId: "1001", release: true, counts: false, now: start.addingTimeInterval(60))
        let entry = try #require(usage.entries.first)
        #expect(entry.score == 1 && entry.lastOpened == start)
        #expect(usage.preparesRelease(accountId: "synthetic-account", appId: "1001", now: start.addingTimeInterval(86_400)))
        #expect(!usage.preparesRelease(accountId: "synthetic-account", appId: "1001", now: start.addingTimeInterval(31 * 86_400)))
        #expect(!usage.preparesRelease(accountId: "synthetic-account", appId: "1002", now: start))
        #expect(try AppUsage(usage.json) == usage)
    }

    @Test func usageKeepsABoundedNumberOfApps() {
        var usage = AppUsage()
        for index in 0..<(AppUsage.capacity + 10) { usage = usage.recording(accountId: "synthetic-account", appId: String(5000 + index), now: start.addingTimeInterval(Double(index))) }
        #expect(usage.entries.count == AppUsage.capacity)
        #expect(usage.entries.first?.appId == String(5000 + AppUsage.capacity + 9))
    }

    @Test func theChoiceIsSavedInTheEncryptedWorkspace() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        #expect(try await session.backgroundPreparation().appLimit == BackgroundPreparation.standard)
        try await session.setBackgroundPreparation(BackgroundPreparation(appLimit: 10))
        #expect(try await session.backgroundPreparation().appLimit == 10)
        await #expect(throws: AccountFailure.self) { try await session.recordAppOpened(accountId: "synthetic-account", appId: "1001") }
    }

    @MainActor @Test func aNewerSuggestionReplacesOnlyUneditedInputsWithoutAPlan() async throws {
        let date = start
        let old = ReleasePlanInputs(start: .copy, sourceRevisionId: "synthetic-import-1", baseVersionId: "synthetic-version-1", targetVersion: "1.1", date: date)
        let newer = ReleasePlanInputs(start: .reuse, sourceRevisionId: "synthetic-import-2", baseVersionId: "synthetic-version-2", targetVersion: "1.1", date: date)
        let editor = ReleasePlanEditor(accountId: "synthetic-account", appId: "1001", initial: old, read: { nil },
                                       save: { _, _ in throw ReleaseFailure.sourceUnavailable }, remove: { _ in })
        #expect(!editor.suggest(newer))
        await editor.load()
        #expect(editor.suggest(newer) && editor.inputs == newer && editor.baseline == newer && !editor.dirty)
        editor.inputs.targetVersion = "1.2"
        #expect(!editor.suggest(old) && editor.inputs.targetVersion == "1.2" && editor.inputs.sourceRevisionId == "synthetic-import-2")
    }
}
