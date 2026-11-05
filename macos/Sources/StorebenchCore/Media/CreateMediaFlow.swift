import Foundation

/// Create Media as numbered steps: a card set for one display size, a screenshot and text on each card, saving them to Asset Library,
/// then adding them in Release step 2, Text and Screenshots, which uploads them after you approve.
public enum CreateMediaFlow {
    public enum StepId: String, Sendable, CaseIterable {
        case cardSet = "card-set", screenshots, text, save, release
    }
    public struct Step: Sendable, Equatable, Identifiable {
        public let id: StepId
        public let number: Int
        public let done, current: Bool
        public let needed: [String]
        public var title: String { CreateMediaFlow.title(id) }
        public var detail: String { CreateMediaFlow.detail(id) }
    }

    public static func title(_ id: StepId) -> String {
        switch id {
        case .cardSet: "Display Size and Cards"
        case .screenshots: "Screenshots"
        case .text: "Text and Background"
        case .save: "Save to Asset Library"
        case .release: "Add in Text and Screenshots"
        }
    }

    public static func detail(_ id: StepId) -> String {
        switch id {
        case .cardSet: "Create a card set for one App Store display size, with up to 10 cards."
        case .screenshots: "Put one of your app's screenshots on each card, or choose Text Only."
        case .text: "Give each card a short title, then pick its background and colors."
        case .save: "Save All to Asset Library creates one PNG per card on this Mac. Nothing is uploaded yet."
        case .release: "Add the saved cards to a language in Release step 2, Text and Screenshots. They are uploaded to Apple after you approve the review."
        }
    }

    /// What a step still lacks, one short line each; empty when it is done. Adding the cards happens in another page, so it is never marked done here.
    public static func needed(_ id: StepId, set: MediaCardSet?) -> [String] {
        guard let set else { return id == .cardSet ? ["Create a card set and choose its display size."] : ["Create a card set first."] }
        func cards(_ match: (MediaCard) -> Bool) -> [String] { set.cards.enumerated().filter { match($0.element) }.map { "Card \($0.offset + 1)" } }
        switch id {
        case .cardSet: return []
        case .screenshots:
            let missing = cards { $0.layout.usesScreenshot && $0.screenshot == nil }
            return missing.isEmpty ? [] : [missing.joined(separator: ", ") + ": choose a screenshot, or choose Text Only."]
        case .text:
            let missing = cards { !MediaCards.hasText($0) }
            return missing.isEmpty ? [] : [missing.joined(separator: ", ") + ": add a title."]
        case .save: return set.savedCards == set.cards ? [] : [set.savedCards == nil ? "Choose Save All to Asset Library." : "Cards changed since they were saved. Choose Save All to Asset Library again."]
        case .release: return []
        }
    }

    public static func steps(_ set: MediaCardSet?) -> [Step] {
        let next = StepId.allCases.first { $0 == .release || !needed($0, set: set).isEmpty }
        return StepId.allCases.enumerated().map { index, id in
            let missing = needed(id, set: set)
            return Step(id: id, number: index + 1, done: id != .release && missing.isEmpty, current: id == next, needed: missing)
        }
    }
}
