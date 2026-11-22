import Foundation
import Testing
@testable import StorebenchCore

@Suite struct TranslationFittingTests {
    init() throws { _ = try TestIsolation.require() }
    private static func result(_ texts: [String]) -> JSONText { .object([("translations", .array(texts.map(JSONText.string)))]) }
    private actor Probe {
        var requests: [AIRequest] = []
        func record(_ request: AIRequest) -> Int { requests.append(request); return requests.count }
    }

    @Test func initialPromptNamesEveryHardCharacterAndSharedByteLimit() throws {
        let fields = ["name", "subtitle", "description", "promotionalText", "whatsNew", "privacyPolicyText", "supportUrl", "keywords", "keywords"]
        let request = try AIRequest.translation(Array(repeating: "Synthetic copy", count: fields.count), source: "en-US", target: "sv", fields: fields)
        for (index, field) in fields.enumerated() where field != "keywords" {
            #expect(request.instructions.contains("Input \(index): \(field), hard maximum \(AIRequest.limit(field)) characters"))
        }
        #expect(request.instructions.contains("Keyword inputs 7, 8 share ONE maximum of 100 UTF-8 bytes"))
        #expect(request.instructions.contains("including one comma between terms"))
        #expect(request.instructions.contains("spaces, punctuation and line breaks"))
        #expect(request.instructions.contains("they are not token limits"))
    }

    @Test func anExpandingTranslationIsRewordedAtTheExactFieldBoundaryWithoutClipping() async throws {
        let request = try AIRequest.translation(["Synthetic description with {count} and https://example.test/help"], source: "en-US", target: "sv", fields: ["description"])
        let probe = Probe(), tooLong = String(repeating: "x", count: 4001), shortened = "Syntetisk beskrivning med {count} och https://example.test/help. Hela slutmeningen finns kvar."
        let value = try await TranslationFitting.generate(request) { input in
            if await probe.record(input) == 1 { return Self.result([tooLong]) }
            #expect(input.instructions.contains("uses 4001 characters; the hard limit is 4000"))
            return Self.result([shortened])
        }
        #expect(try AIRequest.translations(value, count: 1) == [shortened])
        #expect(await probe.requests.count == 2)
    }

    @Test func remoteModelGetsTheWholeListingAndOnlyTheOverflowingFieldIsReworded() async throws {
        let body = String(repeating: "Synthetic sentence with {count}. ", count: 100)
        let request = try AIRequest.translation([body, "Synthetic subtitle", "notes"], source: "en-US", target: "sv", fields: ["description", "subtitle", "keywords"])
        let probe = Probe(), tooLong = "Synthetic subtitle longer than thirty characters"
        let value = try await TranslationFitting.generate(request) { input in
            let count = await probe.record(input)
            if count == 1 {
                #expect(input == request, "The initial remote request must retain all fields and full context")
                return Self.result([body, tooLong, "anteckningar"])
            }
            let repair = try JSONText.parse(Data(input.input.utf8))
            #expect(repair["sourceTexts"] == .array([.string("Synthetic subtitle")]))
            #expect(repair["translations"] == .array([.string(tooLong)]))
            #expect(input.translationFields == ["subtitle"] && input.language == "sv")
            #expect(input.instructions.contains("do not truncate"))
            return Self.result(["Kort syntetisk text"])
        }
        #expect(try AIRequest.translations(value, count: 3) == [body, "Kort syntetisk text", "anteckningar"])
        #expect(await probe.requests.count == 2)
    }

    @Test func remoteKeywordRepairCountsCombinedUTF8BytesAndPreservesOtherFields() async throws {
        let request = try AIRequest.translation(["one", "two", "Synthetic description"], source: "en-US", target: "sv", fields: ["keywords", "keywords", "description"])
        #expect(request.instructions.contains("share ONE maximum of 100 UTF-8 bytes"))
        let probe = Probe(), initial = String(repeating: "å", count: 30)
        let value = try await TranslationFitting.generate(request) { input in
            let count = await probe.record(input)
            if count == 1 { return Self.result([initial, initial, "Syntetisk beskrivning"] ) }
            #expect(input.translationFields == ["keywords", "keywords"])
            #expect(input.instructions.contains("uses 121 UTF-8 bytes"))
            return Self.result([String(repeating: "å", count: 15), String(repeating: "ä", count: 30)])
        }
        #expect(try AIRequest.translations(value, count: 3) == [String(repeating: "å", count: 15), String(repeating: "ä", count: 30), "Syntetisk beskrivning"])
        #expect(await probe.requests.count == 2)
    }

