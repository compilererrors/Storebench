import Foundation

/// Only the most recently requested destination can apply a completed asynchronous read.
public struct NavigationIntent: Sendable {
    private var ticket = UUID()
    public init() {}
    public mutating func begin() -> UUID { ticket = UUID(); return ticket }
    public func owns(_ value: UUID) -> Bool { value == ticket }
}
