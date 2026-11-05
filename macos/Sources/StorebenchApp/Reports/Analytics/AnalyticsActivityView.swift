import StorebenchCore
import SwiftUI

/// The chart, top lists and activity breakdown each own their measure selection.
struct AnalyticsActivityView: View {
    let periods: [AnalyticsPeriod], kind: String
    var openLocalizations: (() -> Void)? = nil
    var filters: AnyView? = nil
    var actions: AnyView? = nil
    @State private var chartMetrics: [String] = []
    @State private var scale = "absolute"
    @State private var topMetric = "first"
    @State private var metric = "first"
    @State private var dimension = "territory"
    @State private var query = ""
    @State private var ordering = "count-desc"
    @State private var page = 1
    @State private var pageSize = 10
    private struct Input: Equatable, Sendable {
        let periods: [AnalyticsPeriod], metric: String, top: String, overlay: [String], indexed: Bool
    }
    private struct Prepared: Sendable {
        let input: Input, summary: AnalyticsPresentation.Summary?, top: AnalyticsPresentation.Summary?, series: [SavedTimeSeries.Series]?
    }
    @State private var prepared: Prepared?
    @Environment(\.navigationPresentation) private var presentation
    /// The last figures prepared in this window, reused at once when the saved reports and choices are the same.
    private var preparedKey: String { "analytics-activity/prepared" + (presentation?.scope ?? "") }
    private struct Choices: Equatable { var chartMetrics: [String]; var scale, topMetric, metric, dimension, query, ordering: String; var page, pageSize: Int }
    private var input: Input { Input(periods: periods, metric: selectedMetric, top: selectedTop, overlay: overlay, indexed: scale == "indexed") }
    private var measures: [(String, String)] { kind == "downloads" ? Array(analyticsMeasures.prefix(4)) : Array(analyticsMeasures.suffix(4)) }
    private var selectedMetric: String { measures.contains { $0.0 == metric } ? metric : measures[0].0 }
    private var selectedTop: String { measures.contains { $0.0 == topMetric } ? topMetric : measures[0].0 }
    private var overlay: [String] { let chosen = chartMetrics.filter { key in measures.contains { $0.0 == key } }; return chosen.isEmpty ? [measures[0].0] : chosen }
    private func label(_ metric: String) -> String { analyticsMeasures.first { $0.0 == metric }?.1 ?? metric }
    private func territory(_ key: String) -> String { AnalyticsPresentation.territoryName(key) }
    private func filtered(_ summary: AnalyticsPresentation.Summary, metric dataMetric: String) -> [AnalyticsPresentation.Row] {
        (try? AnalyticsPresentation.breakdown(periods, summary: summary, metric: dataMetric, dimension: AnalyticsPresentation.Dimension(rawValue: dimension) ?? .territory, query: query, order: AnalyticsPresentation.Order(rawValue: ordering) ?? .countDescending)) ?? []
    }
    var body: some View {
        content.task(id: input) {
            let expected = input
            if let saved = presentation?.rememberedRead(preparedKey, as: Prepared.self), saved.input == expected { prepared = saved; return }
            let worker = Task.detached(priority: .userInitiated) {
                guard !Task.isCancelled else { return nil as Prepared? }
                let summary = try? AnalyticsPresentation.summary(expected.periods, metric: expected.metric)
                let top = try? AnalyticsPresentation.summary(expected.periods, metric: expected.top)
                let series = try? ReportCharts.analytics(expected.periods, metrics: expected.overlay, indexed: expected.indexed)
                return Prepared(input: expected, summary: summary, top: top, series: series)
            }
            let next = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, input == expected else { return }; prepared = next
            if let next { presentation?.rememberRead(next, preparedKey) }
        }
        .historyValue("analytics-activity", Binding(get: { Choices(chartMetrics: chartMetrics, scale: scale, topMetric: topMetric, metric: metric, dimension: dimension, query: query, ordering: ordering, page: page, pageSize: pageSize) }, set: { value in
            chartMetrics = value.chartMetrics; scale = value.scale; topMetric = value.topMetric; metric = value.metric; dimension = value.dimension; query = value.query; ordering = value.ordering; page = value.page; pageSize = value.pageSize
        }))
    }
    @ViewBuilder private var content: some View {
        if let prepared, prepared.input.periods == periods, let summary = prepared.summary, let top = prepared.top, let series = prepared.series {
            Card(title: "Saved Analytics analysis", subtitle: Self.analysisSubtitle, actions: actions) {
                filters
                StorebenchFeedback(text: prepared.input == input ? "" : "Updating Analytics… Figures below still use the previous measure and scale.", height: 26)
                StorebenchCardSection(title: "Activity summary") { StorebenchMetricGrid { metrics(summary) } }
                activityCard(summary, metric: prepared.input.metric)
                StorebenchCardSection(title: "Activity over time", description: "Each point is one complete saved activity period in UTC. Missing intervals break the line. Indexed lines have an average of 100.") {
                    StorebenchMetricGrid(maximumColumns: 4, minimumWidth: 180) {
                    ForEach(measures, id: \.0) { key, title in
                        Toggle(title, isOn: Binding(get: { overlay.contains(key) }, set: { checked in var chosen = overlay; if checked && chosen.count < 4 { chosen.append(key) } else if !checked { chosen.removeAll { $0 == key } }; chartMetrics = chosen }))
                    }
                    }
                    StorebenchPicker("Scale", selection: $scale) { SelectionOption("Reported values", value: "absolute"); SelectionOption("Indexed · average = 100", value: "indexed") }.storebenchFormColumn()
                    if prepared.input.overlay.count == 1 && !prepared.input.indexed {
                        Text("Total: \(periods.isEmpty ? "—" : AsoProgress.count(summary.totals[prepared.input.overlay[0]] ?? 0))").font(.sbHeadline).frame(minHeight: 36, alignment: .topLeading)
                    }
                    SavedReportChart(series: series, format: { value in AsoProgress.count(prepared.input.indexed ? value.rounded() : value) }, emptyText: "No saved activity for this selection. Missing reports are not zero activity.")
                }
                StorebenchCardSection(title: "Top storefronts and sources", description: "The eight largest reported groups for this measure in the selected dates.") {
                    StorebenchPicker("Measure for top lists", selection: Binding(get: { selectedTop }, set: { topMetric = $0 })) { selectionOptions(measures) { SelectionOption($0.1, value: $0.0) } }.storebenchFormColumn()
                    ranked("Leading territories · " + label(prepared.input.top), rows: Array(top.territories.prefix(8)), total: top.totals[prepared.input.top] ?? 0, countries: true)
                    ranked("Discovery sources · " + label(prepared.input.top), rows: Array(top.sources.prefix(8)), total: top.totals[prepared.input.top] ?? 0, countries: false)
                }
                if let leading = AnalyticsPresentation.leadingTerritory(top, metric: prepared.input.top) {
                    StorebenchCardSection(title: "Review your leading download territory", description: "An observation about reported first-time downloads, without inferred price or listing impact.") {
                        Text("\(leading.name) accounts for \(leading.share) of reported first-time downloads in this selection. Check its listing and screenshot coverage alongside Sales before prioritizing work. No prices or content are changed.").fixedSize(horizontal: false, vertical: true)
                        if let openLocalizations { Button("Review Languages") { openLocalizations() } }
                    }
                }
                StorebenchCardSection(title: "Report definitions", description: "Analytics describes recorded activity, with privacy limits. Missing reports remain unknown.") {
                    Text("First-time downloads exclude redownloads, updates and restores. Impressions, product page views, Get taps and downloads are separate events and can differ in timing and suppression. Weekly and monthly reports retain their full periods. These observations do not establish a conversion rate or attributed listing impact.").font(.sbCallout).fixedSize(horizontal: false, vertical: true)
                    StorebenchTextLink("Apple Analytics metric definitions", destination: URL(string: "https://developer.apple.com/help/app-store-connect-analytics/reference/metrics-definitions")!)
                }
            }
            .onChange(of: kind) { chartMetrics = []; page = 1 }
            .onChange(of: metric) { page = 1 }
            .onChange(of: dimension) { query = ""; page = 1 }
            .onChange(of: query) { page = 1 }
            .onChange(of: ordering) { page = 1 }
        } else if prepared?.input != input {
            Self.placeholder(filters: filters, actions: actions)
        } else {
            Card(title: "Analytics activity could not be prepared", subtitle: "Saved facts or period metadata could not be validated. Read saved reports before continuing; no reports were changed.", actions: actions) { filters }
        }
    }
    static let analysisSubtitle = "Summary, breakdown and trends from the saved report and activity dates selected here."
    static func placeholder(filters: AnyView?, actions: AnyView?) -> some View {
        Card(title: "Saved Analytics analysis", subtitle: analysisSubtitle, actions: actions) {
            filters
            StorebenchFeedback(text: "", height: 26)
            StorebenchLoadState(state: .loading("Preparing the selected saved reports…")) { EmptyView() } placeholder: {
                StorebenchCardSection(title: "Activity summary") { StorebenchMetricGrid { ForEach(0..<4, id: \.self) { _ in Fact(title: "Saved measure", value: "0") } } }
                StorebenchCardSection(title: "Activity over time", description: "Placeholder for the saved activity periods shown in the chart below.") {
                    RoundedRectangle(cornerRadius: 8).fill(StorebenchTheme.border).frame(maxWidth: .infinity, minHeight: 320)
                }
            }
        }
    }
    private func metrics(_ summary: AnalyticsPresentation.Summary) -> some View {
        ForEach(measures, id: \.0) { key, title in Fact(title: title, value: periods.isEmpty ? "—" : (summary.totals[key] ?? 0).formatted(.number.precision(.fractionLength(0)))) }
    }
    private func ranked(_ title: String, rows: [AnalyticsPresentation.Activity], total: Double, countries: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.sbHeadline)
            if rows.isEmpty { Text("No reported activity for this selection.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted) }
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top) {
                        StorebenchTextSlot(text: countries ? territory(row.key) : row.key, height: 40, font: .sbCallout, color: nil)
                        Text(row.count.formatted(.number.precision(.fractionLength(0)))).monospacedDigit().frame(width: 120, alignment: .trailing)
                    }
                    ProgressView(value: total > 0 ? row.count / total : 0).accessibilityLabel(countries ? territory(row.key) : row.key)
                }
            }
        }
    }
    private func activityCard(_ summary: AnalyticsPresentation.Summary, metric dataMetric: String) -> some View {
        let rows = filtered(summary, metric: dataMetric), pages = max(1, (rows.count + pageSize - 1) / pageSize), current = min(page, pages)
        return StorebenchCardSection(title: "Activity breakdown", description: "Every reported group or saved period for the chosen measure. \(rows.count) groups match this search.") {
            StorebenchMetricGrid(maximumColumns: 2, minimumWidth: 230) {
                StorebenchPicker("Breakdown measure", selection: Binding(get: { selectedMetric }, set: { metric = $0 })) { selectionOptions(measures) { SelectionOption($0.1, value: $0.0) } }
                StorebenchPicker("Group by", selection: $dimension) { SelectionOption("Territory", value: "territory"); SelectionOption("Discovery source", value: "source"); SelectionOption("Device", value: "device"); SelectionOption("Activity period", value: "period") }
            }
            StorebenchTableControls(query: $query,
                sort: Binding(get: { ordering.hasPrefix("name") ? "name" : "count" }, set: { ordering = $0 + (ordering.hasSuffix("asc") ? "-asc" : "-desc") }),
                descending: Binding(get: { ordering.hasSuffix("desc") }, set: { ordering = (ordering.hasPrefix("name") ? "name" : "count") + ($0 ? "-desc" : "-asc") }),
                options: [("count", "Count"), ("name", "Name")], pageSize: $pageSize, searchTitle: "Find activity")
                .onChange(of: pageSize) { page = 1 }
            if rows.isEmpty { Text("No reported activity for this selection.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted) }
            StorebenchTableFrame {
                StorebenchResizableTableViewport(key: "analytics-activity", minimum: [250, 150, 100], weights: [3, 1, 1], height: DataTablePresentation.headerHeight + Double(min(pageSize, max(0, rows.count - (current - 1) * pageSize))) * DataTablePresentation.rowHeight) { columns, resize in
                        VStack(alignment: .leading, spacing: 0) {
                            StorebenchTableHeader(columns: [(dimension == "source" ? "Discovery source" : dimension == "device" ? "Device" : dimension == "period" ? "Activity period" : "Territory", columns[0]), (measures.first { $0.0 == dataMetric }?.1 ?? "Count", columns[1]), ("Share", columns[2])], resize: resize)
                            ForEach(Array(rows.dropFirst((current - 1) * pageSize).prefix(pageSize).enumerated()), id: \.element.id) { index, row in
                                StorebenchTableRow(index: index) {
                                    StorebenchTableCell(text: row.name, width: columns[0], title: "Reported group")
                                    StorebenchTableCell(text: row.count.formatted(.number.precision(.fractionLength(0))), width: columns[1], title: "Reported count")
                                    StorebenchTableCell(text: row.share.map { $0.formatted(.percent.precision(.fractionLength(1))) } ?? "—", width: columns[2], title: "Share")
                                }
                            }
                        }.frame(width: columns.reduce(0, +))
                }
            }
            StorebenchPagination(page: current, count: pages) { page = $0 }
        }
    }
}
