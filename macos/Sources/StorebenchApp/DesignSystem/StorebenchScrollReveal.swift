import AppKit
import SwiftUI

/// The newest reveal wins; the second, bounded placement accounts for native control layout.
@MainActor final class StorebenchScrollReveal {
    private var task: Task<Void, Never>?
    func cancel() { task?.cancel(); task = nil }
    func reveal(_ id: String, anchor: UnitPoint, position: @escaping @MainActor (String, UnitPoint) -> Void) {
        cancel()
        task = Task { @MainActor in
            for delay in [0, 80] {
                if delay == 0 { await Task.yield() } else { try? await Task.sleep(for: .milliseconds(delay)) }
                guard !Task.isCancelled else { return }
                position(id, anchor)
            }
        }
    }
}

/// Tracks the actual control in its native scroll views, including sheets and nested inspectors.
/// A delayed layout may move the control again; a newer interaction always ends this placement.
@MainActor final class StorebenchScrollFocus {
    enum Placement { case top, visible, preserve }
    private weak var view: NSView?
    private static let sessions = NSMapTable<NSWindow, Session>.weakToStrongObjects()

    func attach(_ view: NSView) { self.view = view }
    func preserving(_ change: () -> Void) {
        reveal(.preserve)
        var transaction = Transaction(animation: nil); transaction.disablesAnimations = true
        withTransaction(transaction, change)
    }
    /// Also used by native button activation, including keyboard and accessibility commands.
    func interact() { if let window = view?.window { Self.cancel(in: window) } }
    func detach(_ view: NSView) {
        guard self.view === view else { return }
        if let window = view.window, Self.sessions.object(forKey: window)?.anchor === view { Self.cancel(in: window) }
        self.view = nil
    }
    static func cancel(in window: NSWindow) {
        sessions.object(forKey: window)?.cancel(); sessions.removeObject(forKey: window)
    }
    @discardableResult func reveal(_ placement: Placement = .top) -> Bool {
        guard let view, let window = view.window, !view.isHiddenOrHasHiddenAncestor else { return false }
        var ancestor = view.superview, scrolls: [NSScrollView] = []
        while let current = ancestor {
            if let scroll = current as? NSScrollView { scrolls.append(scroll) }
            ancestor = current.superview
        }
        guard !scrolls.isEmpty else { return false }
        Self.cancel(in: window)
        let session = Session(anchor: view, scrolls: scrolls, placement: placement)
        Self.sessions.setObject(session, forKey: window)
        session.start()
        return true
    }

