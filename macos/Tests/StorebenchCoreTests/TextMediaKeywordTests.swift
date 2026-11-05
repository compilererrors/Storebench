import Foundation
import Testing
@testable import StorebenchCore

@Suite struct TextMediaKeywordTests {
    init() throws { _ = try TestIsolation.require() }

    @Test func compactDatesNormalizeWithoutAcceptingImpossibleDatesOrChangingOtherFields() throws {
        let original = KeywordIdea(term: "  synthetic phrase  ", locale: "en-US", status: "ready", observedOn: " 20320229 ", notes: "Synthetic research")
        let value = try Keywords.validatedInput(original)
        #expect(value.observedOn == "2032-02-29" && value.term == "synthetic phrase" && value.notes == original.notes && value.id == original.id)
        #expect(original.observedOn == " 20320229 ")
        for date in ["2031-02-29", "20310431", "20321301", "20320012", "2032-2-03", "20320229T1200", "٢٠٣٢٠٢٢٩"] {
            var invalid = original; invalid.observedOn = date
            #expect(throws: KeywordInputFailure.self) { try Keywords.validatedInput(invalid) }
            do { _ = try Keywords.validatedInput(invalid); Issue.record("Invalid date was accepted") }
            catch let error as KeywordInputFailure { #expect(error.field == "Observation date") }
        }
        var empty = original; empty.observedOn = ""; #expect(try Keywords.validatedInput(empty).observedOn.isEmpty)
        #expect(throws: KeywordFailure.format) { try Keywords.normalizedIdea(original) }
    }

    @Test func preciseValidationAndReviewedSaveMakeReadyIdeasAvailableInListingPicker() async throws {
        let root = try TestIsolation.require().appendingPathComponent("synthetic-keyword-save-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = VaultWriter(dataRoot: root, storage: MemoryVaultStorage())
        let session = try Workspace(root: root).createFresh(writer: writer, password: nil)
        let baseline = try await session.keywordNotebook(accountId: "synthetic-keywords", appId: "920001")
        var editor = try KeywordNotebookEditor(notebook: baseline.notebook, revision: baseline.revision)
        let candidate = try Keywords.validatedInput(KeywordIdea(term: "synthetic phrase", locale: "en-US", status: "ready", observedOn: "20320510"))
        try editor.change(KeywordNotebook(accountId: baseline.notebook.accountId, appId: baseline.notebook.appId, items: [candidate]))
        #expect(editor.dirty && editor.review == nil)
        try editor.prepareReview(currentRevision: baseline.revision)
        let savedRevision = try await session.saveReviewedKeywordNotebook(editor.reviewedSave())
        try editor.confirmedSave(savedRevision)
        #expect(!editor.dirty)
        let saved = try await session.keywordNotebook(accountId: baseline.notebook.accountId, appId: baseline.notebook.appId)
        let scope = try RecoveryGuidance.Scope(accountId: baseline.notebook.accountId, appId: baseline.notebook.appId)
        let picker = try KeywordPickerSnapshot(notebook: saved.notebook, scope: scope, locale: "en-US")
        let selection = try picker.selection(current: "existing", selected: [candidate.id], mode: .append)
        #expect(selection.proposed == "existing,synthetic phrase" && selection.canUse)
        #expect(try await session.keywordNotebook(accountId: scope.accountId, appId: scope.appId).notebook == saved.notebook)
        try await session.signOut()
    }

    @Test func resizeAndZoomStayFiniteAndWithinTheirOwnTracks() {
        #expect(TextSurfacePresentation.initialHeight(field: "description") > TextSurfacePresentation.initialHeight(field: "keywords"))
        #expect(TextSurfacePresentation.resized(start: 140, translation: -1000) == 70)
        #expect(TextSurfacePresentation.resized(start: 140, translation: 1000) == 800)
        #expect(TextSurfacePresentation.resized(start: 140, translation: .nan) == 140)
        for (w, h) in [(320.0, 400.0), (768, 640), (1440, 900), (1920, 1080)] {
            for (iw, ih) in [(2880.0, 1800.0), (600, 8000), (160, 90)] {
                let fit = MediaViewport.scale(imageWidth: iw, imageHeight: ih, width: w, height: h, zoom: nil)
                #expect(fit.isFinite && iw * fit <= w + 0.001 && ih * fit <= h + 0.001)
                #expect(MediaViewport.scale(imageWidth: iw, imageHeight: ih, width: w, height: h, zoom: 1) == 1)
            }
        }
        #expect(MediaViewport.scale(imageWidth: .nan, imageHeight: 200, width: 600, height: 600, zoom: nil) == 1)
        #expect(MediaViewport.scale(imageWidth: 200, imageHeight: 200, width: 600, height: 600, zoom: .infinity) == 1)
        #expect(MediaViewport.scale(imageWidth: 200, imageHeight: 200, width: 600, height: 600, zoom: 100) == 8)
    }
}
