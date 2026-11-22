import AppKit
import SwiftUI

/// Keeps a column beside a taller one in view while the page scrolls, such as a guide's step list beside its open step.
/// The column moves with the page until its top reaches the page's top edge, stays there, and stops at the end of the area
/// it sits in. A column taller than the page keeps its end in view instead, so every part of it can still be reached.
/// The column is moved in AppKit in the same frame as the page, so scrolling never asks SwiftUI to draw it again.
struct StorebenchStickyColumn<Content: View>: NSViewRepresentable {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    func makeNSView(context: Context) -> StorebenchStickyColumnView { StorebenchStickyColumnView() }
    func updateNSView(_ view: StorebenchStickyColumnView, context: Context) {
        view.show(AnyView(content.environment(\.self, context.environment)))
    }
    /// The column's own height when nothing else is asked, and the whole area it may move in when its place is given.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: StorebenchStickyColumnView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? view.naturalWidth
        let area = proposal.height.flatMap { $0.isFinite ? $0 : nil } ?? 0
        return CGSize(width: width, height: max(view.height(for: width), area))
    }
}

final class StorebenchStickyColumnView: NSView {
    /// The room kept between the column and the page's top or bottom edge while it is held in view.
    static let margin = StorebenchTheme.space(3)
    private let host = NSHostingController(rootView: AnyView(EmptyView()))
    private var columnHeight: CGFloat = 0
    private weak var page: NSScrollView?
    private var observations: [NSObjectProtocol] = []
    private var joined: [ObjectIdentifier?] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        host.sizingOptions = []
        host.view.postsFrameChangedNotifications = false
        addSubview(host.view)
    }
    required init?(coder: NSCoder) { nil }
    isolated deinit { observations.forEach(NotificationCenter.default.removeObserver) }
    override var isFlipped: Bool { true }
    /// The column takes clicks on its content only; the empty area below it passes them on.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    /// Where the column is in its area, for tests.
    var columnFrame: CGRect { host.view.frame }
    var naturalWidth: CGFloat { host.sizeThatFits(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)).width }
    func height(for width: CGFloat) -> CGFloat {
        host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }
    func show(_ view: AnyView) { host.rootView = view; needsLayout = true }

    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }
    override func setFrameOrigin(_ newOrigin: NSPoint) { super.setFrameOrigin(newOrigin); if page == nil { join() }; place() }
    override func layout() {
        super.layout()
        columnHeight = height(for: bounds.width)
        place()
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); join() }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); join() }
    /// Joins the page it is shown in. SwiftUI can place the view in its window before it is inside the page's scroll view,
    /// so this is tried again whenever the view moves or is placed.
    private func join() {
        let next = window == nil ? nil : enclosingScrollView
        var chain: [NSView] = [], container = superview
        while let view = container, let document = next?.documentView, view !== document { chain.append(view); container = view.superview }
        let identities = ([next as NSView?] + chain).map { $0.map(ObjectIdentifier.init) }
        guard identities != joined else { needsLayout = true; return }
        joined = identities
        observations.forEach(NotificationCenter.default.removeObserver); observations = []
        page = next
        if let page {
            let clip = page.contentView
            clip.postsBoundsChangedNotifications = true
            // Scroll steps are followed at once, so the column moves in the same frame as the page.
            observe(NSView.boundsDidChangeNotification, clip)
            observe(NSView.frameDidChangeNotification, page)
            if let document = page.documentView { document.postsFrameChangedNotifications = true; observe(NSView.frameDidChangeNotification, document) }
            // SwiftUI moves the views that hold this one rather than this view itself, so their moves are followed too.
            for view in chain { view.postsFrameChangedNotifications = true; observe(NSView.frameDidChangeNotification, view) }
        }
        needsLayout = true
    }
    private func observe(_ name: Notification.Name, _ object: NSView) {
        observations.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        })
    }

    /// Puts the column where it is held in view: at the page's top edge, or with its end at the page's bottom edge when
    /// it is taller than the page, and always inside its own area.
    func place() {
        var y: CGFloat = 0
        if let page {
            let clip = page.contentView, insets = clip.contentInsets, visible = convert(clip.bounds, from: clip)
            let top = visible.minY + insets.top, bottom = visible.maxY - insets.bottom, margin = Self.margin
            y = columnHeight + 2 * margin <= bottom - top ? top + margin : bottom - margin - columnHeight
        }
        y = max(0, min(y, bounds.height - columnHeight))
        let frame = backingAlignedRect(CGRect(x: 0, y: y, width: bounds.width, height: columnHeight), options: .alignAllEdgesNearest)
        if host.view.frame != frame { host.view.frame = frame }
    }
}
