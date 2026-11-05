import AppKit
import StorebenchCore
import SwiftUI

struct StorebenchSidebar: View {
    let selection: String?
    let section: AppNavigation.Section
    let hasApp: Bool
    let selectLibrary: (String?) -> Void
    let selectSection: (AppNavigation.Section) -> Void
    let settings: () -> Void
    let help: () -> Void
    /// The sidebar scrolls in the app; a still rendering of the window shows its items without a scroll view.
    var scrolls = true
    @FocusState private var focused: String?
    /// Collapsed groups by key, kept between launches.
    @AppStorage("sidebar.collapsedGroups") private var collapsedGroups = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var collapsed: Set<String> { Set(collapsedGroups.split(separator: ",").map(String.init)) }
    /// A collapsed group still shows the page that is open, so the sidebar always says where you are.
    private func shows(_ group: String, active: Bool) -> Bool { active || !collapsed.contains(group) }
    private func toggle(_ group: String) {
        var next = collapsed
        if next.remove(group) == nil { next.insert(group) }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { collapsedGroups = next.sorted().joined(separator: ",") }
    }
    private func active(_ destination: AppNavigation.Section) -> Bool { hasApp ? section == destination : librarySelection(destination) == selection }

    private var groups: [AppNavigation.Group] { AppNavigation.Group.allCases.filter { !sections($0).isEmpty } }
    private func sections(_ group: AppNavigation.Group) -> [AppNavigation.Section] {
        let all = StorebenchDesign.shared.sections.filter { $0.group == group.key }.compactMap { AppNavigation.Section(key: $0.key) }
        return hasApp ? all : all.filter { LibraryChooser.sections.contains($0) || $0 == .sales || $0 == .history }
    }
    var body: some View {
        Group {
            if scrolls { ScrollView { items } } else { items.frame(maxHeight: .infinity, alignment: .top) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Rectangle().fill(StorebenchTheme.color("color-nav-raised")).frame(height: 1)
                Text("App Store Connect").font(.sbCallout).foregroundStyle(StorebenchTheme.color("color-nav-text"))
                Text("Prepare, review and publish.").font(.sbCallout).foregroundStyle(StorebenchTheme.color("color-nav-muted"))
            }.padding(.horizontal, 26).padding(.vertical, 20).frame(maxWidth: .infinity, alignment: .leading).background(StorebenchTheme.nav)
        }
        .frame(width: 248).background(StorebenchTheme.nav).accessibilityLabel("Main navigation")
        .onKeyPress { press in
            guard press.modifiers.isEmpty, let focused else { return .ignored }
            let workspace = [("Overview", selection == LibraryOverview.Section.overview.selection), ("Apps", selection == "library:apps")].filter { shows("workspace", active: $0.1) }.map(\.0)
            let ids = ["group:workspace"] + workspace + groups.flatMap { group in ["group:" + group.key] + sections(group).filter { shows(group.key, active: active($0)) }.map(\.title) }
                + ["group:support"] + (collapsed.contains("support") ? [] : ["Settings", "Help"])
            let direction = press.key == .upArrow ? -1 : press.key == .downArrow ? 1 : 0
            guard direction != 0 else { return .ignored }
            self.focused = KeyboardNavigation.adjacent(ids, current: focused, direction: direction); return .handled
        }
    }
    private var items: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { selectLibrary(LibraryOverview.Section.overview.selection) } label: {
                StorebenchBrand(onDark: true).padding(.horizontal, 10).padding(.bottom, 18).frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(StorebenchPressStyle()).accessibilityLabel("Storebench overview")
            VStack(alignment: .leading, spacing: 14) {
            group("Workspace", key: "workspace") {
                let overview = selection == LibraryOverview.Section.overview.selection, apps = selection == "library:apps"
                if shows("workspace", active: overview) { item("Overview", icon: "overview", active: overview) { selectLibrary(LibraryOverview.Section.overview.selection) } }
                if shows("workspace", active: apps) { item("Apps", icon: "apps", active: apps) { selectLibrary("library:apps") } }
            }
            ForEach(groups, id: \.self) { group in
                self.group(group.rawValue, key: group.key) {
                    ForEach(sections(group).filter { shows(group.key, active: active($0)) }, id: \.self) { destination in
                        item(destination.title, icon: destination.designIcon, active: active(destination)) {
                            if hasApp { selectSection(destination) } else { selectLibrary(librarySelection(destination)) }
                        }
                    }
                }
            }
            group("Support", key: "support") {
                if shows("support", active: false) {
                    item("Settings", icon: "settings", active: false, action: settings)
                    item("Help", icon: "help", active: false, action: help)
                }
            }
            }
        }.padding(.top, StorebenchTheme.space(4)).padding(.horizontal, 16)
    }
    private func librarySelection(_ section: AppNavigation.Section) -> String {
        if section == .sales { return "library:sales" }
        if section == .history { return LibraryOverview.Section.history.selection }
        return LibraryChooser.selection(section)
    }
    /// A group heading that collapses or expands its items; the heading keeps its size either way.
    private func group<Content: View>(_ title: String, key: String, @ViewBuilder content: () -> Content) -> some View {
        let open = !collapsed.contains(key), id = "group:" + key
        return VStack(alignment: .leading, spacing: 0) {
            Button { toggle(key) } label: {
                HStack(spacing: 6) {
                    Text(title.uppercased()).font(.sbCaption2.bold()).tracking(1.1)
                    Spacer(minLength: 0)
                    StorebenchIcon(name: "next", size: 12).rotationEffect(.degrees(open ? 90 : 0))
                }.foregroundStyle(StorebenchTheme.color("color-nav-muted"))
                    .padding(.horizontal, 13).padding(.vertical, 4).frame(minHeight: 24).frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(RoundedRectangle(cornerRadius: StorebenchTheme.controlRadius).strokeBorder(focused == id ? StorebenchTheme.color("color-nav-focus") : .clear, lineWidth: 2))
                    .contentShape(Rectangle())
            }.buttonStyle(StorebenchPressStyle()).focusable(interactions: .activate).focusEffectDisabled().focused($focused, equals: id)
                .onKeyPress { press in
                    guard focused == id, press.modifiers.isEmpty else { return .ignored }
                    switch press.key {
                    case .return, .space: toggle(key)
                    case .leftArrow: if open { toggle(key) }
                    case .rightArrow: if !open { toggle(key) }
                    default: return .ignored
                    }
                    return .handled
                }
                .help(open ? "Collapse \(title)" : "Expand \(title)").accessibilityLabel(title)
                .accessibilityValue(open ? "Expanded" : "Collapsed").accessibilityAddTraits(.isHeader)
                .padding(.bottom, 4)
            VStack(alignment: .leading, spacing: 3) { content() }
        }
    }
    private func item(_ title: String, icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                StorebenchIcon(name: icon)
                Text(title).font(.sbBody.weight(active ? .semibold : .regular)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }.padding(.horizontal, 13).padding(.vertical, 6).frame(minHeight: 44).frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(StorebenchTheme.color(active ? "color-nav-selected-text" : "color-nav-text"))
                .background(active ? StorebenchTheme.color("color-nav-active") : .clear, in: RoundedRectangle(cornerRadius: StorebenchTheme.controlRadius))
                .overlay(alignment: .leading) { if active { Capsule().fill(StorebenchTheme.color("color-nav-focus")).frame(width: 3, height: 20).padding(.leading, 4) } }
                .overlay(RoundedRectangle(cornerRadius: StorebenchTheme.controlRadius).strokeBorder(focused == title ? StorebenchTheme.color("color-nav-focus") : .clear, lineWidth: 2))
                .contentShape(RoundedRectangle(cornerRadius: StorebenchTheme.controlRadius))
        }.buttonStyle(StorebenchPressStyle()).focusable(interactions: .activate).focusEffectDisabled().focused($focused, equals: title)
            .onKeyPress { press in
                guard focused == title, press.modifiers.isEmpty, press.key == .return || press.key == .space else { return .ignored }
                action(); return .handled
            }
            .help(title).accessibilityLabel(title).accessibilityAddTraits(active ? [.isSelected] : [])
    }
}

