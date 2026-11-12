import AppKit
import StorebenchCore
import SwiftUI

@MainActor struct StorebenchMaterialAction {
    let title: String
    var enabled = true
    var separator = false
    var destructive = false
    let run: () -> Void
}

@MainActor struct StorebenchMaterialInteraction {
    let id, title, context: String
    let order, visibleOrder: [String]
    let enabled, reduceMotion: Bool
    let session: MaterialReorder
    let apply: ([String], [String], String) -> Bool
    let open, remove: (() -> Void)?
    var subjects: [String] { session.subjects(for: id, order: visibleOrder) }
    func select(_ modifiers: NSEvent.ModifierFlags = [], preserving: Bool = false) {
        guard enabled else { return }
        session.select(id, order: visibleOrder, toggle: modifiers.contains(.command), extending: modifiers.contains(.shift), preserving: preserving)
    }
    func move(_ destination: MaterialReorder.Destination, selected requested: [String]? = nil) {
        let selected = requested ?? subjects
        guard enabled, !session.active, let next = MaterialReorder.moving(order, sources: Set(selected), destination: destination) else { return }
        var accepted = false
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) { accepted = apply(next, order, context) }
        if accepted { session.selectAll(selected) } else { session.rejected() }
    }
    func actions() -> [StorebenchMaterialAction] {
        guard enabled, !session.active else { return [] }
        let selected = subjects, count = selected.count
        let prefix = count > 1 ? "Move \(count) Items" : "Move"
        var actions: [StorebenchMaterialAction] = []
        if let open { actions.append(.init(title: "Open", run: open)) }
        for (title, destination) in [("to Beginning", MaterialReorder.Destination.beginning), ("to End", .end), ("Earlier", .earlier), ("Later", .later)] {
            actions.append(.init(title: prefix + " " + title, enabled: MaterialReorder.moving(order, sources: Set(subjects), destination: destination) != nil,
                                 separator: title == "to Beginning" && !actions.isEmpty, run: { move(destination, selected: selected) }))
        }
        actions.append(.init(title: "Select All", enabled: Set(visibleOrder) != session.selection, separator: true, run: { session.selectAll(visibleOrder) }))
        actions.append(.init(title: "Deselect All", enabled: !session.selection.isEmpty, run: { session.clearSelection() }))
        if count <= 1, let remove { actions.append(.init(title: "Remove", separator: true, destructive: true, run: { remove(); session.clearSelection() })) }
        return actions
    }
    func nativeMenu() -> NSMenu {
        select(preserving: true)
        let menu = NSMenu(title: title); menu.autoenablesItems = false
        var separator = false
        for action in actions() {
            separator = separator || action.separator
            guard action.enabled else { continue }
            if separator, !menu.items.isEmpty { menu.addItem(.separator()) }
            separator = false
            let target = StorebenchMaterialMenuTarget(action.run)
            let item = NSMenuItem(title: action.title, action: #selector(StorebenchMaterialMenuTarget.invokeMaterialAction), keyEquivalent: "")
            item.target = target; item.representedObject = target
            menu.addItem(item)
        }
        return menu
    }
}

@MainActor private final class StorebenchMaterialMenuTarget: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func invokeMaterialAction() { action() }
}

private struct StorebenchMaterialInteractionKey: EnvironmentKey { static var defaultValue: StorebenchMaterialInteraction? { nil } }
extension EnvironmentValues {
    var materialInteraction: StorebenchMaterialInteraction? {
        get { self[StorebenchMaterialInteractionKey.self] }
        set { self[StorebenchMaterialInteractionKey.self] = newValue }
    }
}

extension View {
    func materialReorderCard(id: String, title: String, order: [String], visibleOrder: [String]? = nil, context: String, enabled: Bool, session: MaterialReorder,
                             apply: @escaping ([String], [String], String) -> Bool, open: (() -> Void)? = nil, remove: (() -> Void)? = nil) -> some View {
        modifier(StorebenchMaterialCardInteraction(id: id, title: title, order: order, visibleOrder: visibleOrder ?? order,
            context: context, enabled: enabled, session: session, apply: apply, open: open, remove: remove))
    }
}

private struct StorebenchMaterialCardInteraction: ViewModifier {
    let id, title: String, order, visibleOrder: [String], context: String, enabled: Bool, session: MaterialReorder
    let apply: ([String], [String], String) -> Bool
    let open, remove: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var environmentEnabled
    private var interaction: StorebenchMaterialInteraction {
        .init(id: id, title: title, context: context, order: order, visibleOrder: visibleOrder, enabled: enabled && environmentEnabled,
              reduceMotion: reduceMotion, session: session, apply: apply, open: open, remove: remove)
    }
    func body(content: Content) -> some View {
        content.materialDropTarget(id: id, session: session)
            .storebenchControlID("material.card." + id)
            .environment(\.materialInteraction, interaction)
            .contextMenu { StorebenchMaterialMenuContents(interaction: interaction) }
            .accessibilityAddTraits(session.selection.contains(id) ? [.isSelected] : [])
            .accessibilityAction(named: Text("Select")) { interaction.select() }
            .accessibilityAction(named: Text("Move to Beginning")) { interaction.move(.beginning) }
            .accessibilityAction(named: Text("Move to End")) { interaction.move(.end) }
    }
}

private struct StorebenchMaterialMenuContents: View {
    let interaction: StorebenchMaterialInteraction
    var body: some View {
        ForEach(Array(interaction.actions().enumerated()), id: \.offset) { _, action in
            if action.separator { StorebenchMenuSeparator() }
            Button(action.title, role: action.destructive ? .destructive : nil, action: action.run).disabled(!action.enabled)
        }
    }
}

/// Quiet card commands keep secondary moves in one discoverable menu instead of repeating arrow and destructive buttons.
struct StorebenchMaterialToolbar: View {
    @Environment(\.materialInteraction) private var interaction
    var body: some View {
        if let interaction {
            HStack(spacing: StorebenchTheme.space(2)) {
                StorebenchReorderHandle(id: interaction.id, title: interaction.title, context: interaction.context, order: interaction.order,
                    enabled: interaction.enabled, session: interaction.session, apply: interaction.apply)
                Spacer(minLength: StorebenchTheme.space(2))
                HStack(spacing: StorebenchTheme.space(2)) {
                    if let open = interaction.open {
                        StorebenchIconButton(title: "Open " + interaction.title, icon: "screenshots", action: open)
                    }
                    StorebenchIconMenu(title: "Actions for " + interaction.title) { StorebenchMaterialMenuContents(interaction: interaction) }
                        .storebenchControlID("material.actions." + interaction.id)
                }
                .storebenchWorking(interaction.session.active)
            }.storebenchWorking(!interaction.enabled)
        }
    }
}
