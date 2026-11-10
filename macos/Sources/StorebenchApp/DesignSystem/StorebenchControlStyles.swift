import AppKit
import StorebenchCore
import SwiftUI

/// Independent options use native checkboxes; a prominent setting opts into a switch explicitly.
struct StorebenchToggleStyle: ToggleStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.actionBusy) private var actionBusy
    func makeBody(configuration: Configuration) -> some View {
        let locked = !enabled && actionBusy
        let toggle = Toggle(isOn: Binding(get: { configuration.isOn }, set: { if !locked { configuration.isOn = $0 } })) {
            HStack(spacing: 0) {
                configuration.label.font(.sbCallout).foregroundStyle(enabled || actionBusy ? StorebenchTheme.ink : StorebenchTheme.subtle)
                    .fixedSize(horizontal: false, vertical: true)
                if prominent { Spacer(minLength: StorebenchTheme.gap) }
            }
        }.environment(\.isEnabled, enabled || actionBusy).allowsHitTesting(!locked)
        return Group {
            if prominent { toggle.toggleStyle(.switch).controlSize(.small).frame(maxWidth: .infinity, minHeight: StorebenchTheme.controlHeight, alignment: .leading) }
            else { toggle.toggleStyle(.checkbox).frame(minHeight: StorebenchTheme.measure("optionHeight"), alignment: .leading) }
        }
    }
}

struct StorebenchPicker<Selection: Hashable>: View {
    let title: String
    var hint = ""
    @Binding var selection: Selection
    let options: [SelectionOption<Selection>]
    private var hideLabel = false
    init(_ title: String, selection: Binding<Selection>, hint: String = "", @SelectionOptionsBuilder<Selection> content: () -> [SelectionOption<Selection>]) { self.title = title; self.hint = hint; _selection = selection; options = content() }
    func labelsHidden() -> Self { var copy = self; copy.hideLabel = true; return copy }
    var body: some View {
        StorebenchFormField(label: title, hint: hint, hideLabel: hideLabel, hideHint: hideLabel) {
            StorebenchNativePicker(title: title, selection: $selection, options: options)
        }.accessibilityLabel(title)
    }
}

/// One visual vocabulary for selections, searchable selections, navigation choices and command menus.
struct StorebenchMenuFace: View {
    let title: String
    var icon = ""
    var command = false
    var searchable = false
    var focused: Bool? = nil
    var emphasized = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.actionBusy) private var busy
    var body: some View {
        let active = enabled || busy
        HStack(spacing: StorebenchTheme.space(2)) {
            if !icon.isEmpty { StorebenchIcon(name: icon, size: 14) }
            Text(title).font(command ? .sbCallout.weight(.semibold) : .sbBody).lineLimit(1).truncationMode(.middle)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            if searchable { StorebenchIcon(name: "keywords", size: 14).foregroundStyle(active ? StorebenchTheme.muted : StorebenchTheme.subtle) }
            StorebenchIcon(name: "next", size: 14).rotationEffect(.degrees(90)).foregroundStyle(active ? StorebenchTheme.muted : StorebenchTheme.subtle)
        }.padding(.horizontal, StorebenchTheme.space(3)).frame(minWidth: 0, maxWidth: .infinity)
            .frame(height: StorebenchTheme.controlHeight)
            .foregroundStyle(active ? command ? StorebenchTheme.color("color-accent-muted") : StorebenchTheme.ink : StorebenchTheme.subtle)
            .background(StorebenchTheme.color(active ? emphasized ? "color-surface-subtle" : command ? "color-surface-accent" : "color-surface" : "color-surface-sunken"), in: RoundedRectangle(cornerRadius: StorebenchTheme.controlRadius))
            .overlay(StorebenchControlOutline(border: StorebenchTheme.color(emphasized ? "color-border-accent" : "color-border-control"), focusedOverride: focused))
            .contentShape(RoundedRectangle(cornerRadius: StorebenchTheme.controlRadius))
    }
}

struct StorebenchPressStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && enabled && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct StorebenchNavigationSelect<Options: View>: View {
    let title, selected: String
    @ViewBuilder let options: () -> Options
    @State private var hovered = false
    var body: some View {
        StorebenchFormField(label: title, hideHint: true) {
            Menu { options().nativeMenuContent() } label: { StorebenchMenuFace(title: selected, emphasized: hovered) }
                .menuStyle(.button).menuIndicator(.hidden).buttonStyle(StorebenchPressStyle()).onHover { hovered = $0 }
                .frame(height: StorebenchTheme.controlHeight)
                .foregroundStyle(StorebenchTheme.ink).help(selected).accessibilityLabel("Switch " + title.lowercased()).accessibilityValue(selected)
        }
    }
}

