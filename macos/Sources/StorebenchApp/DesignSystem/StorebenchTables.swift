import AppKit
import StorebenchCore
import SwiftUI

struct StorebenchTableControls: View {
    @Binding var query: String
    @Binding var sort: String
    @Binding var descending: Bool
    let options: [(String, String)]
    var pageSize: Binding<Int>?
    var searchTitle = "Search table"
    var filter: Binding<String>? = nil
    var filters: [(String, String)] = []
    var body: some View {
        HStack(spacing: StorebenchTheme.space(2)) {
            StorebenchTableControlsLayout { search; commands }
            if let filter {
                Menu {
                    ForEach(filters, id: \.0) { item in
                        StorebenchMenuOption(title: item.1, selected: filter.wrappedValue == item.0) { filter.wrappedValue = item.0 }
                    }.nativeMenuContent()
                } label: { Image(nsImage: StorebenchIcon.templateImage(name: "filter", size: 16)) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .frame(width: StorebenchTheme.controlHeight, height: StorebenchTheme.controlHeight)
                    .tint(filter.wrappedValue == filters.first?.0 ? StorebenchTheme.muted : StorebenchTheme.accent)
                    .help("Filter: " + (filters.first { $0.0 == filter.wrappedValue }?.1 ?? "All"))
                    .accessibilityLabel("Filter Table").accessibilityValue(filters.first { $0.0 == filter.wrappedValue }?.1 ?? "All")
                    .storebenchControlID("table.filter")
            }
        }
            .environment(\.naturalActions, true).accessibilityElement(children: .contain).accessibilityLabel("Table controls")
    }
    private var search: some View { StorebenchTableSearch(title: searchTitle, text: $query).frame(height: StorebenchTheme.controlHeight).frame(minWidth: 0, maxWidth: .infinity) }
    @ViewBuilder private var commands: some View {
        Menu {
            ForEach(options, id: \.0) { item in
                StorebenchMenuOption(title: item.1, selected: sort == item.0) { sort = item.0 }
            }.nativeMenuContent()
            Divider()
            StorebenchMenuOption(title: "Ascending", selected: !descending) { descending = false }.nativeMenuContent()
            StorebenchMenuOption(title: "Descending", selected: descending) { descending = true }.nativeMenuContent()
        } label: { Image(nsImage: StorebenchIcon.templateImage(name: "sort", size: 16)) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .frame(width: StorebenchTheme.controlHeight, height: StorebenchTheme.controlHeight)
            .help("Sort by " + (options.first { $0.0 == sort }?.1 ?? "Original Order") + (descending ? ", Descending" : ", Ascending"))
            .accessibilityLabel("Sort Table").accessibilityValue((options.first { $0.0 == sort }?.1 ?? "Original Order") + (descending ? ", Descending" : ", Ascending"))
            .storebenchControlID("table.sort")
        if let pageSize {
            Menu {
                ForEach([5, 10, 20, 50], id: \.self) { count in
                    StorebenchMenuOption(title: "\(count) Rows", selected: pageSize.wrappedValue == count) { pageSize.wrappedValue = count }
                }.nativeMenuContent()
            } label: { Text("\(pageSize.wrappedValue) Rows").font(.sbCaption).monospacedDigit() }
                .menuStyle(.borderlessButton).fixedSize().frame(height: StorebenchTheme.controlHeight)
                .help("Rows per Page").accessibilityLabel("Rows per Page").accessibilityValue(String(pageSize.wrappedValue))
                .storebenchControlID("table.page-size")
        }
    }
}

/// macOS owns text editing, the search and clear affordances, focus ring and keyboard behavior.
private struct StorebenchTableSearch: NSViewRepresentable {
    let title: String
    @Binding var text: String
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.controlSize = .regular; field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.sendsSearchStringImmediately = true; field.sendsWholeSearchString = false
        field.delegate = context.coordinator; field.target = context.coordinator; field.action = #selector(Coordinator.changed(_:))
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = title; field.setAccessibilityLabel(title); field.isEnabled = enabled
        if field.stringValue != text { field.stringValue = text }
    }
    @MainActor final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: StorebenchTableSearch
        init(_ parent: StorebenchTableSearch) { self.parent = parent }
        @objc func changed(_ field: NSSearchField) { if parent.text != field.stringValue { parent.text = field.stringValue } }
        func controlTextDidChange(_ notification: Notification) { if let field = notification.object as? NSSearchField { changed(field) } }
    }
}

