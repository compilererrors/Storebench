import AppKit
import SwiftUI

/// A stable native identity for controls hosted by SwiftUI, including custom button styles.
final class StorebenchControlMarker: NSView {
    var available = false
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
private struct StorebenchNativeControlIdentity: NSViewRepresentable {
    let id: String
    func makeNSView(context: Context) -> StorebenchControlMarker {
        let view = StorebenchControlMarker(); view.setAccessibilityElement(false); return view
    }
    func updateNSView(_ view: StorebenchControlMarker, context: Context) {
        view.identifier = NSUserInterfaceItemIdentifier(id)
        view.available = context.environment.isEnabled && !context.environment.actionBusy
    }
}
extension View {
    func storebenchControlID(_ id: String) -> some View {
        accessibilityIdentifier(id).background(StorebenchNativeControlIdentity(id: id))
    }
}
