import Foundation

/// Explicit keyword cleanup using the current language's name and subtitle.
public struct SearchLint: Sendable {
    public struct Finding: Identifiable, Sendable {
        public let kind: String, terms: [String], bytes: Int, message: String
        /// False for a possible overlap, such as another word form, that is shown for you to judge and never removed by Clean Up.
        public var certain = true
        public var id: String { kind }
        public var json: JSONText { .object([("kind", .string(kind)), ("terms", .array(terms.map(JSONText.string))), ("bytes", .number(Double(bytes))), ("message", .string(message))]) }
    }
    public let findings: [Finding], cleaned: String, freedBytes: Int
    /// Words both the app name and the subtitle use, for the language given; App Store search already reads both fields.
    public let nameAndSubtitle: [String]
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
    /// English words whose final "s" is not a plural ending, so they never match a shorter word.
    private static let unpluralized: Set<String> = ["news", "series", "species", "ios", "macos", "tvos", "watchos", "visionos", "bus", "gas", "plus", "bonus", "status",
        "focus", "virus", "campus", "census", "chaos", "canvas", "atlas", "alias", "analysis", "basis", "crisis", "thesis", "emphasis", "physics", "maths", "mathematics",
        "economics", "politics", "athletics", "gymnastics", "graphics", "analytics", "statistics", "glass", "class", "boss", "chess", "dress", "fitness", "business", "less", "yes", "this", "his", "its", "was", "has", "does", "is", "us", "always", "perhaps", "towards"]
    private static func singular(_ word: String) -> String {
        if word.utf16.count > 4 && word.hasSuffix("ies") { return String(word.dropLast(3)) + "y" }
        if word.utf16.count > 3 && word.hasSuffix("s") && !word.hasSuffix("ss") { return String(word.dropLast()) }
        return word
    }
    /// With `locale`, plural forms are matched only for English and never for words such as "news", and a plural match is a possible
    /// overlap that Clean Up leaves in place. Without it, the earlier English-only rules apply to every language.
    public init(_ keywords: String, name: String = "", subtitle: String = "", locale: String? = nil) {
        let english = locale.map { $0.lowercased().hasPrefix("en") } ?? true
        func singular(_ word: String) -> String { !english ? word : locale != nil && Self.unpluralized.contains(word) ? word : Self.singular(word) }
        let terms = keywords.components(separatedBy: ",").map(TextSemantics.trim).filter { !$0.isEmpty }
        var findings: [Finding] = []
        let spacing = keywords.utf8.count - terms.joined(separator: ",").utf8.count
        if spacing > 0 { findings.append(.init(kind: "spacing", terms: [], bytes: spacing, message: "\(spacing) \(spacing == 1 ? "byte is" : "bytes are") spaces or empty entries around commas.")) }
        let titleWords = Self.words(name) + Self.words(subtitle), exactTitle = Set(titleWords), title = Set(titleWords.map(singular))
        var kept: [String] = [], seen = Set<String>(), singulars = Set<String>(), removed: [String: [String]] = [:]
        for term in terms {
            let key = Self.normalized(term), words = Self.words(term)
            let kind: String?
            if seen.contains(key) { kind = "duplicate" }
            else if !words.isEmpty && words.allSatisfy({ Self.fillers.contains($0) }) { kind = "filler" }
            else if !words.isEmpty && words.allSatisfy({ exactTitle.contains($0) }) { kind = "in-title" }
            // With a language, another word form of a title word is only a possible overlap; without one, the earlier rule removes it.
            else if !words.isEmpty && words.allSatisfy({ title.contains(singular($0)) }) { kind = locale == nil ? "in-title" : "title-form" }
            else if singulars.contains(words.map(singular).joined(separator: " ")) { kind = "plural" }
            else { kind = nil }
            // A possible overlap is reported, but the term stays in the cleaned list.
            let possible = (kind == "plural" || kind == "title-form") && locale != nil
            if let kind { removed[kind, default: []].append(term) }
            if kind == nil || possible { seen.insert(key); singulars.insert(words.map(singular).joined(separator: " ")); kept.append(term) }
        }
        for kind in ["duplicate", "in-title", "title-form", "plural", "filler"] {
            guard let terms = removed[kind], !terms.isEmpty else { continue }
            let message: String
            switch kind {
            case "duplicate": message = "\(terms.count == 1 ? "A keyword appears" : "\(terms.count) keywords appear") more than once."
            case "in-title": message = "Already in the app name or subtitle, which Apple indexes too."
            case "plural": message = locale == nil ? "Apple matches singular and plural forms; one of them is enough."
                : "Possibly another form of a keyword already listed. App Store search often matches singular and plural forms; check before removing it."
            case "title-form": message = "Possibly another form of a word in the app name or subtitle. App Store search often matches singular and plural forms; check before removing it."
            default: message = "Filler words such as “app” or device names add no search reach."
            }
            findings.append(.init(kind: kind, terms: terms, bytes: terms.reduce(0) { $0 + $1.utf8.count + 1 }, message: message, certain: !((kind == "plural" || kind == "title-form") && locale != nil)))
        }
        let subtitleWords = Set(Self.words(subtitle).map(singular))
        var shared: [String] = []
        for word in Self.words(name) where !Self.fillers.contains(word) && subtitleWords.contains(singular(word)) && !shared.contains(word) { shared.append(word) }
        nameAndSubtitle = locale == nil ? [] : shared
        self.findings = findings; cleaned = kept.joined(separator: ","); freedBytes = max(0, keywords.utf8.count - cleaned.utf8.count)
    }
}

/// The keyword check as sentences: certain findings with the bytes they free, possible overlaps marked as such, and the app name
/// and subtitle sharing words. Advisory only: it never blocks saving or publishing.
public enum SearchLintPresentation {
    public static func lines(_ lint: SearchLint) -> [String] {
        var lines = lint.findings.map { finding in
            let terms = finding.terms.isEmpty ? "" : " " + finding.terms.joined(separator: ", ")
            return finding.certain ? finding.message + terms + " · \(finding.bytes) bytes" : "Possible overlap: " + finding.message + terms
        }
        if !lint.nameAndSubtitle.isEmpty {
            lines.append("The app name and subtitle both use " + lint.nameAndSubtitle.joined(separator: ", ") + ". App Store search reads both fields, so the subtitle can carry other words.")
        }
        return lines
    }
}
