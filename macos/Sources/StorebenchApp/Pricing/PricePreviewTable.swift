import StorebenchCore
import SwiftUI

/// A bounded country preview keeps calculated amounts, Apple matches and unavailable observations distinct.
struct PricePreviewTable: View {
    let rows: [ModelPrice]
    var matching = false
    var unverified = false
    @State private var query = ""
    @State private var sort = "country"
    @State private var descending = false
    @State private var filter = "all"
    @State private var presentation = CollectionPresentation<String>(pageSize: 20)
    private var ordered: [ModelPrice] {
        let filtered = rows.filter { row in
            (filter == "all" || (filter == "matched" ? row.amount != nil : row.amount == nil)) &&
                (query.isEmpty || [WorkspaceSession.countryName(row.territory), row.territory, row.currency, row.problem ?? ""].joined(separator: " ").localizedCaseInsensitiveContains(query))
        }
        return DataTablePresentation.sorted(filtered, descending: descending) { row in
            switch sort {
            case "currency": return .text(row.currency)
            case "amount": return row.amount.flatMap(PricingMath.decimal).map { .money($0, currency: row.currency) } ?? .unknown
            default: return .text(WorkspaceSession.countryName(row.territory))
            }
        }
    }
    var body: some View {
        let ordered = ordered, page = presentation.page(ordered.map(\.id)), current = Array(ordered[page.range])
        StorebenchDataTable {
            StorebenchTableControls(query: $query, sort: $sort, descending: $descending,
                options: [("country", "Country"), ("currency", "Currency"), ("amount", "Price within Currency")],
                pageSize: Binding(get: { presentation.pageSize }, set: { presentation.chooseSize($0) }), searchTitle: "Search Countries or Currencies",
                filter: $filter, filters: [("all", "All Countries or Regions"), ("matched", "Matched Apple Prices"), ("unavailable", "No Matching Price")])
        } content: {
            StorebenchResizableTableViewport(key: "model-country-preview", minimum: [170, 115, 115, 110], weights: [2, 1, 1, 1],
                height: DataTablePresentation.headerHeight + Double(max(1, current.count)) * DataTablePresentation.rowHeight) { widths, resize in
                VStack(spacing: 0) {
                    StorebenchTableHeader(columns: zip(["Country or Region", "Model Price", "Apple Price", "Status"], widths).map { ($0.0, CGFloat($0.1)) },
                        resize: resize, sortable: [0, 2], sorted: sort == "country" ? (0, descending) : sort == "amount" ? (2, descending) : nil,
                        sort: { index in let next = index == 0 ? "country" : "amount"; if sort == next { descending.toggle() } else { sort = next; descending = false } })
                    ForEach(Array(current.enumerated()), id: \.element.id) { index, row in
                        StorebenchTableRow(index: index) {
                            StorebenchTableCell(text: WorkspaceSession.countryName(row.territory) + " · " + row.territory, width: widths[0], title: "Country or Region")
                            StorebenchTableCell(text: row.calculated.map { PricingMath.shown($0, currency: row.currency) + " " + row.currency } ?? "—", width: widths[1], title: "Model Price", summary: row.calculated.map { PricingMath.shown($0, currency: row.currency) + " " + row.currency })
                            StorebenchTableCell(text: row.amount.map { $0 + " " + row.currency } ?? "—", width: widths[2], title: "Apple Price")
                            StorebenchTableCell(text: unverified && row.calculated != nil ? "The amount is calculated. Apple's price points must be checked before this price can be saved." : row.problem ?? row.detail, width: widths[3], title: "Price Calculation", summary: row.amount != nil ? "Matched" : row.calculated == nil ? "No Estimate" : matching ? "Checking…" : unverified ? "Not Checked" : "No Match")
                        }.storebenchControlID("pricing.preview-row." + row.territory)
                    }
                    if current.isEmpty {
                        Text("No Countries Match This View").font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
                            .frame(width: widths.reduce(0, +), height: DataTablePresentation.rowHeight)
                    }
                }
            }
        } footer: {
            StorebenchTablePageFooter(summary: page.summary + " Countries or Regions", page: page.number, count: page.count) { presentation.choosePage($0) }
        }
        .onChange(of: query) { presentation.resetPage() }
        .onChange(of: sort) { presentation.resetPage() }
        .onChange(of: descending) { presentation.resetPage() }
        .onChange(of: filter) { presentation.resetPage() }
        .onChange(of: rows) { _, rows in presentation.reconcile(rows.map(\.id)) }
        .storebenchControlID("pricing.preview-table")
    }
}
