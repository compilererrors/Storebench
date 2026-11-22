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
        // Reused app information holds Add for Review back only when Apple is confirmed to differ.
        #expect(!QuickRelease.textNeedsAction(step("apple-info:sv", .unknown)) && QuickRelease.textNeedsAction(step("apple-info:sv", .blocked)))
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

    /// Before App Store Connect has the version, step 1 says what to do next and the build step waits for it without looking broken.
    @Test func aVersionNotCreatedYetSaysToCreateItAndTheBuildWaitsForIt() throws {
        let plan = try plan(), phases = QuickRelease.progress(plan: plan, snapshot: try progressSnapshot(plan, target: nil))
        #expect(phases[0].check.label == "Ready to Create" && phases[0].check.detail.contains("Sync to Apple"), "\(phases[0].check)")
        #expect(phases[2].check.label == "After Step 1" && phases[2].check.status == .review, "\(phases[2].check)")
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
        // The build is still needed, as the next step after creating the version, so it is never green.
        #expect(new[0].check.status == .review && new[2].check.status == .review && new[2].check.label == "After Step 1")
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

    /// Sync to Apple takes App Store Connect's newer text where only Apple changed it, waits for a choice where both sides did
    /// outside Quick Release's fields, and sends every text field when other text is only on this Mac.
    @Test func syncSettlesTextAppStoreConnectChangedBeforeSending() {
        func issue(_ field: String, _ section: String) -> ReleaseMaterial.Issue {
            var value = ReleaseMaterial.Issue(field: field, message: field, section: section)
            if section != "missing" { value.localizationId = "synthetic-locale"; value.scope = .version; value.apple = "Synthetic Apple text"; value.mine = "Synthetic text" }
            return value
        }
        func steps(_ issues: [ReleaseMaterial.Issue]) -> [ReleaseReadiness.Step] {
            var text = step("apple-text:en-US", .blocked); text.issues = issues; return [text]
        }
        let newer = QuickRelease.textSync(steps([issue("promotionalText", ReleaseMaterial.changedAtApple), issue("whatsNew", "missing")]))
        #expect(newer.adopt.map(\.field) == ["promotionalText"] && newer.conflicts.isEmpty)
        #expect(newer.includesOtherText, "A field outside Quick Release that differs must be covered by the review, or Add for Review is never reached")
        #expect(!QuickRelease.textSync(steps([issue("description", ReleaseMaterial.changedAtApple), issue("whatsNew", "missing")])).includesOtherText)
        let both = QuickRelease.textSync(steps([issue("marketingUrl", ReleaseMaterial.changedOnBothSides), issue("whatsNew", ReleaseMaterial.changedOnBothSides)]))
        #expect(both.conflicts.map(\.field) == ["marketingUrl"], "Quick Release's own fields send what was typed here")
        #expect(QuickRelease.textSync(steps([issue("supportUrl", "missing")])).includesOtherText)
    }

    /// An app already on the App Store reuses its countries or regions while Apple's selection can't be read.
    @Test func aPublishedAppReusesItsAvailability() throws {
        let plan = try plan()
        func snapshot(_ state: String) throws -> ReleaseReadinessSnapshot {
            .init(scope: try .init(accountId: plan.accountId, appId: plan.appId), plan: plan, steps: [step("territories", .unknown)], materialSignature: "synthetic-availability",
                  targetVersionId: "version-2", targetState: "PREPARE_FOR_SUBMISSION", parts: .all,
                  observations: .object([("appleVersions", .array([.object([("id", .string("version-1")), ("state", .string(state))])]))]))
        }
        #expect(QuickRelease.reusedAvailability(try snapshot("READY_FOR_DISTRIBUTION"))?.label == "Ready to Reuse")
        #expect(QuickRelease.reusedAvailability(try snapshot("PREPARE_FOR_SUBMISSION")) == nil, "A first version still checks its countries")
    }

    /// A new version whose saved import is older than Apple's listing: only what was typed on this Mac is ever proposed.
    private func newVersionReview(_ prepare: (WorkspaceSession, String) async throws -> Void) async throws -> (bodies: String, review: PublishReview, imported: String) {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "quick-release-new-version-\(UUID().uuidString.lowercased()).appstoreconnect.test"
        let imported = try #require(try await session.textDraft(accountId: accountId, appId: appId, revisionId: revisionId, localizationId: "version-locale-1", scope: .version).fields["description"])
        let live = "Synthetic description changed at App Store Connect after the import"
        #expect(!imported.isEmpty && imported != live)
        // App Store Connect: version 1.0 is on sale with newer text than the import, and 1.1 was created as a copy of it.
        let versions: [[String: Any]] = [
            ["type": "appStoreVersions", "id": "version-1", "attributes": ["platform": "IOS", "versionString": "1.0", "appVersionState": "READY_FOR_SALE", "releaseType": "MANUAL"], "relationships": ["app": ["data": ["type": "apps", "id": appId]]]],
            ["type": "appStoreVersions", "id": "version-2", "attributes": ["platform": "IOS", "versionString": "1.1", "appVersionState": "PREPARE_FOR_SUBMISSION", "releaseType": "MANUAL"], "relationships": ["app": ["data": ["type": "apps", "id": appId]]]]]
        func locale(_ id: String, version: String, notes: String) -> [String: Any] {
            ["type": "appStoreVersionLocalizations", "id": id, "attributes": ["locale": "en-US", "description": live, "keywords": "sample,test", "whatsNew": notes], "relationships": ["appStoreVersion": ["data": ["type": "appStoreVersions", "id": version]]]]
        }
        let info: [String: Any] = ["type": "appInfoLocalizations", "id": "info-locale-1", "attributes": ["locale": "en-US", "name": "Second synthetic app", "subtitle": "Sample subtitle"], "relationships": ["appInfo": ["data": ["type": "appInfos", "id": "info-1"]]]]
        StubProtocol.handle(host) { request in
            switch request.url?.path {
            case "/v1/apps/\(appId)/appStoreVersions": return apple.page(versions)
            case "/v1/appStoreVersions/version-1/appStoreVersionLocalizations": return apple.page([locale("version-locale-1", version: "version-1", notes: "Synthetic earlier notes")])
            case "/v1/appStoreVersions/version-2/appStoreVersionLocalizations": return apple.page([locale("version-locale-2", version: "version-2", notes: "")])
            case "/v1/appInfos/info-1/appInfoLocalizations": return apple.page([info])
            default: return apple.handle(request)
            }
        }
        let saved = try await session.saveReleasePlan(account: account, appId: appId, start: .reuse, sourceRevisionId: revisionId, baseVersionId: "version-1", targetVersion: "1.1",
                                                      releaseType: "MANUAL", earliestReleaseDate: nil, expected: "null")
        try await prepare(session, live)
        let review = try await session.preparePublishing(account: account, request: QuickRelease.textRequest(accountId: accountId, appId: appId, plan: saved), client: try PublishingTests().client(account, host: host))
        #expect(apple.writes.isEmpty)
        return (review.steps.compactMap { $0.body?.stringify() }.joined(separator: "\n"), review, imported)
    }
    private func type(_ session: WorkspaceSession, _ values: [(String, String)], revision: String? = nil) async throws {
        let revision = revision ?? revisionId
        var editor = try LanguageEditorState(await session.languageTextDrafts(accountId: accountId, appId: appId, revisionId: revision, selections: [.init(id: "version-locale-1", scope: .version)]))
        for (key, value) in values { try editor.change(field(editor, key), to: value) }
        _ = try await session.saveLanguageDraft(accountId: accountId, appId: appId, revisionId: revision, entries: try editor.entries())
    }

    /// Sync to Apple with a saved listing older than App Store Connect's: what was never edited here takes Apple's current text,
    /// so nothing old is sent and the status has nothing left to wait for.
    @Test func syncTakesApplesCurrentTextForUneditedFieldsOnly() async throws {
        for start in [ReleaseStart.reuse] {
            let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
            let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "quick-release-reuse-\(UUID().uuidString.lowercased()).appstoreconnect.test"
            let live = "Synthetic description changed at App Store Connect after the import"
            let versions: [[String: Any]] = [
                ["type": "appStoreVersions", "id": "version-1", "attributes": ["platform": "IOS", "versionString": "1.0", "appVersionState": "READY_FOR_SALE", "releaseType": "MANUAL"], "relationships": ["app": ["data": ["type": "apps", "id": appId]]]],
                ["type": "appStoreVersions", "id": "version-2", "attributes": ["platform": "IOS", "versionString": "1.1", "appVersionState": "PREPARE_FOR_SUBMISSION", "releaseType": "MANUAL"], "relationships": ["app": ["data": ["type": "apps", "id": appId]]]]]
            func locale(_ id: String, version: String, notes: String) -> [String: Any] {
                ["type": "appStoreVersionLocalizations", "id": id, "attributes": ["locale": "en-US", "description": live, "keywords": "sample,test", "whatsNew": notes], "relationships": ["appStoreVersion": ["data": ["type": "appStoreVersions", "id": version]]]]
            }
            StubProtocol.handle(host) { request in
                switch request.url?.path {
                case "/v1/apps/\(appId)/appStoreVersions": return apple.page(versions)
                case "/v1/appStoreVersions/version-1/appStoreVersionLocalizations": return apple.page([locale("version-locale-1", version: "version-1", notes: "Synthetic earlier notes")])
                case "/v1/appStoreVersions/version-2/appStoreVersionLocalizations": return apple.page([locale("version-locale-2", version: "version-2", notes: "")])
                default: return apple.handle(request)
                }
            }
            let plan = try await session.saveReleasePlan(account: account, appId: appId, start: start, sourceRevisionId: revisionId, baseVersionId: "version-1", targetVersion: "1.1",
                                                         releaseType: "MANUAL", earliestReleaseDate: nil, expected: "null")
            let client = try PublishingTests().client(account, host: host)
            func saved() async throws -> [String: String] {
                try await session.textDraft(accountId: accountId, appId: appId, revisionId: plan.sourceRevisionId, localizationId: "version-locale-1", scope: .version).fields
            }
            let imported = try #require(try await saved()["description"]); #expect(!imported.isEmpty && imported != live)
            try await type(session, [("whatsNew", "Synthetic new notes")], revision: plan.sourceRevisionId)
            let taken = try await session.reuseCurrentAppleText(account: account, plan: plan, client: client), after = try await saved()
            #expect(taken >= 1 && after["description"] == live && after["whatsNew"] == "Synthetic new notes", "\(start): the older saved description was kept")
            // The review sends the notes and nothing old, and a second sync finds nothing left to take.
            let review = try await session.preparePublishing(account: account, request: QuickRelease.textRequest(accountId: accountId, appId: appId, plan: plan), client: client)
            let bodies = review.steps.compactMap { $0.body?.stringify() }.joined(separator: "\n")
            #expect(bodies.contains("Synthetic new notes") && !bodies.contains("description") && !bodies.contains(imported), "\(start): text that was never edited here was proposed")
            let again = try await session.reuseCurrentAppleText(account: account, plan: plan, client: client)
            #expect(again == 0)
            // A description typed here afterwards is this Mac's: it is never replaced, and it is what the review sends.
            try await type(session, [("description", "Synthetic description written now")], revision: plan.sourceRevisionId)
            let overTyped = try await session.reuseCurrentAppleText(account: account, plan: plan, client: client), kept = try await saved()
            #expect(overTyped == 0 && kept["description"] == "Synthetic description written now")
            let typed = try await session.preparePublishing(account: account, request: QuickRelease.textRequest(accountId: accountId, appId: appId, plan: plan), client: client)
            let sent = typed.steps.compactMap { $0.body?.stringify() }.joined(separator: "\n")
            #expect(sent.contains("Synthetic description written now"), "\(start): the typed description was not sent")
            #expect(apple.writes.isEmpty)
        }
    }

    /// A new version copied on this Mac has no continued version at Apple to read: an unedited field takes the new version's own
    /// text, and one Apple left empty keeps the saved text, which the review then sends.
    @Test func aCopiedVersionTakesTheNewVersionsTextAndFillsWhatAppleLeftEmpty() {
        let record = JSONText.object([("id", .string("synthetic-locale")), ("fields", .object([("locale", .string("en-US")), ("description", .string("Synthetic older description")),
            ("keywords", .string("one,two")), ("promotionalText", .string("Synthetic promotion")), ("supportUrl", .string("https://example.test/support"))]))])
        let apple = AppStoreConnectClient.Resource(type: "appStoreVersionLocalizations", id: "synthetic-target", attributes: ["locale": .string("en-US"), "description": .string("Synthetic newer description"),
            "keywords": .string("one,two,three"), "promotionalText": .string(""), "supportUrl": .string("https://example.test/help"), "marketingUrl": .string("https://example.test/product")], relationships: nil)
        func sha(_ text: String) -> String { JSONText.string(text).rawSHA256 }
        // Keywords were typed here and Support URL was kept with Keep Mine; neither is touched.
        var draft = TextDrafts.empty("synthetic-revision")
            .setting("texts", .object([("synthetic-locale", .object([("keywords", .string("one,two,four"))]))]))
            .setting("keptAppleText", .object([("synthetic-locale", .object([("supportUrl", .string(sha("https://example.test/help")))]))]))
        let fields = TextDrafts.versionFields.filter { $0 != "whatsNew" }
        let taken = WorkspaceSession.reuseAppleText(&draft, record: record, fields: fields, target: apple) { field, imported in
            let there = apple.attributes?[field]?.string ?? ""
            guard let imported else { return there }
            return there.isEmpty ? imported : there
        }
        let texts = draft["texts"]?["synthetic-locale"]
        #expect(taken == 2 && texts?["description"]?.text == "Synthetic newer description" && texts?["marketingUrl"]?.text == "https://example.test/product")
        #expect(texts?["keywords"]?.text == "one,two,four" && texts?["supportUrl"] == nil && texts?["promotionalText"] == nil)
        #expect(draft["takenAppleText"]?["synthetic-locale"]?["description"]?.text == sha("Synthetic newer description"))
        // Taken text is Apple's, not an edit: when Apple changes it again it follows, and nothing of it is ever sent.
        let later = AppStoreConnectClient.Resource(type: apple.type, id: apple.id, attributes: (apple.attributes ?? [:]).merging(["description": .string("Synthetic newest description")]) { _, new in new }, relationships: nil)
        #expect(WorkspaceSession.reuseAppleText(&draft, record: record, fields: fields, target: later) { field, _ in later.attributes?[field]?.string ?? "" } >= 1)
        #expect(draft["texts"]?["synthetic-locale"]?["description"]?.text == "Synthetic newest description" && draft["texts"]?["synthetic-locale"]?["keywords"]?.text == "one,two,four")
        let edited = WorkspaceSession.editedText(WorkspaceSession.fieldPairs(draft["texts"]?["synthetic-locale"]), imported: WorkspaceSession.fieldPairs(record["fields"]), kept: draft["keptAppleText"]?["synthetic-locale"],
                                                 taken: draft["takenAppleText"]?["synthetic-locale"], apple: later)
        #expect(edited.map(\.0) == ["keywords"], "Only what was typed here is this Mac's to send")
    }

    @Test func syncNeverTakesApplesTextOverKeepMine() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "quick-release-kept-\(UUID().uuidString.lowercased()).appstoreconnect.test"
        let live = "Synthetic description changed at App Store Connect after the import"
        let version: [String: Any] = ["type": "appStoreVersions", "id": "version-1", "attributes": ["platform": "IOS", "versionString": "1.0", "appVersionState": "PREPARE_FOR_SUBMISSION", "releaseType": "MANUAL"], "relationships": ["app": ["data": ["type": "apps", "id": appId]]]]
        let locale: [String: Any] = ["type": "appStoreVersionLocalizations", "id": "version-locale-1", "attributes": ["locale": "en-US", "description": live, "keywords": "sample,test", "whatsNew": ""], "relationships": ["appStoreVersion": ["data": ["type": "appStoreVersions", "id": "version-1"]]]]
        StubProtocol.handle(host) { request in
            switch request.url?.path {
            case "/v1/apps/\(appId)/appStoreVersions": return apple.page([version])
            case "/v1/appStoreVersions/version-1/appStoreVersionLocalizations": return apple.page([locale])
            default: return apple.handle(request)
            }
        }
        let plan = try plan("1.0")
        let imported = try #require(try await session.textDraft(accountId: accountId, appId: appId, revisionId: revisionId, localizationId: "version-locale-1", scope: .version).fields["description"])
        try await session.keepDraftText(accountId: accountId, appId: appId, revisionId: revisionId, localizationId: "version-locale-1", scope: .version, apple: ["description": live])
        _ = try await session.reuseCurrentAppleText(account: account, plan: plan, client: try PublishingTests().client(account, host: host))
        let after = try await session.textDraft(accountId: accountId, appId: appId, revisionId: revisionId, localizationId: "version-locale-1", scope: .version).fields["description"]
        #expect(after == imported, "Keep Mine was replaced by App Store Connect's text")
        #expect(apple.writes.isEmpty)
    }

    @Test func aNewVersionNeverGetsTheOlderImportedDescription() async throws {
        // Only What's New was typed: the description stays as App Store Connect has it, and the review says so.
        let result = try await newVersionReview { session, _ in try await self.type(session, [("whatsNew", "Synthetic new notes")]) }
        #expect(result.bodies.contains("Synthetic new notes"))
        #expect(!result.bodies.contains(result.imported) && !result.bodies.contains("description"), "The older saved description was proposed")
        #expect(result.review.notes.contains { $0.hasPrefix("Left as App Store Connect has it now") && $0.contains("Description") })
    }

    @Test func eachStepReadsOnlyWhatItShowsBeforeTheRest() {
        // The open step's parts come first; screenshots at Apple and the details outside the page never hold a step back.
        let slow: ReleaseReadiness.Parts = [.media, .review, .appConfiguration, .ageRating, .accessibility, .availability]
        for step in QuickRelease.stepIDs + ["unchosen"] {
            let parts = QuickRelease.reads(step == "unchosen" ? nil : step)
            #expect(parts.contains(.versions) && parts.isDisjoint(with: slow), "\(step) waits for parts it does not show")
        }
        #expect(QuickRelease.reads("version") == [.versions] && QuickRelease.reads("build") == [.versions, .build])
        #expect(QuickRelease.reads("text") == [.versions, .versionText, .appInfoText])
        // Add for Review lists the text and the build it waits for, and so does the choice of the step that opens first.
        #expect(QuickRelease.reads("submit") == [.versions, .versionText, .appInfoText, .build] && QuickRelease.reads(nil) == QuickRelease.reads("submit"))
        // Every other part still follows in the background, the open step's first.
        let rest = ReleaseReadiness.Parts.batches(ReleaseReadiness.Parts.all.subtracting(QuickRelease.reads("version")), first: QuickRelease.reads("build"))
        #expect(rest.first == [.build] && rest.reduce(into: ReleaseReadiness.Parts()) { $0.formUnion($1) } == ReleaseReadiness.Parts.all.subtracting([.versions]))
    }

    @Test func aDescriptionTypedHereIsSentAlsoAfterKeepMine() async throws {
        // The person wrote a new description, saved it and chose Keep Mine over App Store Connect's text.
        let result = try await newVersionReview { session, live in
            try await self.type(session, [("description", "Synthetic description written now"), ("whatsNew", "Synthetic new notes")])
            try await session.keepDraftText(accountId: self.accountId, appId: self.appId, revisionId: self.revisionId, localizationId: "version-locale-1", scope: .version, apple: ["description": live])
        }
        #expect(result.bodies.contains("Synthetic description written now") && result.bodies.contains("Synthetic new notes"))
        #expect(!result.bodies.contains(result.imported), "The older saved description was proposed instead of the one just written")
        let text = try #require(result.review.steps.first { $0.label == "Update version text · en-US" })
        #expect(text.after?.contains("Synthetic description written now") == true && text.after?.contains(result.imported) != true)
    }

    @Test func textTakenFromAppStoreConnectIsNeverSentBackAndNeverReplacesWhatIsTypedLater() async throws {
        // Use App Store Connect took an earlier reading of Apple's text into the draft. It is Apple's, not an edit, so it is not sent.
        let taken = try await newVersionReview { session, _ in
            try await session.useAppStoreConnectText(accountId: self.accountId, appId: self.appId, revisionId: self.revisionId, localizationId: "version-locale-1", scope: .version, values: ["description": "Synthetic earlier reading of Apple's description"])
            try await self.type(session, [("whatsNew", "Synthetic new notes")])
        }
        #expect(!taken.bodies.contains("Synthetic earlier reading") && !taken.bodies.contains("description") && taken.bodies.contains("Synthetic new notes"))
        // Typing over it afterwards makes the field this Mac's again.
        let typed = try await newVersionReview { session, _ in
            try await session.useAppStoreConnectText(accountId: self.accountId, appId: self.appId, revisionId: self.revisionId, localizationId: "version-locale-1", scope: .version, values: ["description": "Synthetic earlier reading of Apple's description"])
            try await self.type(session, [("description", "Synthetic description written now"), ("whatsNew", "Synthetic new notes")])
        }
        #expect(typed.bodies.contains("Synthetic description written now") && !typed.bodies.contains("Synthetic earlier reading"))
    }
}
