import AppKit

/// A text box inside a scrolling page scrolls its own text while it has more to show in the scroll's direction, then lets the
/// page scroll, so long text can be read without clicking into it and the page never stops at a box that has nothing more
/// to show. A box being edited always scrolls itself. A gesture keeps the target it started with, including its momentum.
@MainActor final class StorebenchNestedScrolling {
    static let shared = StorebenchNestedScrolling()
    /// Posted with the page before it receives a redirected event, which other event monitors then do not see.
    static let didRedirect = Notification.Name("StorebenchNestedScrollingDidRedirect")
    private var monitor: Any?
    private weak var target: NSScrollView?
    /// When the user last scrolled in each window, with a mouse wheel or a trackpad, on the monotonic clock.
    private var scrolled: [ObjectIdentifier: TimeInterval] = [:]
    /// How long after a scroll step a change of the page still counts as part of the user's scroll.
    static let scrollWindow: TimeInterval = 0.35

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            let redirected = MainActor.assumeIsolated {
                StorebenchNestedScrolling.shared.noteScroll(in: event.window)
                return StorebenchNestedScrolling.shared.redirect(event)
            }
            return redirected ? nil : event
        }
    }

    /// Notes that the user scrolls in a window right now, by a wheel step or a trackpad or momentum step.
    func noteScroll(in window: NSWindow?) {
        guard let window else { return }
        scrolled[ObjectIdentifier(window)] = ProcessInfo.processInfo.systemUptime
    }
    /// True while the user scrolls in a window: a page under the user's hand follows their scroll and nothing else.
    func userIsScrolling(in window: NSWindow?) -> Bool {
        guard let window, let last = scrolled[ObjectIdentifier(window)] else { return false }
        return ProcessInfo.processInfo.systemUptime - last < Self.scrollWindow
    }

    /// True when the page received the event instead of the text box under the pointer.
    private func redirect(_ event: NSEvent) -> Bool {
        let phase = event.phase, momentum = event.momentumPhase
        // A mouse wheel has no phases, so each of its steps is a gesture of its own.
        let discrete = phase.isEmpty && momentum.isEmpty
        // A trackpad's first touch has no direction yet, so the target is chosen when the gesture starts moving.
        if phase.contains(.mayBegin) { target = nil; return false }
        if discrete || phase.contains(.began) { target = Self.page(for: event) }
        guard let page = target, page.window === event.window else { return false }
        NotificationCenter.default.post(name: Self.didRedirect, object: page)
        page.scrollWheel(with: event)
        if discrete || momentum.contains(.ended) || momentum.contains(.cancelled) { target = nil }
        return true
    }

    /// The page behind an unfocused text box under the pointer, or nil when the box scrolls itself: while it is being edited,
    /// or while its text goes on in the direction of the scroll.
    static func page(for event: NSEvent) -> NSScrollView? {
        guard let window = event.window, let content = window.contentView else { return nil }
        let point = content.superview.map { $0.convert(event.locationInWindow, from: nil) } ?? event.locationInWindow
        guard let hit = content.hitTest(point), let box = hit.enclosingScrollViewIncludingSelf,
              let text = box.documentView as? NSTextView, window.firstResponder !== text else { return nil }
        if canScroll(box, by: event.scrollingDeltaY) { return nil }
        return box.superview?.enclosingScrollView
    }
    /// True when a scroll by `delta` (positive toward the top, as AppKit reports it) still moves the box's own text.
    static func canScroll(_ box: NSScrollView, by delta: CGFloat) -> Bool {
        guard delta != 0, let document = box.documentView else { return false }
        let clip = box.contentView, visible = clip.documentVisibleRect, height = document.frame.height
        guard height > visible.height + 0.5 else { return false }
        let atTop = document.isFlipped ? visible.minY <= 0.5 : visible.maxY >= height - 0.5
        let atBottom = document.isFlipped ? visible.maxY >= height - 0.5 : visible.minY <= 0.5
        return delta > 0 ? !atTop : !atBottom
    }
}

private extension NSView {
    var enclosingScrollViewIncludingSelf: NSScrollView? { (self as? NSScrollView) ?? enclosingScrollView }
}
