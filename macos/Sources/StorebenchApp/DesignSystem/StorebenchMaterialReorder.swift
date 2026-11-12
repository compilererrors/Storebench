import AppKit
import StorebenchCore
import SwiftUI
import UniformTypeIdentifiers

private let materialDragType = UTType(exportedAs: "app.storebench.material-reorder", conformingTo: .data)

extension View {
    func materialDragSource(id: String, title: String, order: [String], context: String, enabled: Bool, session: MaterialReorder, activate: @escaping () -> Void = {}) -> some View {
        overlay {
            if enabled {
                MaterialDragSource(id: id, title: title, begin: { session.begin(id, order: order, context: context, enabled: enabled) }, count: { session.drag?.sources.count ?? 1 }, end: { session.cancel(token: $0) }, activate: activate)
            }
        }
    }
    func materialDragSource(_ drag: MaterialDrag?) -> some View {
        overlay {
            if let drag {
                Color.clear.materialDragSource(id: drag.id, title: drag.title, order: drag.order, context: drag.context, enabled: drag.enabled, session: drag.session, activate: drag.activate)
            }
        }
    }
    /// Marks one card for the surrounding drop area: it reports its frame and draws where the material will land.
    func materialDropTarget(id: String, session: MaterialReorder) -> some View {
        modifier(MaterialTargetAppearance(id: id, session: session))
    }
    /// One drop area over the whole collection. A drop anywhere in it, including gaps and the empty space after the last card,
    /// lands beside the nearest card in that row.
    func materialDropArea(order: [String], context: String, enabled: Bool, session: MaterialReorder, apply: @escaping ([String], [String], String) -> Bool) -> some View {
        modifier(MaterialDropAreaModifier(order: order, context: context, enabled: enabled, session: session, apply: apply))
    }
}

private struct MaterialTargetAppearance: ViewModifier {
    let id: String, session: MaterialReorder
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.anchorPreference(key: MaterialTargetFrames.self, value: .bounds) { [id: $0] }
            .overlay {
                if session.selection.contains(id) {
                    RoundedRectangle(cornerRadius: StorebenchTheme.measure("assetRadius"))
                        .strokeBorder(StorebenchTheme.accent, style: StrokeStyle(lineWidth: 2, dash: session.drag?.sources.contains(id) == true ? [5, 4] : []))
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if let edge = session.drag?.indicator, edge.id == id {
                    RoundedRectangle(cornerRadius: 2).fill(StorebenchTheme.accent)
                        .frame(width: 3).padding(.vertical, 8)
                        .storebenchControlID("material.insertion.\(edge.id).\(edge.after ? "after" : "before")")
                        .shadow(color: StorebenchTheme.accent.opacity(0.6), radius: 5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: edge.after ? .trailing : .leading)
                        .padding(.horizontal, 1).allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .topTrailing) {
                if session.selection.contains(id) {
                    StorebenchIcon(name: "check", size: 12).foregroundStyle(StorebenchTheme.accent)
                        .frame(width: 22, height: 22).background(StorebenchTheme.surface, in: Circle())
                        .overlay(Circle().strokeBorder(StorebenchTheme.accent, lineWidth: 1.5))
                        .padding(8).allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: session.drag?.indicator)
    }
}

private struct MaterialDropAreaModifier: ViewModifier {
    let order: [String], context: String, enabled: Bool, session: MaterialReorder
    let apply: ([String], [String], String) -> Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.overlayPreferenceValue(MaterialTargetFrames.self) { anchors in
            GeometryReader { geometry in
                let frames = order.compactMap { id in anchors[id].map { (id: id, frame: geometry[$0]) } }
                Color.clear.contentShape(Rectangle())
                    .onDrop(of: [materialDragType], delegate: MaterialDropArea(order: order, context: context, enabled: enabled, reduceMotion: reduceMotion, session: session, frames: frames, apply: apply))
            }
            .allowsHitTesting(session.active)
        }
        .onChange(of: order) { session.invalidate(order: order, context: context, enabled: enabled); session.reconcileSelection(order) }
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
    @Environment(\.materialInteraction) private var interaction
    var body: some View {
        Button {} label: { StorebenchIcon(name: "drag", size: 16) }
            .buttonStyle(StorebenchButtonStyle(.quiet, size: .icon)).storebenchWorking(!enabled)
            .opacity(order.count < 2 ? 0 : 1).allowsHitTesting(order.count > 1).accessibilityHidden(order.count < 2)
            .help("Drag to reorder. Arrow keys move one position; Home and End move to the ends.")
            .accessibilityLabel("Reorder " + title)
            .storebenchControlID("material.handle." + id)
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
                if let interaction {
                    let destination: MaterialReorder.Destination = key.key == .home ? .beginning : key.key == .end ? .end : (key.key == .leftArrow || key.key == .upArrow) ? .earlier : .later
                    interaction.move(destination); return .handled
                }
                if let next = MaterialReorder.moving(order, source: id, to: target) { _ = apply(next, order, context) }
                return .handled
            }
    }
}

struct StorebenchReorderFeedback: View {
    let session: MaterialReorder
    var body: some View {
        StorebenchTextSlot(text: session.announcement.isEmpty ? "Click to select. Command-click for more; Shift-click for a range. Double-click to open. Drag into the highlighted gap to reorder." : session.announcement,
                          height: 34, font: .sbCaption, color: StorebenchTheme.muted, live: true)
            .onChange(of: session.announcement) { _, value in
                if !value.isEmpty { NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [.announcement: value, .priority: NSAccessibilityPriorityLevel.medium.rawValue]) }
            }
    }
}

