import AppKit
import StorebenchCore
import SwiftUI
import UniformTypeIdentifiers

struct FinancialActivityView: View {
    let periods: [FinancialPresentation.Period], money: ReportMoney.Context?, moneyState: String
    var compareSales: ((ReportNavigation.SalesRequest) -> Void)? = nil
    @Environment(\.recoveryNavigation) private var navigation
    @State private var basis = "consolidated"
    @State private var fiscal = "all"
    @State private var query = ""
    @State private var territoryOrder = "default"
    @State private var currencyOrder = "default"
    @State private var page = 1
    @State private var currencyPage = 1
    @State private var pageSize = 20
    @State private var currencyPageSize = 10
    @State private var currencyQuery = ""
    @State private var exportStatus = ""
    @State private var restored: Choices?
    private struct Choices: Equatable { var basis, fiscal, query, territoryOrder, currencyOrder, currencyQuery: String; var page, currencyPage, pageSize, currencyPageSize: Int }
    private var choices: Choices { Choices(basis: basis, fiscal: fiscal, query: query, territoryOrder: territoryOrder, currencyOrder: currencyOrder, currencyQuery: currencyQuery, page: page, currencyPage: currencyPage, pageSize: pageSize, currencyPageSize: currencyPageSize) }
    /// Choices that Back restored keep their pages; any later change to a filter starts from its first page.
    private func reset(_ apply: () -> Void) { if restored != nil, restored == choices { return }; restored = nil; apply() }
    private static let bases = [("consolidated", "All countries · summary"), ("detailed", "All countries · detailed"), ("regional", "Individual regions")]
    private var availableBases: [(String, String)] { Self.bases.filter { candidate in periods.contains { $0.basis == candidate.0 } } }
    private var selectedBasis: String { availableBases.contains { $0.0 == basis } ? basis : availableBases.first?.0 ?? "consolidated" }
    private var dates: [FinancialPresentation.Period] {
        ReportNavigation.financialDates(periods, basis: selectedBasis)
    }
    private var selectedFiscal: String { dates.contains { $0.dateKey == fiscal } ? fiscal : "all" }
    private var selected: [FinancialPresentation.Period] { periods.filter { $0.basis == selectedBasis && (selectedFiscal == "all" || $0.dateKey == selectedFiscal) } }
    private var context: ReportMoney.Context { money ?? ReportMoney.Context(currency: "") }
    private func label(_ key: String) -> String {
        switch key { case "territory": "Territory"; case "paid": "Paid units"; case "returned": "Returns"; case "net": "Net units"; case "proceeds": "Reported proceeds"; case "estimate": "Estimate"; case "currency": "Currency"; case "amount": "Reported amount"; default: key }
    }
    private func territories(_ summary: FinancialPresentation.Summary) -> [FinancialPresentation.Fact] {
        let order = territoryOrder.components(separatedBy: ":")
        return FinancialPresentation.territories(summary, context: context, query: query, sort: FinancialPresentation.Sort(rawValue: order[0]), descending: order.last == "desc")
    }
    private func currencies(_ summary: FinancialPresentation.Summary) -> [ReportMoney.Amount] {
        let order = currencyOrder.components(separatedBy: ":")
        return FinancialPresentation.currencies(summary, sort: FinancialPresentation.CurrencySort(rawValue: order[0]), descending: order.last == "desc")
    }
    var body: some View {
        if let summary = try? FinancialPresentation.summary(selected) {
            VStack(alignment: .leading, spacing: 20) {
                Card(title: "Financial summary", subtitle: Self.summarySubtitle) {
                    StorebenchActionGroup { navigationActions }
                    StorebenchMetricGrid(maximumColumns: 2, minimumWidth: 230) {
                    StorebenchPicker("Financial dataset", selection: Binding(get: { selectedBasis }, set: { basis = $0; fiscal = "all" })) { selectionOptions(availableBases) { SelectionOption($0.1, value: $0.0) } }
                    StorebenchPicker("Fiscal period", selection: Binding(get: { selectedFiscal }, set: { fiscal = $0 })) {
                        SelectionOption("All saved fiscal periods", value: "all")
                        selectionOptions(dates) { SelectionOption("\($0.beginDate) – \($0.endDate)", value: $0.dateKey) }
                    }
                    }
                    Text("Dates follow the report's fiscal calendar and can differ from calendar months.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
                }
                StorebenchMetricGrid { metrics(summary) }
                coverage(summary)
                currencyCard(summary)
                territoryCard(summary)
                OriginalReportChart(source: .financial(selected))
            }
            .historyValue("finance-activity", Binding(get: { choices }, set: { value in
                restored = value; basis = value.basis; fiscal = value.fiscal; query = value.query; territoryOrder = value.territoryOrder; currencyOrder = value.currencyOrder
                currencyQuery = value.currencyQuery; page = value.page; currencyPage = value.currencyPage; pageSize = value.pageSize; currencyPageSize = value.currencyPageSize
            }))
            .onChange(of: basis) { reset { page = 1; currencyPage = 1; exportStatus = "" } }
            .onChange(of: fiscal) { reset { page = 1; currencyPage = 1; exportStatus = "" } }
            .onChange(of: query) { reset { page = 1 } }
            .onChange(of: territoryOrder) { reset { page = 1 } }
            .onChange(of: currencyOrder) { reset { currencyPage = 1 } }
            .onChange(of: currencyQuery) { reset { currencyPage = 1 } }
            .onChange(of: pageSize) { reset { page = 1 } }
            .onChange(of: currencyPageSize) { reset { currencyPage = 1 } }
        } else { Card(title: "Financial summary could not be prepared", subtitle: "Read and validate saved fiscal periods before continuing.") { EmptyView() } }
    }
    static let summarySubtitle = "Direct app transactions by Apple fiscal period. Summary, detailed and regional files are alternative datasets."
    static func placeholder() -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Card(title: "Financial summary", subtitle: summarySubtitle) {
                StorebenchActionGroup { ReportDownloadButton(area: .finance) }
                StorebenchMetricGrid(maximumColumns: 2, minimumWidth: 230) {
                    StorebenchPicker("Financial dataset", selection: .constant("")) { SelectionOption("All countries · summary", value: "") }
                    StorebenchPicker("Fiscal period", selection: .constant("")) { SelectionOption("All saved fiscal periods", value: "") }
                }
                Text("Placeholder for the note on fiscal calendar dates.").font(.sbCallout)
            }
            StorebenchMetricGrid { ForEach(0..<4, id: \.self) { _ in Fact(title: "Saved total", value: "0") } }
            StorebenchPlaceholderCard(rows: 6)
        }.storebenchPlaceholder()
    }
    @ViewBuilder private var navigationActions: some View {
        ReportDownloadButton(area: .finance)
        if compareSales != nil && navigation.scope != nil {
            Button("Compare with Sales") {
                guard let scope = navigation.scope, let range = try? ReportNavigation.financialSalesRange(periods, basis: selectedBasis, fiscal: selectedFiscal) else {
                    if let scope = navigation.scope, selectedFiscal == "all" { compareSales?(.init(scope: scope, range: nil)) }; return
                }
                compareSales?(.init(scope: scope, range: range))
            }
        }
    }
    private func metrics(_ summary: FinancialPresentation.Summary) -> some View {
        Group {
            Fact(title: "Paid purchase units", value: summary.paid.formatted(.number.locale(Locale(identifier: "en_US"))))
            Fact(title: "Returned paid units", value: summary.returned.formatted(.number.locale(Locale(identifier: "en_US"))), info: "Paid units returned in the selected financial reports. A return can concern a purchase from an earlier period.")
            Fact(title: "Net paid units", value: summary.net.formatted(.number.locale(Locale(identifier: "en_US"))), info: "Paid units minus returns in the selected financial reports.")
            Fact(title: money.map { "Estimated proceeds · \($0.currency)" } ?? "Estimated proceeds", value: money.map { ReportMoney.label(ReportMoney.convert(summary.proceeds, context: $0).amount, currency: $0.currency) } ?? "—")
        }
    }
    private func coverage(_ summary: FinancialPresentation.Summary) -> some View {
        Card(title: "Coverage and reference conversion", subtitle: "\(selected.count) reports in \(Set(selected.map(\.dateKey)).count) fiscal periods · \(summary.rows.count) reported territories.") {
            Text("\(summary.other.formatted(.number.locale(Locale(identifier: "en_US")))) other net units are reported separately. Returns can concern earlier purchases.").font(.sbCallout)
            Text(selectedBasis == "regional" ? "\(Set(selected.map(\.region)).count) imported regions only. Missing regions are not zero proceeds." : "Coverage is limited to the available rows in the imported reports.").font(.sbCallout)
            if let money {
                let estimate = ReportMoney.convert(summary.proceeds, context: money)
                Text(estimate.complete ? "Dated reference conversion. Matching currencies and explicitly reported zeros need no cross-currency rate." : "Partial estimate. Missing reference amounts or rates: \(estimate.missing.joined(separator: ", ")).").font(.sbCallout)
                if !estimate.dates.isEmpty { Text("Reference dates: \(estimate.dates.joined(separator: ", ")).").font(.sbCallout) }
                if !money.staleCurrencies.isEmpty { Text("Older cached reference rates: \(money.staleCurrencies.joined(separator: ", ")).").font(.sbCallout) }
            } else { Text(moneyState == "loading" ? "Reading the display currency and dated reference rates…" : "Display currency or reference rates could not be read. Original amounts remain available.").font(.sbCallout) }
            Text("Reported proceeds are Extended Partner Share amounts, including returns. Bank payouts can include adjustments, taxes and settlement conversions. Sales uses different timing, so a difference is not automatically an error. In-app products and subscriptions are not attributed by name.").font(.sbCallout).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func currencyCard(_ summary: FinancialPresentation.Summary) -> some View {
        let rows = currencies(summary).filter { currencyQuery.isEmpty || ($0.currency + " " + $0.amount).localizedCaseInsensitiveContains(currencyQuery) }, pages = max(1, (rows.count + currencyPageSize - 1) / currencyPageSize), current = min(currencyPage, pages)
        return Card(title: "Reported proceeds by currency", subtitle: "Original report amounts. Change the estimate currency in Display settings.") {
            StorebenchReportTableControls(query: $currencyQuery, order: $currencyOrder, pageSize: $currencyPageSize,
                options: [("default", "Reported order")] + FinancialPresentation.CurrencySort.allCases.map { ($0.rawValue, label($0.rawValue)) }, searchTitle: "Find currencies")
            StorebenchTableFrame {
                StorebenchResizableTableViewport(key: "financial-currencies", minimum: [150, 250], weights: [1, 2], height: DataTablePresentation.headerHeight + Double(min(currencyPageSize, max(0, rows.count - (current - 1) * currencyPageSize))) * DataTablePresentation.rowHeight) { columns, resize in
                        VStack(alignment: .leading, spacing: 0) {
                            StorebenchTableHeader(columns: [("Currency", columns[0]), ("Reported proceeds", columns[1])], resize: resize)
                            ForEach(Array(rows.dropFirst((current - 1) * currencyPageSize).prefix(currencyPageSize).enumerated()), id: \.element.currency) { index, row in
                                StorebenchTableRow(index: index) {
                                    StorebenchTableCell(text: row.currency, width: columns[0], title: "Currency")
                                    StorebenchTableCell(text: ReportMoney.label(row.amount, currency: row.currency), width: columns[1], title: "Reported proceeds")
                                }
                            }
                        }.frame(width: columns.reduce(0, +))
                }
            }
            pagination(current, pages: pages, value: $currencyPage, label: "Currency")
        }
    }
    private func territoryCard(_ summary: FinancialPresentation.Summary) -> some View {
        let rows = territories(summary), pages = max(1, (rows.count + pageSize - 1) / pageSize), current = min(page, pages)
        return Card(title: "Financial territories", subtitle: "\(rows.count) storefronts match this search. Summary totals and analysis exports cover the full selected fiscal period.") {
            StorebenchReportTableControls(query: $query, order: $territoryOrder, pageSize: $pageSize,
                options: [("default", "Paid units · reported order")] + FinancialPresentation.Sort.allCases.map { ($0.rawValue, label($0.rawValue)) }, searchTitle: "Find financial territories")
            if rows.isEmpty { Text("No territory matches this search.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted) }
            StorebenchTableFrame {
                StorebenchResizableTableViewport(key: "financial-territories", minimum: [198, 108, 108, 108, 198, 180], weights: [], height: DataTablePresentation.headerHeight + Double(min(pageSize, max(0, rows.count - (current - 1) * pageSize))) * ComponentLayout.tableRowHeight(lines: 3)) { columns, resize in
                    VStack(alignment: .leading, spacing: 0) {
                        StorebenchTableHeader(columns: zip(["Territory", "Paid units", "Returns", "Net units", "Reported proceeds", money.map { "Estimate · \($0.currency)" } ?? "Estimate"], columns).map { ($0.0, CGFloat($0.1)) }, resize: resize)
                        ForEach(Array(rows.dropFirst((current - 1) * pageSize).prefix(pageSize).enumerated()), id: \.element.id) { index, row in
                            let estimate = ReportMoney.convert(row.proceeds, context: context)
                            StorebenchTableRow(index: index) {
                                track(Territories.name(row.territory), width: columns[0], title: "Territory")
                                track(row.paid.formatted(.number.locale(Locale(identifier: "en_US"))), width: columns[1], title: "Paid units")
                                track(row.returned.formatted(.number.locale(Locale(identifier: "en_US"))), width: columns[2], title: "Returns")
                                track((row.paid - row.returned).formatted(.number.locale(Locale(identifier: "en_US"))), width: columns[3], title: "Net units")
                                track(row.proceeds.map { ReportMoney.label($0.amount, currency: $0.currency) }.joined(separator: " · "), width: columns[4], title: "Reported proceeds")
                                track(money.map { ReportMoney.label(estimate.amount, currency: $0.currency) + (estimate.complete ? "" : " · partial") } ?? "—", width: columns[5], title: "Reference estimate")
                            }
                        }
                    }.frame(width: columns.reduce(0, +), alignment: .leading)
                }
            }
            pagination(current, pages: pages, value: $page, label: "Territory")
            if money != nil { StorebenchFormFooter { Button("Export Analysis CSV") { export() } } }
            StorebenchTextSlot(text: exportStatus.isEmpty ? "Exports every selected territory with original amounts, estimate completeness and rate dates." : exportStatus, height: 48, font: .sbCallout, color: nil, live: true)
        }
    }
    private func track(_ text: String, width: CGFloat, title: String) -> some View {
        StorebenchTableCell(text: text, width: width, title: title)
    }
    private func pagination(_ current: Int, pages: Int, value: Binding<Int>, label: String) -> some View {
        StorebenchPagination(page: current, count: pages) { value.wrappedValue = $0 }.accessibilityLabel(label + " pages")
    }
    private func export() {
        guard let money else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "financial-analysis.csv"; panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try FinancialPresentation.writeAnalysisCSV(selected, context: money, to: url); exportStatus = "Financial analysis exported for every selected territory." }
        catch { exportStatus = "The financial analysis could not be exported. Check the destination and try again." }
    }
}
