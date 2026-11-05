import Foundation

/// Saves country price drafts for one app. A permanent draft replaces the country's earlier permanent draft; temporary periods may not overlap.
/// The write runs inside the session's store access, so the session keeps its single database connection and its lifetime and access checks.
struct SaveCountryDrafts {
    let accountId, appId: String
    let drafts: [PricingDraft]

    /// Validates the amounts and dates before any lock is taken.
    init(accountId: String, appId: String, amounts: [(territory: String, currency: String, amount: String)], startDate: String?, endDate: String?, now: Date) throws {
        guard !amounts.isEmpty, amounts.count <= 200, Set(amounts.map(\.territory)).count == amounts.count else { throw PricingFailure.selection }
        guard (startDate == nil) == (endDate == nil) else { throw PricingFailure.invalid("Temporary prices need valid start and end dates.") }
        if let startDate, let endDate { guard ReportTables.validDate(startDate), ReportTables.validDate(endDate), startDate <= endDate else { throw PricingFailure.invalid("Temporary prices need valid start and end dates.") } }
        for item in amounts where item.amount.range(of: #"^0(?:\.0{1,4})?$"#, options: .regularExpression) == nil { _ = try PricingMath.desired(item.amount) }
        let created = CustomerReview.isoString(now)
        self.accountId = accountId; self.appId = appId
        drafts = amounts.map { PricingDraft(id: UUID().uuidString.lowercased(), accountId: accountId, appId: appId, territory: $0.territory, currency: $0.currency, amount: $0.amount, startDate: startDate, endDate: endDate, createdAt: created) }
    }

    /// Rechecks protection while it is held, then merges and writes the drafts against the revision that was read.
    func write(to store: EncryptedDocumentStore) throws {
        try PricingLock.holding([.protection, .drafts], in: store) {
            let protected = WorkspaceSession.items(try PricingState.read(store, "price_protection").value?["locks"])
            if protected.contains(where: { lock in lock["accountId"]?.text == accountId && lock["appId"]?.text == appId && lock["priceProduct"]?.text == "paid-app" && drafts.contains { $0.territory == lock["territory"]?.text } }) {
                throw PricingFailure.selection
            }
            let (document, value) = try PricingState.read(store, "pricing_drafts")
            let kept = try merged(into: WorkspaceSession.items(value?["drafts"]))
            try PricingState.replace(store, "pricing_drafts", previous: document, value: .object([("schemaVersion", .number(1)), ("drafts", .array(kept + drafts.map(\.json)))]))
        }
    }

    /// The saved drafts that stay: unreadable and other apps' entries are kept as saved; temporary periods may not overlap.
    private func merged(into saved: [JSONText]) throws -> [JSONText] {
        let replaced = Set(drafts.filter { $0.startDate == nil }.map { "\($0.accountId):\($0.appId):\($0.territory)" })
        let kept = saved.filter { item in item["startDate"]?.text != nil || !replaced.contains("\(item["accountId"]?.text ?? ""):\(item["appId"]?.text ?? ""):\(item["territory"]?.text ?? "")") }
        var periods: [String: [(String, String)]] = [:]
        for draft in kept.compactMap(PricingDraft.init) + drafts { if let start = draft.startDate, let end = draft.endDate {
            let key = "\(draft.accountId):\(draft.appId):\(draft.territory)"
            if periods[key, default: []].contains(where: { $0.0 <= end && start <= $0.1 }) { throw PricingFailure.invalid("Temporary price dates overlap for a country.") }
            periods[key, default: []].append((start, end))
        } }
        guard kept.count + drafts.count <= 2000 else { throw PricingFailure.invalid("Too many price drafts.") }
        return kept
    }
}
