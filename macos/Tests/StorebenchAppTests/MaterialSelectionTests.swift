import AppKit
import Observation
import SwiftUI
import Testing
@testable import StorebenchApp
@testable import StorebenchCore

@MainActor @Observable final class MaterialSelectionPresentation {
    var order = (1...9).map { "synthetic-\($0)" }
    let reorder = MaterialReorder()
    var context = "synthetic-language-display-size"
    var busy = false
    var opened = 0
    var removed: [String] = []
    func apply(_ next: [String], _ expected: [String], _ context: String) -> Bool {
        guard !busy, self.context == context, order == expected, next.count == order.count, Set(next) == Set(order) else { return false }
        order = next; return true
    }
}

@MainActor private struct MaterialSelectionFixture: View {
    let model: MaterialSelectionPresentation
    var body: some View {
        StorebenchMetricGrid(maximumColumns: 3, minimumWidth: 240, spacing: 16) {
            ForEach(Array(model.order.enumerated()), id: \.element) { index, id in
                StorebenchAssetCard(title: id + ".png", metadata: "Synthetic screenshot", status: "", position: index + 1, previewHeight: 100, compact: true,
                    drag: MaterialDrag(id: id, title: id, context: model.context, order: model.order, enabled: !model.busy, session: model.reorder, activate: { model.opened += 1 })) {
                    RoundedRectangle(cornerRadius: 6).fill(StorebenchTheme.color("color-surface-accent"))
                        .overlay { Text(id).font(.sbHeadline) }
                        .materialDragSource(id: id, title: id, order: model.order, context: model.context, enabled: !model.busy, session: model.reorder, activate: { model.opened += 1 })
                } actions: { StorebenchMaterialToolbar() }
                .materialReorderCard(id: id, title: id, order: model.order, context: model.context, enabled: !model.busy, session: model.reorder,
                    apply: model.apply, open: { model.opened += 1 }, remove: { model.removed.append(id) })
            }
        }
        .materialDropArea(order: model.order, context: model.context, enabled: !model.busy, session: model.reorder, apply: model.apply)
    }
}

