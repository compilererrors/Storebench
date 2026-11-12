import AppKit
import Observation
import SwiftUI
import Testing
@testable import StorebenchApp
@testable import StorebenchCore

@MainActor @Suite(.serialized) struct TableToolsTests {
    init() throws { _ = try TestIsolation.require() }
    private func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
    private func wait(_ root: NSView, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw FileMutex.Failure.timeout }
            root.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20))
        }
        root.layoutSubtreeIfNeeded()
    }

    @Test(arguments: [CGFloat(640), CGFloat(1100)])
    func nativeSearchFiltersTheCountryTableImmediatelyAndToolsStayBesideTheirContent(_ width: CGFloat) async throws {
        _ = NSApplication.shared
        let rows = [ModelPrice(territory: "USA", currency: "USD", calculated: "4.99", amount: "4.99", detail: "Synthetic price match", problem: nil, pointStatus: "available"),
                    ModelPrice(territory: "SWE", currency: "SEK", calculated: "19.96", amount: "19.99", detail: "Synthetic price match", problem: nil, pointStatus: "available"),
                    ModelPrice(territory: "GBR", currency: "GBP", calculated: nil, amount: nil, detail: "", problem: "Synthetic missing observation", pointStatus: nil)]
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: width, height: 360), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let host = NSHostingView(rootView: PricePreviewTable(rows: rows).padding(20).frame(width: width, height: 360, alignment: .top).modifier(StorebenchAppearance()).environment(\.colorScheme, .light))
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.makeFirstResponder(nil); window.contentView = nil; window.orderOut(nil); window.close() }
        func marker(_ id: String) -> StorebenchControlMarker? { views(host).compactMap { $0 as? StorebenchControlMarker }.first { $0.identifier?.rawValue == id } }
        try await wait(host) { marker("pricing.preview-row.SWE") != nil && views(host).contains { $0 is NSSearchField } }
        let search = try #require(views(host).compactMap { $0 as? NSSearchField }.first)
        #expect(search.sendsSearchStringImmediately && search.placeholderString == "Search Countries or Currencies")
        let searchFrame = search.convert(search.bounds, to: host)
        #expect(searchFrame.width > 250 && searchFrame.minX >= 20 && searchFrame.maxX < width - 20)
        for id in ["table.sort", "table.filter", "table.page-size"] {
            let tool = try #require(marker(id)), frame = tool.convert(tool.bounds, to: host)
            #expect(frame.maxX <= width - 20 && frame.minX >= searchFrame.maxX)
            #expect(abs(frame.midY - searchFrame.midY) < 2 && frame.height <= StorebenchTheme.controlHeight + 1)
            if id != "table.page-size" {
                let area = frame.insetBy(dx: 5, dy: 5), bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: area))
                host.cacheDisplay(in: area, to: bitmap)
                var darkest: CGFloat = 1, lightest: CGFloat = 0
                for x in 0..<bitmap.pixelsWide { for y in 0..<bitmap.pixelsHigh {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.5 else { continue }
                    let value = (color.redComponent + color.greenComponent + color.blueComponent) / 3
                    darkest = min(darkest, value); lightest = max(lightest, value)
                } }
                #expect(lightest - darkest > 0.25, "The native menu must draw its registered icon, not an empty toolbar slot")
            }
        }
        search.stringValue = "SEK"
        #expect(NSApp.sendAction(try #require(search.action), to: search.target, from: search))
        try await wait(host) { marker("pricing.preview-row.SWE") != nil && marker("pricing.preview-row.USA") == nil && marker("pricing.preview-row.GBR") == nil }
        search.stringValue = ""; _ = NSApp.sendAction(try #require(search.action), to: search.target, from: search)
        try await wait(host) { marker("pricing.preview-row.USA") != nil && marker("pricing.preview-row.GBR") != nil }
        if width == 1100 {
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: TestIsolation.require().appendingPathComponent("pricing-native-table.png"))
        }
    }
}
