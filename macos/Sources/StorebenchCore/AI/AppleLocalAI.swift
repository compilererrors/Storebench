import Foundation
#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26, *) @Generable private struct LocalCardProposal {
    @Guide(description: "Zero-based index of the original screenshot. Use each screenshot exactly once.") var screenshotIndex: Int
    @Guide(description: "Short benefit-led title, at most 60 characters.") var title: String
    @Guide(description: "Optional subtitle, at most 90 characters. Use an empty string when unnecessary.") var subtitle: String
    @Guide(description: "One of textAbove, textBelow, bleedBottom, bleedTop, focus.") var layout: String
    @Guide(description: "Background color as #RRGGBB.") var color: String
    @Guide(description: "Second background color as #RRGGBB.") var secondColor: String
    @Guide(description: "Contrasting text color as #RRGGBB.") var titleColor: String
}
@available(macOS 26, *) @Generable private struct LocalCardProposals {
    @Guide(.maximumCount(10)) var cards: [LocalCardProposal]
}
@available(macOS 26, *) @Generable private struct LocalTranslations {
    @Guide(description: "One translation for each supplied input, in exactly the same order.") var translations: [String]
}
#endif

public enum AppleLocalAI {
    public static var available: Bool {
        guard !Network.testMode else { return false }
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return SystemLanguageModel.default.isAvailable }
        #endif
        return false
    }
    static func generate(_ input: AIRequest) async throws -> JSONText {
        guard available else { throw AIFailure.localUnavailable }
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            if let language = input.language, !SystemLanguageModel.default.supportsLocale(Locale(identifier: language)) { throw AIFailure.languageUnsupported }
            let session = LanguageModelSession(instructions: input.instructions)
            if input.purpose == "cards" {
                let context = input.images.enumerated().map { "Screenshot \($0.offset): \($0.element.text)" }.joined(separator: "\n")
                let response = try await session.respond(to: input.input + "\n" + context, generating: LocalCardProposals.self)
                return .object([("cards", .array(response.content.cards.map { card in
                    .object([("screenshotIndex", .number(Double(card.screenshotIndex))), ("title", .string(card.title)), ("subtitle", .string(card.subtitle)),
                        ("layout", .string(card.layout)), ("color", .string(card.color)), ("secondColor", .string(card.secondColor)), ("titleColor", .string(card.titleColor))])
                }))])
            }
            let response = try await session.respond(to: input.input, generating: LocalTranslations.self)
            return .object([("translations", .array(response.content.translations.map(JSONText.string)))])
        }
        #endif
        throw AIFailure.localUnavailable
    }
}