/// A native source owns cancellation and drag completion on every supported macOS version.
private struct MaterialDragSource: NSViewRepresentable {
    let id, title: String, begin: () -> UUID?, count: () -> Int, end: (UUID) -> Void, activate: () -> Void
    func makeNSView(context: Context) -> MaterialDragView { MaterialDragView() }
    func updateNSView(_ view: MaterialDragView, context: Context) {
        view.title = title; view.begin = begin; view.count = count; view.end = end; view.activate = activate
        view.identifier = .init("material.source." + id)
        view.interaction = context.environment.materialInteraction.flatMap { $0.id == id ? $0 : nil }
        view.enabled = context.environment.isEnabled && context.environment.collectionVisible
        if !view.enabled { view.cancel() }
    }
    static func dismantleNSView(_ view: MaterialDragView, coordinator: ()) { view.cancel(); view.interaction = nil }
}

private final class MaterialDragView: NSView, NSDraggingSource {
    var title = "", begin: (() -> UUID?)?, count: (() -> Int)?, end: ((UUID) -> Void)?, activate: (() -> Void)?
    var interaction: StorebenchMaterialInteraction?
    var enabled = true
    private var starting: CGPoint?, token: UUID?
    private var scrollTimer: Timer?
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); setAccessibilityElement(false) }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { enabled ? super.hitTest(point) : nil }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override var acceptsFirstResponder: Bool { enabled }
    override func mouseDown(with event: NSEvent) {
        guard enabled else { return }
        if event.modifierFlags.contains(.control), interaction != nil { rightMouseDown(with: event); return }
        window?.makeFirstResponder(self)
        interaction?.select(event.modifierFlags, preserving: true)
        starting = convert(event.locationInWindow, from: nil)
    }
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if starting != nil, token == nil, bounds.contains(point) {
            if let interaction {
                if event.clickCount >= 2 { activate?() }
                else if event.modifierFlags.intersection([.command, .shift]).isEmpty { interaction.select() }
            } else { activate?() }
        }
        starting = nil
    }
    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menu(for: event) else { super.rightMouseDown(with: event); return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    override func menu(for event: NSEvent) -> NSMenu? { enabled ? interaction?.nativeMenu() : nil }
    override func keyDown(with event: NSEvent) {
        guard enabled, let interaction, !interaction.session.active else { super.keyDown(with: event); return }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "a" {
            interaction.session.selectAll(interaction.visibleOrder); return
        }
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { super.keyDown(with: event); return }
        switch event.keyCode {
        case 53: interaction.session.clearSelection()
        case 123, 126: interaction.move(.earlier)
        case 124, 125: interaction.move(.later)
        case 115: interaction.move(.beginning)
        case 119: interaction.move(.end)
        default: super.keyDown(with: event)
        }
    }
    override func mouseDragged(with event: NSEvent) {
        guard enabled, token == nil, let starting else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - starting.x, point.y - starting.y) >= 6, let token = begin?() else { return }
        self.token = token
        let item = NSPasteboardItem(); item.setData(Data(token.uuidString.utf8), forType: .init(materialDragType.identifier))
        let dragging = NSDraggingItem(pasteboardWriter: item)
        let selectedCount = count?() ?? 1
        let preview = ImageRenderer(content: VStack(alignment: .leading, spacing: 8) {
            StorebenchLabel(selectedCount == 1 ? "Move Item" : "Move \(selectedCount) Items", icon: "drag", size: 16)
            Text(selectedCount == 1 ? title : "Selected items keep their relative order").font(.sbCaption).lineLimit(2)
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
    let order: [String], context: String, enabled: Bool, reduceMotion: Bool, session: MaterialReorder, frames: [(id: String, frame: CGRect)]
    let apply: ([String], [String], String) -> Bool
    func validateDrop(info: DropInfo) -> Bool { session.matches(order: order, context: context, enabled: enabled) && info.hasItemsConforming(to: [materialDragType]) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return DropProposal(operation: .forbidden) }
        update(info.location)
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) { session.exit() }
    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info) else { return false }
        update(info.location)
        // Our native source writes the opaque ticket synchronously. Commit before AppKit ends the session.
        guard info.itemProviders(for: [materialDragType]).count == 1,
              let data = NSPasteboard(name: .drag).data(forType: .init(materialDragType.identifier)), data.count == 36,
              let value = String(data: data, encoding: .utf8), let token = UUID(uuidString: value),
              let next = session.commit(token: token, order: order, context: context, enabled: enabled) else { return false }
        var accepted = false
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) { accepted = apply(next, order, context) }
        guard accepted else { session.rejected(); return false }; return true
    }
    private func update(_ point: CGPoint) {
        let available = frames.filter { session.drag?.sources.contains($0.id) != true }
        if let slot = MaterialReorder.slot(at: point, frames: available) {
            session.hover(slot.target, after: slot.after, order: order, context: context, enabled: enabled, visibleOrder: frames.map(\.id))
        } else { session.exit() }
    }
}
