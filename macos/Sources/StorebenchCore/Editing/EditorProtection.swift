/// Pure navigation/close policy. Busy owners remain protected until their exact lease is released.
public struct EditorProtectionPolicy: Sendable {
    public enum Decision: Equatable, Sendable { case ready, confirmDiscard, wait }
    private struct State: Sendable, Equatable { let dirty, busy: Bool }
    private var editors: [String: State] = [:]
    public init() {}
    public mutating func update(id: String, dirty: Bool, busy: Bool) {
        if dirty || busy { editors[id] = State(dirty: dirty, busy: busy) }
        else { editors.removeValue(forKey: id) }
    }
    public mutating func remove(id: String) { editors.removeValue(forKey: id) }
    public func excluding(id: String) -> Self { var copy = self; copy.remove(id: id); return copy }
    public var decision: Decision {
        if editors.values.contains(where: \.busy) { return .wait }
        return editors.values.contains(where: \.dirty) ? .confirmDiscard : .ready
    }
    /// Changing views does not release a job's lease or close its workspace session.
    public var navigationDecision: Decision { dirtyIds.isEmpty ? .ready : .confirmDiscard }
    public var dirtyIds: Set<String> { Set(editors.filter { $0.value.dirty }.keys) }
    public func isBusy(id: String) -> Bool { editors[id]?.busy == true }
    public func allowsNavigation(after latest: Self, discardConfirmed: Bool) -> Bool {
        if latest.dirtyIds.isEmpty { return true }
        return discardConfirmed && !dirtyIds.isEmpty && latest.dirtyIds.isSubset(of: dirtyIds)
    }
    /// Revalidate after a modal confirmation; it cannot authorize a newly busy or different dirty owner.
    public func allowsLeaving(after latest: Self, discardConfirmed: Bool) -> Bool {
        switch latest.decision {
        case .wait: return false
        case .ready: return true
        case .confirmDiscard: return discardConfirmed && decision == .confirmDiscard && editors == latest.editors
        }
    }
    public static func combined(_ policies: [Self]) -> Decision {
        if policies.contains(where: { $0.decision == .wait }) { return .wait }
        return policies.contains(where: { $0.decision == .confirmDiscard }) ? .confirmDiscard : .ready
    }
    public static func allowsLeaving<Key: Hashable>(starting: [Key: Self], latest: [Key: Self], discardConfirmed: Bool) -> Bool {
        latest.allSatisfy { key, policy in (starting[key] ?? Self()).allowsLeaving(after: policy, discardConfirmed: discardConfirmed) }
    }
}
