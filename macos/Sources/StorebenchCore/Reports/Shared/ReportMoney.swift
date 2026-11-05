import Foundation

/// Report proceeds use decimal text; reference quotes are quote currency per display currency.
public enum ReportMoney {
    public struct Amount: Equatable, Sendable, Codable {
        public let currency: String, amount: String
        public init(currency: String, amount: String) { self.currency = currency; self.amount = amount }
    }
    public struct Rate: Equatable, Sendable, Codable {
        public let rate: String, date: String
        public init(rate: String, date: String) { self.rate = rate; self.date = date }
    }
    public struct Context: Sendable, Codable {
        public let currency: String, rates: [String: Rate], staleCurrencies: [String]
        public init(currency: String, rates: [String: Rate] = [:], staleCurrencies: [String] = []) {
            self.currency = currency; self.rates = rates; self.staleCurrencies = staleCurrencies
        }
    }
    public struct Conversion: Equatable, Sendable {
        public let amount: String?, missing: [String], dates: [String], complete: Bool
    }
    public static func fractionDigits(_ currency: String) -> Int {
        if ["AFN", "ALL", "BIF", "CLP", "COP", "DJF", "GNF", "HUF", "IDR", "IQD", "IRR", "ISK", "JPY", "KMF", "KPW", "KRW", "LAK", "LBP", "MGA", "MMK", "PKR", "PYG", "RWF", "SLL", "SOS", "SYP", "UGX", "UYI", "VND", "VUV", "XAF", "XOF", "XPF", "YER"].contains(currency) { return 0 }
        if ["BHD", "JOD", "KWD", "LYD", "OMR", "TND"].contains(currency) { return 3 }
        if ["CLF", "UYW"].contains(currency) { return 4 }
        return 2
    }
    public static func convert(_ amounts: [Amount], context: Context) -> Conversion {
        var sum = ReportDecimal.zero, converted = 0, missing: [String] = [], dates = Set<String>()
        for item in amounts {
            guard let amount = ReportDecimal(item.amount) else { missing.append(item.currency); continue }
            if item.currency == context.currency || amount.isZero { sum = sum.adding(amount); converted += 1; continue }
            guard let quote = context.rates[item.currency], let rate = ReportDecimal(quote.rate), !rate.negative, !rate.isZero else { missing.append(item.currency); continue }
            sum = sum.adding(amount.divided(by: rate)); dates.insert(quote.date); converted += 1
        }
        return Conversion(amount: converted == 0 ? nil : sum.fixed(fractionDigits(context.currency)), missing: missing, dates: dates.sorted(), complete: !amounts.isEmpty && missing.isEmpty)
    }
    public static func label(_ amount: String?, currency: String) -> String {
        guard let amount, let value = ReportDecimal(amount) ?? ReportDecimal.scientific(amount) else { return "—" }
        let parts = value.fixed(max(fractionDigits(currency), value.fractionPlaces)).split(separator: ".", omittingEmptySubsequences: false)
        let integer = String(parts[0]), negative = integer.hasPrefix("-"), digits = negative ? String(integer.dropFirst()) : integer
        let grouped = digits.enumerated().map { index, character in (index > 0 && (digits.count - index) % 3 == 0 ? "," : "") + String(character) }.joined()
        return currency + " " + (negative ? "-" : "") + grouped + (parts.count == 2 ? "." + parts[1] : "")
    }
}

