/// An editor's revision changes only after saving or explicitly accepting a comparison.
public struct SavedValueReview<Value: Equatable & Sendable>: Sendable {
    public struct Snapshot: Equatable, Sendable {
        public let value: Value
        public let revision: String
        public init(value: Value, revision: String) { self.value = value; self.revision = revision }
    }
    public private(set) var baseline: Snapshot
    public var inputs: Value
    public private(set) var comparison: Snapshot?
    public var dirty: Bool { inputs != baseline.value }

    public init(value: Value, revision: String) {
        baseline = Snapshot(value: value, revision: revision); inputs = value
    }
    public mutating func compare(value: Value, revision: String) {
        comparison = Snapshot(value: value, revision: revision)
    }
    public mutating func acceptLatest(useSaved: Bool) {
        guard let comparison else { return }
        baseline = comparison
        if useSaved { inputs = comparison.value }
        self.comparison = nil
    }
}
