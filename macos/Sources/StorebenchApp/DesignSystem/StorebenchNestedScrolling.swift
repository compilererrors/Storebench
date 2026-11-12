import AppKit

/// A text box inside a scrolling page scrolls the page until the box is being edited, so the page never stops
/// under the pointer while it passes text boxes. A gesture keeps the target it started with, including its momentum.
@MainActor final class StorebenchNestedScrolling {
    static let shared = StorebenchNestedScrolling()
    /// Posted with the page before it receives a redirected event, which other event monitors then do not see.
    static let didRedirect = Notification.Name("StorebenchNestedScrollingDidRedirect")
    private var monitor: Any?
    private weak var target: NSScrollView?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            let redirected = MainActor.assumeIsolated { StorebenchNestedScrolling.shared.redirect(event) }
            return redirected ? nil : event
        }
    }

    /// True when the page received the event instead of the text box under the pointer.
    private func redirect(_ event: NSEvent) -> Bool {
        let phase = event.phase, momentum = event.momentumPhase
        // A mouse wheel has no phases, so each of its steps is a gesture of its own.
        let discrete = phase.isEmpty && momentum.isEmpty
        if discrete || phase.contains(.mayBegin) || phase.contains(.began) { target = Self.page(for: event) }
        guard let page = target, page.window === event.window else { return false }
        NotificationCenter.default.post(name: Self.didRedirect, object: page)
        page.scrollWheel(with: event)
        if discrete || momentum.contains(.ended) || momentum.contains(.cancelled) { target = nil }
        return true
    }

    /// The page behind an unfocused text box under the pointer, or nil when the box scrolls itself.
    static func page(for event: NSEvent) -> NSScrollView? {
        guard let window = event.window, let content = window.contentView else { return nil }
        let point = content.superview.map { $0.convert(event.locationInWindow, from: nil) } ?? event.locationInWindow
        guard let hit = content.hitTest(point), let box = hit.enclosingScrollViewIncludingSelf,
              let text = box.documentView as? NSTextView, window.firstResponder !== text else { return nil }
        return box.superview?.enclosingScrollView
    }
}

private extension NSView {
    var enclosingScrollViewIncludingSelf: NSScrollView? { (self as? NSScrollView) ?? enclosingScrollView }
}
