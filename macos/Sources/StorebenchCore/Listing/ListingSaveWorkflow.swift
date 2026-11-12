import Foundation
import Observation

/// Saves each owned editor once, before a saved listing may be prepared for Publish.
@MainActor @Observable public final class ListingSaveWorkflow {
    public enum Priority: Int, Sendable { case text = -1, layout = 0, file = 1 }
    public enum Phase: Equatable, Sendable { case saving, preparing }
    public enum Failure: Equatable, Sendable {
        case busy, blocked, changed, save, preparation, cancelled
        public var message: String {
            switch self {
            case .busy: "Wait for the current save or review preparation to finish."
            case .blocked: "Finish reading or comparing the selected editor and confirm its inputs before continuing."
            case .changed: "The selected inputs changed while preparing. Your edits are kept; prepare this part again."
            case .save: "The local save could not be confirmed. Your remaining edits are kept."
            case .preparation: "The App Store review could not be prepared. Your local saves are kept."
            case .cancelled: "The operation stopped. Your confirmed saves and remaining edits are kept."
            }
        }
    }
    public struct State: Equatable, Sendable {
        public let dirty, blocked: Bool
        let signature: Data
        public init(dirty: Bool, blocked: Bool, signature: String) {
            self.dirty = dirty; self.blocked = blocked; self.signature = Data(signature.utf8)
        }
    }
    public struct Result: Equatable, Sendable {
        public let id: UUID, saves: Int, prepared: Bool, failure: Failure?
        public var savedAny: Bool { saves > 0 }
        public var complete: Bool { failure == nil }
        public var reviewReady: Bool { complete && prepared }
    }
    @MainActor private final class Entry {
        let priority: Priority, ordinal: UInt64, required: Bool
        let state: @MainActor () -> State
        let save: @MainActor () async -> Bool
        init(priority: Priority, ordinal: UInt64, required: Bool, state: @escaping @MainActor () -> State, save: @escaping @MainActor () async -> Bool) {
            self.priority = priority; self.ordinal = ordinal; self.required = required; self.state = state; self.save = save
        }
    }
    private struct Job { let id: UUID, entry: Entry, signature: Data }
    @ObservationIgnored private var identity: Data
    @ObservationIgnored private var entries: [UUID: Entry] = [:]
    @ObservationIgnored private var ticket: UUID?
    @ObservationIgnored private var ordinal: UInt64 = 0
    @ObservationIgnored public var didChange: @MainActor () -> Void = {}
    @ObservationIgnored private var observers: [UUID: @MainActor () -> Void] = [:]
    /// What views show: the combined answer, which changes only when it actually changes, so typing in one language
    /// does not refresh every view that reads this workflow. Decisions read `dirty`, `blocked` and `ready` instead.
    public struct Shown: Equatable, Sendable {
        public var dirty = false, blocked = false, busy = false
        public var ready: Bool { !busy && !dirty && !blocked }
    }
    public var shown: Shown { verifyShown(); return storedShown }
    private var storedShown = Shown()
    /// Changes when providers are added or removed, which their own observed state cannot report.
    private var structure: UInt64 = 0
    @ObservationIgnored private var verifying = false
    /// Counts reported input changes, so a preparation can tell whether anything changed while it ran.
    @ObservationIgnored private var changes: UInt64 = 0
    public private(set) var phase: Phase? { didSet { notifyObservers() } }
    public private(set) var lastResult: Result?
    public var busy: Bool { phase != nil }
    /// Read from every provider now.
    public var dirty: Bool { _ = structure; return entries.values.contains { $0.state().dirty } }
    public var blocked: Bool { _ = structure; return entries.values.contains { $0.state().blocked } }
    public var ready: Bool { !busy && !dirty && !blocked }

    public init(identity: String) { self.identity = Data(identity.utf8) }

