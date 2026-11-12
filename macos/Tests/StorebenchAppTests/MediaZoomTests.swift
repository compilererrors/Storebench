import AppKit
import Observation
import SwiftUI
import Testing
@testable import StorebenchApp
@testable import StorebenchCore

@MainActor @Observable private final class MediaZoomPresentation {
    var zoom = 0.4
    var fitted = true
    var cropZoom = 1.0
    var position = 0.8
    var image = 1
    var applied: ScreenshotEdits?
}

@MainActor private struct MediaZoomFixture: View {
    let model: MediaZoomPresentation
    var crop = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if crop {
                StorebenchCropControls(zoom: Binding(get: { model.cropZoom }, set: { model.cropZoom = $0 })) {
                    model.cropZoom = 1; model.position = 0.5
                }
            } else {
                Text("Sample Screenshot").font(.sbHeadline)
                RoundedRectangle(cornerRadius: 12).fill(LinearGradient(colors: [.indigo, .teal], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay { Text("Plan a clearer day.").font(.largeTitle.weight(.semibold)).foregroundStyle(.white) }.frame(height: 270)
                StorebenchMediaToolbar {
                    HStack(spacing: 4) {
                        StorebenchIconButton(title: "Previous Screenshot", icon: "previous") { model.image -= 1 }.storebenchControlID("test.previous")
                        StorebenchIconButton(title: "Next Screenshot", icon: "next") { model.image += 1 }.storebenchControlID("test.next")
                        Text("\(model.image) / 10").font(.sbCaption).monospacedDigit().frame(minWidth: 52)
                    }
                } zoom: {
                    StorebenchZoomControl(value: Binding(get: { model.zoom }, set: { model.zoom = $0; model.fitted = false }), fitted: model.fitted,
                        fit: { model.zoom = 0.4; model.fitted = true })
                } actions: {
                    Button("Download Original…") {}.storebenchControlID("test.download")
                }
                Text("Double-click to switch between Fit and 100%. Scroll to inspect an enlarged image.").font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
            }
        }.padding(16).modifier(StorebenchAppearance())
    }
}

