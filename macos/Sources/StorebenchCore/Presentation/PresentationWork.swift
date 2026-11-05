import Foundation

/// A view owns temporary observers and tasks for one presentation generation.
/// Retirement is immediate and idempotent; late registrations are disposed rather than retained.
@MainActor public final class PresentationWork {
    private var disposals: [() -> Void] = []
    public private(set) var generation = UUID()
    public private(set) var active = false
    public var resourceCount: Int { disposals.count }
    public init() {}
    isolated deinit { end() }
    @discardableResult public func begin() -> UUID {
        end(); generation = UUID(); active = true; return generation
    }
    public func accepts(_ ticket: UUID) -> Bool { active && ticket == generation }
    @discardableResult public func own(_ disposal: @escaping () -> Void, ticket: UUID) -> Bool {
        guard accepts(ticket), disposals.count < 16 else { disposal(); return false }
        disposals.append(disposal); return true
    }
    public func end() {
        active = false
        let pending = disposals; disposals.removeAll(keepingCapacity: false)
        for dispose in pending.reversed() { dispose() }
    }
}