    /// Providers read current inputs directly; a view update is not proof that an editor is ready.
    @discardableResult public func register(priority: Priority, required: Bool = false, state: @escaping @MainActor () -> State, save: @escaping @MainActor () async -> Bool) -> UUID {
        let id = UUID(); entries[id] = Entry(priority: priority, ordinal: ordinal, required: required, state: state, save: save)
        ordinal &+= 1; structure &+= 1; changed(); return id
    }
    public func changed() { if lastResult != nil { lastResult = nil }; changes &+= 1; notifyObservers() }
    private func notifyObservers() { refreshShown(); didChange(); for observer in Array(observers.values) { observer() } }
    private func refreshShown() {
        let next = Shown(dirty: entries.values.contains { $0.state().dirty }, blocked: entries.values.contains { $0.state().blocked }, busy: busy)
        if next != storedShown { storedShown = next }
    }
    /// A provider whose state changed without reporting it is picked up on the next main-actor turn, outside the reading view.
    private func verifyShown() {
        guard !verifying else { return }
        verifying = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.verifying = false; self.refreshShown()
        }
    }
    /// Each persistent owner releases only its own observer and registrations.
    @discardableResult public func observe(_ observer: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID(); observers[id] = observer; return id
    }
    public func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    public func unregister(_ id: UUID) { if entries.removeValue(forKey: id) != nil { structure &+= 1; changed() } }
    public func cancel() { ticket = nil; phase = nil; lastResult = nil }
    public func reset(identity: String) {
        cancel(); self.identity = Data(identity.utf8); entries.removeAll(); ordinal = 0; structure &+= 1; changed()
    }
    public func owns(_ result: Result) -> Bool { !busy && lastResult == result }

    /// A part keeps the version/account gates, while unrelated languages and media keep their own inputs.
    private func selected(_ only: Set<UUID>?) -> [UUID: Entry]? {
        guard let only else { return entries }
        guard !only.isEmpty, only.allSatisfy({ entries[$0] != nil }) else { return nil }
        return entries.filter { only.contains($0.key) || $0.value.required }
    }
    public func inputsReady(only: Set<UUID>) -> Bool {
        _ = structure
        guard let owners = selected(only) else { return false }
        return owners.values.allSatisfy { let state = $0.state(); return !state.dirty && !state.blocked }
    }
    public func ready(only: Set<UUID>) -> Bool { !busy && inputsReady(only: only) }

    /// A failed or interrupted run keeps remaining inputs. Preparing never approves an Apple write.
    public func run(only: Set<UUID>? = nil, prepare: (@MainActor () async throws -> Void)? = nil) async -> Result {
        let id = UUID()
        guard !busy else { return Result(id: id, saves: 0, prepared: false, failure: .busy) }
        guard let owners = selected(only), !owners.values.contains(where: { $0.state().blocked }) else { return Result(id: id, saves: 0, prepared: false, failure: .blocked) }
        guard !Task.isCancelled else { return Result(id: id, saves: 0, prepared: false, failure: .cancelled) }
        let starting = identity
        ticket = id; phase = .saving; lastResult = nil
        let jobs = owners.compactMap { key, entry -> Job? in
            let value = entry.state(); return value.dirty ? Job(id: key, entry: entry, signature: value.signature) : nil
        }.sorted { lhs, rhs in
            lhs.entry.priority == rhs.entry.priority ? lhs.entry.ordinal < rhs.entry.ordinal : lhs.entry.priority.rawValue < rhs.entry.priority.rawValue
        }
        var saves = 0, prepared = false
        func finish(_ failure: Failure?) -> Result {
            let result = Result(id: id, saves: saves, prepared: prepared, failure: failure)
            if ticket == id, identity == starting { ticket = nil; phase = nil; lastResult = result; changes &+= 1; notifyObservers() }
            return result
        }
        func interrupted() -> Bool { Task.isCancelled || ticket != id || identity != starting }
        func retainedOwners() -> Bool { owners.allSatisfy { entries[$0.key] === $0.value } }
        func selectedDirty() -> Bool { owners.values.contains { $0.state().dirty } }
        func selectedBlocked() -> Bool { owners.values.contains { $0.state().blocked } }
        for job in jobs {
            guard !interrupted() else { return finish(.cancelled) }
            guard entries[job.id] === job.entry else { return finish(.changed) }
            let current = job.entry.state()
            guard !current.blocked else { return finish(.blocked) }
            if !current.dirty { continue }
            guard current.signature == job.signature else { return finish(.changed) }
            let saved = await job.entry.save()
            if saved { saves += 1 }
            guard !interrupted() else { return finish(.cancelled) }
            guard entries[job.id] === job.entry else { return finish(.changed) }
            guard saved else { return finish(.save) }
            guard !job.entry.state().dirty else { return finish(.changed) }
        }
        guard !interrupted() else { return finish(.cancelled) }
        guard retainedOwners() else { return finish(.changed) }
        guard !selectedDirty() else { return finish(.changed) }
        guard !selectedBlocked() else { return finish(.blocked) }
        if let prepare {
            phase = .preparing
            let preparingChanges = changes, preparedInputs = owners.mapValues { $0.state() }
            do { try await prepare(); prepared = true }
            catch is CancellationError { return finish(.cancelled) }
            catch { return finish(interrupted() ? .cancelled : .preparation) }
            guard !interrupted() else { return finish(.cancelled) }
            guard retainedOwners() else { return finish(.changed) }
            guard (only != nil || changes == preparingChanges && entries.count == preparedInputs.count),
                  owners.allSatisfy({ preparedInputs[$0.key] == $0.value.state() }),
                  selected(only)?.count == owners.count else { return finish(.changed) }
            guard !selectedDirty() else { return finish(.changed) }
            guard !selectedBlocked() else { return finish(.blocked) }
        }
        return finish(nil)
    }
}
