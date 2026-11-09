import Foundation

/// Apple's Reporter service over HTTPS: Reporter 2.2 Robot.XML requests.
/// Upstream messages are never shown; they can include account information.
public struct ReporterClient: Sendable {
    public enum Answer: Equatable { case report(Data), noSales, unavailable }
    public enum Failure: Error, Equatable { case expiredToken, access, wrongAccount, unsupported, invalidToken, serviceUnavailable, size }
    let token: String, session: URLSession
    let pool: BoundedResponse.Pool
    let sales: URL, finance: URL
    struct Selection: Sendable {
        let accountId, accountNumber, vendorNumber, credentialId: String
        func matches(accountId: String, connection: WorkspaceSession.SalesConnection.Reporter) -> Bool {
            self.accountId == accountId && accountNumber == connection.accountNumber && vendorNumber == connection.vendorNumber && credentialId == connection.credentialId
        }
    }
    let selection: Selection?
    let accessCheck: @Sendable () throws -> Void

    public init(token: String, origin: URL = URL(string: "https://reportingitc-reporter.apple.com")!, configuration: URLSessionConfiguration = .ephemeral) throws {
        try self.init(token: token, origin: origin, configuration: configuration, selection: nil)
    }
    init(token: String, origin: URL = URL(string: "https://reportingitc-reporter.apple.com")!, configuration: URLSessionConfiguration = .ephemeral, selection: Selection?, accessCheck: @escaping @Sendable () throws -> Void = {}) throws {
        let trimmed = TextSemantics.trim(token)
        // Reporter tokens are opaque; Apple verifies their format and validity during discovery.
        guard !trimmed.isEmpty, trimmed.utf8.count <= 200,
              trimmed.unicodeScalars.allSatisfy({ (0x21...0x7e).contains($0.value) }) else { throw Failure.invalidToken }
        configuration.timeoutIntervalForRequest = 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        let pool = BoundedResponse.Pool(configuration: configuration)
        self.token = trimmed; self.pool = pool; self.session = pool.session; self.selection = selection
        self.accessCheck = accessCheck
        self.sales = origin.appendingPathComponent("reportservice/sales/v1"); self.finance = origin.appendingPathComponent("reportservice/finance/v1")
    }

    struct Reply {
        let gzip: Bool; let ok: Bool; let body: Data
        var status = 200, contentType: String? = nil
        var shape: String { ReplyDiagnostics.describe(status: status, contentType: contentType, body: body) }
    }