    @Test func healthyRemoteListingNeedsExactlyOneRequest() async throws {
        let request = try AIRequest.translation(["Synthetic source"], source: "en-US", target: "sv", fields: ["description"]), probe = Probe()
        let value = try await TranslationFitting.generate(request) { input in
            _ = await probe.record(input); return Self.result(["Syntetisk text"])
        }
        #expect(value == Self.result(["Syntetisk text"]))
        #expect(await probe.requests.count == 1)
    }

    @Test func cardUTF16LimitsDoNotShortenHealthyListingUnicode() async throws {
        let request = try AIRequest.translation(["Synthetic body", "Synthetic title"], source: "en-US", target: "sv", fields: ["description", "card-title"])
        let emoji = String(repeating: "🙂", count: MediaCards.titleLimit / 2 + 1), probe = Probe()
        let value = try await TranslationFitting.generate(request) { input in
            if await probe.record(input) == 1 { return Self.result([emoji, emoji]) }
            #expect(input.translationFields == ["card-title"])
            #expect(input.instructions.contains("UTF-16 code units"))
            return Self.result(["Syntetisk titel"])
        }
        #expect(try AIRequest.translations(value, count: 2) == [emoji, "Syntetisk titel"])
    }

    @Test func repairIsBoundedAndNamesTheSpecificLimitWithoutExposingText() async throws {
        let request = try AIRequest.translation(["Synthetic subtitle"], source: "en-US", target: "sv", fields: ["subtitle"]), probe = Probe()
        do {
            _ = try await TranslationFitting.generate(request) { input in
                _ = await probe.record(input); return Self.result([String(repeating: "z", count: 31)])
            }
            Issue.record("An oversized translation cannot become a result")
        } catch let failure as TranslationLengthFailure {
            #expect(failure.field == "Subtitle" && failure.used == 31 && failure.maximum == 30)
            #expect(AIFailure.message(failure).contains("The translated Subtitle is 31 characters and App Store Connect allows 30"))
            #expect(!AIFailure.message(failure).contains("still"))
            #expect(!AIFailure.message(failure).contains("Synthetic"))
        }
        #expect(await probe.requests.count == 1 + TranslationFitting.repairRounds)
    }

    @Test func malformedRepairIsRetriedWithoutReplacingValidFields() async throws {
        let request = try AIRequest.translation(["Synthetic subtitle", "Synthetic body"], source: "en-US", target: "sv", fields: ["subtitle", "description"]), probe = Probe()
        let value = try await TranslationFitting.generate(request) { input in
            switch await probe.record(input) {
            case 1: Self.result([String(repeating: "x", count: 31), "Beskrivning"])
            case 2: Self.result([])
            default: Self.result(["Kort text"])
            }
        }
        #expect(try AIRequest.translations(value, count: 2) == ["Kort text", "Beskrivning"])
        #expect(await probe.requests.count == 3)
    }

    @Test(arguments: ["", "   ", "\n\t"])
    func emptyKeywordRepairsCannotSilentlyRemoveATerm(_ empty: String) async throws {
        let request = try AIRequest.translation(["one", "two"], source: "en-US", target: "sv", fields: ["keywords", "keywords"]), probe = Probe()
        let long = String(repeating: "å", count: 30)
        let value = try await TranslationFitting.generate(request) { input in
            switch await probe.record(input) {
            case 1: Self.result([long, long])
            case 2: Self.result([long, empty])
            default: Self.result(["syntetisk", "anteckning"])
            }
        }
        #expect(try AIRequest.translations(value, count: 2) == ["syntetisk", "anteckning"])
        #expect(await probe.requests.count == 3)
    }

