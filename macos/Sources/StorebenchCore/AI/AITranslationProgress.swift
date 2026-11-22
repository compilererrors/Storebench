import Foundation

/// How far one language's translation has come: text parts translated of those sent, then any shortening to fit a limit.
public struct AITranslationStep: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case translating, shortening(field: String, round: Int, rounds: Int)
        /// Rewording was not enough, so whole closing sentences of a field were left out to fit its limit.
        case leftOut(field: String, sentences: Int, maximum: Int, unit: String)
        /// Keywords left out whole: repeated terms, terms the name or subtitle already give Apple, then the last terms.
        case keywordsLeftOut(repeated: Int, indexed: Int, last: Int, maximum: Int)
        /// A short phrase such as a subtitle left out its last whole words to fit its limit.
        case wordsLeftOut(field: String, maximum: Int, unit: String)
    }
    public let done: Int, total: Int
    public let phase: Phase
    public init(done: Int, total: Int, phase: Phase = .translating) { self.done = max(0, min(done, total)); self.total = max(0, total); self.phase = phase }
    /// Translating fills the first 85% of the bar and shortening the rest, so the bar never goes back.
    public var fraction: Double {
        switch phase {
        case .translating: return total == 0 ? 0 : 0.85 * Double(done) / Double(total)
        case .shortening(_, let round, let rounds): return 0.85 + 0.15 * Double(round) / Double(max(1, rounds))
        case .leftOut, .keywordsLeftOut, .wordsLeftOut: return 1
        }
    }
    public var text: String {
        switch phase {
        case .translating: return total <= 1 ? "Translating…" : "Translating part \(min(done + 1, total)) of \(total)…"
        case .shortening(let field, let round, _): return "Shortening \(field) to fit the App Store limit, try \(round + 1)…"
        case .leftOut(let field, let sentences, let maximum, let unit):
            return "\(field): \(sentences == 1 ? "the last sentence was" : "the last \(sentences) sentences were") left out to fit \(maximum.formatted()) \(unit). Read it before syncing."
        case .wordsLeftOut(let field, let maximum, let unit):
            return "\(field): its last words were left out to fit \(maximum.formatted()) \(unit). Read it before syncing."
        case .keywordsLeftOut(let repeated, let indexed, let last, let maximum):
            let total = repeated + indexed + last
            let reasons = [repeated > 0 ? "\(repeated) repeated" : nil, indexed > 0 ? "\(indexed) already in the name or subtitle" : nil,
                           last > 0 ? "the last \(last) of the list" : nil].compactMap { $0 }.joined(separator: ", ")
            return "Keywords: \(total == 1 ? "1 keyword was" : "\(total) keywords were") left out to fit \(maximum.formatted()) bytes (\(reasons)). Read them before syncing."
        }
    }
}

/// Reports translation steps to the screen that started the translation. It travels with the task, so the model code
/// reports without knowing who listens; nothing is reported when no screen listens.
public enum AITranslationProgress {
    @TaskLocal public static var report: (@Sendable (AITranslationStep) -> Void)?
}
