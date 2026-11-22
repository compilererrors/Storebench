import Foundation
import Testing
@testable import StorebenchCore

/// Back and Forward answer the same input as in Safari and Finder: Command-[ and Command-], the mouse's side buttons and a swipe.
@Suite struct HistoryGestureTests {
    init() throws { _ = try TestIsolation.require() }

    @Test func historyHasTheStandardMacKeys() throws {
        let keymap = try ShortcutKeymap()
        #expect(keymap.binding(.back)?.specification == "command+[" && keymap.binding(.forward)?.specification == "command+]")
    }

    @Test func theMouseSideButtonsAndASwipeGoBackAndForward() {
        #expect(HistoryGesture.command(mouseButton: 3) == .back && HistoryGesture.command(mouseButton: 4) == .forward)
        #expect(HistoryGesture.command(mouseButton: 0) == nil && HistoryGesture.command(mouseButton: 2) == nil)
        // Swiping right shows the earlier page, as in Safari.
        #expect(HistoryGesture.command(swipeX: 1) == .back && HistoryGesture.command(swipeX: -1) == .forward && HistoryGesture.command(swipeX: 0) == nil)
    }

    @Test func theBackAndForwardButtonsNameTheirShortcut() throws {
        let keymap = try ShortcutKeymap()
        #expect(HistoryGesture.help(.back, binding: keymap.binding(.back)) == "Back (Cmd+[)")
        #expect(HistoryGesture.help(.forward, binding: keymap.binding(.forward)) == "Forward (Cmd+])")
        #expect(HistoryGesture.help(.back, binding: nil) == "Back")
    }
}
