import StorebenchCore
import SwiftUI

/// Two saved listing states side by side, with reported activity after each. Observations, not attributed effects.
struct AsoDiffView: View {
    let account: Account, app: Account.App, session: WorkspaceSession?
    var openJournal: ((String) -> Void)? = nil
    @Environment(\.editorProtection) private var protection
    @State private var tab = "compare"
    @State private var events: [JournalEvent] = []
    @State private var outcomeSales: [SalesPresentation.Period] = []
    @State private var readIssue = ""
    @State private var outcomeEventId = ""
    @State private var loading = false
    @State private var loadId = UUID()
    @State private var snapshots: [AsoSnapshot] = []
    @State private var drafts: [AsoChange] = []
    @State private var primary = ""
    @State private var leftId = ""
    @State private var rightId = ""
    @State private var days = 7
    @State private var onlyChanged = false
    @State private var choices = ViewPeriods()
    @State private var timelineMetric = "impressions"
    @State private var timelineIndexed = false
    @State private var timelineId = ""
    @State private var analytics: [AnalyticsPeriod] = []
    @State private var status = ""
    @Environment(\.navigationPresentation) private var history
    private let metrics = AsoOutcome.metrics
    private struct Choices: Equatable { var tab, leftId, rightId, timelineMetric, timelineId, outcomeEventId: String; var days: Int; var onlyChanged: Bool }
    private var choicesValue: Binding<Choices> {
        Binding(get: { Choices(tab: tab, leftId: leftId, rightId: rightId, timelineMetric: timelineMetric, timelineId: timelineId, outcomeEventId: outcomeEventId, days: days, onlyChanged: onlyChanged) }, set: { value in
            tab = value.tab; leftId = value.leftId; rightId = value.rightId; timelineMetric = value.timelineMetric; timelineId = value.timelineId
            outcomeEventId = value.outcomeEventId; days = value.days; onlyChanged = value.onlyChanged
        })
    }
    private struct Read: Codable { let snapshots: [AsoSnapshot], drafts: [AsoChange], primary: String, analytics: [AnalyticsPeriod], events: [JournalEvent], sales: [SalesPresentation.Period], status: String, issue: String }
    private var readKey: String { "aso-diff/\(account.id)/\(app.id)" }

