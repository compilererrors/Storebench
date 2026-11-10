import Foundation
#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26, *) @Generable private struct LocalTranslations {
    @Guide(description: "One translation for each supplied input, in exactly the same order.") var translations: [String]
}
#endif

public enum AppleLocalAI {
    // Fixed properties give each screenshot one card; the model chooses importance, never source identity.
    #if canImport(FoundationModels)
    @available(macOS 26, *)
    static func cardSchema(count: Int, allowCropping: Bool = true) throws -> GenerationSchema {
        guard (1...10).contains(count) else { throw AIFailure.configuration }
        let color = DynamicGenerationSchema(name: "RGBColor", description: "RGB color components, each from 0 to 255.", properties: ["red", "green", "blue"].map {
            .init(name: $0, schema: .init(type: Int.self, guides: [.range(0...255)]))
        })
        let card = DynamicGenerationSchema(name: "CardProposal", properties: [
            .init(name: "priority", description: "Marketing importance, 0 to 100. Higher comes first.", schema: .init(type: Int.self, guides: [.range(0...100)])),
            .init(name: "title", description: "Benefit-led title on one line, at most 60 characters.", schema: .init(type: String.self)),
            .init(name: "subtitle", description: "Subtitle on one line, at most 90 characters; empty when unnecessary.", schema: .init(type: String.self)),
            .init(name: "layout", schema: .init(name: "ScreenshotLayout", anyOf: MediaCard.Layout.allCases.filter { $0.usesScreenshot && (allowCropping || [.textAbove, .textBelow].contains($0)) }.map(\.rawValue))),
            .init(name: "color", description: "Background color.", schema: .init(referenceTo: "RGBColor")),
            .init(name: "secondColor", description: "Second background color.", schema: .init(referenceTo: "RGBColor")),
            .init(name: "titleColor", description: "Text color contrasting with both backgrounds.", schema: .init(referenceTo: "RGBColor"))
        ])
        let root = DynamicGenerationSchema(name: "CardProposals", properties: (0..<count).map {
            .init(name: "card\($0)", description: "Describe screenshot \($0) only.", schema: .init(referenceTo: "CardProposal"))
        })
        return try GenerationSchema(root: root, dependencies: [card, color])
    }
    #endif

    static func checkedCardResponse(_ response: JSONText, count: Int) throws -> JSONText {
        guard (1...10).contains(count) else { throw AIFailure.configuration }
        let names = Set((0..<count).map { "card\($0)" })
        guard case .object(let fields) = response, fields.count == count, Set(fields.map(\.0)) == names else { throw AIFailure.response }
        let keys: Set<String> = ["priority", "title", "subtitle", "layout", "color", "secondColor", "titleColor"]
        var ordered: [(index: Int, priority: Int, value: JSONText)] = []
        for index in 0..<count {
            guard let value = response["card\(index)"], case .object(let fields) = value,
                  fields.count == keys.count, Set(fields.map(\.0)) == keys,
                  case .number(let raw)? = value["priority"], let priority = Int(exactly: raw), (0...100).contains(priority) else { throw AIFailure.response }
            var card = JSONText.object([("screenshotIndex", .number(Double(index)))] + fields.filter { $0.0 != "priority" })
            for name in ["color", "secondColor", "titleColor"] { card = card.setting(name, .string(try hexColor(value[name]))) }
            ordered.append((index, priority, card))
        }
        ordered.sort { $0.priority == $1.priority ? $0.index < $1.index : $0.priority > $1.priority }
        let result = JSONText.object([("cards", .array(ordered.map(\.value)))])
        _ = try AICards.checked(result, count: count)
        return result
    }

    private static func hexColor(_ value: JSONText?) throws -> String {
        let names = ["red", "green", "blue"]
        guard case .object(let fields)? = value, fields.count == names.count, Set(fields.map(\.0)) == Set(names) else { throw AIFailure.response }
        let components = try names.map { name -> Int in
            guard case .number(let raw)? = value?[name], let number = Int(exactly: raw), (0...255).contains(number) else { throw AIFailure.response }
            return number
        }
        return String(format: "#%02X%02X%02X", components[0], components[1], components[2])
    }