    @MainActor private final class Session {
        private struct Geometry { let anchor, document, viewport: CGRect }
        weak var anchor: NSView?
        private let scrolls: [WeakScroll]
        private let placement: Placement
        private var preservedTop: [ObjectIdentifier: CGFloat] = [:]
        private var space: [ScrollSpace] = []
        private var task: Task<Void, Never>?
        private var inputMonitor: Any?
        private var observations: [NSObjectProtocol] = []
        private var applying = false
        private var cancelled = false
        private var placements: [ObjectIdentifier: Geometry] = [:]
        init(anchor: NSView, scrolls: [NSScrollView], placement: Placement) {
            self.anchor = anchor; self.scrolls = scrolls.map(WeakScroll.init); self.placement = placement
            if placement == .preserve {
                for scroll in scrolls {
                    let clip = scroll.contentView, rect = anchor.convert(anchor.bounds, to: clip)
                    preservedTop[ObjectIdentifier(scroll)] = clip.isFlipped ? rect.minY - clip.bounds.minY : clip.bounds.maxY - rect.maxY
                }
            }
        }
        func start() {
            if placement == .preserve {
                space = scrolls.compactMap { reference in
                    guard let scroll = reference.value, let anchor else { return nil }
                    return ScrollSpace.hold(scroll.contentView, anchor: anchor)
                }
            }
            inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
                MainActor.assumeIsolated { if event.window === self?.anchor?.window { self?.cancel() } }
                return event
            }
            observations.append(NotificationCenter.default.addObserver(forName: StorebenchNestedScrolling.didRedirect, object: nil, queue: .main) { [weak self] note in
                let page = note.object as? NSView
                MainActor.assumeIsolated { if let page, page.window === self?.anchor?.window { self?.cancel() } }
            })
            var ancestor = anchor
            while let view = ancestor {
                view.postsFrameChangedNotifications = true
                view.postsBoundsChangedNotifications = true
                for name in [NSView.frameDidChangeNotification, NSView.boundsDidChangeNotification] {
                    observations.append(NotificationCenter.default.addObserver(forName: name, object: view, queue: .main) { [weak self, weak view] _ in
                        MainActor.assumeIsolated { self?.layoutChanged(clip: view as? NSClipView) }
                    })
                }
                ancestor = view.superview
            }
            layoutChanged()
        }
        private func layoutChanged(clip: NSClipView? = nil) {
            guard !cancelled, !applying else { return }
            if let clip, let document = clip.documentView, let anchor, let previous = placements[ObjectIdentifier(clip)],
               previous.viewport.origin != clip.bounds.origin, previous.viewport.size == clip.bounds.size,
               previous.document == document.bounds, previous.anchor == anchor.convert(anchor.bounds, to: document) {
                // A scroll without a content change is a newer placement, including ScrollViewReader and accessibility.
                cancel(); return
            }
            // Preserve before AppKit draws the layout change, rather than correcting it on a later frame.
            if placement == .preserve { _ = position(layout: false) }
            guard task == nil else { return }
            task = Task { @MainActor [weak self] in
                // Wait for SwiftUI to commit the disclosure before touching the native clip view.
                await Task.yield()
                let clock = ContinuousClock(), deadline = clock.now + .milliseconds(1500)
                var lastGeometry: [CGRect] = [], settledAt = clock.now
                while !Task.isCancelled, let self {
                    guard let geometry = self.position() else { break }
                    if geometry != lastGeometry { lastGeometry = geometry; settledAt = clock.now }
                    // Stop once the actual geometry has settled, rather than assuming two layout passes suffice.
                    if clock.now >= deadline || clock.now - settledAt >= .milliseconds(250) { break }
                    do { try await Task.sleep(for: .milliseconds(16)) } catch { break }
                }
                if let self {
                    self.applying = true
                    for reservation in self.space { reservation.tighten() }
                    self.applying = false; self.task = nil
                }
            }
        }
        private func position(layout: Bool = true) -> [CGRect]? {
            guard let anchor, let window = anchor.window, !anchor.isHiddenOrHasHiddenAncestor else { return nil }
            applying = true
            defer { applying = false }
            if layout { window.contentView?.layoutSubtreeIfNeeded() }
            for reservation in space { reservation.ensure() }
            var geometry: [CGRect] = []
            for (index, reference) in scrolls.enumerated() {
                guard let scroll = reference.value, scroll.window === window, let document = scroll.documentView else { return nil }
                let clip = scroll.contentView, viewport = clip.bounds
                // In an outer page, reveal the inspector's viewport too, so its fields do not sit below the fold.
                let scope: NSView = placement == .preserve || index == 0 ? anchor : (scrolls[index - 1].value?.contentView ?? anchor)
                let rect = scope.convert(scope.bounds, to: clip)
                guard rect.height > 0, viewport.height > 0 else { return nil }
                let inset: CGFloat = 12
                let top = clip.isFlipped ? rect.minY - viewport.minY : viewport.maxY - rect.maxY
                let bottom = clip.isFlipped ? rect.maxY - viewport.minY : viewport.maxY - rect.minY
                var shift: CGFloat = 0
                if placement == .preserve, let target = preservedTop[ObjectIdentifier(scroll)] { shift = top - target }
                else if (index == 0 && placement == .top) || top < inset { shift = top - inset }
                else if bottom > viewport.height - inset {
                    shift = min(top - inset, bottom - viewport.height + inset)
                }
                if abs(shift) > 0.5 {
                    var next = viewport
                    next.origin.y += clip.isFlipped ? shift : -shift
                    next = clip.constrainBoundsRect(next)
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0; context.allowsImplicitAnimation = false
                        clip.scroll(to: next.origin); scroll.reflectScrolledClipView(clip)
                    }
                }
                geometry.append(anchor.convert(anchor.bounds, to: document))
                geometry.append(document.bounds); geometry.append(clip.bounds)
                placements[ObjectIdentifier(clip)] = Geometry(anchor: anchor.convert(anchor.bounds, to: document), document: document.bounds, viewport: clip.bounds)
            }
            if layout { for reservation in space { reservation.tighten() } }
            return geometry
        }
        func cancel() {
            cancelled = true
            task?.cancel(); task = nil
            if let inputMonitor { NSEvent.removeMonitor(inputMonitor); self.inputMonitor = nil }
            for observation in observations { NotificationCenter.default.removeObserver(observation) }
            observations.removeAll()
            for reservation in space { reservation.release() }; space.removeAll()
        }
        isolated deinit { cancel() }
    }
    private final class WeakScroll {
        weak var value: NSScrollView?
        init(_ value: NSScrollView) { self.value = value }
    }

    /// Leave enough native scroll range for a shrinking document, so its bottom does not clamp the
    /// viewport during a disclosure. Release it once ordinary scrolling can continue at the same point.
    @MainActor private final class ScrollSpace {
        private static let owners = NSMapTable<NSClipView, ScrollSpace>.weakToStrongObjects()
        private weak var clip: NSClipView?
        private let original: NSEdgeInsets
        private let adjustedAutomatically: Bool
        private var reservation: CGFloat = 0
        private var startingHeight: CGFloat = 0
        private var protected = true
        private var applying = false
        private var observations: [NSObjectProtocol] = []
        static func hold(_ clip: NSClipView, anchor: NSView) -> ScrollSpace {
            let value = owners.object(forKey: clip) ?? ScrollSpace(clip)
            value.reservation = max(0, clip.bounds.maxY - anchor.convert(anchor.bounds, to: clip).maxY) + 1
            value.startingHeight = clip.bounds.height
            owners.setObject(value, forKey: clip); value.protected = true; value.ensure(); return value
        }
        private init(_ clip: NSClipView) {
            self.clip = clip; original = clip.contentInsets; adjustedAutomatically = clip.automaticallyAdjustsContentInsets
            clip.automaticallyAdjustsContentInsets = false
            for (name, view) in [(NSView.boundsDidChangeNotification, clip as NSView), (NSView.frameDidChangeNotification, clip.documentView ?? clip)] {
                view.postsBoundsChangedNotifications = true; view.postsFrameChangedNotifications = true
                observations.append(NotificationCenter.default.addObserver(forName: name, object: view, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.releaseIfPossible() }
                })
            }
        }
        func ensure() {
            guard let clip, !applying else { return }
            var expanded = original
            if clip.isFlipped { expanded.bottom += reservation + max(0, clip.bounds.height - startingHeight) }
            else { expanded.top += reservation }
            guard clip.contentInsets.top != expanded.top || clip.contentInsets.bottom != expanded.bottom else { return }
            applying = true; let point = clip.bounds.origin
            clip.contentInsets = expanded; clip.scroll(to: point); clip.enclosingScrollView?.reflectScrolledClipView(clip)
            applying = false
        }
        func release() { protected = false; releaseIfPossible() }
        func tighten() {
            guard !applying, let clip, let document = clip.documentView else { return }
            let point = clip.bounds.origin, viewport = clip.bounds
            let leading = max(0, document.frame.minY - viewport.minY)
            let trailing = max(0, viewport.maxY - document.frame.maxY)
            var required = original
            required.top = max(original.top, clip.isFlipped ? leading : trailing)
            required.bottom = max(original.bottom, clip.isFlipped ? trailing : leading)
            applying = true; clip.contentInsets = required; clip.scroll(to: point); clip.enclosingScrollView?.reflectScrolledClipView(clip); applying = false
        }
        private func releaseIfPossible() {
            guard !protected, !applying, let clip, let document = clip.documentView else { return }
            let lower = document.frame.minY - (clip.isFlipped ? original.top : original.bottom)
            let upper = max(lower, document.frame.maxY - clip.bounds.height + (clip.isFlipped ? original.bottom : original.top))
            guard clip.bounds.minY >= lower - 0.5, clip.bounds.minY <= upper + 0.5 else { tighten(); return }
            applying = true; let point = clip.bounds.origin
            clip.contentInsets = original; clip.automaticallyAdjustsContentInsets = adjustedAutomatically
            clip.scroll(to: point); clip.enclosingScrollView?.reflectScrolledClipView(clip)
            for observation in observations { NotificationCenter.default.removeObserver(observation) }; observations.removeAll()
            Self.owners.removeObject(forKey: clip); applying = false
        }
        isolated deinit { for observation in observations { NotificationCenter.default.removeObserver(observation) } }
    }
}

