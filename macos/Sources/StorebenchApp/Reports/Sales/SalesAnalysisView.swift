import AppKit
import StorebenchCore
import SwiftUI
import UniformTypeIdentifiers

struct SalesAnalysisView: View {
    let reports: [SalesPresentation.Period], range: SalesPresentation.Range, money: ReportMoney.Context?, moneyState: String
    let openSection: ((String) -> Void)?
    let readAt: Date, openReports: (() -> Void)?
    var filters: AnyView? = nil
    var actions: AnyView? = nil
    @State private var query = ""
    @State private var order = "default"
    @State private var measure = "auto"
    @State private var page = 1
    @State private var pageSize = 20
    @State private var minimum = "30"
    @State private var countryMinimum = "20"
    @State private var share = "40"
    @State private var exportStatus = ""
    @State private var saving = false
    private struct Choices: Equatable { var query, order, measure, minimum, countryMinimum, share: String; var page, pageSize: Int }
    private var criteria: SalesPresentation.Criteria? { try? .init(purchases: minimum, country: countryMinimum, share: share) }
    private var context: ReportMoney.Context { money ?? .init(currency: "USD") }
    private struct Input: Equatable, Sendable { let reports: [SalesPresentation.Period], range: SalesPresentation.Range, criteria: SalesPresentation.Criteria }
    private struct Prepared: Sendable { let input: Input, selected: SalesPresentation.Selection?, previous: SalesPresentation.Selection? }
    @State private var prepared: Prepared?
    @Environment(\.navigationPresentation) private var presentation
    /// The last figures prepared in this window, reused at once when the saved reports and choices are the same.
    private var preparedKey: String { "sales-analysis/prepared" + (presentation?.scope ?? "") }
    private var input: Input { Input(reports: reports, range: range, criteria: criteria ?? .defaults) }
    private var previous: SalesPresentation.Selection? { prepared?.input == input ? prepared?.previous : nil }

