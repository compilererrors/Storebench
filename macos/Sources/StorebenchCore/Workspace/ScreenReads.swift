import Foundation

/// Screens show local results first, then check App Store Connect. Concurrent screens share requests already in flight;
/// an explicit Refresh replaces earlier requests. Reading ahead reuses the cache and waits behind the open screen.
public enum ScreenReads {
    /// One freshness boundary for the whole load, including nested reads and pagination. Speculative reads keep the cache's
    /// configured lifetime; visible screens check Apple even when their last response is still cached.
    public static func reading<T>(fresh: Bool, isolation: isolated (any Actor)? = #isolation, _ body: () async throws -> T) async rethrows -> T {
        let revalidation = fresh ? nil : AppStoreReadCache.revalidatedSince ?? (AppleReadPriority.current == .visible ? .now : nil)
        return try await AppStoreReadCache.$revalidatedSince.withValue(revalidation) {
            try await AppStoreReadCache.$refreshedSince.withValue(fresh ? .now : AppStoreReadCache.refreshedSince, operation: body, isolation: isolation)
        }
    }
    /// Runs `body` as reads for the step the user is likely to open next.
    public static func ahead<T>(isolation: isolated (any Actor)? = #isolation, _ body: () async throws -> T) async rethrows -> T {
        try await AppleReadPriority.$current.withValue(.next, operation: body, isolation: isolation)
    }
}
