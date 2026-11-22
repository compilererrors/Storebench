import AppKit
import ObjectiveC
import SwiftUI

/// Keeps what the user is looking at in place when content above it changes height, such as a checklist row that is resolved
/// or a status that is read again. Each scrolled page and dialog has its own controller, created by the first card or row in it.
///
/// The anchor is the first card or row that starts in view, inside the innermost one that crosses the top edge; when no such
/// element starts in view, it is that crossing element itself. When the anchor is removed, such as a resolved row, the next
/// one below it is kept in place instead, so the content below takes its place without moving. Whenever content moves while the user has not scrolled, the
/// page is moved by the same amount in the same layout pass, before anything is drawn. A page at its top stays at its top,
/// and a field the app is placing in view keeps its own placement until the user scrolls. While the user scrolls, with a
/// mouse wheel, a trackpad or its momentum, the page follows only them: content that changes meanwhile never pulls it back.
@MainActor final class StorebenchScrollAnchoring {
    private struct Anchor { weak var view: NSView?; let offset: CGFloat }
    private struct Mark { weak var view: NSView?; let rect: CGRect }
    private let marks = NSHashTable<StorebenchScrollAnchorView>.weakObjects()
    private weak var page: NSScrollView?
    private var anchors: [Anchor] = []
    /// Every card's and row's place in the document. Scrolling does not change it, so a scroll step only does arithmetic; a
    /// layout change clears it and the next new anchor measures the page once.
    private var placesInDocument: [Mark]?
    private var atTop = true
    private var documentHeight: CGFloat = 0
    /// False until the page's position was read once; before that a scroll is the user's, never a layout change to undo.
    private var known = false
    private var applying = false
    /// True between the start and end of a live scroll, such as a trackpad gesture with its momentum.
    private var live = false
    private var observations: [NSObjectProtocol] = []
    /// How often the page was moved to keep its content in place, so tests can tell a held page from one that never moved.
    private(set) var corrections = 0
    /// How many cards and rows were measured, so tests can tell that scrolling and loading stay cheap.
    private(set) var measurements = 0
    /// How often content moved and the anchor was checked.
    private(set) var restores = 0
    /// The cards and rows in this page, so tests can tell that they joined it.
    var marked: Int { marks.allObjects.count }

