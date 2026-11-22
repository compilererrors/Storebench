import AppKit
import ObjectiveC
import StorebenchCore
import SwiftUI

/// Keeps the top of a card that is taller than the page in view while the user scrolls through it, such as one language
/// among many in Localizations. The pinned top covers exactly the card's width and is pushed up by the card's end.
/// Nested cards read outer to inner. Every page scroll view has its own controller, created by the first card that needs it.
/// Scrolling is followed in AppKit in the same frame as the page; SwiftUI draws the pinned top again only when its card changes.
@MainActor final class StorebenchStickyHeaders {
    struct Header: Equatable { let id: String, title: String, subtitle: String, disclosure: Bool }
    static let height: CGFloat = 56

    /// The pinned cards, outermost first.
    private(set) var current: [Header] = []
    /// How often `current` changed, so tests can check that scrolling inside one card changes nothing.
    private(set) var changes = 0
    let pin = StorebenchStickyPinView()
    private let sections = NSHashTable<StorebenchStickySectionView>.weakObjects()
    private weak var page: NSScrollView?
    private var observations: [NSObjectProtocol] = []
    private var scheduled = false

    nonisolated(unsafe) private static var key: UInt8 = 0
    /// The controller of one scroll view; it lives as long as the scroll view.
    static func controller(for scroll: NSScrollView) -> StorebenchStickyHeaders {
        if let existing = objc_getAssociatedObject(scroll, &key) as? StorebenchStickyHeaders { return existing }
        let created = StorebenchStickyHeaders(scroll)
        objc_setAssociatedObject(scroll, &key, created, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return created
    }

    private init(_ scroll: NSScrollView) {
        page = scroll; pin.controller = self; pin.isHidden = true
        let clip = scroll.contentView
        clip.postsBoundsChangedNotifications = true
        // A scroll step is followed at once, so the pinned top moves in the same frame as the page.
        observe(NSView.boundsDidChangeNotification, clip) { $0.update() }
        observe(NSView.frameDidChangeNotification, scroll) { $0.setNeedsUpdate() }
        if let document = scroll.documentView {
            document.postsFrameChangedNotifications = true
            observe(NSView.frameDidChangeNotification, document) { $0.setNeedsUpdate() }
        }
    }

    func add(_ view: StorebenchStickySectionView) { sections.add(view); setNeedsUpdate() }
    func remove(_ view: StorebenchStickySectionView) { sections.remove(view); setNeedsUpdate() }

    /// Layout and card changes are gathered and applied once after the current update.
    func setNeedsUpdate() {
        guard !scheduled else { return }
        scheduled = true
        Task { @MainActor [weak self] in self?.scheduled = false; self?.update() }
    }

    func update() {
        guard let scroll = page else { return }
        let clip = scroll.contentView, flipped = clip.isFlipped, insets = clip.contentInsets
        let edge = flipped ? clip.bounds.minY + insets.top : clip.bounds.maxY - insets.top
        let visible = clip.bounds.height - insets.top - insets.bottom
        var found: [(top: CGFloat, bottom: CGFloat, rect: CGRect, header: Header)] = []
        for view in sections.allObjects {
            guard let header = view.header, view.window === scroll.window, view.enclosingScrollView === scroll, !view.isHiddenOrHasHiddenAncestor else { continue }
            let rect = view.convert(view.bounds, to: clip)
            // Only a card taller than the page needs its top kept in view.
            guard rect.height > visible + 0.5 else { continue }
            let top = flipped ? rect.minY - edge : edge - rect.maxY, bottom = flipped ? rect.maxY - edge : edge - rect.minY
            if top <= 0.5, bottom > 1 { found.append((top, bottom, rect, header)) }
        }
        found.sort { $0.top < $1.top }
        let headers = found.map(\.header)
        if headers != current {
            current = headers; changes += 1
            if !headers.isEmpty { pin.show(headers) }
        }
        guard let inner = found.last else { pin.isHidden = true; return }
        // The pinned top stays at the page's top edge and is pushed up by the card's end.
        let shown = min(Self.height, inner.bottom)
        let area = CGRect(x: inner.rect.minX, y: flipped ? edge : edge - shown, width: inner.rect.width, height: shown)
        if pin.superview !== scroll { scroll.addSubview(pin, positioned: .above, relativeTo: clip) }
        pin.place(clip.convert(area, to: scroll), visibleHeight: shown)
        pin.isHidden = false
    }

    /// Scrolls the page to the top of the innermost pinned card, as if the user scrolled there.
    func showCurrent() {
        guard let page, let id = current.last?.id,
              let view = sections.allObjects.first(where: { $0.header?.id == id && $0.enclosingScrollView === page }) else { return }
        let clip = page.contentView, rect = view.convert(view.bounds, to: clip)
        NotificationCenter.default.post(name: StorebenchNestedScrolling.didRedirect, object: page)
        let y = clip.isFlipped ? rect.minY - clip.contentInsets.top : rect.maxY - clip.bounds.height + clip.contentInsets.top
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y)); page.reflectScrolledClipView(clip)
    }

    private func observe(_ name: Notification.Name, _ object: NSView, _ action: @escaping @MainActor (StorebenchStickyHeaders) -> Void) {
        observations.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        })
    }
}