struct StorebenchTopbar: View {
    let breadcrumb: String
    var appName: String? = nil
    var canGoBack = false, canGoForward = false
    var back: () -> Void = {}, forward: () -> Void = {}
    let overview: () -> Void
    let signOut: (() -> Void)?
    @Environment(\.workspaceWidth) private var width
    var body: some View {
        let insets = ComponentLayout.pageInsets(viewportWidth: width)
        HStack(spacing: StorebenchTheme.space(2)) {
            HStack(spacing: 4) {
                Button { if canGoBack { back() } } label: { StorebenchIcon(name: "previous") }.buttonStyle(StorebenchButtonStyle(.quiet, size: .icon)).opacity(canGoBack ? 1 : 0).allowsHitTesting(canGoBack).accessibilityHidden(!canGoBack).help("Back").accessibilityLabel("Back")
                Button { if canGoForward { forward() } } label: { StorebenchIcon(name: "next") }.buttonStyle(StorebenchButtonStyle(.quiet, size: .icon)).opacity(canGoForward ? 1 : 0).allowsHitTesting(canGoForward).accessibilityHidden(!canGoForward).help("Forward").accessibilityLabel("Forward")
            }
            HStack(spacing: StorebenchTheme.space(2)) {
                Button("Overview", action: overview).buttonStyle(StorebenchPressStyle()).font(.sbSubheadline).foregroundStyle(StorebenchTheme.muted).frame(height: StorebenchTheme.controlHeight).fixedSize(horizontal: true, vertical: false)
                if let appName, breadcrumb != appName {
                    StorebenchIcon(name: "next", size: 14).foregroundStyle(StorebenchTheme.subtle)
                    // Hugs its name, so the next separator follows it directly; a long name is cut in the middle at 220 pt.
                    Text(appName).font(.sbSubheadline).lineLimit(1).truncationMode(.middle).frame(maxWidth: 220, alignment: .leading).fixedSize(horizontal: true, vertical: false).help(appName)
                }
                if breadcrumb != "Overview" {
                    StorebenchIcon(name: "next", size: 14).foregroundStyle(StorebenchTheme.subtle)
                    Text(breadcrumb).font(.sbSubheadline.weight(.semibold)).lineLimit(1).truncationMode(.middle).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).help(breadcrumb)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).frame(height: StorebenchTheme.controlHeight).accessibilityElement(children: .contain).accessibilityLabel("Current location")
            if let signOut { Button("Sign Out", action: signOut).buttonStyle(StorebenchButtonStyle(.quiet)).environment(\.naturalActions, true).fixedSize(horizontal: true, vertical: false) }
        }.padding(.horizontal, insets.horizontal).frame(maxWidth: 1380).frame(maxWidth: .infinity).frame(height: StorebenchTheme.toolbarHeight)
            .background(StorebenchTheme.color("color-surface-subtle"))
            .background(.regularMaterial).overlay(alignment: .bottom) { StorebenchDivider() }
    }
}
