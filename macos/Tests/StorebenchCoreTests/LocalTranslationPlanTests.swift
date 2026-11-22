import Foundation
import Testing
@testable import StorebenchCore

@Suite struct LocalTranslationPlanTests {
    init() throws { _ = try TestIsolation.require() }
    private actor Probe {
        var texts: [String] = [], instructions: [String] = []
        func record(_ text: String, instructions: String) -> Int {
            texts.append(text); self.instructions.append(instructions); return texts.count
        }
    }

    /// A long field goes to the on-device model in parts that end at a paragraph or sentence and keep every character in order.
    @Test func longUnicodeFieldsGoInPartsThatKeepTheirOrderAndParagraphs() async throws {
        let body = String(repeating: "Synthetic paragraph with {name}. ", count: 50) + "\n\n" + String(repeating: "漢字🙂", count: 280) + " End."
        let texts = [body, "journal", "notes", "timer", "Synthetic subtitle"]
        let request = try AIRequest.translation(texts, source: "en-US", target: "sv", fields: ["description", "keywords", "keywords", "keywords", "subtitle"])
        let plan = try LocalTranslationPlan(request), probe = Probe()
        #expect(plan.segments[0].fragments.count > 1 && plan.segments.dropFirst().allSatisfy { $0.fragments.count == 1 })
        #expect(plan.segments[0].fragments.map { $0.text + $0.separator }.joined() == body)
        #expect(plan.segments[0].fragments.allSatisfy { $0.text.utf16.count <= LocalTranslationPlan.partLimit("sv") })
        #expect(try #require(plan.segments[0].fragments.first).text.hasSuffix("."), "A part ends at a sentence")
        #expect(!plan.instructions.contains("Return JSON only."))
        #expect(plan.instructions.contains("do not truncate"))
        let result = try await AppleLocalAI.translate(request) { instructions, text in
            _ = await probe.record(text, instructions: instructions); return text
        }
        #expect(try AIRequest.translations(result, count: texts.count) == texts)
        #expect(await probe.texts == plan.segments.flatMap { $0.fragments.map(\.text) }, "Each part is sent once, in order")
        #expect(!AppleLocalAI.available, "Synthetic responders never start the on-device model")
    }

    @Test func anOversizedFragmentIsRetriedWithoutCuttingItsText() async throws {
        let request = try AIRequest.translation(["Synthetic subtitle"], source: "en-US", target: "de-DE", fields: ["subtitle"]), probe = Probe()
        let result = try await AppleLocalAI.translate(request) { instructions, text in
            let call = await probe.record(text, instructions: instructions)
            return call == 1 ? String(repeating: "x", count: 31) : "Synthetic short result"
        }
        #expect(try AIRequest.translations(result, count: 1) == ["Synthetic short result"])
        #expect(await probe.texts == ["Synthetic subtitle", String(repeating: "x", count: 31)])
        #expect(await probe.instructions.last?.contains("uses 31 of 30 characters") == true)
        #expect(await probe.instructions.last?.contains("do not truncate") == true)
    }

    @Test func aLongFieldWithAnOverlongTranslationIsRewordedWholeWithoutSplitting() async throws {
        let source = String(repeating: "Synthetic description. ", count: 40) + "{count} https://example.test/help"
        let request = try AIRequest.translation([source], source: "en-US", target: "sv", fields: ["description"]), probe = Probe()
        let overlong = String(repeating: "x", count: 4001), rewritten = "Syntetisk beskrivning med {count} och https://example.test/help. Hela slutmeningen finns kvar."
        let result = try await AppleLocalAI.translate(request) { instructions, text in
            let call = await probe.record(text, instructions: instructions)
            return call == 1 ? overlong : rewritten
        }
        #expect(try AIRequest.translations(result, count: 1) == [rewritten])
        #expect(await probe.texts == [source, overlong], "An output field limit calls for rewording, not smaller source parts")
        #expect(await probe.instructions.first?.contains("hard maximum of 4000 characters") == true)
        #expect(await probe.instructions.last?.contains("uses 4001 of 4000 characters") == true)
    }

    @Test func spacesAroundParagraphsNeverDependOnModelWhitespace() async throws {
        let text = "  " + String(repeating: "Synthetic paragraph. ", count: 70) + " \n\n\t  " + String(repeating: "More text. ", count: 60) + "End.  \n"
        let request = try AIRequest.translation([text], source: "en-GB", target: "sv", fields: ["description"])
        let plan = try LocalTranslationPlan(request)
        #expect(plan.segments[0].prefix + plan.segments[0].fragments.map { $0.text + $0.separator }.joined() == text)
        #expect(plan.segments.flatMap(\.fragments).allSatisfy { !$0.text.isEmpty && $0.text == TextSemantics.trim($0.text) })
        let result = try await AppleLocalAI.translate(request) { _, input in input }
        #expect(try AIRequest.translations(result, count: 1) == [text])
    }

