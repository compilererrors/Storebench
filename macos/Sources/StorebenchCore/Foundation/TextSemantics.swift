import Foundation

/// Stable whitespace and text rules for stored text plans and keyword normalization.
enum TextSemantics {
    /// Formats finite JSON numbers with stable decimal/scientific thresholds and shortest text.
    static func number(_ value: Double) -> String? {
        guard value.isFinite else { return nil }
        if value == 0 { return "0" }
        let parts = String(value).lowercased().split(separator: "e", omittingEmptySubsequences: false)
        var mantissa = String(parts[0]); if mantissa.hasSuffix(".0") { mantissa.removeLast(2) }
        guard parts.count == 2, let exponent = Int(parts[1]) else { return mantissa }
        if abs(value) < 1e-6 || abs(value) >= 1e21 { return mantissa + "e" + (exponent >= 0 ? "+" : "") + String(exponent) }
        let negative = mantissa.hasPrefix("-"); if negative { mantissa.removeFirst() }
        let fragments = mantissa.split(separator: ".", omittingEmptySubsequences: false), digits = fragments.joined(), point = fragments[0].count + exponent
        let expanded = point <= 0 ? "0." + String(repeating: "0", count: -point) + digits : point >= digits.count ? digits + String(repeating: "0", count: point - digits.count) : String(digits.prefix(point)) + "." + String(digits.dropFirst(point))
        return (negative ? "-" : "") + expanded
    }

    static let whitespace = CharacterSet(charactersIn: "\u{0009}\u{000a}\u{000b}\u{000c}\u{000d}\u{0020}\u{00a0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200a}\u{2028}\u{2029}\u{202f}\u{205f}\u{3000}\u{feff}")
    private static let invalidTextControls: CharacterSet = {
        var result = CharacterSet(charactersIn: UnicodeScalar(0)!...UnicodeScalar(31)!)
        result.insert(charactersIn: "\u{7f}")
        result.remove(charactersIn: "\t\n\r")
        return result
    }()
    static func validControlText(_ text: String) -> Bool { text.rangeOfCharacter(from: invalidTextControls) == nil }
    static func trim(_ text: String) -> String { text.trimmingCharacters(in: whitespace) }
    static func same(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case (let a?, let b?): a.utf8.count == b.utf8.count && Data(a.utf8) == Data(b.utf8)
        default: false
        }
    }
    /// Listing text as App Store Connect keeps it: one kind of line break, no whitespace at line ends or around the text.
    /// Composed and decomposed characters stay distinct, since Storebench sends the exact characters it compares.
    static func storeText(_ text: String) -> String {
        var unified = text
        for separator in ["\r\n", "\r", "\u{2028}", "\u{2029}"] { unified = unified.replacingOccurrences(of: separator, with: "\n", options: .literal) }
        let lines = unified.components(separatedBy: "\n").map { line -> String in
            var scalars = Array(line.unicodeScalars)
            while let last = scalars.last, whitespace.contains(last) { scalars.removeLast() }
            var view = String.UnicodeScalarView(); view.append(contentsOf: scalars); return String(view)
        }
        return trim(lines.joined(separator: "\n"))
    }
    static func sameStoreText(_ lhs: String?, _ rhs: String?) -> Bool { same(lhs.map(storeText), rhs.map(storeText)) }
    static func pathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()"))!
    }
    static func words(_ text: String) -> String {
        var result = "", space = false
        for scalar in trim(text).unicodeScalars {
            if whitespace.contains(scalar) { if !space { result.append(" ") }; space = true }
            else { result.unicodeScalars.append(scalar); space = false }
        }
        return result
    }
}
