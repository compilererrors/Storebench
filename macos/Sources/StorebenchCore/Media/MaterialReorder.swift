import CoreGraphics
import Foundation
import Observation

/// Drag previews never mutate an editor. Only a drop from this exact session can commit its order.
@MainActor @Observable public final class MaterialReorder {
    /// A bounded scroll step for a pointer inside an owned scroll viewport.
    public static func scrollStep(position: Double, length: Double) -> Double {
        guard position.isFinite, length.isFinite, length > 0, position >= 0, position <= length else { return 0 }
        let edge = min(48, length / 3)
        if position < edge { return -12 * (1 - position / edge) }
        if position > length - edge { return 12 * (1 - (length - position) / edge) }
        return 0
    }
    public struct Drag: Equatable, Sendable {
        public let token: UUID, context: String, source: String, baseline: [String]
        public let sources: [String]
        public var target: String?, after = false
        public var indicator: InsertionEdge?
    }
    public struct InsertionEdge: Equatable, Sendable {
        public let id: String, after: Bool
    }
    public enum Destination: Sendable { case beginning, end, earlier, later }
    public private(set) var drag: Drag?
    public private(set) var selection: Set<String> = []
    private var selectionAnchor: String?
    public private(set) var announcement = ""
    public init() {}
    public var active: Bool { drag != nil }
    public func select(_ id: String, order: [String], toggle: Bool = false, extending: Bool = false, preserving: Bool = false) {
        guard !active, Self.valid(order), order.contains(id) else { return }
        selection.formIntersection(order)
        if extending, let anchor = selectionAnchor, let start = order.firstIndex(of: anchor), let end = order.firstIndex(of: id) {
            let range = Set(order[min(start, end)...max(start, end)])
            selection = toggle ? selection.union(range) : range
        } else if toggle {
            if !selection.insert(id).inserted { selection.remove(id) }
            selectionAnchor = id
        } else if !preserving || !selection.contains(id) {
            selection = [id]; selectionAnchor = id
        }
        announcement = selection.isEmpty ? "Selection cleared." : "\(selection.count) \(selection.count == 1 ? "item" : "items") selected."
    }
    public func selectAll(_ order: [String]) {
        guard !active, Self.valid(order) else { return }
        selection = Set(order); selectionAnchor = order.first
        announcement = "\(selection.count) items selected."
    }
    public func clearSelection() {
        guard !active else { return }
        selection.removeAll(); selectionAnchor = nil; announcement = "Selection cleared."
    }
    public func reconcileSelection(_ order: [String]) {
        selection.formIntersection(order)
        if let anchor = selectionAnchor, !order.contains(anchor) { selectionAnchor = nil }
    }
    public func subjects(for id: String, order: [String]) -> [String] {
        selection.contains(id) ? order.filter { selection.contains($0) } : order.filter { $0 == id }
    }
    @discardableResult public func begin(_ id: String, order: [String], context: String, enabled: Bool) -> UUID? {
        guard enabled, drag == nil, !context.isEmpty, Self.valid(order), order.count > 1, order.contains(id) else { return nil }
        let sources = subjects(for: id, order: order)
        selection = Set(sources)
        let token = UUID(); drag = Drag(token: token, context: context, source: id, baseline: order, sources: sources)
        announcement = "Drag \(sources.count == 1 ? "the item" : "the selected items") to a highlighted gap. Release to place; press Escape to cancel."
        return token
    }
    public func matches(order: [String], context: String, enabled: Bool) -> Bool {
        enabled && drag?.context == context && drag?.baseline == order
    }
    public func hover(_ id: String, after: Bool, order: [String], context: String, enabled: Bool, visibleOrder: [String]? = nil) {
        guard matches(order: order, context: context, enabled: enabled), order.contains(id) else { return }
        guard drag?.target != id || drag?.after != after else { return }
        drag?.target = id; drag?.after = after
        let available = (visibleOrder ?? order).filter { drag?.sources.contains($0) != true }
        if let index = available.firstIndex(of: id) {
            drag?.indicator = after || index == 0 ? InsertionEdge(id: id, after: after) : InsertionEdge(id: available[index - 1], after: true)
        } else { drag?.indicator = nil }
    }
    public func exit(_ id: String? = nil) { if id == nil || drag?.target == id { drag?.target = nil; drag?.indicator = nil } }
    /// Where a drop at `point` places the material: beside the nearest card in the pointer's row, before or after its middle.
    /// Gaps between cards and the empty space after the last card count too, so the last position can always be reached.
    public static func slot(at point: CGPoint, frames: [(id: String, frame: CGRect)]) -> (target: String, after: Bool)? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        func distance(_ low: CGFloat, _ high: CGFloat, _ value: CGFloat) -> CGFloat { value < low ? low - value : value > high ? value - high : 0 }
        guard let rowDistance = frames.map({ distance($0.frame.minY, $0.frame.maxY, point.y) }).min() else { return nil }
        let row = frames.filter { distance($0.frame.minY, $0.frame.maxY, point.y) <= rowDistance + 0.5 }
        guard let nearest = row.min(by: { distance($0.frame.minX, $0.frame.maxX, point.x) < distance($1.frame.minX, $1.frame.maxX, point.x) }) else { return nil }
        return (nearest.id, point.x > nearest.frame.midX)
    }
    public func invalidate(order: [String], context: String, enabled: Bool) {
        if active && !matches(order: order, context: context, enabled: enabled) { cancel() }
    }
    public func cancel(token: UUID? = nil) {
        guard let drag, token == nil || token == drag.token else { return }
        self.drag = nil; announcement = "Reordering cancelled. The order is unchanged."
    }
    public func rejected() { drag = nil; announcement = "The material changed while dragging. Nothing moved; try again." }
    public func commit(token: UUID, order: [String], context: String, enabled: Bool) -> [String]? {
        guard let drag, drag.token == token else { return nil }
        defer { self.drag = nil }
        guard matches(order: order, context: context, enabled: enabled), let target = drag.target,
              let next = Self.placing(order, sources: Set(drag.sources), target: target, after: drag.after), next != order else {
            announcement = "Reordering cancelled. The order is unchanged."; return nil
        }
        announcement = "Moved \(drag.sources.count == 1 ? "item" : "\(drag.sources.count) items") to position \(next.firstIndex(of: drag.sources[0])! + 1) of \(next.count). Save to keep the new order locally."
        return next
    }
    public static func placing(_ order: [String], source: String, target: String, after: Bool) -> [String]? {
        placing(order, sources: [source], target: target, after: after)
    }
    public static func placing(_ order: [String], sources: Set<String>, target: String, after: Bool) -> [String]? {
        guard valid(order), !sources.isEmpty, sources.isSubset(of: Set(order)), !sources.contains(target), order.contains(target) else { return nil }
        let moving = order.filter { sources.contains($0) }
        var next = order.filter { !sources.contains($0) }
        guard let index = next.firstIndex(of: target) else { return nil }
        next.insert(contentsOf: moving, at: index + (after ? 1 : 0)); return next
    }
    public static func moving(_ order: [String], sources: Set<String>, destination: Destination) -> [String]? {
        guard valid(order), !sources.isEmpty, sources.isSubset(of: Set(order)),
              let first = order.firstIndex(where: { sources.contains($0) }), let last = order.lastIndex(where: { sources.contains($0) }) else { return nil }
        let moving = order.filter { sources.contains($0) }, remaining = order.filter { !sources.contains($0) }
        let next: [String]?
        switch destination {
        case .beginning: next = moving + remaining
        case .end: next = remaining + moving
        case .earlier: next = first > 0 ? placing(order, sources: sources, target: order[first - 1], after: false) : nil
        case .later: next = last + 1 < order.count ? placing(order, sources: sources, target: order[last + 1], after: true) : nil
        }
        return next == order ? nil : next
    }
    public static func moving(_ order: [String], source: String, to index: Int) -> [String]? {
        guard valid(order), order.indices.contains(index), let from = order.firstIndex(of: source), from != index else { return nil }
        var next = order; next.remove(at: from); next.insert(source, at: index); return next
    }
    private static func valid(_ order: [String]) -> Bool {
        !order.isEmpty && order.count <= 1000 && order.allSatisfy { !$0.isEmpty && $0.utf8.count <= 512 } && Set(order).count == order.count
    }
}
