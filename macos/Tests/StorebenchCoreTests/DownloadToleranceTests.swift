import Foundation
import Testing
@testable import StorebenchCore

/// Downloads keep working when Apple changes form but not meaning: CDATA messages, new codes with documented text,
/// uncompressed reports, byte order marks, trailing cells, new report columns and new download types.
/// When a reply is still unusable, its shape is recorded without any of its content. Everything here is synthetic.
struct DownloadToleranceTests {
    init() throws { _ = try TestIsolation.require() }

    private func reporter(_ host: String, status: Int = 200, type: String, body: String) throws -> ReporterClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        StubProtocol.handle(host) { _ in (status, ["Content-Type": type], Data(body.utf8)) }
        return try ReporterClient(token: "synthetic-reporting-token", origin: URL(string: "https://\(host)")!, configuration: configuration)
    }
    private func sales(_ client: ReporterClient) async throws -> ReporterClient.Answer {
        try await client.dailySales(account: "1234567", vendor: "80000001", day: "2026-10-13")
    }

    @Test func robotErrorsAreReadByCodeWhateverTheMessageForm() async throws {
        let cdata = try reporter("cdata.reporting.test", type: "text/xml", body: #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Error><Code>213</Code><Message><![CDATA[There were no sales for the date specified.]]></Message></Error>"#)
        #expect(try await sales(cdata) == .noSales)
        let attribute = try reporter("attribute.reporting.test", status: 400, type: "application/xml", body: "<Error version=\"2\">\n  <Code> 210 </Code>\n  <Message>Daily reports are delayed.</Message>\n</Error>")
        #expect(try await sales(attribute) == .unavailable)
        let documented = try reporter("documented.reporting.test", type: "text/xml", body: "<Error><Code>999</Code><Message>Your Access Token is expired. Please regenerate your Access Token.</Message></Error>")
        await #expect(throws: ReporterClient.Failure.expiredToken) { try await sales(documented) }
        let unknown = try reporter("unknown-code.reporting.test", type: "text/xml", body: "<Error><Code>998</Code><Message>Synthetic upstream detail</Message></Error>")
        await #expect(throws: ReporterClient.Failure.access) { try await sales(unknown) }
    }

    @Test func uncompressedReportsWithByteOrderMarksAndWindowsLineEndingsAreAccepted() async throws {
        let text = "\u{FEFF}Provider\tProvider Country\tSKU\tUnits\r\nAPPLE\tUS\tsynthetic.sku\t3\r\n"
        let client = try reporter("bom.reporting.test", type: "text/plain;charset=UTF-8", body: text)
        #expect(try await sales(client) == .report(Data(text.utf8)))
    }

    @Test func unusableRepliesStayUnsupported() async throws {
        let html = try reporter("html.reporting.test", type: "text/html", body: "<!DOCTYPE html><html><body>Synthetic maintenance page</body></html>")
        await #expect(throws: ReporterClient.Failure.unsupported) { try await sales(html) }
        let json = try reporter("json.reporting.test", type: "application/json", body: #"{"synthetic":true}"#)
        await #expect(throws: ReporterClient.Failure.unsupported) { try await sales(json) }
    }

    @Test func replyShapesNameFormNeverContent() {
        let html = ReplyDiagnostics.describe(status: 503, contentType: "text/html; charset=utf-8", body: Data("<!doctype html><html><title>secret-synthetic-account</title></html>".utf8))
        #expect(html.hasPrefix("HTTP 503 · text/html · HTML page · "))
        #expect(!html.contains("secret"))
        let error = ReplyDiagnostics.describe(status: 200, contentType: "text/xml", body: Data("<?xml version=\"1.0\"?><Error><Code>777</Code><Message>secret-synthetic</Message></Error>".utf8))
        #expect(error.contains("XML Error, code 777") && !error.contains("secret"))
        let table = ReplyDiagnostics.describe(status: 200, contentType: nil, body: Data("Provider\tSKU\tUnits\nAPPLE\tsecret.sku\t1\n".utf8))
        #expect(table.contains("no content type") && table.contains("3 columns") && table.contains("“Provider”") && !table.contains("secret"))
        let unknown = ReplyDiagnostics.describe(status: 200, contentType: "text/plain", body: Data("secret-synthetic\tvalue\n".utf8))
        #expect(unknown.contains("first column not a known report column") && !unknown.contains("secret"))
        let plain = ReplyDiagnostics.describe(status: 200, contentType: "Application/Octet-Stream; x=y", body: Data("secret synthetic words".utf8))
        #expect(plain.contains("application/octet-stream · plain text, 22 characters") && !plain.contains("secret"))
        #expect(ReplyDiagnostics.describe(status: 200, contentType: "bad type\u{0}", body: Data([0x1f, 0x8b, 1])).contains("unrecognized content type · gzip data"))
        #expect(ReplyDiagnostics.describe(status: 204, contentType: "", body: Data()).contains("no content type · empty reply"))
        #expect(ReplyDiagnostics.kind(Data([0xff, 0xfe, 0x00, 0xd8])) == "binary data")
    }

    @Test func issueDetailsCarryTheReplyShapeOnlyWhenGiven() {
        let plain = ReportingMessages.issueDetails("SB-REPORTER-RESPONSE")
        #expect(!plain.contains("What Apple sent"))
        let shaped = ReportingMessages.issueDetails("SB-REPORTER-RESPONSE", reply: "HTTP 200 · text/html · HTML page · 1 KB")
        #expect(shaped.contains("What Apple sent: HTTP 200 · text/html · HTML page · 1 KB\n"))
        #expect(ReplyDiagnostics.source(forCode: "SB-REPORTER-RESPONSE") == .reporterSales && ReplyDiagnostics.source(forCode: "SB-ANALYTICS-FORMAT") == .analytics)
        #expect(ReplyDiagnostics.source(forCode: "SB-REPORT-NETWORK") == nil)
    }

    @Test func salesReportsReadCompressedOrNotWithTrailingCells() throws {
        let columns = SalesSyncTests.columns.joined(separator: "\t")
        let row = ["APPLE", "synthetic.sku", "1234567890", "1F", "3", "0.99", "10/13/2026", "10/13/2026", "US", ""].joined(separator: "\t")
        let free = ["APPLE", "synthetic.sub", "2234567890", "IAC", "1", "0", "10/13/2026", "10/13/2026", "SE", "synthetic.sku"].joined(separator: "\t")
        let text = columns + "\r\n" + row + "\t\t\r\n" + free + "\r\n\r\n"
        for bytes in [Data(text.utf8), gzip(text)] {
            let record = try #require(try SalesReports.parseDay(bytes, appId: "1234567890", accountId: "synthetic-account", day: "2026-10-13", importedAt: "2026-10-14T00:00:00.000Z", appSku: nil, scope: nil))
            #expect(record.unitsByTerritory == ["USA": 3])
        }
        #expect(throws: SalesFailure.decode) { try SalesReports.parseDay(Data([0x1f, 0x8b, 0, 1, 2]), appId: "1234567890", accountId: "synthetic-account", day: "2026-10-13", importedAt: "2026-10-14T00:00:00.000Z", appSku: nil, scope: nil) }
    }

    @Test func analyticsReportsAcceptNewColumnsAndDownloadTypes() throws {
        let meta = try AnalyticsMetadata(kind: "downloads", level: "standard", granularity: "DAILY", processingDate: "2026-10-14")
        let columns = ["Date", "App Apple Identifier", "Download Type", "Campaign", "Synthetic New Column", "Territory", "Counts"]
        let text = columns.joined(separator: "\t") + "\n\n"
            + ["2026-10-13", "1234567890", "First-time Download", "", "x", "US", "4"].joined(separator: "\t") + "\t\n"
            + ["2026-10-13", "1234567890", "Synthetic future download type", "", "y", "SE", "2"].joined(separator: "\t") + "\n"
        let table = try ReportTables.parseSegment(text)
        let partitions = try AnalyticsReports.importSegments([table], meta: meta, accountId: "synthetic-account", appId: "1234567890", importedAt: "2026-10-14T00:00:00.000Z")
        #expect(partitions.count == 1)
        guard case .array(let periods) = try AnalyticsReports.view(partitions), case .array(let facts)? = periods.first?["facts"] else { Issue.record("Missing synthetic facts"); return }
        let metrics = facts.compactMap { $0["metric"]?.text }
        #expect(metrics.sorted() == ["first", "other"])
    }

    @Test func analyticsReportsStillNeedTheirCountingColumns() throws {
        let meta = try AnalyticsMetadata(kind: "engagement", level: "standard", granularity: "DAILY", processingDate: "2026-10-14")
        let missing = ReportTable(columns: ["Date", "App Apple Identifier", "Event"], rows: [["2026-10-13", "1234567890", "Impression"]])
        #expect(throws: AnalyticsFailure.format) { try AnalyticsReports.validate(missing, meta) }
        let other = ReportTable(columns: ["Date", "App Apple Identifier", "Event", "Download Type", "Counts"], rows: [["2026-10-13", "1234567890", "Impression", "Redownload", "1"]])
        #expect(throws: AnalyticsFailure.format) { try AnalyticsReports.validate(other, meta) }
        let engagement = ReportTable(columns: ["Date", "App Apple Identifier", "Event", "Counts"], rows: [["2026-10-13", "1234567890", "Synthetic new event", "1"]])
        try AnalyticsReports.validate(engagement, meta)
    }
}