    static func failure(_ error: Error) -> AIFailure {
        if let failure = error as? AIFailure { return failure }
        if error is CancellationError { return .cancelled }
        #if canImport(FoundationModels)
        if #available(macOS 27, *) {
            if let failure = error as? LanguageModelError {
                switch failure {
                case .contextSizeExceeded: return .tooLarge
                case .rateLimited: return .localBusy
                case .guardrailViolation, .refusal: return .localRejected
                case .unsupportedGenerationGuide, .unsupportedCapability: return .localFormatUnsupported
                case .unsupportedLanguageOrLocale: return .languageUnsupported
                case .unsupportedTranscriptContent: return .response
                case .timeout: return .localFailed
                @unknown default: return .localFailed
                }
            }
            if error is SystemLanguageModel.Error { return .localUnavailable }
            if error is LanguageModelSession.Error { return .localBusy }
            if error is GeneratedContent.ParsingError { return .response }
        }
        if #available(macOS 26, *) {
            if let failure = error as? LanguageModelSession.GenerationError {
                switch failure {
                case .exceededContextWindowSize: return .tooLarge
                case .assetsUnavailable: return .localUnavailable
                case .unsupportedLanguageOrLocale: return .languageUnsupported
                case .unsupportedGuide: return .localFormatUnsupported
                case .decodingFailure: return .response
                case .rateLimited, .concurrentRequests: return .localBusy
                case .guardrailViolation, .refusal: return .localRejected
                @unknown default: return .localFailed
                }
            }
            if error is GenerationSchema.SchemaError { return .localFormatUnsupported }
        }
        #endif
        return .localFailed
    }

    public static var available: Bool {
        guard !Network.testMode else { return false }
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return SystemLanguageModel.default.isAvailable }
        #endif
        return false
    }
    static func allowsCropping(_ input: AIRequest) -> Bool {
        guard let data = try? JSONText.parse(Data(input.input.utf8)), case .array(let values)? = data["directions"] else { return true }
        return values.contains(.string(AICardDirection.allowCropping.rawValue))
    }
    static func executionSnapshot(_ input: AIRequest) -> AIExecutionSnapshot {
        guard input.purpose == "cards" else { return .init(instructions: input.instructions, input: input.input, format: "Native structured translations") }
        let source = (try? JSONText.parse(Data(input.input.utf8))) ?? .null
        let directions = (try? AICardDirection.selected(in: source)) ?? AICardDirection.defaults
        let language = input.language ?? "en-US"
        let instructions = AICards.instructions(language: language, directions: directions, customInstructions: input.cardDraft?["customInstructions"]?.text)
            + "\n\n" + AICards.outputContract(language: language, directions: directions) + "\nEach cardN describes screenshot N only; the app assigns screenshot indices. Use priority from 0 to 100 for marketing importance, higher first. Each color is an RGB object with red, green and blue integer components from 0 to 255. Return only the requested native structure."
        let context = input.images.enumerated().map { "Screenshot \($0.offset): \($0.element.text)" }.joined(separator: "\n")
        return .init(instructions: instructions, input: input.input + "\n" + context, format: "Native card0…cardN: priority, title, subtitle, layout and three RGB colors. Screenshots are supplied as recognized text, not image pixels.")
    }
    static func generate(_ input: AIRequest) async throws -> JSONText {
        guard available else { throw AIFailure.localUnavailable }
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            if let language = input.language, !SystemLanguageModel.default.supportsLocale(Locale(identifier: language)) { throw AIFailure.languageUnsupported }
            do {
                if input.purpose == "cards" {
                    let execution = executionSnapshot(input)
                    let session = LanguageModelSession(instructions: execution.instructions)
                    let response = try await session.respond(to: execution.input, schema: cardSchema(count: input.images.count, allowCropping: allowsCropping(input)))
                    return try checkedCardResponse(JSONText.parse(Data(response.content.jsonString.utf8)), count: input.images.count)
                }
                let session = LanguageModelSession(instructions: input.instructions)
                let response = try await session.respond(to: input.input, generating: LocalTranslations.self)
                return .object([("translations", .array(response.content.translations.map(JSONText.string)))])
            } catch let error as CancellationError {
                throw error
            } catch {
                throw failure(error)
            }
        }
        #endif
        throw AIFailure.localUnavailable
    }
}
