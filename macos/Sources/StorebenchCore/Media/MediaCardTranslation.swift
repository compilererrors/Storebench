import Foundation

/// A card set in another language: the same cards, style, layout and screenshots, with translated text.
public enum MediaCardTranslation {
    private static var fields: [WritableKeyPath<MediaCard, String>] { [\.title, \.subtitle, \.body] }
    private static let limits = [MediaCards.titleLimit, MediaCards.subtitleLimit, MediaCards.bodyLimit]

    /// Every card text to translate, card by card in title, subtitle and body order. Empty texts are skipped.
    public static func segments(_ set: MediaCardSet) -> [String] {
        set.cards.flatMap { card in fields.map { card[keyPath: $0] }.filter { !TextSemantics.trim($0).isEmpty } }
    }

    /// The name of the translated set: the source name followed by the language, shortened to fit the name limit.
    public static func name(_ source: String, language: String) -> String {
        let suffix = " · " + StoreLocales.name(language)
        var base = TextSemantics.trim(source)
        while !base.isEmpty, (base + suffix).utf16.count > MediaCards.nameLimit { base.removeLast() }
        return TextSemantics.trim(base) + suffix
    }

    /// A new, unsaved card set with the translated texts. The source set is not changed.
    public static func translated(_ source: MediaCardSet, to language: String, translations: [String]) throws -> MediaCardSet {
        guard StoreLocales.codes.contains(language), language != source.language else { throw MediaCardFailure.invalid }
        guard translations.count == segments(source).count else { throw MediaCardFailure.translation }
        var remaining = translations[...], result = source
        result.id = UUID().uuidString.lowercased(); result.name = name(source.name, language: language)
        result.language = language; result.savedCards = nil
        for index in result.cards.indices {
            result.cards[index].id = UUID().uuidString.lowercased()
            for (field, limit) in zip(fields, limits) where !TextSemantics.trim(result.cards[index][keyPath: field]).isEmpty {
                let text = TextSemantics.trim(remaining.removeFirst())
                guard !text.isEmpty else { throw MediaCardFailure.translation }
                guard MediaCards.validText(text, limit) else { throw MediaCardFailure.translationLength }
                result.cards[index][keyPath: field] = text
            }
        }
        try MediaCards.validate(result)
        return result
    }
}
