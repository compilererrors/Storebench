import StorebenchCore
import SwiftUI

/// A long change listed one line per item, such as a price schedule's countries, as one table: each item's value now and after,
/// on one row, with search, a filter for changed rows and pages. Pages keep a long list inside the dialog's own scroll, so
/// nothing scrolls inside another scroll.
struct ReviewComparisonTable: View {
    struct Row: Identifiable, Equatable, Sendable {
        let id: String, name: String, now: String, after: String
        var changed: Bool { now != after }
    }
    let rows: [Row]
    @State private var query = ""
    @State private var sort = "item"
    @State private var descending = false
    @State private var filter = "changed"
    @State private var presentation = CollectionPresentation<String>(pageSize: 20)

    /// The rows of a change whose before and after texts list one `Key: value` line per item, or nil for any other change.
    /// An item listed more than once, such as a country with a temporary price, keeps each of its lines in order.
    nonisolated static func rows(before: String, after: String) -> [Row]? {
        func keyed(_ text: String) -> [(String, String)]? {
            let lines = text.split(separator: "\n").map { String($0) }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            var result: [(String, String)] = [], seen: [String: Int] = [:]
            for line in lines {
                guard let range = line.range(of: ": ") else { return nil }
                let key = String(line[..<range.lowerBound]), value = String(line[range.upperBound...])
                guard !key.isEmpty, key.count <= 40 else { return nil }
                seen[key, default: 0] += 1
                result.append((seen[key]! == 1 ? key : "\(key) (\(seen[key]!))", value))
            }
            return result
        }
        guard let now = keyed(before), let next = keyed(after), now.count + next.count >= 6 else { return nil }
        var order: [String] = []
        for (key, _) in now + next where !order.contains(key) { order.append(key) }
        let nowValues = Dictionary(now, uniquingKeysWith: { first, _ in first }), afterValues = Dictionary(next, uniquingKeysWith: { first, _ in first })
        return order.map { key in
            let code = key.prefix(3)
            let name = key.count == 3 && key.allSatisfy({ $0.isUppercase }) ? WorkspaceSession.countryName(String(code)) + " · " + key : key
            return Row(id: key, name: name, now: nowValues[key] ?? "—", after: afterValues[key] ?? "—")
        }
    }

    private var ordered: [Row] {
        let filtered = rows.filter { row in
            (filter == "all" || row.changed) && (query.isEmpty || [row.name, row.now, row.after].joined(separator: " ").localizedCaseInsensitiveContains(query))
        }
        return DataTablePresentation.sorted(filtered, descending: descending) { row in sort == "after" ? .text(row.after) : .text(row.name) }
    }

    var body: some View {
        let ordered = ordered, page = presentation.page(ordered.map(\.id)), current = Array(ordered[page.range])
        let changed = rows.filter(\.changed).count
        StorebenchDataTable {
            StorebenchTableControls(query: $query, sort: $sort, descending: $descending, options: [("item", "Name"), ("after", "After")],
                pageSize: Binding(get: { presentation.pageSize }, set: { presentation.chooseSize($0) }), searchTitle: "Search Changes",
                filter: $filter, filters: [("changed", "Changed (\(changed))"), ("all", "All (\(rows.count))")])
        } content: {
            StorebenchResizableTableViewport(key: "review-comparison", minimum: [170, 160, 160], weights: [1, 1.4, 1.4],
                height: DataTablePresentation.headerHeight + Double(max(1, current.count)) * DataTablePresentation.rowHeight) { widths, resize in
                VStack(spacing: 0) {
                    StorebenchTableHeader(columns: zip(["Name", "Now", "After"], widths).map { ($0.0, CGFloat($0.1)) }, resize: resize)
                    ForEach(Array(current.enumerated()), id: \.element.id) { index, row in
                        StorebenchTableRow(index: index) {
                            StorebenchTableCell(text: row.name, width: widths[0], title: "Name")
                            StorebenchTableCell(text: row.now, width: widths[1], title: "Now")
                            StorebenchTableCell(text: row.after, width: widths[2], title: "After")
                        }
                    }
                    if current.isEmpty {
                        Text(filter == "changed" && query.isEmpty ? "Nothing Changes" : "No Rows Match This View").font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
                            .frame(width: widths.reduce(0, +), height: DataTablePresentation.rowHeight)
                    }
                }
            }
        } footer: {
            StorebenchTablePageFooter(summary: page.summary + " of \(rows.count) · \(changed) changed", page: page.number, count: page.count) { presentation.choosePage($0) }
        }
        .onChange(of: query) { presentation.resetPage() }
        .onChange(of: sort) { presentation.resetPage() }
        .onChange(of: descending) { presentation.resetPage() }
        .onChange(of: filter) { presentation.resetPage() }
        .storebenchControlID("publish.review-comparison")
    }
}
