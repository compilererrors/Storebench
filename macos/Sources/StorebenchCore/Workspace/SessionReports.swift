import Foundation

/// Report work admitted under the open session's lifetime.
extension WorkspaceSession {
    /// A report's lease includes terminal progress and ownership release, even after cancellation.
    func ownedReport<Result: Sendable>(_ operation: @escaping @Sendable () async throws -> Result) throws -> Task<Result, Error> {
        try requireSessionAccess()
        let lease = try lifetime.admit(.report)
        return Task {
            defer { lease.finish() }
            return try await SessionContext.$lease.withValue(lease) { try await operation() }
        }
    }
}
