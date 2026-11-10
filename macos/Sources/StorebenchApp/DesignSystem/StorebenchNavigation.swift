import AppKit
import StorebenchCore
import SwiftUI

struct StorebenchNavigationTab<ID: Hashable>: Identifiable {
    let id: ID
    let title, icon: String
    /// Hover help that says what the tab holds; the title alone when nil.
    var help: String? = nil
}

struct StorebenchNavigationTabs<ID: Hashable>: View {
    let items: [StorebenchNavigationTab<ID>]
    let selected: ID
    let label: String
    var minimumWidth = StorebenchTheme.design.number("navigation-minimum-width")
    let select: (ID) -> Void
    @FocusState private var focused: ID?

    var body: some View {
        // All tabs share one row when it fits; when they wrap, the rows hold equal numbers of tabs.
        StorebenchMetricGrid(maximumColumns: max(1, items.count), minimumWidth: minimumWidth, evenRows: true, spacing: StorebenchTheme.design.number("navigation-gap")) { buttons }
            .padding(StorebenchTheme.space(2) + 1)
            .background(StorebenchTheme.color("color-surface-sunken"), in: RoundedRectangle(cornerRadius: StorebenchTheme.radius))
            .overlay(RoundedRectangle(cornerRadius: StorebenchTheme.radius).strokeBorder(StorebenchTheme.border))
            .accessibilityElement(children: .contain).accessibilityLabel(label)
            .onKeyPress { press in
                guard press.modifiers.isEmpty, focused != nil else { return .ignored }
                if press.key == .return || press.key == .space, let focused { select(focused); return .handled }
                let direction = press.key == .leftArrow || press.key == .upArrow ? -1 : press.key == .rightArrow || press.key == .downArrow ? 1 : 0
                guard direction != 0 else { return .ignored }
                focused = KeyboardNavigation.adjacent(items.map(\.id), current: focused, direction: direction); return .handled
            }
    }
    private var buttons: some View {
        ForEach(items) { item in
            StorebenchTabButton(title: item.title, icon: item.icon, help: item.help ?? item.title, selected: item.id == selected, focused: focused == item.id) { select(item.id) }
                .focusable(interactions: .activate).focusEffectDisabled().focused($focused, equals: item.id)
        }
    }
}

private struct StorebenchTabButton: View {
    let title, icon, help: String
    let selected, focused: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            StorebenchLabel(title, icon: icon, size: 16).font(.sbCallout.weight(selected ? .semibold : .medium)).lineLimit(2).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity).padding(.horizontal, StorebenchTheme.space(3)).frame(height: StorebenchTheme.controlHeight)
                .foregroundStyle(StorebenchTheme.color(selected ? "color-accent-muted" : "color-text-tertiary"))
                .background(selected || hovering ? StorebenchTheme.color("color-surface-accent") : StorebenchTheme.surface, in: RoundedRectangle(cornerRadius: StorebenchTheme.controlRadius))
                .overlay(RoundedRectangle(cornerRadius: StorebenchTheme.controlRadius).strokeBorder(StorebenchTheme.color(selected ? "color-border-accent" : "color-border-control")))
                .overlay(alignment: .bottom) { Rectangle().fill(selected ? StorebenchTheme.accent : .clear).frame(height: 3).padding(.horizontal, 7) }
                .overlay(RoundedRectangle(cornerRadius: StorebenchTheme.controlRadius).strokeBorder(focused ? StorebenchTheme.accent : .clear, lineWidth: 2))
                .contentShape(Rectangle())
        }.buttonStyle(StorebenchPressStyle()).onHover { hovering = $0 }
            .help(help).accessibilityLabel(title).accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

struct StorebenchSidebarRow: View {
    let title, icon: String
    let selected, focused: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: StorebenchTheme.space(2)) {
                StorebenchIcon(name: icon, size: 16).frame(width: 20)
                    .foregroundStyle(selected ? StorebenchTheme.color("color-accent-muted") : StorebenchTheme.muted)
                Text(title).font(.sbBody.weight(selected ? .semibold : .regular))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }.padding(.horizontal, StorebenchTheme.space(2)).padding(.vertical, StorebenchTheme.space(1))
                .frame(maxWidth: .infinity, minHeight: StorebenchTheme.controlHeight, alignment: .leading)
                .foregroundStyle(StorebenchTheme.ink)
                .background(StorebenchTheme.color(selected ? "color-surface-accent-strong" : "color-surface-sunken").opacity(selected || hovering ? 1 : 0), in: RoundedRectangle(cornerRadius: StorebenchTheme.controlRadius))
                .overlay(StorebenchControlOutline(border: .clear, focusedOverride: focused))
                .contentShape(RoundedRectangle(cornerRadius: StorebenchTheme.controlRadius))
        }.buttonStyle(StorebenchPressStyle()).onHover { hovering = $0 }
            .help("Open " + title).accessibilityLabel(title).accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

struct StorebenchSidebarHeading: View {
    let title: String
    let expanded, focused: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: StorebenchTheme.space(2)) {
                Text(title).font(.sbCaption.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                StorebenchIcon(name: "next", size: 11).rotationEffect(.degrees(expanded ? 90 : 0))
            }.foregroundStyle(StorebenchTheme.muted)
                .padding(.horizontal, StorebenchTheme.space(2)).padding(.vertical, StorebenchTheme.space(1))
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .overlay(StorebenchControlOutline(border: .clear, focusedOverride: focused))
                .contentShape(RoundedRectangle(cornerRadius: StorebenchTheme.controlRadius))
        }.buttonStyle(StorebenchPressStyle())
            .help((expanded ? "Collapse " : "Expand ") + title).accessibilityLabel(title)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed").accessibilityAddTraits(.isHeader)
    }
}