    @Test func repeatedOverflowHasABoundedActionableFailureAndNoPartialResult() async throws {
        let request = try AIRequest.translation(["Synthetic subtitle", "A later field"], source: "en-US", target: "sv", fields: ["subtitle", "description"]), probe = Probe()
        await #expect(throws: TranslationLengthFailure.self) {
            try await AppleLocalAI.translate(request) { instructions, text in
                _ = await probe.record(text, instructions: instructions); return String(repeating: "x", count: 31)
            }
        }
        #expect(await probe.texts.count == 2 + TranslationFitting.repairRounds, "Two initial fields and one repair of the subtitle per round")
        #expect(AIFailure.translationLength.message.contains("longer than App Store Connect allows"))
    }

    @Test func keywordTermsShareOneByteBudgetIncludingTheirCommas() throws {
        let request = try AIRequest.translation(["journal", "notes", "timer"], source: "en-US", target: "sv", fields: Array(repeating: "keywords", count: 3))
        let plan = try LocalTranslationPlan(request)
        #expect(plan.segments.count == 3)
        let budget = try #require(TranslationBudget.groups(request, count: 3).first)
        #expect(budget.maximum == 100 && budget.used(["å", "🙂", "ä"]) == 10)
        #expect(LocalTranslationPlan.used("å🙂", field: "keywords") == 6)
        #expect(LocalTranslationPlan.used("å🙂", field: "description") == 2)
        let impossible = try AIRequest.translation(Array(repeating: "a", count: 51), source: "en-US", target: "sv", fields: Array(repeating: "keywords", count: 51))
        #expect(throws: AIFailure.translationLength) { try LocalTranslationPlan(impossible) }
    }

    @Test func cancellationIsNeverTurnedIntoAModelRetry() async throws {
        let request = try AIRequest.translation(["Synthetic text"], source: "en-US", target: "sv"), probe = Probe()
        await #expect(throws: CancellationError.self) {
            try await AppleLocalAI.translate(request) { instructions, text in
                _ = await probe.record(text, instructions: instructions); throw CancellationError()
            }
        }
        #expect(await probe.texts.count == 1)
    }

    @Test func aLongHealthyFieldCanUseItsWholeBudgetInOneResponse() async throws {
        let source = String(repeating: "Synthetic sentence. ", count: 50)
        let request = try AIRequest.translation([source], source: "en-US", target: "sv", fields: ["description"])
        let probe = Probe()
        let result = try await AppleLocalAI.translate(request) { instructions, text in
            let count = await probe.record(text, instructions: instructions)
            return count == 1 ? String(repeating: "å", count: 2000) : "Kort mening."
        }
        let translated = try #require(AIRequest.translations(result, count: 1).first)
        #expect(translated.hasPrefix(String(repeating: "å", count: 2000)))
        #expect(translated.unicodeScalars.count < 4000)
        #expect(await probe.texts == [TextSemantics.trim(source)], "A longer translation that fits the field needs no split or repair")
    }

    @Test func unevenKeywordTermsUseTheirCombinedByteBudget() async throws {
        let request = try AIRequest.translation(["one", "two", "three"], source: "en-US", target: "sv", fields: Array(repeating: "keywords", count: 3))
        let probe = Probe(), translated = [String(repeating: "å", count: 40), "b", "c"]
        let result = try await AppleLocalAI.translate(request) { instructions, text in
            let count = await probe.record(text, instructions: instructions); return translated[count - 1]
        }
        #expect(try AIRequest.translations(result, count: 3) == translated)
        #expect(await probe.texts.count == 3)
    }

    @Test func completeFieldOverflowRewordsOnlyAsMuchAsNeeded() async throws {
        let request = try AIRequest.translation(["one", "two"], source: "en-US", target: "sv", fields: ["keywords", "keywords"]), probe = Probe()
        let first = String(repeating: "å", count: 40), second = String(repeating: "b", count: 30)
        let result = try await AppleLocalAI.translate(request) { instructions, text in
            let count = await probe.record(text, instructions: instructions)
            return count == 1 ? first : count == 2 ? second : String(repeating: "å", count: 30)
        }
        #expect(try AIRequest.translations(result, count: 2) == [String(repeating: "å", count: 30), second])
        #expect(await probe.texts == ["one", "two", first])
    }

    @Test func onlyAContextErrorSplitsAWholeFieldAndKeepsAllSourceText() async throws {
        let source = "  " + String(repeating: "Synthetic sentence {count}. ", count: 60) + "\n\nEnd. "
        let request = try AIRequest.translation([source], source: "en-US", target: "sv", fields: ["description"]), probe = Probe()
        let result = try await AppleLocalAI.translate(request) { instructions, text in
            _ = await probe.record(text, instructions: instructions)
            if text.utf16.count > 300 { throw AIFailure.tooLarge }
            return text
        }
        #expect(try AIRequest.translations(result, count: 1) == [source])
        // A field longer than one on-device part goes in parts that end at a sentence, before any request fails.
        let first = try #require(await probe.texts.first)
        #expect(first.utf16.count <= LocalTranslationPlan.partLimit("sv") && first.hasSuffix("."), "Parts end at a sentence: \(first.suffix(20))")
        #expect(await probe.texts.count > 3)
    }

    /// A malformed answer is asked for again; other failures stop at once. Neither splits the part further.
    @Test(arguments: [AIFailure.localBusy, .localRejected, .response, .localFailed])
    func nonContextFailuresNeverSplitOrRetryAWholeField(_ failure: AIFailure) async throws {
        let source = String(repeating: "Synthetic text. ", count: 50)
        let request = try AIRequest.translation([source], source: "en-US", target: "sv", fields: ["description"]), probe = Probe()
        await #expect(throws: failure) {
            try await AppleLocalAI.translate(request) { instructions, text in
                _ = await probe.record(text, instructions: instructions); throw failure
            }
        }
        #expect(await probe.texts == Array(repeating: TextSemantics.trim(source), count: failure == .response ? TranslationFitting.answerAttempts : 1))
    }

    @Test func nativeBusyAndUnrecoverableContextErrorsAreBounded() async throws {
        let request = try AIRequest.translation([String(repeating: "Synthetic text. ", count: 50)], source: "en-US", target: "sv")
        let probe = Probe()
        await #expect(throws: AIFailure.localBusy) {
            try await AppleLocalAI.translate(request) { instructions, text in
                _ = await probe.record(text, instructions: instructions); throw AIFailure.localBusy
            }
        }
        #expect(await probe.texts.count == 1)
        let context = Probe()
        await #expect(throws: AIFailure.tooLarge) {
            try await AppleLocalAI.translate(request) { instructions, text in
                _ = await context.record(text, instructions: instructions); throw AIFailure.tooLarge
            }
        }
        // A context error splits the part a bounded number of times: the part and at most five smaller halves.
        #expect(await context.texts.count <= 6)
    }

    @Test func batchSummariesDistinguishFailureSuccessAndPreservedText() {
        #expect(LanguageTranslation.summary([.failed, .failed]) == "No languages were translated. 2 failed. Your saved text is unchanged.")
        #expect(LanguageTranslation.summary([.saved, .failed]).contains("1 failed; retry"))
        #expect(LanguageTranslation.summary([.saved, .skipped]).contains("1 skipped"))
        #expect(LanguageTranslation.summary([.skipped]).contains("Existing text was preserved"))
    }

    @Test func eachTranslatedPartAndEachShorteningRoundIsReported() async throws {
        let request = try AIRequest.translation(["Synthetic subtitle", "Synthetic promotion"], source: "en-US", target: "sv", fields: ["subtitle", "promotionalText"])
        final class Steps: @unchecked Sendable { let lock = NSLock(); var values: [AITranslationStep] = []; func add(_ step: AITranslationStep) { lock.withLock { values.append(step) } } }
        let steps = Steps(), probe = Probe()
        _ = try await AITranslationProgress.$report.withValue({ steps.add($0) }) {
            try await AppleLocalAI.translate(request) { instructions, text in
                let call = await probe.record(text, instructions: instructions)
                return call == 1 ? String(repeating: "x", count: 31) : "Kort text"
            }
        }
        let values = steps.lock.withLock { steps.values }
        #expect(values.prefix(3).map(\.done) == [0, 1, 2] && values.allSatisfy { $0.total == 2 })
        #expect(values.contains { if case .shortening(let field, 0, _) = $0.phase { return field == "Subtitle" }; return false })
        // The bar only moves forward.
        #expect(zip(values, values.dropFirst()).allSatisfy { $0.fraction <= $1.fraction })
    }

    @Test func aTranslationThatCannotSayEverythingMayDropADetailInLaterRounds() async throws {
        let request = try AIRequest.translation(["Synthetic promotion"], source: "en-US", target: "sv", fields: ["promotionalText"]), probe = Probe()
        // A model that only fits once it is allowed to leave out a minor detail, as long Swedish promotions often need.
        let result = try await AppleLocalAI.translate(request) { instructions, text in
            _ = await probe.record(text, instructions: instructions)
            return instructions.contains("leave out the least important detail") ? "Kort svensk kampanjtext." : String(repeating: "å", count: 195)
        }
        #expect(try AIRequest.translations(result, count: 1) == ["Kort svensk kampanjtext."])
        let instructions = await probe.instructions
        #expect(instructions.dropFirst().first?.contains("do not truncate") == true, "Early rounds keep every fact")
        #expect(instructions.last?.contains("never cut text off mid-sentence") == true)
        // Each round aims lower than the last.
        #expect(TranslationFitting.targetShare(round: 0) > TranslationFitting.targetShare(round: 1) && TranslationFitting.targetShare(round: 4) >= 50)
    }

    @Test func translationStepsDescribeTheWorkInPlainWords() {
        #expect(AITranslationStep(done: 0, total: 1).text == "Translating…")
        #expect(AITranslationStep(done: 1, total: 4).text == "Translating part 2 of 4…")
        #expect(AITranslationStep(done: 4, total: 4, phase: .shortening(field: "Promotional Text", round: 1, rounds: 5)).text == "Shortening Promotional Text to fit the App Store limit, try 2…")
        #expect(AITranslationStep(done: 2, total: 4).fraction == 0.425 && AITranslationStep(done: 9, total: 4).done == 4)
    }
}
