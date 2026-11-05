import StorebenchCore
import SwiftUI

struct AsoOutcomeBrowser: View {
    let account: Account, app: Account.App, session: WorkspaceSession?, events: [JournalEvent], analytics: [AnalyticsPeriod], sales: [SalesPresentation.Period]
    @Binding var selectedId: String
    var openJournal: ((String) -> Void)? = nil
    var readGeneration = ""
    @Environment(\.editorProtection) private var protection
    private var selected: JournalEvent? {
        events.first { $0.id == selectedId } ?? events.first { $0.source == "import" && $0.occurrenceAfter?.isEmpty == false && !$0.changes.isEmpty }
        ?? events.first { $0.source == "publish" && !$0.changes.isEmpty } ?? events.first { $0.source == "import" }
    }
    private var choices: [JournalEvent] {
        var result = Array(events.filter { !$0.changes.isEmpty && ["import", "publish"].contains($0.source) }.prefix(200))
        if let selected, !result.contains(where: { $0.id == selected.id }) { result.append(selected) }; return result
    }
    var body: some View {
        Card(title: "Outcome review", subtitle: "Recorded changes with exact saved report coverage. This describes reported activity; it does not estimate a listing effect.") {
            if let selected {
                StorebenchPicker("Recorded change", selection: Binding(get: { selected.id }, set: { if $0 != selected.id, protection?.allowLeaving() != false { selectedId = $0 } })) {
                    selectionOptions(choices) { SelectionOption("\($0.title) · \($0.time)", value: $0.id) }
                }.storebenchFormColumn()
                Text("The newest 200 changed records are offered. Older records remain in the journal.").font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
                AsoOutcomeView(account: account, app: app, session: session, event: selected, events: events, analytics: analytics, sales: sales, openJournal: openJournal, readGeneration: readGeneration).id(selected.id)
            } else { Text("No journal event to review. Import a listing or prepare a reviewed Apple change to create an analysis anchor.").foregroundStyle(StorebenchTheme.muted) }
        }
    }
}

