import StorebenchCore
import SwiftUI

struct StorebenchCollectionSort<Item> {
    let id: String, label: String
    let less: (Item, Item) -> Bool
}

struct StorebenchCollectionEntry<Value>: Identifiable {
    let id: String, value: Value
}

/// A request to show one record: its page is chosen and it opens, then `onRevealed` runs once it is on screen. Every request has
/// its own token, so asking again for the same record, even after it was closed, shows it again.
struct StorebenchCollectionReveal<ID: Hashable>: Equatable {
    let id: ID, token = UUID()
}

struct StorebenchResultsPerPage: View {
    @Binding var size: Int
    var body: some View {
        StorebenchPicker("Results per page", selection: $size) {
            selectionOptions(CollectionPresentation<Int>.pageSizes) { SelectionOption("\($0) results", value: $0) }
        }.environment(\.fieldHintHeight, 0)
    }
}

/// A shared record browser. Visited editors stay mounted through paging, sorting and collapse.
struct StorebenchCollection<Item: Identifiable, Content: View>: View {
    let items: [Item]
    let title: (Item) -> String
    var subtitle: (Item) -> String = { _ in "" }
    var icon: ((Item) -> AnyView)? = nil
    var sorts: [StorebenchCollectionSort<Item>] = []
    var maximumColumns = 1
    var minimumWidth: CGFloat = 260
    var cardSurface = true
    var preferenceID = ""
    var initialOpeningLimit = 0
    var focusedID: Item.ID? = nil
    /// What is missing and how to add it. Every collection names its own empty state; an empty string shows nothing when another message already says it.
    let empty: String
    var onOpen: ((Item) -> Void)? = nil
    /// Rows that only lead somewhere open it directly: the row shows the action and an arrow, and nothing expands.
    var activate: ((Item) -> Void)? = nil
    var action = "Open"
    var reveal: StorebenchCollectionReveal<Item.ID>? = nil
    var onRevealed: ((Item.ID) -> Void)? = nil
    @ViewBuilder let content: (Item) -> Content
    @State private var presentation = CollectionPresentation<Item.ID>()
    @State private var sort = "default"
    @State private var descending = false
    @State private var initialized = false
    @State private var historyOwner: NavigationPresentationContext?
    @State private var historyKey = ""
    @State private var restoringSort: String?
    @State private var restoringDescending: Bool?
    @Environment(\.navigationPresentation) private var history
    @Environment(\.collectionPersistence) private var persistence
    @State private var persistenceReady = false
    @State private var persistenceIssue = ""
    @State private var persistenceWrite: Task<Void, Never>?
    @State private var persistenceOwner: CollectionPersistenceContext?
    @State private var persistenceKey = ""
    @State private var restoredFromHistory = false
    @State private var savedPreference: CollectionViewPreferences?
    private var savedViewKey: String { CollectionViewPreferences.key([persistence.view, history?.scope ?? "", String(reflecting: Item.self), preferenceID]) }
    private struct Snapshot {
        let presentation: CollectionPresentation<Item.ID>, sort: String, descending: Bool
    }

