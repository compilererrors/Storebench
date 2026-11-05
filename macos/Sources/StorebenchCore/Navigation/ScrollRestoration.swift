import Foundation

/// Wait for asynchronous page content before restoring an offset. A user gesture wins immediately.
public struct ScrollRestoration: Sendable {
    public private(set) var target: CGPoint?
    public init(_ target: CGPoint?) {
        self.target = target.map { CGPoint(x: $0.x.isFinite ? max(0, $0.x) : 0, y: $0.y.isFinite ? max(0, $0.y) : 0) }
    }
    public mutating func cancel() { target = nil }
    public mutating func resolve(content: CGSize, viewport: CGSize, finishedWaiting: Bool = false) -> CGPoint? {
        guard let target else { return nil }
        let maxX = max(0, content.width - viewport.width), maxY = max(0, content.height - viewport.height)
        guard finishedWaiting || (maxX >= target.x && maxY >= target.y) else { return nil }
        self.target = nil
        return CGPoint(x: min(target.x, maxX), y: min(target.y, maxY))
    }
}