@MainActor @Suite(.serialized) struct MaterialSelectionTests {
    init() throws { _ = try TestIsolation.require() }
    @MainActor private final class Window {
        enum Failure: Error { case timeout(String), missingSource }
        let window: NSWindow, host: NSHostingView<AnyView>
        init(_ model: MaterialSelectionPresentation, withoutAnimations: Bool = false) {
            _ = NSApplication.shared
            window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1100, height: 1000), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            host = NSHostingView(rootView: AnyView(ScrollView {
                MaterialSelectionFixture(model: model).padding(20)
            }.modifier(StorebenchAppearance()).transaction {
                if withoutAnimations { $0.animation = nil; $0.disablesAnimations = true }
            }))
            window.contentView = host; window.makeKeyAndOrderFront(nil)
        }
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        func marker(_ id: String) -> StorebenchControlMarker? { views(host).compactMap { $0 as? StorebenchControlMarker }.first { $0.identifier?.rawValue == id } }
        func settle() async throws { host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try await Task.sleep(for: .milliseconds(40)) }
        func wait(file: StaticString = #fileID, line: UInt = #line, _ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(12)
            while !condition() { guard ContinuousClock.now < deadline else { throw Failure.timeout("\(file):\(line)") }; try await settle() }
            try await settle()
        }
        func source(_ id: String) async throws -> NSView {
            try await wait { marker("material.card." + id) != nil }
            let card = try #require(marker("material.card." + id))
            card.scrollToVisible(card.bounds)
            for _ in 0..<4 { try await settle() }
            return try #require(views(host).filter {
                $0.identifier?.rawValue == "material.source." + id
            }.max { $0.convert($0.bounds, to: nil).midY < $1.convert($1.bounds, to: nil).midY })
        }
        func event(_ type: NSEvent.EventType, in view: NSView, modifiers: NSEvent.ModifierFlags = [], count: Int = 1) throws -> NSEvent {
            let point = view.convert(.init(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            return try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: type == .leftMouseDown ? 1 : 0))
        }
        func click(_ id: String, modifiers: NSEvent.ModifierFlags = [], count: Int = 1) async throws {
            let view = try await source(id)
            view.mouseDown(with: try event(.leftMouseDown, in: view, modifiers: modifiers, count: count))
            view.mouseUp(with: try event(.leftMouseUp, in: view, modifiers: modifiers, count: count))
            try await settle()
        }
        func menu(_ id: String) async throws -> NSMenu {
            let view = try await source(id)
            return try #require(view.menu(for: try event(.rightMouseDown, in: view)))
        }
        func invoke(_ title: String, menu: NSMenu) throws {
            let item = try #require(menu.items.first { $0.title == title }), action = try #require(item.action)
            #expect(item.isEnabled && NSApp.sendAction(action, to: item.target, from: item))
        }
        func capture(_ name: String) throws {
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: TestIsolation.require().appendingPathComponent(name + ".png"))
        }
        func close() { window.makeFirstResponder(nil); window.contentView = nil; window.orderOut(nil); window.close() }
    }

    @Test func commandClickAndTheNativeContextMenuMoveTheWholeSelection() async throws {
        let model = MaterialSelectionPresentation(), ui = Window(model), original = model.order
        defer { ui.close() }
        try await ui.click(original[3]); try await ui.click(original[1], modifiers: .command)
        #expect(model.reorder.selection == [original[1], original[3]] && model.opened == 0 && model.order == original)
        let menu = try await ui.menu(original[3])
        #expect(menu.items.contains { $0.title == "Move 2 Items to Beginning" })
        #expect(!menu.items.contains { $0.title == "Remove" })
        try ui.invoke("Move 2 Items to Beginning", menu: menu)
        try await ui.wait { model.order == [original[1], original[3], original[0], original[2]] + Array(original[4...]) }
        #expect(model.reorder.selection == [original[1], original[3]] && model.removed.isEmpty)
        let endMenu = try await ui.menu(original[1]); try ui.invoke("Move 2 Items to End", menu: endMenu)
        try await ui.wait { Array(model.order.suffix(2)) == [original[1], original[3]] }
        #expect(Set(model.order) == Set(original))
    }

    @Test func rangeSelectionDoubleClickAndAStaleMenuRespectTheirContext() async throws {
        let model = MaterialSelectionPresentation(), ui = Window(model), original = model.order
        defer { ui.close() }
        try await ui.click(original[2]); try await ui.click(original[5], modifiers: .shift)
        #expect(model.reorder.selection == Set(original[2...5]) && model.opened == 0)
        let source = try await ui.source(original[5])
        let modifiedArrow = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: ui.window.windowNumber, context: nil,
            characters: "\u{f702}", charactersIgnoringModifiers: "\u{f702}", isARepeat: false, keyCode: 123))
        source.keyDown(with: modifiedArrow)
        #expect(model.order == original, "Modified arrow keys must not become reorder commands")
        try await ui.click(original[4], count: 2); #expect(model.opened == 1)
        let menu = try await ui.menu(original[4])
        let command = try #require(menu.items.first { $0.title.hasSuffix("to End") })
        model.context = "synthetic-other-display-size"
        #expect(NSApp.sendAction(try #require(command.action), to: command.target, from: command))
        #expect(model.order == original && model.removed.isEmpty)
    }

    @Test(arguments: [false, true])
    func theInsertionGlowAppearsAfterFiveAndTheActiveDragHandleStaysEnabled(_ withoutAnimations: Bool) async throws {
        let model = MaterialSelectionPresentation(), ui = Window(model, withoutAnimations: withoutAnimations), order = model.order
        defer { ui.close() }
        try await ui.wait { ui.marker("material.handle." + order[8]) != nil }
        let token = try #require(model.reorder.begin(order[8], order: order, context: model.context, enabled: true))
        model.reorder.hover(order[5], after: false, order: order, context: model.context, enabled: true)
        try await ui.wait { ui.marker("material.insertion." + order[4] + ".after") != nil }
        let indicator = try #require(ui.marker("material.insertion." + order[4] + ".after")), card = try #require(ui.marker("material.card." + order[4]))
        let edge = indicator.convert(indicator.bounds, to: ui.host), bounds = card.convert(card.bounds, to: ui.host)
        #expect(edge.width <= 4 && abs(edge.maxX - bounds.maxX) <= 4)
        #expect(ui.marker("material.insertion." + order[5] + ".before") == nil)
        #expect(ui.marker("material.handle." + order[8])?.available == true, "Disabling the source mid-drag would cancel its native session")
        #expect(model.order == order, "Hover never saves or mutates the editor")
        if !withoutAnimations { try ui.capture("material-reorder-insertion") }
        model.reorder.cancel(token: token)
        try await ui.wait { ui.marker("material.insertion." + order[4] + ".after") == nil }
        #expect(model.order == order)
    }
}
