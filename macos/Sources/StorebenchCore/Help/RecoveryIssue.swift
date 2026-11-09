import Foundation

/// Select fixed public codes from typed failures; arbitrary upstream messages never enter recovery UI.
public enum RecoveryIssue {
    public static func apple(_ error: Error) -> String? {
        switch error {
        case is PasswordVaultStorage.Failure: "SB-SESSION-EXPIRED"
        case AppStoreConnectClient.Failure.status(401), AccountFailure.auth: "SB-APPLE-AUTH"
        case AppStoreConnectClient.Failure.status(403), AccountFailure.access, AccountFailure.empty: "SB-APPLE-ACCESS"
        case AppStoreConnectClient.Failure.agreement, AccountFailure.agreement: "SB-APPLE-AGREEMENT"
        case AccountFailure.keychain, ReviewsFailure.noKey, is CredentialAccessFailure, is CredentialVault.Failure, is VaultWriter.Failure: "SB-APPLE-KEYCHAIN"
        case is SessionFailure: "SB-SESSION-EXPIRED"
        default: nil
        }
    }
    public static func reporter(_ error: Error) -> String? {
        if let code = apple(error) { return code }
        if cancelled(error) { return nil }
        switch error {
        case ReporterClient.Failure.invalidToken: return nil
        case ReporterSetupFailure.changed: return "SB-REPORTER-CHANGED"
        case ReporterSetupFailure.keychain: return "SB-REPORTER-KEYCHAIN"
        case ReporterClient.Failure.expiredToken: return "SB-REPORTER-SETUP"
        case ReporterSetupFailure.storage: return "SB-REPORTER-CONNECTION"
        case ReporterSetupFailure.busy, is FileMutex.Failure: return "SB-REPORTER-BUSY"
        default: return "SB-REPORTER-SETUP"
        }
    }
    public static func sales(_ error: Error) -> String? {
        if let code = apple(error) { return code }
        if cancelled(error) { return nil }
        if error as? SalesFileFailure == .format { return "SB-REPORT-FORMAT" }
        return SalesDownloadJob.failureCode(error)
    }
    public static func finance(_ error: Error) -> String? {
        if let code = apple(error) { return code }
        return cancelled(error) ? nil : FinancialDownloadJob.failureCode(error)
    }
    public static func analytics(_ error: Error) -> String? {
        if let code = apple(error) { return code }
        if cancelled(error) { return nil }
        if error as? AnalyticsFileFailure == .changedFiles { return "SB-ANALYTICS-STALE" }
        return AnalyticsDownloadJob.failureCode(error)
    }
    public static func reviews(_ error: Error) -> String? {
        if let code = apple(error) { return code }
        if cancelled(error) { return nil }
        switch error {
        case ReviewsFileFailure.changedFiles: return "SB-REVIEWS-STALE"
        case ReviewsFileFailure.missing: return "SB-REVIEWS-STORAGE"
        case ReviewsFileFailure.size: return "SB-REVIEWS-LIMIT"
        default: return ReviewsDownloadJob.failureCode(error)
        }
    }
    public static func keywords(_ error: Error) -> String? {
        if let code = apple(error) { return code }
        if cancelled(error) { return nil }
        switch error {
        case KeywordFailure.format: return "SB-KEYWORDS-FORMAT"
        case KeywordFailure.scope: return "SB-KEYWORDS-SCOPE"
        case KeywordFailure.duplicate: return "SB-KEYWORDS-DUPLICATE"
        case KeywordFailure.stale: return "SB-KEYWORDS-STALE"
        case KeywordFailure.limit: return "SB-KEYWORDS-LIMIT"
        default: return "SB-KEYWORDS-STORAGE"
        }
    }
    private static func cancelled(_ error: Error) -> Bool { error is CancellationError || (error as? URLError)?.code == .cancelled }
}
