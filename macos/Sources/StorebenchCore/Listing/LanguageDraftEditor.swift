import Foundation
import Observation

/// Keeps one language's exact text baseline and work ownership across view updates.
@MainActor @Observable public final class LanguageDraftEditor {
    public let scope: MediaDraftScope, versionId: String, locale: String
    public let workflow: ListingSaveWorkflow
    public let autosave = DraftAutosave()
    @ObservationIgnored public var didChange: @MainActor () -> Void = {}
    public private(set) var editor: LanguageEditorState? { didSet { changed() } }
    public private(set) var latest: [LanguageDrafts.Section]?
    public private(set) var loading = false { didSet { changed() } }
    public private(set) var saving = false { didSet { changed() } }
    public private(set) var readingLatest = false { didSet { changed() } }
    public private(set) var needsComparison = false { didSet { changed() } }
    public private(set) var status = ""
    public private(set) var active = true
    public var auxiliaryBusy = false { didSet { changed() } }
    public var dialogOpen = false { didSet { changed() } }
    @ObservationIgnored private let selections: [LanguageDrafts.Selection]
    @ObservationIgnored private let read: @MainActor () async throws -> [LanguageDrafts.Section]
    @ObservationIgnored private let write: @MainActor ([LanguageDrafts.Entry]) async throws -> [String: String]
    @ObservationIgnored private let ownsWorkflow: Bool
    @ObservationIgnored private var operation: UUID?
    @ObservationIgnored private var registration: UUID?
    @ObservationIgnored private var observer: UUID?
    public var dirty: Bool { editor?.dirty == true }
    public var busy: Bool { loading || saving || readingLatest || auxiliaryBusy || dialogOpen }
    public var problem: String? {
        guard let editor else { return "Read the saved language text before continuing." }
        do { _ = try editor.entries(); return nil } catch { return Self.message(error) }
    }
    public var state: ListingSaveWorkflow.State {
        .init(dirty: dirty, blocked: !active || busy || editor == nil || needsComparison || problem != nil, signature: editor?.signature ?? "Unread language text")
    }

