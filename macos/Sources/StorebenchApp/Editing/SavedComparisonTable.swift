import StorebenchCore
import SwiftUI

/// Bounded, resizable columns keep the row identity visible while report columns scroll.
struct SavedComparisonTable: View {
    struct Column: Identifiable { let id, title: String; let width: Double }
    let rows: [AsoProgressRow], columns: [Column]
    let cell: (AsoProgressRow, String) -> (value: String, detail: String, explanation: String)
    var numeric: (AsoProgressRow, String) -> Double? = { _, _ in nil }
    let open: (String) -> Void
    @State private var query = ""
    @State private var sort = "date"
    @State private var descending = true
    @State private var paging = CollectionPresentation<String>(pageSize: 10)
    @Environment(\.navigationPresentation) private var history
    @State private var historyOwner: NavigationPresentationContext?
    @State private var restoredQuery: String?
    @State private var restoredSort: String?
    @State private var restoredDescending: Bool?
    private struct Snapshot { let query: String, sort: String, descending: Bool, paging: CollectionPresentation<String> }
    @AppStorage("asoProgressTableColumnWidths") private var savedWidths = "{}"
    /// Widths shown while a divider is dragged; saved when the drag ends.
    @State private var dragging: [String: Double] = [:]
    private var widths: JSONText { (try? JSONText.parse(Data(savedWidths.utf8))) ?? .object([]) }
    private func width(_ column: Column) -> Double {
        if let live = dragging[column.id] { return live }
        if case .number(let value)? = widths[column.id], value.isFinite, (144...640).contains(value) { return value }
        return column.width
    }
    private func resize(_ column: Column, to value: Double?) {
        var fields: [(String, JSONText)] = []
        if case .object(let existing) = widths { fields = existing.filter { $0.0 != column.id } }
        if let value { fields.append((column.id, .number(min(640, max(144, value))))) }
        savedWidths = String(decoding: JSONText.object(fields).data, as: UTF8.self)
    }
    private var ordered: [AsoProgressRow] {
        let matches = rows.filter { query.isEmpty || ($0.version + " " + $0.date + " " + $0.changes.map { AsoComparison.fieldName($0.field) }.joined(separator: " ")).localizedCaseInsensitiveContains(query) }
        return DataTablePresentation.sorted(matches, descending: descending) { row in
            if sort == "date" { return row.dateKnown ? .text(row.date) : .unknown }
            if sort == "version" { return .text(row.version) }
            if sort == "changed" { return .text(cell(row, "changed").value) }
            return numeric(row, sort).map { .number($0) } ?? .unknown
        }
    }
    var body: some View {
        let sorted = ordered, page = paging.page(sorted.map(\.id)), shown = Array(sorted[page.range])
        VStack(alignment: .leading, spacing: 12) {
            StorebenchTableControls(query: $query, sort: $sort, descending: $descending,
                options: [("date", "Version date")] + columns.map { ($0.id, $0.title) },
                pageSize: Binding(get: { paging.pageSize }, set: { paging.chooseSize($0) }), searchTitle: "Find versions or changed fields")
            StorebenchHeader {
                Text(page.summary + " comparisons · Drag column handles to resize. Double click to reset.").font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
            } actions: {
                Button("Reset Column Widths") { savedWidths = "{}" }.environment(\.naturalActions, true)
            }
            if let first = columns.first {
                StorebenchTableFrame {
                    GeometryReader { geometry in
                        HStack(alignment: .top, spacing: 0) {
                            column(first, rows: shown, maximumWidth: max(144, geometry.size.width - 144))
                            ScrollView(.horizontal) {
                                HStack(alignment: .top, spacing: 0) { ForEach(Array(columns.dropFirst())) { column($0, rows: shown) } }
                            }.frame(maxWidth: .infinity)
                        }.frame(maxWidth: .infinity).accessibilityLabel("Version comparison table")
                    }.frame(height: DataTablePresentation.headerHeight + Double(shown.count) * DataTablePresentation.rowHeight)
                }
            }
            if page.count > 1 { StorebenchPagination(page: page.number, count: page.count) { paging.choosePage($0) } }
        }.onAppear { restore() }.onDisappear { save() }
            .onChange(of: history?.entry) { save(); restore() }
            .onChange(of: query) { if restoredQuery == query { restoredQuery = nil } else { paging.resetPage() }; save() }
            .onChange(of: sort) { if restoredSort == sort { restoredSort = nil } else { paging.resetPage() }; save() }
            .onChange(of: descending) { if restoredDescending == descending { restoredDescending = nil } else { paging.resetPage() }; save() }
            .onChange(of: paging) { save() }
    }
    private func restore() {
        historyOwner = history
        guard let history, let snapshot = history.store.collection("comparison-table:" + history.scope, entry: history.entry, as: Snapshot.self) else { return }
        restoredQuery = query == snapshot.query ? nil : snapshot.query
        restoredSort = sort == snapshot.sort ? nil : snapshot.sort
        restoredDescending = descending == snapshot.descending ? nil : snapshot.descending
        query = snapshot.query; sort = snapshot.sort; descending = snapshot.descending; paging = snapshot.paging
    }
    private func save() {
        guard let historyOwner else { return }
        historyOwner.store.saveCollection(Snapshot(query: query, sort: sort, descending: descending, paging: paging), key: "comparison-table:" + historyOwner.scope, entry: historyOwner.entry)
    }
    private func column(_ column: Column, rows: [AsoProgressRow], maximumWidth: Double = 640) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 4) {
                Text(column.title).font(.sbCaption.bold()).foregroundStyle(StorebenchTheme.color("color-text-tertiary")).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading).help(column.title).accessibilityLabel(column.title)
                StorebenchColumnHandle(title: column.title, width: width(column), live: { dragging[column.id] = min(640, max(144, $0)) }) { value in
                    dragging.removeValue(forKey: column.id); resize(column, to: value)
                }.offset(x: 12)
            }.padding(.horizontal, 12).frame(height: DataTablePresentation.headerHeight).background(StorebenchTheme.color("color-surface-sunken"))
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                let shown = cell(row, column.id)
                Group {
                    if column.id == "version" {
                        Button { open(row.id) } label: {
                            Text(DataTablePresentation.compactText(shown.value + " · " + shown.detail)).font(.sbCallout)
                                .lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
                        }.buttonStyle(StorebenchPressStyle()).foregroundStyle(StorebenchTheme.color("color-accent-muted"))
                            .help(shown.explanation + "\nOpen the saved listing change")
                            .accessibilityAddTraits(.isLink).accessibilityLabel(shown.explanation)
                    } else {
                        StorebenchTableValue(text: shown.value + "\n" + shown.detail + "\n\n" + shown.explanation, title: column.title + " · " + row.version, summary: shown.value + " · " + shown.detail)
                    }
                }.frame(height: DataTablePresentation.rowHeight - 1).padding(.bottom, 1)
                    .background(index.isMultiple(of: 2) ? StorebenchTheme.surface : StorebenchTheme.color("color-surface-subtle"))
                    .overlay(alignment: .bottom) { StorebenchDivider() }
            }
        }.frame(width: min(maximumWidth, max(144, width(column)))).overlay(alignment: .trailing) { Divider() }
    }
}
