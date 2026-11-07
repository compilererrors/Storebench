import StorebenchCore
import SwiftUI
import Translation

/// One requested translation between two App Store languages.
struct ListingTranslationRequest: Equatable {
    let id = UUID()
    let source: String, target: String
}

/// Apple's on-device translation for App Store languages, used for listing text and card text. The system asks before it downloads a language.
enum ListingTranslation {
    /// The Translation framework's language for an App Store language code.
    static func language(_ code: String) -> Locale.Language {
        Locale.Language(identifier: code == "no" ? "nb" : code)
    }

    /// The sources that can be translated into the target on this Mac, including languages the system can still download.
    static func translatableSources(_ sources: [String], target: String) async -> Set<String> {
        guard #available(macOS 15, *), !target.isEmpty else { return [] }
        let availability = LanguageAvailability()
        var result = Set<String>()
        for source in sources where source != target {
            if await availability.status(from: language(source), to: language(target)) != .unsupported { result.insert(source) }
        }
        return result
    }

    /// The targets the source can be translated into on this Mac, in the order given.
    static func translatableTargets(from source: String, among targets: [String]) async -> [String] {
        guard #available(macOS 15, *), !source.isEmpty else { return [] }
        let availability = LanguageAvailability()
        var result: [String] = []
        for target in targets where target != source {
            if await availability.status(from: language(source), to: language(target)) != .unsupported { result.append(target) }
        }
        return result
    }
}

extension View {
    /// Runs `perform` with a translator for the requested pair, then clears the request through `finished`.
    func listingTranslation(_ request: ListingTranslationRequest?, perform: @escaping (ListingTranslationRequest, @escaping TextTranslator) async -> Void,
                            finished: @escaping () -> Void) -> some View {
        modifier(ListingTranslationModifier(request: request, perform: perform, finished: finished))
    }
}

private struct ListingTranslationModifier: ViewModifier {
    let request: ListingTranslationRequest?
    let perform: (ListingTranslationRequest, @escaping TextTranslator) async -> Void
    let finished: () -> Void

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.modifier(ListingTranslationTask(request: request, perform: perform, finished: finished))
        } else {
            content
        }
    }
}

@available(macOS 15, *)
private struct ListingTranslationTask: ViewModifier {
    let request: ListingTranslationRequest?
    let perform: (ListingTranslationRequest, @escaping TextTranslator) async -> Void
    let finished: () -> Void

    func body(content: Content) -> some View {
        content.translationTask(request.map { TranslationSession.Configuration(source: ListingTranslation.language($0.source), target: ListingTranslation.language($0.target)) }) { session in
            guard let request else { return }
            let owned = OwnedSession(session: session)
            await perform(request) { texts in try await Self.translate(texts, with: owned) }
            finished()
        }
    }

    /// The session handed to this task. Only this task uses it, one call at a time, while the task runs.
    private struct OwnedSession: @unchecked Sendable { let session: TranslationSession }

    private nonisolated static func translate(_ texts: [String], with owned: OwnedSession) async throws -> [String] {
        guard !texts.isEmpty else { return [] }
        try await owned.session.prepareTranslation()
        let responses = try await owned.session.translations(from: texts.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) })
        var translated = [String?](repeating: nil, count: texts.count)
        for response in responses { if let index = response.clientIdentifier.flatMap(Int.init), translated.indices.contains(index) { translated[index] = response.targetText } }
        return try translated.map { try $0 ?? { throw LanguageFailure.translationFailed }() }
    }
}
