import Foundation

extension WorkspaceSession {
    /// Applies the Performance setting to this session's memory. A smaller budget or shorter lifetime evicts at once.
    public func applyCachePolicy(_ policy: CachePolicy) async {
        let budget = policy.budget()
        cacheBudget = budget
        decodedRevisions.resize(budget.decodedRevisions)
        parsedSources.resize(budget.draftSources)
        archivedRevisions.resize(budget.archivedRevisions)
        releaseStatusMemory.resize(budget.releaseStatus)
        pricingCaches.resize(budget.pricingScreens)
        libraryThumbnails.resize(budget.thumbnails)
        await appleReadCache.configure(limit: budget.appleReads, lifetime: budget.appleReadLifetime)
    }

    /// Applies the Performance setting's activity level to what this session prepares ahead.
    public func applyWorkPlan(_ plan: WorkPolicy.Plan) { workPlan = plan }

    /// Frees what can be read or decoded again when macOS reports memory pressure. Saved work, drafts and reads in flight are kept.
    public func trimCachedMemory() async {
        decodedRevisions.removeAll(); archivedRevisions.removeAll(); releaseStatusMemory.removeAll()
        revisionLists.removeAll(); archivedLists.removeAll(); committedImports.removeAll(); parsedSources.removeAll()
        pricingCaches.trim(); libraryMetadataCache.removeAll(); libraryThumbnails.removeAll(); libraryThumbnailRefreshed.removeAll(); publishHistoryMemo.removeAll()
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
        let local = decodedRevisions.cost + parsedSources.cost + archivedRevisions.cost + releaseStatusMemory.cost + pricingCaches.retainedBytes + libraryMetadataCache.cost + libraryThumbnails.cost + publishHistoryMemo.cost
        return await local + appleReadCache.retainedBytes
    }

    /// How long a read from App Store Connect is reused, for screens that keep the next step warm.
    public var appleReadLifetime: Duration { cacheBudget.appleReadLifetime }
}
