import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import StorebenchCore

@Suite(.serialized) @MainActor struct MediaListingEditorTests {
    init() throws { _ = try TestIsolation.require() }
    private let scope = MediaDraftScope(accountId: "synthetic-account", appId: "1000000001", revisionId: "00000000-0000-4000-8000-000000000002")
    private enum SyntheticFailure: Error { case timeout }
    private func editor(_ session: WorkspaceSession) async throws -> MediaListingEditor {
        let revision = try #require(try await session.revisions(accountId: scope.accountId, appId: scope.appId).first { $0.id == scope.revisionId })
        let localization = try #require(revision.versions.first { $0.id == "version-1" }?.localizations.first { $0.id == "version-locale-1" })
        let model = MediaListingEditor(scope: scope, localization: localization, platform: "IOS", session: session); await model.load(); return model
    }
    private func settle(_ selected: PendingScreenshotSelection) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while selected.validating { guard ContinuousClock.now < deadline else { throw SyntheticFailure.timeout }; try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func duplicateLoadsAndRetiredSelectionCannotAffectAnotherAppsSelection() async throws {
        var reads = 0
        var resume: CheckedContinuation<ScreenshotSelection, Never>?
        let url = try TestIsolation.require().appendingPathComponent("synthetic-pending.png")
        let previous = PendingScreenshotSelection(scope: scope, platform: "IOS", setId: nil, displayType: nil, urls: [url], read: { _ in
            reads += 1
            return await withCheckedContinuation { resume = $0 }
        }, save: { _ in throw SyntheticFailure.timeout })
        let loading = Task { await previous.load() }
        let deadline = ContinuousClock.now + .seconds(5)
        while resume == nil { guard ContinuousClock.now < deadline else { throw SyntheticFailure.timeout }; await Task.yield() }
        for _ in 0..<20 { await previous.load() }
        #expect(reads == 1 && previous.reading)
        previous.retire()
        let otherScope = MediaDraftScope(accountId: scope.accountId, appId: "1000000002", revisionId: scope.revisionId)
        let next = PendingScreenshotSelection(scope: otherScope, platform: "IOS", setId: nil, displayType: nil, urls: [],
            read: { _ in ScreenshotSelection(items: []) }, save: { _ in throw SyntheticFailure.timeout })
        await next.load()
        resume?.resume(returning: ScreenshotSelection(items: [.init(name: "synthetic-old.png", data: Data([1]))]))
        await loading.value
        #expect(!previous.active && previous.selection == nil && previous.readProgress == nil && !previous.busy)
        #expect(next.active && next.scope == otherScope && next.selection?.items.isEmpty == true && next.status.isEmpty && !next.busy)
        next.retire()
    }

    @Test func retiringSharedMediaKeepsAnotherTextsWorkflowOwnership() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let revision = try #require(try await session.revisions(accountId: scope.accountId, appId: scope.appId).first { $0.id == scope.revisionId })
        let localization = try #require(revision.versions.first { $0.id == "version-1" }?.localizations.first)
        let workflow = ListingSaveWorkflow(identity: "Synthetic shared media and text"); var dirty = true, saves = 0
        workflow.register(priority: .text, state: { .init(dirty: dirty, blocked: false, signature: "Synthetic text") }, save: { saves += 1; dirty = false; return true })
        let model = MediaListingEditor(scope: scope, localization: localization, platform: "IOS", session: session, workflow: workflow)
        await model.load(); #expect(!model.dirty && workflow.dirty)
        model.retire(); let result = await workflow.run()
        #expect(result.complete && result.saves == 1 && saves == 1 && workflow.ready && !model.active)
    }

