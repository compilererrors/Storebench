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
    @State private var currency = ""
    private struct Input: Equatable, Sendable { let source: Source, metric: String, currency: String }
    private struct Prepared: Sendable { let input: Input, series: [SavedTimeSeries.Series]? }
    @State private var prepared: Prepared?
    private var selectedCurrency: String { source.currencies.contains(currency) ? currency : source.currencies.first ?? "" }
    private var selectedMetric: String { source.financial ? metric : "proceeds" }
    private var input: Input { Input(source: source, metric: selectedMetric, currency: selectedCurrency) }
    var body: some View {
        Card(title: source.financial ? "Financial periods" : "Original proceeds over time", subtitle: "Complete saved report intervals. Original currencies stay separate; missing amounts remain unknown. These are reported proceeds, not bank payouts.") {
            StorebenchMetricGrid(maximumColumns: 2, minimumWidth: 230) {
                if source.financial {
                    StorebenchPicker("Measure", selection: $metric) {
                        SelectionOption("Paid units", value: "paid"); SelectionOption("Returned units", value: "returned")
                        SelectionOption("Net units", value: "net"); SelectionOption("Other net units", value: "other")
                        SelectionOption("Reported proceeds", value: "proceeds")
                    }
                }
                if selectedMetric == "proceeds" && !source.currencies.isEmpty {
                    StorebenchPicker("Original report currency", selection: Binding(get: { selectedCurrency }, set: { currency = $0 })) {
                        selectionOptions(source.currencies) { SelectionOption($0, value: $0) }
                    }
                }
            }
            if selectedMetric == "proceeds", source.currencies.isEmpty {
                Text("No original currency amounts are available in this selection.").foregroundStyle(StorebenchTheme.muted)
            } else if let prepared, prepared.input == input, let series = prepared.series {
                SavedReportChart(series: series, format: { value in
                    selectedMetric == "proceeds" ? ReportMoney.label(String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), ReportMoney.fractionDigits(selectedCurrency), value), currency: selectedCurrency) : AsoProgress.count(value)
                }, note: "The inspection shows original amounts. Gaps and unavailable details are never filled with zero.")
            } else if prepared?.input != input {
                ProgressView("Preparing saved reports…").frame(maxWidth: .infinity, minHeight: 320)
            } else {
                Text("Saved report intervals could not be validated. Read the original reports before continuing.").foregroundStyle(StorebenchTheme.muted)
            }
        }.task(id: input) {
            let expected = input
            let worker = Task.detached(priority: .userInitiated) {
                guard !Task.isCancelled else { return nil as Prepared? }
                let series: [SavedTimeSeries.Series]?
                switch expected.source {
                case .sales(let periods): series = try? ReportCharts.salesProceeds(periods, currency: expected.currency)
                case .financial(let periods): series = try? ReportCharts.financial(periods, metric: expected.metric, currency: expected.currency)
                }
                return Prepared(input: expected, series: series)
            }
            let next = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, input == expected else { return }; prepared = next
        }
    }
}