    private var ordered: [Item] {
        let less: ((Item, Item) -> Bool)? = sort == "name" ? { title($0).localizedStandardCompare(title($1)) == .orderedAscending } : sorts.first { $0.id == sort }?.less
        let base = less.map { comparison in
            items.enumerated().sorted { a, b in
                if comparison(a.element, b.element) { return true }
                if comparison(b.element, a.element) { return false }
                return a.offset < b.offset
            }.map(\.element)
        } ?? items
        return descending ? Array(base.reversed()) : base
    }
    private var current: CollectionPresentation<Item.ID>.Page { presentation.page(ordered.map(\.id)) }
    var body: some View {
        VStack(alignment: .leading, spacing: StorebenchTheme.gap) {
            if items.count > 1 { StorebenchCollectionControls(summary: current.summary, pageSize: Binding(get: { presentation.pageSize }, set: { presentation.chooseSize($0) }),
                sort: $sort, descending: $descending, sorts: [("name", "Name")] + sorts.map { ($0.id, $0.label) },
                openingLimit: Binding(get: { presentation.openingLimit }, set: { presentation.chooseOpeningLimit($0, on: current) }),
                allExpanded: !current.ids.isEmpty && current.ids.allSatisfy { presentation.expanded($0, on: current) },
                allCollapsed: current.ids.allSatisfy { !presentation.expanded($0, on: current) },
                expand: { presentation.setPageExpanded(current, true) }, collapse: { presentation.setPageExpanded(current, false) }, pageItems: current.ids.count, expandable: activate == nil) }
            if items.isEmpty && !empty.isEmpty { Text(empty).font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true) }
            StorebenchCollectionLayout(maximumColumns: maximumColumns, minimumWidth: minimumWidth) {
                ForEach(ordered) { item in
                    let visible = current.ids.contains(item.id)
                    if let activate {
                        StorebenchCollectionLink(title: title(item), subtitle: subtitle(item), action: action, icon: icon?(item), visible: visible, surface: cardSurface) { activate(item) }
                            .layoutValue(key: CollectionVisible.self, value: visible)
                    } else {
                    StorebenchCollectionCard(title: title(item), subtitle: subtitle(item), icon: icon?(item), visible: visible, surface: cardSurface,
                        expanded: Binding(get: { presentation.expanded(item.id, on: current) }, set: { value in
                            presentation.setExpanded(item.id, value); if value { onOpen?(item) }
                        }), revealToken: reveal?.id == item.id ? reveal?.token : nil, onShown: { onRevealed?(item.id) }) { content(item).transformEnvironment(\.navigationPresentation) { $0 = $0?.scoped(String(describing: item.id)) } }
                        .layoutValue(key: CollectionVisible.self, value: visible)
                    }
                }
            }
            if current.count > 1 { StorebenchPagination(page: current.number, count: current.count) { presentation.choosePage($0) } }
            if !persistenceIssue.isEmpty { Text(persistenceIssue).font(.sbCaption).foregroundStyle(StorebenchTheme.muted).help(persistenceIssue) }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .onAppear { restorePresentation() }
            .task(id: persistence.taskIdentity + savedViewKey) { await restoreSavedView() }
            .onDisappear { savePresentation() }
            .onChange(of: history?.entry) { savePresentation(); initialized = false; restorePresentation() }
            .onChange(of: presentation) { savePresentation() }
            .onChange(of: sort) { if restoringSort == sort { restoringSort = nil } else if initialized { presentation.resetPage(); savePresentation() } }
            .onChange(of: descending) { if restoringDescending == descending { restoringDescending = nil } else if initialized { presentation.resetPage(); savePresentation() } }
            .onChange(of: items.map(\.id)) { old, next in
                let wasInitialized = initialized
                if !initialized { restorePresentation() }
                else { presentation.reconcile(next) }
                if wasInitialized, let focusedID, !old.contains(focusedID), next.contains(focusedID) { presentation.reveal(focusedID, in: ordered.map(\.id)) }
            }
            .onChange(of: focusedID) { if let focusedID { presentation.reveal(focusedID, in: ordered.map(\.id)) } }
            .onChange(of: reveal) { if let reveal { presentation.reveal(reveal.id, in: ordered.map(\.id)) } }
    }
    private func restorePresentation() {
        guard !initialized, !items.isEmpty else { return }
        historyOwner = history
        historyKey = String(reflecting: Item.self) + ":" + (history?.scope ?? "") + ":" + preferenceID
        if let history, let saved = history.store.collection(historyKey, entry: history.entry, as: Snapshot.self) {
            restoredFromHistory = true
            restoringSort = sort == saved.sort ? nil : saved.sort; restoringDescending = descending == saved.descending ? nil : saved.descending
            presentation = saved.presentation; sort = saved.sort; descending = saved.descending
            presentation.reconcile(items.map(\.id))
        } else if let savedPreference, persistenceKey == savedViewKey {
            restoredFromHistory = false
            apply(savedPreference)
        } else {
            restoredFromHistory = false
            restoringSort = sort == "default" ? nil : "default"; restoringDescending = descending ? false : nil
            sort = "default"; descending = false
            presentation = CollectionPresentation(openingLimit: initialOpeningLimit)
            if let focusedID { presentation.reveal(focusedID, in: ordered.map(\.id)) }
        }
        initialized = true
    }
    private func savePresentation() {
        guard initialized else { return }
        if let historyOwner { historyOwner.store.saveCollection(Snapshot(presentation: presentation, sort: sort, descending: descending), key: historyKey, entry: historyOwner.entry) }
        guard persistenceReady, persistenceKey == savedViewKey, let owner = persistenceOwner, let store = owner.store, owner.view == persistence.view,
              let value = try? presentation.preferences(ids: ordered.map(\.id), sort: sort, descending: descending) else { return }
        let previous = persistenceWrite, key = persistenceKey
        persistenceWrite = Task { @MainActor in
            await previous?.value
            do { try await store.saveCollectionViewPreference(key, value: value); if persistenceKey == key { persistenceIssue = "" } }
            catch { if persistenceKey == key { persistenceIssue = "View options could not be saved. Your current view is kept for this session." } }
        }
    }
    private func restoreSavedView() async {
        persistenceReady = false; savedPreference = nil; persistenceOwner = persistence; persistenceKey = savedViewKey
        let key = savedViewKey, expected = presentation, expectedSort = sort, expectedDescending = descending
        guard let store = persistence.store else { return }
        do {
            let saved = try await store.collectionViewPreference(key)
            guard !Task.isCancelled, savedViewKey == key else { return }
            savedPreference = saved
            if let saved, !restoredFromHistory, presentation == expected, sort == expectedSort, descending == expectedDescending {
                apply(saved)
                initialized = !items.isEmpty
            }
            persistenceReady = true; persistenceIssue = ""; savePresentation()
        } catch {
            if !Task.isCancelled, savedViewKey == key { persistenceIssue = "Saved view options could not be read. Default options are shown; the saved preferences have not been replaced." }
        }
    }
    private func apply(_ saved: CollectionViewPreferences) {
        let chosen = (["default", "name"] + sorts.map(\.id)).contains(saved.sort) ? saved.sort : "default"
        restoringSort = sort == chosen ? nil : chosen; restoringDescending = descending == saved.descending ? nil : saved.descending
        sort = chosen; descending = saved.descending
        presentation = CollectionPresentation(preferences: saved, ids: items.map(\.id))
        if let focusedID { presentation.reveal(focusedID, in: ordered.map(\.id)) }
    }
}

