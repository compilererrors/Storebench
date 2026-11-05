import Foundation
import Testing
@testable import StorebenchCore

/// Reporter answers in the formats Apple's Reporter guide documents, even when the HTTP content type or
/// the Robot.XML mode is not what earlier responses used. Everything here is synthetic.
struct ReporterResponseTests {
    init() throws { _ = try TestIsolation.require() }

    private func client(_ host: String, status: Int = 200, type: String, body: Data) throws -> ReporterClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        StubProtocol.handle(host) { _ in (status, ["Content-Type": type], body) }
        return try ReporterClient(token: "synthetic-reporting-token", origin: URL(string: "https://\(host)")!, configuration: configuration)
    }
    private let header = "Provider\tProvider Country\tSKU\tDeveloper\tTitle\tVersion\tProduct Type Identifier\tUnits"

    @Test(arguments: ["application/a-gzip", "application/x-gzip", "application/gzip", "application/octet-stream", ""])
    func gzipReportsAreRecognizedByTheirBytes(_ type: String) async throws {
        let bytes = Data([0x1f, 0x8b, 0x08, 0x00]) + Data(repeating: 7, count: 32)
        let reporter = try client("gzip-\(type.isEmpty ? "none" : type.replacingOccurrences(of: "/", with: "-")).reporting.test", type: type, body: bytes)
        #expect(try await reporter.dailySales(account: "1234567", vendor: "80000001", day: "2026-10-13") == .report(bytes))
    }

    @Test func plainTextNoSalesAndUnavailableKeepTheirMeaning() async throws {
        let noSales = try client("plain-no-sales.reporting.test", type: "text/plain", body: Data("There were no sales for the date specified.".utf8))
        #expect(try await noSales.dailySales(account: "1234567", vendor: "80000001", day: "2026-10-12") == .noSales)
        let later = try client("plain-not-yet.reporting.test", type: "text/plain", body: Data("Report is not available yet. Daily reports for the Americas are available by 5 am Pacific Time.".utf8))
        #expect(try await later.dailySales(account: "1234567", vendor: "80000001", day: "2026-10-16") == .unavailable)
    }

    @Test func plainTextAccessErrorsKeepTheirMeaning() async throws {
        let expired = try client("plain-expired.reporting.test", type: "text/plain", body: Data("Your Access Token is expired. Please regenerate your Access Token.".utf8))
        await #expect(throws: ReporterClient.Failure.expiredToken) { try await expired.dailySales(account: "1234567", vendor: "80000001", day: "2026-10-12") }
        let vendor = try client("plain-vendor.reporting.test", type: "text/plain", body: Data("Invalid vendor number specified. Try again.".utf8))
        await #expect(throws: ReporterClient.Failure.wrongAccount) { try await vendor.dailySales(account: "1234567", vendor: "80000001", day: "2026-10-12") }
    }

    @Test func uncompressedReportsAreAccepted() async throws {
        let text = Data((header + "\nAPPLE\tUS\tsynthetic.sku\tSynthetic Developer\tSynthetic App\t1.0\t1F\t3\n").utf8)
        let reporter = try client("plain-report.reporting.test", type: "text/plain", body: text)
        #expect(try await reporter.dailySales(account: "1234567", vendor: "80000001", day: "2026-10-13") == .report(text))
    }

    @Test func unknownTextAndFailedStatusesStayUnsupported() async throws {
        let unknown = try client("plain-unknown.reporting.test", type: "text/plain", body: Data("Synthetic upstream detail".utf8))
        await #expect(throws: ReporterClient.Failure.unsupported) { try await unknown.dailySales(account: "1234567", vendor: "80000001", day: "2026-10-13") }
        let failed = try client("plain-report-failed.reporting.test", status: 400, type: "text/plain", body: Data((header + "\n").utf8))
        await #expect(throws: ReporterClient.Failure.unsupported) { try await failed.dailySales(account: "1234567", vendor: "80000001", day: "2026-10-13") }
        let truncated = try client("gzip-type-not-gzip.reporting.test", type: "application/a-gzip", body: Data("not a gzip stream".utf8))
        await #expect(throws: ReporterClient.Failure.unsupported) { try await truncated.dailySales(account: "1234567", vendor: "80000001", day: "2026-10-13") }
    }
}
