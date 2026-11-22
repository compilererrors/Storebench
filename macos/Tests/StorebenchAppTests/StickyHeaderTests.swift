import AppKit
import StorebenchCore
import SwiftUI
import Testing
@testable import StorebenchApp

/// A long page of open languages, like Text and Screenshots: a card taller than the page keeps its own top in view.
@MainActor @Suite(.serialized) struct StickyHeaderTests {
    init() throws { _ = try TestIsolation.require() }

    struct Language: Identifiable { let id: Int }
    struct Page: View {
        var body: some View {
            ScrollView {
                HStack(alignment: .top, spacing: 24) {
                    // A step rail beside the cards, as in Release; the pinned top never covers it.
                    Color.gray.frame(width: 160, height: 300)
                    VStack(alignment: .leading, spacing: 12) {
                        Card(title: "Synthetic Short Card", subtitle: "Fits on the page") { Text("Synthetic short content") }
                        StorebenchCollection(items: (1...6).map(Language.init), title: { "Synthetic Language \($0.id)" }, subtitle: { "synthetic-\($0.id) · Saved language and media" },
                                             initialOpeningLimit: -1, empty: "") { language in
                            VStack(alignment: .leading, spacing: 0) { ForEach(0..<30, id: \.self) { Text("Synthetic field \($0) of language \(language.id)").frame(height: 30) } }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
        }
    }

    private func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews { if let found = scrollView(in: child) { return found } }
        return nil
    }
    private func settle(_ window: NSWindow, _ times: Int = 4) async throws {
        for _ in 0..<times { window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try await Task.sleep(for: .milliseconds(16)) }
    }
    private func open() async throws -> (NSWindow, NSScrollView, StorebenchStickyHeaders) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Page())
        window.orderBack(nil)
        try await settle(window, 8)
        let content = try #require(window.contentView)
        let scroll = try #require(scrollView(in: content))
        return (window, scroll, StorebenchStickyHeaders.controller(for: scroll))
    }
    private func card(_ title: String, _ scroll: NSScrollView) throws -> CGRect {
        func find(_ view: NSView) -> [StorebenchStickySectionView] { (view as? StorebenchStickySectionView).map { [$0] } ?? view.subviews.flatMap(find) }
        let marker = try #require(find(scroll).first { $0.header?.title == title })
        return marker.convert(marker.bounds, to: scroll.contentView)
    }
    private func language(_ id: Int, _ scroll: NSScrollView) throws -> CGRect { try card("Synthetic Language \(id)", scroll) }
    private func scroll(_ scroll: NSScrollView, to y: CGFloat) { scroll.contentView.scroll(to: CGPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView) }

    @Test func aTallCardKeepsItsOwnTopInViewAtItsOwnWidth() async throws {
        let (window, page, headers) = try await open()
        defer { window.orderOut(nil); window.close() }
        #expect(headers.current.isEmpty, "Nothing is pinned while every header shows: \(headers.current)")
        let third = try language(3, page)
        scroll(page, to: third.minY + 400); try await settle(window, 2)
        #expect(headers.current.map(\.title) == ["Synthetic Language 3"])
        #expect(headers.current.last?.subtitle == "synthetic-3 · Saved language and media")
        // The pinned top covers the card only, not the rail beside it, and sits at the page's top edge.
        let pinned = page.contentView.convert(headers.pin.frame, from: page)
        #expect(!headers.pin.isHidden && abs(pinned.minX - third.minX) < 1 && abs(pinned.width - third.width) < 1, "Pinned at \(pinned), card at \(third)")
        #expect(abs(pinned.minY - page.contentView.bounds.minY) < 1 && abs(pinned.height - StorebenchStickyHeaders.height) < 1, "Pinned at \(pinned)")
        // Further down it follows the next language, and back at the top nothing is pinned.
        let fifth = try language(5, page)
        scroll(page, to: fifth.minY + 10); try await settle(window, 2)
        #expect(headers.current.map(\.title) == ["Synthetic Language 5"])
        scroll(page, to: 0); try await settle(window, 2)
        #expect(headers.current.isEmpty && headers.pin.isHidden)
    }

    @Test func aCardThatFitsOnThePageIsNeverPinned() async throws {
        let (window, page, headers) = try await open()
        defer { window.orderOut(nil); window.close() }
        let short = try card("Synthetic Short Card", page)
        for offset in stride(from: CGFloat(4), to: short.height, by: 12) {
            scroll(page, to: short.minY + offset); try await settle(window, 1)
            #expect(!headers.current.contains { $0.title == "Synthetic Short Card" }, "Pinned at offset \(offset)")
        }
    }

    @Test func theCardsEndPushesItsTopUp() async throws {
        let (window, page, headers) = try await open()
        defer { window.orderOut(nil); window.close() }
        let second = try language(2, page)
        scroll(page, to: second.maxY - 20); try await settle(window, 2)
        #expect(headers.current.map(\.title) == ["Synthetic Language 2"])
        #expect(abs(headers.pin.frame.height - 20) < 1, "Only the last 20 pt of the card show, but the pin is \(headers.pin.frame.height) tall")
    }

    @Test func scrollingInsideOneCardNeverDrawsItsTopAgain() async throws {
        let (window, page, headers) = try await open()
        defer { window.orderOut(nil); window.close() }
        let second = try language(2, page)
        scroll(page, to: second.minY + 20); try await settle(window, 2)
        let before = headers.changes
        #expect(headers.current.map(\.title) == ["Synthetic Language 2"])
        // A quick scroll through the card is dozens of steps; its pinned top is drawn once.
        for step in 1...40 { scroll(page, to: second.minY + 20 + CGFloat(step) * 15); try await settle(window, 1) }
        #expect(headers.changes == before, "The pinned top changed \(headers.changes - before) times inside one card")
    }

    @Test func clickingThePinnedTopGoesToTheTopOfThatCard() async throws {
        let (window, page, headers) = try await open()
        defer { window.orderOut(nil); window.close() }
        let fourth = try language(4, page)
        scroll(page, to: fourth.minY + 600); try await settle(window, 2)
        headers.showCurrent(); try await settle(window, 2)
        #expect(abs(page.contentView.bounds.minY - (fourth.minY - page.contentView.contentInsets.top)) < 1, "At \(page.contentView.bounds.minY), the card starts at \(fourth.minY)")
    }
}
