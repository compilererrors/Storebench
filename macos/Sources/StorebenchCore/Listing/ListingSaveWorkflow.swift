import Foundation
import Observation

/// Saves each owned editor once, before a saved listing may be prepared for Publish.
@MainActor @Observable public final class ListingSaveWorkflow {
    public enum Priority: Int, Sendable { case text = -1, layout = 0, file = 1 }
    public enum Phase: Equatable, Sendable { case saving, preparing }
    public enum Failure: Equatable, Sendable { case busy, blocked, changed, save, preparation, cancelled }
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
        let priority: Priority, ordinal: UInt64
        let state: @MainActor () -> State
        let save: @MainActor () async -> Bool
        init(priority: Priority, ordinal: UInt64, state: @escaping @MainActor () -> State, save: @escaping @MainActor () async -> Bool) {
            self.priority = priority; self.ordinal = ordinal; self.state = state; self.save = save
        }
    }
    private struct Job { let id: UUID, entry: Entry, signature: Data }
    @ObservationIgnored private var identity: Data
    @ObservationIgnored private var entries: [UUID: Entry] = [:]
    @ObservationIgnored private var ticket: UUID?
    @ObservationIgnored private var ordinal: UInt64 = 0
    @ObservationIgnored public var didChange: @MainActor () -> Void = {}
    @ObservationIgnored private var observers: [UUID: @MainActor () -> Void] = [:]
    private var changes: UInt64 = 0
    public private(set) var phase: Phase? { didSet { notifyObservers() } }
    public private(set) var lastResult: Result?
    public var busy: Bool { phase != nil }
    public var dirty: Bool { _ = changes; return entries.values.contains { $0.state().dirty } }
    public var blocked: Bool { _ = changes; return entries.values.contains { $0.state().blocked } }
    public var ready: Bool { !busy && !dirty && !blocked }

    public init(identity: String) { self.identity = Data(identity.utf8) }

    /// Providers read current inputs directly; a view update is not proof that an editor is ready.
    @discardableResult public func register(priority: Priority, state: @escaping @MainActor () -> State, save: @escaping @MainActor () async -> Bool) -> UUID {
        let id = UUID(); entries[id] = Entry(priority: priority, ordinal: ordinal, state: state, save: save)
        ordinal &+= 1; changed(); return id
    }
    public func changed() { lastResult = nil; notifyChange() }
    private func notifyChange() { changes &+= 1; notifyObservers() }
    private func notifyObservers() { didChange(); for observer in Array(observers.values) { observer() } }
    /// Each persistent owner releases only its own observer and registrations.
    @discardableResult public func observe(_ observer: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID(); observers[id] = observer; return id
    }
    public func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    public func unregister(_ id: UUID) { if entries.removeValue(forKey: id) != nil { changed() } }
    public func cancel() { ticket = nil; phase = nil; lastResult = nil }
    public func reset(identity: String) {
        cancel(); self.identity = Data(identity.utf8); entries.removeAll(); ordinal = 0; changed()
    }
    public func owns(_ result: Result) -> Bool { !busy && lastResult == result }

    /// A failed or interrupted run keeps remaining inputs. Preparing never approves an Apple write.
    public func run(prepare: (@MainActor () async throws -> Void)? = nil) async -> Result {
        let id = UUID()
        guard !busy else { return Result(id: id, saves: 0, prepared: false, failure: .busy) }
        guard !blocked else { return Result(id: id, saves: 0, prepared: false, failure: .blocked) }
        guard !Task.isCancelled else { return Result(id: id, saves: 0, prepared: false, failure: .cancelled) }
        let starting = identity
        ticket = id; phase = .saving; lastResult = nil
        let owners = entries
        let jobs = entries.compactMap { key, entry -> Job? in
            let value = entry.state(); return value.dirty ? Job(id: key, entry: entry, signature: value.signature) : nil
        }.sorted { lhs, rhs in
            lhs.entry.priority == rhs.entry.priority ? lhs.entry.ordinal < rhs.entry.ordinal : lhs.entry.priority.rawValue < rhs.entry.priority.rawValue
        }
        var saves = 0, prepared = false
        func finish(_ failure: Failure?) -> Result {
            let result = Result(id: id, saves: saves, prepared: prepared, failure: failure)
            if ticket == id, identity == starting { ticket = nil; phase = nil; lastResult = result; notifyChange() }
            return result
        }
        func interrupted() -> Bool { Task.isCancelled || ticket != id || identity != starting }
        func retainedOwners() -> Bool { owners.allSatisfy { entries[$0.key] === $0.value } }
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
        guard !dirty else { return finish(.changed) }
        guard !blocked else { return finish(.blocked) }
        if let prepare {
            phase = .preparing
            let preparingChanges = changes, preparedInputs = entries.mapValues { $0.state() }
            do { try await prepare(); prepared = true }
            catch is CancellationError { return finish(.cancelled) }
            catch { return finish(interrupted() ? .cancelled : .preparation) }
            guard !interrupted() else { return finish(.cancelled) }
            guard retainedOwners() else { return finish(.changed) }
            guard changes == preparingChanges, entries.count == preparedInputs.count,
                  entries.allSatisfy({ preparedInputs[$0.key] == $0.value.state() }) else { return finish(.changed) }
            guard !dirty else { return finish(.changed) }
            guard !blocked else { return finish(.blocked) }
        }
        return finish(nil)
    }
}
