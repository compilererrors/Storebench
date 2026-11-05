import Foundation
import Observation

public struct EditingPreferences: Equatable, Sendable {
    public var autosaveDrafts: Bool
    /// Destructive actions that no longer ask first, chosen with Don't ask again and turned back on in Settings.
    public var skippedConfirmations: Set<DestructiveConfirmation>
    public init(autosaveDrafts: Bool = false, skippedConfirmations: Set<DestructiveConfirmation> = []) {
        self.autosaveDrafts = autosaveDrafts; self.skippedConfirmations = skippedConfirmations
    }
    public init(_ value: JSONText) throws {
        guard case .number(let version)? = value["schemaVersion"], version == 1 || version == 2, case .bool(let enabled)? = value["autosaveDrafts"] else { throw DraftFailure.invalid }
        autosaveDrafts = enabled; skippedConfirmations = []
        if version == 2 {
            guard case .array(let skipped)? = value["skippedConfirmations"] else { throw DraftFailure.invalid }
            for item in skipped { guard let kind = item.text.flatMap(DestructiveConfirmation.init) else { throw DraftFailure.invalid }; skippedConfirmations.insert(kind) }
        }
    }
    public var json: JSONText {
        .object([("schemaVersion", .number(2)), ("autosaveDrafts", .bool(autosaveDrafts)),
                 ("skippedConfirmations", .array(DestructiveConfirmation.allCases.filter(skippedConfirmations.contains).map { .string($0.rawValue) }))])
    }
    /// Whether this action asks before it runs.
    public func asks(_ kind: DestructiveConfirmation) -> Bool { !skippedConfirmations.contains(kind) }
}

extension WorkspaceSession {
    public func editingPreferences() throws -> EditingPreferences {
        try storeAccess { store in
            try store.document(namespace: "editing_preferences", key: "current").map { try EditingPreferences(JSONText.parse($0.payload)) } ?? EditingPreferences()
        }
    }
    public func saveEditingPreferences(_ preferences: EditingPreferences) throws {
        _ = try updateEditingPreferences { $0 = preferences }
    }
    /// Changes only what `change` changes, on the preferences saved now, so the autosave choice and each confirmation keep their own latest value.
    public func updateEditingPreferences(_ change: @Sendable (inout EditingPreferences) -> Void) throws -> EditingPreferences {
        try storeAccess { store in
            try FileMutex.withLock(store.directory.appendingPathComponent("editing_preferences.mutex")) {
                var result = EditingPreferences()
                try store.transaction { current in
                    var value = try current("editing_preferences", "current").map { try EditingPreferences(JSONText.parse($0.payload)) } ?? EditingPreferences()
                    change(&value); result = value
                    return [.put(namespace: "editing_preferences", key: "current", json: value.json.data)]
                }
                return result
            }
        }
    }
}

/// Debounces local draft writes, keeps an active write independent of its timer,
/// and pauses after failure until the user explicitly retries or accepts a baseline.
@MainActor @Observable public final class DraftAutosave {
    public enum Phase: Equatable { case idle, waiting, saving, paused }
    public struct Input: Equatable, Sendable {
        let identity, signature: Data
        let enabled, dirty: Bool
        var blocked: Bool
        public init(identity: String, signature: String, enabled: Bool, dirty: Bool, blocked: Bool) {
            self.identity = Data(identity.utf8); self.signature = Data(signature.utf8)
            self.enabled = enabled; self.dirty = dirty; self.blocked = blocked
        }
        var eligible: Bool { enabled && dirty && !blocked }
        public func blocking(_ disabled: Bool) -> Input { var next = self; next.blocked = blocked || disabled; return next }
    }
    public static let debounce: Duration = .milliseconds(1200)
    public private(set) var phase: Phase = .idle
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var sequence: UInt64 = 0
    @ObservationIgnored private var latest: (input: Input, save: @MainActor () async -> Bool)?
    @ObservationIgnored private let delay: @MainActor () async throws -> Void

    public init(delay: @escaping @MainActor () async throws -> Void = { try await Task.sleep(for: DraftAutosave.debounce) }) { self.delay = delay }

    public func update(_ input: Input, save: @escaping @MainActor () async -> Bool) {
        let previous = latest?.input
        latest = (input, save)
        // A save already sent to the local store must finish on its original snapshot.
        guard phase != .saving else { return }
        if phase == .paused, !input.dirty { phase = .idle }
        if previous == input, phase == .waiting { return }
        cancelPending()
        guard input.eligible, phase != .paused else { return }
        phase = .waiting; let ticket = sequence, delay = delay
        pending = Task { [weak self] in
            do { try await delay(); try Task.checkCancellation() } catch { return }
            guard let self, self.sequence == ticket, let request = self.latest, request.input == input, self.phase == .waiting else { return }
            self.pending = nil; self.phase = .saving
            let successful = await request.save()
            self.phase = successful ? .idle : .paused
            // An edit made during the save gets its own delay and snapshot.
            if successful, let next = self.latest, next.input.identity == input.identity, next.input.signature != input.signature {
                self.update(next.input, save: next.save)
            }
        }
    }
    public func cancelPending() {
        sequence &+= 1; pending?.cancel(); pending = nil
        if phase == .waiting { phase = .idle }
    }
    public func stop() { cancelPending(); latest = nil }
    public func pause() { cancelPending(); if phase != .saving { phase = .paused } }
    public func resume() { cancelPending(); if phase != .saving { phase = .idle } }
}
