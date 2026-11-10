import Foundation

/// Optional colors shared by a generated set. Explicit choices also apply when a model suggests other colors.
public struct AICardPalette: Equatable, Sendable {
    public var fill: MediaCardStyle.Fill = .gradient
    public var color = "#2F4FD8", secondColor = "#7B3FE4", textColor = "#FFFFFF"
    public init() {}
    public var value: JSONText {
        .object([("fill", .string(fill.rawValue)), ("color", .string(color)), ("secondColor", .string(secondColor)), ("textColor", .string(textColor))])
    }
    public static func read(_ value: JSONText?) throws -> Self? {
        guard let value, value != .null else { return nil }
        guard let fill = value["fill"]?.text.flatMap(MediaCardStyle.Fill.init(rawValue:)),
              let color = value["color"]?.text, let second = value["secondColor"]?.text, let text = value["textColor"]?.text,
              [color, second, text].allSatisfy(MediaCards.color) else { throw AIFailure.configuration }
        var palette = Self(); palette.fill = fill; palette.color = color; palette.secondColor = second; palette.textColor = text
        return palette
    }
}

extension AICards {
    public static let cardBriefLimit = 600
    public static func cardBriefIssue(_ briefs: [String]) -> String? {
        for (index, brief) in briefs.enumerated() {
            if brief.utf16.count > cardBriefLimit { return "Keep instructions for Screenshot \(index + 1) within \(cardBriefLimit) characters." }
            if !TextSemantics.validControlText(brief) { return "Remove unsupported control characters from Screenshot \(index + 1)'s instructions." }
        }
        return nil
    }
    public static func cardBriefs(in draft: JSONText, count: Int) throws -> [String] {
        guard let value = draft["cardBriefs"], value != .null else { return Array(repeating: "", count: count) }
        guard case .array(let rows) = value, rows.count == count else { throw AIFailure.configuration }
        let briefs = try rows.map { row in guard let text = row.text else { throw AIFailure.configuration }; return text }
        guard cardBriefIssue(briefs) == nil else { throw AIFailure.configuration }
        return briefs
    }
    static func generationGuidance(in draft: JSONText, count: Int) throws -> JSONText {
        let briefs = try cardBriefs(in: draft, count: count)
        let palette = try AICardPalette.read(draft["cardPalette"])
        return .object([("cardInstructions", .array(briefs.enumerated().map { index, brief in
            .object([("screenshotIndex", .number(Double(index))), ("instructions", .string(brief))])
        })), ("palette", palette?.value ?? .null)])
    }
}
