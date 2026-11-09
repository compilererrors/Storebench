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
    public let base: JSONText?
    init(revision: Int, value: JSONText, base: JSONText? = nil) { self.revision = revision; self.value = value; self.base = base }
    static func decode(_ document: EncryptedDocumentStore.Document) throws -> Self {
        let json = try JSONText.parse(document.payload)
        if json["format"] == .string("editor-draft-v1"), let value = json["value"] {
            return .init(revision: document.revision, value: value, base: json["base"])
        }
        return .init(revision: document.revision, value: json)
    }
    static func encoded(_ value: JSONText, base: JSONText?) -> Data {
        guard let base else { return value.data }
        return JSONText.object([("format", .string("editor-draft-v1")), ("value", value), ("base", base)]).data
    }
}

extension WorkspaceSession {
    public func localEditorDraft(_ scope: LocalEditorDraft.Scope) throws -> LocalEditorDraft? {
        try storeAccess { store in
            try store.document(namespace: "editor_drafts", key: scope.key).map(LocalEditorDraft.decode)
        }
    }
    /// Read, compare and replace under one process-shared mutex. Stale editors never retry against a new revision.
    public func saveLocalEditorDraft(_ value: JSONText, scope: LocalEditorDraft.Scope, expected: Int, base: JSONText? = nil) throws -> LocalEditorDraft {
        guard ![scope.accountId, scope.appId, scope.editor, scope.resource].contains(where: \.isEmpty), expected >= 0 else { throw DraftFailure.invalid }
        let data = LocalEditorDraft.encoded(value, base: base)
        guard data.count <= 1_000_000 else { throw DraftFailure.tooLarge }
        return try storeAccess { store in
            let name = "editor_draft_" + JSONText.string(scope.key).rawSHA256.prefix(40) + ".mutex"
            return try FileMutex.withLock(store.directory.appendingPathComponent(name)) {
                try store.transaction { current in
                    try Task.checkCancellation()
                    guard try (current("editor_drafts", scope.key)?.revision ?? 0) == expected else { throw DraftFailure.stale }
                    return [.put(namespace: "editor_drafts", key: scope.key, json: data)]
                }
                return .init(revision: expected + 1, value: value, base: base)
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
    public struct SyncSnapshot: Sendable {
        public let revision: Int, value: JSONText
        public let paths: [[String]]?
    }
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
            initialValue = initial; expected = saved?.revision ?? 0; loaded = true
            guard let saved else { baseline = initial; return nil }
            let merged = Self.merge(saved.value, base: saved.base ?? .null, remote: initial)
            if merged.conflict {
                baseline = initial; latest = saved; needsComparison = true
                status = "Apple and your saved draft changed. Compare the draft before restoring it."
                return nil
            }
            baseline = merged.value
            return merged.value == initial ? nil : merged.value
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
            let saved = try await session.saveLocalEditorDraft(value, scope: scope, expected: expected, base: initialValue)
            baseline = saved.value; expected = saved.revision; status = "Draft saved on this Mac. Nothing was sent to Apple."
            return true
        } catch {
            if error as? DraftFailure == .stale { needsComparison = true }
            status = (error as? DraftFailure)?.message ?? "The draft could not be saved. Your edits are kept."
            return false
        }
    }
    /// The review retains exactly the saved input it represents, including partial-form scope.
    public func syncSnapshot(paths: [[String]]? = nil) -> SyncSnapshot? {
        guard loaded, !busy, !needsComparison, let baseline else { return nil }
        return .init(revision: expected, value: baseline, paths: paths)
    }
    public func acknowledge(_ snapshot: SyncSnapshot) async {
        guard loaded, !busy, expected == snapshot.revision, baseline == snapshot.value, let initialValue else { return }
        busy = true; defer { busy = false }
        let nextBase = Self.applying(snapshot.value, to: initialValue, paths: snapshot.paths)
        do {
            let saved = try await session.saveLocalEditorDraft(snapshot.value, scope: scope, expected: snapshot.revision, base: nextBase)
            expected = saved.revision; self.initialValue = nextBase
            status = "Synced with Apple."
        } catch { status = "Synced with Apple. A newer local draft was kept; compare it before continuing." }
    }
    private static func applying(_ value: JSONText, to base: JSONText, paths: [[String]]?) -> JSONText {
        guard let paths else { return value }
        func replace(_ target: JSONText, source: JSONText, path: ArraySlice<String>) -> JSONText {
            guard let key = path.first else { return source }
            return target.setting(key, replace(target[key] ?? .null, source: source[key] ?? .null, path: path.dropFirst()))
        }
        return paths.reduce(base) { replace($0, source: value, path: $1[...]) }
    }
    /// Local patches follow fresh remote values; overlapping changes require an explicit comparison.
    private static func merge(_ saved: JSONText, base: JSONText, remote: JSONText) -> (value: JSONText, conflict: Bool) {
        if saved == base { return (remote, false) }
        if remote == base || remote == saved { return (saved, false) }
        if case .object(let a) = saved, case .object(let b) = base, case .object(let c) = remote {
            let keys = Set(a.map(\.0) + b.map(\.0) + c.map(\.0)).sorted()
            var conflict = false
            let fields = keys.map { key -> (String, JSONText) in
                let result = merge(saved[key] ?? .null, base: base[key] ?? .null, remote: remote[key] ?? .null)
                conflict = conflict || result.conflict; return (key, result.value)
            }
            return (.object(fields), conflict)
        }
        return (remote, true)
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
