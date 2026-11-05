import Foundation

extension WorkspaceSession {
    /// Applies the Performance setting to this session's memory. A smaller budget or shorter lifetime evicts at once.
    public func applyCachePolicy(_ policy: CachePolicy) async {
        let budget = policy.budget()
        cacheBudget = budget
        decodedRevisions.resize(budget.decodedRevisions)
        archivedRevisions.resize(budget.archivedRevisions)
        releaseStatusMemory.resize(budget.releaseStatus)
        pricingCaches.resize(budget.pricingScreens)
        await appleReadCache.configure(limit: budget.appleReads, lifetime: budget.appleReadLifetime)
    }

    /// Frees what can be read or decoded again when macOS reports memory pressure. Saved work, drafts and reads in flight are kept.
    public func trimCachedMemory() async {
        decodedRevisions.removeAll(); archivedRevisions.removeAll(); releaseStatusMemory.removeAll()
        pricingCaches.trim(); libraryMetadataCache.removeAll()
        await appleReadCache.trim()
    }

    /// Clears what this session keeps in memory and the saved screen reads, as after Refresh on every screen at once.
    /// Saved work, drafts, history and choices are kept. Returns the new view-read epoch for the windows.
    @discardableResult public func clearCachedReads() async -> Int {
        await trimCachedMemory()
        clearViewReads()
        await invalidateAppleReads()
        return viewReadEpoch
    }

    /// Estimated bytes the session caches hold now.
    public func cachedMemoryBytes() async -> Int {
        let local = decodedRevisions.cost + archivedRevisions.cost + releaseStatusMemory.cost + pricingCaches.retainedBytes + libraryMetadataCache.cost
        return await local + appleReadCache.retainedBytes
    }

    /// How long a read from App Store Connect is reused, for screens that keep the next step warm.
    public var appleReadLifetime: Duration { cacheBudget.appleReadLifetime }
}