    @Test func allLayoutsAndSelectedImagesAndVideosSaveBeforeReviewWithoutRemounting() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try await editor(session), initial = model.screenshots.map(\.editor)
        #expect(model.previews.count == PreviewSpecs.types(platform: "IOS").count && model.previews.allSatisfy { $0.editor.draft != nil })
        let layout = try #require(model.screenshots.first { $0.id == "set-1" }); layout.editor.inputs.hidden.insert("shot-1")
        var urls: [URL] = []
        for seed in 0..<10 {
            let url = root.appendingPathComponent("synthetic-selected-\(seed).png"); try syntheticPNG(width: 1290, height: 2796, seed: UInt8(seed)).write(to: url); urls.append(url)
        }
        let images = try #require(model.selectScreenshots(urls, setId: "set-1", displayType: "APP_IPHONE_67")); await images.load(); try await settle(images)
        let video = root.appendingPathComponent("synthetic-selected.mp4"); try syntheticMovie().write(to: video)
        let preview = try #require(model.selectPreview(video, type: "IPHONE_67")); var prepares = 0
        let result = await model.run(prepare: {
            prepares += 1
            let shots = try await session.screenshotSet(accountId: scope.accountId, appId: scope.appId, revisionId: scope.revisionId, setId: "set-1")
            let videos = try await session.previewSet(accountId: scope.accountId, appId: scope.appId, revisionId: scope.revisionId, localizationId: "version-locale-1", type: "IPHONE_67")
            #expect(shots.items.count == 11 && shots.hidden == ["shot-1"] && videos.items.count == 1)
        })
        #expect(result.reviewReady && result.saves == 3 && prepares == 1 && model.workflow.ready)
        #expect(!images.dirty && !preview.pending && layout.editor.inputs.order.count == 11)
        #expect(zip(initial, model.screenshots.map(\.editor)).allSatisfy { pair in pair.0 === pair.1 })
        #expect(model.previews.first { $0.type == "IPHONE_67" }?.editor.inputs.order.count == 1)
    }

    @Test func aFailedVideoKeepsItsFileAndDoesNotDuplicateAnEarlierSaveOnRetry() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try await editor(session), valid = root.appendingPathComponent("synthetic-valid.mp4"), invalid = root.appendingPathComponent("synthetic-short.mp4")
        try syntheticMovie().write(to: valid); try syntheticMovie(seconds: 10).write(to: invalid)
        let first = try #require(model.selectPreview(valid, type: "IPHONE_67")), second = try #require(model.selectPreview(invalid, type: "IPHONE_67"))
        var prepares = 0
        let failed = await model.run(prepare: { prepares += 1 })
        #expect(failed.failure == .save && failed.saves == 1 && !first.pending && second.pending && !second.status.isEmpty && prepares == 0)
        try syntheticMovie(seed: 1).write(to: invalid)
        let retry = await model.run(prepare: { prepares += 1 })
        #expect(retry.reviewReady && retry.saves == 1 && !second.pending && prepares == 1)
        let videos = try await session.previewSet(accountId: scope.accountId, appId: scope.appId, revisionId: scope.revisionId, localizationId: "version-locale-1", type: "IPHONE_67")
        #expect(videos.items.count == 2 && model.workflow.ready)
    }

    @Test func unreadImagesRemainPendingAndCanBeRetriedOrExplicitlyRemoved() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try await editor(session), missing = root.appendingPathComponent("synthetic-not-yet-readable.png")
        let selected = try #require(model.selectScreenshots([missing])); await selected.load()
        #expect(selected.dirty && selected.state.blocked && selected.selection == nil && !selected.status.isEmpty)
        var prepares = 0; let blocked = await model.run(prepare: { prepares += 1 })
        #expect(blocked.failure == .blocked && prepares == 0)
        try syntheticPNG(width: 1290, height: 2796).write(to: missing); await selected.load(); try await settle(selected)
        #expect(selected.ready && selected.selection?.items.first?.originalName == missing.lastPathComponent)
        selected.clear(); #expect(!selected.dirty && !selected.state.blocked)
        let removed = await model.run(prepare: { prepares += 1 }); #expect(removed.reviewReady && removed.saves == 0 && prepares == 1)
    }

    @Test func invalidImagesBlockReviewAndKeepOriginalsAfterEditingSessions() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try await editor(session), url = root.appendingPathComponent("synthetic-original.png"), original = syntheticPNG(width: 20, height: 10)
        try original.write(to: url); let selected = try #require(model.selectScreenshots([url])); await selected.load(); try await settle(selected)
        #expect(selected.problem != nil && selected.state.blocked)
        let item = try #require(selected.selection?.items.first), edits = ScreenshotEdits(width: 1290, height: 2796)
        selected.setEditing(true); try selected.apply(item.id, data: syntheticJPEG(width: 1290, height: 2796), edits: edits); selected.setEditing(false); try await settle(selected)
        #expect(selected.ready && selected.selection?.items.first?.original == original && selected.selection?.items.first?.edits == edits)
        selected.setEditing(true); selected.setEditing(false)
        #expect(selected.selection?.items.first?.original == original && selected.selection?.items.first?.name == "synthetic-original-edited.jpg")
        let result = await model.run(); #expect(result.complete && result.saves == 1 && !selected.dirty)
    }

    @Test func anOwnAdditionCreatesOnePersistentNewSizeWithItsConfirmedCatalog() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try await editor(session), before = model.screenshots.count, url = root.appendingPathComponent("synthetic-new-size.png")
        try syntheticPNG(width: 2048, height: 2732).write(to: url)
        let selected = try #require(model.selectScreenshots([url])); await selected.load(); try await settle(selected)
        #expect(selected.ready); let result = await model.run()
        #expect(result.complete && model.screenshots.count == before + 1 && model.workflow.ready)
        let new = try #require(model.screenshots.last); #expect(new.editor.inputs.order.count == 1 && new.editor.draft != nil)
        let again = try #require(model.selectScreenshots([url])); await again.load(); try await settle(again); let repeated = await model.run()
        #expect(repeated.complete && model.screenshots.count == before + 1 && model.screenshots.last?.editor === new.editor && new.editor.inputs.order.count == 2)
    }

    private func translucentPNG(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 0.4)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData(), destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil); #expect(CGImageDestinationFinalize(destination)); return data as Data
    }

    @Test func imagesWithAnAlphaChannelAreFlattenedOnWhiteAndOpaqueImagesStayUntouched() throws {
        let translucent = try translucentPNG(width: 1290, height: 2796)
        #expect(throws: ScreenshotFailure.self) { try ScreenshotSpecs.validate(translucent) }
        let flat = try #require(try ScreenshotRenderer.opaque(translucent))
        let image = try ScreenshotSpecs.validate(flat)
        #expect(image.width == 1290 && image.height == 2796 && image.contentType == "image/png")
        #expect(try ScreenshotRenderer.opaque(syntheticPNG(width: 1290, height: 2796)) == nil)
    }

    @Test func addingScreenshotsSavesThemIntoTheDraftAtOnce() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try await editor(session)
        let total = { model.screenshots.reduce(0) { $0 + $1.editor.inputs.order.count } }, before = total()
        let opaque = root.appendingPathComponent("synthetic-added-opaque.png"), translucent = root.appendingPathComponent("synthetic-added-translucent.png")
        try syntheticPNG(width: 1290, height: 2796, seed: 7).write(to: opaque); try translucentPNG(width: 1290, height: 2796).write(to: translucent)
        let added = try #require(await model.addScreenshots([opaque, translucent]))
        #expect(!added.dirty && !added.busy && !model.dirty && model.workflow.ready && total() == before + 2)
        #expect(model.status == "2 screenshots added and saved on this Mac. Transparency was replaced with white in 1 image, as Apple requires.")
        // A file that cannot be used stays in the section with its problem instead of being saved.
        let wrong = root.appendingPathComponent("synthetic-wrong-size.png"); try syntheticPNG(width: 20, height: 10).write(to: wrong)
        let rejected = try #require(await model.addScreenshots([wrong]))
        #expect(rejected.dirty && rejected.problem != nil && !rejected.ready && model.dirty && total() == before + 2)
        // Leaving or moving on names this exact item and its next step.
        let marked = try #require(model.unsavedItem)
        #expect(marked.hasPrefix("1 screenshot not added. ") && marked.hasSuffix("Choose Fix Images… or Discard."))
        rejected.clear(); #expect(!rejected.dirty && !model.dirty && model.unsavedItem == nil)
    }

    @Test func fileDialogsBlockSavingAndRetiredEditorsCannotStartQueuedWork() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try await editor(session); model.fileDialogOpen = true
        var prepares = 0; let blocked = await model.run(prepare: { prepares += 1 })
        #expect(blocked.failure == .blocked && prepares == 0 && model.busy)
        model.fileDialogOpen = false; model.retire()
        let retired = await model.run(prepare: { prepares += 1 }); #expect(retired.failure == .cancelled && prepares == 0 && !model.active)
    }

    @Test func reopeningReadsNewSavedSizesEvenWhenTheParentRevisionSnapshotIsOlder() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try #require(try await session.revisions(accountId: scope.accountId, appId: scope.appId).first { $0.id == scope.revisionId })
        let language = try #require(source.versions.first { $0.id == "version-1" }?.localizations.first { $0.id == "version-locale-1" })
        let first = MediaListingEditor(scope: scope, localization: language, platform: "IOS", session: session); await first.load()
        let url = root.appendingPathComponent("synthetic-reopened.png"); try syntheticPNG(width: 2048, height: 2732).write(to: url)
        let selection = try #require(first.selectScreenshots([url])); await selection.load(); try await settle(selection)
        let saved = await first.run(); #expect(saved.complete); first.retire()
        let second = MediaListingEditor(scope: scope, localization: language, platform: "IOS", session: session); await second.load()
        #expect(second.screenshots.count == language.screenshotSets.count + 1 && second.workflow.ready)
        let new = try #require(second.screenshots.first { entry in !language.screenshotSets.contains { $0.id == entry.id } })
        #expect(new.editor.inputs.order.count == 1)
    }

    @Test func anUnreadCatalogCannotBeTreatedAsAnEmptyReadyListing() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try #require(try await session.revisions(accountId: scope.accountId, appId: scope.appId).first { $0.id == scope.revisionId })
        let language = try #require(source.versions.first?.localizations.first)
        let missing = MediaDraftScope(accountId: scope.accountId, appId: scope.appId, revisionId: "00000000-0000-4000-8000-000000000099")
        let model = MediaListingEditor(scope: missing, localization: language, platform: "IOS", session: session); await model.load()
        #expect(model.catalogFailed && model.screenshots.isEmpty && model.workflow.blocked && !model.status.isEmpty)
        var prepares = 0; let result = await model.run(prepare: { prepares += 1 })
        #expect(result.failure == .blocked && prepares == 0)
        await model.retryCatalog(); #expect(model.catalogFailed && model.workflow.blocked)
        model.retire()
    }

    @Test func protectionAndReviewValidityChangeImmediatelyWithoutWaitingForAViewUpdate() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let model = try await editor(session); var policy = EditorProtectionPolicy()
        model.didChange = { [weak model] in
            guard let model else { return }; policy.update(id: "synthetic-owned-editor", dirty: model.dirty, busy: model.busy)
        }
        let result = await model.run(prepare: { #expect(policy.decision == .wait) })
        #expect(result.reviewReady && policy.decision == .ready && model.workflow.owns(result))
        let layout = try #require(model.screenshots.first { $0.id == "set-1" })
        layout.editor.inputs.hidden.insert("shot-1")
        #expect(policy.decision == .confirmDiscard && !model.workflow.owns(result))
        #expect(await layout.editor.save()); #expect(policy.decision == .ready && !model.workflow.owns(result))
        model.fileDialogOpen = true; #expect(policy.decision == .wait)
        model.fileDialogOpen = false; #expect(policy.decision == .ready)
        model.didChange = {}
    }
}
