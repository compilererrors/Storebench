import Foundation

/// Explicit keyword cleanup using the current language's name and subtitle.
public struct SearchLint: Sendable {
    public struct Finding: Identifiable, Sendable {
        public let kind: String, terms: [String], bytes: Int, message: String
        public var id: String { kind }
        public var json: JSONText { .object([("kind", .string(kind)), ("terms", .array(terms.map(JSONText.string))), ("bytes", .number(Double(bytes))), ("message", .string(message))]) }
    }
    public let findings: [Finding], cleaned: String, freedBytes: Int
    public var json: JSONText { .object([("findings", .array(findings.map(\.json))), ("cleaned", .string(cleaned)), ("freedBytes", .number(Double(freedBytes)))]) }
    private static let fillers: Set<String> = ["app", "apps", "the", "and", "a", "an", "of", "for", "with", "iphone", "ipad", "ios", "mac", "macos"]
    private static func normalized(_ text: String) -> String { text.precomposedStringWithCompatibilityMapping.lowercased(with: Locale(identifier: "en_US")) }
    private static func words(_ text: String) -> [String] {
        var words: [String] = [], word = ""
        for scalar in normalized(text).unicodeScalars {
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber, .letterNumber, .otherNumber: word.unicodeScalars.append(scalar)
            default: if !word.isEmpty { words.append(word); word = "" }
            }
        }
        if !word.isEmpty { words.append(word) }; return words
    }
    private static func singular(_ word: String) -> String {
        if word.utf16.count > 4 && word.hasSuffix("ies") { return String(word.dropLast(3)) + "y" }
        if word.utf16.count > 3 && word.hasSuffix("s") && !word.hasSuffix("ss") { return String(word.dropLast()) }
        return word
    }
    public init(_ keywords: String, name: String = "", subtitle: String = "") {
        let terms = keywords.components(separatedBy: ",").map(TextSemantics.trim).filter { !$0.isEmpty }
        var findings: [Finding] = []
        let spacing = keywords.utf8.count - terms.joined(separator: ",").utf8.count
        if spacing > 0 { findings.append(.init(kind: "spacing", terms: [], bytes: spacing, message: "\(spacing) \(spacing == 1 ? "byte is" : "bytes are") spaces or empty entries around commas.")) }
        let title = Set((Self.words(name) + Self.words(subtitle)).map(Self.singular))
        var kept: [String] = [], seen = Set<String>(), singulars = Set<String>(), removed: [String: [String]] = [:]
        for term in terms {
            let key = Self.normalized(term), words = Self.words(term)
            let kind: String?
            if seen.contains(key) { kind = "duplicate" }
            else if !words.isEmpty && words.allSatisfy({ Self.fillers.contains($0) }) { kind = "filler" }
            else if !words.isEmpty && words.allSatisfy({ title.contains(Self.singular($0)) }) { kind = "in-title" }
            else if singulars.contains(words.map(Self.singular).joined(separator: " ")) { kind = "plural" }
            else { kind = nil }
            if let kind { removed[kind, default: []].append(term) }
            else { seen.insert(key); singulars.insert(words.map(Self.singular).joined(separator: " ")); kept.append(term) }
        }
        for kind in ["duplicate", "in-title", "plural", "filler"] {
            guard let terms = removed[kind], !terms.isEmpty else { continue }
            let message: String
            switch kind {
            case "duplicate": message = "\(terms.count == 1 ? "A keyword appears" : "\(terms.count) keywords appear") more than once."
            case "in-title": message = "Already in the app name or subtitle, which Apple indexes too."
            case "plural": message = "Apple matches singular and plural forms; one of them is enough."
            default: message = "Filler words such as “app” or device names add no search reach."
            }
            findings.append(.init(kind: kind, terms: terms, bytes: terms.reduce(0) { $0 + $1.utf8.count + 1 }, message: message))
        }
        self.findings = findings; cleaned = kept.joined(separator: ","); freedBytes = max(0, keywords.utf8.count - cleaned.utf8.count)
    }
}
