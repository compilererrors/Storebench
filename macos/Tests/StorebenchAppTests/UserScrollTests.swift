import AppKit
import StorebenchCore
import Testing
@testable import StorebenchApp

/// The page always follows the user's own scroll, with a mouse wheel or a trackpad and its momentum, even when its content
/// changes in the same frame, such as rows that are shown as they come into view or statuses that are read meanwhile.
/// Content that changes while the user is not scrolling still leaves what they see in place.
@MainActor @Suite(.serialized) struct UserScrollTests {
    init() throws { _ = try TestIsolation.require() }

    @MainActor private final class Document: NSView { override var isFlipped: Bool { true } }
    @MainActor private final class Page {
        let window: NSWindow, scroll: NSScrollView, document: NSView
        var rows: [StorebenchScrollAnchorView] = []
        private var observation: NSObjectProtocol?
        /// How much the page grows below on each scroll step, as content shown while scrolling does.
        var growth: CGFloat = 0
        init() {
            _ = NSApplication.shared
            window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 700, height: 500))
            scroll.hasVerticalScroller = true
            document = Document(frame: CGRect(x: 0, y: 0, width: 680, height: 4_000))
            scroll.documentView = document; window.contentView = scroll
            window.orderBack(nil)
            let clip = scroll.contentView
            clip.postsBoundsChangedNotifications = true
            // Like SwiftUI, this layout follows the scroll before the page's own observers do and changes the page at once.
            observation = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.growth > 0 else { return }
                    self.document.setFrameSize(CGSize(width: 680, height: self.document.frame.height + self.growth))
                }
            }
            for index in 0..<20 {
                let row = StorebenchScrollAnchorView(frame: CGRect(x: 0, y: CGFloat(index) * 200, width: 680, height: 180))
                document.addSubview(row); rows.append(row)
            }
        }
        var offset: CGFloat { scroll.contentView.bounds.minY }
        func moveTo(_ y: CGFloat) { scroll.contentView.scroll(to: CGPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView) }
        func close() { observation.map(NotificationCenter.default.removeObserver); window.orderOut(nil); window.close() }
    }

    @Test func aMouseWheelScrollIsNeverPulledBackByContentShownMeanwhile() async throws {
        let page = Page(); defer { page.close() }
        page.growth = 40
        for y in stride(from: CGFloat(60), through: 1_200, by: 60) {
            StorebenchNestedScrolling.shared.noteScroll(in: page.window)
            page.moveTo(y)
            #expect(abs(page.offset - y) < 0.5, "Wheel step to \(y) shows \(page.offset)")
        }
    }

    @Test func aTrackpadScrollAndItsMomentumAreNeverPulledBack() async throws {
        let page = Page(); defer { page.close() }
        page.growth = 40
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: page.scroll)
        for y in stride(from: CGFloat(30), through: 1_500, by: 30) {
            page.moveTo(y)
            #expect(abs(page.offset - y) < 0.5, "Trackpad step to \(y) shows \(page.offset)")
        }
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: page.scroll)
        #expect(abs(page.offset - 1_500) < 0.5)
    }

    @Test func contentThatChangesAfterTheUserStoppedStillLeavesWhatTheySeeInPlace() async throws {
        let page = Page(); defer { page.close() }
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: page.scroll)
        page.moveTo(1_000)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: page.scroll)
        try await Task.sleep(for: .milliseconds(Int(StorebenchNestedScrolling.scrollWindow * 1_000) + 100))
        // A row above the view grows: the rows in view keep their place on screen.
        page.document.setFrameSize(CGSize(width: 680, height: 4_100))
        page.rows[1].setFrameSize(CGSize(width: 680, height: 280))
        for row in page.rows.dropFirst(2) { row.setFrameOrigin(CGPoint(x: 0, y: row.frame.minY + 100)) }
        #expect(abs(page.offset - 1_100) < 0.5, "What the user sees stays in place: \(page.offset)")
    }

    /// A long text box under the pointer scrolls its own text first, without clicking into it, and hands the scroll to the
    /// page once its text ends in that direction; a box whose text fits always lets the page scroll.
    @Test func aLongTextBoxScrollsItsOwnTextBeforeThePage() throws {
        _ = NSApplication.shared
        let box = NSScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 120))
        let text = NSTextView(frame: CGRect(x: 0, y: 0, width: 400, height: 120))
        text.isVerticallyResizable = true; text.textContainer?.widthTracksTextView = true
        text.minSize = NSSize(width: 0, height: 120); text.maxSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        text.string = (1...80).map { "Synthetic release note line \($0)" }.joined(separator: "\n")
        box.documentView = text; text.sizeToFit()
        #expect(text.frame.height > 400, "The synthetic text is longer than the box: \(text.frame.height)")
        // At the top: scrolling down moves the text, scrolling up goes to the page.
        #expect(StorebenchNestedScrolling.canScroll(box, by: -10) && !StorebenchNestedScrolling.canScroll(box, by: 10))
        box.contentView.scroll(to: CGPoint(x: 0, y: text.frame.height - 120)); box.reflectScrolledClipView(box.contentView)
        // At the end: scrolling down goes to the page, scrolling up moves the text.
        #expect(!StorebenchNestedScrolling.canScroll(box, by: -10) && StorebenchNestedScrolling.canScroll(box, by: 10))
        text.string = "Synthetic short note"; text.sizeToFit(); text.setFrameSize(CGSize(width: 400, height: 120))
        box.contentView.scroll(to: .zero); box.reflectScrolledClipView(box.contentView)
        #expect(!StorebenchNestedScrolling.canScroll(box, by: -10) && !StorebenchNestedScrolling.canScroll(box, by: 10))
    }
}
