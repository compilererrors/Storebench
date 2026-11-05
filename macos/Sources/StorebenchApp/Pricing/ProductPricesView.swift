import StorebenchCore
import SwiftUI

/// Apple's current and scheduled prices for one subscription or in-app purchase, read-only, from the schedule Pricing already read.
/// The count compares the countries and regions with a current price against Apple's list, so prices that stopped partway are visible.
/// The table keeps its height while a product is chosen or read, so the form below never moves.
struct ProductPriceScheduleTable: View {
    let kind: PriceProduct.Kind?
    /// Apple's schedule for the product; nil while no product is chosen or Apple's prices were not read.
    let schedule: ProductPriceSchedule?
    /// The number of countries and regions Apple sells in; nil until read.
    let territories: Int?
    let unread: Bool
    private static let height: Double = 240

    var body: some View {
        let view = ProductPricePresentation(kind: kind, schedule: schedule, today: ReportDay.today, activeTerritories: nil, points: nil, amount: "")
        VStack(alignment: .leading, spacing: StorebenchTheme.space(2)) {
            Text(count(view)).font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
            StorebenchTableFrame {
                StorebenchResizableTableViewport(key: "product-price-schedule", minimum: [200, 130, 130, 130], weights: [], height: Self.height) { columns, resize in
                    LazyVStack(alignment: .leading, spacing: 0) {
                        StorebenchTableHeader(columns: zip(["Country or Region", "Price", "Start Date", "End Date"], columns).map { ($0.0, CGFloat($0.1)) }, resize: resize)
                        ForEach(Array(view.rows.enumerated()), id: \.element.key) { index, row in
                            StorebenchTableRow(index: index) {
                                StorebenchTableCell(text: WorkspaceSession.countryName(row.territory), width: columns[0])
                                StorebenchTableCell(text: "\(row.customerPrice ?? "Amount unknown") \(row.currency ?? "")", width: columns[1])
                                StorebenchTableCell(text: row.startDate ?? (row.startKnown ? "No start date" : "Unknown"), width: columns[2])
                                StorebenchTableCell(text: row.endDate ?? (row.endKnown ? "No end date" : "Unknown"), width: columns[3])
                            }
                        }
                        if view.rows.isEmpty {
                            Text(empty).font(.sbCallout).foregroundStyle(StorebenchTheme.muted).padding(StorebenchTheme.space(3)).fixedSize(horizontal: false, vertical: true)
                        }
                    }.frame(width: columns.reduce(0, +), alignment: .leading)
                }.frame(height: Self.height).accessibilityLabel("Apple's current and scheduled prices")
            }
        }
    }

    private func count(_ view: ProductPricePresentation) -> String {
        guard let schedule, !unread else { return "Prices by Country or Region" }
        if schedule.rows.isEmpty { return "No prices at Apple yet" }
        let current = Set(view.rows.filter { view.phases[$0.key] == .current }.map(\.territory)).count
        let scheduled = Set(view.rows.filter { view.phases[$0.key] == .future }.map(\.territory)).count
        let total = territories.map { " of \($0)" } ?? ""
        return "\(current)\(total) countries and regions have a current price" + (scheduled > 0 ? " · \(scheduled) with a scheduled change" : "")
    }
    private var empty: String {
        if kind == nil { return "Choose a product to see Apple's prices." }
        if unread { return "Apple did not return this product's prices. Refresh first." }
        return schedule == nil ? "Reading Apple's prices…" : "Apple has no current or scheduled prices for this product."
    }
}