struct StorebenchCollectionControls: View {
    let summary: String
    @Binding var pageSize: Int
    @Binding var sort: String
    @Binding var descending: Bool
    let sorts: [(String, String)]
    @Binding var openingLimit: Int
    let allExpanded, allCollapsed: Bool
    let expand, collapse: () -> Void
    var pageItems = 2
    /// False for rows that open directly, which have nothing to expand.
    var expandable = true
    @State private var options = false
    var body: some View {
        VStack(alignment: .leading, spacing: StorebenchTheme.space(2)) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: StorebenchTheme.space(3)) { leading; Spacer(minLength: StorebenchTheme.space(3)); pageCommand }
                VStack(alignment: .leading, spacing: StorebenchTheme.space(2)) { leading; pageCommand }
            }
            if options {
                StorebenchMetricGrid(maximumColumns: 4, minimumWidth: 180) {
                    StorebenchPicker("Results per page", selection: $pageSize) { selectionOptions(CollectionPresentation<Int>.pageSizes) { SelectionOption("\($0) results", value: $0) } }
                    StorebenchPicker("Sort", selection: $sort) {
                        SelectionOption("Original order", value: "default")
                        selectionOptions(sorts) { SelectionOption($0.1, value: $0.0) }
                    }
                    StorebenchPicker("Order", selection: $descending) { SelectionOption("Ascending", value: false); SelectionOption("Descending", value: true) }
                    if expandable {
                        StorebenchPicker("Default expansion per page · remembered", selection: $openingLimit) {
                            SelectionOption("None", value: 0); SelectionOption("First card", value: 1); SelectionOption("First 3 cards", value: 3); SelectionOption("First 5 cards", value: 5); SelectionOption("All on page", value: -1)
                        }
                    }
                }.environment(\.fieldHintHeight, 0)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .historyDisclosure("collection-view-options", isExpanded: $options)
    }
    private var leading: some View {
        HStack(alignment: .center, spacing: StorebenchTheme.space(3)) {
            StorebenchDisclosureButton(isExpanded: $options, compact: true) {
                Text("View Options").font(.sbCallout.weight(.semibold)).foregroundStyle(StorebenchTheme.color("color-accent-muted"))
            }.fixedSize()
            Text(summary + " · \(pageSize) per page").font(.sbCaption).foregroundStyle(StorebenchTheme.muted).lineLimit(1).fixedSize()
        }
    }
    @ViewBuilder private var pageCommand: some View {
        if pageItems > 1 && expandable {
            Button(allExpanded ? "Collapse All on Page" : "Expand All on Page", action: allExpanded ? collapse : expand)
                .help(allExpanded ? "Close every card on this page." : "Open every card on this page.")
        }
    }
}

