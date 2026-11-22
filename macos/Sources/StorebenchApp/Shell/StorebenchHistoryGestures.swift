import AppKit
import StorebenchCore
import SwiftUI

/// Goes Back and Forward when the mouse's side buttons are pressed or the user swipes between pages in this window, as in
/// Safari and Finder. Nothing happens while a sheet or another modal window is open.
struct StorebenchHistoryGestures: NSViewRepresentable {
    let perform: @MainActor (ShortcutCommand) -> Void
    func makeNSView(context: Context) -> GestureView { GestureView() }
    func updateNSView(_ view: GestureView, context: Context) { view.perform = perform }
    static func dismantleNSView(_ view: GestureView, coordinator: ()) { view.stop() }

    final class GestureView: NSView {
        var perform: (@MainActor (ShortcutCommand) -> Void)?
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseUp, .swipe]) { [weak self] event in
                guard let command = event.type == .swipe ? HistoryGesture.command(swipeX: Double(event.deltaX)) : HistoryGesture.command(mouseButton: event.buttonNumber)
                else { return event }
                let number = event.windowNumber
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard let self, let window = self.window, number == window.windowNumber, window.attachedSheet == nil, NSApp.modalWindow == nil else { return false }
                    self.perform?(command)
                    return true
                }
                return handled ? nil : event
            }
        }
        func stop() { if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil } }
        isolated deinit { stop() }
    }
}