    func request(_ endpoint: URL, command: String, account: String?, maxReportBytes: Int = 4_000_000) async throws -> Reply {
        try accessCheck()
        if let account { guard account.range(of: #"^\d{1,20}$"#, options: .regularExpression) != nil else { throw Failure.unsupported } }
        var fields: [String: String] = ["version": "2.2", "mode": "Robot.XML", "queryInput": "[p=Reporter.properties, \(command)]", "accesstoken": token]
        if let account { fields["account"] = account }
        let body = try JSONSerialization.data(withJSONObject: fields)
        var request = URLRequest(url: endpoint); request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/a-gzip, text/xml, text/plain", forHTTPHeaderField: "Accept")
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        request.httpBody = Data("jsonRequest=\(String(decoding: body, as: UTF8.self).addingPercentEncoding(withAllowedCharacters: allowed)!)".utf8)
        let result: BoundedResponse.Result
        do { result = try await pool.read(request, maximumBytes: maxReportBytes) }
        catch BoundedResponse.Failure.tooLarge { throw Failure.size }
        catch BoundedResponse.Failure.invalidResponse { throw Failure.unsupported }
        try accessCheck()
        let data = result.data, http = result.response
        if http.statusCode == 429 || http.statusCode >= 500 || http.statusCode == 401 || http.statusCode == 403 {
            let source: ReplyDiagnostics.Source = endpoint == finance ? .reporterFinance : .reporterSales
            ReplyDiagnostics.record(source, ReplyDiagnostics.describe(status: http.statusCode, contentType: http.value(forHTTPHeaderField: "Content-Type"), body: data))
            throw http.statusCode == 401 ? Failure.expiredToken : http.statusCode == 403 ? Failure.access : Failure.serviceUnavailable
        }
        // The payload's own gzip signature decides, never the content type: account and vendor lists arrive
        // as Robot.XML labelled application/a-gzip, and reports arrive under several gzip or generic types.
        let gzip = Self.isGzip(data)
        let markup = !gzip && (String(data: data.prefix(256), encoding: .utf8).map { TextSemantics.trim($0).hasPrefix("<") } ?? false)
        guard data.count <= (markup ? 64_000 : maxReportBytes) else { throw Failure.size }
        return Reply(gzip: gzip, ok: (200..<300).contains(http.statusCode), body: data, status: http.statusCode, contentType: http.value(forHTTPHeaderField: "Content-Type"))
    }

    /// Robot.XML errors arrive even with an error status; anything else is unsupported.
    static func xml(_ reply: Reply, root: String) throws -> String {
        guard !reply.gzip, var text = Self.text(reply.body), text.hasPrefix("<") else { throw Failure.unsupported }
        if let declaration = text.range(of: #"^<\?xml\s[^?]*\?>\s*"#, options: .regularExpression) { text.removeSubrange(declaration) }
        guard text.utf16.count <= 64_000 else { throw Failure.unsupported }
        // Errors are read by their code alone, so a message in a CDATA section or an attribute on the root still counts.
        if text.range(of: #"^<Error(\s[^>]*)?>[\s\S]*</Error>$"#, options: .regularExpression) != nil {
            let code = text.range(of: #"<Code>\s*\d{1,6}\s*</Code>"#, options: .regularExpression).flatMap { Int(text[$0].filter(\.isNumber)) }
            switch code {
            case 1: throw Failure.serviceUnavailable
            case 123, 124, 125: throw Failure.expiredToken
            case 213: throw Unavailable(noSales: true)
            case 117, 209, 210, 211: throw Unavailable(noSales: false)
            case 200, 214, 215, 216: throw Failure.wrongAccount
            default:
                // An undocumented code keeps the meaning of Apple's documented message, when it has one.
                if let message = text.range(of: #"(?<=<Message>)[\s\S]{0,2000}?(?=</Message>)"#, options: .regularExpression) {
                    try plainTextAnswer(text[message].replacingOccurrences(of: "<![CDATA[", with: "").replacingOccurrences(of: "]]>", with: ""))
                }
                throw Failure.access
            }
        }
        guard !text.contains("<!"), !text.contains("<?") else { throw Failure.unsupported }
        guard text.hasPrefix("<\(root)>"), text.hasSuffix("</\(root)>"), reply.ok else { throw Failure.unsupported }
        return String(text.dropFirst(root.count + 2).dropLast(root.count + 3))
    }
    struct Unavailable: Error { let noSales: Bool }

    /// UTF-8 text without a byte order mark or surrounding whitespace.
    static func text(_ data: Data) -> String? {
        guard var text = String(data: data, encoding: .utf8) else { return nil }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return TextSemantics.trim(text)
    }

    static func isGzip(_ data: Data) -> Bool { data.count >= 2 && data[data.startIndex] == 0x1f && data[data.startIndex + 1] == 0x8b }

    static func report(_ reply: Reply) throws -> Data {
        if reply.gzip {
            guard reply.ok, isGzip(reply.body) else { throw Failure.unsupported }
            return reply.body
        }
        guard let text = Self.text(reply.body), !text.isEmpty else { throw Failure.unsupported }
        if text.hasPrefix("<") { _ = try xml(reply, root: "Output"); throw Failure.unsupported }
        // Apple can ignore Robot.XML and answer in its normal text mode; its documented messages keep their meaning.
        try plainTextAnswer(text)
        // An uncompressed report is tab-separated text with Apple's header row.
        guard reply.ok, let header = text.split(separator: "\n", maxSplits: 1).first, header.contains("\t"),
              header.hasPrefix("Provider") || header.hasPrefix("Start Date") else { throw Failure.unsupported }
        return reply.body
    }

    /// Runs `body` and, when the reply cannot be used or is an error, records its shape so the failure can say what Apple sent.
    static func recorded<T>(_ reply: Reply, _ source: ReplyDiagnostics.Source, _ body: (Reply) throws -> T) throws -> T {
        do { let value = try body(reply); ReplyDiagnostics.clear(source); return value }
        catch let failure as Failure { ReplyDiagnostics.record(source, reply.shape); throw failure }
    }

    /// Maps the messages from Apple's Reporter guide when they arrive as plain text instead of Robot.XML.
    static func plainTextAnswer(_ text: String) throws {
        let message = text.lowercased()
        if message.contains("there were no sales for the date specified") { throw Unavailable(noSales: true) }
        if ["reports are delayed", "report is not available yet", "report is no longer available", "report is unexpectedly not available",
            "no reports available", "is not available for the selected", "are available only for"].contains(where: message.contains) { throw Unavailable(noSales: false) }
        if message.contains("access token is expired") || message.contains("access token is invalid") || message.contains("access token is incorrectly specified") { throw Failure.expiredToken }
        if message.contains("invalid vendor number") || message.contains("invalid account number") || message.contains("access to more than one account") { throw Failure.wrongAccount }
        if message.contains("an unexpected error occurred") { throw Failure.serviceUnavailable }
    }

    public func dailySales(account: String, vendor: String, day: String) async throws -> Answer {
        if let selection, selection.accountNumber != account || selection.vendorNumber != vendor { throw Failure.wrongAccount }
        guard vendor.range(of: #"^\d{6,20}$"#, options: .regularExpression) != nil, ReportTables.validDate(day) else { throw Failure.unsupported }
        let reply = try await request(sales, command: "Sales.getReport, \(vendor),Sales,Summary,Daily,\(day.replacingOccurrences(of: "-", with: ""))", account: account)
        do { return .report(try Self.recorded(reply, .reporterSales) { try Self.report($0) }) }
        catch let answer as Unavailable { return answer.noSales ? .noSales : .unavailable }
    }

    /// Vendors with the regions whose Financial reports this token can read.
    public func financeVendors(account: String) async throws -> [(number: String, regions: [String])] {
        if let selection, selection.accountNumber != account { throw Failure.wrongAccount }
        let catalog = try await request(finance, command: "Finance.getVendorsAndRegions", account: account)
        let body = try Self.recorded(catalog, .reporterFinance) { try Self.xml($0, root: "VendorsAndRegions") }
        var vendors: [(String, [String])] = [], rest = body
        let vendorPattern = try NSRegularExpression(pattern: #"<Vendor>\s*<Number>(\d{6,20})</Number>([\s\S]*?)</Vendor>"#)
        let regionPattern = try NSRegularExpression(pattern: #"<Region>\s*<Code>([A-Z0-9]{2})</Code>\s*<Reports>([\s\S]*?)</Reports>\s*</Region>"#)
        let reportPattern = try NSRegularExpression(pattern: #"<Report>([A-Za-z][A-Za-z0-9]{0,39})</Report>"#)
        func groups(_ match: NSTextCheckingResult, in text: String) -> [String] { (1..<match.numberOfRanges).map { String(text[Range(match.range(at: $0), in: text)!]) } }
        func strip(_ pattern: NSRegularExpression, _ text: String) -> String { pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "") }
        for match in vendorPattern.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
            let parts = groups(match, in: body)
            var regions: [String] = []
            for region in regionPattern.matches(in: parts[1], range: NSRange(parts[1].startIndex..., in: parts[1])) {
                let fields = groups(region, in: parts[1])
                let types = reportPattern.matches(in: fields[1], range: NSRange(fields[1].startIndex..., in: fields[1])).map { groups($0, in: fields[1])[0] }
                guard strip(reportPattern, fields[1]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.unsupported }
                if types.contains("Financial") { regions.append(fields[0]) }
            }
            guard strip(regionPattern, parts[1]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, regions.count <= 100, Set(regions).count == regions.count else { throw Failure.unsupported }
            vendors.append((parts[0], regions))
        }
        rest = strip(vendorPattern, rest)
        guard rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !vendors.isEmpty, vendors.count <= 200, Set(vendors.map(\.0)).count == vendors.count else { throw Failure.access }
        return vendors
    }

    public func financialReport(account: String, vendor: String, region: String, year: Int, period: Int) async throws -> Answer {
        if let selection, selection.accountNumber != account || selection.vendorNumber != vendor { throw Failure.wrongAccount }
        guard vendor.range(of: #"^\d{6,20}$"#, options: .regularExpression) != nil, (1...12).contains(period), (2001...9999).contains(year),
              region.range(of: "^[A-Z0-9]{2}$", options: .regularExpression) != nil else { throw Failure.unsupported }
        let reply = try await request(finance, command: "Finance.getReport, \(vendor),\(region),Financial,\(year),\(period)", account: account, maxReportBytes: 10_000_000)
        do { return .report(try Self.recorded(reply, .reporterFinance) { try Self.report($0) }) }
        catch let answer as Unavailable { return answer.noSales ? .noSales : .unavailable }
    }
}

/// Reporter and report-file requests never follow redirects.
final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? { nil }
}
