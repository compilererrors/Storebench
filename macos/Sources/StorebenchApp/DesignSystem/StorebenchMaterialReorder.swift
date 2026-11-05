import AppKit
import StorebenchCore
import SwiftUI
import UniformTypeIdentifiers

private let materialDragType = UTType(exportedAs: "app.storebench.material-reorder", conformingTo: .data)

extension View {
    func materialDragSource(id: String, title: String, order: [String], context: String, enabled: Bool, session: MaterialReorder, activate: @escaping () -> Void = {}) -> some View {
        overlay {
            if enabled {
                MaterialDragSource(title: title, begin: { session.begin(id, order: order, context: context, enabled: enabled) }, end: { session.cancel(token: $0) }, activate: activate)
            }
        }
    }
    func materialDragSource(_ drag: MaterialDrag?) -> some View {
        overlay {
            if let drag {
                Color.clear.materialDragSource(id: drag.id, title: drag.title, order: drag.order, context: drag.context, enabled: drag.enabled && drag.order.count > 1, session: drag.session, activate: drag.activate)
            }
        }
    }
    /// Marks one card for the surrounding drop area: it reports its frame and draws where the material will land.
    func materialDropTarget(id: String, session: MaterialReorder) -> some View {
        anchorPreference(key: MaterialTargetFrames.self, value: .bounds) { [id: $0] }
        .overlay {
            if session.drag?.target == id, session.drag?.source != id {
                RoundedRectangle(cornerRadius: StorebenchTheme.radius).strokeBorder(StorebenchTheme.accent, lineWidth: 2).allowsHitTesting(false)
                if let drag = session.drag {
                    RoundedRectangle(cornerRadius: 2).fill(StorebenchTheme.accent).frame(width: 3)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: drag.after ? .trailing : .leading)
                        .padding(4).allowsHitTesting(false)
                }
            }
        }
        .overlay {
            if session.drag?.source == id {
                RoundedRectangle(cornerRadius: StorebenchTheme.radius).strokeBorder(StorebenchTheme.accent, style: StrokeStyle(lineWidth: 2, dash: [5, 4])).allowsHitTesting(false)
            }
        }
    }
    /// One drop area over the whole collection. A drop anywhere in it, including gaps and the empty space after the last card,
    /// lands beside the nearest card in that row.
    func materialDropArea(order: [String], context: String, enabled: Bool, session: MaterialReorder, apply: @escaping ([String], [String], String) -> Bool) -> some View {
        overlayPreferenceValue(MaterialTargetFrames.self) { anchors in
            GeometryReader { geometry in
                let frames = order.compactMap { id in anchors[id].map { (id: id, frame: geometry[$0]) } }
                Color.clear.contentShape(Rectangle())
                    .onDrop(of: [materialDragType], delegate: MaterialDropArea(order: order, context: context, enabled: enabled, session: session, frames: frames, apply: apply))
            }
            .allowsHitTesting(session.active)
        }
        .onChange(of: order) { session.invalidate(order: order, context: context, enabled: enabled) }
        .onChange(of: enabled) { session.invalidate(order: order, context: context, enabled: enabled) }
        .onChange(of: context) { session.cancel() }
    }
}

/// What a card's name, details and preview need to start moving it.
struct MaterialDrag {
    let id, title, context: String, order: [String], enabled: Bool, session: MaterialReorder
    var activate: () -> Void = {}
}

private struct MaterialTargetFrames: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) { value.merge(nextValue()) { $1 } }
}

struct StorebenchReorderHandle: View {
    let id, title, context: String, order: [String], enabled: Bool, session: MaterialReorder
    let apply: ([String], [String], String) -> Bool
    @FocusState private var focused: Bool
    var body: some View {
        Button {} label: { StorebenchIcon(name: "drag", size: 16) }
            .buttonStyle(StorebenchButtonStyle(.quiet, size: .icon)).storebenchWorking(!enabled)
            .opacity(order.count < 2 ? 0 : 1).allowsHitTesting(order.count > 1).accessibilityHidden(order.count < 2)
            .help("Drag to reorder. Arrow keys move one position; Home and End move to the ends.")
            .accessibilityLabel("Reorder " + title)
            .focused($focused)
            .materialDragSource(id: id, title: title, order: order, context: context, enabled: enabled && order.count > 1, session: session, activate: { focused = true })
            .onKeyPress { key in
                guard enabled, !session.active, key.modifiers.isEmpty, let index = order.firstIndex(of: id) else { return .ignored }
                let target: Int
                switch key.key {
                case .leftArrow, .upArrow: target = max(0, index - 1)
                case .rightArrow, .downArrow: target = min(order.count - 1, index + 1)
                case .home: target = 0
                case .end: target = order.count - 1
                default: return .ignored
                }
                if let next = MaterialReorder.moving(order, source: id, to: target) { _ = apply(next, order, context) }
                return .handled
            }
    }
}

struct StorebenchReorderFeedback: View {
    let session: MaterialReorder
    var body: some View {
        StorebenchTextSlot(text: session.announcement, height: 34, font: .sbCaption, color: StorebenchTheme.muted, live: true)
            .onChange(of: session.announcement) { _, value in
                if !value.isEmpty { NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [.announcement: value, .priority: NSAccessibilityPriorityLevel.medium.rawValue]) }
            }
    }
}

