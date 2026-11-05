import Foundation
import Observation

public struct MediaDraftScope: Equatable, Sendable {
    public let accountId, appId, revisionId: String
    public init(accountId: String, appId: String, revisionId: String) {
        self.accountId = accountId; self.appId = appId; self.revisionId = revisionId
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.accountId.utf8.elementsEqual(rhs.accountId.utf8) && lhs.appId.utf8.elementsEqual(rhs.appId.utf8) && lhs.revisionId.utf8.elementsEqual(rhs.revisionId.utf8)
    }
}

/// A confirmed catalog is kept separately from the editor's current inputs.
public enum MediaLayoutDraft: Sendable {
    case screenshots(ScreenshotSetDraft)
    case previews(localizationId: String, type: String, draft: PreviewSetDraft)
    public var key: String {
        switch self {
        case .screenshots(let draft): return JSONText.array([.string("screenshots"), .string(draft.setId)]).stringify()
        case .previews(let localizationId, let type, _): return JSONText.array([.string("previews"), .string(localizationId), .string(type)]).stringify()
        }
    }
    public var signature: String {
        switch self { case .screenshots(let draft): draft.signature; case .previews(_, _, let draft): draft.signature }
    }
    public var inputs: MediaDraftInputs {
        switch self { case .screenshots(let draft): MediaDraftInputs(draft); case .previews(_, _, let draft): MediaDraftInputs(draft) }
    }
    public var names: [(String, String)] {
        switch self { case .screenshots(let draft): draft.items.map { ($0.id, $0.fileName) }; case .previews(_, _, let draft): draft.items.map { ($0.id, $0.fileName) } }
    }
    public func problem(_ inputs: MediaDraftInputs) -> String? {
        let ids = self.inputs.order, available = Set(ids)
        guard available.count == ids.count, inputs.order.count == ids.count, Set(inputs.order) == available,
              inputs.hidden.isSubset(of: available), Set(inputs.posterTimes.keys).isSubset(of: available) else { return "Compare the latest media catalog before saving this layout." }
        switch self {
        case .screenshots:
            guard inputs.order.filter({ !inputs.hidden.contains($0) }).count <= ScreenshotSpecs.maximum else { return "Include no more than 10 screenshots per display size." }
            guard inputs.posterTimes.isEmpty else { return "Screenshot layouts do not have poster frames." }
        case .previews(_, _, let draft):
            guard inputs.order.filter({ !inputs.hidden.contains($0) }).count <= PreviewSpecs.maximum else { return "Include no more than 3 app previews per display size." }
            for (id, time) in inputs.posterTimes {
                guard let duration = draft.items.first(where: { $0.id == id })?.duration, time.isFinite, time >= 0, time < duration else { return "Choose a poster frame within the video's duration." }
            }
        }
        return nil
    }
}

/// Before and after catalogs come from the same atomic draft mutation.
public struct MediaCatalogChange: Sendable {
    public let before: MediaLayoutDraft?, after: MediaLayoutDraft
    public init(before: MediaLayoutDraft?, after: MediaLayoutDraft) { self.before = before; self.after = after }
}
public struct MediaAdditionReceipt: Sendable {
    public let scope: MediaDraftScope, count: Int, changes: [MediaCatalogChange]
    public init(scope: MediaDraftScope, count: Int, changes: [MediaCatalogChange]) { self.scope = scope; self.count = count; self.changes = changes }
}

/// Owns a media layout across view updates without adopting another writer's baseline.
@MainActor @Observable public final class MediaLayoutEditor {
    public let scope: MediaDraftScope, key: String, identity: String
    public let autosave = DraftAutosave()
    @ObservationIgnored public var didChange: @MainActor () -> Void = {}
    public private(set) var draft: MediaLayoutDraft? { didSet { didChange() } }
    public var inputs = MediaDraftInputs(order: [], hidden: []) { didSet { latest = nil; didChange() } }
    public private(set) var latest: MediaLayoutDraft?
    public private(set) var status = ""
    public private(set) var loading = false { didSet { didChange() } }
    public private(set) var saving = false { didSet { didChange() } }
    public private(set) var readingLatest = false { didSet { didChange() } }
    public private(set) var needsComparison = false { didSet { didChange() } }
    public private(set) var active = true
    @ObservationIgnored private var operation: UUID?
    @ObservationIgnored private let read: @MainActor () async throws -> MediaLayoutDraft
    @ObservationIgnored private let write: @MainActor (MediaDraftInputs, String) async throws -> MediaLayoutDraft
    public var busy: Bool { loading || saving || readingLatest }
    public var dirty: Bool { draft.map { inputs != $0.inputs } ?? false }
    public var included: Int { inputs.order.filter { !inputs.hidden.contains($0) }.count }
    public var problem: String? { draft?.problem(inputs) }
    public var state: ListingSaveWorkflow.State { .init(dirty: dirty, blocked: !active || busy || draft == nil || needsComparison || problem != nil, signature: inputs.signature) }
    public var reorderContext: String { identity + ":" + (draft?.signature ?? "") }
    @discardableResult public func reorder(_ order: [String], expected: [String], context: String) -> Bool {
        guard !state.blocked, reorderContext == context, inputs.order == expected, order.count == expected.count, Set(order) == Set(expected), Set(order).count == order.count else { return false }
        guard order != expected else { return true }
        inputs.order = order; status = "Order changed locally. Save Layout keeps it on this Mac; Upload opens a review before anything is sent to Apple."
        return true
    }

