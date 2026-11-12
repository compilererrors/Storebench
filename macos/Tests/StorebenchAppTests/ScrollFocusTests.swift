import AppKit
import StorebenchCore
import Testing
@testable import StorebenchApp

@MainActor @Suite(.serialized) struct ScrollFocusTests {
    init() throws { _ = try TestIsolation.require() }

    @MainActor private final class Document: NSView {
        let flippedCoordinates: Bool
        init(frame: CGRect, flipped: Bool = true) { flippedCoordinates = flipped; super.init(frame: frame) }
        required init?(coder: NSCoder) { nil }
        override var isFlipped: Bool { flippedCoordinates }
    }
    @MainActor private final class Page {
        let window: NSWindow, scroll: NSScrollView, document: NSView, header: NSView
        let focus = StorebenchScrollFocus()
        init(flipped: Bool = true) {
            _ = NSApplication.shared
            window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 700, height: 500))
            scroll.hasVerticalScroller = true
            document = Document(frame: CGRect(x: 0, y: 0, width: 680, height: 3200), flipped: flipped)
            header = Document(frame: CGRect(x: 20, y: 1200, width: 600, height: 40), flipped: flipped)
            document.addSubview(header); scroll.documentView = document; window.contentView = scroll
            focus.attach(header); window.orderBack(nil)
        }
        var top: CGFloat {
            let rect = header.convert(header.bounds, to: scroll.contentView), viewport = scroll.contentView.bounds
            return scroll.contentView.isFlipped ? rect.minY - viewport.minY : viewport.maxY - rect.maxY
        }
        func close() { StorebenchScrollFocus.cancel(in: window); window.orderOut(nil); window.close() }
    }
    private func wait(detail: @autoclosure () -> String = "Native placement did not settle", _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(condition(), "\(detail())")
    }

    @Test(arguments: [true, false])
    func aHeaderStaysVisibleWhenLaterLayoutMovesItWithoutChangingDocumentSize(_ flipped: Bool) async throws {
        let page = Page(flipped: flipped); defer { page.close() }
        #expect(page.focus.reveal())
        try await wait(detail: "Initial header top: \(page.top); clip: \(page.scroll.contentView.bounds)") { abs(page.top - 12) < 1 }
        // A later sibling measurement can move the active section after the initial layout has settled.
        try await Task.sleep(for: .milliseconds(400))
        let size = page.document.bounds.size
        page.header.setFrameOrigin(CGPoint(x: 20, y: 1660))
        try await wait(detail: "Later lower header top: \(page.top); clip: \(page.scroll.contentView.bounds)") { abs(page.top - 12) < 1 }
        #expect(page.document.bounds.size == size)
        page.header.setFrameOrigin(CGPoint(x: 20, y: 740))
        try await wait(detail: "Later upper header top: \(page.top); clip: \(page.scroll.contentView.bounds)") { abs(page.top - 12) < 1 }
    }

    @Test func theNewestControlWinsAndRetiringItDoesNotKeepPullingThePageBack() async throws {
        let page = Page(); defer { page.close() }
        page.focus.reveal()
        try await wait { abs(page.top - 12) < 1 }
        let next = Document(frame: CGRect(x: 20, y: 2300, width: 600, height: 40)), focus = StorebenchScrollFocus()
        page.document.addSubview(next); focus.attach(next); focus.reveal()
        try await wait { abs(next.convert(next.bounds, to: page.scroll.contentView).minY - page.scroll.contentView.bounds.minY - 12) < 1 }
        let offset = page.scroll.contentView.bounds.origin
        page.header.setFrameOrigin(CGPoint(x: 20, y: 300))
        try await Task.sleep(for: .milliseconds(100))
        #expect(page.scroll.contentView.bounds.origin == offset)
        focus.detach(next)
        next.setFrameOrigin(CGPoint(x: 20, y: 1800))
        try await Task.sleep(for: .milliseconds(100))
        #expect(page.scroll.contentView.bounds.origin == offset)
    }

    @Test func cancellingPlacementLetsTheUserKeepTheirOwnScrollPosition() async throws {
        let page = Page(); defer { page.close() }
        page.focus.reveal()
        try await wait { abs(page.top - 12) < 1 }
        page.focus.interact()
        page.scroll.contentView.scroll(to: CGPoint(x: 0, y: 300))
        page.header.setFrameOrigin(CGPoint(x: 20, y: 1700))
        try await Task.sleep(for: .milliseconds(150))
        #expect(abs(page.scroll.contentView.bounds.origin.y - 300) < 1)
    }

    @Test func revealingAnAlreadyVisibleInputDoesNotChangeItsPosition() async throws {
        let page = Page(); defer { page.close() }
        page.scroll.contentView.scroll(to: CGPoint(x: 0, y: 1100))
        let offset = page.scroll.contentView.bounds.origin
        page.focus.reveal(.visible)
        try await Task.sleep(for: .milliseconds(100))
        #expect(page.scroll.contentView.bounds.origin == offset)
        page.header.setFrameOrigin(CGPoint(x: 20, y: 1700))
        try await wait { page.top >= 12 && page.top + page.header.bounds.height <= page.scroll.contentView.bounds.height - 12 }
    }

    @Test func aLaterProgrammaticScrollTakesOverFromTheEarlierHeader() async throws {
        let page = Page(); defer { page.close() }
        page.focus.reveal()
        try await wait { abs(page.top - 12) < 1 }
        page.scroll.contentView.scroll(to: CGPoint(x: 0, y: 300))
        try await Task.sleep(for: .milliseconds(100))
        page.header.setFrameOrigin(CGPoint(x: 20, y: 1700))
        try await Task.sleep(for: .milliseconds(100))
        #expect(abs(page.scroll.contentView.bounds.origin.y - 300) < 1)
    }

    @Test func anInspectorRevealsItsHeaderInsideBothNestedViewports() async throws {
        let page = Page(); defer { page.close() }
        let inspector = NSScrollView(frame: CGRect(x: 20, y: 1600, width: 600, height: 300))
        let content = Document(frame: CGRect(x: 0, y: 0, width: 580, height: 1800))
        let header = Document(frame: CGRect(x: 20, y: 1100, width: 520, height: 40)), focus = StorebenchScrollFocus()
        content.addSubview(header); inspector.documentView = content; page.document.addSubview(inspector)
        focus.attach(header); focus.reveal()
        try await wait {
            let inner = header.convert(header.bounds, to: inspector.contentView), outer = header.convert(header.bounds, to: page.scroll.contentView)
            return abs(inner.minY - inspector.contentView.bounds.minY - 12) < 1 && page.scroll.contentView.bounds.insetBy(dx: 0, dy: 11).contains(outer)
        }
    }

    @Test func placementInOneWindowDoesNotCancelAnotherWindow() async throws {
        let first = Page(), second = Page(); defer { first.close(); second.close() }
        first.focus.reveal(); second.focus.reveal()
        try await wait { abs(first.top - 12) < 1 && abs(second.top - 12) < 1 }
        first.header.setFrameOrigin(CGPoint(x: 20, y: 1800))
        second.header.setFrameOrigin(CGPoint(x: 20, y: 800))
        try await wait { abs(first.top - 12) < 1 && abs(second.top - 12) < 1 }
    }

    @Test func aUserScrollCancelsOlderPageRequestsWithoutRecursingThroughHistoryCapture() async throws {
        let page = Page(); defer { page.close() }
        let checkpoint = StorebenchScrollCheckpoint.CheckpointView(frame: .zero)
        page.document.addSubview(checkpoint)
        let history = NavigationPresentation(), entry = UUID()
        history.save(CGPoint(x: 0, y: 1800), for: entry)
        var interactions = 0
        checkpoint.configure(.init(store: history, entry: entry), interaction: {
            interactions += 1
            history.keepScroll?()
        })
        // A deliberate programmatic placement captures history but is not a new user action.
        history.keepScroll?()
        #expect(interactions == 0)
        page.scroll.contentView.scroll(to: CGPoint(x: 0, y: 400))
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: page.scroll)
        #expect(interactions == 1)
        try await Task.sleep(for: .milliseconds(350))
        #expect(abs(page.scroll.contentView.bounds.origin.y - 400) < 1)
        checkpoint.retire()
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: page.scroll)
        #expect(interactions == 1)
    }

    @Test(arguments: [true, false])
    func preservingAHeaderDoesNotMoveItToTheTopOrJumpWhenTheDocumentShrinks(_ flipped: Bool) async throws {
        let page = Page(flipped: flipped); defer { page.close() }
        page.scroll.contentView.scroll(to: CGPoint(x: 0, y: 1100))
        let before = page.top
        #expect(page.focus.reveal(.preserve))
        #expect(abs(page.top - before) < 1)
        page.header.setFrameOrigin(CGPoint(x: 20, y: 1600))
        try await wait { abs(page.top - before) < 1 }
        try await Task.sleep(for: .milliseconds(400))
        // Removing everything below the active header must not clamp the viewport to a different position.
        page.document.setFrameSize(CGSize(width: 680, height: 1640))
        var samples: [CGFloat] = []
        for _ in 0..<35 {
            page.window.contentView?.layoutSubtreeIfNeeded(); page.window.displayIfNeeded()
            samples.append(page.top)
            try await Task.sleep(for: .milliseconds(16))
        }
        #expect(samples.allSatisfy { abs($0 - before) < 1 }, "Preserved header samples: \(samples); insets: \(page.scroll.contentView.contentInsets); bounds: \(page.scroll.contentView.bounds); document: \(page.document.frame)")
        page.focus.interact()
        let offset = page.scroll.contentView.bounds.origin
        #expect(abs(page.top - before) < 1)
        page.scroll.contentView.scroll(to: CGPoint(x: 0, y: 500))
        try await Task.sleep(for: .milliseconds(60))
        #expect(abs(page.scroll.contentView.bounds.minY - 500) < 1)
        #expect(page.scroll.contentView.bounds.origin != offset)
    }

    @Test func aNestedDisclosureKeepsItsPositionInBothViewports() async throws {
        let page = Page(); defer { page.close() }
        let inspector = NSScrollView(frame: CGRect(x: 20, y: 1600, width: 600, height: 300))
        let content = Document(frame: CGRect(x: 0, y: 0, width: 580, height: 1800))
        let header = Document(frame: CGRect(x: 20, y: 1100, width: 520, height: 40)), focus = StorebenchScrollFocus()
        content.addSubview(header); inspector.documentView = content; page.document.addSubview(inspector)
        focus.attach(header)
        inspector.contentView.scroll(to: CGPoint(x: 0, y: 1000)); page.scroll.contentView.scroll(to: CGPoint(x: 0, y: 1400))
        func top(_ scroll: NSScrollView) -> CGFloat { header.convert(header.bounds, to: scroll.contentView).minY - scroll.contentView.bounds.minY }
        let inner = top(inspector), outer = top(page.scroll)
        #expect(focus.reveal(.preserve))
        content.setFrameSize(CGSize(width: 580, height: 1140))
        inspector.setFrameOrigin(CGPoint(x: 20, y: 1800))
        var innerSamples: [CGFloat] = [], outerSamples: [CGFloat] = []
        for _ in 0..<35 {
            page.window.contentView?.layoutSubtreeIfNeeded(); page.window.displayIfNeeded()
            innerSamples.append(top(inspector)); outerSamples.append(top(page.scroll))
            try await Task.sleep(for: .milliseconds(16))
        }
        #expect(innerSamples.allSatisfy { abs($0 - inner) < 1 }, "Inner header samples: \(innerSamples)")
        #expect(outerSamples.allSatisfy { abs($0 - outer) < 1 }, "Outer header samples: \(outerSamples)")
    }
}
