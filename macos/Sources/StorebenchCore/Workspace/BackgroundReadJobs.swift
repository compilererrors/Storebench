import Foundation

/// Lightweight reads use the same discovery, status stores and admission queue as their screens.
struct BackgroundReadJobs: Sendable {
    var releaseStates: @Sendable (WorkspaceSession) async -> Void = { await $0.refreshReleaseOverviews() }
    var catalogDue: @Sendable (WorkspaceSession) async throws -> Bool = { try await $0.appCatalogNeedsRefresh() }
    var catalog: @Sendable (WorkspaceSession) async throws -> AppCatalogRefresh = { try await $0.refreshAppCatalog(onlyIfNeeded: true) }
    var preparation: @Sendable (WorkspaceSession) async -> Void = { session in
        let limit = (try? await session.backgroundPreparation().appLimit) ?? 0
        guard limit > 0 else { return }
        await session.warmReleaseStatus(limit: min(4, limit))
    }
    var pricingIndexes: @Sendable (WorkspaceSession) async -> Void = { session in
        guard (try? await session.accounts().isEmpty) == false else { return }
        await session.preparePricingIndexes()
    }
}