struct StorebenchTablePageFooter: View {
    let summary: String, page: Int, count: Int
    let choose: (Int) -> Void
    private var pages: [Int] { Array(Set([1, count] + Array(max(1, page - 5)...max(1, min(count, page + 5))))).sorted() }
    var body: some View {
        HStack(spacing: StorebenchTheme.space(2)) {
            Text(summary).font(.sbCaption).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if count > 1 {
                StorebenchIconButton(title: "Previous Page", icon: "previous") { choose(max(1, page - 1)) }.disabled(page <= 1)
                Menu {
                    ForEach(pages, id: \.self) { number in StorebenchMenuOption(title: "Page \(number)", selected: number == page) { choose(number) } }.nativeMenuContent()
                } label: { Text("\(page) of \(count)").font(.sbCaption).monospacedDigit() }
                    .menuStyle(.borderlessButton).fixedSize().help("Go to Page").accessibilityLabel("Page \(page) of \(count)")
                StorebenchIconButton(title: "Next Page", icon: "next") { choose(min(count, page + 1)) }.disabled(page >= count)
            }
        }.frame(minHeight: StorebenchTheme.controlHeight)
    }
}

/// Search and view options belong to the table they control, above its header rather than in a separate form.
struct StorebenchDataTable<Controls: View, Content: View, Footer: View>: View {
    @ViewBuilder let controls: () -> Controls
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer
    var body: some View {
        StorebenchTableFrame {
            VStack(spacing: 0) {
                controls().padding(.horizontal, 12).padding(.vertical, 6)
                StorebenchDivider()
                content()
                StorebenchDivider()
                footer().padding(.horizontal, 12).padding(.vertical, 6)
            }
        }
    }
}

private struct StorebenchTableControlsLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.usableWidth()
        return CGSize(width: width, height: ComponentLayout.tableControls(width: width, pageSize: subviews.count > 2).height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = ComponentLayout.tableControls(width: bounds.width, pageSize: subviews.count > 2)
        for (index, view) in subviews.enumerated() {
            let frame = layout.frames[index]
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }
}

/// Adapter for report presenters whose validated ordering uses field:direction keys.
struct StorebenchReportTableControls: View {
    @Binding var query: String
    @Binding var order: String
    @Binding var pageSize: Int
    let options: [(String, String)], searchTitle: String
    var body: some View {
        StorebenchTableControls(query: $query,
            sort: Binding(get: { order.components(separatedBy: ":")[0] }, set: { order = $0 + (order.hasSuffix(":desc") ? ":desc" : ":asc") }),
            descending: Binding(get: { order.hasSuffix(":desc") }, set: { order = order.components(separatedBy: ":")[0] + ($0 ? ":desc" : ":asc") }),
            options: options, pageSize: $pageSize, searchTitle: searchTitle)
    }
}