/// The pinned top of a card. A click goes to the card's top; a scroll passes on to the page behind it.
final class StorebenchStickyPinView: NSView {
    weak var controller: StorebenchStickyHeaders?
    private let host = NSHostingView(rootView: StorebenchPinnedHeading(headers: []))
    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        host.autoresizingMask = [.width]
        addSubview(host)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    /// The heading underneath never takes the click, so it always reaches this view.
    override func hitTest(_ point: NSPoint) -> NSView? { !isHidden && frame.contains(point) ? self : nil }
    override func mouseDown(with event: NSEvent) { controller?.showCurrent() }
    func show(_ headers: [StorebenchStickyHeaders.Header]) { host.rootView = StorebenchPinnedHeading(headers: headers) }
    func place(_ rect: CGRect, visibleHeight: CGFloat) {
        if frame != rect { frame = rect }
        // When the card's end pushes it up, the heading moves up inside the pin and its upper part is clipped.
        let heading = CGRect(x: 0, y: visibleHeight - StorebenchStickyHeaders.height, width: rect.width, height: StorebenchStickyHeaders.height)
        if host.frame != heading { host.frame = heading }
    }
}

/// The card's own top, drawn in the pinned area: its open disclosure, title and description on the card's surface.
struct StorebenchPinnedHeading: View {
    let headers: [StorebenchStickyHeaders.Header]
    var body: some View {
        if let inner = headers.last {
            let title = headers.map(\.title).joined(separator: " › ")
            HStack(alignment: .center, spacing: StorebenchTheme.space(3)) {
                if inner.disclosure {
                    StorebenchIcon(name: "disclosure", size: StorebenchTheme.measure("disclosureIcon"), filled: true).rotationEffect(.degrees(90))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(inner.disclosure ? .sbTitle3.weight(.semibold) : .sbTitle3).foregroundStyle(StorebenchTheme.ink).lineLimit(1).truncationMode(.middle)
                    if !inner.subtitle.isEmpty { Text(inner.subtitle).font(.sbCaption).foregroundStyle(StorebenchTheme.muted).lineLimit(1).truncationMode(.tail) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, StorebenchTheme.padding + (inner.disclosure ? StorebenchTheme.space(2) : 0))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(StorebenchTheme.surface)
            .overlay { Rectangle().strokeBorder(StorebenchTheme.border) }
            .help(inner.subtitle.isEmpty ? "\(title). Click to go to its top." : "\(title) · \(inner.subtitle). Click to go to its top.")
            .accessibilityElement(children: .ignore).accessibilityLabel("Showing \(title)").accessibilityAddTraits(.isHeader)
            .storebenchControlID("page.sticky-header")
        }
    }
}

/// Covers one card, so its scroll view knows where the card starts and ends without SwiftUI measuring it on every scroll step.
struct StorebenchStickySection: NSViewRepresentable {
    let header: StorebenchStickyHeaders.Header
    var active = true
    func makeNSView(context: Context) -> StorebenchStickySectionView { StorebenchStickySectionView() }
    func updateNSView(_ view: StorebenchStickySectionView, context: Context) {
        view.configure(active && context.environment.collectionVisible ? header : nil)
    }
    static func dismantleNSView(_ view: StorebenchStickySectionView, coordinator: ()) { view.configure(nil) }
}

final class StorebenchStickySectionView: NSView {
    private(set) var header: StorebenchStickyHeaders.Header?
    private weak var owner: StorebenchStickyHeaders?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func configure(_ header: StorebenchStickyHeaders.Header?) {
        guard header != self.header else { return }
        self.header = header; register()
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); register() }
    private func register() {
        let scroll = window == nil || header == nil ? nil : enclosingScrollView
        let next = scroll.map(StorebenchStickyHeaders.controller(for:))
        if next !== owner { owner?.remove(self); owner = next }
        if let next { next.add(self) }
    }
}