/// A native source owns cancellation and drag completion on every supported macOS version.
private struct MaterialDragSource: NSViewRepresentable {
    let title: String, begin: () -> UUID?, end: (UUID) -> Void, activate: () -> Void
    func makeNSView(context: Context) -> MaterialDragView { MaterialDragView() }
    func updateNSView(_ view: MaterialDragView, context: Context) {
        view.title = title; view.begin = begin; view.end = end; view.activate = activate
        view.enabled = context.environment.isEnabled && context.environment.collectionVisible
        if !view.enabled { view.cancel() }
    }
    static func dismantleNSView(_ view: MaterialDragView, coordinator: ()) { view.cancel() }
}

private final class MaterialDragView: NSView, NSDraggingSource {
    var title = "", begin: (() -> UUID?)?, end: ((UUID) -> Void)?, activate: (() -> Void)?
    var enabled = true
    private var starting: CGPoint?, token: UUID?
    private var scrollTimer: Timer?
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); setAccessibilityElement(false) }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { enabled ? super.hitTest(point) : nil }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) { starting = convert(event.locationInWindow, from: nil) }
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if starting != nil, token == nil, bounds.contains(point) { activate?() }
        starting = nil
    }
    override func mouseDragged(with event: NSEvent) {
        guard enabled, token == nil, let starting else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - starting.x, point.y - starting.y) >= 6, let token = begin?() else { return }
        self.token = token
        let item = NSPasteboardItem(); item.setData(Data(token.uuidString.utf8), forType: .init(materialDragType.identifier))
        let dragging = NSDraggingItem(pasteboardWriter: item)
        let preview = ImageRenderer(content: VStack(alignment: .leading, spacing: 8) {
            StorebenchLabel("Move material", icon: "drag", size: 16)
            Text(title).font(.sbCaption).lineLimit(2)
        }.font(.sbCallout).padding(12).frame(width: 180, height: 80).foregroundStyle(StorebenchTheme.ink).background(StorebenchTheme.surface, in: RoundedRectangle(cornerRadius: 8)))
        dragging.setDraggingFrame(CGRect(x: point.x - 12, y: point.y - 12, width: 180, height: 80), contents: preview.nsImage)
        let session = beginDraggingSession(with: [dragging], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        let timer = Timer(timeInterval: 1.0 / 60, target: self, selector: #selector(scrollDuringDrag), userInfo: nil, repeats: true)
        scrollTimer = timer
        RunLoop.main.add(timer, forMode: .eventTracking); RunLoop.main.add(timer, forMode: .common)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { context == .withinApplication ? .move : [] }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { cancel() }
    func cancel() { scrollTimer?.invalidate(); scrollTimer = nil; if let token { end?(token) }; token = nil; starting = nil }
    @objc private func scrollDuringDrag() {
        guard enabled, token != nil, let window, let scroll = enclosingScrollView, let document = scroll.documentView else { return }
        let clip = scroll.contentView, visible = clip.bounds
        let point = clip.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        guard visible.contains(point) else { return }
        let horizontal = document.frame.width > visible.width ? MaterialReorder.scrollStep(position: point.x - visible.minX, length: visible.width) : 0
        let vertical = document.frame.height > visible.height ? MaterialReorder.scrollStep(position: point.y - visible.minY, length: visible.height) : 0
        guard horizontal != 0 || vertical != 0 else { return }
        var next = visible; next.origin.x += horizontal; next.origin.y += vertical
        let constrained = clip.constrainBoundsRect(next)
        if constrained.origin != visible.origin { clip.scroll(to: constrained.origin); scroll.reflectScrolledClipView(clip) }
    }
}

private struct MaterialDropArea: DropDelegate {
    let order: [String], context: String, enabled: Bool, session: MaterialReorder, frames: [(id: String, frame: CGRect)]
    let apply: ([String], [String], String) -> Bool
    func validateDrop(info: DropInfo) -> Bool { session.matches(order: order, context: context, enabled: enabled) && info.hasItemsConforming(to: [materialDragType]) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return DropProposal(operation: .forbidden) }
        if let slot = MaterialReorder.slot(at: info.location, frames: frames) { session.hover(slot.target, after: slot.after, order: order, context: context, enabled: enabled) }
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) { session.exit() }
    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info) else { return false }
        if let slot = MaterialReorder.slot(at: info.location, frames: frames) { session.hover(slot.target, after: slot.after, order: order, context: context, enabled: enabled) }
        // Our native source writes the opaque ticket synchronously. Commit before AppKit ends the session.
        guard info.itemProviders(for: [materialDragType]).count == 1,
              let data = NSPasteboard(name: .drag).data(forType: .init(materialDragType.identifier)), data.count == 36,
              let value = String(data: data, encoding: .utf8), let token = UUID(uuidString: value),
              let next = session.commit(token: token, order: order, context: context, enabled: enabled) else { return false }
        guard apply(next, order, context) else { session.rejected(); return false }; return true
    }
}
