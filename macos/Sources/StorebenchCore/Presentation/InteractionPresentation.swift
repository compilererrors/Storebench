import Foundation

public struct TextSurfaceResizeSession: Sendable {
    public private(set) var ticket: UUID?
    public private(set) var value = 140.0
    private var start = 140.0
    private var pending: Double?
    public init() {}
    @discardableResult public mutating func begin(height: Double) -> UUID {
        let next = UUID(); ticket = next
        start = TextSurfacePresentation.height(height); value = start; pending = nil
        return next
    }
    public mutating func queue(translation: Double, ticket: UUID) {
        guard self.ticket == ticket, translation.isFinite else { return }
        let next = TextSurfacePresentation.resized(start: start, translation: translation).rounded()
        pending = next == value ? nil : next
    }
    public mutating func take(ticket: UUID) -> Double? {
        guard self.ticket == ticket, let next = pending else { return nil }
        pending = nil; value = next; return next
    }
    public mutating func finish(translation: Double, ticket: UUID) -> Double? {
        guard self.ticket == ticket else { return nil }
        queue(translation: translation, ticket: ticket)
        let result = take(ticket: ticket); cancel(); return result
    }
    public mutating func cancel() { ticket = nil; pending = nil }
}

/// One result per view, keyed by every input that changes its measurement.
public struct LayoutMeasurementCache<Key: Equatable, Value> {
    private var stored: (Key, Value)?
    public init() {}
    public mutating func resolve(_ key: Key, measure: () -> Value) -> Value {
        if let stored, stored.0 == key { return stored.1 }
        let value = measure(); stored = (key, value); return value
    }
    /// Placement consumes the preceding measurement; another placement must measure again.
    public mutating func consume(_ key: Key) -> Value? {
        defer { stored = nil }
        return stored?.0 == key ? stored?.1 : nil
    }
    public mutating func invalidate() { stored = nil }
}