/// A row that opens its destination directly, with the action and an arrow at its trailing edge.
private struct StorebenchCollectionLink: View {
    let title, subtitle, action: String
    let icon: AnyView?
    let visible: Bool, surface: Bool
    let activate: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: activate) {
            HStack(spacing: StorebenchTheme.space(3)) {
                if let icon { icon.frame(width: 42, height: 42).fixedSize().accessibilityHidden(true) }
                VStack(alignment: .leading, spacing: 2) {
                    StorebenchAdaptiveText(text: title, maximumHeight: 40, font: .sbHeadline)
                    if !subtitle.isEmpty { StorebenchAdaptiveText(text: subtitle, maximumHeight: 34, font: .sbCaption, color: StorebenchTheme.muted) }
                }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 12) {
                    Text(action).font(.sbCallout.weight(.semibold)).lineLimit(1).fixedSize()
                    StorebenchIcon(name: "right")
                }.foregroundStyle(StorebenchTheme.color("color-accent-muted"))
            }
            .padding(surface ? StorebenchTheme.padding : 0).frame(maxWidth: .infinity, alignment: .leading)
            .background { if surface { RoundedRectangle(cornerRadius: StorebenchTheme.radius).fill(hovering ? StorebenchTheme.page : StorebenchTheme.surface) } }
            .overlay { if surface { RoundedRectangle(cornerRadius: StorebenchTheme.radius).strokeBorder(StorebenchTheme.border) } }
            .contentShape(Rectangle())
        }.buttonStyle(StorebenchPressStyle()).onHover { hovering = $0 }
            .help(title + " · " + action).accessibilityLabel(title + " · " + action).accessibilityHint(subtitle)
            .collectionVisibility(visible)
    }
}

private struct StorebenchCollectionCard<Content: View>: View {
    let title, subtitle: String
    let icon: AnyView?
    let visible: Bool, surface: Bool
    @Binding var expanded: Bool
    var revealToken: UUID? = nil
    var onShown: () -> Void = {}
    @ViewBuilder let content: () -> Content
    @State private var mounted = false
    var body: some View {
        VStack(alignment: .leading, spacing: expanded && visible ? StorebenchTheme.gap : 0) {
            StorebenchDisclosureButton(isExpanded: $expanded, card: true) {
                HStack(spacing: StorebenchTheme.space(3)) {
                    if let icon { icon.frame(width: 42, height: 42).fixedSize().accessibilityHidden(true) }
                    VStack(alignment: .leading, spacing: 2) {
                        StorebenchAdaptiveText(text: title, maximumHeight: 40, font: .sbHeadline)
                        if !subtitle.isEmpty { StorebenchAdaptiveText(text: subtitle, maximumHeight: 34, font: .sbCaption, color: StorebenchTheme.muted) }
                    }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                }
            }.accessibilityLabel(title)
            if mounted || expanded {
                VStack(alignment: .leading, spacing: StorebenchTheme.gap) {
                    content()
                }.fixedSize(horizontal: false, vertical: true)
                    .collectionVisibility(expanded && visible)
            }
        }.padding(surface ? StorebenchTheme.padding : 0).frame(maxWidth: .infinity, alignment: .leading)
            .background { if surface { RoundedRectangle(cornerRadius: StorebenchTheme.radius).fill(StorebenchTheme.surface) } }
            .overlay { if surface { RoundedRectangle(cornerRadius: StorebenchTheme.radius).strokeBorder(StorebenchTheme.border) } }
            .collectionVisibility(visible)
            .onChange(of: expanded, initial: true) { if expanded { mounted = true } }
            // Runs after the update that opened and showed this card, so a scroll to its content finds it laid out.
            .onChange(of: expanded && visible ? revealToken : nil, initial: true) { _, shown in if shown != nil { onShown() } }
    }
}

