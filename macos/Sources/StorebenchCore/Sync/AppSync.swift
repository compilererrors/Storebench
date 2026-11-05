import Foundation

/// The sync order. Each source uses its own download, lock and validation; nothing is sent to App Store Connect.
public enum AppSync {
    public static let sources = [("material", "Apple versions & material"), ("pricing", "Prices"), ("sales", "Sales & proceeds"), ("downloads", "Analytics · downloads"),
                                 ("engagement", "Analytics · discovery & engagement"), ("finance", "Financial reports"), ("reviews", "Customer reviews")]
    public static let executionOrder = ["pricing", "sales", "downloads", "engagement", "material", "finance", "reviews"]
    public static func pending() -> [SyncItem] { sources.map { SyncItem(key: $0.0, state: .pending, detail: "Not checked in this sync yet.") } }

    public static func salesStatus(_ result: SalesSyncResult) -> (state: SyncItem.State, detail: String) {
        var parts = ["\(result.changes.added) new, \(result.changes.updated) updated, \(result.changes.unchanged) unchanged."]
        if !result.noSalesDays.isEmpty { parts.append("\(result.noSalesDays.count) days without sales.") }
        if !result.unavailableDays.isEmpty { parts.append("\(result.unavailableDays.count) days not yet available from Apple.") }
        if !result.noAppRowsDays.isEmpty { parts.append("\(result.noAppRowsDays.count) reports could not be attributed to this app. Import app information to match in-app purchases. Missing reports stay unknown.") }
        return (result.unavailableDays.isEmpty && result.noAppRowsDays.isEmpty ? .synced : .partial, parts.joined(separator: " "))
    }
    public static func analyticsStatus(_ result: AnalyticsSyncResult, processingDays: Int? = nil) -> (state: SyncItem.State, detail: String) {
        let unavailable = max(result.unavailableDays.count, (processingDays ?? result.instances) - result.instances)
        var parts = ["\(result.instances) report instances checked · \(result.changes.added) added · \(result.changes.replaced) replaced · \(result.changes.unchanged + result.changes.older) retained."]
        if unavailable > 0 { parts.append("\(unavailable) requested processing days not available from Apple.") }
        if result.noAppInstances > 0 { parts.append("\(result.noAppInstances) instances without this app's rows.") }
        parts.append("Missing activity is not zero.")
        return (unavailable == 0 && result.noAppInstances == 0 ? .synced : .partial, parts.joined(separator: " "))
    }

    public static func financialStatus(_ result: FinancialDownload) -> (state: SyncItem.State, detail: String) {
        let waiting = result.changes.contains(where: { $0.action != "unchanged" })
        let state: SyncItem.State = waiting ? .attention : result.unavailable.isEmpty && result.noApp.isEmpty ? .synced : .partial
        var parts = [waiting ? "Downloaded. Open Financial Reports to review the fiscal dates and changes, then save the reports." :
            result.reports.isEmpty ? "No attributable reports were added. Existing reports are kept." : "The downloaded financial reports match saved history."]
        if !result.unavailable.isEmpty { parts.append("\(result.unavailable.count) fiscal periods remain unavailable and unknown.") }
        if !result.noApp.isEmpty { parts.append("\(result.noApp.count) fiscal periods could not be attributed to this app and remain unknown.") }
        return (state, parts.joined(separator: " "))
    }

    /// What went wrong for one source, worded like that source's own view. Setup and availability are attention, not failure.
    static func outcome(_ error: Error, key: String) -> (SyncItem.State, String) {
        switch error {
        case AppStoreConnectClient.Failure.status(let code) where code == 401 || code == 403:
            return (.attention, key == "sales" || key == "finance" ? "Apple did not accept this API key for these reports. Sales and finance reports need a Team API key or Reporter." : "Apple did not allow this API key to read this data. In App Store Connect, check the key's role under Users and Access → Integrations and your app access under Users and Access → People.")
        case ReporterClient.Failure.expiredToken: return (.attention, "The Reporter access token has expired. In App Store Connect, open Trends → Sales and Trends Reports, click the question mark (?) beside About Reports and choose Generate Reporter Token, then reconnect Reporter.")
        case ReviewsFailure.noKey: return (.attention, "This account's API key is not in Keychain. Reconnect it in the Storebench app.")
        case let failure as SalesFailure: return (.attention, failure.message)
        case let failure as AnalyticsFailure: return (.attention, failure.message)
        case let failure as FinanceFailure: return (.attention, failure.message)
        case let failure as PricingFailure: return (.failed, failure.message)
        case let failure as ImportFailure: return (failure == .busy ? .attention : .failed, failure.message)
        default: return (.failed, "This source could not be synced. Saved data is kept.")
        }
    }
}
