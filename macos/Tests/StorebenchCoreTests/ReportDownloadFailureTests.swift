import Foundation
import Testing
@testable import StorebenchCore

struct ReportDownloadFailureTests {
    init() throws { _ = try TestIsolation.require() }

    @Test func failuresHaveSpecificPublicReasonsWithoutUpstreamDiagnostics() {
        let vectors: [(Error, String, String)] = [
            (URLError(.timedOut), "SB-REPORT-NETWORK", "SB-FINANCE-NETWORK"),
            (AppStoreConnectClient.Failure.status(429), "SB-REPORT-SERVICE", "SB-FINANCE-SERVICE"),
            (AppStoreConnectClient.Failure.status(503), "SB-REPORT-SERVICE", "SB-FINANCE-SERVICE"),
            (ReporterClient.Failure.serviceUnavailable, "SB-REPORT-SERVICE", "SB-FINANCE-SERVICE"),
            (ReporterClient.Failure.access, "SB-REPORT-ACCESS", "SB-FINANCE-ACCESS"),
            (ReporterClient.Failure.expiredToken, "SB-REPORTER-KEYCHAIN", "SB-REPORTER-KEYCHAIN"),
            (ReporterClient.Failure.wrongAccount, "SB-REPORTER-CHANGED", "SB-REPORTER-CHANGED"),
            (ReporterClient.Failure.unsupported, "SB-REPORTER-RESPONSE", "SB-FINANCE-RESPONSE"),
            (ReporterClient.Failure.size, "SB-REPORT-SIZE", "SB-REPORT-SIZE")
        ]
        for (error, sales, finance) in vectors {
            #expect(SalesDownloadJob.failureCode(error) == sales)
            #expect(FinancialDownloadJob.failureCode(error) == finance)
            #expect(RecoveryIssue.sales(error) == sales && RecoveryIssue.finance(error) == finance)
            #expect(ReportingMessages.normalized(sales) == sales && ReportingMessages.normalized(finance) == finance)
        }
        let upstream = NSError(domain: "Synthetic untrusted diagnostic", code: 999, userInfo: [NSLocalizedDescriptionKey: "Synthetic upstream detail"])
        #expect(SalesDownloadJob.failureCode(upstream) == "SB-REPORT-DOWNLOAD")
        #expect(FinancialDownloadJob.failureCode(upstream) == "SB-FINANCE-DOWNLOAD")
        #expect(!ReportingMessages.message(FinancialDownloadJob.failureCode(upstream)).contains("Synthetic upstream"))
    }

    @Test(arguments: [1, 123, 124, 125, 200, 214, 215, 216]) func robotErrorsKeepTheirMeaning(_ code: Int) throws {
        let expected: ReporterClient.Failure = code == 1 ? .serviceUnavailable : code < 200 ? .expiredToken : .wrongAccount
        #expect(throws: expected) { try ReporterClient.xml(.init(gzip: false, ok: true, body: Data("<Error><Code>\(code)</Code><Message>Synthetic upstream detail</Message></Error>".utf8)), root: "Output") }
    }

    @Test(arguments: [401, 403, 429, 503]) func httpErrorsHaveAnActionableReason(_ status: Int) async throws {
        let host = "report-download-\(status).reporting.test", configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        StubProtocol.handle(host) { _ in (status, ["Content-Type": "text/plain"], Data("Synthetic upstream detail".utf8)) }
        let client = try ReporterClient(token: "synthetic-reporting-token", origin: URL(string: "https://\(host)")!, configuration: configuration)
        let expected: ReporterClient.Failure = status == 401 ? .expiredToken : status == 403 ? .access : .serviceUnavailable
        await #expect(throws: expected) { try await client.financialReport(account: "1234567", vendor: "80000001", region: "ZZ", year: 2026, period: 4) }
    }

    @Test func financialTransportUsesItsOwnBoundedReportLimit() async throws {
        let host = "financial-report-size.reporting.test", configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let bytes = Data([0x1f, 0x8b]) + Data(repeating: 1, count: 4_000_001)
        StubProtocol.handle(host) { _ in (200, ["Content-Type": "application/a-gzip"], bytes) }
        let client = try ReporterClient(token: "synthetic-reporting-token", origin: URL(string: "https://\(host)")!, configuration: configuration)
        #expect(try await client.financialReport(account: "1234567", vendor: "80000001", region: "ZZ", year: 2026, period: 4) == .report(bytes))
        await #expect(throws: ReporterClient.Failure.size) { try await client.dailySales(account: "1234567", vendor: "80000001", day: "2026-03-01") }
        StubProtocol.handle(host) { _ in (200, ["Content-Type": "application/a-gzip"], Data([0x1f, 0x8b]) + Data(repeating: 1, count: 10_000_001)) }
        await #expect(throws: ReporterClient.Failure.size) { try await client.financialReport(account: "1234567", vendor: "80000001", region: "ZZ", year: 2026, period: 4) }
    }
}