    nonisolated(unsafe) private static var key: UInt8 = 0
    static func controller(for scroll: NSScrollView) -> StorebenchScrollAnchoring {
        if let existing = objc_getAssociatedObject(scroll, &key) as? StorebenchScrollAnchoring { return existing }
        let created = StorebenchScrollAnchoring(scroll)
        objc_setAssociatedObject(scroll, &key, created, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return created
    }

    private init(_ scroll: NSScrollView) {
        page = scroll
        let clip = scroll.contentView
        clip.postsBoundsChangedNotifications = true
        observe(NSView.boundsDidChangeNotification, clip) { $0.scrolled() }
        observe(NSView.frameDidChangeNotification, scroll) { $0.contentMoved() }
        observe(NSScrollView.willStartLiveScrollNotification, scroll) { $0.live = true }
        observe(NSScrollView.didEndLiveScrollNotification, scroll) { $0.live = false; $0.record() }
        if let document = scroll.documentView {
            document.postsFrameChangedNotifications = true
            observe(NSView.frameDidChangeNotification, document) { $0.contentMoved() }
        }
    }

    /// A new card or row only clears the measured places; nothing is measured until an anchor is needed.
    func add(_ view: StorebenchScrollAnchorView) { marks.add(view); placesInDocument = nil }
    func remove(_ view: StorebenchScrollAnchorView) { marks.remove(view); placesInDocument = nil }

    /// The user is scrolling this page right now, so it follows their scroll alone.
    private var userScrolling: Bool { live || StorebenchNestedScrolling.shared.userIsScrolling(in: page?.window) }

    /// A card or row moved during layout: put the anchor back before the frame is drawn. While the user scrolls, the
    /// change is part of their scroll, such as rows shown as they come into view, so the page is left where they put it.
    func contentMoved() {
        placesInDocument = nil
        guard !applying else { return }
        if userScrolling { record(); return }
        restore()
    }

    /// The clip view moved. A move without a change of content height is a scroll, by the user or by the app placing a field,
    /// and sets a new anchor. A move with one is AppKit keeping the clip inside a document that changed, so the anchor is kept.
    private func scrolled() {
        guard !applying, let document = page?.documentView else { return }
        if !userScrolling, known, abs(document.frame.height - documentHeight) > 0.5 { restore() } else { record() }
    }

    /// The top edge of the visible area, in document coordinates, and the visible height.
    private func viewport(_ scroll: NSScrollView, _ document: NSView) -> (top: CGFloat, height: CGFloat) {
        let clip = scroll.contentView, visible = document.convert(clip.bounds, from: clip)
        let height = clip.bounds.height - clip.contentInsets.top - clip.contentInsets.bottom
        return (document.isFlipped ? visible.minY + clip.contentInsets.top : visible.maxY - clip.contentInsets.top, height)
    }
    /// A place in the document measured from the visible top edge: positive below it.
    private func distance(_ rect: CGRect, from top: CGFloat, flipped: Bool) -> (top: CGFloat, bottom: CGFloat) {
        flipped ? (rect.minY - top, rect.maxY - top) : (top - rect.maxY, top - rect.minY)
    }
    private func measure(_ view: NSView, in document: NSView) -> CGRect? {
        guard let scroll = page, view.window === scroll.window, view.window != nil, view.enclosingScrollView === scroll, !view.isHiddenOrHasHiddenAncestor else { return nil }
        measurements += 1
        let rect = view.convert(view.bounds, to: document)
        return rect.height > 0 ? rect : nil
    }
    private func places(in document: NSView) -> [Mark] {
        if let placesInDocument { return placesInDocument }
        let measured = marks.allObjects.compactMap { view in measure(view, in: document).map { Mark(view: view, rect: $0) } }
        placesInDocument = measured
        return measured
    }

    private static func top(_ clip: NSClipView) -> Bool {
        let documentTop = clip.documentView.map { clip.isFlipped ? $0.frame.minY : $0.frame.maxY } ?? 0
        return clip.isFlipped ? clip.bounds.minY + clip.contentInsets.top <= documentTop + 0.5 : clip.bounds.maxY - clip.contentInsets.top >= documentTop - 0.5
    }

    private struct Placed { let view: NSView; let top, bottom: CGFloat }
    private func record() {
        guard let scroll = page, let document = scroll.documentView else { return }
        documentHeight = document.frame.height; known = true
        atTop = Self.top(scroll.contentView)
        // A page at its top keeps its top, so it needs no anchor and measures nothing.
        guard !atTop else { anchors = []; return }
        let (edge, visible) = viewport(scroll, document)
        let all = places(in: document).compactMap { mark -> Placed? in
            guard let view = mark.view else { return nil }
            let place = distance(mark.rect, from: edge, flipped: document.isFlipped)
            return Placed(view: view, top: place.top, bottom: place.bottom)
        }
        let crossing = all.filter { $0.top < -0.5 && $0.bottom > 0.5 }.min { $0.bottom - $0.top < $1.bottom - $1.top }
        let starting = all.filter { item in
            guard item.top >= -0.5, item.top < visible else { return false }
            guard let crossing else { return true }
            return item.bottom <= crossing.bottom + 0.5
        }.sorted { $0.top < $1.top }
        // The first card or row in view is held. When it is removed, such as a resolved row or a removed language, what is
        // above it is held instead, so nothing above moves and what is below moves up into the gap, as in Mail or Finder.
        var chosen: [Placed] = []
        if let first = starting.first { chosen.append(first) }
        if let crossing { chosen.append(crossing) }
        if let above = all.filter({ $0.bottom <= 0.5 }).max(by: { $0.bottom < $1.bottom }) { chosen.append(above) }
        if chosen.isEmpty, let next = all.filter({ $0.top >= -0.5 }).min(by: { $0.top < $1.top }) { chosen.append(next) }
        anchors = chosen.map { Anchor(view: $0.view, offset: $0.top) }
    }

    /// Only the anchors are measured, so a burst of layout changes while a page loads stays cheap.
    private func restore() {
        guard let scroll = page, let document = scroll.documentView else { return }
        restores += 1
        let clip = scroll.contentView
        defer { documentHeight = document.frame.height }
        // Until the page's position was read once there is nothing to keep; reading it now measures nothing at the top.
        guard known else { record(); return }
        // A field being placed in view, such as an opened disclosure or a focused input, keeps its own placement.
        if let window = scroll.window, StorebenchScrollFocus.placing(in: window) { record(); return }
        if atTop {
            guard !Self.top(clip) else { return }
            let documentTop = clip.isFlipped ? document.frame.minY - clip.contentInsets.top : document.frame.maxY - clip.bounds.height + clip.contentInsets.top
            move(clip, scroll, to: documentTop); return
        }
        let edge = viewport(scroll, document).top
        for anchor in anchors {
            // A card or row that left the page, such as a resolved row still fading out, hands over to the next anchor.
            guard let view = anchor.view as? StorebenchScrollAnchorView, marks.contains(view), let rect = measure(view, in: document) else { continue }
            let shift = distance(rect, from: edge, flipped: document.isFlipped).top - anchor.offset
            if abs(shift) > 0.5 { move(clip, scroll, to: clip.bounds.minY + (clip.isFlipped ? shift : -shift)) }
            return
        }
        record()
    }

    private func move(_ clip: NSClipView, _ scroll: NSScrollView, to y: CGFloat) {
        var next = clip.bounds; next.origin.y = y
        next = clip.constrainBoundsRect(next)
        guard abs(next.origin.y - clip.bounds.minY) > 0.5 else { return }
        applying = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0; context.allowsImplicitAnimation = false
            clip.scroll(to: next.origin); scroll.reflectScrolledClipView(clip)
        }
        applying = false; corrections += 1
    }