struct StorebenchTableFrame<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        content().frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: StorebenchTheme.controlRadius))
            .clipShape(RoundedRectangle(cornerRadius: StorebenchTheme.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: StorebenchTheme.controlRadius).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6)))
    }
}
struct StorebenchTableHeader: View {
    let columns: [(String, CGFloat)]
    var resize: ((Int, Double?) -> Void)? = nil
    var fixed: Set<Int> = []
    /// App Store Connect's list headers are capitals; VoiceOver keeps the column name.
    var capitals = false
    var sortable: Set<Int> = []
    var sorted: (column: Int, descending: Bool)? = nil
    var sort: ((Int) -> Void)? = nil
    @Environment(\.tableLiveResize) private var liveResize
    var body: some View {
        HStack(spacing: 0) {
            ForEach(columns.indices, id: \.self) { index in
                title(index)
                    .padding(.horizontal, 12)
                    .frame(width: columns[index].1, height: DataTablePresentation.headerHeight - 1, alignment: .leading)
                    .overlay(alignment: .trailing) {
                        if let resize, !fixed.contains(index) {
                            StorebenchColumnHandle(title: columns[index].0, width: columns[index].1, live: liveResize.map { live in { live(index, $0) } }) { resize(index, $0) }.offset(x: 5)
                        }
                    }
            }
        }.padding(.bottom, 1).background(Color(nsColor: .controlBackgroundColor))
            .overlay(alignment: .bottom) { StorebenchDivider() }
    }
    @ViewBuilder private func title(_ index: Int) -> some View {
        let name = columns[index].0, active = sorted?.column == index
        let label = HStack(spacing: 4) {
            Text(name).textCase(capitals ? .uppercase : nil).font(.sbCaption.bold()).foregroundStyle(StorebenchTheme.color("color-text-tertiary")).lineLimit(1).truncationMode(.tail)
            if active { StorebenchIcon(name: sorted?.descending == true ? "down" : "up", size: 10).foregroundStyle(StorebenchTheme.color("color-text-tertiary")) }
        }
        if let sort, sortable.contains(index) {
            Button { sort(index) } label: { label.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).contentShape(Rectangle()) }
                .buttonStyle(StorebenchPressStyle()).help("Sort by " + name)
                .accessibilityLabel(name).accessibilityValue(active ? (sorted?.descending == true ? "Sorted descending" : "Sorted ascending") : "")
                .accessibilityHint("Sorts the table by this column")
        } else {
            label.help(name).accessibilityElement(children: .ignore).accessibilityLabel(name)
        }
    }
}
struct StorebenchTableCell: View {
    let text: String
    var width: CGFloat? = nil
    var lines = 3
    var title = "Value details"
    var summary: String? = nil
    var body: some View {
        StorebenchTableValue(text: text, title: title, summary: summary).frame(width: width, height: DataTablePresentation.rowHeight - 1, alignment: .leading)
    }
}
struct StorebenchTableValue: View {
    let text, title: String
    var summary: String? = nil
    var lines = 1
    @State private var inspecting = false
    @State private var hovering = false
    var body: some View {
        Button { inspecting = true } label: {
            HStack(spacing: 6) {
                Text(DataTablePresentation.compactText(summary ?? text)).font(.sbCallout).monospacedDigit().foregroundStyle(StorebenchTheme.ink)
                    .lineLimit(lines).truncationMode(.tail).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                StorebenchIcon(name: "info", size: 12).foregroundStyle(StorebenchTheme.muted).opacity(hovering || inspecting ? 1 : 0)
            }.padding(.horizontal, 12).frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
        }.buttonStyle(StorebenchPressStyle()).onHover { hovering = $0 }
            .help("Open " + title.lowercased() + " to read the complete value")
            .accessibilityLabel(title + ": " + text).accessibilityHint("Open the complete value")
            .popover(isPresented: $inspecting) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(title).font(.sbHeadline)
                    ScrollView { Text(text).font(.sbCallout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 220)
                    Button("Done") { inspecting = false }.environment(\.naturalActions, true)
                }.padding(16).frame(width: 360).foregroundStyle(StorebenchTheme.ink).background(StorebenchTheme.surface)
            }
    }
}
/// A row's command column: its commands keep their own fixed track at the row's height.
struct StorebenchTableActions<Content: View>: View {
    let width: Double
    @ViewBuilder let actions: () -> Content
    var body: some View {
        HStack(spacing: StorebenchTheme.space(2)) { actions() }.frame(height: 42).padding(.horizontal, 12).frame(width: width, alignment: .leading)
    }
}

/// A record name that opens the record, in link colour, on its track's leading edge, such as in a table cell.
struct StorebenchRecordLink: View {
    let text: String
    var lines = 3
    var help = ""
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(text).font(.sbCallout).foregroundStyle(StorebenchTheme.color("color-accent-muted")).multilineTextAlignment(.leading).lineLimit(lines).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(StorebenchPressStyle()).help(help.isEmpty ? text : help).accessibilityAddTraits(.isLink)
    }
}

struct StorebenchTableRow<Content: View>: View {
    var index: Int
    var height = DataTablePresentation.rowHeight
    @ViewBuilder let content: () -> Content
    var body: some View {
        HStack(alignment: .center, spacing: 0) { content() }
            .frame(height: height - 1).padding(.bottom, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: NSColor.alternatingContentBackgroundColors[index.isMultiple(of: 2) ? 0 : 1]))
    }
}

