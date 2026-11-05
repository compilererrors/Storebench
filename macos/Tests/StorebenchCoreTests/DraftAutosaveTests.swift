import Foundation
import Testing
@testable import StorebenchCore

@MainActor private final class DraftDelay {
    var pending: [CheckedContinuation<Void, any Error>] = []
    func wait() async throws {
        try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func advance() { let waiting = pending; pending = []; waiting.forEach { $0.resume() } }
}

@Suite(.serialized) struct DraftAutosaveTests {
    init() throws { _ = try TestIsolation.require() }
    @MainActor func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            if ContinuousClock.now >= deadline { Issue.record("Synthetic autosave did not reach its expected state"); return false }
            await Task.yield()
        }
        return true
    }
    func input(_ signature: String, enabled: Bool = true, dirty: Bool = true, blocked: Bool = false, identity: String = "synthetic-account/1000000001/synthetic-localization") -> DraftAutosave.Input {
        .init(identity: identity, signature: signature, enabled: enabled, dirty: dirty, blocked: blocked)
    }

    @Test func preferencesUseTheWebSchemaAndRefuseCorruptSavedState() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        #expect(try await session.editingPreferences() == EditingPreferences(autosaveDrafts: false))
        try await session.saveEditingPreferences(EditingPreferences(autosaveDrafts: true))
        #expect(try await session.editingPreferences().autosaveDrafts)
        let stored = try #require(try await session.storeAccess { try $0.document(namespace: "editing_preferences", key: "current") })
        #expect(String(data: stored.payload, encoding: .utf8) == #"{"schemaVersion":2,"autosaveDrafts":true,"skippedConfirmations":[]}"#)
        let fixture = try JSONText.parse(Data(contentsOf: try TestIsolation.require().appendingPathComponent("native-fixtures/editing-preferences.json")))
        for item in WorkspaceSession.items(fixture["vectors"]) {
            if item["rejected"] == .bool(true) { #expect(throws: DraftFailure.invalid) { try EditingPreferences(#require(item["input"])) } }
            else { #expect(try EditingPreferences(#require(item["input"])).json.stringify() == item["expected"]?.stringify()) }
        }
        try await session.storeAccess { store in
            try store.transaction { _ in [.put(namespace: "editing_preferences", key: "current", json: Data(#"{"schemaVersion":1,"autosaveDrafts":"true"}"#.utf8))] }
        }
        await #expect(throws: DraftFailure.invalid) { try await session.editingPreferences() }
        await #expect(throws: DraftFailure.invalid) { try await session.saveEditingPreferences(EditingPreferences()) }
        #expect(try await session.storeAccess { try $0.document(namespace: "editing_preferences", key: "current")?.revision } == stored.revision + 1)
    }

    @Test @MainActor func rapidEditsOnlySaveTheLatestScopedSnapshot() async throws {
        let clock = DraftDelay(), controller = DraftAutosave(delay: { try await clock.wait() })
        defer { controller.stop(); clock.advance() }
        var saved: [String] = []
        controller.update(input("first")) { saved.append("first"); return true }
        guard await eventually({ clock.pending.count == 1 }) else { return }
        controller.update(input("second")) { saved.append("second"); return true }
        guard await eventually({ clock.pending.count == 2 }) else { return }
        controller.update(input("third", identity: "synthetic-account/1000000002/other-localization")) { saved.append("third"); return true }
        guard await eventually({ clock.pending.count == 3 }) else { return }
        #expect(saved.isEmpty && controller.phase == .waiting)
        clock.advance()
        guard await eventually({ controller.phase == .idle }) else { return }
        #expect(saved == ["third"])
    }

    @Test @MainActor func unchangedInputsKeepTheirTimerAndUseTheLatestCallback() async throws {
        let clock = DraftDelay(), controller = DraftAutosave(delay: { try await clock.wait() })
        defer { controller.stop(); clock.advance() }
        var saved: [String] = []
        let current = input("unchanged")
        controller.update(current) { saved.append("old callback"); return true }
        guard await eventually({ clock.pending.count == 1 }) else { return }
        controller.update(current) { saved.append("latest callback"); return true }
        #expect(clock.pending.count == 1)
        clock.advance(); guard await eventually({ controller.phase == .idle }) else { return }
        #expect(saved == ["latest callback"])
    }

    @Test @MainActor func disablingBlockingRevertingAndLeavingCancelPendingWrites() async throws {
        let clock = DraftDelay(), controller = DraftAutosave(delay: { try await clock.wait() })
        defer { controller.stop(); clock.advance() }
        var writes = 0
        for stopping in [input("disabled", enabled: false), input("busy", blocked: true), input("clean", dirty: false), input("disabled-parent").blocking(true)] {
            controller.update(input("waiting")) { writes += 1; return true }
            guard await eventually({ !clock.pending.isEmpty }) else { return }
            controller.update(stopping) { writes += 1; return true }
            clock.advance(); await Task.yield()
            #expect(controller.phase == .idle && writes == 0)
        }
        controller.update(input("before-leaving")) { writes += 1; return true }
        guard await eventually({ !clock.pending.isEmpty }) else { return }
        controller.stop(); clock.advance(); await Task.yield()
        #expect(writes == 0 && controller.phase == .idle)
    }

    @Test @MainActor func activeWritesFinishTheirOwnSnapshotAndNewerEditsQueueOnce() async throws {
        let clock = DraftDelay(), completion = DraftDelay(), controller = DraftAutosave(delay: { try await clock.wait() })
        defer { controller.stop(); clock.advance(); completion.advance() }
        var saved: [String] = []
        controller.update(input("original")) {
            saved.append("original-started"); try? await completion.wait(); saved.append("original-finished"); return true
        }
        guard await eventually({ !clock.pending.isEmpty }) else { return }; clock.advance()
        guard await eventually({ controller.phase == .saving && !completion.pending.isEmpty }) else { return }
        controller.update(input("blocked", blocked: true)) { saved.append("blocked"); return true }
        controller.cancelPending()
        #expect(controller.phase == .saving)
        controller.update(input("newer")) { saved.append("newer"); return true }
        completion.advance()
        guard await eventually({ controller.phase == .waiting && !clock.pending.isEmpty }) else { return }
        #expect(saved == ["original-started", "original-finished"])
        clock.advance(); guard await eventually({ controller.phase == .idle }) else { return }
        #expect(saved == ["original-started", "original-finished", "newer"])
    }

    @Test @MainActor func leavingReleasesTheCallbackAndNeverQueuesAfterAnActiveWrite() async throws {
        let clock = DraftDelay(), completion = DraftDelay()
        var controller: DraftAutosave? = DraftAutosave(delay: { try await clock.wait() })
        weak var observed = controller
        var writes = 0
        do {
            let current = try #require(controller)
            current.update(input("original")) { [current] in
                writes += 1; try? await completion.wait(); current.pause(); return true
            }
            guard await eventually({ !clock.pending.isEmpty }) else { return }; clock.advance()
            guard await eventually({ current.phase == .saving && !completion.pending.isEmpty }) else { return }
            current.update(input("waiting-next")) { writes += 1; return true }
            current.stop(); controller = nil; completion.advance()
        }
        guard await eventually({ observed == nil }) else { return }
        #expect(writes == 1 && clock.pending.isEmpty)
    }

    @Test @MainActor func failedSavesAndExplicitComparisonsStayPausedUntilRetry() async throws {
        let clock = DraftDelay(), controller = DraftAutosave(delay: { try await clock.wait() })
        defer { controller.stop(); clock.advance() }
        var writes = 0
        controller.update(input("conflicting")) { writes += 1; return false }
        guard await eventually({ !clock.pending.isEmpty }) else { return }; clock.advance()
        guard await eventually({ controller.phase == .paused }) else { return }
        controller.update(input("edited-again")) { writes += 1; return true }
        await Task.yield(); #expect(clock.pending.isEmpty && writes == 1 && controller.phase == .paused)
        controller.resume(); controller.update(input("retry")) { writes += 1; return true }
        guard await eventually({ !clock.pending.isEmpty }) else { return }; clock.advance()
        guard await eventually({ controller.phase == .idle }) else { return }
        #expect(writes == 2)
        controller.update(input("comparison")) { writes += 1; return true }
        guard await eventually({ !clock.pending.isEmpty }) else { return }
        controller.pause(); clock.advance(); controller.update(input("explicit-new-baseline")) { writes += 1; return true }
        await Task.yield(); #expect(writes == 2 && controller.phase == .paused)
    }

    @Test @MainActor func theDefaultDelayUsesARealShortPauseBeforeAnyWrite() async throws {
        let controller = DraftAutosave(); defer { controller.cancelPending() }
        let started = ContinuousClock.now; var savedAt: ContinuousClock.Instant?
        controller.update(input("default-timer")) { savedAt = .now; return true }
        try await Task.sleep(for: .milliseconds(80)); #expect(savedAt == nil)
        guard await eventually({ savedAt != nil }) else { return }
        #expect(started.duration(to: try #require(savedAt)) >= .milliseconds(1200))
    }

    @Test @MainActor func autosaveUsesTheRealDraftGuardAndPausesOnAnotherEditorsSave() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = "synthetic-account", app = "1000000001", revision = "00000000-0000-4000-8000-000000000002", locale = "version-locale-1"
        let loaded = try await session.textDraft(accountId: account, appId: app, revisionId: revision, localizationId: locale, scope: .version)
        var own = loaded.fields; own["description"] = "Unsaved synthetic text é e\u{301}"
        var other = loaded.fields; other["description"] = "Saved by another synthetic editor"
        let clock = DraftDelay(), controller = DraftAutosave(delay: { try await clock.wait() })
        defer { controller.stop(); clock.advance() }
        var attempts = 0
        controller.update(input(TextDrafts.fingerprint(own))) {
            attempts += 1
            do { _ = try await session.saveTextDraft(accountId: account, appId: app, revisionId: revision, localizationId: locale, scope: .version, fields: own, fingerprint: loaded.fingerprint); return true }
            catch { return false }
        }
        guard await eventually({ !clock.pending.isEmpty }) else { return }
        try await session.saveTextDraft(accountId: account, appId: app, revisionId: revision, localizationId: locale, scope: .version, fields: other, fingerprint: loaded.fingerprint)
        clock.advance(); guard await eventually({ controller.phase == .paused }) else { return }
        #expect(attempts == 1 && own["description"] == "Unsaved synthetic text é e\u{301}")
        #expect(try await session.textDraft(accountId: account, appId: app, revisionId: revision, localizationId: locale, scope: .version).fields["description"] == other["description"])
        let latest = try await session.textDraft(accountId: account, appId: app, revisionId: revision, localizationId: locale, scope: .version)
        controller.resume(); try await session.saveTextDraft(accountId: account, appId: app, revisionId: revision, localizationId: locale, scope: .version, fields: own, fingerprint: latest.fingerprint)
        #expect(try await session.publishHistory(accountId: account, appId: app).isEmpty)
    }

    @Test func mediaAcknowledgementsNeverRefreshToAnotherEditorsLayout() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = "synthetic-account", app = "1000000001", revision = "00000000-0000-4000-8000-000000000002", locale = "version-locale-1"
        let shot = try await session.screenshotSet(accountId: account, appId: app, revisionId: revision, setId: "set-1")
        let confirmed = try await session.saveScreenshotLayout(accountId: account, appId: app, revisionId: revision, setId: "set-1", order: shot.items.map(\.id), hidden: ["shot-1"], expected: shot.signature)
        _ = try await session.saveScreenshotLayout(accountId: account, appId: app, revisionId: revision, setId: "set-1", order: confirmed.items.map(\.id), hidden: [], expected: confirmed.signature)
        #expect(confirmed.hidden == ["shot-1"] && confirmed.signature != shot.signature)
        await #expect(throws: ScreenshotFailure.stale) { try await session.saveScreenshotLayout(accountId: account, appId: app, revisionId: revision, setId: "set-1", order: confirmed.items.map(\.id), hidden: ["shot-1"], expected: confirmed.signature) }
        let movie = try PreviewTests().file(syntheticMovie(), "synthetic-autosave.mp4"); defer { try? FileManager.default.removeItem(at: movie) }
        try await session.addPreview(accountId: account, appId: app, revisionId: revision, localizationId: locale, type: "IPHONE_67", file: movie)
        let preview = try await session.previewSet(accountId: account, appId: app, revisionId: revision, localizationId: locale, type: "IPHONE_67")
        let id = try #require(preview.items.first?.id)
        let acknowledged = try await session.savePreviewLayout(accountId: account, appId: app, revisionId: revision, localizationId: locale, type: "IPHONE_67", order: [id], hidden: [], posterTimes: [id: 7], expected: preview.signature)
        _ = try await session.savePreviewLayout(accountId: account, appId: app, revisionId: revision, localizationId: locale, type: "IPHONE_67", order: [id], hidden: [id], posterTimes: [id: 9], expected: acknowledged.signature)
        #expect(acknowledged.posterTimes[id] == 7 && acknowledged.hidden.isEmpty)
        await #expect(throws: PreviewFailure.stale) { try await session.savePreviewLayout(accountId: account, appId: app, revisionId: revision, localizationId: locale, type: "IPHONE_67", order: [id], hidden: [], posterTimes: [id: 7], expected: acknowledged.signature) }
    }

    @Test func explicitMediaComparisonPreservesEditsAndUsesTheReviewedCatalog() {
        let own = MediaDraftInputs(order: ["b", "a", "removed"], hidden: ["a"], posterTimes: ["a": 8, "b": 9, "removed": 7])
        let latest = MediaDraftInputs(order: ["a", "b", "added"], hidden: ["b", "added"], posterTimes: ["a": 4, "b": 5, "added": 6])
        let kept = own.keepingEdits(on: latest)
        #expect(kept.order == ["b", "a", "added"] && kept.hidden == ["a", "added"] && kept.posterTimes == ["a": 8, "b": 9, "added": 6])
        #expect(own.order == ["b", "a", "removed"] && latest.posterTimes["a"] == 4)
    }
}