struct StorebenchScrollFocusAnchor: NSViewRepresentable {
    let focus: StorebenchScrollFocus
    func makeNSView(context: Context) -> AnchorView { AnchorView(focus: focus) }
    func updateNSView(_ view: AnchorView, context: Context) { focus.attach(view) }
    static func dismantleNSView(_ view: AnchorView, coordinator: ()) { view.focus.detach(view) }
    final class AnchorView: NSView {
        let focus: StorebenchScrollFocus
        init(focus: StorebenchScrollFocus) { self.focus = focus; super.init(frame: .zero); setAccessibilityElement(false); focus.attach(self) }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { focus.detach(self) }
            super.viewWillMove(toWindow: newWindow)
        }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window != nil { focus.attach(self) } }
    }
}

extension View {
    /// A requested input stays visible while its parent sections finish opening and measuring.
    func scrollFocus(_ ticket: UUID?, active: Bool) -> some View { modifier(StorebenchInputScrollFocus(ticket: ticket, active: active)) }
}
private struct StorebenchInputScrollFocus: ViewModifier {
    private struct Request: Equatable { let ticket: UUID?; let active: Bool }
    let ticket: UUID?, active: Bool
    @State private var focus = StorebenchScrollFocus()
    @Environment(\.pageFocusInteraction) private var interaction
    func body(content: Content) -> some View {
        content.background(StorebenchScrollFocusAnchor(focus: focus))
            .task(id: Request(ticket: ticket, active: active)) {
                guard ticket != nil, active else { return }
                await Task.yield(); guard !Task.isCancelled else { return }
                interaction?()
                focus.reveal(.visible)
            }
    }
}
