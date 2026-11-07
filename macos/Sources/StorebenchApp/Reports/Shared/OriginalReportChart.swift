import Foundation
import StorebenchCore
import SwiftUI

/// Original currency series are separate from dated conversion estimates and bank payouts.
struct OriginalReportChart: View {
    enum Source: Equatable, Sendable {
        case sales([SalesPresentation.Period]), financial([FinancialPresentation.Period])
        var financial: Bool { if case .financial = self { return true }; return false }
        var currencies: [String] {
            switch self {
            case .sales(let rows): return Array(Set(rows.flatMap { $0.rows.flatMap { $0.proceeds.map(\.currency) } })).sorted()
            case .financial(let rows): return Array(Set(rows.flatMap { $0.rows.flatMap { $0.proceeds.map(\.currency) } })).sorted()
            }
        }
    }
    let source: Source
    @State private var metric = "paid"
    @State private var currencies = ""
    @State private var indexed = false
    private struct Input: Equatable, Sendable { let source: Source, metric: String, currencies: [String], indexed: Bool }
    private struct Prepared: Sendable { let input: Input, series: [SavedTimeSeries.Series]? }
    @State private var prepared: Prepared?
    /// The currencies drawn together; the first reported currency until others are chosen.
    private var chosen: [String] { ChartMeasures.chosen(currencies, allowed: source.currencies, fallback: Array(source.currencies.prefix(1))) }
    private var selectedMetric: String { source.financial ? metric : "proceeds" }
    /// The scale the chart actually draws: reported values whenever the scale choice is not shown.
    private var drawnIndexed: Bool { ChartMeasures.indexed(indexed, metric: selectedMetric, currencies: source.currencies.count) }
    private var input: Input { Input(source: source, metric: selectedMetric, currencies: chosen, indexed: drawnIndexed) }
    private func label(_ value: Double) -> String {
        if drawnIndexed { return AsoProgress.count(value.rounded()) }
        guard selectedMetric == "proceeds" else { return AsoProgress.count(value) }
        let digits = chosen.count == 1 ? ReportMoney.fractionDigits(chosen[0]) : 2, amount = String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), digits, value)
        return chosen.count == 1 ? ReportMoney.label(amount, currency: chosen[0]) : amount
    }
    var body: some View {
        Card(title: source.financial ? "Financial periods" : "Original proceeds over time", subtitle: "Complete saved report intervals. Original currencies stay separate; missing amounts remain unknown. These are reported proceeds, not bank payouts.") {
            if source.financial {
                StorebenchPicker("Measure", selection: $metric) {
                    SelectionOption("Paid units", value: "paid"); SelectionOption("Returned units", value: "returned")
                    SelectionOption("Net units", value: "net"); SelectionOption("Other net units", value: "other")
                    SelectionOption("Reported proceeds", value: "proceeds")
                }.storebenchFormColumn()
            }
            if ChartMeasures.scaleOffered(metric: selectedMetric, currencies: source.currencies.count) {
                StorebenchCardSection(title: "Original report currencies") {
                    ChartMeasureToggles(options: source.currencies.map { (key: $0, title: $0) }, chosen: chosen) { currencies = $0 }
                    ChartScalePicker(indexed: $indexed)
                    if chosen.count > 1 && !indexed {
                        Text("Amounts in different currencies share one axis and are not converted. Choose Indexed to compare their shape.").font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
                    }
                }
            }
            if selectedMetric == "proceeds", source.currencies.isEmpty {
                Text("No original currency amounts are available in this selection.").foregroundStyle(StorebenchTheme.muted)
            } else if let prepared, prepared.input == input, let series = prepared.series {
                if case .sales(let periods) = source, case let unverified = ReportCharts.unverifiedProceeds(periods), unverified > 0 {
                    Text("\(unverified) of \(periods.count) report \(periods.count == 1 ? "period is" : "periods are") not plotted: their proceeds or product coverage need verification, so their amounts stay unknown here and the totals above are partial. Download those reports again to verify them.")
                        .foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
                }
                SavedReportChart(series: series, format: label, note: "The inspection shows original amounts. Gaps and unavailable details are never filled with zero.")
            } else if prepared?.input != input {
                ProgressView("Preparing saved reports…").frame(maxWidth: .infinity, minHeight: 320)
            } else {
                Text("Saved report intervals could not be validated. Read the original reports before continuing.").foregroundStyle(StorebenchTheme.muted)
            }
        }.task(id: input) {
            let expected = input
            let worker = Task.detached(priority: .userInitiated) {
                guard !Task.isCancelled else { return nil as Prepared? }
                let reported: [SavedTimeSeries.Series]?
                switch expected.source {
                case .sales(let periods): reported = try? expected.currencies.flatMap { try ReportCharts.salesProceeds(periods, currency: $0) }
                case .financial(let periods):
                    reported = expected.metric == "proceeds" ? try? expected.currencies.flatMap { try ReportCharts.financial(periods, metric: expected.metric, currency: $0) }
                        : try? ReportCharts.financial(periods, metric: expected.metric)
                }
                return Prepared(input: expected, series: expected.indexed ? reported.map(SavedTimeSeries.indexed) : reported)
            }
            let next = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, input == expected else { return }; prepared = next
        }
    }
}
