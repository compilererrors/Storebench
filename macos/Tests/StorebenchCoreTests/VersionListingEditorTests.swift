import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) @MainActor struct VersionListingEditorTests {
    init() throws { _ = try TestIsolation.require() }
    private enum SyntheticFailure: Error { case timeout }
    @MainActor private final class Gate {
        var entered = false
        private var continuation: CheckedContinuation<Void, Never>?
        func hold() async { await withCheckedContinuation { continuation = $0; entered = true } }
        func release() { continuation?.resume(); continuation = nil }
        func wait() async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while !entered { guard ContinuousClock.now < deadline else { throw SyntheticFailure.timeout }; try await Task.sleep(for: .milliseconds(10)) }
        }
    }
    private func plan(_ session: WorkspaceSession) async throws -> ReleasePlanEditor {
        let account = try #require(try await session.accounts().first)
        let model = ReleasePlanEditor(account: account, appId: "1000000001", initial: .init(start: .empty(platform: "IOS", locale: "en-US"), date: Date(timeIntervalSince1970: 2_000_000_000)), session: session)
        await model.load(); model.inputs.targetVersion = "2.0"; #expect(await model.save()); return model
    }
    private func textField(_ language: VersionListingEditor.Language) throws -> LanguageEditorState.Field {
        try #require(language.text.editor?.fields.first { $0.key == "description" })
    }
    private func settle(_ selection: PendingScreenshotSelection) async throws {
        await selection.load(); let deadline = ContinuousClock.now + .seconds(5)
        while selection.validating { guard ContinuousClock.now < deadline else { throw SyntheticFailure.timeout }; try await Task.sleep(for: .milliseconds(10)) }
    }
    @Test func initialListingUsesTheCapturedPlannedSourceAndIncludesAllHiddenEditors() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let plan = try await plan(session), model = try VersionListingEditor(planEditor: plan, session: session)
        #expect(model.workflow.blocked); await model.load()
        let language = try #require(model.languages.first), saved = try #require(plan.plan)
        #expect(model.revision?.id == saved.sourceRevisionId && model.version?.id == saved.baseVersionId && model.workflow.ready && model.languages.count == 1)
        #expect(language.text.editor?.selections.count == 2 && language.media.count == 1)
        #expect(language.media[0].previews.count == PreviewSpecs.types(platform: "IOS").count && language.media[0].previews.allSatisfy { $0.editor.draft != nil })
        let request = try model.publishingRequest(); #expect(request.revisionId == saved.sourceRevisionId && request.versionId == saved.baseVersionId && request.targetMode == "release-plan")
    }
    @Test func copiedListingKeepsPreviousTextAndScreenshotsAndSavesReorderRemovalAndNewFilesLocally() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), sourceOwner = try await plan(session), source = try #require(sourceOwner.plan)
        let sourceListing = try VersionListingEditor(planEditor: sourceOwner, session: session); await sourceListing.load()
        let language = try #require(sourceListing.languages.first), text = try #require(language.text.editor)
        let values = ["name": "Synthetic App", "subtitle": "Synthetic subtitle", "privacyPolicyUrl": "https://example.test/privacy", "privacyChoicesUrl": "https://example.test/choices",
            "privacyPolicyText": "Synthetic privacy text", "description": "Synthetic description", "keywords": "synthetic,example", "supportUrl": "https://example.test/support",
            "marketingUrl": "https://example.test/product", "promotionalText": "Synthetic promotion", "whatsNew": "Previous synthetic notes"]
        for field in text.fields { try language.text.change(field, to: values[field.key] ?? "") }
        #expect((await sourceListing.run()).complete)
        let sourceLocale = try #require(language.media.first?.localizationId)
        _ = try await session.addScreenshots(accountId: account.id, appId: source.appId, revisionId: source.sourceRevisionId, localizationId: sourceLocale, setId: nil,
            files: [("synthetic-one.png", syntheticPNG(width: 1290, height: 2796, seed: 1)), ("synthetic-two.png", syntheticPNG(width: 1290, height: 2796, seed: 2))])
        try await session.removeReleasePlan(accountId: account.id, appId: source.appId, expected: source.token)
        let copied = try await session.saveReleasePlan(account: account, appId: source.appId, start: .copy, sourceRevisionId: source.sourceRevisionId, baseVersionId: source.baseVersionId,
            targetVersion: "2.1", releaseType: "MANUAL", earliestReleaseDate: nil, expected: "null")
        let owner = ReleasePlanEditor(account: account, appId: source.appId, initial: .init(date: Date(timeIntervalSince1970: 2_000_000_000)), session: session)
        await owner.load(); let listing = try VersionListingEditor(planEditor: owner, session: session); await listing.load()
        let copiedLanguage = try #require(listing.languages.first), copiedText = try #require(copiedLanguage.text.editor)
        for field in copiedText.fields { #expect(copiedText.value(field) == (field.key == "whatsNew" ? "" : values[field.key] ?? "")) }
        #expect(!copiedText.dirty)
        let media = try #require(copiedLanguage.media.first), layout = try #require(media.screenshots.first?.editor)
        let originalOrder = layout.inputs.order; #expect(originalOrder.count == 2)
        #expect(layout.reorder(Array(originalOrder.reversed()), expected: originalOrder, context: layout.reorderContext))
        layout.inputs.hidden.insert(originalOrder[0])
        let result = await listing.run(); #expect(result.complete)
        let set = try await session.screenshotSet(accountId: account.id, appId: source.appId, revisionId: copied.sourceRevisionId, setId: media.screenshots[0].id)
        #expect(set.items.map(\.id) == Array(originalOrder.reversed()) && set.hidden == [originalOrder[0]])
        let url = root.appendingPathComponent("synthetic-added.png"); try syntheticPNG(width: 1290, height: 2796, seed: 3).write(to: url)
        let selection = try #require(media.selectScreenshots([url])); try await settle(selection)
        #expect((await listing.run()).complete)
        let catalog = try await session.screenshotCatalog(accountId: account.id, appId: source.appId, revisionId: copied.sourceRevisionId, localizationId: sourceLocale)
        #expect(catalog.flatMap(\.items).count == 3 && catalog.flatMap(\.hidden) == [originalOrder[0]])
        let unchanged = try await session.screenshotCatalog(accountId: account.id, appId: source.appId, revisionId: source.sourceRevisionId, localizationId: sourceLocale)
        #expect(unchanged.flatMap(\.items).count == 2 && unchanged.flatMap(\.hidden).isEmpty)
    }
    @Test func addingAnEmptyLanguageKeepsDirtyTextAndLayoutOwnersWithoutRemounting() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let plan = try await plan(session), saved = try #require(plan.plan)
        _ = try await session.addScreenshots(accountId: saved.accountId, appId: saved.appId, revisionId: saved.sourceRevisionId, localizationId: "local-locale-\(saved.sourceRevisionId)", setId: nil, files: [("synthetic-before.png", syntheticPNG(width: 1290, height: 2796))])
        let model = try VersionListingEditor(planEditor: plan, session: session); await model.load()
        let first = try #require(model.languages.first), field = try textField(first), layout = try #require(first.media.first?.screenshots.first?.editor), image = try #require(layout.inputs.order.first)
        try first.text.change(field, to: "Synthetic retained dirty text"); layout.inputs.hidden.insert(image)
        #expect(await model.addLanguage("sv")); let original = try #require(model.languages.first { $0.locale == "en-US" })
        #expect(original.text === first.text && original.media.first === first.media.first && original.media.first?.screenshots.first?.editor === layout)
        #expect(original.text.dirty && original.text.editor?.value(field) == "Synthetic retained dirty text" && layout.inputs.hidden == [image])
        #expect(model.languages.count == 2 && model.languages.last?.text.editor?.selections.count == 2 && model.workflow.dirty)
        let result = await model.run(); #expect(result.complete && result.saves == 2 && model.workflow.ready)
    }
    @Test func pagingSortingAndCollapseKeepDirtyOwnersAndPendingOriginalsInTheListingSave() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let plan = try await plan(session), saved = try #require(plan.plan), model = try VersionListingEditor(planEditor: plan, session: session)
        await model.load()
        let first = try #require(model.languages.first), media = try #require(first.media.first), field = try textField(first)
        try first.text.change(field, to: "Synthetic hidden language text")
        let url = root.appendingPathComponent("synthetic-hidden-selection.png"); try syntheticPNG(width: 1290, height: 2796).write(to: url)
        let pending = try #require(media.selectScreenshots([url])); try await settle(pending)
        for locale in ["sv", "de-DE", "fr-FR", "it", "ja", "ko"] { #expect(await model.addLanguage(locale)) }
        let ids = model.languages.map(\.id)
        var presentation = CollectionPresentation<String>(pageSize: 5)
        presentation.setPageExpanded(presentation.page(ids), false)
        presentation.choosePage(2); presentation.setPageExpanded(presentation.page(ids), true)
        presentation.chooseSize(10); presentation.reveal(first.id, in: Array(ids.reversed()))
        presentation.setPageExpanded(presentation.page(Array(ids.reversed())), false)
        #expect(model.languages.first?.text === first.text && first.text.active && media.active)
        #expect(first.text.dirty && first.text.editor?.value(field) == "Synthetic hidden language text" && pending.dirty)
        let result = await model.run()
        #expect(result.complete && model.workflow.ready && !first.text.dirty && !pending.dirty)
        let texts = try await session.languageTextDrafts(accountId: saved.accountId, appId: saved.appId, revisionId: saved.sourceRevisionId, selections: try #require(first.text.editor?.selections))
        #expect(texts.first { $0.selection.scope == .version }?.draft.fields["description"] == "Synthetic hidden language text")
        #expect(try await session.screenshotCatalog(accountId: saved.accountId, appId: saved.appId, revisionId: saved.sourceRevisionId, localizationId: media.localizationId).flatMap(\.items).count == 1)
    }
    @Test func allLanguageTextsLayoutsAndPendingOriginalsSaveBeforeOneReview() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let plan = try await plan(session), saved = try #require(plan.plan), model = try VersionListingEditor(planEditor: plan, session: session)
        await model.load(); #expect(await model.addLanguage("sv"))
        for language in model.languages { try language.text.change(textField(language), to: "Synthetic combined \(language.locale) wording") }
        let first = try #require(model.languages.first), media = try #require(first.media.first)
        let url = root.appendingPathComponent("synthetic-combined.png"); try syntheticPNG(width: 1290, height: 2796).write(to: url)
        let selected = try #require(media.selectScreenshots([url])); try await settle(selected)
        var preparations = 0
        let result = await model.run(prepare: {
            preparations += 1
            for language in model.languages {
                let sections = try await session.languageTextDrafts(accountId: saved.accountId, appId: saved.appId, revisionId: saved.sourceRevisionId, selections: try #require(language.text.editor?.selections))
                #expect(sections.first { $0.selection.scope == .version }?.draft.fields["description"] == "Synthetic combined \(language.locale) wording")
            }
            #expect(try await session.screenshotCatalog(accountId: saved.accountId, appId: saved.appId, revisionId: saved.sourceRevisionId, localizationId: media.localizationId).flatMap(\.items).count == 1)
        })
        #expect(result.reviewReady && result.saves == 3 && preparations == 1 && !selected.dirty && model.workflow.ready)
    }
    @Test func unreadPlanMismatchBlocksInitialMaterialInsteadOfAdoptingLatest() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let owner = try await plan(session), saved = try #require(owner.plan), account = try #require(try await session.accounts().first)
        _ = try await session.saveReleasePlan(account: account, appId: saved.appId, start: .reuse, sourceRevisionId: saved.sourceRevisionId, baseVersionId: saved.baseVersionId, targetVersion: "3.0", releaseType: "MANUAL", earliestReleaseDate: nil, expected: saved.token)
        let model = try VersionListingEditor(planEditor: owner, session: session); await model.load()
        #expect(model.catalogFailed && model.languages.isEmpty && model.workflow.blocked && owner.expected == saved.token)
        let result = await model.run(); #expect(result.failure == .blocked)
        await owner.readLatest(); owner.acceptLatest(keepEdits: false); await model.load()
        #expect(!model.catalogFailed && model.workflow.ready && model.matchesPlan && owner.inputs.targetVersion == "3.0")
    }
    @Test func aPlanEditAndItsSaveDuringPreparationInvalidateTheOlderReview() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let plan = try await plan(session), model = try VersionListingEditor(planEditor: plan, session: session), gate = Gate()
        await model.load(); let task = Task { await model.run(prepare: { await gate.hold() }) }; try await gate.wait(); defer { gate.release() }
        plan.inputs.releaseType = "AFTER_APPROVAL"; #expect(model.workflow.blocked)
        #expect(await plan.save()); #expect(!plan.dirty && model.matchesPlan)
        gate.release(); let result = await task.value
        #expect(result.failure == .changed && !result.reviewReady && model.workflow.ready)
    }
    @Test func aFailedPendingFileKeepsOtherConfirmedLanguageSavesForRetry() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let plan = try await plan(session), model = try VersionListingEditor(planEditor: plan, session: session); await model.load()
        let language = try #require(model.languages.first), media = try #require(language.media.first)
        try language.text.change(textField(language), to: "Synthetic first saved wording")
        let video = root.appendingPathComponent("synthetic-retry.mp4"); try syntheticMovie(seconds: 10).write(to: video)
        let selection = try #require(media.selectPreview(video, type: "IPHONE_67")); var prepares = 0
        let failed = await model.run(prepare: { prepares += 1 })
        #expect(failed.failure == .save && failed.saves == 1 && !language.text.dirty && selection.pending && prepares == 0)
        try syntheticMovie().write(to: video); let retry = await model.run(prepare: { prepares += 1 })
        #expect(retry.reviewReady && retry.saves == 1 && !selection.pending && prepares == 1)
    }
    @Test func retiredListingCannotStartQueuedSavesOrRemoveThePlanOwnersObservers() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let plan = try await plan(session), model = try VersionListingEditor(planEditor: plan, session: session); var notifications = 0
        let other = plan.observe { notifications += 1 }; await model.load(); model.retire()
        let result = await model.run(); #expect(result.failure == .cancelled && !model.active)
        plan.inputs.targetVersion = "3.0"; #expect(notifications > 0 && plan.active && plan.dirty)
        plan.removeObserver(other)
    }
    @Test func aConfirmedBulkSaveAdvancesOnlyMatchingCleanTextAndKeepsLateInputs() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let plan = try await plan(session), saved = try #require(plan.plan), model = try VersionListingEditor(planEditor: plan, session: session)
        await model.load(); #expect(await model.addLanguage("sv"))
        let revision = try #require(model.revision), destination = try #require(model.languages.first { $0.locale == "sv" })
        let late = try LanguageDraftEditor(scope: model.scope, revision: revision, versionId: model.versionId, locale: "sv", session: session)
        await late.load(); let lateField = try #require(late.editor?.fields.first { $0.key == "description" })
        let snapshot = try await session.releaseText(accountId: saved.accountId, appId: saved.appId, revisionId: saved.sourceRevisionId, planToken: saved.token)
        let source = try #require(snapshot.rows.first { $0.locale == "en-US" }), target = try #require(snapshot.rows.first { $0.locale == "sv" })
        let selection = ReleaseText.Selection(versionId: saved.baseVersionId, sourceLocale: source.locale, sourceBaseline: source.values,
            targets: [.init(locale: target.locale, baseline: target.values, values: .init(whatsNew: "Synthetic confirmed release notes"), copied: [])], replaceExisting: false)
        let preview = try await session.previewReleaseText(accountId: saved.accountId, appId: saved.appId, revisionId: saved.sourceRevisionId, planToken: saved.token, selection: selection)
        let receipt = try await session.applyReleaseTextWithReceipt(accountId: saved.accountId, appId: saved.appId, revisionId: saved.sourceRevisionId, planToken: saved.token, selection: selection, fingerprint: preview.fingerprint)
        try late.change(lateField, to: "Synthetic late description"); #expect(!late.reconcile(receipt))
        #expect(late.dirty && late.needsComparison && late.editor?.value(lateField) == "Synthetic late description")
        model.reconcile(receipt)
        let notes = try #require(destination.text.editor?.fields.first { $0.key == "whatsNew" })
        #expect(destination.text.editor?.value(notes) == "Synthetic confirmed release notes")
        #expect(!destination.text.dirty)
        #expect(!destination.text.needsComparison)
        #expect(model.workflow.ready)
        let foreign = ReleaseTextSaveReceipt(scope: .init(accountId: "synthetic-other-account", appId: saved.appId, revisionId: saved.sourceRevisionId), preview: receipt.preview, before: receipt.before, after: receipt.after)
        #expect(!destination.text.reconcile(foreign)); #expect(!destination.text.needsComparison)
        #expect(!destination.text.reconcile(receipt)); #expect(destination.text.needsComparison && model.workflow.blocked)
    }
}
