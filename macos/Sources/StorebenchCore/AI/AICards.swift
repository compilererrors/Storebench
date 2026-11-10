import CoreGraphics
import Foundation
import ImageIO
import Vision

public enum AICards {
    public static func generationIssue(name: String, brief: String, screenshots: Int, provider: String, connections: [AIConnection], localAvailable: Bool) -> String? {
        guard !TextSemantics.trim(name).isEmpty else { return "Add a card set name before generating." }
        guard MediaCards.validText(name, MediaCards.nameLimit), !name.contains("\n") else { return "Use a card set name of up to \(MediaCards.nameLimit) characters on one line." }
        guard !TextSemantics.trim(brief).isEmpty else { return "Describe what the cards should convey before generating." }
        guard brief.utf16.count <= 2000, TextSemantics.validControlText(brief) else { return "Keep the brief within 2000 characters." }
        guard (1...10).contains(screenshots) else { return "Choose between 1 and 10 screenshots before generating." }
        guard let service = AIProvider(rawValue: provider) else { return "Choose an AI service before generating." }
        if service == .apple { return localAvailable ? nil : "Apple Intelligence is unavailable. Choose another service or open AI Settings." }
        guard connections.contains(where: { $0.provider == service }) else { return "Connect \(service.title) in AI Settings before generating." }
        return nil
    }