    @Test(arguments: [AIFailure.quota, .credentials, .changed, .unavailable])
    func providerFailuresDuringRepairAreNeverRetriedOrChangedToLengthErrors(_ failure: AIFailure) async throws {
        let request = try AIRequest.translation(["Synthetic subtitle"], source: "en-US", target: "sv", fields: ["subtitle"]), probe = Probe()
        await #expect(throws: failure) {
            try await TranslationFitting.generate(request) { input in
                if await probe.record(input) == 1 { return Self.result([String(repeating: "x", count: 31)]) }
                throw failure
            }
        }
        #expect(await probe.requests.count == 2)
    }

    @Test func cancellationDuringRepairStopsImmediately() async throws {
        let request = try AIRequest.translation(["Synthetic subtitle"], source: "en-US", target: "sv", fields: ["subtitle"]), probe = Probe()
        await #expect(throws: CancellationError.self) {
            try await TranslationFitting.generate(request) { input in
                if await probe.record(input) == 1 { return Self.result([String(repeating: "x", count: 31)]) }
                throw CancellationError()
            }
        }
        #expect(await probe.requests.count == 2)
    }

    /// A synthetic Swedish description over the 4,000 character limit, in paragraphs with a heading, like a real listing.
    private static func longDescription() -> String {
        let sentence = { (n: Int) in "Syntetisk mening nummer \(n) beskriver en funktion i appen med flera ord för att fylla ut texten ordentligt." }
        let first = (0..<14).map(sentence).joined(separator: " ")
        let second = (14..<28).map(sentence).joined(separator: " ")
        let third = (28..<42).map(sentence).joined(separator: " ")
        return first + "\n\nSYNTETISK RUBRIK\n" + second + "\n\nANDRA RUBRIKEN\n" + third
    }

    @Test func aFieldThatRewordingCannotShortenLeavesOutWholeClosingSentencesAndFits() async throws {
        let text = Self.longDescription(), limit = AIRequest.limit("description")
        #expect(text.unicodeScalars.count > limit)
        let request = try AIRequest.translation(["Synthetic description"], source: "en-GB", target: "sv", fields: ["description"])
        let steps = Steps()
        // The model returns the same overlong text every round.
        let value = try await AITranslationProgress.$report.withValue({ step in steps.add(step) }) {
            try await TranslationFitting.generate(request) { _ in Self.result([text]) }
        }
        let fitted = try #require(try AIRequest.translations(value, count: 1).first)
        #expect(fitted.unicodeScalars.count <= limit)
        // Only whole sentences from the end are gone: the result is the start of the text and ends with a full sentence.
        #expect(text.hasPrefix(fitted) && fitted.hasSuffix("."))
        #expect(fitted.contains("SYNTETISK RUBRIK"))
        let left = try #require(steps.all.compactMap { step -> Int? in if case .leftOut(let field, let sentences, 4_000, "characters") = step.phase, field == "Description" { sentences } else { nil } }.first)
        #expect(left > 0)
        #expect(steps.all.last?.text.hasPrefix("Description: the last") == true && steps.all.last?.text.contains("left out to fit") == true)
    }

    @Test func aHeadingIsNeverLeftWithoutItsTextAndTheFirstSentenceStays() throws {
        let text = "First synthetic sentence. Second synthetic sentence.\n\nSYNTHETIC HEADING\nOnly sentence under the heading."
        let fitted = try #require(TranslationFitting.leavingOutClosingSentences(text, field: "promotionalText", maximum: 60))
        #expect(fitted.text == "First synthetic sentence. Second synthetic sentence.")
        #expect(fitted.omitted == 1)
        let tight = try #require(TranslationFitting.leavingOutClosingSentences(text, field: "promotionalText", maximum: 30))
        #expect(tight.text == "First synthetic sentence.")
        // One sentence that is too long by itself is never cut, and keyword lists are never shortened this way.
        #expect(TranslationFitting.leavingOutClosingSentences("One synthetic sentence that is far too long.", field: "subtitle", maximum: 10) == nil)
        #expect(TranslationFitting.leavingOutClosingSentences("synthetic,keywords,list", field: "keywords", maximum: 5) == nil)
    }

    @Test func theLocalModelAlsoFitsByLeavingOutClosingSentences() async throws {
        let text = Self.longDescription(), limit = AIRequest.limit("description")
        let request = try AIRequest.translation([text], source: "en-GB", target: "sv", fields: ["description"])
        let value = try await AppleLocalAI.translate(request) { _, input in input }
        let fitted = try #require(try AIRequest.translations(value, count: 1).first)
        #expect(fitted.unicodeScalars.count <= limit && text.hasPrefix(fitted))
    }

    final class Steps: @unchecked Sendable {
        private let lock = NSLock(); private var steps: [AITranslationStep] = []
        func add(_ step: AITranslationStep) { lock.withLock { steps.append(step) } }
        var all: [AITranslationStep] { lock.withLock { steps } }
    }

    // MARK: Keywords

    @Test func repeatedKeywordsAreLeftOutAndTheRestKeepTheirOrderWithoutSpaces() throws {
        let fitted = try #require(TranslationFitting.fittedKeywords([" Anteckning ", "dagbok", "anteckning", "Dagbok", "timer"], maximum: 100, alsoIndexed: []))
        #expect(fitted.terms == ["Anteckning", "dagbok", "", "", "timer"])
        #expect(fitted.repeated == 2 && fitted.indexed == 0 && fitted.last == 0)
        #expect(TranslationFitting.joinedKeywords(fitted.terms) == "Anteckning,dagbok,timer")
    }

    @Test func wordsAlreadyInTheNameOrSubtitleGoFirstOnlyWhenTheListIsTooLong() throws {
        let terms = ["kubernetes", "kluster", "terminal", "loggar"]
        // Within the limit nothing is removed, even though the name has "Kubernetes".
        let roomy = try #require(TranslationFitting.fittedKeywords(terms, maximum: 100, alsoIndexed: ["Rune Kubernetes-klient", "Kluster och loggar"]))
        #expect(roomy.terms == terms && roomy.indexed == 0)
        // Over the limit, the terms Apple already indexes from the name and subtitle go before any other.
        let tight = try #require(TranslationFitting.fittedKeywords(terms, maximum: 20, alsoIndexed: ["Rune Kubernetes", "Kluster och loggar"]))
        // Only as many as needed go, from the end: "loggar" and "kluster" are enough here.
        #expect(tight.terms == ["kubernetes", "", "terminal", ""])
        #expect(TranslationFitting.joinedKeywords(tight.terms).utf8.count <= 20)
        #expect(tight.indexed == 2 && tight.last == 0)
    }

    @Test func theLastKeywordsAreLeftOutWholeUntilTheListFitsItsBytes() throws {
        // Swedish letters such as å and ö take two bytes each.
        let terms = ["översättning", "skärmdumpar", "nyckelord", "försäljning", "intäkter", "recensioner", "lansering", "prissättning", "språkversioner", "användare"]
        let joined = terms.joined(separator: ",")
        #expect(joined.utf8.count > 100)
        let fitted = try #require(TranslationFitting.fittedKeywords(terms, maximum: 100, alsoIndexed: []))
        let result = TranslationFitting.joinedKeywords(fitted.terms)
        #expect(result.utf8.count <= 100)
        // Kept terms are whole, in their original order, and only terms from the end are gone.
        let kept = fitted.terms.filter { !$0.isEmpty }
        #expect(kept == Array(terms.prefix(kept.count)) && fitted.last == terms.count - kept.count && fitted.last > 0)
        // One term longer than the whole field is never cut.
        #expect(TranslationFitting.fittedKeywords([String(repeating: "å", count: 60)], maximum: 100, alsoIndexed: []) == nil)
    }

    @Test func anOverlongTranslatedKeywordListFitsAndSaysWhatWasLeftOut() async throws {
        let sources = ["kubernetes", "cluster", "logs", "terminal", "pods", "deployments", "namespaces", "monitoring", "devops", "containers", "helm", "yaml"]
        let request = try AIRequest.translation(["Rune Kubernetes Client", "Clusters and logs"] + sources, source: "en-US", target: "sv",
                                                fields: ["name", "subtitle"] + Array(repeating: "keywords", count: sources.count))
        let swedish = ["kubernetes", "kluster", "loggar", "terminalfönster", "poddar", "driftsättningar", "namnrymder", "övervakning", "devops", "behållare", "helm", "yaml"]
        let steps = Steps(), probe = Probe()
        // The model keeps returning the same long list, so the last step has to fit it.
        let value = try await AITranslationProgress.$report.withValue({ step in steps.add(step) }) {
            try await TranslationFitting.generate(request) { input in
                _ = await probe.record(input)
                return input.translationFields?.allSatisfy { $0 == "keywords" } == true ? Self.result(swedish) : Self.result(["Rune Kubernetes-klient", "Kluster och loggar"] + swedish)
            }
        }
        let fields = request.translationFields
        let texts = try AIRequest.translations(value, count: 2 + sources.count, fields: fields)
        let keywords = TranslationFitting.joinedKeywords(Array(texts.dropFirst(2)))
        #expect(keywords.utf8.count <= 100 && !keywords.isEmpty)
        #expect(!keywords.split(separator: ",").contains("kluster") && !keywords.split(separator: ",").contains("loggar"))
        // At most two shortening rounds ask the model, since leaving out terms finishes the job.
        #expect(await probe.requests.count <= 3)
        let note = try #require(steps.all.last { if case .keywordsLeftOut = $0.phase { true } else { false } })
        #expect(note.text.hasPrefix("Keywords:") && note.text.contains("100 bytes") && !note.text.contains("sentence"))
        // Model answers themselves never get to leave a keyword empty.
        #expect(throws: AIFailure.response) { try AIRequest.translations(Self.result(["", "två"]), count: 2) }
    }

    @Test func translationsAskForNativeCopyRatherThanWordForWordInTheFirstLine() throws {
        let request = try AIRequest.translation(["Diagnose failing pods with logs, YAML and events in one app."], source: "en-US", target: "sv", fields: ["promotionalText"])
        // The on-device model receives only the first line, so the guidance must be there.
        let first = String(request.instructions.split(separator: "\n", maxSplits: 1).first ?? "")
        #expect(first.contains("English (U.S.) (en-US) to Swedish (sv)"))
        #expect(first.contains("native Swedish App Store copywriter") && first.contains("never a word-for-word rendering"))
        #expect(first.contains("technical terms"))
    }

    // MARK: Short phrases

    @Test func aSubtitleThatIsStillTooLongLeavesOutItsLastWholeWordsAndNothingHangs() {
        let fitted = TranslationFitting.leavingOutClosingWords("Schneller Texteditor für Entwickler und Teams", field: "subtitle", maximum: 30)
        #expect(fitted == "Schneller Texteditor")
        #expect(TranslationFitting.leavingOutClosingWords("Logs, YAML & Events – an einem Ort", field: "subtitle", maximum: 30) == "Logs, YAML & Events")
        #expect(TranslationFitting.leavingOutClosingWords("Kurz genug", field: "subtitle", maximum: 30) == "Kurz genug")
        // One word longer than the limit is never cut, and keywords use their own fitting.
        #expect(TranslationFitting.leavingOutClosingWords(String(repeating: "x", count: 31), field: "subtitle", maximum: 30) == nil)
        #expect(TranslationFitting.leavingOutClosingWords("one two three", field: "keywords", maximum: 5) == nil)
        // Text without spaces ends at its last punctuation mark that fits.
        let japanese = TranslationFitting.leavingOutClosingWords("高速なテキストエディタ、開発者向けの軽量ツールです", field: "subtitle", maximum: 14)
        #expect(japanese == "高速なテキストエディタ")
    }

    @Test func aTranslatedSubtitleThatRewordingCannotShortenStillFitsAndSaysSo() async throws {
        let request = try AIRequest.translation(["Fast text editor for developers and teams"], source: "en-US", target: "de-DE", fields: ["subtitle"])
        let steps = Steps()
        let value = try await AITranslationProgress.$report.withValue({ step in steps.add(step) }) {
            try await TranslationFitting.generate(request) { _ in Self.result(["Schneller Texteditor für Entwickler und Teams"]) }
        }
        #expect(try AIRequest.translations(value, count: 1) == ["Schneller Texteditor"])
        #expect(steps.all.contains { if case .wordsLeftOut(let field, 30, "characters") = $0.phase { field == "Subtitle" } else { false } })
    }

    @Test func aMalformedAnswerIsAskedForAgainBeforeTheTranslationFails() async throws {
        let request = try AIRequest.translation(["Synthetic description"], source: "en-US", target: "sv", fields: ["description"]), probe = Probe()
        let value = try await TranslationFitting.generate(request) { input in
            await probe.record(input) == 1 ? .object([("unexpected", .string("Synthetic"))]) : Self.result(["Syntetisk beskrivning"])
        }
        #expect(try AIRequest.translations(value, count: 1) == ["Syntetisk beskrivning"])
        #expect(await probe.requests.count == 2)
        // The on-device path asks again too.
        final class Calls: @unchecked Sendable { private let lock = NSLock(); private var count = 0; func next() -> Int { lock.withLock { count += 1; return count } } }
        let calls = Calls()
        let local = try await AppleLocalAI.translate(request) { _, _ in calls.next() == 1 ? "" : "Syntetisk beskrivning" }
        #expect(try AIRequest.translations(local, count: 1) == ["Syntetisk beskrivning"])
    }
}