@MainActor @Suite(.serialized) struct MediaZoomTests {
    init() throws { _ = try TestIsolation.require() }
    @MainActor private final class Window {
        let window: NSWindow, host: NSHostingView<AnyView>
        convenience init(_ model: MediaZoomPresentation, width: CGFloat, crop: Bool = false) {
            self.init(MediaZoomFixture(model: model, crop: crop), width: width, height: crop ? 140 : 500)
        }
        init<V: View>(_ view: V, width: CGFloat, height: CGFloat) {
            _ = NSApplication.shared
            window = NSWindow(contentRect: .init(x: 0, y: 0, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
            host = NSHostingView(rootView: AnyView(view))
            window.contentView = host; window.orderBack(nil)
        }
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        func marker(_ id: String) -> StorebenchControlMarker? { views(host).compactMap { $0 as? StorebenchControlMarker }.first { $0.identifier?.rawValue == id } }
        func settle() async throws { host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try await Task.sleep(for: .milliseconds(40)) }
        func ready(_ id: String) async throws -> StorebenchControlMarker {
            let deadline = ContinuousClock.now + .seconds(5)
            while marker(id) == nil { guard ContinuousClock.now < deadline else { throw FileMutex.Failure.timeout }; try await settle() }
            try await settle(); return try #require(marker(id))
        }
        func press(_ id: String) async throws {
            window.makeKeyAndOrderFront(nil)
            let marker = try await ready(id), point = marker.convert(.init(x: marker.bounds.midX, y: marker.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)))
            }
            try await settle()
        }
        func choose(_ title: String) async throws {
            try await settle()
            let scope = try #require(marker("media.zoom.level") ?? marker("media.crop.zoom.level"))
            let frame = scope.convert(scope.bounds, to: host)
            let popup = try #require(views(host).compactMap { $0 as? NSPopUpButton }.first {
                $0.accessibilityLabel() == "Zoom Level" && !$0.isHiddenOrHasHiddenAncestor && frame.intersects($0.convert($0.bounds, to: host))
            })
            func normalized(_ value: String) -> String { String(value.filter { !$0.isWhitespace }) }
            let item = try #require(popup.itemArray.first { normalized($0.title) == normalized(title) }, "Wanted \(title); native zoom options: \(popup.itemTitles)")
            popup.select(item); #expect(NSApp.sendAction(try #require(popup.action), to: popup.target, from: popup))
            try await settle()
        }
        func close() { window.makeFirstResponder(nil); window.contentView = nil; window.orderOut(nil); window.close() }
    }

    @Test func screenshotEditorAppliesTheCropChosenWithTheSharedZoomTools() async throws {
        let model = MediaZoomPresentation()
        let context = try #require(CGContext(data: nil, width: 800, height: 500, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(NSColor.systemTeal.cgColor); context.fill(CGRect(x: 0, y: 0, width: 800, height: 500))
        let image = try #require(context.makeImage()), bitmap = NSBitmapImageRep(cgImage: image)
        let bytes = try #require(bitmap.representation(using: .png, properties: [:]))
        let editor = ScreenshotImageEditor(item: .init(name: "sample-screenshot.png", data: bytes), platform: "MAC_OS", displayType: nil,
            customTargets: [.init(type: "SYNTHETIC_DISPLAY", width: 800, height: 500)], outputPNG: true, apply: { _, edits in model.applied = edits }, close: {})
            .environment(\.workspaceWidth, 1100).environment(\.workspaceHeight, 820).modifier(StorebenchAppearance())
        let ui = Window(editor, width: 1100, height: 820)
        defer { ui.close() }
        _ = try await ui.ready("media.crop.zoom.in")
        try await ui.press("media.crop.zoom.in")
        let deadline = ContinuousClock.now + .seconds(8)
        while ui.marker("media.image-apply")?.available != true { guard ContinuousClock.now < deadline else { throw FileMutex.Failure.timeout }; try await ui.settle() }
        let capture = try #require(ui.host.bitmapImageRepForCachingDisplay(in: ui.host.bounds))
        ui.host.cacheDisplay(in: ui.host.bounds, to: capture)
        try #require(capture.representation(using: .png, properties: [:])).write(to: TestIsolation.require().appendingPathComponent("media-image-editor.png"))
        try await ui.press("media.image-apply")
        while model.applied == nil { guard ContinuousClock.now < deadline else { throw FileMutex.Failure.timeout }; try await ui.settle() }
        #expect(abs(try #require(model.applied).zoom - 1.1) < 0.001)
        #expect(model.applied?.width == 800 && model.applied?.height == 500)
    }

    @Test(arguments: [CGFloat(500), CGFloat(1060)])
    func zoomNavigationAndExportKeepTheirGroupsAndNativePresets(_ width: CGFloat) async throws {
        let model = MediaZoomPresentation(), ui = Window(model, width: width)
        defer { ui.close() }
        let out = try await ui.ready("media.zoom.out"), inside = try await ui.ready("media.zoom.in")
        let outFrame = out.convert(out.bounds, to: ui.host), inFrame = inside.convert(inside.bounds, to: ui.host)
        #expect(abs(outFrame.midY - inFrame.midY) < 1 && abs(inFrame.minX - outFrame.maxX) < 1)
        for id in ["media.zoom.out", "media.zoom.in", "media.zoom.slider", "media.zoom.level", "test.previous", "test.next", "test.download"] {
            let view = try await ui.ready(id), frame = view.convert(view.bounds, to: ui.host)
            #expect(frame.minX >= 15 && frame.maxX <= width - 15 && frame.height <= StorebenchTheme.controlHeight + 1, "\(id): \(frame)")
        }
        let download = try await ui.ready("test.download"), downloadFrame = download.convert(download.bounds, to: ui.host)
        #expect(!downloadFrame.intersects(inFrame), "Export must never overlap zoom")
        let bitmap = try #require(ui.host.bitmapImageRepForCachingDisplay(in: ui.host.bounds))
        ui.host.cacheDisplay(in: ui.host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: TestIsolation.require().appendingPathComponent("media-toolbar-\(Int(width)).png"))
        try await ui.press("media.zoom.in"); #expect(abs(model.zoom - 0.5) < 0.001 && !model.fitted)
        try await ui.press("media.zoom.out"); #expect(abs(model.zoom - 0.4) < 0.001)
        try await ui.choose(Double(1).formatted(.percent.precision(.fractionLength(0)))); #expect(model.zoom == 1 && !model.fitted)
        try await ui.choose("Fit Image"); #expect(model.zoom == 0.4 && model.fitted)
        try await ui.press("test.next"); #expect(model.image == 2)
        try await ui.press("test.previous"); #expect(model.image == 1)
    }

    @Test(arguments: [CGFloat(300), CGFloat(520)])
    func cropZoomKeepsBothButtonsAtBoundsAndRecenterIsBesideItsControls(_ width: CGFloat) async throws {
        let model = MediaZoomPresentation(), ui = Window(model, width: width, crop: true)
        defer { ui.close() }
        let out = try await ui.ready("media.crop.zoom.out")
        #expect(!out.available)
        let initial = out.convert(out.bounds, to: ui.host)
        try await ui.press("media.crop.zoom.out"); #expect(model.cropZoom == 1)
        try await ui.press("media.crop.zoom.in"); #expect(abs(model.cropZoom - 1.1) < 0.001)
        let slider = try #require(ui.views(ui.host).compactMap { $0 as? NSSlider }.first)
        slider.doubleValue = (slider.minValue + slider.maxValue) / 2
        #expect(NSApp.sendAction(try #require(slider.action), to: slider.target, from: slider))
        try await ui.settle(); #expect(abs(model.cropZoom - 2) < 0.001)
        try await ui.choose(Double(4).formatted(.percent.precision(.fractionLength(0)))); #expect(model.cropZoom == 4)
        let inside = try await ui.ready("media.crop.zoom.in"); #expect(!inside.available)
        #expect(out.convert(out.bounds, to: ui.host) == initial, "Zooming must not move or hide its controls")
        try await ui.press("media.crop.recenter"); #expect(model.cropZoom == 1 && model.position == 0.5)
        for id in ["media.crop.recenter", "media.crop.zoom.level", "media.crop.zoom.slider"] {
            let view = try await ui.ready(id), frame = view.convert(view.bounds, to: ui.host)
            #expect(frame.minX >= 15 && frame.maxX <= width - 15)
        }
    }
}