    public static func image(_ bytes: Data, recognizeText: Bool = true, textLimit: Int = 600) async throws -> AIImage {
        try await Task.detached {
            try Task.checkCancellation()
            guard bytes.count <= ScreenshotEditing.maximumSourceBytes,
                  let source = CGImageSourceCreateWithData(bytes as CFData, nil), CGImageSourceGetCount(source) == 1,
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1400] as CFDictionary) else { throw AIFailure.response }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else { throw AIFailure.response }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.78] as CFDictionary)
            guard CGImageDestinationFinalize(destination), output.length <= 2_000_000 else { throw AIFailure.tooLarge }
            var text = ""
            if recognizeText {
                let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
                do { try VNImageRequestHandler(cgImage: image).perform([request]) }
                catch { try Task.checkCancellation(); throw AIFailure.localImageText }
                try Task.checkCancellation()
                text = screenshotText((request.results ?? []).compactMap { observation in
                    observation.topCandidates(1).first.map { (text: $0.string, bounds: observation.boundingBox) }
                }, limit: textLimit)
            }
            return AIImage(data: output as Data, text: text)
        }.value
    }
    /// Keep main content before narrow edge navigation without discarding the original reading order within either group.
    static func screenshotText(_ lines: [(text: String, bounds: CGRect)], limit: Int) -> String {
        func main(_ bounds: CGRect) -> Bool { bounds.minX >= 0.18 || bounds.width >= 0.5 || bounds.height >= 0.025 }
        let ordered = lines.filter { main($0.bounds) } + lines.filter { !main($0.bounds) }
        return String(ordered.map(\.text).joined(separator: "\n").prefix(max(0, min(6000, limit))))
    }
    public static func request(brief: String, language: String, target: ScreenshotEditing.Target, images: [AIImage], directions: [AICardDirection] = AICardDirection.defaults, cardDraft: JSONText? = nil, variationID: String? = nil, customInstructions: String? = nil) throws -> AIRequest {
        guard !TextSemantics.trim(brief).isEmpty, brief.utf16.count <= 2000, StoreLocales.codes.contains(language), (1...10).contains(images.count) else { throw AIFailure.configuration }
        let custom = try customInstructions ?? Self.customInstructions(in: cardDraft ?? .null)
        guard customInstructionIssue(custom) == nil else { throw AIFailure.configuration }
        let savedDraft = custom.map { (cardDraft ?? .object([])).setting("customInstructions", .string($0)) } ?? cardDraft
        let guidance = try generationGuidance(in: savedDraft ?? .null, count: images.count)
        let fields: [(String, JSONText)] = [
            ("screenshotIndex", .object([("type", .string("integer"))])), ("title", AIRequest.stringSchema), ("subtitle", AIRequest.stringSchema),
            ("layout", .object([("type", .string("string")), ("enum", .array(MediaCard.Layout.allCases.filter { $0.usesScreenshot && (directions.contains(.allowCropping) || [.textAbove, .textBelow].contains($0)) }.map { .string($0.rawValue) }))])),
            ("color", AIRequest.stringSchema), ("secondColor", AIRequest.stringSchema), ("titleColor", AIRequest.stringSchema)]
        return .init(purpose: "cards", instructions: instructions(language: language, directions: directions, customInstructions: custom) + "\n\n" + outputContract(language: language, directions: directions) + "\nUse each screenshotIndex exactly once, ordered by marketing importance. Return only the requested JSON structure. Each color is a #RRGGBB string.",
            input: JSONText.object([("brief", .string(brief)), ("language", .string(language)), ("width", .number(Double(target.width))), ("height", .number(Double(target.height))), ("screenshotCount", .number(Double(images.count))), ("directions", .array(directions.map { .string($0.rawValue) })), ("previousCard", cardDraft?["previousCard"] ?? .null),
                ("cardInstructions", guidance["cardInstructions"] ?? .array([])), ("palette", guidance["palette"] ?? .null)]).stringify(),
            schema: AIRequest.objectSchema([("cards", .object([("type", .string("array")), ("items", AIRequest.objectSchema(fields))]))]), images: images, language: language, cardDraft: savedDraft, variationID: variationID)
    }
    static func checked(_ result: JSONText, count: Int) throws -> [JSONText] {
        guard case .array(let cards)? = result["cards"], cards.count == count else { throw AIFailure.response }
        var indices = Set<Int>()
        for card in cards {
            guard case .number(let raw)? = card["screenshotIndex"], let index = Int(exactly: raw), (0..<count).contains(index), indices.insert(index).inserted,
                  let title = card["title"]?.text, !TextSemantics.trim(title).isEmpty, MediaCards.validText(title, MediaCards.titleLimit),
                  let subtitle = card["subtitle"]?.text, MediaCards.validText(subtitle, MediaCards.subtitleLimit),
                  let layout = card["layout"]?.text.flatMap(MediaCard.Layout.init(rawValue:)), layout.usesScreenshot else { throw AIFailure.response }
            for key in ["color", "secondColor", "titleColor"] {
                guard let hex = card[key]?.text, hex.range(of: #"\A#[0-9a-fA-F]{6}\z"#, options: .regularExpression) != nil else { throw AIFailure.response }
            }
        }
        return cards
    }
    public static func cardSet(_ result: JSONText, screenshots: [MediaCard.Screenshot], name: String, language: String, target: ScreenshotEditing.Target, directions: [AICardDirection] = AICardDirection.defaults, variationID: String? = nil, palette: AICardPalette? = nil) throws -> MediaCardSet {
        let cards = try checked(result, count: screenshots.count)
        var set = MediaCardSet(name: name, target: target); set.language = language
        let identity: [JSONText] = [result, .array(screenshots.map { .string($0.hash) }), .string(name), .string(language), .string(target.id)]
        let digest = JSONText.array(identity + (variationID.map { [.string($0)] } ?? []) + (palette.map { [$0.value] } ?? [])).sha256
        let chars = Array(digest.prefix(32))
        set.id = String(chars[0..<8]) + "-" + String(chars[8..<12]) + "-4" + String(chars[13..<16]) + "-8" + String(chars[17..<20]) + "-" + String(chars[20..<32])
        set.cards = cards.map { input in
            var card = MediaCard(); card.title = input["title"]!.text!; card.subtitle = input["subtitle"]!.text!
            card.layout = MediaCard.Layout(rawValue: input["layout"]!.text!)!
            if !directions.contains(.allowCropping), ![.textAbove, .textBelow].contains(card.layout) { card.layout = .textAbove }
            card.style.screenshotWidth = 1; card.style.margin = 3; card.style.cornerRadius = 1.8
            card.style.textSpace = target.width > target.height ? 0.18 : 0.22
            card.style.textSize = 1.08; card.style.alignment = .leading
            if case .number(let index)? = input["screenshotIndex"] { card.screenshot = screenshots[Int(index)] }
            card.style.color = input["color"]!.text!; card.style.secondColor = input["secondColor"]!.text!; card.style.titleColor = input["titleColor"]!.text!
            if let palette {
                card.style.fill = palette.fill; card.style.color = palette.color; card.style.secondColor = palette.secondColor; card.style.titleColor = palette.textColor
            }
            card.style.subtitleColor = card.style.titleColor; card.style.bodyColor = card.style.titleColor; return card
        }
        try MediaCards.validate(set); return set
    }
}
