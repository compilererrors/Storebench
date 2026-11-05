import Foundation

public struct ReporterAccount: Equatable, Sendable, Identifiable {
    public let number, name: String
    public var id: String { number }
}

/// Bounded Robot.XML discovery. Only verified account names/numbers leave the parser; upstream error text is discarded.
public enum ReporterCatalog {
    static func body(_ xml: String, root: String) throws -> String {
        guard xml.utf16.count <= 64_000 else { throw ReporterClient.Failure.unsupported }
        return try ReporterClient.xml(ReporterClient.Reply(gzip: false, ok: true, body: Data(xml.utf8)), root: root)
    }
    static func values(_ pattern: String, body: String) throws -> ([[String]], String) {
        let expression = try NSRegularExpression(pattern: pattern)
        let values = expression.matches(in: body, range: NSRange(body.startIndex..., in: body)).map { match in
            (1..<match.numberOfRanges).map { String(body[Range(match.range(at: $0), in: body)!]) }
        }
        return (values, TextSemantics.trim(expression.stringByReplacingMatches(in: body, range: NSRange(body.startIndex..., in: body), withTemplate: "")))
    }
    static func name(_ source: String) throws -> String {
        let expression = try NSRegularExpression(pattern: #"&(amp|lt|gt|quot|apos|#[0-9]+|#x[0-9a-fA-F]+);"#)
        var result = "", position = source.startIndex
        for match in expression.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            let range = Range(match.range, in: source)!, entity = String(source[Range(match.range(at: 1), in: source)!])
            let plain = source[position..<range.lowerBound]
            guard !plain.contains("&"), !plain.contains("<") else { throw ReporterClient.Failure.unsupported }
            result += plain
            switch entity {
            case "amp": result += "&"
            case "lt": result += "<"
            case "gt": result += ">"
            case "quot": result += "\""
            case "apos": result += "'"
            default:
                let hexadecimal = entity.hasPrefix("#x"), digits = String(entity.dropFirst(hexadecimal ? 2 : 1))
                guard let code = UInt32(digits, radix: hexadecimal ? 16 : 10), code >= 32, let scalar = UnicodeScalar(code) else { throw ReporterClient.Failure.unsupported }
                result.unicodeScalars.append(scalar)
            }
            position = range.upperBound
        }
        let remainder = source[position...]
        guard !remainder.contains("&"), !remainder.contains("<") else { throw ReporterClient.Failure.unsupported }
        result += remainder; result = TextSemantics.trim(result)
        guard !result.isEmpty, result.utf16.count <= 300 else { throw ReporterClient.Failure.unsupported }
        return result
    }
    public static func accounts(_ xml: String) throws -> [ReporterAccount] {
        let (values, remainder) = try values(#"<Account>\s*<Name>([^<]*)</Name>\s*<Number>([0-9]{1,20})</Number>\s*</Account>"#, body: body(xml, root: "Accounts"))
        guard remainder.isEmpty, (1...200).contains(values.count), Set(values.map { $0[1] }).count == values.count else { throw ReporterClient.Failure.access }
        return try values.map { ReporterAccount(number: $0[1], name: try name($0[0])) }
    }
    public static func vendors(_ xml: String) throws -> [String] {
        let (values, remainder) = try values(#"<Vendor>([0-9]{6,20})</Vendor>"#, body: body(xml, root: "Vendors"))
        let vendors = values.map { $0[0] }
        guard remainder.isEmpty, (1...200).contains(vendors.count), Set(vendors).count == vendors.count else { throw ReporterClient.Failure.access }
        return vendors
    }
}

extension ReporterClient {
    public func accounts() async throws -> [ReporterAccount] {
        let reply = try await request(sales, command: "Sales.getAccounts", account: nil)
        _ = try Self.recorded(reply, .reporterSales) { try Self.xml($0, root: "Accounts") }
        guard let xml = String(data: reply.body, encoding: .utf8) else { throw Failure.unsupported }
        return try ReporterCatalog.accounts(xml)
    }
    public func vendors(account: String) async throws -> [String] {
        if let selection, selection.accountNumber != account { throw Failure.wrongAccount }
        let reply = try await request(sales, command: "Sales.getVendors", account: account)
        _ = try Self.recorded(reply, .reporterSales) { try Self.xml($0, root: "Vendors") }
        guard let xml = String(data: reply.body, encoding: .utf8) else { throw Failure.unsupported }
        return try ReporterCatalog.vendors(xml)
    }
}
