import Foundation

/// How a screen reads App Store Connect. A Refresh reads the screen's own data again and replaces what was kept, without
/// dropping what other screens read; reading ahead waits behind what the open screen shows.
public enum ScreenReads {
    /// Runs `body` as a Refresh when `fresh`, otherwise inside any refresh already running.
    public static func reading<T>(fresh: Bool, isolation: isolated (any Actor)? = #isolation, _ body: () async throws -> T) async rethrows -> T {
        try await AppStoreReadCache.$refreshedSince.withValue(fresh ? .now : AppStoreReadCache.refreshedSince, operation: body, isolation: isolation)
    }
    /// Runs `body` as reads for the step the user is likely to open next.
    public static func ahead<T>(isolation: isolated (any Actor)? = #isolation, _ body: () async throws -> T) async rethrows -> T {
        try await AppleReadPriority.$current.withValue(.next, operation: body, isolation: isolation)
    }
}
