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
        public var target: String?, after = false
    }
    public private(set) var drag: Drag?
    public private(set) var announcement = ""
    public init() {}
    public var active: Bool { drag != nil }
    @discardableResult public func begin(_ id: String, order: [String], context: String, enabled: Bool) -> UUID? {
        guard enabled, drag == nil, !context.isEmpty, Self.valid(order), order.count > 1, order.contains(id) else { return nil }
        let token = UUID(); drag = Drag(token: token, context: context, source: id, baseline: order)
        announcement = "Drag to a position. Release to place it; press Escape to cancel."
        return token
    }
    public func matches(order: [String], context: String, enabled: Bool) -> Bool {
        enabled && drag?.context == context && drag?.baseline == order
    }
    public func hover(_ id: String, after: Bool, order: [String], context: String, enabled: Bool) {
        guard matches(order: order, context: context, enabled: enabled), order.contains(id) else { return }
        guard drag?.target != id || drag?.after != after else { return }
        drag?.target = id; drag?.after = after
    }
    public func exit(_ id: String? = nil) { if id == nil || drag?.target == id { drag?.target = nil } }
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
              let next = Self.placing(order, source: drag.source, target: target, after: drag.after), next != order else {
            announcement = "Reordering cancelled. The order is unchanged."; return nil
        }
        announcement = "Moved to position \(next.firstIndex(of: drag.source)! + 1) of \(next.count). Save to keep the new order locally."
        return next
    }
    public static func placing(_ order: [String], source: String, target: String, after: Bool) -> [String]? {
        guard valid(order), source != target, order.contains(source), order.contains(target) else { return nil }
        var next = order.filter { $0 != source }
        guard let index = next.firstIndex(of: target) else { return nil }
        next.insert(source, at: index + (after ? 1 : 0)); return next
    }
    public static func moving(_ order: [String], source: String, to index: Int) -> [String]? {
        guard valid(order), order.indices.contains(index), let from = order.firstIndex(of: source), from != index else { return nil }
        var next = order; next.remove(at: from); next.insert(source, at: index); return next
    }
    private static func valid(_ order: [String]) -> Bool {
        !order.isEmpty && order.count <= 1000 && order.allSatisfy { !$0.isEmpty && $0.utf8.count <= 512 } && Set(order).count == order.count
    }
}