extension View {
    /// Hiding presentation must not retire an editor or release a pending operation's protection.
    func collectionVisibility(_ visible: Bool) -> some View {
        modifier(StorebenchCollectionVisibility(visible: visible))
    }
}
private struct CollectionVisibleEnvironment: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var collectionVisible: Bool {
        get { self[CollectionVisibleEnvironment.self] }
        set { self[CollectionVisibleEnvironment.self] = newValue }
    }
}
private struct StorebenchCollectionVisibility: ViewModifier {
    let visible: Bool
    @Environment(\.collectionVisible) private var parentVisible
    func body(content: Content) -> some View {
        let shown = visible && parentVisible
        CollectionVisibilityLayout(visible: shown) { content }.frame(height: shown ? nil : 0, alignment: .top).clipped().opacity(shown ? 1 : 0)
            .environment(\.isEnabled, shown).allowsHitTesting(shown).accessibilityHidden(!shown).environment(\.collectionVisible, shown)
    }
}
private struct CollectionVisibilityLayout: Layout {
    let visible: Bool
    struct Cache { var measurement = LayoutMeasurementCache<CGFloat, ComponentLayout.CollectionGrid>() }
    func makeCache(subviews: Subviews) -> Cache { Cache() }
    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache.measurement.invalidate() }
    private func geometry(_ width: CGFloat, subviews: Subviews) -> ComponentLayout.CollectionGrid {
        ComponentLayout.collectionGrid(width: width, heights: subviews.map { view in
            visible ? view.sizeThatFits(ProposedViewSize(width: width, height: nil)).height : nil
        }, maximum: 1, minimumWidth: 1, spacing: 0)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        cache.measurement.invalidate()
        guard visible else { return .zero }
        let width = proposal.usableWidth()
        return CGSize(width: width, height: cache.measurement.resolve(width) { geometry(width, subviews: subviews) }.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        guard visible else { return }
        let layout = cache.measurement.consume(bounds.width) ?? geometry(bounds.width, subviews: subviews)
        for (index, view) in subviews.enumerated() {
            let frame = layout.frames[index]
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }
}
private struct CollectionVisible: LayoutValueKey { static let defaultValue = true }
private struct StorebenchCollectionLayout: Layout {
    let maximumColumns: Int, minimumWidth: CGFloat
    struct Cache { var measurement = LayoutMeasurementCache<CGFloat, ComponentLayout.CollectionGrid>() }
    func makeCache(subviews: Subviews) -> Cache { Cache() }
    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache.measurement.invalidate() }
    private func geometry(_ width: CGFloat, subviews: Subviews) -> ComponentLayout.CollectionGrid {
        let count = subviews.filter { $0[CollectionVisible.self] }.count
        let columns = ComponentLayout.columns(width: width, count: count, maximum: maximumColumns, minimumWidth: minimumWidth, spacing: StorebenchTheme.gap)
        let cell = max(0, (width - CGFloat(columns - 1) * StorebenchTheme.gap) / CGFloat(columns))
        return ComponentLayout.collectionGrid(width: width, heights: subviews.map { $0[CollectionVisible.self] ? Double($0.sizeThatFits(ProposedViewSize(width: cell, height: nil)).height) : nil }, maximum: maximumColumns, minimumWidth: minimumWidth, spacing: StorebenchTheme.gap)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.usableWidth()
        cache.measurement.invalidate()
        let grid = cache.measurement.resolve(width) { geometry(width, subviews: subviews) }
        return CGSize(width: width, height: grid.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let grid = cache.measurement.consume(bounds.width) ?? geometry(bounds.width, subviews: subviews)
        for (index, frame) in grid.frames.enumerated() where index < subviews.count && subviews[index][CollectionVisible.self] {
            subviews.place(index, at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }
}