/// Button geometry stays in the label; system menus keep their own menu-item rendering.
struct StorebenchButtonStyle: ButtonStyle {
    typealias Variant = ControlColors.Variant
    enum Size { case regular, icon }
    var variant: Variant = .secondary
    var size: Size = .regular
    var stretch = false
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    init(_ variant: Variant = .secondary, size: Size = .regular, stretch: Bool = false) { self.variant = variant; self.size = size; self.stretch = stretch }
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(StorebenchControlSurface(variant: configuration.role == .destructive ? .danger : variant, size: size, stretch: stretch, emphasized: hovering || configuration.isPressed))
            .scaleEffect(configuration.isPressed && enabled && !reduceMotion ? 0.99 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(RoundedRectangle(cornerRadius: StorebenchTheme.controlRadius))
            .onHover { hovering = $0 }
    }
}

/// Commands in content use an opaque surface; Liquid Glass is reserved for the navigation layer, as Apple recommends.
struct StorebenchControlSurface: ViewModifier {
    let variant: ControlColors.Variant
    var size: StorebenchButtonStyle.Size = .regular
    var stretch = false
    var emphasized = false
    var focused: Bool? = nil
    @Environment(\.naturalActions) private var naturalActions
    @Environment(\.actionFill) private var actionFill
    @Environment(\.actionBusy) private var actionBusy
    @Environment(\.isEnabled) private var enabled
    func body(content: Content) -> some View {
        let colors = ControlColors(variant, enabled: enabled, busy: actionBusy, emphasized: emphasized)
        let radius = StorebenchTheme.controlRadius
        let icon = CGFloat(StorebenchTheme.controlHeight)
        let width: StorebenchCommandWidth = size == .icon ? .init(minimum: icon, maximum: icon, fill: false)
            // Standard commands share one width, so buttons line up on the grid; only chips, fields and stretched tiles size otherwise.
            : .init(minimum: naturalActions || variant == .field ? 0 : CGFloat(StorebenchTheme.actionWidth),
                    maximum: naturalActions && !stretch && !actionFill ? .infinity : CGFloat(stretch ? StorebenchTheme.actionMaxWidth : StorebenchTheme.actionWidth), fill: stretch || actionFill)
        width {
            content.font(.sbCallout.weight(variant == .field ? .regular : .semibold)).lineLimit(nil).multilineTextAlignment(.center)
                .padding(.horizontal, size == .icon ? 4 : 16)
        }
            .frame(minHeight: StorebenchTheme.controlHeight)
            .foregroundStyle(StorebenchTheme.color(colors.foreground))
            .background(StorebenchTheme.color(colors.background), in: RoundedRectangle(cornerRadius: radius))
            .overlay(StorebenchControlOutline(border: StorebenchTheme.color(colors.border), radius: radius, focusedOverride: focused))
    }
}

/// Observes the control's system focus without adding another focus target or binding.
struct StorebenchControlOutline: View {
    var border = StorebenchTheme.color("color-border-control")
    var radius = StorebenchTheme.controlRadius
    var focusedOverride: Bool? = nil
    @Environment(\.isFocused) private var focused
    @Environment(\.isEnabled) private var enabled
    @Environment(\.actionBusy) private var actionBusy
    var body: some View {
        RoundedRectangle(cornerRadius: radius)
            .strokeBorder(enabled && (focusedOverride ?? focused) ? StorebenchTheme.color("color-focus") : enabled || actionBusy ? border : StorebenchTheme.border,
                          lineWidth: enabled && (focusedOverride ?? focused) ? 2 : 1)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// A busy form keeps its normal colours: the operation locks the field without making it look unavailable.
struct StorebenchTextFieldStyle: TextFieldStyle {
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.actionBusy) private var actionBusy
    func _body(configuration: TextField<Self._Label>) -> some View {
        let active = enabled || actionBusy
        return configuration.font(.system(size: StorebenchTheme.measure("inputFont"))).textFieldStyle(.plain).padding(.horizontal, 11)
            .frame(height: StorebenchTheme.controlHeight).background(active ? StorebenchTheme.surface : StorebenchTheme.color("color-surface-sunken"), in: RoundedRectangle(cornerRadius: StorebenchTheme.controlRadius))
            .foregroundStyle(active ? StorebenchTheme.ink : StorebenchTheme.subtle)
            .overlay(StorebenchControlOutline(border: StorebenchTheme.color(hovering ? "color-border-accent" : "color-border-control")))
            .onHover { hovering = $0 }
    }
}


/// A command's width: its label on one line within the minimum and maximum, or the whole proposal when it fills
/// a shared cell or stretches. A label wider than the maximum wraps to a second line instead of being cut off.
struct StorebenchCommandWidth: Layout {
    let minimum: CGFloat, maximum: CGFloat, fill: Bool
    private func width(_ proposal: ProposedViewSize, _ subviews: Subviews) -> CGFloat {
        let ideal = subviews.first?.sizeThatFits(.unspecified).width ?? 0
        let natural = min(max(ideal, minimum), maximum)
        guard let offered = proposal.width, offered.isFinite else { return natural }
        return fill ? max(offered, 0) : min(natural, max(offered, 0))
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let resolved = width(proposal, subviews)
        let height = subviews.first?.sizeThatFits(ProposedViewSize(width: resolved, height: proposal.height)).height ?? 0
        return CGSize(width: resolved, height: height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}
