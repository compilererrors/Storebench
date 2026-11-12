import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct QuickReleaseTests {
    init() throws { _ = try TestIsolation.require() }
    let accountId = "synthetic-account", appId = "1000000001", revisionId = "00000000-0000-4000-8000-000000000002"
    private func step(_ id: String, _ state: ReleaseReadiness.State, fields: [String] = []) -> ReleaseReadiness.Step {
        var step = ReleaseReadiness.Step(id: id, label: id, detail: "Synthetic detail", href: "/synthetic", action: "Open \(id)", state: state, territories: nil, guideHref: nil)
        step.issues = fields.map { .init(field: $0, message: "Synthetic \($0) is missing.", section: "missing") }
        return step
    }
    private func plan(_ target: String = "1.1") throws -> ReleasePlan {
        try #require(ReleasePlan(.object([("accountId", .string(accountId)), ("appId", .string(appId)), ("sourceRevisionId", .string(revisionId)), ("baseVersionId", .string("version-1")),
                                          ("platform", .string("IOS")), ("targetVersion", .string(target)), ("updatedAt", .string("2026-01-01T00:00:00.000Z")), ("releaseType", .string("MANUAL"))])))
    }
    private func field(_ editor: LanguageEditorState, _ key: String) throws -> LanguageEditorState.Field { try #require(editor.fields.first { $0.key == key }) }

    @Test func blockersLeaveOutWhatThePageDoesItselfAndKeepReleaseOrder() {
        let steps = [step("version", .blocked), step("apple-text:en-US", .blocked), step("apple-info:en-US", .blocked), step("copyright", .blocked),
                     step("local:en-US", .blocked, fields: ["whatsNew", "keywords"]), step("local:sv", .blocked, fields: ["whatsNew", "supportUrl"]), step("media:en-US", .blocked),
                     step("build", .blocked), step("export-compliance", .blocked), step("review-info", .unknown), step("age-rating", .blocked), step("submission", .blocked), step("territories", .ready)]
        let blockers = QuickRelease.blockers(steps)
        #expect(blockers.map(\.id) == ["copyright", "local:en-US", "local:sv", "media:en-US", "age-rating"])
        // A language whose every problem is one of the page's fields is fixed at that field; any other field opens Release.
        #expect(QuickRelease.fixedHere(blockers[1]) && !QuickRelease.fixedHere(blockers[2]) && !QuickRelease.fixedHere(blockers[0]))
        #expect(QuickRelease.fieldIssues(blockers[2]).map(\.field) == ["whatsNew"] && QuickRelease.fieldIssues(blockers[3]).isEmpty)
        #expect(QuickRelease.fields == ["description", "subtitle", "keywords", "whatsNew"])
    }

    @Test func textRequestNamesThePlannedVersionAndOnlyItsQuickStage() throws {
        let request = QuickRelease.textRequest(accountId: accountId, appId: appId, plan: try plan())
        #expect(request.scope == .metadata && request.targetMode == "release-plan" && request.revisionId == revisionId && request.versionId == "version-1" && request.mediaStage == PublishRequest.quickStage)
        #expect(try request.validated() == request && PublishRequest(request.json) == request)
        // The stage belongs to the planned version: an imported Apple version or another scope cannot use it.
        var apple = request; apple.targetMode = "apple-version"
        #expect(throws: PublishFailure.self) { try apple.validated() }
        var other = PublishRequest(accountId: accountId, appId: appId, scope: .submit, versionId: "version-1"); other.mediaStage = PublishRequest.quickStage
        #expect(throws: PublishFailure.self) { try other.validated() }
    }

    @Test func stageFollowsAppleVersionState() throws {
        let scope = try RecoveryGuidance.Scope(accountId: accountId, appId: appId), saved = try plan()
        func snapshot(_ version: String?, _ state: String?) -> ReleaseReadinessSnapshot {
            .init(scope: scope, plan: saved, steps: [], materialSignature: "synthetic", targetVersionId: version, targetState: state)
        }
        #expect(QuickRelease.stage(snapshot(nil, nil)) == .create)
        #expect(QuickRelease.stage(snapshot("version-1", "PREPARE_FOR_SUBMISSION")) == .prepare)
        #expect(QuickRelease.stage(snapshot("version-1", "DEVELOPER_REJECTED")) == .prepare)
        #expect(QuickRelease.stage(snapshot("version-1", "WAITING_FOR_REVIEW")) == .submitted("WAITING_FOR_REVIEW"))
    }

    @Test func fourStepsKeepEveryReleaseDestinationInsideTheQuickFlow() {
        #expect(QuickRelease.stepIDs == ["version", "text", "build", "submit"])
        for id in ["plan", "version", "send", "create"] { #expect(QuickRelease.step(for: id) == "version") }
        for id in ["listing", "local:sv", "apple-text:en-US", "apple-info:sv"] { #expect(QuickRelease.step(for: id) == "text") }
        #expect(QuickRelease.step(for: "export-compliance") == "build")
        #expect(QuickRelease.step(for: "privacy") == "submit")
        #expect(QuickRelease.textNeedsAction(step("local:sv", .blocked, fields: ["whatsNew"])))
        #expect(!QuickRelease.textNeedsAction(step("local:sv", .blocked, fields: ["screenshots"])))
        #expect(QuickRelease.textNeedsAction(step("apple-text:sv", .unknown)))
        #expect(!QuickRelease.textNeedsAction(step("apple-text:sv", .ready)))
    }

    @Test func optionalTextChangesUseATextOnlyReviewAndRetainTheSamePlan() throws {
        let request = QuickRelease.textRequest(accountId: accountId, appId: appId, plan: try plan(), includingOtherText: true)
        #expect(request.mediaStage == PublishRequest.textStage && request.targetMode == "release-plan")
        #expect(try request.validated() == request && request.versionId == "version-1" && request.revisionId == revisionId)
    }

    private func progressSnapshot(_ plan: ReleasePlan, notesMissing: Bool = true, buildMissing: Bool = true, target: String? = "version-2", state: String = "PREPARE_FOR_SUBMISSION") throws -> ReleaseReadinessSnapshot {
        var local = step("local:sv", notesMissing ? .blocked : .review, fields: notesMissing ? ["whatsNew"] : [])
        local.issues = notesMissing ? [.init(field: "whatsNew", message: "Synthetic release notes are required.", section: "text")] : []
        var remote = step("apple-text:sv", notesMissing ? .blocked : .ready, fields: notesMissing ? ["whatsNew"] : [])
        if notesMissing { remote.issues = local.issues }
        let checks = [step("plan", .ready), step("version", target == nil ? .blocked : .ready), local, remote, step("apple-info:sv", .ready),
            step("build", buildMissing ? .blocked : .ready), step("export-compliance", buildMissing ? .unknown : .ready),
            step("copyright", .ready), step("review-info", .ready), step("app-configuration", .review), step("age-rating", .review),
            step("accessibility", .review), step("privacy", .ready), step("tax", .ready), step("territories", .ready), step("media:sv", .review)]
        return .init(scope: try .init(accountId: plan.accountId, appId: plan.appId), plan: plan, steps: checks, materialSignature: "synthetic-progress",
                     targetVersionId: target, targetState: state, parts: .all)
    }

    @Test func aPreparedUpdateNamesMissingNotesAndBuildWithoutMarkingCopiedSettingsMissing() throws {
        let plan = try plan(), snapshot = try progressSnapshot(plan)
        let phases = QuickRelease.progress(plan: plan, snapshot: snapshot)
        #expect(phases.map(\.check.status) == [.ready, .missing, .missing, .review])
        #expect(QuickRelease.initialStep(phases) == "text")
        let copied = snapshot.steps.filter { !QuickRelease.handledHere($0.id) }
        #expect(QuickRelease.check(copied, excluding: ["whatsNew"]).status == .ready)
    }

    @Test func unsavedNotesPendingSyncAndApprovalAreYellowButInvalidRequiredNotesAreRed() throws {
        let plan = try plan(), snapshot = try progressSnapshot(plan)
        let editing = QuickRelease.progress(plan: plan, snapshot: snapshot, notes: ["sv": "Synthetic release notes"], notesEdited: true)
        #expect(editing[1].check.status == .review && editing[1].check.label == "Save Draft")
        let empty = QuickRelease.progress(plan: plan, snapshot: snapshot, notes: ["sv": "  "], notesEdited: true)
        #expect(empty[1].check.status == .missing)
        let long = QuickRelease.progress(plan: plan, snapshot: snapshot, notes: ["sv": String(repeating: "x", count: 4001)], notesEdited: true)
        #expect(long[1].check.status == .missing)
        let controls = QuickRelease.progress(plan: plan, snapshot: snapshot, notes: ["sv": "Synthetic\u{7}notes"], notesEdited: true)
        #expect(controls[1].check.status == .missing)
        let ready = QuickRelease.progress(plan: plan, snapshot: try progressSnapshot(plan, notesMissing: false, buildMissing: false))
        #expect(ready.map(\.check.status) == [.ready, .ready, .ready, .review] && ready[3].check.label == "Ready for Review")
        #expect(QuickRelease.check([step("apple-text:sv", .blocked)]).status == .review)
        #expect(QuickRelease.check([step("copyright", .blocked)]).status == .missing)
        #expect(QuickRelease.check([step("export-compliance", .waiting)]).status == .review)
        #expect(QuickRelease.check([step("privacy", .unknown)]).status == .review)
    }

    @Test func aNewVersionStillNeedsABuildAndUnknownOrForeignChecksCannotTurnGreen() throws {
        let plan = try plan(), new = QuickRelease.progress(plan: plan, snapshot: try progressSnapshot(plan, target: nil))
        #expect(new[0].check.status == .review && new[2].check.status == .missing)
        let unknown = QuickRelease.progress(plan: plan, snapshot: nil)
        #expect(!unknown.contains { $0.check.status == .ready })
        let foreign = try progressSnapshot(self.plan("9.0"), notesMissing: false, buildMissing: false)
        #expect(!QuickRelease.progress(plan: plan, snapshot: foreign).contains { $0.check.status == .ready })
        let first = QuickRelease.progress(plan: plan, snapshot: try progressSnapshot(plan), notes: ["sv": ""], notesRequired: false)
        #expect(first[1].check.status == .ready && first[1].check.label == "Not Required")
    }

    @Test func submittedUpdatesShowAppleConfirmationInsteadOfOldMissingNotesAndBuild() throws {
        let plan = try plan(), value = QuickRelease.progress(plan: plan, snapshot: try progressSnapshot(plan, state: "WAITING_FOR_REVIEW"))
        #expect(value.allSatisfy { $0.complete } && value[3].check.label == "Waiting for Review")
    }

    @Test func theReleaseOptionSavedWithAPlanStartsTheAppsNextVersion() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first)
        #expect(try await session.releasePreference(accountId: accountId, appId: appId) == nil)
        let editor = await ReleasePlanEditor(account: account, appId: appId, initial: .init(start: .reuse, sourceRevisionId: revisionId, baseVersionId: "version-1", targetVersion: "1.0", releaseType: "AFTER_APPROVAL", date: Date()), session: session)
        await editor.load()
        #expect(await editor.save())
        #expect(try await session.releasePreference(accountId: accountId, appId: appId) == "AFTER_APPROVAL")
        // Another app keeps its own option, and an invalid option is never saved.
        #expect(try await session.releasePreference(accountId: accountId, appId: "1000000002") == nil)
        await #expect(throws: ReleaseFailure.self) { try await session.saveReleasePreference(accountId: accountId, appId: appId, releaseType: "SOON") }
        let suggested = ReleasePlanInputs(start: .copy, releaseType: "MANUAL", date: Date())
        #expect(ReleasePreference.applying("SCHEDULED", to: suggested).releaseType == "SCHEDULED")
        #expect(ReleasePreference.applying(nil, to: suggested).releaseType == "MANUAL" && ReleasePreference.applying("SOON", to: suggested).releaseType == "MANUAL")
    }

    @Test func quickReleaseSavesOnlyItsFourFieldsAndLeavesScreenshotsAndOtherDraftsOnThisMac() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "quick-release-text.appstoreconnect.test"
        // An earlier version is on the App Store, so this is an update and What's New is sent.
        apple.lock.withLock { apple.versions.append(["type": "appStoreVersions", "id": "version-0", "attributes": ["platform": "IOS", "versionString": "0.9", "appVersionState": "READY_FOR_SALE", "releaseType": "MANUAL"], "relationships": ["app": ["data": ["type": "apps", "id": appId]]]]) }
        let history = try await session.revisions(accountId: accountId, appId: appId)
        #expect(!QuickRelease.needsFullRelease(.init(start: .copy, date: Date()), history: history))
        #expect(QuickRelease.needsFullRelease(.init(start: .empty(platform: "IOS", locale: "en-US"), date: Date()), history: history))
        #expect(QuickRelease.needsFullRelease(.init(start: .copy, date: Date()), history: []))
        let saved = try await session.saveReleasePlan(account: account, appId: appId, start: .reuse, sourceRevisionId: revisionId, baseVersionId: "version-1", targetVersion: "1.0",
                                                      releaseType: "MANUAL", earliestReleaseDate: nil, expected: "null")

        var editor = try LanguageEditorState(await session.languageTextDrafts(accountId: accountId, appId: appId, revisionId: revisionId, selections: [.init(id: "version-locale-1", scope: .version), .init(id: "info-locale-1", scope: .appInfo)]))
        for (key, value) in [("description", "Synthetic quick description"), ("keywords", "quick,synthetic"), ("whatsNew", "Synthetic quick fixes"), ("subtitle", "Synthetic quick subtitle"),
                             ("promotionalText", "Synthetic promotion stays local"), ("name", "Synthetic name stays local")] {
            try editor.change(field(editor, key), to: value)
        }
        _ = try await session.saveLanguageDraft(accountId: accountId, appId: appId, revisionId: revisionId, entries: try editor.entries())
        // A screenshot hidden on this Mac stays a local change: Quick Release never sends media.
        let set = try await session.screenshotSet(accountId: accountId, appId: appId, revisionId: revisionId, setId: "set-1")
        _ = try await session.saveScreenshotLayout(accountId: accountId, appId: appId, revisionId: revisionId, setId: "set-1", order: set.items.map(\.id), hidden: ["shot-1"], expected: set.signature)

        let info: [String: Any] = ["type": "appInfoLocalizations", "id": "info-locale-1", "attributes": ["locale": "en-US", "name": "Second synthetic app", "subtitle": "Sample subtitle"], "relationships": ["appInfo": ["data": ["type": "appInfos", "id": "info-1"]]]]
        StubProtocol.handle(host) { request in
            if request.url?.path == "/v1/appInfos/info-1/appInfoLocalizations" { return apple.page([info]) }
            if request.url?.path == "/v1/appInfoLocalizations/info-locale-1" {
                if request.httpMethod == "GET" { return apple.page(info) }
                guard request.httpMethod == "PATCH" else { return (404, [:], Data()) }
                let body = try? JSONSerialization.jsonObject(with: apple.body(request)) as? [String: Any]
                apple.lock.withLock { apple.writes.append(("PATCH", request.url!.path, body)) }; return apple.page(info)
            }
            return apple.handle(request)
        }
        let client = try PublishingTests().client(account, host: host)
        let review = try await session.preparePublishing(account: account, request: QuickRelease.textRequest(accountId: accountId, appId: appId, plan: saved), client: client)
        let bodies = review.steps.compactMap { $0.body?.stringify() }.joined(separator: "\n")
        #expect(review.title.hasPrefix("Save text to App Store Connect") && apple.writes.isEmpty)
        #expect(review.steps.contains { $0.label == "Update version text · en-US" } && review.steps.contains { $0.label == "Update app information · en-US" })
        for sent in ["Synthetic quick description", "quick,synthetic", "Synthetic quick fixes", "Synthetic quick subtitle"] { #expect(bodies.contains(sent), "\(sent)") }
        #expect(!bodies.contains("Synthetic promotion stays local") && !bodies.contains("Synthetic name stays local") && !bodies.contains("promotionalText"))
        #expect(!review.steps.contains { $0.kind == .upload || $0.path.first?.text?.hasPrefix("appAssetLibrary") == true || $0.label.hasPrefix("Remove screenshot") || $0.label.hasPrefix("Add screenshot") })
        #expect(review.notes.contains { $0.hasPrefix("Quick Release saves Description, Subtitle, Keywords and What's New only.") })

        let otherText = try await session.preparePublishing(account: account, request: QuickRelease.textRequest(accountId: accountId, appId: appId, plan: saved, includingOtherText: true), client: client)
        let otherBodies = otherText.steps.compactMap { $0.body?.stringify() }.joined(separator: "\n")
        #expect(otherBodies.contains("Synthetic promotion stays local") && otherBodies.contains("Synthetic name stays local"))
        #expect(!otherText.steps.contains { $0.kind == .upload || $0.path.contains { $0.text?.hasPrefix("appAssetLibrary") == true } })

        let done = try await session.approvePublishing(account: account, appId: appId, id: review.id, fingerprint: review.fingerprint, client: client)
        #expect(done.state == "complete", "\(done.error ?? "")")
        let written = apple.writes.map { $0.2.map { String(describing: $0) } ?? "" }.joined(separator: "\n")
        #expect(written.contains("Synthetic quick subtitle") && written.contains("Synthetic quick fixes"))
        #expect(!written.contains("Synthetic promotion stays local") && !written.contains("Synthetic name stays local"))
        #expect(!apple.writes.contains { $0.1.hasPrefix("/v1/appScreenshot") || $0.1.hasPrefix("/v1/appAssetLibrary") })
        await #expect(throws: PublishFailure.used) { try await session.approvePublishing(account: account, appId: appId, id: review.id, fingerprint: review.fingerprint, client: client) }
    }
}
