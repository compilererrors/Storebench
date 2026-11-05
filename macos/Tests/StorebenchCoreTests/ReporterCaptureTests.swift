import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct ReporterCaptureTests {
    init() throws { _ = try TestIsolation.require() }
    @Test func aCapturedTokenCannotBeReusedForAnotherAccountVendorOrCredentialChoice() async throws {
        let (session, account, root) = try await FinanceSyncTests().session(reporter: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let captured = try #require(try await session.reporterClient(accountId: account.id))
        let apiHost = "reporter-capture.appstoreconnect.test", reporterHost = "reporter-capture.reporting.test"
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubProtocol.self]
        let reporter = try ReporterClient(token: captured.token, origin: URL(string: "https://\(reporterHost)")!, configuration: configuration, selection: captured.selection)
        let client = try FinanceSyncTests().client(apiHost, account)
        await #expect(throws: ReporterClient.Failure.wrongAccount) { try await reporter.dailySales(account: "1234568", vendor: "80000001", day: "2026-02-10") }
        await #expect(throws: ReporterClient.Failure.wrongAccount) { try await reporter.financeVendors(account: "1234568") }
        await #expect(throws: ReporterClient.Failure.wrongAccount) { try await reporter.financialReport(account: "1234567", vendor: "80000002", region: "ZZ", year: 2026, period: 4) }
        for (number, vendor, credential) in [("1234568", "80000001", "00000000-0000-4000-8000-000000000099"), ("1234567", "80000002", "00000000-0000-4000-8000-000000000099"), ("1234567", "80000001", "00000000-0000-4000-8000-000000000098")] {
            try await session.storeAccess { store in
                try FileMutex.withLock(store.directory.appendingPathComponent("reporter_" + JSONText.string(account.id).rawSHA256.prefix(32) + ".mutex")) {
                    try store.transaction { _ in [.put(namespace: "sales_connection", key: account.id, json: JSONText.object([("schemaVersion", .number(1)), ("accountId", .string(account.id)), ("vendorNumber", .string(vendor)), ("reporter", .object([("accountNumber", .string(number)), ("vendorNumber", .string(vendor)), ("credentialId", .string(credential)), ("connectedAt", .string("2026-01-01T00:00:00.000Z"))]))]).data)] }
                }
            }
            await #expect(throws: SalesFailure.changedConnection) { try await session.downloadSales(account: account, appId: "1000000001", days: ["2026-02-10"], client: client, reporter: reporter) }
            await #expect(throws: FinanceFailure.access) { try await session.downloadFinancial(account: account, appId: "1000000001", region: "ZZ", periods: [FiscalPeriod(year: 2026, period: 4)], client: client, reporter: reporter) }
        }
        try await session.storeAccess { store in try store.transaction { _ in [.put(namespace: "sales_connection", key: "synthetic-other-account", json: Data(#"{"schemaVersion":1,"accountId":"synthetic-other-account","vendorNumber":"80000001","reporter":{"accountNumber":"1234567","vendorNumber":"80000001","credentialId":"00000000-0000-4000-8000-000000000099","connectedAt":"2026-01-01T00:00:00.000Z"}}"#.utf8))] } }
        await #expect(throws: SalesFailure.changedConnection) { try await session.capturedSalesConnection(accountId: "synthetic-other-account", reporter: reporter) }
        #expect(StubProtocol.requests(apiHost).isEmpty && StubProtocol.requests(reporterHost).isEmpty)
    }
    @Test func aRawTransportTokenCannotSelectAConfiguredReporterAndSwitchingToTeamApiRequiresAFreshCapture() async throws {
        let (session, account, root) = try await FinanceSyncTests().session(reporter: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let captured = try #require(try await session.reporterClient(accountId: account.id))
        let raw = try ReporterClient(token: captured.token)
        await #expect(throws: SalesFailure.changedConnection) { try await session.capturedSalesConnection(accountId: account.id, reporter: raw) }
        try await session.storeAccess { store in try store.transaction { _ in [.put(namespace: "sales_connection", key: account.id, json: try SalesSyncTests.connection(#"{"vendorNumber":"80000001"}"#, accountId: account.id).data)] } }
        await #expect(throws: SalesFailure.changedConnection) { try await session.capturedSalesConnection(accountId: account.id, reporter: captured) }
        let fresh = try await session.capturedSalesConnection(accountId: account.id, reporter: nil)
        #expect(fresh?.vendorNumber == "80000001" && fresh?.reporter == nil)
    }
}
