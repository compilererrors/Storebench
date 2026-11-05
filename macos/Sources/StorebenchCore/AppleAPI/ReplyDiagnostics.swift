import Foundation

/// The shape of the latest reply Storebench could not use, per source, without any of its content: HTTP status,
/// media type, payload kind and size, or the format rule a report broke. A failure can then say what Apple sent,
/// and the text is safe to show and copy because it never includes upstream messages, accounts or report rows.
public enum ReplyDiagnostics {
    public enum Source: String, Sendable, CaseIterable { case reporterSales, reporterFinance, salesReport, analytics }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var latest: [Source: String] = [:]

    public static func record(_ source: Source, _ summary: String) { lock.withLock { latest[source] = String(summary.prefix(200)) } }
    public static func clear(_ source: Source) { lock.withLock { latest[source] = nil } }
    public static func latest(_ source: Source) -> String? { lock.withLock { latest[source] } }

    /// The source whose reply explains a public error code, if any.
    public static func source(forCode code: String?) -> Source? {
        switch code {
        case "SB-REPORTER-RESPONSE": .reporterSales
        case "SB-FINANCE-RESPONSE": .reporterFinance
        case "SB-REPORT-FORMAT": .salesReport
        case "SB-ANALYTICS-FORMAT": .analytics
        default: nil
        }
    }
    public static func latest(forCode code: String?) -> String? { source(forCode: code).flatMap(latest) }

    static let knownReportColumns: Set<String> = ["Provider", "Start Date", "Date", "App Apple Identifier", "Vendor Identifier", "Transaction Date", "Begin Date"]

    /// Describes a reply by its form only.
    static func describe(status: Int, contentType: String?, body: Data) -> String {
        let declared = (contentType ?? "").split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        let media = declared.isEmpty ? "no content type"
            : declared.range(of: #"^[a-z0-9.+-]{1,40}/[a-z0-9.+-]{1,60}$"#, options: .regularExpression) != nil ? declared : "unrecognized content type"
        return "HTTP \(status) · \(media) · \(kind(body)) · \(ByteCountFormatter.string(fromByteCount: Int64(body.count), countStyle: .file))"
    }

    static func kind(_ body: Data) -> String {
        if body.isEmpty { return "empty reply" }
        if body.count >= 2, body[body.startIndex] == 0x1f, body[body.startIndex + 1] == 0x8b { return "gzip data" }
        guard var text = String(data: body.prefix(64_000), encoding: .utf8) ?? (body.count > 64_000 ? String(decoding: body.prefix(64_000), as: UTF8.self) : nil) else { return "binary data" }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("<") {
            let lower = text.prefix(2_000).lowercased()
            if lower.contains("<html") || lower.contains("<!doctype html") { return "HTML page" }
            let body = text.replacingOccurrences(of: #"^<\?xml[^>]*>\s*"#, with: "", options: .regularExpression)
            guard let root = body.range(of: #"^<[A-Za-z][A-Za-z0-9]{0,39}"#, options: .regularExpression) else { return "markup" }
            let name = String(body[root].dropFirst())
            if name == "Error", let code = body.range(of: #"<Code>\s*\d{1,6}\s*</Code>"#, options: .regularExpression) {
                return "XML Error, code " + body[code].filter(\.isNumber)
            }
            return "XML <\(name)>"
        }
        let header = text.prefix { $0 != "\n" && $0 != "\r" }
        if header.contains("\t") {
            let columns = header.split(separator: "\t", omittingEmptySubsequences: false)
            let first = columns.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            return "tab-separated text, \(columns.count) columns, " + (knownReportColumns.contains(first) ? "first column “\(first)”" : "first column not a known report column")
        }
        if text.hasPrefix("{") || text.hasPrefix("[") { return "JSON" }
        return "plain text, \(text.count) characters, not a documented Reporter message"
    }
}
