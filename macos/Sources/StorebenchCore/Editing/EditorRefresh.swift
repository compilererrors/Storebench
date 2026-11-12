import Foundation
import Observation

/// A refresh is scoped to the visible page and never discards inputs without a captured choice.
@MainActor @Observable public final class EditorRefresh {
    public struct State: Equatable, Sendable {
        public let dirty, busy, refreshWhileBusy: Bool
        public let signature: String
        public init(dirty: Bool = false, busy: Bool = false, signature: String = "", refreshWhileBusy: Bool = false) {
            self.dirty = dirty; self.busy = busy; self.signature = signature; self.refreshWhileBusy = refreshWhileBusy
        }
    }
    public enum Choice: Equatable, Sendable { case refresh, save, discard, cancel }
    public struct Confirmation: Identifiable {
        public let id: UUID, canSave, canDiscard: Bool
    }
    private struct Participant {
        let scope, generation: String
        let priority: Int
        let state: @MainActor () -> State
        let save: (@MainActor () async -> Bool)?
        let discard: (@MainActor () -> Bool)?
        let refresh: @MainActor () async -> Bool
    }
    private struct Request {
        let id: UUID, scope: String
        let owners: [UUID: Participant], states: [UUID: State]
    }
    public private(set) var confirmation: Confirmation?
    public private(set) var busy = false
    public private(set) var status = ""
    public private(set) var failed = false
    @ObservationIgnored private var participants: [UUID: Participant] = [:]
    @ObservationIgnored private var request: Request?
    public init() {}
    public func register(id: UUID, scope: String, generation: String, priority: Int = 0,
                         state: @escaping @MainActor () -> State,
                         save: (@MainActor () async -> Bool)? = nil, discard: (@MainActor () -> Bool)? = nil,
                         refresh: @escaping @MainActor () async -> Bool) {
        participants[id] = .init(scope: scope, generation: generation, priority: priority, state: state, save: save, discard: discard, refresh: refresh)
    }
    public func remove(_ id: UUID) { participants.removeValue(forKey: id) }
    public func cancel() { request = nil; confirmation = nil; status = ""; failed = false }
    /// Returns true when the request can proceed, possibly after its confirmation sheet.
    @discardableResult public func begin(scope: String) -> Bool {
        guard !busy else { return false }
        request = nil; confirmation = nil
        let owners = participants.filter { $0.value.scope == scope }, states = owners.mapValues { $0.state() }
        guard !states.values.contains(where: { $0.busy && ($0.dirty || !$0.refreshWhileBusy) }) else { return stop("A card is still working. Wait for it to finish, then refresh.") }
        let captured = Request(id: UUID(), scope: scope, owners: owners, states: states)
        request = captured; status = ""; failed = false
        let dirty = states.filter { $0.value.dirty }.keys
        confirmation = dirty.isEmpty ? nil : .init(id: captured.id,
            canSave: dirty.allSatisfy { owners[$0]?.save != nil }, canDiscard: dirty.allSatisfy { owners[$0]?.discard != nil })
        return true
    }
    /// Save and Discard apply only to the exact inputs captured when Refresh was pressed.
    public func perform(_ choice: Choice, summary: @MainActor () async -> Bool = { true }) async -> Bool {
        if choice == .cancel { cancel(); return false }
        guard !busy, let captured = request, current(captured) else { return false }
        guard !captured.states.values.contains(where: \.dirty) || choice != .refresh else { return false }
        guard inputsCurrent(captured) else { return stopChanged() }
        busy = true; confirmation = nil; status = "Refreshing the cards in this step…"; failed = false
        defer { busy = false; if request?.id == captured.id { request = nil } }
        let ordered = captured.owners.keys.sorted { (captured.owners[$0]!.priority, $0.uuidString) < (captured.owners[$1]!.priority, $1.uuidString) }
        for id in ordered where captured.states[id]?.dirty == true {
            guard current(captured) else { return false }
            guard inputsCurrent(captured), let owner = owner(id, captured), let starting = captured.states[id] else { return stopChanged() }
            let state = owner.state()
            if !state.dirty { continue }
            guard !state.busy, state.signature == starting.signature else { return stopChanged() }
            let settled: Bool
            switch choice {
            case .save: settled = await owner.save?() == true
            case .discard: settled = owner.discard?() == true
            default: return false
            }
            guard current(captured) else { return false }
            guard settled, let latest = self.owner(id, captured)?.state(), !latest.dirty, !latest.busy else {
                return stop("Changes could not be settled. Your remaining inputs are kept; resolve the card before refreshing.")
            }
        }
        guard current(captured) else { return false }
        guard clean(captured) else { return stopChanged() }
        var complete = true
        for id in ordered {
            guard current(captured) else { return false }
            guard clean(captured) else { return stopChanged() }
            guard let owner = owner(id, captured) else { continue }
            if !(await owner.refresh()) { complete = false }
        }
        guard current(captured) else { return false }
        if !(await summary()) { complete = false }
        guard current(captured) else { return false }
        guard clean(captured) else { return stopChanged() }
        if !complete { return stop("Some cards could not be refreshed. Their last known values are kept; see the card for details.") }
        status = "Cards refreshed at " + Date().formatted(date: .omitted, time: .standard) + "."; return true
    }
    private func current(_ captured: Request) -> Bool { !Task.isCancelled && request?.id == captured.id }
    private func owner(_ id: UUID, _ captured: Request) -> Participant? {
        guard let next = participants[id], next.scope == captured.scope, next.generation == captured.owners[id]?.generation else { return nil }
        return next
    }
    private func clean(_ captured: Request) -> Bool {
        participants.filter { $0.value.scope == captured.scope }.allSatisfy {
            let state = $0.value.state(); return !state.dirty && (!state.busy || state.refreshWhileBusy)
        }
    }
    private func inputsCurrent(_ captured: Request) -> Bool {
        for (id, starting) in captured.states where starting.dirty {
            guard owner(id, captured) != nil else { return false }
        }
        return participants.filter { $0.value.scope == captured.scope }.allSatisfy { id, participant in
            let state = participant.state()
            guard !state.busy || (!state.dirty && state.refreshWhileBusy) else { return false }
            return !state.dirty || (participant.generation == captured.owners[id]?.generation && captured.states[id]?.dirty == true && state.signature == captured.states[id]?.signature)
        }
    }
    private func stopChanged() -> Bool { stop("The cards or inputs changed while refreshing. Newer edits are kept. Choose Refresh Status again.") }
    private func stop(_ message: String) -> Bool { confirmation = nil; failed = true; status = message; return false }
}
