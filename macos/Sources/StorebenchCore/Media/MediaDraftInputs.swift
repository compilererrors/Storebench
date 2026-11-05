import Foundation

/// Unsaved media values, separate from the last acknowledged catalog and signature.
public struct MediaDraftInputs: Equatable, Sendable {
    public var order: [String]
    public var hidden: Set<String>
    public var posterTimes: [String: Double]
    public init(order: [String], hidden: Set<String>, posterTimes: [String: Double] = [:]) {
        self.order = order; self.hidden = hidden; self.posterTimes = posterTimes
    }
    public init(_ draft: ScreenshotSetDraft) { self.init(order: draft.items.map(\.id), hidden: draft.hidden) }
    public init(_ draft: PreviewSetDraft) { self.init(order: draft.items.map(\.id), hidden: draft.hidden, posterTimes: draft.posterTimes) }
    public var signature: String { PreviewSpecs.signature(order: order, hidden: order.filter(hidden.contains), posterTimes: posterTimes) }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.signature.utf8.elementsEqual(rhs.signature.utf8) }

    /// Used only after the user chooses Keep My Edits: preserve existing media's
    /// choices, and take new or removed media from the explicitly reviewed catalog.
    public func keepingEdits(on latest: Self) -> Self {
        let known = Set(latest.order), existing = Set(order)
        let retained = order.filter(known.contains), added = latest.order.filter { !existing.contains($0) }
        let selection = hidden.intersection(known).union(latest.hidden.intersection(added))
        let times = Dictionary((retained + added).compactMap { id in
            (existing.contains(id) ? posterTimes[id] ?? latest.posterTimes[id] : latest.posterTimes[id]).map { (id, $0) }
        }, uniquingKeysWith: { _, last in last })
        return Self(order: retained + added, hidden: selection, posterTimes: times)
    }
}
