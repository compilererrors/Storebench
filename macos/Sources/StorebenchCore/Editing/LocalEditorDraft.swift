import Foundation
import Observation

/// A local working copy, independent of Apple's validation and publishing approval.
public struct LocalEditorDraft: Sendable, Equatable {
    public struct Scope: Sendable, Equatable {
        public let accountId, appId, editor, resource: String
        public init(accountId: String, appId: String, editor: String, resource: String) {
            self.accountId = accountId; self.appId = appId; self.editor = editor; self.resource = resource
        }
        var key: String { JSONText.array([accountId, appId, editor, resource].map(JSONText.string)).stringify() }
    }
    public let revision: Int, value: JSONText
}

extension WorkspaceSession {
    public func localEditorDraft(_ scope: LocalEditorDraft.Scope) throws -> LocalEditorDraft? {
        try storeAccess { store in
            try store.document(namespace: "editor_drafts", key: scope.key).map { .init(revision: $0.revision, value: try JSONText.parse($0.payload)) }
        }
    }
    /// Read, compare and replace under one process-shared mutex. Stale editors never retry against a new revision.
    public func saveLocalEditorDraft(_ value: JSONText, scope: LocalEditorDraft.Scope, expected: Int) throws -> LocalEditorDraft {
        guard ![scope.accountId, scope.appId, scope.editor, scope.resource].contains(where: \.isEmpty), expected >= 0 else { throw DraftFailure.invalid }
        let data = value.data
        guard data.count <= 1_000_000 else { throw DraftFailure.tooLarge }
        return try storeAccess { store in
            let name = "editor_draft_" + JSONText.string(scope.key).rawSHA256.prefix(40) + ".mutex"
            return try FileMutex.withLock(store.directory.appendingPathComponent(name)) {
                try store.transaction { current in
                    try Task.checkCancellation()
                    guard try (current("editor_drafts", scope.key)?.revision ?? 0) == expected else { throw DraftFailure.stale }
                    return [.put(namespace: "editor_drafts", key: scope.key, json: data)]
                }
                return .init(revision: expected + 1, value: value)
            }
        }
    }
}

/// Keeps the exact local baseline until the user explicitly compares a newer save.
@MainActor @Observable public final class LocalEditorDraftEditor {
    public let scope: LocalEditorDraft.Scope
    public private(set) var loaded = false
    public private(set) var busy = false
    public private(set) var needsComparison = false
    private var initialValue: JSONText?
    public func hasChangesToSync(_ value: JSONText) -> Bool { loaded && value != initialValue }
    public private(set) var baseline: JSONText?
    public private(set) var latest: LocalEditorDraft?
    public private(set) var status = ""
    private var expected = 0
    private let session: WorkspaceSession
    public init(scope: LocalEditorDraft.Scope, session: WorkspaceSession) { self.scope = scope; self.session = session }
    public func dirty(_ value: JSONText) -> Bool { loaded && baseline != value }
    public func load(initial: JSONText) async -> JSONText? {
        guard !busy, !loaded else { return nil }
        busy = true; defer { busy = false }
        do {
            let saved = try await session.localEditorDraft(scope)
            try Task.checkCancellation()
            initialValue = initial; baseline = saved?.value ?? initial; expected = saved?.revision ?? 0; loaded = true
            return saved?.value
        } catch { status = "The local draft could not be read. Retry before editing."; return nil }
    }
    @discardableResult public func save(_ value: JSONText) async -> Bool {
        guard loaded, !busy, !needsComparison, !Task.isCancelled else { return false }
        busy = true; defer { busy = false }
        do {
            if !dirty(value) {
                let current = try await session.localEditorDraft(scope)
                guard (current?.revision ?? 0) == expected else { throw DraftFailure.stale }
                return true
            }
            let saved = try await session.saveLocalEditorDraft(value, scope: scope, expected: expected)
            baseline = saved.value; expected = saved.revision; status = "Draft saved on this Mac. Nothing was sent to Apple."
            return true
        } catch {
            if error as? DraftFailure == .stale { needsComparison = true }
            status = (error as? DraftFailure)?.message ?? "The draft could not be saved. Your edits are kept."
            return false
        }
    }
    /// A departure may continue only when this exact save also covers the form's current inputs.
    public func saveCurrent(value: @MainActor () -> JSONText) async -> Bool {
        let saved = await save(value())
        return saved && !dirty(value())
    }
    public func readLatest() async {
        guard loaded, !busy else { return }
        busy = true; defer { busy = false }
        do {
            latest = try await session.localEditorDraft(scope)
            status = "Compare the latest draft, then choose a baseline. Nothing was saved."
        } catch { status = "The latest draft could not be read. Your edits are kept." }
    }
    public func acceptLatest(keepEdits: Bool) -> JSONText? {
        guard !busy, let latest else { return nil }
        baseline = latest.value; expected = latest.revision; self.latest = nil; needsComparison = false
        status = keepEdits ? "Latest draft compared. Save Draft keeps your edits." : "Latest draft loaded. Nothing was saved."
        return keepEdits ? nil : latest.value
    }
}
