import Foundation

/// What Pricing does for one app: read saved prices, refresh them from Apple, protect prices and keep country drafts.
/// Saved state goes through a `PricingStore` and Apple through the client it is given, so callers never handle the database,
/// the Apple client or Apple's batches. Nothing here changes App Store Connect.
public struct PricingService: Sendable {
    let store: any PricingStore, account: Account, appId: String
    let client: @Sendable (Account) async throws -> AppStoreConnectClient

    public init(session: WorkspaceSession, account: Account, appId: String) {
        self.init(store: session, account: account, appId: appId) { try await session.client(for: $0) }
    }

    init(store: any PricingStore, account: Account, appId: String, client: @escaping @Sendable (Account) async throws -> AppStoreConnectClient) {
        self.store = store; self.account = account; self.appId = appId; self.client = client
    }

    public func screen() async throws -> PricingScreen {
        try await store.pricingScreen(account: account, appId: appId, today: PeriodDates.text(Date()))
    }

    /// Reads Apple's price schedule and saves it; Apple refusing the key is `PricingFailure.access`.
    public func refresh() async throws {
        do { _ = try await store.refreshPricing(account: account, appId: appId, client: try await client(account), now: Date()) }
        catch AppStoreConnectClient.Failure.status(let code) where code == 401 || code == 403 { throw PricingFailure.access }
    }

    /// Keeps today's Apple price for these countries in `basis`, the schedule the person reviewed. Returns how many were protected.
    public func protect(_ territories: [String], basis: [PriceRow], today: String) async throws -> Int {
        let rows = PricingMath.current(basis, today: today)
        let prices = territories.compactMap { code in rows[code].map { (territory: code, customerPrice: $0.customerPrice, currency: $0.currency) } }
        try await store.protectPrices(accountId: account.id, appId: appId, prices: prices, now: Date())
        return prices.count
    }

    public func allowChanges(_ territory: String) async throws {
        try await store.unprotectPrice(accountId: account.id, appId: appId, territory: territory)
    }

    public func removeDraft(_ draft: PricingDraft) async throws {
        try await store.removePricingDraft(accountId: account.id, appId: appId, id: draft.id)
    }

    /// Checks the reviewed prices, reads Apple's price points before any lock is taken, then saves through the store's locked draft write.
    public func saveDrafts(_ request: CountryDraftRequest, basis: [PriceRow], today: String) async throws -> [PricingDraft] {
        let plan = CountryDraftPlan(basis: basis, today: today)
        try plan.check(request)
        var points: [PricePoint] = []
        if plan.needsPricePoints(request) {
            let read = try await PricePointCatalog.readAll(appId: appId, territories: request.territories, client: try await client(account))
            guard read.failed.isEmpty else { throw PricingFailure.points }
            points = read.points
        }
        let amounts = try plan.amounts(request, points: points)
        try Task.checkCancellation()
        return try await store.saveCountryDrafts(accountId: account.id, appId: appId, amounts: amounts, startDate: request.period?.start, endDate: request.period?.end, now: Date())
    }
}
