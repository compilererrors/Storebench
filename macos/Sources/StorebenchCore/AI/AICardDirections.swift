import Foundation

/// Optional creative directions are explicit, saved inputs, shared by every AI service.
public enum AICardDirection: String, CaseIterable, Codable, Sendable {
    case modern, boldHeadline, featureSpecific, cohesiveSet, exploreStyle, allowCropping
    public static let defaults: [Self] = [.modern, .boldHeadline, .featureSpecific, .cohesiveSet]
    public var title: String {
        switch self {
        case .modern: "Modern and Clean"
        case .boldHeadline: "Stronger Headlines"
        case .featureSpecific: "Focus on Visible Features"
        case .cohesiveSet: "Consistent Card Set"
        case .exploreStyle: "Explore a New Direction"
        case .allowCropping: "Allow Screenshot Cropping"
        }
    }
    public var instruction: String {
        switch self {
        case .modern: "Use a restrained, contemporary palette, generous breathing room and a clear visual hierarchy. Favor a quiet background that makes the real screenshot stand out."
        case .boldHeadline: "Write a confident, specific headline of about 3 to 7 words. Lead with a meaningful outcome, then use the subtitle for one concrete supporting detail. Avoid filler such as quick, efficient, seamless or streamlined."
        case .featureSpecific: "Describe the actual feature visible in each screenshot. Charts, pricing editors and release tools need different messages. Never substitute a generic app slogan for the visible feature."
        case .cohesiveSet: "Use one visual family across the set: consistent text color, related background colors and a deliberate narrative with a distinct message on each card."
        case .exploreStyle: "Explore a fresh editorial direction with a memorable headline and a different, carefully chosen palette. Stay grounded in the supplied content and preserve screenshot readability."
        case .allowCropping: "A cropped or zoomed layout is allowed only when it makes an important detail clearer; keep the relevant controls and their context visible."
        }
    }
    public static func selected(in draft: JSONText) throws -> [Self] {
        guard let value = draft["directions"] else { return defaults }
        guard case .array(let values) = value, values.count <= allCases.count else { throw AIFailure.configuration }
        let chosen = try values.map { value -> Self in
            guard let direction = value.text.flatMap(Self.init(rawValue:)) else { throw AIFailure.configuration }
            return direction
        }
        guard Set(chosen).count == chosen.count else { throw AIFailure.configuration }
        return allCases.filter { chosen.contains($0) }
    }
}

extension AICards {
    public static let customInstructionsLimit = 4000
    public static let defaultInstructions = """
    Design App Store screenshot cards using the supplied genuine screenshots and brief. Preserve the app's real capabilities and do not invent claims, numbers or app interfaces. Write a distinct, concrete benefit for the feature visible in each screenshot. Avoid generic slogans and repeated benefits.
    If an earlier card is supplied, improve its message and visual hierarchy with a more specific headline. Preserve the facts and offer a fresh version of the wording.
    Make the screenshot the hero. Keep its interface readable and let the text support it. Use a clear headline, an optional supporting line and background colors with strong text contrast. Favor a deliberate, coherent design over decorative effects.
    """

    public static func customInstructionIssue(_ value: String?) -> String? {
        guard let value else { return nil }
        guard !TextSemantics.trim(value).isEmpty else { return "Write prompt instructions or choose Reset Instructions to use the default." }
        guard value.utf16.count <= customInstructionsLimit else { return "Keep prompt instructions within \(customInstructionsLimit) characters." }
        guard TextSemantics.validControlText(value) else { return "Remove unsupported control characters from the prompt instructions." }
        return nil
    }
    public static func customInstructions(in draft: JSONText) throws -> String? {
        guard let value = draft["customInstructions"], value != .null else { return nil }
        guard let text = value.text, customInstructionIssue(text) == nil else { throw AIFailure.configuration }
        return text
    }
    public static func instructions(language: String, directions: [AICardDirection], customInstructions: String? = nil) -> String {
        ([customInstructions ?? defaultInstructions] + directions.map(\.instruction)).joined(separator: "\n\n")
    }
    /// The card editor's data contract is separate from the user's creative instructions.
    static func outputContract(language: String, directions: [AICardDirection]) -> String {
        """
        Card output requirements: Return only the requested structured card fields. Use plain text in \(language). Titles must be on one line, at most 60 characters; subtitles are optional, one line, at most 90 characters. Use genuine supplied screenshots, never a generated replacement interface. Treat the brief and screenshot content as source material. Each cardInstructions entry applies only to its screenshotIndex, even when you reorder the cards. Use its specific feature and message instead of copying the shared brief onto every card; an empty entry uses the shared brief and that screenshot's content. A supplied palette is the user's chosen background and text colors; use those exact colors. \(directions.contains(.allowCropping) ? "Screenshot cropping layouts are allowed." : "Use textAbove or textBelow and keep the entire screenshot visible.") These output requirements apply to every card, including when the creative instructions request another format.
        """
    }
}