    var body: some View {
        content.task(id: input) {
            let expected = input
            if let saved = presentation?.rememberedRead(preparedKey, as: Prepared.self), saved.input == expected { prepared = saved; return }
            let worker = Task.detached(priority: .userInitiated) {
                guard !Task.isCancelled else { return nil as Prepared? }
                let selected = try? SalesPresentation.select(expected.reports, range: expected.range, criteria: expected.criteria)
                let previous = expected.range.previous.flatMap { try? SalesPresentation.select(expected.reports, range: $0) }
                return Prepared(input: expected, selected: selected, previous: previous)
            }
            let next = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, input == expected else { return }; prepared = next
            if let next { presentation?.rememberRead(next, preparedKey) }
        }
        .historyValue("sales-analysis", Binding(get: { Choices(query: query, order: order, measure: measure, minimum: minimum, countryMinimum: countryMinimum, share: share, page: page, pageSize: pageSize) }, set: { value in
            query = value.query; order = value.order; measure = value.measure; minimum = value.minimum; countryMinimum = value.countryMinimum; share = value.share; page = value.page; pageSize = value.pageSize
        }))
    }
    @ViewBuilder private var content: some View {
        if let prepared, prepared.input.reports == reports, let selected = prepared.selected {
            VStack(alignment: .leading, spacing: 20) {
                StorebenchFeedback(text: prepared.input == input ? "" : "Updating analysis… Figures below still use the previous selection.", height: 26)
                if selected.analysis.coverage != nil {
                    summary(selected)
                    countryCard(selected)
                    trend(selected.analysis)
                    moneyCard(selected)
                    OriginalReportChart(source: .sales(selected.analysis.coverage?.periods ?? []))
                    comparison(selected)
                    coverage(selected)
                    suggestions(selected.analysis)
                } else { Card(title: "No complete reports in this range", subtitle: "Aggregate reports cannot be divided into daily figures. Choose a whole saved period or download missing days.", actions: actions) { filters } }
            }
            .onChange(of: query) { page = 1 }
            .onChange(of: order) { page = 1 }
            .onChange(of: range) { page = 1; exportStatus = "" }
            .trackUnsavedChanges(false, busy: saving)
        } else if prepared?.input != input {
            Self.placeholder(filters: filters, actions: actions)
        } else { Card(title: "Sales summary", subtitle: "Saved sales figures could not be analyzed. Choose another range or read the original reports again.", actions: actions) { filters } }
    }
    static let summarySubtitle = "App purchases in the selected saved reports, before refunds. In-app products are shown separately."
    static func placeholder(filters: AnyView?, actions: AnyView?) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            StorebenchFeedback(text: "", height: 26)
            Card(title: "Sales summary", subtitle: summarySubtitle, actions: actions) {
                filters
                StorebenchLoadState(state: .loading("Preparing the selected saved reports…")) { EmptyView() } placeholder: {
                    StorebenchCardSection(title: "Saved purchase totals", description: "Placeholder dates through placeholder dates · reporting days covered. Missing days remain unknown.") {
                        StorebenchMetricGrid { ForEach(0..<4, id: \.self) { _ in Fact(title: "Saved total", value: "0") } }
                    }
                }
            }
            StorebenchPlaceholderCard(rows: 8)
        }
    }
    private func coverage(_ selected: SalesPresentation.Selection) -> some View {
        Card(title: "Reporting coverage", subtitle: "\(selected.coveredDays) of \(selected.requestedDays) days covered · \(selected.analysis.coverage?.periods.count ?? 0) saved periods · Pacific reporting dates", help: "report-availability") {
            if selected.complete { Text("The requested range has complete saved coverage.").foregroundStyle(StorebenchTheme.muted) }
            else {
                Text("Missing days remain unknown. \(selected.crossingPeriods) reports cross a range boundary and are excluded.").foregroundStyle(StorebenchTheme.muted)
                SalesAvailabilityView(days: selected.missingDays, readAt: readAt, covered: selected.coveredDays, requested: selected.requestedDays, openReports: openReports)
                if !selected.missingDays.isEmpty {
                    DisclosureGroup("Missing reporting days\(selected.missingDays.count > 400 ? " · first 401" : "")") {
                        StorebenchTextSlot(text: selected.missingDays.joined(separator: ", "), height: 100, font: nil, color: nil)
                    }
                }
            }
        }
    }
    private func summary(_ selected: SalesPresentation.Selection) -> some View {
        Card(title: "Sales summary", subtitle: Self.summarySubtitle, actions: actions) {
            filters
            StorebenchCardSection(title: "Saved purchase totals", description: "\(selected.range.beginDate) through \(selected.range.endDate) · \(selected.coveredDays) of \(selected.requestedDays) reporting days covered. Missing days remain unknown.") {
                StorebenchMetricGrid { totals(selected.analysis) }
            }
        }
    }
    @ViewBuilder private func totals(_ a: SalesPresentation.Analysis) -> some View {
        Fact(title: "Paid app purchases", value: String(a.paid)); Fact(title: "Refunded paid units", value: count(a.refunds), info: "Units Apple reports as refunded in the selected Sales reports. A refund can concern an earlier purchase."); Fact(title: "Free app downloads", value: count(a.free)); Fact(title: "Countries with purchases", value: String(a.rows.filter { $0.paid > 0 }.count))
    }
    private func trend(_ analysis: SalesPresentation.Analysis) -> some View {
        let chart = ReportCharts.sales(analysis, measure: SalesPresentation.Measure(rawValue: measure))
        return Card(title: "Sales over time", subtitle: "One point per saved report period. Unknown detail values break the line and remain available for inspection.") {
            StorebenchPicker("Measure", selection: $measure) { SelectionOption("Automatic", value: "auto"); selectionOptions(ReportCharts.salesMeasures) { SelectionOption(ReportCharts.salesLabel($0), value: $0.rawValue) } }.storebenchFormColumn()
            Text("Free downloads, refunds and in-app purchases need Apple’s original report rows.").font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
            Text("\(chart.totalLabel): \(chart.total.map(AsoProgress.count) ?? "—")").font(.sbHeadline).frame(minHeight: 36, alignment: .topLeading)
            SavedReportChart(series: chart.series, note: chart.note, emptyText: "No saved reports in this range. Missing reports are not zero sales.")
            Text(analysis.comparable ? "The latest two periods are adjacent and have equal length." : "Trend suggestions require adjacent reports of equal length.").font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
        }
    }

    private func moneyCard(_ selected: SalesPresentation.Selection) -> some View {
        let a = selected.analysis, total = ReportMoney.convert(a.proceeds, context: context)
        let complete = money != nil && selected.complete && a.moneyComplete && a.productsComplete && total.complete
        return Card(title: "In-app purchases and proceeds", subtitle: "Verified associated product IDs, including subscriptions. Conversion is a reference estimate, not a confirmed payout.") {
            StorebenchMetricGrid(maximumColumns: 2) {
                Fact(title: "In-app purchases", value: count(a.inAppPurchases)); Fact(title: "In-app refunded units", value: count(a.inAppRefunds), info: "In-app purchase units Apple reports as refunded. A refund can concern an earlier purchase or renewal.")
            }
            if !a.productsComplete { Text("Product coverage needs verification. Download the reports again after checking app API access and the product catalog.").foregroundStyle(StorebenchTheme.muted) }
            Fact(title: "Estimated proceeds · \(context.currency)\(complete ? "" : " · Partial")", value: money == nil ? "—" : ReportMoney.label(total.amount, currency: context.currency), info: "Reported proceeds converted to your display currency with dated reference rates. An estimate, not a payout.")
            Text(SalesPresentation.proceedsText(a.proceeds, complete: selected.moneyComplete)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text(moneyState.isEmpty ? "Rate dates: \(total.dates.isEmpty ? "same-currency amounts or no converted rates" : total.dates.joined(separator: ", "))" : moneyState).font(.sbCaption).foregroundStyle(StorebenchTheme.muted).frame(minHeight: 32, alignment: .topLeading)
        }
    }
    private func comparison(_ selected: SalesPresentation.Selection) -> some View {
        Card(title: "Previous period", subtitle: previous.map { "\($0.range.beginDate) through \($0.range.endDate). Percentages require complete coverage in both ranges." } ?? "A preceding date range is unavailable.") {
            if let previous {
                comparisonRow("Paid purchases", String(selected.analysis.paid), String(previous.analysis.paid), selected.complete && previous.complete)
                comparisonRow("Refunded paid units", selected.analysis.refunds.map(String.init), previous.analysis.refunds.map(String.init), selected.complete && previous.complete)
                comparisonRow("Free downloads", selected.analysis.free.map(String.init), previous.analysis.free.map(String.init), selected.complete && previous.complete)
                let currentMoney = ReportMoney.convert(selected.analysis.proceeds, context: context), beforeMoney = ReportMoney.convert(previous.analysis.proceeds, context: context)
                comparisonRow("Estimated proceeds · \(context.currency)", money == nil ? nil : currentMoney.amount, money == nil ? nil : beforeMoney.amount,
                              money != nil && selected.complete && previous.complete && selected.analysis.moneyComplete && previous.analysis.moneyComplete && selected.analysis.productsComplete && previous.analysis.productsComplete && currentMoney.complete && beforeMoney.complete)
            }
        }
    }
    private func comparisonRow(_ label: String, _ current: String?, _ previous: String?, _ complete: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(label).font(.sbHeadline); Text("Current: \(current ?? "—") · Previous: \(previous ?? "—")").textSelection(.enabled); Text(complete ? SalesPresentation.change(current, previous: previous) : "Unavailable · incomplete reporting coverage or details").font(.sbCaption).foregroundStyle(StorebenchTheme.muted) }.padding(.vertical, 4)
    }
    private func suggestions(_ analysis: SalesPresentation.Analysis) -> some View {
        Card(title: "Sales observations", subtitle: "Informational criteria do not establish a cause or trigger price changes or publishing.", help: "sales") {
            StorebenchMetricGrid(maximumColumns: 3, minimumWidth: 190) { StorebenchTextField("Minimum purchases", text: $minimum); StorebenchTextField("Minimum country purchases", text: $countryMinimum); StorebenchTextField("Minimum share %", text: $share) }
            if criteria == nil { Text(SalesPresentationFailure.criteria.message).foregroundStyle(StorebenchTheme.muted) }
            else {
                ForEach(analysis.insights) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.title).font(.sbHeadline); Text(item.evidence).fixedSize(horizontal: false, vertical: true); Text(item.suggestion).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
                        if let section = item.section, let openSection { Button(section == "pricing" ? "Open Pricing" : "Open Localizations") { openSection(section) } }
                    }.padding(.vertical, 6)
                }
                if analysis.insights.isEmpty { Text("No observations meet these criteria.").foregroundStyle(StorebenchTheme.muted) }
            }
        }
    }
    private func countryCard(_ selected: SalesPresentation.Selection) -> some View {
        let fields = order.components(separatedBy: ":"), rows = SalesPresentation.countries(selected.analysis, context: context, query: query, sort: SalesPresentation.Sort(rawValue: fields[0]), descending: fields.last == "desc")
        let pages = max(1, (rows.count + pageSize - 1) / pageSize), current = min(page, pages)
        return Card(title: "Country sales", subtitle: "Search and ordering affect this list. The summary and CSV retain all selected countries.") {
            StorebenchReportTableControls(query: $query, order: $order, pageSize: $pageSize,
                options: [("default", "Purchase leaders")] + SalesPresentation.Sort.allCases.map { ($0.rawValue, $0.rawValue.capitalized) }, searchTitle: "Find country sales")
                .onChange(of: pageSize) { page = 1 }
            StorebenchTableFrame {
                StorebenchResizableTableViewport(key: "country-sales", minimum: [180, 120, 90, 120, 195, 195], weights: [], height: DataTablePresentation.headerHeight + Double(min(pageSize, max(0, rows.count - (current - 1) * pageSize))) * ComponentLayout.tableRowHeight(lines: 3)) { columns, resize in
                    VStack(alignment: .leading, spacing: 0) {
                        StorebenchTableHeader(columns: zip(["Country", "Paid purchases", "Share", "Refunded units", "Reported proceeds", "Estimate · \(context.currency)"], columns).map { ($0.0, CGFloat($0.1)) }, resize: resize)
                        ForEach(Array(rows.dropFirst((current - 1) * pageSize).prefix(pageSize).enumerated()), id: \.element.id) { index, row in
                            let conversion = ReportMoney.convert(row.proceeds, context: context), complete = money != nil && conversion.complete && selected.complete && selected.analysis.moneyComplete && selected.analysis.productsComplete
                            StorebenchTableRow(index: index) {
                                StorebenchTableCell(text: "\(row.name)\n\(row.code)", width: columns[0], title: "Country")
                                StorebenchTableCell(text: String(row.paid), width: columns[1], title: "Paid purchases")
                                StorebenchTableCell(text: SalesPresentation.shareLabel(row.paid, total: selected.analysis.paid), width: columns[2], title: "Share")
                                StorebenchTableCell(text: selected.analysis.refunds == nil ? "—" : String(row.refunds), width: columns[3], title: "Refunded units")
                                StorebenchTableCell(text: SalesPresentation.proceedsText(row.proceeds, complete: selected.moneyComplete), width: columns[4], title: "Reported proceeds", summary: row.proceeds.isEmpty ? "—" : nil)
                                StorebenchTableCell(text: SalesPresentation.estimateText(conversion, context: context, complete: complete, available: money != nil), width: columns[5], title: "Reference estimate")
                            }
                        }
                    }.frame(width: columns.reduce(0, +), alignment: .leading)
                }
            }
            if rows.isEmpty { Text("No countries match your search.").foregroundStyle(StorebenchTheme.muted) }
            StorebenchPagination(page: current, count: pages) { page = $0 }
            if criteria != nil && money != nil { StorebenchFormFooter { Button("Export Analysis CSV…") { if !saving, prepared?.input == input { export(selected) } }.storebenchWorking(saving || prepared?.input != input) } }
            StorebenchFeedback(text: exportStatus, height: 34)
        }
    }
    private func count(_ value: Int?) -> String { value.map(String.init) ?? "—" }
    private func export(_ selection: SalesPresentation.Selection) {
        guard !saving, let money else { return }; saving = true; defer { saving = false }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.commaSeparatedText]; panel.nameFieldStringValue = "sales-analysis.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do { try SalesPresentation.writeAnalysisCSV(selection, context: money, to: url); exportStatus = "Analysis CSV exported. Source reports and Apple data were unchanged." }
        catch { exportStatus = "Analysis CSV could not be exported." }
    }
}