/// Decimal arithmetic with 50 significant digits and half-up rounding for report amounts.
struct ReportDecimal: Equatable, Sendable {
    let negative: Bool, digits: [UInt8], scale: Int
    static let zero = ReportDecimal(negative: false, digits: [0], scale: 0)
    var isZero: Bool { digits == [0] }
    var fractionPlaces: Int { max(0, scale) }
    init?(_ text: String) {
        guard text.range(of: #"\A-?(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)\z"#, options: .regularExpression) != nil else { return nil }
        let bytes = Array(text.utf8), negative = bytes.first == 45, start = negative ? 1 : 0
        let point = bytes.firstIndex(of: 46)
        self.init(negative: negative, digits: bytes[start...].filter { $0 != 46 }.map { $0 - 48 }, scale: point.map { bytes.count - $0 - 1 } ?? 0)
    }
    static func scientific(_ text: String) -> ReportDecimal? {
        let parts = text.split(separator: "e", omittingEmptySubsequences: false)
        guard parts.count == 2, let value = ReportDecimal(String(parts[0])), let exponent = Int(parts[1]), (-100_000...100_000).contains(exponent) else { return nil }
        return ReportDecimal(negative: value.negative, digits: value.digits, scale: value.scale - exponent)
    }
    private init(negative: Bool, digits: [UInt8], scale: Int) {
        var digits = Self.trim(digits), scale = scale
        while digits.count > 1 && digits.last == 0 { digits.removeLast(); scale -= 1 }
        self.negative = negative && digits != [0]; self.digits = digits; self.scale = digits == [0] ? 0 : scale
    }
    private static func trim(_ value: [UInt8]) -> [UInt8] {
        guard let start = value.firstIndex(where: { $0 != 0 }) else { return [0] }; return Array(value[start...])
    }
    private static func compare(_ a: [UInt8], _ b: [UInt8]) -> Int {
        if a.count != b.count { return a.count < b.count ? -1 : 1 }
        if a == b { return 0 }; return a.lexicographicallyPrecedes(b) ? -1 : 1
    }
    private static func plus(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
        var result: [UInt8] = [], carry = 0
        for offset in 0..<max(a.count, b.count) {
            let value = (offset < a.count ? Int(a[a.count - offset - 1]) : 0) + (offset < b.count ? Int(b[b.count - offset - 1]) : 0) + carry
            result.append(UInt8(value % 10)); carry = value / 10
        }
        if carry != 0 { result.append(UInt8(carry)) }; return Array(result.reversed())
    }
    private static func minus(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
        var result: [UInt8] = [], borrow = 0
        for offset in 0..<a.count {
            let value = Int(a[a.count - offset - 1]) - (offset < b.count ? Int(b[b.count - offset - 1]) : 0) - borrow
            result.append(UInt8(value < 0 ? value + 10 : value)); borrow = value < 0 ? 1 : 0
        }
        return trim(Array(result.reversed()))
    }
    private func roundedSignificant(_ precision: Int = 50) -> ReportDecimal {
        guard digits.count > precision else { return self }
        let drop = digits.count - precision, kept = Array(digits.prefix(precision)), rounded = digits[precision] >= 5 ? Self.plus(kept, [1]) : kept
        return ReportDecimal(negative: negative, digits: rounded, scale: scale - drop)
    }
    func adding(_ other: ReportDecimal, precision: Int = 50) -> ReportDecimal {
        if isZero { return other.roundedSignificant(precision) }; if other.isZero { return roundedSignificant(precision) }
        let scale = max(scale, other.scale)
        let a = digits + Array(repeating: 0, count: scale - self.scale), b = other.digits + Array(repeating: 0, count: scale - other.scale)
        if negative == other.negative { return ReportDecimal(negative: negative, digits: Self.plus(a, b), scale: scale).roundedSignificant(precision) }
        let order = Self.compare(a, b)
        return ReportDecimal(negative: order >= 0 ? negative : other.negative, digits: order >= 0 ? Self.minus(a, b) : Self.minus(b, a), scale: scale).roundedSignificant(precision)
    }
    func multiplied(by other: ReportDecimal, precision: Int = 50) -> ReportDecimal {
        if isZero || other.isZero { return .zero }
        var product = [Int](repeating: 0, count: digits.count + other.digits.count)
        for a in digits.indices { for b in other.digits.indices { product[a + b + 1] += Int(digits[a]) * Int(other.digits[b]) } }
        for index in stride(from: product.count - 1, through: 1, by: -1) { product[index - 1] += product[index] / 10; product[index] %= 10 }
        return ReportDecimal(negative: negative != other.negative, digits: product.map(UInt8.init), scale: scale + other.scale).roundedSignificant(precision)
    }
    var plain: String { fixed(max(0, scale)) }
    func divided(by other: ReportDecimal, precision: Int = 50) -> ReportDecimal {
        if isZero { return .zero }
        let difference = digits.count - other.digits.count
        let comparison = difference >= 0 ? Self.compare(digits, other.digits + Array(repeating: 0, count: difference)) : Self.compare(digits + Array(repeating: 0, count: -difference), other.digits)
        let exponent = difference - (comparison < 0 ? 1 : 0), shift = precision - 1 - exponent
        let numerator = digits + Array(repeating: 0, count: max(0, shift)), denominator = other.digits + Array(repeating: 0, count: max(0, -shift))
        var remainder: [UInt8] = [0], quotient: [UInt8] = []
        for digit in numerator {
            remainder = Self.trim(remainder + [digit]); var value: UInt8 = 0
            while Self.compare(remainder, denominator) >= 0 { remainder = Self.minus(remainder, denominator); value += 1 }
            quotient.append(value)
        }
        if Self.compare(Self.plus(remainder, remainder), denominator) >= 0 { quotient = Self.plus(quotient, [1]) }
        return ReportDecimal(negative: negative != other.negative, digits: quotient, scale: scale - other.scale + shift)
    }
    func fixed(_ places: Int) -> String {
        let drop = scale - places
        var value: [UInt8]
        if drop > 0 {
            if drop >= digits.count { value = drop == digits.count && digits[0] >= 5 ? [1] : [0] }
            else { let kept = Array(digits.prefix(digits.count - drop)); value = digits[digits.count - drop] >= 5 ? Self.plus(kept, [1]) : kept }
        } else { value = digits + Array(repeating: 0, count: -drop) }
        if value.count <= places { value = Array(repeating: 0, count: places + 1 - value.count) + value }
        var text = String(bytes: value.map { $0 + 48 }, encoding: .utf8)!
        if places > 0 { text.insert(".", at: text.index(text.endIndex, offsetBy: -places)) }
        return (negative ? "-" : "") + text
    }
    var text: String {
        let exponent = digits.count - scale - 1
        if !isZero && (exponent >= 21 || exponent <= -7) {
            let tail = String(bytes: digits.dropFirst().map { $0 + 48 }, encoding: .utf8)!
            return (negative ? "-" : "") + String(digits[0]) + (tail.isEmpty ? "" : "." + tail) + "e" + (exponent >= 0 ? "+" : "") + String(exponent)
        }
        return fixed(max(0, scale))
    }
}
