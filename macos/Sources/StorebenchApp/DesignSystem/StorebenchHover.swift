import StorebenchCore
import SwiftUI

/// The one place the app follows the pointer. Disclosure headings, navigation rows, tabs, quiet commands, menus and fields
/// all read hover through `storebenchHover` and draw it with `HoverFeedback`, so they answer the pointer alike.
private struct HoverPreviewKey: EnvironmentKey { static let defaultValue: Bool? = nil }
extension EnvironmentValues {
    /// Draws controls as if the pointer were over them (true) or elsewhere (false), such as for a rendered comparison; nil follows the pointer.
    var hoverPreview: Bool? { get { self[HoverPreviewKey.self] } set { self[HoverPreviewKey.self] = newValue } }
}

/// Gives its content whether the pointer is over it, through the shared core.
struct StorebenchHoverReader<Content: View>: View {
    @ViewBuilder let content: (_ hovering: Bool) -> Content
    @State private var hovering = false
    @Environment(\.hoverPreview) private var preview
    var body: some View { content(preview ?? hovering).storebenchHover { hovering = $0 } }
}

extension View {
    /// Tells `changed` when the pointer enters or leaves this view.
    nonisolated func storebenchHover(_ changed: @escaping (Bool) -> Void) -> some View { onHover(perform: changed) }
    /// Tells `moved` where the pointer is over this view, or nil when it leaves, such as for a chart's readout.
    nonisolated func storebenchPointer(_ moved: @escaping (CGPoint?) -> Void) -> some View {
        onContinuousHover { phase in
            switch phase { case .active(let location): moved(location); case .ended: moved(nil) }
        }
    }

    /// The shared hover fill of an interactive area, with the shared corner radius, so the whole target is one shape.
    func storebenchHoverFill(_ hovering: Bool, on ground: HoverFeedback.Ground = .surface, selected: Bool = false,
                             radius: CGFloat = StorebenchTheme.controlRadius) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius)
        return background(StorebenchTheme.hoverColor(hovering, on: ground, selected: selected), in: shape).contentShape(shape)
            .overlay(shape.strokeBorder(StorebenchTheme.hoverOutline(hovering, on: ground)).allowsHitTesting(false).accessibilityHidden(true))
    }
}

extension StorebenchTheme {
    /// The shared hover fill as a colour, for a shape that draws its own background; `resting` shows when the pointer is elsewhere.
    /// The shared hover outline as a colour; clear when the pointer is elsewhere.
    static func hoverOutline(_ hovering: Bool, on ground: HoverFeedback.Ground = .surface) -> Color {
        HoverFeedback.outline(on: ground, hovering: hovering).map(color) ?? .clear
    }
    static func hoverColor(_ hovering: Bool, on ground: HoverFeedback.Ground = .surface, selected: Bool = false, resting: Color = .clear) -> Color {
        HoverFeedback.fill(on: ground, hovering: hovering, selected: selected).map(color) ?? resting
    }
}