    private func observe(_ name: Notification.Name, _ object: NSView, _ action: @escaping @MainActor (StorebenchScrollAnchoring) -> Void) {
        // Handled as it is posted, inside the layout pass that moved the content, rather than on a later turn after drawing.
        observations.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        })
    }
}

/// Covers one card or row, so its page knows what the user is looking at without SwiftUI measuring anything on each scroll step.
struct StorebenchScrollAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> StorebenchScrollAnchorView { StorebenchScrollAnchorView() }
    func updateNSView(_ view: StorebenchScrollAnchorView, context: Context) { view.join() }
    static func dismantleNSView(_ view: StorebenchScrollAnchorView, coordinator: ()) { view.leave() }
}

final class StorebenchScrollAnchorView: NSView {
    private weak var owner: StorebenchScrollAnchoring?
    private var watched: [NSObjectProtocol] = []
    private var watchedChain: [ObjectIdentifier] = []
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    /// Joins the page it is shown in. SwiftUI can place the view in its window before it is inside the page's scroll view, so
    /// this is tried again whenever the view moves or is placed.
    func join() {
        let scroll = window == nil ? nil : enclosingScrollView
        let next = scroll.map(StorebenchScrollAnchoring.controller(for:))
        if next !== owner { owner?.remove(self); owner = next; next?.add(self) }
        watchContainers(up: scroll?.documentView)
    }
    /// SwiftUI moves the views that hold this one rather than this view itself, so their moves are followed as they happen.
    private func watchContainers(up document: NSView?) {
        var chain: [NSView] = [], container = superview
        while let view = container, let document, view !== document { chain.append(view); container = view.superview }
        let identities = chain.map(ObjectIdentifier.init)
        guard identities != watchedChain else { return }
        stopWatching(); watchedChain = identities
        for view in chain {
            view.postsFrameChangedNotifications = true
            watched.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.owner?.contentMoved() }
            })
        }
    }
    private func stopWatching() {
        for observation in watched { NotificationCenter.default.removeObserver(observation) }
        watched.removeAll(); watchedChain = []
    }
    isolated deinit { stopWatching() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); join() }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); join() }
    override func setFrameOrigin(_ origin: NSPoint) {
        let moved = origin != frame.origin
        super.setFrameOrigin(origin)
        if owner == nil { join() }
        if moved { owner?.contentMoved() }
    }
    override func setFrameSize(_ size: NSSize) {
        let changed = size != frame.size
        super.setFrameSize(size)
        if owner == nil { join() }
        if changed { owner?.contentMoved() }
    }
    func leave() { owner?.remove(self); owner = nil; stopWatching() }
}

extension View {
    /// Marks a card or row that its page keeps in place while content above it changes.
    func storebenchScrollAnchor() -> some View { background { StorebenchScrollAnchor().accessibilityHidden(true) } }
}
