import Foundation

/// Decides when a view that repeats a read of saved state has to read again.
/// A read is due the first time, when the session's saved state changed, while something shown is still working, and when
/// the last read is older than `staleAfter`, so states that follow the clock or another process still arrive.
public struct SavedStateWatch: Sendable {
    public static let staleAfter: Duration = .seconds(30)
    private var token: String?
    private var readAt: ContinuousClock.Instant?
    public init() {}

    /// `current` is the session's token now, or nil when it could not be read; an unknown token always reads.
    public func due(_ current: String?, working: Bool, now: ContinuousClock.Instant = .now, staleAfter: Duration = SavedStateWatch.staleAfter) -> Bool {
        guard !working, let current, let token, let readAt else { return true }
        return current != token || now - readAt >= staleAfter
    }

    /// Notes a read that started when the session's token was `current`. A change during the read leaves the token older than
    /// the session's, so the next check reads again.
    public mutating func read(_ current: String?, at now: ContinuousClock.Instant = .now) { token = current; readAt = now }
}