/// The divider at a column's trailing edge, as in a Mac table: drag it to resize, double-click or press Escape to reset, or use the arrow keys.
/// While the pointer moves only the table itself follows it; the width is saved once, when the drag ends.
struct StorebenchColumnHandle: View {
    let title: String, width: Double
    /// Shows a width while dragging without saving it; without it each step is saved.
    var live: ((Double) -> Void)? = nil
    let resize: (Double?) -> Void
    @State private var initial: Double?
    @State private var latest: Double?
    @State private var hovering = false
    @FocusState private var focused: Bool
    var body: some View {
        let active = hovering || initial != nil || focused
        Rectangle().fill(active ? StorebenchTheme.accent : .clear)
            .frame(width: active ? 2 : 1, height: 16)
            .frame(width: 9, height: DataTablePresentation.headerHeight - 1)
            .contentShape(Rectangle())
            .onHover { inside in
                guard inside != hovering else { return }
                hovering = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .onDisappear { if hovering { hovering = false; NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global).onChanged { value in
                if initial == nil { initial = width }
                let next = initial! + value.translation.width
                latest = next
                if let live { live(next) } else { resize(next) }
            }.onEnded { _ in
                if live != nil, let latest { resize(latest) }
                initial = nil; latest = nil
            })
            .onTapGesture(count: 2) { resize(nil) }
            .focusable(interactions: .edit).focused($focused).focusEffectDisabled()
            .help("Drag to resize " + title + ". Double-click to reset.")
            .accessibilityLabel("Resize " + title).accessibilityValue("\(Int(width)) points")
            .accessibilityHint("Use left and right arrows; press Escape to reset")
            .accessibilityAdjustableAction { resize(width + ($0 == .increment ? 16 : -16)) }
            .onKeyPress { press in
                guard press.modifiers.isEmpty else { return .ignored }
                switch press.key { case .leftArrow: resize(width - 16); case .rightArrow: resize(width + 16); case .escape: resize(nil); default: return .ignored }
                return .handled
            }
    }
}

/// The width a column shows while its divider is dragged, set by the table that owns the columns.
private struct TableLiveResizeKey: EnvironmentKey { static var defaultValue: ((Int, Double) -> Void)? { nil } }
extension EnvironmentValues {
    var tableLiveResize: ((Int, Double) -> Void)? {
        get { self[TableLiveResizeKey.self] }
        set { self[TableLiveResizeKey.self] = newValue }
    }
}

struct StorebenchResizableTableViewport<Content: View>: View {
    let key: String, minimum: [Double], weights: [Double], height: Double
    var fixed: Set<Int> = []
    @ViewBuilder let content: ([Double], @escaping (Int, Double?) -> Void) -> Content
    @AppStorage("tableColumnWidths") private var saved = "{}"
    /// The column being dragged and its width; saved only when the drag ends, so other tables do not redraw while it moves.
    @State private var dragging: (index: Int, width: Double)?
    private var widths: JSONText { saved.utf8.count <= 16_384 ? (try? JSONText.parse(Data(saved.utf8))) ?? .object([]) : .object([]) }
    var body: some View {
        GeometryReader { geometry in
            let base = DataTablePresentation.widths(available: geometry.size.width, minimum: minimum, weights: weights)
            let preferences = widths[key]
            let columns = base.indices.map { index in
                if let dragging, dragging.index == index { return dragging.width }
                if !fixed.contains(index), case .number(let value)? = preferences?[String(index)] { return DataTablePresentation.resizedWidth(value) }
                return base[index]
            }
            ScrollView([.horizontal, .vertical]) { content(columns, resize).frame(width: columns.reduce(0, +), alignment: .leading) }
                .environment(\.tableLiveResize) { index, width in
                    guard minimum.indices.contains(index), !fixed.contains(index) else { return }
                    var transaction = Transaction(); transaction.disablesAnimations = true
                    withTransaction(transaction) { dragging = (index, DataTablePresentation.resizedWidth(width)) }
                }
        }.frame(height: height).frame(maxWidth: .infinity)
    }
    private func resize(_ index: Int, _ value: Double?) {
        defer { dragging = nil }
        guard minimum.indices.contains(index), !fixed.contains(index) else { return }
        var fields: [(String, JSONText)] = []
        if case .object(let existing)? = widths[key] { fields = existing.filter { $0.0 != String(index) } }
        if let value { fields.append((String(index), .number(DataTablePresentation.resizedWidth(value)))) }
        var tables: [(String, JSONText)] = []
        if case .object(let existing) = widths { tables = existing.filter { $0.0 != key } }
        tables.append((key, .object(fields)))
        saved = String(decoding: JSONText.object(tables).data, as: UTF8.self)
    }
}