    public init(scope: MediaDraftScope, key: String, draft: MediaLayoutDraft? = nil, read: @escaping @MainActor () async throws -> MediaLayoutDraft,
                save: @escaping @MainActor (MediaDraftInputs, String) async throws -> MediaLayoutDraft) {
        self.scope = scope; self.key = key; self.read = read; self.write = save
        identity = JSONText.array([.string(scope.accountId), .string(scope.appId), .string(scope.revisionId), .string(key)]).stringify()
        if let draft, key.utf8.elementsEqual(draft.key.utf8) { self.draft = draft; inputs = draft.inputs }
    }
    public func retire() {
        active = false; operation = nil; loading = false; saving = false; readingLatest = false; autosave.stop()
    }
    public func revert() {
        guard active, !busy, let draft else { return }
        inputs = draft.inputs; latest = nil; autosave.resume()
    }
    public func load() async {
        guard active, !busy, draft == nil, !Task.isCancelled else { return }
        let ticket = UUID(); operation = ticket; loading = true; autosave.cancelPending()
        defer { if owns(ticket) { operation = nil; loading = false } }
        do {
            let value = try await read(); try Task.checkCancellation()
            guard owns(ticket), sameKey(value) else { return }
            draft = value; inputs = value.inputs; needsComparison = false; status = ""; autosave.resume()
        } catch {
            guard owns(ticket) else { return }
            status = "The saved media layout could not be read. Read the latest save before continuing."
        }
    }
    /// A clean, valid editor succeeds without writing. Later inputs remain unsaved after a confirmed write.
    public func save(automatic: Bool = false) async -> Bool {
        guard active, !busy, !needsComparison, problem == nil, let draft, !Task.isCancelled else { return false }
        guard dirty else { return true }
        if !automatic { autosave.resume() }
        let snapshot = inputs, ticket = UUID(); operation = ticket; saving = true
        defer { if owns(ticket) { operation = nil; saving = false } }
        do {
            let confirmed = try await write(snapshot, draft.signature)
            guard sameKey(confirmed), confirmed.inputs == snapshot else { throw DraftFailure.invalid }
            // A physical write has finished even if its editor has since been retired.
            guard owns(ticket) else { return true }
            self.draft = confirmed; latest = nil
            status = dirty ? "Earlier layout saved. Newer edits are waiting to save." : "Layout saved on this Mac."
            return true
        } catch {
            guard owns(ticket) else { return false }
            status = Self.message(error); autosave.pause(); return false
        }
    }
    public func readLatest() async {
        guard active, !busy, !Task.isCancelled else { return }
        let ticket = UUID(); operation = ticket; readingLatest = true; latest = nil; autosave.pause()
        defer { if owns(ticket) { operation = nil; readingLatest = false } }
        do {
            let value = try await read(); try Task.checkCancellation()
            guard owns(ticket), sameKey(value) else { return }
            latest = value; status = "Latest layout read. Compare and explicitly choose a baseline; nothing was saved."
        } catch { if owns(ticket) { status = "The latest layout could not be read. Your edits are kept." } }
    }
    public func acceptLatest(keepEdits: Bool) {
        guard active, !busy, let latest else { return }
        let next = keepEdits && draft != nil ? inputs.keepingEdits(on: latest.inputs) : latest.inputs
        draft = latest; inputs = next; self.latest = nil; needsComparison = false; autosave.pause()
        status = keepEdits ? "Latest layout compared. Choose Save Layout to keep your edits; autosave is paused." : "Latest layout loaded. Nothing was saved by the comparison."
    }
    /// Only this workflow's confirmed addition may advance a clean matching baseline.
    @discardableResult public func reconcile(_ change: MediaCatalogChange, scope: MediaDraftScope) -> Bool {
        guard active, scope == self.scope, sameKey(change.after) else { return false }
        guard !busy, !dirty, let draft, let before = change.before, sameKey(before),
              draft.signature.utf8.elementsEqual(before.signature.utf8), !needsComparison else {
            needsComparison = true; latest = nil; autosave.pause()
            status = "The media catalog changed. Your edits are kept; compare the latest save before continuing."
            return false
        }
        self.draft = change.after; inputs = change.after.inputs; latest = nil; return true
    }
    private func owns(_ ticket: UUID) -> Bool { active && operation == ticket }
    private func sameKey(_ value: MediaLayoutDraft) -> Bool { key.utf8.elementsEqual(value.key.utf8) }
    private static func message(_ error: any Error) -> String {
        if let error = error as? ScreenshotFailure { return error.message }
        if let error = error as? PreviewFailure { return error.message }
        if let error = error as? DraftFailure { return error.message }
        return "The layout could not be saved locally. Your edits are kept."
    }
}
