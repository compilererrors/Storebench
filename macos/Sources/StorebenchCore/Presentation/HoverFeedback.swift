/// How every control shows that the pointer is over it, so disclosure headings, navigation rows, quiet commands, menus and
/// fields answer the pointer alike across the app. The values are design token names.
public enum HoverFeedback {
    public enum Ground: Sendable, CaseIterable {
        /// An area on a card or dialog surface: a disclosure heading, a navigation row, a quiet command or a tab.
        case surface
        /// A row on the page background, such as the sidebar.
        case page
    }
    /// The fill behind an area the pointer is over or that is selected; nil leaves it clear.
    public static func fill(on ground: Ground, hovering: Bool, selected: Bool = false) -> String? {
        switch ground {
        case .surface: selected ? "color-surface-accent-strong" : hovering ? "color-surface-accent" : nil
        case .page: selected ? "color-surface-accent-strong" : hovering ? "color-surface-sunken" : nil
        }
    }
    /// The outline of an area under the pointer: the same accent border bordered commands, menus and fields show, so every
    /// target answers the pointer with one cue. Rows on the page background, such as the sidebar, show their fill only.
    public static func outline(on ground: Ground, hovering: Bool) -> String? {
        ground == .surface && hovering ? border(hovering: true) : nil
    }
    /// The border of a bordered control, such as a menu or a field, while the pointer is over it.
    public static func border(hovering: Bool) -> String { hovering ? "color-border-accent" : "color-border-control" }
    /// A standard push button under the pointer: a primary command turns a darker accent with a darker rim, and secondary and
    /// destructive commands get the accent border that menus and fields show. `tint` colours the button; `border` is drawn around it, or nil.
    public static func command(_ variant: ControlColors.Variant, hovering: Bool) -> (tint: String, border: String?) {
        switch variant {
        case .primary: (hovering ? "color-accent-strong" : "color-accent", hovering ? "color-accent-strong" : nil)
        case .danger: ("color-danger", hovering ? "color-danger-border" : nil)
        default: ("color-accent", hovering ? border(hovering: true) : nil)
        }
    }
}
