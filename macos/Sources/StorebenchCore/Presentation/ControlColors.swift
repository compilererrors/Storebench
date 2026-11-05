import Foundation

/// The foreground and opaque surface are chosen together for every control state.
public struct ControlColors: Equatable, Sendable {
    public enum Variant: CaseIterable, Sendable { case primary, secondary, quiet, danger, field }
    public let foreground, background, border: String
    /// An unavailable control and one whose operation is running both look dimmed, as in macOS; a running one also shows its spinner.
    public init(_ variant: Variant, enabled: Bool = true, busy: Bool = false, emphasized: Bool = false, settings: Bool = false) {
        guard enabled && !busy else {
            foreground = "color-text-subtle"; background = "color-surface-sunken"; border = "color-border-control"; return
        }
        switch variant {
        case .primary:
            foreground = "color-on-accent"; background = emphasized ? "color-accent-strong" : "color-accent"; border = background
        case .secondary:
            foreground = settings ? "color-text-secondary" : "color-accent-muted"
            background = emphasized ? "color-surface-accent-strong" : settings ? "color-surface-subtle" : "color-surface-accent"
            border = settings ? "color-border-control" : "color-border-accent"
        case .quiet:
            foreground = "color-text-secondary"; background = emphasized ? "color-surface-accent" : "color-surface-subtle"; border = "color-border-control"
        case .danger:
            foreground = "color-danger"; background = "color-danger-surface"; border = "color-danger-border"
        case .field:
            foreground = "color-text"; background = emphasized ? "color-surface-subtle" : "color-surface"; border = emphasized ? "color-border-accent" : "color-border-control"
        }
    }
}
