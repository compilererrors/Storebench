import Foundation
import CryptoKit
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct RecoveryGuidanceTests {
    init() throws { _ = try TestIsolation.require() }
    func fixture() throws -> (JSONText, JSONText, HelpCatalog, RecoveryGuidance) {
        let root = try TestIsolation.require().appendingPathComponent("native-fixtures")
        let value = try JSONText.parse(Data(contentsOf: root.appendingPathComponent("recovery-guidance.json")))
        let helpValue = try JSONText.parse(Data(contentsOf: root.appendingPathComponent("help-catalog.json"))), help = try HelpCatalog(data: #require(helpValue["catalog"]).data)
        let catalog = try #require(value["catalog"])
        return (value, catalog, help, try RecoveryGuidance(data: catalog.data, help: help))
    }
    @Test func everyGuidanceConnectionAndFinancialOverrideMatchesPrimary() throws {
        let (value, _, _, catalog) = try fixture()
        #expect(!catalog.entries.isEmpty)
        for row in WorkspaceSession.items(value["scenarios"]) {
            let scope: RecoveryGuidance.Scope?
            if let context = row["scope"], context != .null { scope = try RecoveryGuidance.Scope(accountId: #require(context["accountId"]?.text), appId: #require(context["appId"]?.text)) }
            else { scope = nil }
            let module = row["module"]?.text.flatMap(RecoveryGuidance.Module.init(rawValue:))
            let actual = catalog.entry(row["code"]?.text, module: module)?.presentation(scope: scope) ?? .null
            #expect(actual == row["expected"], "Synthetic recovery \(row["code"]?.text ?? "unknown")")
        }
        for row in WorkspaceSession.items(value["connections"]) { #expect((catalog.connection(row["status"]?.text)?.presentation() ?? .null) == row["expected"]) }
        #expect(catalog.entry("SB-REPORT-UNAVAILABLE")?.neutral == true)
        #expect(catalog.entry("SB-REPORT-UNAVAILABLE", module: .finance)?.message?.contains("not zero proceeds") == true)
        #expect(catalog.message("SB-REPORT-UNAVAILABLE", module: .finance) == catalog.entry("SB-REPORT-UNAVAILABLE", module: .finance)?.message)
        #expect(catalog.message("SB-REPORT-ACCESS", module: .finance) == ReportingMessages.message("SB-FINANCE-ACCESS"))
        #expect(catalog.message("SB-REPORT-ACCESS") == ReportingMessages.message("SB-REPORT-ACCESS"))
        #expect(catalog.message("SB-REPORT-UNAVAILABLE") == ReportingMessages.message("SB-REPORT-UNAVAILABLE"))
        #expect(catalog.entry("SB-ANALYTICS-NO-INSTANCES")?.target.analyticsOngoing == false)
        #expect(catalog.entry("SB-ANALYTICS-SETUP")?.target.analyticsOngoing == true)
    }
    @Test func scopedActionsKeepForeignAppsAndBusyEditorsProtected() throws {
        let (_, _, _, catalog) = try fixture()
        let current = try RecoveryGuidance.Scope(accountId: "synthetic-recovery-account", appId: "1000000001"), otherApp = try RecoveryGuidance.Scope(accountId: current.accountId, appId: "1000000002"), otherAccount = try RecoveryGuidance.Scope(accountId: "synthetic-other-account", appId: current.appId)
        for entry in catalog.entries.values where entry.target.requiresApp {
            #expect(entry.target.resolved(scope: nil) == nil)
            let action = try #require(entry.target.resolved(scope: current))
            #expect(action.allowed(current: current, decision: .ready))
            #expect(!action.allowed(current: otherApp, decision: .ready) && !action.allowed(current: otherAccount, decision: .ready))
            #expect(!action.allowed(current: current, decision: .confirmDiscard))
            #expect(action.allowed(current: current, decision: .confirmDiscard, discardConfirmed: true))
            #expect(!action.allowed(current: current, decision: .wait, discardConfirmed: true))
        }
        #expect(throws: RecoveryGuidance.Failure.self) { try RecoveryGuidance.Scope(accountId: "synthetic/account", appId: current.appId) }
        #expect(throws: RecoveryGuidance.Failure.self) { try RecoveryGuidance.Scope(accountId: current.accountId, appId: "synthetic-app") }
        #expect(catalog.entry("SB-REPORTER-SETUP")?.target.opensConnection == true)
        #expect(catalog.entry("SB-SYNC-FISCAL-PERIOD")?.target.focus == "finance-download-period")
        #expect(catalog.entry("SB-APPLE-AUTH")?.target.accountRecovery == "auth")
    }
    @Test func malformedDestinationsCannotOpenArbitraryFilesOrUnrelatedViews() throws {
        let (_, raw, help, _) = try fixture(), code = "SB-APPLE-AUTH", first = try #require(raw["guidance"]?[code])
        let changes: [(String, JSONText)] = [("path", .string("file:///synthetic")), ("path", .string("https://synthetic.example.test/")), ("path", .string("/unknown")), ("global", .bool(false)), ("opensNewTab", .bool(true)), ("opensConnection", .bool(true)), ("focus", .string("unrelated-field")), ("kind", .number(1)), ("guideHref", .string("/settings/help#unknown")), ("status", .string("Synthetic\nstatus")), ("message", .null)]
        for (field, value) in changes {
            let changed = raw.setting("guidance", try #require(raw["guidance"]).setting(code, first.setting(field, value)))
            #expect(throws: RecoveryGuidance.Failure.self) { try RecoveryGuidance(data: changed.data, help: help) }
        }
    }
    @Test func libraryRecoveryKeepsTheExactAppAndAllSetupFocusWithoutDownloadingOrPublishing() throws {
        let (_, _, _, catalog) = try fixture()
        let scope = try RecoveryGuidance.Scope(accountId: "synthetic-recovery-account", appId: "1000000001")
        let foreign = try RecoveryGuidance.Scope(accountId: scope.accountId, appId: "1000000002")
        for entry in catalog.entries.values where entry.target.requiresApp {
            let action = try #require(entry.target.resolved(scope: scope))
            let destination = try ConnectedApps.Destination(scope: scope, recovery: action)
            #expect(destination.scope == scope && destination.section == entry.target.section)
            #expect(destination.recoveryAction == action)
            #expect(destination.recoveryAction?.target.anchor == entry.target.anchor)
            #expect(destination.recoveryAction?.target.focus == entry.target.focus)
            #expect(destination.recoveryAction?.target.opensConnection == entry.target.opensConnection)
            #expect(destination.recoveryAction?.target.analyticsOngoing == entry.target.analyticsOngoing)
            #expect(throws: ConnectedApps.Failure.self) { try ConnectedApps.Destination(scope: foreign, recovery: action) }
        }
        let help = try RecoveryGuidance.Target.help("analytics").resolved(scope: scope)
        #expect(throws: ConnectedApps.Failure.self) { try ConnectedApps.Destination(scope: scope, recovery: #require(help)) }
    }
    @Test func copyDetailsAndFailureFallbackContainOnlyTheFixedPublicIssue() throws {
        let (value, _, _, _) = try fixture()
        for row in WorkspaceSession.items(value["details"]) {
            let code = row["code"]?.text ?? "synthetic unknown"
            #expect(ReportingMessages.supportAvailable(row["code"]?.text) == (row["support"] == .bool(true)))
            #expect(ReportingMessages.issueDetails(code) == row["expected"]?.text)
            var copy = IssueCopy(code: code)
            #expect(copy.code == row["safe"]?.text)
            #expect(copy.begin(.details) == row["expected"]?.text)
            #expect(copy.begin(.code) == nil)
            copy.finish(.code, success: true); #expect(copy.pending == .details && copy.copied == nil)
            copy.finish(.details, success: false); #expect(copy.fallback == row["expected"]?.text && copy.status.isEmpty)
            copy.dismissFallback(); #expect(copy.fallback == nil)
            #expect(copy.begin(.code) == row["safe"]?.text)
            copy.finish(.code, success: true); #expect(copy.status == "Error code copied" && copy.fallback == nil)
        }
    }
    @Test func boundedAppleAgreementCodesMatchPrimaryWithoutRetainingResponseText() throws {
        let (value, _, _, _) = try fixture()
        for row in WorkspaceSession.items(value["apple"]) {
            guard case .number(let number)? = row["status"] else { throw RecoveryGuidance.Failure.invalid }
            let status = Int(number), body = Data(try #require(row["body"]?.text).utf8)
            let failure = AppStoreConnectClient.failure(status: status, data: body, contentType: row["contentType"]?.text)
            let expected = row["expected"]?.text
            #expect(failure == (expected == "apple_agreement" ? .agreement : .status(status)))
        }
        #expect(AccountFailure.classify(AppStoreConnectClient.Failure.agreement) as? AccountFailure == .agreement)
        #expect(AccountFailure.agreement.message.contains("test the connection again"))
        #expect(!AccountFailure.agreement.message.contains("retry the download"))
        #expect(!WorkspaceSession.publishingError(AppStoreConnectClient.Failure.agreement).contains("retry the download"))
        #expect(ImportFailure(AppStoreConnectClient.Failure.agreement) == .agreement)
        #expect(ImportFailure(AccountFailure.agreement) == .agreement)
        #expect(SalesDownloadJob.failureCode(AppStoreConnectClient.Failure.agreement) == "SB-APPLE-AGREEMENT")
        #expect(FinancialDownloadJob.failureCode(AppStoreConnectClient.Failure.agreement) == "SB-APPLE-AGREEMENT")
        #expect(AnalyticsDownloadJob.failureCode(AppStoreConnectClient.Failure.agreement) == "SB-APPLE-AGREEMENT")
        #expect(ReviewsDownloadJob.failureCode(AppStoreConnectClient.Failure.agreement) == "SB-APPLE-AGREEMENT")
    }
    @Test func guardedPageAndReportTransportPreserveAgreementFailure() async throws {
        let host = "recovery-agreement.appstoreconnect.test", account = Account(id: "synthetic-recovery-account", name: "Synthetic Recovery", keyId: "SAMPLE0001", keyType: "team", issuerId: "00000000-0000-4000-8000-000000000003", appIds: ["1000000001"], appNames: nil)
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubProtocol.self]
        let client = AppStoreConnectClient(token: try AppleToken(account: account, privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation), origin: URL(string: "https://\(host)")!, configuration: configuration)
        let body = JSONText.object([("errors", .array([.object([("code", .string("FORBIDDEN.REQUIRED_AGREEMENTS_MISSING_OR_EXPIRED")), ("detail", .string("Synthetic upstream detail"))])]))]).data
        StubProtocol.handle(host) { _ in (403, ["Content-Type": "application/json"], body) }
        await #expect(throws: AppStoreConnectClient.Failure.agreement) { try await client.get("/v1/apps/1000000001") }
        await #expect(throws: AppStoreConnectClient.Failure.agreement) { try await client.download("/v1/salesReports") }
        #expect(StubProtocol.requests(host).count == 2)
    }
    @Test func typedFailuresSupplyFixedActionsAndCancellationSuppliesNone() {
        #expect(RecoveryIssue.apple(AccountFailure.auth) == "SB-APPLE-AUTH")
        #expect(RecoveryIssue.apple(AccountFailure.agreement) == "SB-APPLE-AGREEMENT")
        #expect(RecoveryIssue.apple(SessionFailure.closed) == "SB-SESSION-EXPIRED")
        #expect(RecoveryIssue.apple(AccountFailure.invalid) == nil)
        #expect(RecoveryIssue.reporter(ReporterSetupFailure.changed) == "SB-REPORTER-CHANGED")
        #expect(RecoveryIssue.reporter(ReporterSetupFailure.keychain) == "SB-REPORTER-KEYCHAIN")
        #expect(RecoveryIssue.reporter(ReporterClient.Failure.expiredToken) == "SB-REPORTER-KEYCHAIN")
        #expect(RecoveryIssue.reporter(ReporterSetupFailure.busy) == "SB-REPORTER-BUSY")
        #expect(RecoveryIssue.finance(FinanceFailure.period) == "SB-FINANCE-PERIOD")
        #expect(RecoveryIssue.sales(SalesFileFailure.format) == "SB-REPORT-FORMAT")
        #expect(RecoveryIssue.analytics(AnalyticsFileFailure.changedFiles) == "SB-ANALYTICS-STALE")
        #expect(RecoveryIssue.reviews(ReviewsFileFailure.changedFiles) == "SB-REVIEWS-STALE")
        #expect(RecoveryIssue.reviews(ReviewsFileFailure.size) == "SB-REVIEWS-LIMIT")
        let keywords: [(KeywordFailure, String)] = [(.format, "SB-KEYWORDS-FORMAT"), (.scope, "SB-KEYWORDS-SCOPE"), (.duplicate, "SB-KEYWORDS-DUPLICATE"), (.stale, "SB-KEYWORDS-STALE"), (.storage, "SB-KEYWORDS-STORAGE"), (.limit, "SB-KEYWORDS-LIMIT")]
        for (failure, code) in keywords { #expect(RecoveryIssue.keywords(failure) == code) }
        for action in [RecoveryIssue.reporter, RecoveryIssue.sales, RecoveryIssue.finance, RecoveryIssue.analytics, RecoveryIssue.reviews, RecoveryIssue.keywords] { #expect(action(CancellationError()) == nil) }
    }
}