    public init(scope: MediaDraftScope, versionId: String, locale: String, selections: [LanguageDrafts.Selection], workflow shared: ListingSaveWorkflow? = nil,
                read: @escaping @MainActor () async throws -> [LanguageDrafts.Section],
                save: @escaping @MainActor ([LanguageDrafts.Entry]) async throws -> [String: String]) {
        self.scope = scope; self.versionId = versionId; self.locale = locale; self.selections = selections; self.read = read; write = save
        ownsWorkflow = shared == nil
        workflow = shared ?? ListingSaveWorkflow(identity: JSONText.array([.string(scope.accountId), .string(scope.appId), .string(scope.revisionId), .string(versionId), .string(locale)]).stringify())
        observer = workflow.observe { [weak self] in self?.didChange() }
        registration = workflow.register(priority: .text, state: { [weak self] in self?.state ?? .init(dirty: false, blocked: true, signature: "Retired language text") },
                                         save: { [weak self] in await self?.save() ?? false })
    }
    public convenience init(scope: MediaDraftScope, revision: Revision, versionId: String, locale: String, session: WorkspaceSession, workflow: ListingSaveWorkflow? = nil) throws {
        let selections = try LanguageEditorState.selections(revision: revision, versionId: versionId, locale: locale)
        self.init(scope: scope, versionId: versionId, locale: locale, selections: selections, workflow: workflow,
                  read: { try await session.languageTextDrafts(accountId: scope.accountId, appId: scope.appId, revisionId: scope.revisionId, selections: selections) },
                  save: { try await session.saveLanguageDraft(accountId: scope.accountId, appId: scope.appId, revisionId: scope.revisionId, entries: $0) })
    }
    public func retire() {
        guard active else { return }; active = false; operation = nil; autosave.stop()
        if let observer { workflow.removeObserver(observer); self.observer = nil }
        if ownsWorkflow { workflow.cancel() }
        if let registration { workflow.unregister(registration); self.registration = nil }
        loading = false; saving = false; readingLatest = false; auxiliaryBusy = false; dialogOpen = false; didChange()
    }
    public func change(_ field: LanguageEditorState.Field, to value: String) throws {
        guard active, !loading, !readingLatest, !auxiliaryBusy, editor != nil else { throw DraftFailure.invalid }
        try editor?.change(field, to: value); latest = nil; status = ""
    }
    public func restoreImport(_ field: LanguageEditorState.Field) throws {
        guard let editor else { throw DraftFailure.invalid }; try change(field, to: editor.original(field))
    }
    public func revert() {
        guard active, !busy else { return }; editor?.discard(); latest = nil; autosave.resume(); status = ""
    }
    public func load(afterReuse: Bool = false) async {
        guard active, !busy, !Task.isCancelled, editor == nil || (afterReuse && !dirty && !needsComparison) else { return }
        let ticket = begin(); loading = true; autosave.cancelPending(); defer { if owns(ticket) { operation = nil; loading = false } }
        do {
            let sections = try await read(); try Task.checkCancellation(); try validate(sections)
            guard owns(ticket) else { return }
            editor = try LanguageEditorState(sections); latest = nil; needsComparison = false; status = ""; autosave.resume()
        } catch { if owns(ticket) { status = "Saved language text could not be read. Compare the latest save before continuing." } }
    }
    @discardableResult public func save(automatic: Bool = false) async -> Bool {
        guard active, !busy, !needsComparison, let snapshot = editor, !Task.isCancelled else { return false }
        do {
            let entries = try snapshot.entries(); if entries.isEmpty { return true }
            if !automatic { autosave.resume() }
            let ticket = begin(); saving = true; defer { if owns(ticket) { operation = nil; saving = false } }
            do {
                let receipt = try await write(entries)
                var verified = snapshot; try verified.confirmed(entries, fingerprints: receipt)
                // The atomic write completed even if this exact editor has since retired.
                guard owns(ticket) else { return true }
                try editor?.confirmed(entries, fingerprints: receipt); latest = nil
                status = dirty ? "Earlier language text saved. Newer edits are waiting to save." : "Language draft saved on this Mac."
                return true
            } catch {
                guard owns(ticket) else { return false }
                if let error = error as? DraftFailure, error == .stale { needsComparison = true }
                status = Self.message(error); autosave.pause(); return false
            }
        } catch { status = Self.message(error); autosave.pause(); return false }
    }
    public func readLatest() async {
        guard active, !busy, !Task.isCancelled else { return }
        let ticket = begin(); readingLatest = true; latest = nil; autosave.pause()
        defer { if owns(ticket) { operation = nil; readingLatest = false } }
        do {
            let sections = try await read(); try Task.checkCancellation(); try validate(sections)
            guard owns(ticket) else { return }
            if editor != nil { try editor?.compare(sections) }
            latest = sections; status = "Latest language text read. Choose a baseline explicitly; nothing was saved."
        } catch { if owns(ticket) { status = "The latest language text could not be read. Your edits are kept." } }
    }
    public func acceptLatest(keepEdits: Bool) {
        guard active, !busy, let latest else { return }
        do {
            if editor == nil { editor = try LanguageEditorState(latest) }
            else { try editor?.compare(latest); editor?.acceptLatest(keepEdits: keepEdits) }
            self.latest = nil; needsComparison = false; autosave.pause()
            status = keepEdits ? "Latest save compared. Choose Save Draft to keep your edits; autosave is paused." : "Saved language text loaded. Nothing was saved by the comparison."
        } catch { status = Self.message(error) }
    }
    public func publishingRequest(targetMode: String) throws -> PublishRequest {
        guard active, !state.blocked, !dirty, let editor else { throw PublishFailure.invalid("Confirm and save the language text before preparing its App Store review.") }
        var request = try editor.publishingRequest(accountId: scope.accountId, appId: scope.appId, revisionId: scope.revisionId, versionId: versionId, targetMode: targetMode)
        request.listingLocale = locale
        return try request.validated()
    }
    /// Only this listing's clean, matching before snapshot can adopt its own confirmed bulk save.
    @discardableResult public func reconcile(_ receipt: ReleaseTextSaveReceipt) -> Bool {
        guard active, receipt.scope == scope, let current = editor else { return false }
        let affected = receipt.before.filter { before in selections.contains { $0.id.utf8.elementsEqual(before.selection.id.utf8) && $0.scope == before.selection.scope } }
        guard !affected.isEmpty else { return false }
        do {
            guard !busy, !dirty, !needsComparison, affected.allSatisfy({ before in
                current.fingerprints[before.selection.id] == before.draft.fingerprint && TextDrafts.sameFields(current.baseline[before.selection.id] ?? [:], before.draft.fields)
            }) else { throw DraftFailure.stale }
            var sections = current.selections.map { selection in
                LanguageDrafts.Section(selection: selection, imported: current.imported[selection.id] ?? [:],
                    draft: .init(fields: current.baseline[selection.id] ?? [:], fingerprint: current.fingerprints[selection.id] ?? "", edited: current.edited))
            }
            for before in affected {
                let matches = receipt.after.filter { $0.selection.id.utf8.elementsEqual(before.selection.id.utf8) && $0.selection.scope == before.selection.scope }
                // The guarded save returns the persisted patch fingerprint, which can differ from the full text projected with imported defaults.
                guard matches.count == 1, let after = matches.first,
                      TextDrafts.sameFields(after.imported, before.imported), after.draft.edited,
                      let index = sections.firstIndex(where: { $0.selection.id.utf8.elementsEqual(after.selection.id.utf8) && $0.selection.scope == after.selection.scope }) else { throw DraftFailure.stale }
                sections[index] = after
            }
            try validate(sections); try editor?.compare(sections); editor?.acceptLatest(keepEdits: false); latest = nil
            status = "Confirmed release fields loaded from this listing's own save."; return true
        } catch {
            needsComparison = true; latest = nil; autosave.pause()
            status = "Release fields were saved. Your editor inputs are kept; compare the latest save before continuing."; return false
        }
    }
    private func validate(_ sections: [LanguageDrafts.Section]) throws {
        _ = try LanguageEditorState(sections)
        guard sections.count == selections.count, sections.allSatisfy({ section in selections.contains {
            $0.id.utf8.elementsEqual(section.selection.id.utf8) && $0.scope == section.selection.scope
        } }) else { throw DraftFailure.invalid }
    }
    private func changed() { workflow.changed() }
    private func begin() -> UUID { let ticket = UUID(); operation = ticket; return ticket }
    private func owns(_ ticket: UUID) -> Bool { active && operation == ticket }
    private static func message(_ error: any Error) -> String {
        (error as? DraftFailure)?.message ?? "The local language save could not be confirmed. Your edits are kept; compare the latest save before retrying."
    }
}
