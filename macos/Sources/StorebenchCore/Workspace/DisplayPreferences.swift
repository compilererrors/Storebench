import Foundation

public struct DisplayPreferences: Equatable, Sendable {
    public static let currencies = [
        "AED", "AFN", "ALL", "AMD", "ANG", "AOA", "ARS", "AUD", "AWG", "AZN", "BAM", "BBD", "BDT", "BGN", "BHD", "BIF",
        "BMD", "BND", "BOB", "BRL", "BSD", "BTN", "BWP", "BYN", "BZD", "CAD", "CDF", "CHF", "CLP", "CNY", "COP", "CRC",
        "CUC", "CUP", "CVE", "CZK", "DJF", "DKK", "DOP", "DZD", "EGP", "ERN", "ETB", "EUR", "FJD", "FKP", "GBP", "GEL",
        "GHS", "GIP", "GMD", "GNF", "GTQ", "GYD", "HKD", "HNL", "HRK", "HTG", "HUF", "IDR", "ILS", "INR", "IQD", "IRR",
        "ISK", "JMD", "JOD", "JPY", "KES", "KGS", "KHR", "KMF", "KPW", "KRW", "KWD", "KYD", "KZT", "LAK", "LBP", "LKR",
        "LRD", "LSL", "LYD", "MAD", "MDL", "MGA", "MKD", "MMK", "MNT", "MOP", "MRU", "MUR", "MVR", "MWK", "MXN", "MYR",
        "MZN", "NAD", "NGN", "NIO", "NOK", "NPR", "NZD", "OMR", "PAB", "PEN", "PGK", "PHP", "PKR", "PLN", "PYG", "QAR",
        "RON", "RSD", "RUB", "RWF", "SAR", "SBD", "SCR", "SDG", "SEK", "SGD", "SHP", "SLE", "SLL", "SOS", "SRD", "SSP",
        "STN", "SVC", "SYP", "SZL", "THB", "TJS", "TMT", "TND", "TOP", "TRY", "TTD", "TWD", "TZS", "UAH", "UGX", "USD",
        "UYU", "UZS", "VES", "VND", "VUV", "WST", "XAF", "XCD", "XCG", "XDR", "XOF", "XPF", "XSU", "YER", "ZAR", "ZMW",
        "ZWG", "ZWL",
    ]
    private static let supported = Set(currencies)
    public let currency: String

    public init(currency: String = "USD") throws {
        guard Self.supported.contains(currency) else { throw PricingFailure.invalid("Choose a supported currency.") }
        self.currency = currency
    }

    public init(_ value: JSONText) throws {
        guard case .object = value else { throw PricingFailure.invalid("Invalid display preference.") }
        guard value["schemaVersion"] == .number(1), let code = value["currency"]?.text else { throw PricingFailure.invalid("Choose a supported currency.") }
        try self.init(currency: code)
    }

    public var json: JSONText { .object([("schemaVersion", .number(1)), ("currency", .string(currency))]) }

    static func stored(_ document: EncryptedDocumentStore.Document?) throws -> Self {
        let value = try document.map { try JSONText.parse($0.payload) }
        // The primary state reader treats an absent or null document as its default.
        if value == nil || value == .null { return try Self() }
        return try Self(value!)
    }
}
