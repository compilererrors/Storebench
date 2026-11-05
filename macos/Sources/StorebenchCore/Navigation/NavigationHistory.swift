import Foundation

/// History advances only after protected navigation accepts the exact pending destination.
public struct NavigationHistory<Destination: Equatable & Sendable>: Sendable {
    public enum Direction: Sendable { case back, forward }
    public struct Request: Sendable {
        public let destination: Destination
        fileprivate let index: Int, generation: UUID
    }
    private var entries: [Destination]
    private var identities: [UUID]
    private var index = 0
    private var generation = UUID()
    private let limit: Int
    public init(_ initial: Destination, limit: Int = 100) { entries = [initial]; identities = [UUID()]; self.limit = max(1, min(200, limit)) }
    public var current: Destination { entries[index] }
    public var currentID: UUID { identities[index] }
    public var entryIDs: Set<UUID> { Set(identities) }
    public var count: Int { entries.count }
    public var canGoBack: Bool { index > 0 }
    public var canGoForward: Bool { index + 1 < entries.count }
    public mutating func visit(_ destination: Destination) {
        guard destination != current else { return }
        entries.removeSubrange((index + 1)..<entries.count)
        identities.removeSubrange((index + 1)..<identities.count)
        entries.append(destination)
        identities.append(UUID())
        if entries.count > limit { let removed = entries.count - limit; entries.removeFirst(removed); identities.removeFirst(removed) }
        index = entries.count - 1; generation = UUID()
    }
    /// Refines the current entry without adding one, such as the step a view chose by itself when it opened.
    public mutating func replace(_ destination: Destination) {
        guard destination != current else { return }
        entries[index] = destination; generation = UUID()
    }
    public func request(_ direction: Direction) -> Request? {
        let target = index + (direction == .back ? -1 : 1)
        guard entries.indices.contains(target) else { return nil }
        return Request(destination: entries[target], index: target, generation: generation)
    }
    @discardableResult public mutating func commit(_ request: Request) -> Bool {
        guard request.generation == generation, entries.indices.contains(request.index), entries[request.index] == request.destination else { return false }
        index = request.index; generation = UUID(); return true
    }
}
