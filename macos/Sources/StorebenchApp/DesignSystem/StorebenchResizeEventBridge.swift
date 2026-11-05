import AppKit
import QuartzCore
import StorebenchCore
import SwiftUI

struct StorebenchResizeEventBridge: NSViewRepresentable {
    let label: String, height: Double
    let changed: (Double) -> Void
    let interaction: (Bool) -> Void
    let focus: (Bool) -> Void
    @Environment(\.collectionVisible) private var visible
    func makeNSView(context: Context) -> ResizeView { ResizeView() }
    func updateNSView(_ view: ResizeView, context: Context) {
        view.configure(label: label, height: height, visible: visible, changed: changed, interaction: interaction, focus: focus)
    }
    static func dismantleNSView(_ view: ResizeView, coordinator: ()) { view.retire() }

    final class ResizeView: NSView {
        private var resize = TextSurfaceResizeSession()
        private var startY: CGFloat = 0
        private var currentHeight = 140.0
        private var link: CADisplayLink?
        private var windowObserver: NSObjectProtocol?
        private var changed: ((Double) -> Void)?, interaction: ((Bool) -> Void)?, focus: ((Bool) -> Void)?
        private var shown = true
        override var acceptsFirstResponder: Bool { shown }
        override var mouseDownCanMoveWindow: Bool { false }
        override init(frame: NSRect) { super.init(frame: frame); focusRingType = .none; setAccessibilityElement(true); setAccessibilityRole(.splitter) }
        required init?(coder: NSCoder) { nil }
        isolated deinit { link?.invalidate(); if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) } }
        func configure(label: String, height: Double, visible: Bool, changed: @escaping (Double) -> Void, interaction: @escaping (Bool) -> Void, focus: @escaping (Bool) -> Void) {
            currentHeight = height; shown = visible
            self.changed = changed; self.interaction = interaction; self.focus = focus
            setAccessibilityLabel("Resize " + label.lowercased()); setAccessibilityValue("\(Int(height)) points")
            setAccessibilityHelp("Drag vertically or use the up and down arrow keys")
            if !visible { stop(notify: false) }
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let windowObserver { NotificationCenter.default.removeObserver(windowObserver); self.windowObserver = nil }
            if let window {
                windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.stop(notify: true) }
                }
            } else { stop(notify: false) }
        }
        override func resetCursorRects() { if shown { addCursorRect(bounds, cursor: .resizeUpDown) } }
        override func mouseDown(with event: NSEvent) {
            guard shown, window != nil else { return }
            stop(notify: false)
            if window?.firstResponder === self { window?.makeFirstResponder(nil) }
            focus?(false); startY = event.locationInWindow.y
            resize.begin(height: currentHeight); interaction?(true)
        }
        override func mouseDragged(with event: NSEvent) {
            guard shown, let ticket = resize.ticket else { return }
            resize.queue(translation: Double(startY - event.locationInWindow.y), ticket: ticket)
            if link == nil {
                let target = DisplayTarget(self)
                let next = displayLink(target: target, selector: #selector(DisplayTarget.tick(_:)))
                link = next; next.add(to: .main, forMode: .common)
            }
        }
        override func mouseUp(with event: NSEvent) {
            if let ticket = resize.ticket, let value = resize.finish(translation: Double(startY - event.locationInWindow.y), ticket: ticket) { changed?(value) }
            stop(notify: true)
            if window?.firstResponder === self { window?.makeFirstResponder(nil) }
            focus?(false)
        }
        fileprivate func publishFrame(_ sender: CADisplayLink) {
            guard sender === link, shown, let ticket = resize.ticket, let value = resize.take(ticket: ticket) else { return }
            changed?(value)
        }
        override func keyDown(with event: NSEvent) {
            guard shown, event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty else { super.keyDown(with: event); return }
            switch event.keyCode {
            case 126: adjust(-40)
            case 125: adjust(40)
            case 53: stop(notify: true)
            default: super.keyDown(with: event)
            }
        }
        override func becomeFirstResponder() -> Bool { let accepted = super.becomeFirstResponder(); if accepted { focus?(true) }; return accepted }
        override func resignFirstResponder() -> Bool { let accepted = super.resignFirstResponder(); if accepted { focus?(false) }; return accepted }
        override func accessibilityPerformIncrement() -> Bool { adjust(40); return shown }
        override func accessibilityPerformDecrement() -> Bool { adjust(-40); return shown }
        private func adjust(_ delta: Double) {
            guard shown else { return }; stop(notify: false)
            let next = TextSurfacePresentation.height(currentHeight + delta)
            if next != currentHeight { currentHeight = next; changed?(next) }
        }
        private func stop(notify: Bool) {
            link?.invalidate(); link = nil; resize.cancel()
            if notify { interaction?(false) }
        }
        func retire() {
            stop(notify: false)
            if let windowObserver { NotificationCenter.default.removeObserver(windowObserver); self.windowObserver = nil }
            changed = nil; interaction = nil; focus = nil; shown = false
        }
    }
    @MainActor private final class DisplayTarget: NSObject {
        weak var owner: ResizeView?
        init(_ owner: ResizeView) { self.owner = owner }
        @objc func tick(_ link: CADisplayLink) { owner?.publishFrame(link) }
    }
}