    var body: some View {
        let left = snapshots.first { $0.id == leftId }, right = snapshots.first { $0.id == rightId }
        VStack(alignment: .leading, spacing: 20) {
            StorebenchNavigationTabs(items: [.init(id: "compare", title: "Compare", icon: "history"), .init(id: "graph", title: "Graph", icon: "sales"), .init(id: "outcome", title: "Outcome", icon: "check")], selected: tab, label: "ASO Diff views", minimumWidth: StorebenchTheme.design.number("navigation-compact-minimum-width")) { value in
                if value != tab, protection?.allowLeaving() != false { tab = value }
            }
            Card(title: "Saved ASO data", subtitle: "Listing versions, Analytics and Sales saved on this Mac. Read again after a sync or import.", actions: AnyView(
                Button(loading ? "Reading…" : "Read Latest Save") { if protection?.allowLeaving() != false { Task { await load() } } }.help(loading ? "Reading…" : "Read Latest Saved ASO Data").accessibilityLabel(loading ? "Reading…" : "Read Latest Saved ASO Data").storebenchWorking(loading)
            )) {
                StorebenchFeedback(text: readIssue, height: 34)
            }
            if tab == "outcome" {
                if loading && events.isEmpty && analytics.isEmpty && outcomeSales.isEmpty { StorebenchLoadingStatus(message: "Reading saved ASO data…", surface: false) }
                else { AsoOutcomeBrowser(account: account, app: app, session: session, events: events, analytics: analytics, sales: outcomeSales, selectedId: $outcomeEventId, openJournal: openJournal, readGeneration: loadId.uuidString) }
            } else if tab == "graph" { timeline }
            else {
                if let left, let right {
                    fields(left, right)
                    activity(left, right)
                } else {
                    Card(title: "Compare two saved versions", subtitle: "Choose a saved App Store version state on each side. Fields are compared directly between the two selections.") {
                        Text(status.isEmpty ? "No saved versions yet. Sync app material to save App Store versions." : status).foregroundStyle(StorebenchTheme.muted)
                    }
                }
            }
            if tab != "outcome" {
            if !drafts.isEmpty {
                Card(title: "Unpublished draft changes", subtitle: "Edits saved on this Mac. They have no App Store change date and are separate from the comparison above.") {
                    ForEach(Array(drafts.enumerated()), id: \.offset) { _, change in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(change.section) · \(change.field)").font(.sbHeadline)
                            AsoSavedValues(beforeLabel: "Before", afterLabel: "After", before: AsoComparison.fieldValue(change.before, image: change.field.hasPrefix("screenshots")), after: AsoComparison.fieldValue(change.after, image: change.field.hasPrefix("screenshots")))
                        }
                    }
                }
            }
            }
        }
        .task { showRemembered(); await choices.load(session, scope: try? PeriodScope(accountId: account.id, appId: app.id)); await load() }
        .historyValue("aso-diff", choicesValue)
        .trackUnsavedChanges(false, busy: loading)
        .onDisappear { loadId = UUID() }
    }

    private func sideBinding(_ side: String) -> Binding<String> {
        Binding(get: { side == "left" ? leftId : rightId }, set: { id in
            let pair = AsoComparison.choose(.init(leftId: leftId, rightId: rightId), side: side, id: id); leftId = pair.leftId; rightId = pair.rightId
        })
    }
    private func versionChoice(_ side: String, _ snapshot: AsoSnapshot) -> some View {
        StorebenchNavigationSelect(title: side == "left" ? "Left" : "Right", selected: label(snapshot, snapshots.firstIndex { $0.id == snapshot.id } ?? 0)) {
            ForEach(Array(snapshots.enumerated()), id: \.element.id) { index, item in
                Button(label(item, index)) { sideBinding(side).wrappedValue = item.id }
            }
        }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }
    private func versionSummary(_ snapshot: AsoSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(snapshot.version).font(.sbHeadline)
            Text("\(snapshot.dateCreated ? "Created in App Store Connect" : "Saved by Storebench") · \(snapshot.at)")
            Text("Imported \(snapshot.savedAt) · \(snapshot.fields.count) saved ASO fields")
        }.font(.sbCaption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }
    /// The measures drawn together on the timeline, in the order chosen.
    private var timelineMetrics: [String] { ChartMeasures.chosen(timelineMetric, allowed: metrics.map(\.key), fallback: [AsoComparison.graphMetric(analytics: analytics, sales: outcomeSales)]) }
    private var timelinePoints: [AsoPoint] { timelineMetrics.flatMap { AsoComparison.points($0, analytics: analytics, sales: outcomeSales) } }
    private var latestDate: String { (timelinePoints.map(\.date) + snapshots.map { String($0.at.prefix(10)) }).max() ?? "" }
    private var visibleSnapshots: [AsoSnapshot] {
        let range = try? choices.range(.asoDiffRange).resolve(latest: latestDate)
        return snapshots.filter { range?.contains(String($0.at.prefix(10))) ?? true }
    }
    private var timeline: some View {
        let range = try? choices.range(.asoDiffRange).resolve(latest: latestDate)
        let chosen = timelineMetrics
        let reported = chosen.map { key in
            SavedTimeSeries.Series(key: key, label: metrics.first { $0.key == key }?.title ?? key,
                                   points: AsoComparison.points(key, analytics: analytics, sales: outcomeSales).filter { range?.contains($0.date) ?? true }.map { .init(start: $0.date, end: $0.date, value: $0.value) })
        }
        let most = reported.map(\.points.count).max() ?? 0
        let visible = visibleSnapshots, selected = visible.first { $0.id == timelineId } ?? visible.last
        return VStack(alignment: .leading, spacing: 20) {
            Card(title: "ASO changes and activity over time", subtitle: "Saved daily reports with observations of released versions. Observation dates do not establish the exact publication date or an ASO effect.") {
                ChartMeasureToggles(options: metrics.map { (key: $0.key, title: "\($0.title) · \(AsoComparison.points($0.key, analytics: analytics, sales: outcomeSales).count) daily dates") }, chosen: chosen) { timelineMetric = $0 }
                ChartScalePicker(indexed: $timelineIndexed)
                PeriodRangeField(choice: choices.rangeBinding(.asoDiffRange, session: session), latest: latestDate, title: "Time range")
                PeriodPreferencesNotice(periods: choices)
                if most == 0 { Text("No daily reports in this range. Version dates remain available; missing reports are not zero activity.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted) }
                SavedReportChart(series: timelineIndexed ? SavedTimeSeries.indexed(reported) : reported,
                                 markers: visible.map { .init(date: String($0.at.prefix(10)), label: "\($0.version) \($0.dateCreated ? "created" : "saved")", active: $0.id == selected?.id) },
                                 format: { timelineIndexed ? AsoProgress.count($0.rounded()) : AsoProgress.count($0) })
                if most == 1 { Text("One daily report cannot form a trend. Download more report dates to extend the line.").font(.sbCaption).foregroundStyle(StorebenchTheme.muted) }
                Text("Gaps mean missing daily reports, not zero activity. Select a saved version below to inspect its fields.").font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
                if !visible.isEmpty {
                    StorebenchPicker("Inspect version on timeline", selection: Binding(get: { selected?.id ?? "" }, set: { timelineId = $0 })) {
                        selectionOptions(Array(visible.enumerated())) { SelectionOption(label($0.element, $0.offset), value: $0.element.id) }
                    }
                } else if !snapshots.isEmpty { Button("Show All Dates") { choices.choose(.asoDiffRange, .range(.all), session: session) }.help("Show All Version Dates").accessibilityLabel("Show All Version Dates") }
            }
            if let selected, let index = snapshots.firstIndex(where: { $0.id == selected.id }),
               let previous = snapshots[..<index].last(where: { platform($0) == platform(selected) }) {
                fields(previous, selected, changedOnly: true, beforeLabel: "Previous", afterLabel: "Selected")
            } else if let selected {
                fields(nil, selected, changedOnly: false, beforeLabel: "Baseline", afterLabel: "Selected")
            }
        }
    }
    private func platform(_ snapshot: AsoSnapshot) -> String {
        snapshot.fields.first { $0.key.hasPrefix("version:") }?.key.split(separator: ":").dropFirst().first.map(String.init) ?? String(snapshot.version.split(separator: " ").first ?? "")
    }

    private func label(_ snapshot: AsoSnapshot, _ index: Int) -> String {
        "\(snapshot.version) · \(snapshot.dateCreated ? "created" : "saved") \(snapshot.at.prefix(16).replacingOccurrences(of: "T", with: " ")) UTC · #\(index + 1)"
    }

    private func activity(_ left: AsoSnapshot, _ right: AsoSnapshot) -> some View {
        let leftDate = String(left.at.prefix(10)), rightDate = String(right.at.prefix(10))
        let apart = abs((PeriodDates.number(leftDate) ?? 0) - (PeriodDates.number(rightDate) ?? 0)) >= days
        let rows = AsoComparison.activity(leftDate: leftDate, rightDate: rightDate, days: days, analytics: analytics, sales: outcomeSales)
        return Card(title: "Reported activity", subtitle: "Totals for \(days) days after each date, excluding that day. Dates mark observations of released listings. Their exact publication dates remain unknown; these are observations, not ASO effects.") {
            StorebenchChoicePicker("Days after each version", selection: $days, options: [(1, "1 day"), (3, "3 days"), (7, "7 days"), (14, "14 days")]).fixedSize()
            if leftDate == rightDate { Text("Both states share a date, so their activity uses the same days.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted) }
            else if !apart { Text("These activity windows overlap. Choose fewer days or versions farther apart to compare totals.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted) }
            StorebenchTableFrame {
                StorebenchResizableTableViewport(key: "aso-activity", minimum: [220, 200, 200, 180], weights: [2, 1, 1, 1], height: DataTablePresentation.headerHeight + Double(rows.count) * DataTablePresentation.rowHeight) { columns, resize in
                    let measureWidth = columns[0], leftWidth = columns[1], rightWidth = columns[2], differenceWidth = columns[3]
                        VStack(alignment: .leading, spacing: 0) {
                            StorebenchTableHeader(columns: [("Measure", measureWidth), ("Left · after \(leftDate)", leftWidth), ("Right · after \(rightDate)", rightWidth), ("Right minus left", differenceWidth)], resize: resize)
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                StorebenchTableRow(index: index) {
                                    StorebenchTableCell(text: "\(row.label)\n\(row.reportDates) saved daily dates", width: measureWidth)
                                    StorebenchTableCell(text: "\(row.left.total.map { $0.formatted() } ?? "Unknown")\n\(row.left.saved) of \(days) days saved", width: leftWidth)
                                    StorebenchTableCell(text: "\(row.right.total.map { $0.formatted() } ?? "Unknown")\n\(row.right.saved) of \(days) days saved", width: rightWidth)
                                    StorebenchTableCell(text: row.difference.map { "\($0 > 0 ? "+" : "")\($0.formatted())\(row.percent.map { " (\($0))" } ?? "")" } ?? "—", width: differenceWidth)
                                }
                            }
                        }.frame(width: columns.reduce(0, +))
                }
            }
            Text("Analytics dates use UTC; paid purchases use Sales and Trends days in Pacific time.").font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
        }
    }

    private func fields(_ left: AsoSnapshot?, _ right: AsoSnapshot, changedOnly: Bool? = nil, beforeLabel: String = "Left", afterLabel: String = "Right") -> some View {
        let rows = AsoComparison.fields(left, right, primary: primary), changed = rows.filter(\.changed), filtered = changedOnly ?? onlyChanged
        return Card(title: "ASO fields · \(right.version)", subtitle: left == nil ? "First saved version on this platform · \(rows.count) baseline fields." : "\(changed.count) of \(rows.count) tracked fields differ. Saved values are aligned below.") {
            if changedOnly == nil { Toggle("Show only changed fields", isOn: $onlyChanged).toggleStyle(StorebenchToggleStyle()) }
            Text("App-wide name and subtitle are values observed at import, not a separate history for each release.").font(.sbCaption).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
            if changedOnly == nil, let left {
                HStack(alignment: .top, spacing: 16) { versionSummary(left); versionSummary(right) }
                if snapshots.count < 2 { Text("Only one distinct version state is saved. Sync again when another version or changed listing is available.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted) }
                HStack(alignment: .top, spacing: 16) { versionChoice("left", left); versionChoice("right", right) }
            }
            if rows.isEmpty { Text("Neither saved version contains tracked listing text or screenshots.").foregroundStyle(StorebenchTheme.muted) }
            if filtered && changed.isEmpty { Text("The tracked listing text and screenshot sets match the preceding saved version.").foregroundStyle(StorebenchTheme.muted) }
            ForEach(filtered ? changed : rows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(row.context) · \(row.label)\(row.changed && left != nil ? " · Changed" : "")").font(.sbHeadline)
                    AsoSavedValues(beforeLabel: left == nil ? "Baseline" : beforeLabel, afterLabel: afterLabel, before: left == nil ? "—" : row.beforeDisplay, after: row.afterDisplay)
                }
                StorebenchDivider()
            }
        }
    }

    private func load() async {
        guard let session, !loading else { return }
        let id = UUID(); loadId = id; loading = true
        defer { if loadId == id { loading = false } }
        var issues: [String] = []
        let chosen = keepsPair
        do {
            let saved = try await session.asoSnapshots(accountId: account.id, appId: app.id)
            guard loadId == id, !Task.isCancelled else { return }; (snapshots, drafts, primary) = saved
            if !keepsPair { let pair = AsoComparison.initialPair(snapshots); leftId = pair.leftId; rightId = pair.rightId }
            status = ""
        } catch { guard loadId == id, !Task.isCancelled else { return }; snapshots = []; drafts = []; status = "Saved versions could not be read."; issues.append("version snapshots") }
        do { let value = try await session.analytics(accountId: account.id, appId: app.id); guard loadId == id, !Task.isCancelled else { return }; analytics = value }
        catch { guard loadId == id, !Task.isCancelled else { return }; analytics = []; issues.append("Analytics reports") }
        do { let value = try await session.changeJournal(accountId: account.id, appId: app.id); guard loadId == id, !Task.isCancelled else { return }; events = AsoComparison.statisticsEvents(value, snapshots: snapshots) }
        catch { guard loadId == id, !Task.isCancelled else { return }; events = []; issues.append("change journal") }
        do { let value = try await session.salesPresentation(account: account, appId: app.id); guard loadId == id, !Task.isCancelled else { return }; outcomeSales = value }
        catch { guard loadId == id, !Task.isCancelled else { return }; outcomeSales = []; issues.append("original Sales reports") }
        guard loadId == id, !Task.isCancelled else { return }
        if !chosen {
            days = snapshots.count > 1 ? AsoComparison.initialDays(snapshots.first { $0.id == leftId }, snapshots.first { $0.id == rightId }, analytics: analytics, sales: outcomeSales) : 7
            timelineMetric = AsoComparison.graphMetric(analytics: analytics, sales: outcomeSales)
        }
        readIssue = issues.isEmpty ? "" : "Unavailable saved data: \(issues.joined(separator: ", ")). Missing reports remain unknown; read again before interpreting the outcome."
        history?.rememberRead(Read(snapshots: snapshots, drafts: drafts, primary: primary, analytics: analytics, events: events, sales: outcomeSales, status: status, issue: readIssue), readKey)
    }
    /// The pair, period and graph the user chose, or that Back restored, stay while they still exist in the saved data.
    private var keepsPair: Bool { !leftId.isEmpty && !rightId.isEmpty && leftId != rightId && snapshots.contains { $0.id == leftId } && snapshots.contains { $0.id == rightId } }
    private func showRemembered() {
        guard snapshots.isEmpty, let read = history?.rememberedRead(readKey, as: Read.self) else { return }
        snapshots = read.snapshots; drafts = read.drafts; primary = read.primary; analytics = read.analytics; events = read.events; outcomeSales = read.sales; status = read.status; readIssue = read.issue
        guard !keepsPair else { return }
        let pair = AsoComparison.initialPair(snapshots); leftId = pair.leftId; rightId = pair.rightId
        days = snapshots.count > 1 ? AsoComparison.initialDays(snapshots.first { $0.id == leftId }, snapshots.first { $0.id == rightId }, analytics: analytics, sales: outcomeSales) : 7
        timelineMetric = AsoComparison.graphMetric(analytics: analytics, sales: outcomeSales)
    }
}
