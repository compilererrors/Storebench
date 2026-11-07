import Foundation

/// CSV files with one value per country or region: your own prices, country percentages or your own index. Countries use Apple's
/// three-letter territory codes, such as USA or SWE. Apple has no CSV format for prices, so prices use the columns of Storebench's
/// own price export: an exported file can be edited and read back here, and its extra columns are accepted.
public enum PricingCSV {
    public enum Kind: String, CaseIterable, Sendable, Identifiable {
        case prices, percentages, index
        public var id: String { rawValue }
        /// The column with the value.
        public var column: String {
            switch self { case .prices: "amount"; case .percentages: "percentage"; case .index: "value" }
        }
        public var title: String {
            switch self { case .prices: "Your prices"; case .percentages: "Country percentages"; case .index: "Your own index" }
        }
        /// What each row means, in one sentence.
        public var meaning: String {
            switch self {
            case .prices: "One row per country or region: its price in its own currency. Currency is optional and must match Apple's currency there."
            case .percentages: "One row per country or region: a percentage of the guide price, from 0 to 1,000."
            case .index: "One row per country or region: any value in its own currency, such as the local price of a product everyone buys. Include the guide country."
            }
        }
        /// A synthetic example to copy and fill in.
        public var format: String {
            switch self {
            case .prices: "territory,currency,amount\r\nUSA,USD,4.99\r\nSWE,SEK,59.00\r\nDEU,EUR,4.99\r\n"
            case .percentages: "territory,percentage\r\nSWE,85\r\nIND,40\r\nBRA,60\r\n"
            case .index: "territory,value\r\nUSA,15.49\r\nSWE,129\r\nIND,199\r\n"
            }
        }
        var optional: [String] { self == .prices ? ["app_id", "currency", "start_date", "end_date"] : [] }
    }

    /// The country codes and values in the file, as typed. Every row is checked; nothing is kept from a file with an invalid row.
    /// `territories` is Apple's list with currencies; when it is empty, codes are checked against Apple's territory codes.
    public static func read(_ data: Data, kind: Kind, territories: [Territory]) throws -> [String: String] {
        guard let text = String(data: data, encoding: .utf8) else { throw PricingFailure.invalid("Save the CSV file as UTF-8 text.") }
        let records: [[String: String]]
        do { records = try Delimited.records(try Delimited.parse(text), expected: ["territory", kind.column], optional: kind.optional) }
        catch let failure as Delimited.Failure { throw PricingFailure.invalid(failure.message.replacingOccurrences(of: " Download a template to start.", with: " Copy CSV Format shows an example.")) }
        guard records.count <= 250 else { throw PricingFailure.invalid("A CSV file can contain at most 250 countries or regions.") }
        let known = territories.isEmpty ? Set(Territories.alpha3.values) : Set(territories.map(\.code))
        var values: [String: String] = [:]
        for (offset, record) in records.enumerated() {
            func problem(_ text: String) -> PricingFailure { .invalid("Row \(offset + 2): \(text)") }
            let code = TextSemantics.trim(record["territory"] ?? "").uppercased(), value = TextSemantics.trim(record[kind.column] ?? "")
            guard known.contains(code) else {
                throw problem("Use Apple's three-letter code for the country or region, such as USA.")
            }
            guard values[code] == nil else { throw problem("\(WorkspaceSession.countryName(code)) appears more than once.") }
            guard value.range(of: #"^\d+(?:\.\d+)?$"#, options: .regularExpression) != nil, let number = PricingMath.decimal(value) else { throw problem("Enter the \(kind.column) as a number with a period for decimals, such as 4.99.") }
            switch kind {
            case .prices:
                guard number > 0 else { throw problem("Enter a price above zero.") }
                if let currency = record["currency"].map(TextSemantics.trim), !currency.isEmpty, let expected = territories.first(where: { $0.code == code })?.currency, currency.uppercased() != expected {
                    throw problem("Apple's currency in \(WorkspaceSession.countryName(code)) is \(expected), not \(currency).")
                }
                guard (record["start_date"] ?? "").isEmpty, (record["end_date"] ?? "").isEmpty else { throw problem("Prices with dates are temporary prices. Use Country Drafts for those, or leave the dates empty.") }
            case .percentages: guard number <= 1000 else { throw problem("Enter a percentage from 0 to 1,000.") }
            case .index: guard number > 0 else { throw problem("Enter a value above zero.") }
            }
            values[code] = value
        }
        return values
    }
}
