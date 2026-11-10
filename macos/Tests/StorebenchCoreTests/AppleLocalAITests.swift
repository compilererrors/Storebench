import Foundation
import Testing
@testable import StorebenchCore
#if canImport(FoundationModels)
import FoundationModels
#endif

@Suite struct AppleLocalAITests {
    init() throws { _ = try TestIsolation.require() }

    private func rgb(_ red: Double, _ green: Double, _ blue: Double) -> JSONText {
        .object([("red", .number(red)), ("green", .number(green)), ("blue", .number(blue))])
    }

    private func proposal(_ index: Int, priority: Int = 50) -> JSONText {
        .object([("priority", .number(Double(priority))), ("title", .string("Synthetic Benefit \(index)")), ("subtitle", .string("")),
                 ("layout", .string("textAbove")), ("color", rgb(17, 34, 51)), ("secondColor", rgb(34, 51, 68)), ("titleColor", rgb(255, 255, 255))])
    }

    @Test func eachSelectedScreenshotKeepsItsOwnCardWhilePriorityControlsTheOrder() throws {
        let priorities = [30, 90, 90, 10, 70, 20]
        let response = JSONText.object(priorities.enumerated().map { ("card\($0.offset)", proposal($0.offset, priority: $0.element)) })
        let result = try AppleLocalAI.checkedCardResponse(response, count: 6)
        let cards = try AICards.checked(result, count: 6)
        #expect(cards.compactMap { $0["screenshotIndex"] } == [1, 2, 4, 0, 5, 3].map { .number(Double($0)) })
        for card in cards {
            guard case .number(let index)? = card["screenshotIndex"] else { Issue.record("A generated card lost its screenshot"); continue }
            #expect(card["title"] == .string("Synthetic Benefit \(Int(index))"))
            #expect(card["priority"] == nil)
            #expect(card["color"] == .string("#112233") && card["titleColor"] == .string("#FFFFFF"))
        }
    }

    @Test func localRGBComponentsBecomeHexOnlyAfterStrictValidation() throws {
        let valid = JSONText.object([("card0", proposal(0).setting("color", rgb(0, 128, 255)))])
        let result = try AppleLocalAI.checkedCardResponse(valid, count: 1)
        #expect(try AICards.checked(result, count: 1).first?["color"] == .string("#0080FF"))
        let invalid = [rgb(-1, 0, 0), rgb(0, 256, 0), rgb(0, 0, 0.5), .string("#FFFFFF"),
                       JSONText.object([("red", .number(0)), ("green", .number(0))]),
                       rgb(0, 0, 0).setting("alpha", .number(1)),
                       JSONText.object([("red", .number(0)), ("red", .number(0)), ("blue", .number(0))])]
        for color in invalid {
            let response = JSONText.object([("card0", proposal(0).setting("color", color))])
            #expect(throws: AIFailure.response) { try AppleLocalAI.checkedCardResponse(response, count: 1) }
        }
    }

    @Test func nativeErrorsKeepTheirMeaningWithoutExposingModelDiagnostics() {
        #expect(AppleLocalAI.failure(CancellationError()) == .cancelled)
        #expect(AppleLocalAI.failure(AIFailure.changed) == .changed)
        let unknown = NSError(domain: "SyntheticModelFailure", code: 7, userInfo: [NSLocalizedDescriptionKey: "Synthetic hidden model input"])
        #expect(AppleLocalAI.failure(unknown) == .localFailed)
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            typealias Failure = LanguageModelSession.GenerationError
            let context = Failure.Context(debugDescription: "Synthetic hidden model input")
            let cases: [(Failure, AIFailure)] = [(.exceededContextWindowSize(context), .tooLarge), (.assetsUnavailable(context), .localUnavailable),
                (.unsupportedLanguageOrLocale(context), .languageUnsupported), (.unsupportedGuide(context), .localFormatUnsupported),
                (.decodingFailure(context), .response), (.rateLimited(context), .localBusy), (.concurrentRequests(context), .localBusy),
                (.guardrailViolation(context), .localRejected), (.refusal(.init(transcriptEntries: []), context), .localRejected)]
            for (error, expected) in cases {
                #expect(AppleLocalAI.failure(error) == expected)
                #expect(!AppleLocalAI.failure(error).message.contains(context.debugDescription))
            }
        }
        if #available(macOS 27, *) {
            let errors: [(any Error, AIFailure)] = [
                (LanguageModelError.unsupportedGenerationGuide(.init(schemaName: "Synthetic", debugDescription: "Synthetic hidden model input")), .localFormatUnsupported),
                (LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: "Synthetic hidden model input")), .localBusy),
                (LanguageModelError.refusal(.init(explanation: "Synthetic hidden explanation", debugDescription: "Synthetic hidden model input")), .localRejected),
                (LanguageModelError.contextSizeExceeded(.init(contextSize: 1, tokenCount: 2, debugDescription: "Synthetic hidden model input")), .tooLarge),
                (SystemLanguageModel.Error.assetsUnavailable(.init(debugDescription: "Synthetic hidden model input")), .localUnavailable),
                (LanguageModelSession.Error.concurrentRequests, .localBusy),
                (GeneratedContent.ParsingError(rawContent: "Synthetic hidden model output", debugDescription: "Synthetic hidden model input"), .response)
            ]
            for (error, expected) in errors {
                #expect(AppleLocalAI.failure(error) == expected)
                #expect(!AppleLocalAI.failure(error).message.contains("Synthetic hidden"))
            }
        }
        #endif
    }

    @Test func incompleteExtraAndInvalidLocalFieldsFailWithoutInventingCards() throws {
        let valid = JSONText.object([("card0", proposal(0)), ("card1", proposal(1))])
        let invalid: [JSONText] = [
            .object([("card0", proposal(0))]),
            valid.setting("card2", proposal(2)),
            valid.setting("card1", proposal(1).setting("color", .string("white"))),
            valid.setting("card1", proposal(1).setting("layout", .string("textOnly"))),
            valid.setting("card1", proposal(1).setting("priority", .number(101))),
            valid.setting("card1", proposal(1).setting("priority", .number(0.5))),
            valid.setting("card1", proposal(1).setting("title", .string(""))),
            valid.setting("card1", proposal(1).setting("screenshotIndex", .number(0)))
        ]
        for response in invalid { #expect(throws: AIFailure.response) { try AppleLocalAI.checkedCardResponse(response, count: 2) } }
        for count in [0, 11] { #expect(throws: AIFailure.configuration) { try AppleLocalAI.checkedCardResponse(valid, count: count) } }
    }

    @Test func guidedSchemasAndGeneratedContentBridgeWithoutStartingAModel() throws {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            for count in [1, 6, 10] {
                let schema = try AppleLocalAI.cardSchema(count: count)
                let encoded = try JSONEncoder().encode(schema)
                #expect(!String(decoding: encoded, as: UTF8.self).contains("\"pattern\""), "Native card schemas must not require regex generation guides")
                _ = try JSONDecoder().decode(GenerationSchema.self, from: encoded)
                let value = JSONText.object((0..<count).map { ("card\($0)", proposal($0)) })
                let content = try GeneratedContent(json: value.stringify())
                let result = try AppleLocalAI.checkedCardResponse(JSONText.parse(Data(content.jsonString.utf8)), count: count)
                #expect(try AICards.checked(result, count: count).count == count)
            }
            for count in [0, 11] { #expect(throws: AIFailure.configuration) { try AppleLocalAI.cardSchema(count: count) } }
        }
        #endif
        #expect(!AppleLocalAI.available, "Guarded tests never use the real on-device model")
    }
}
