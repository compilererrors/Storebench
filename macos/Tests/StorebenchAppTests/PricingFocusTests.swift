import AppKit
import SwiftUI
import Testing
@testable import StorebenchApp
@testable import StorebenchCore

@MainActor @Suite(.serialized) struct PricingFocusTests {
    init() throws { _ = try TestIsolation.require() }

    @MainActor private final class Window {
        enum Failure: Error { case timeout }
        let window: NSWindow, host: NSHostingView<AnyView>
        init(_ model: PriceStrategyModel, width: CGFloat, needsInitialPrice: Bool = false) throws {
            _ = NSApplication.shared
            let account = Account(id: "synthetic-account", name: "Synthetic Account", keyId: "SYNTHETIC", keyType: "team", issuerId: nil,
                                  appIds: ["1000000001"], appNames: ["1000000001": "Synthetic App"])
            let app = try #require(account.apps.first)
            window = NSWindow(contentRect: .init(x: 0, y: 0, width: width, height: 1000), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            host = NSHostingView(rootView: AnyView(ScrollView {
                CountryPriceStrategy(account: account, app: app, session: nil, base: "USA", needsInitialPrice: needsInitialPrice,
                    applePrice: AnyView(Card(title: "App Price", subtitle: "Synthetic Apple price editor") { EmptyView() }), model: model)
                    .padding(20)
            }.background(StorebenchTheme.page).modifier(StorebenchAppearance())))
            window.contentView = host; window.makeKeyAndOrderFront(nil)
        }
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        func marker(_ id: String) -> StorebenchControlMarker? {
            views(host).compactMap { $0 as? StorebenchControlMarker }.first { $0.identifier?.rawValue == id }
        }
        func settle() async throws { host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try await Task.sleep(for: .milliseconds(40)) }
        func wait(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(10)
            while !condition() { guard ContinuousClock.now < deadline else { throw Failure.timeout }; try await settle() }
            try await settle()
        }
        func picker() throws -> NSPopUpButton {
            let marker = try #require(marker("pricing.strategy")), bounds = marker.convert(marker.bounds, to: host)
            return try #require(views(host).compactMap { $0 as? NSPopUpButton }.first { bounds.intersects($0.convert($0.bounds, to: host)) })
        }
        func choose(_ title: String) async throws {
            let popup = try picker(), menu = try #require(popup.menu), action = try #require(popup.action)
            menu.delegate?.menuWillOpen?(menu)
            #expect(menu.items.contains { $0.title == title })
            popup.selectItem(withTitle: title)
            #expect(NSApp.sendAction(action, to: popup.target, from: popup))
            menu.delegate?.menuDidClose?(menu)
            try await settle()
        }
        func capture(_ name: String, includeGuide: Bool = true) throws {
            // Capture the product's real focused card and supporting guide with synthetic data only.
            let model = try #require(marker("pricing.model-card")), guide = try #require(marker("pricing.no-sales"))
            let modelBounds = model.convert(model.bounds, to: host)
            let bounds = (includeGuide ? modelBounds.union(guide.convert(guide.bounds, to: host)) : modelBounds).insetBy(dx: -12, dy: -12).intersection(host.bounds)
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: bounds))
            host.cacheDisplay(in: bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: TestIsolation.require().appendingPathComponent(name + ".png"))
        }
        func close() { window.makeFirstResponder(nil); window.contentView = nil; window.orderOut(nil); window.close() }
    }

    @Test(arguments: [CGFloat(640), CGFloat(1100)])
    func choosingAModelShowsOnlyItsFieldsAndKeepsTheNoSalesGuide(_ width: CGFloat) async throws {
        let model = PriceStrategyModel(); model.strategy = .model(.ppp); model.guide = "4.99"
        model.profiles = [PricingProfile(id: "synthetic-profile", name: "Country Percentages", guideTerritory: "USA", rounding: "nearest", method: "custom", percentages: ["USA": 100])]
        let ui = try Window(model, width: width); defer { ui.close() }
        try await ui.wait { ui.marker("pricing.strategy") != nil && ui.marker("pricing.no-sales") != nil }
        #expect(ui.marker("pricing.apple-prices") == nil && ui.marker("pricing.apple-base-price") == nil && ui.marker("pricing.csv") == nil)
        #expect(ui.marker("pricing.guide-price") != nil)
        let picker = try ui.picker(), frame = picker.convert(picker.bounds, to: ui.host)
        #expect(frame.width >= 300 && frame.minX >= 0 && frame.maxX <= ui.host.bounds.width)
        #expect(picker.title == PricingMethod.ppp.name)
        if width == 1100 { try ui.capture("pricing-focused-model") }

        try await ui.choose(PricingMethod.bigmac.name)
        try await ui.wait { model.strategy == .model(.bigmac) }
        #expect(ui.marker("pricing.apple-prices") == nil && ui.marker("pricing.csv") == nil && ui.marker("pricing.no-sales") != nil)

        try await ui.choose(PricingStrategyText.manualName)
        try await ui.wait { ui.marker("pricing.csv") != nil && ui.marker("pricing.guide-price") == nil }
        #expect(ui.marker("pricing.no-sales") != nil)

        try await ui.choose(PricingStrategyText.appleName)
        try await ui.wait { ui.marker("pricing.apple-prices") != nil && ui.marker("pricing.apple-base-price") != nil }
        #expect(ui.marker("pricing.csv") == nil && ui.marker("pricing.no-sales") != nil)

        try await ui.choose("Profile: Country Percentages · " + PricingMethod.custom.name)
        try await ui.wait { model.strategy == .profile("synthetic-profile") && ui.marker("pricing.guide-price") != nil }
        #expect(ui.marker("pricing.apple-prices") == nil && ui.marker("pricing.apple-base-price") == nil)
        #expect(model.guide == "4.99" && ui.marker("pricing.no-sales") != nil)
        if width == 1100 {
            try await ui.choose(PricingMethod.ppp.name)
            let rows = [ModelPrice(territory: "USA", currency: "USD", calculated: "4.99", amount: "4.99", detail: "Synthetic guide country", problem: nil, pointStatus: nil),
                        ModelPrice(territory: "GBR", currency: "GBP", calculated: "2.98", amount: "2.99", detail: "Synthetic purchasing-power example", problem: nil, pointStatus: nil),
                        ModelPrice(territory: "SWE", currency: "SEK", calculated: "28.8", amount: "29", detail: "Synthetic purchasing-power example", problem: nil, pointStatus: nil)]
            let ticket = model.ticket(.app("1000000001"), base: "USA")
            model.accept((rows: rows, warnings: [], points: ["USA": "synthetic-us", "GBR": "synthetic-gb", "SWE": "synthetic-se"]), for: ticket)
            try await ui.settle()
            try ui.capture("pricing-focused-preview", includeGuide: false)
        }
    }

    @Test func initialAppPriceSetupStaysAvailableWithoutReplacingTheSelectedModel() async throws {
        let model = PriceStrategyModel(); model.strategy = .model(.ppp)
        let ui = try Window(model, width: 900, needsInitialPrice: true); defer { ui.close() }
        try await ui.wait { ui.marker("pricing.strategy") != nil && ui.marker("pricing.apple-base-price") != nil }
        #expect(model.strategy == .model(.ppp) && ui.marker("pricing.guide-price") != nil)
        #expect(ui.marker("pricing.apple-prices") == nil && ui.marker("pricing.no-sales") != nil)
    }

    @Test func cancellingOrEditingStopsTheOwnedCalculationAndLateResultsCannotReplaceANewerPreview() async throws {
        let model = PriceStrategyModel(); model.strategy = .model(.ppp); model.guide = "4.99"
        let ui = try Window(model, width: 900); defer { ui.close() }
        let first = model.ticket(.app("1000000001"), base: "USA")
        let task = Task { await model.perform(first) { try? await Task.sleep(for: .milliseconds(150)); return ([], ["Old Result"], [:]) } }
        try await ui.wait { ui.marker("pricing.cancel-calculation") != nil && model.previewing }
        model.cancel()
        #expect(!model.previewing && model.progress.contains("Cancelled"))
        let next = model.ticket(.app("1000000001"), base: "USA")
        await model.perform(next) { ([], ["New Result"], [:]) }
        await task.value
        #expect(model.preview?.warnings == ["New Result"] && !model.previewing && model.problem.isEmpty)
        let editing = Task { await model.perform(next) { try? await Task.sleep(for: .milliseconds(150)); return ([], ["Obsolete Guide Price"], [:]) } }
        try await ui.wait { model.previewing }
        model.guide = "5.99"
        #expect(!model.previewing && model.preview == nil)
        await editing.value
        #expect(model.preview == nil && model.problem.isEmpty)
    }

    @Test func calculationDeadlineRestoresTheButtonAndExplainsTheFailure() async throws {
        let model = PriceStrategyModel(); model.strategy = .model(.ppp)
        await model.perform(model.ticket(.app("1000000001"), base: "USA"), timeout: .milliseconds(20)) {
            try await Task.sleep(for: .seconds(30)); return nil
        }
        #expect(!model.previewing && model.preview == nil && model.problem.contains("too long"))
    }
}