struct AsoOutcomeView: View {
    let account: Account, app: Account.App, session: WorkspaceSession?, event: JournalEvent, events: [JournalEvent], analytics: [AnalyticsPeriod], sales: [SalesPresentation.Period]
    var openJournal: ((String) -> Void)? = nil
    var readGeneration = ""
    @State private var metric = "views"
    @State private var days = 7
    @State private var territory = ""
    @State private var comparison = ""
    private var choices: [String] { AsoOutcome.territories(metric, analytics: analytics, sales: sales) }
    private var outcome: AsoOutcome.Review? { try? AsoOutcome.analyze(event, events: events, analytics: analytics, sales: sales, metric: metric, days: days, territory: territory, comparison: comparison) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StorebenchFormGrid {
                StorebenchPicker("Primary measure", selection: $metric) { selectionOptions(AsoOutcome.metrics) { SelectionOption($0.title, value: $0.key) } }
                StorebenchPicker("Market", selection: Binding(get: { choices.contains(territory) ? territory : "" }, set: { territory = $0 })) {
                    SelectionOption("All reported territories", value: ""); selectionOptions(choices) { SelectionOption("\(Territories.name($0)) · \($0)", value: $0) }
                }
                StorebenchPicker("Window preset", selection: $days) { selectionOptions([1, 3, 7, 14, 30, 60, 90]) { SelectionOption("\($0) days", value: $0) }; if ![1, 3, 7, 14, 30, 60, 90].contains(days) { SelectionOption("\(days) days", value: days) } }
                StorebenchPicker("Comparison market", selection: Binding(get: { choices.contains(comparison) && comparison != territory && !territory.isEmpty ? comparison : "" }, set: { comparison = $0 })) {
                    SelectionOption("No comparison market", value: ""); selectionOptions(choices.filter { $0 != territory }) { SelectionOption("\(Territories.name($0)) · \($0)", value: $0) }
                }
                StorebenchStepper("\(days) days on each side", value: $days, in: 1...90)
            }
            Text("The anchor day is excluded. Filters read saved reports; they do not download or publish anything. A missing measure or country row remains unknown.").font(.sbCaption).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
            if let review = outcome {
                VStack(alignment: .leading, spacing: 6) {
                    Text(event.title).font(.sbHeadline)
                    if let anchor = review.anchor {
                        Text("\(anchor.kind == "public-observation" ? "Verified public observation" : anchor.kind == "import-observation" ? "Apple import observation" : "Apple send"): \(anchor.at)")
                        Text("Report date: \(anchor.date) · \(anchor.timeZone == "UTC" ? "UTC" : "Pacific Time")")
                    } else { Text("No Apple observation or send time.") }
                    if let url = URL(string: review.source.url) { StorebenchTextLink(review.source.name, destination: url) }
                    Text(review.source.definition).fixedSize(horizontal: false, vertical: true)
                    Text(event.locales.isEmpty ? "The listing language for this change is not recorded." : "Recorded listing languages: \(event.locales.joined(separator: ", ")).").foregroundStyle(StorebenchTheme.muted)
                    if let openJournal { Button("Open Journal Record") { openJournal(event.id) } }
                }.font(.sbCallout)
                if !review.reasons.isEmpty {
                    VStack(alignment: .leading, spacing: 6) { Text("Interpretation limits").font(.sbHeadline); ForEach(review.reasons, id: \.self) { Text($0).font(.sbCallout).fixedSize(horizontal: false, vertical: true) } }
                }
                if let primary = review.primary {
                    windows(primary, title: review.territory.isEmpty ? "All reported territories" : Territories.name(review.territory), days: review.days)
                    if review.canDescribeDifference, let difference = primary.difference {
                        Text("Difference in saved activity around the import observation: \(difference > 0 ? "+" : "")\(difference.formatted()). This is not an estimated effect of the listing change.").font(.sbCallout).fixedSize(horizontal: false, vertical: true)
                    }
                    if let comparison = review.comparison { windows(comparison, title: "Comparison market · \(Territories.name(review.comparisonTerritory))", days: review.days) }
                    DisclosureGroup("Report revisions and missing dates") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                evidence("Before", primary.before); evidence("After", primary.after)
                                if let comparison = review.comparison { evidence("Comparison before", comparison.before); evidence("Comparison after", comparison.after) }
                                Text("These are the currently saved revisions. Later processing can replace them; recheck coverage before using an earlier conclusion.").foregroundStyle(StorebenchTheme.muted)
                            }.font(.sbCaption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 240)
                    }
                }
                if review.otherEventsTotal > 0 {
                    DisclosureGroup("Other changes in the report window · \(review.otherEventsTotal)") {
                        ScrollView { VStack(alignment: .leading, spacing: 8) {
                            StorebenchCollection(items: review.otherEvents, title: { $0.title }, subtitle: { $0.scope + " · " + $0.at }, empty: "No other changes in the report window.") { item in
                                VStack(alignment: .leading, spacing: 2) { Text("\(item.title) · \(item.scope) · \(item.at)").font(.sbCaption).fixedSize(horizontal: false, vertical: true); if let openJournal { Button("Open Journal Record") { openJournal(item.id) }.help("Open Related Journal Record").accessibilityLabel("Open Related Journal Record") } }
                            }
                            if review.otherEventsTotal > review.otherEvents.count { Text("Showing \(review.otherEvents.count) changes. The complete overlap remains in the evidence identity; open the journal for all records.").font(.sbCaption).foregroundStyle(StorebenchTheme.muted) }
                        }.frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 240)
                    }
                }
                StorebenchDivider()
                JournalNoteEditor(account: account, app: app, session: session, event: event, suggestedMetric: review.metric, evidence: review.evidenceFingerprint(for: event)).id(event.id + ":" + readGeneration)
            } else { Text(AsoOutcome.Failure.malformed.message).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true) }
        }
    }
    private func windows(_ measure: AsoOutcome.Measure, title: String, days: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.sbHeadline)
            HStack(alignment: .top, spacing: 20) { window("Before anchor", measure.before, days: days); window("After anchor", measure.after, days: days) }
        }
    }
    private func window(_ title: String, _ value: AsoOutcome.Window, days: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.sbSubheadline.bold()); Text("\(value.start) to \(value.end)").font(.sbCaption)
            Text(value.total.map { $0.formatted() } ?? "Unknown").font(.sbTitle2)
            Text("\(value.covered) of \(days) days with this measure and territory").font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
            if !value.missing.isEmpty { Text("Missing: \(value.missing.prefix(6).joined(separator: ", "))\(value.missing.count > 6 ? " and \(value.missing.count - 6) more" : "")").font(.sbCaption).foregroundStyle(StorebenchTheme.muted) }
        }.fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func evidence(_ title: String, _ value: AsoOutcome.Window) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).bold(); Text(value.revisions.isEmpty ? "No matching report revision" : value.revisions.joined(separator: "; "))
            Text("Missing: \(value.missing.isEmpty ? "None" : value.missing.joined(separator: ", "))")
            Text("Saved daily facts: \(value.daily.isEmpty ? "No matching facts" : value.daily.map { "\($0.date): \($0.value)" }.joined(separator: "; "))")
        }
    }
}
