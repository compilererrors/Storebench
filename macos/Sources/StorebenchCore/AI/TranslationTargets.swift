/// The languages Translate Languages fills: a choice that is always shown, with a default that lets it run at once.
public enum TranslationTargets {
    /// The App Store's largest markets by language, offered as one quick choice.
    public static let topMarkets = ["de-DE", "fr-FR", "es-ES", "es-MX", "it", "ja", "ko", "pt-BR", "zh-Hans", "zh-Hant"]

    /// The version's own other languages, or the largest markets when the version has only its source language.
    public static func initial(source: String, inVersion: [String], all: [String]) -> Set<String> {
        let own = Set(inVersion).subtracting([source]).intersection(all)
        return own.isEmpty ? Set(topMarkets.filter { $0 != source && all.contains($0) }) : own
    }

    /// What the Into field shows: the languages by name, or how many when there are more than two.
    public static func summary(_ targets: Set<String>) -> String {
        let names = targets.map(StoreLocales.name).sorted()
        switch names.count {
        case 0: return "Choose Languages"
        case 1, 2: return names.joined(separator: ", ")
        default: return names.prefix(2).joined(separator: ", ") + " and More · \(names.count) Languages"
        }
    }
}
