import StorebenchCore
import SwiftUI

/// Word-level diff text: additions highlighted, removals struck through.
func diffText(_ segments: [AsoTextSegment]) -> Text {
    segments.reduce(Text("")) { text, segment in
        switch segment.kind {
        case .same: text + Text(segment.text)
        case .added: text + Text(segment.text).foregroundColor(StorebenchTheme.color("color-success")).bold()
        case .removed: text + Text(segment.text).foregroundColor(StorebenchTheme.color("color-danger")).strikethrough()
        }
    }
}

struct AsoProgressView: View {
    let account: Account, app: Account.App, session: WorkspaceSession?
    @State private var baseRows: [AsoProgressRow] = [] { didSet { dataRevision += 1 } }
    @State private var locales: [String] = []
    @State private var locale = ""
    @State private var fieldFilter = AsoProgress.FieldFilter.all
    @State private var reveal: StorebenchCollectionReveal<String>?
    @State private var measures: [String] = []
    @State private var granularity = AsoProgress.Granularity.day
    @State private var indexed = false
    @State private var choices = ViewPeriods()
    @State private var points: [String: [AsoPoint]] = [:] { didSet { dataRevision += 1 } }
    @State private var reports = AsoProgress.Reports([:])
    @State private var status = ""
    @State private var loadId = UUID()
    @State private var loading = false
    @State private var keepChoices = false
    @State private var notes: [ChartNote] = [] { didSet { dataRevision += 1 } }
    @State private var noteDate = Date()
    @State private var noteText = ""
    @State private var noteStatus = ""
    @State private var savingNote = false
    @State private var dataRevision = 0
    @State private var presented: (input: PresentationInput, value: AsoProgress.Presentation)?
    @Environment(\.navigationPresentation) private var history
    private struct Choices: Equatable { var locale: String; var fieldFilter: AsoProgress.FieldFilter; var measures: [String]; var granularity: AsoProgress.Granularity; var indexed: Bool }
    private struct Read: Codable, Sendable { let rows: [AsoProgressRow], locales: [String], primary: String, points: [String: [AsoPoint]], status: String }
    private var readKey: String { "aso-progress/\(account.id)/\(app.id)" }
    /// Choices restored by Back stay through the read that follows, while they still exist in the saved data.
    private var choiceValue: Binding<Choices> {
        Binding(get: { Choices(locale: locale, fieldFilter: fieldFilter, measures: measures, granularity: granularity, indexed: indexed) }, set: { value in
            locale = value.locale; fieldFilter = value.fieldFilter; measures = value.measures; granularity = value.granularity; indexed = value.indexed; keepChoices = true
        })
    }
    private var days: Int { choices.days(.asoCompare) }
    private var today: String { PeriodDates.text(Date()) }
    private var available: [String] { AsoProgress.metrics.map(\.key).filter { !(points[$0] ?? []).isEmpty } }
    private var latest: String { (points.values.flatMap { $0.map(\.date) } + baseRows.map(\.date)).max() ?? "" }
    private var range: PeriodDateRange? { try? choices.range(.asoProgressRange).resolve(latest: latest) }
    /// Everything that changes what is drawn. The data's own revision stands in for the saved listings, reports and notes.
    private struct PresentationInput: Equatable, Sendable {
        let revision: Int, locale: String, fields: AsoProgress.FieldFilter, range: PeriodDateRange?, measures: [String], granularity: AsoProgress.Granularity, indexed: Bool
    }
    private var presentationInput: PresentationInput {
        PresentationInput(revision: dataRevision, locale: locale, fields: fieldFilter, range: range, measures: measures, granularity: granularity, indexed: indexed)
    }
    /// The last prepared presentation. While a newer one is prepared, the earlier one stays on screen.
    private var presentation: AsoProgress.Presentation { presented?.value ?? .empty }
    private var rows: [AsoProgressRow] { presentation.rows }
    private var changed: [AsoProgressRow] { presentation.changed }
    private var markers: [SavedTimeSeries.Marker] { presentation.markers }
    /// Marker colors by kind: what a listing change changed, or your own note.
    static let markerKinds: [(kind: String, title: String, color: Color)] = AsoProgress.MarkerKind.allCases.map { kind in
        let token = switch kind { case .keywords: "color-warning"; case .names: "color-nav"; case .screenshots: "color-danger"; case .text: "chart-axis"; case .note: "color-success" }
        return (kind.rawValue, kind.title, StorebenchTheme.color(token))
    }
    private func title(_ metric: String) -> String { AsoProgress.metrics.first { $0.key == metric }?.title ?? metric }
    private func impact(_ metric: String, _ row: AsoProgressRow) -> AsoImpact? { reports.comparison(metric, row: row, days: days, today: today) }

    var body: some View {
        ScrollViewReader { reader in
            VStack(alignment: .leading, spacing: 20) {
                Card(title: "Version comparison", subtitle: "Only released versions are included. Dates mark when Storebench observed the released listing, not its creation or exact release. Each listing change compared with the \(days) days before it. Full windows compare totals; gaps compare the average per reported day. Missing reports are not zero.", help: "aso-progress") {
                    StorebenchFormGrid(maximumColumns: 3) {
                        StorebenchPicker("Language", selection: $locale) { SelectionOption("All languages", value: ""); selectionOptions(locales) { SelectionOption(StoreLocales.name($0), value: $0) } }
                        StorebenchPicker("Listing fields", selection: $fieldFilter) { selectionOptions(AsoProgress.FieldFilter.allCases) { SelectionOption($0.title, value: $0) } }
                        PeriodDaysField(title: "Compare days before and after", value: choices.daysBinding(.asoCompare, session: session))
                    }
                    PeriodRangeField(choice: choices.rangeBinding(.asoProgressRange, session: session), latest: latest)
                    PeriodPreferencesNotice(periods: choices)
                    Text("Listing text is compared within one language. What’s New and URLs are left out: they do not affect search. The date range limits the chart and listed changes; report comparisons can reach outside it.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
                    StorebenchFeedback(text: status, height: 36)
                    if !loading && baseRows.isEmpty && available.isEmpty { Text("Nothing to compare yet. Sync the app to save its listing and download Analytics and Sales reports.").foregroundStyle(StorebenchTheme.muted) }
                    if changed.isEmpty { Text("No listing changes to compare yet. The first saved version is the baseline.").foregroundStyle(StorebenchTheme.muted) }
                    else {
                        DisclosureGroup("How to read the version comparison") {
                            Text("Change compares the same period after and before a listing change. /day is an average per reported day. Waiting for data means the period is not over or Apple has not delivered its reports, usually 2–3 days late. No reports before or after means nothing is saved for that side; Too few reports means fewer than half the days. Coverage shows saved days on each side.").font(.sbCallout).fixedSize(horizontal: false, vertical: true)
                        }
                        SavedComparisonTable(rows: changed, columns: [.init(id: "version", title: "Version", width: 180), .init(id: "changed", title: "Changed", width: 220)] + available.map { .init(id: $0, title: title($0), width: 200) }, cell: cell, numeric: { row, key in guard let value = impact(key, row), value.basis != .missing else { return nil }; return value.change }) { id in reveal = .init(id: id) }
                    }
                }
                Card(title: indexed ? "Measures indexed to their average (100)" : "Measures per \(granularity.rawValue)", subtitle: indexed ? "Each line is scaled so its average is 100. Dashed lines mark listing changes." : "Weeks and months show the average per reported day. Dashed lines mark listing changes. Use Indexed to compare measures of different size.") {
                    ChartMeasureToggles(options: AsoProgress.metrics.filter { available.contains($0.key) }.map { (key: $0.key, title: $0.title) }, selection: $measures)
                    StorebenchFormGrid {
                        StorebenchPicker("Group by", selection: $granularity) { selectionOptions(AsoProgress.Granularity.allCases) { SelectionOption($0.rawValue.capitalized, value: $0) } }
                        ChartScalePicker(indexed: $indexed)
                    }
                    SavedReportChart(series: series, markers: markers, format: format, markerKinds: Self.markerKinds) { target in
                        if target.hasPrefix("note:") { withAnimation { reader.scrollTo("chart-notes", anchor: .top) } } else { reveal = .init(id: target) }
                    }
                }
                notesCard.id("chart-notes")
                Text("Versions in detail").font(.sbTitle3)
                StorebenchCollection(items: changed.enumerated().map { StorebenchCollectionEntry(id: $0.element.id, value: ($0.offset, $0.element)) }, title: { $0.value.1.version }, subtitle: { $0.value.1.date }, empty: "No versions with listing changes yet. Changes appear after a later sync reads a new version.",
                                     reveal: reveal, onRevealed: { id in withAnimation { reader.scrollTo(id, anchor: .top) } }) { entry in
                    let (_, row) = entry.value
                    version(row).id(row.id)
                }
                ForEach(rows.filter(\.baseline).reversed()) { row in
                    Text("\(row.version)\(row.dateKnown ? " (release observed \(row.date))" : "") is the first saved snapshot for \(row.platform). Later versions are compared with it; earlier listing text is unknown.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task { await showRemembered(); await choices.load(session, scope: try? PeriodScope(accountId: account.id, appId: app.id)); await load() }
        .historyValue("aso-progress", choiceValue)
        .onDisappear { loadId = UUID(); loading = false }
        .task(id: presentationInput) {
            let input = presentationInput, rows = baseRows, notes = notes, points = points
            let worker = Task.detached(priority: .userInitiated) {
                AsoProgress.presentation(baseRows: rows, locale: input.locale, fields: input.fields, range: input.range, notes: notes,
                                         measures: input.measures, points: points, granularity: input.granularity, indexed: input.indexed)
            }
            let value = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, presentationInput == input else { return }
            presented = (input, value)
        }
    }
    private var series: [SavedTimeSeries.Series] { presentation.series }
    private func format(_ value: Double) -> String { indexed ? AsoProgress.count(value.rounded()) : granularity == .day ? AsoProgress.count(value) : AsoProgress.count(Double(AsoProgress.fixed(value, digits: 1)) ?? 0) }
    private func cell(_ row: AsoProgressRow, _ key: String) -> (value: String, detail: String, explanation: String) {
        if key == "version" { return (row.version + (row.isUpdate ? " · update" : ""), row.dateKnown ? row.date : "Date unknown", "\(row.version): \(row.dateKnown ? row.date : "Version date unknown")") }
        if key == "changed" {
            var names: [String] = []
            for change in row.changes { let name = change.field.hasPrefix("screenshots") ? "Screenshots" : AsoComparison.fieldName(change.field); if !names.contains(name) { names.append(name) } }
            let value = names.joined(separator: ", "); return (value, "", value)
        }
        guard let value = impact(key, row) else { return ("No date", "Version date unknown", "\(title(key)): Apple did not provide when this released listing was observed.") }
        let description = AsoProgress.describe(value, label: title(key)); return (description.value, description.detail ?? "", description.title)
    }
    private func version(_ row: AsoProgressRow) -> some View {
        Card(title: "\(row.version) · \(row.isUpdate ? "Listing update" : "New version")", subtitle: "\(!row.dateKnown ? "Version date unknown" : row.isUpdate ? "Seen at the sync on \(row.date)" : "Release first observed \(row.date)")\(row.previousVersion.map { " · compared with \(row.isUpdate ? "its earlier state" : $0)" } ?? "")") {
            Text("Listing changes · \(row.changes.count) fields changed. Removed text is red, added text green.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
            VStack(alignment: .leading, spacing: 0) {
                StorebenchCollection(items: row.changes, title: { AsoComparison.fieldName($0.field) }, subtitle: { $0.locale }, maximumColumns: 3, minimumWidth: 240, empty: "No listing fields changed in this version.") { change in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(AsoComparison.fieldName(change.field) + (locale.isEmpty ? " · \(change.locale)" : "")).font(.sbSubheadline.bold())
                        ScrollView(.vertical) {
                            switch change.kind {
                            case .text: diffText(change.segments).font(.sbCallout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            case .list:
                                VStack(alignment: .leading) {
                                    if !change.added.isEmpty { Text("Added: " + change.added.joined(separator: ", ")).foregroundStyle(StorebenchTheme.color("color-success")) }
                                    if !change.removed.isEmpty { Text("Removed: " + change.removed.joined(separator: ", ")).foregroundStyle(StorebenchTheme.color("color-danger")) }
                                    if change.added.isEmpty && change.removed.isEmpty { Text("Keyword order changed.").foregroundStyle(StorebenchTheme.muted) }
                                }.font(.sbCallout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            case .media: Text("\(change.added.count) images added · \(change.removed.count) removed").font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
                            }
                        }.frame(maxHeight: 180)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .topLeading).background(StorebenchTheme.color("color-surface-subtle"), in: RoundedRectangle(cornerRadius: StorebenchTheme.controlRadius))
                }
            }
            if !row.dateKnown { Text("Apple did not provide when this released listing was observed, so its measures cannot be placed in time. Sync the app again to record the date.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted) }
            else {
                ForEach(AsoProgress.groups, id: \.key) { group in
                    let metrics = group.metrics.filter { available.contains($0) }
                    if !metrics.isEmpty {
                        Text(group.title).font(.sbSubheadline.bold())
                        Text(group.description).font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
                        StorebenchMetricGrid {
                            ForEach(metrics, id: \.self) { metric in if let value = impact(metric, row) { delta(value, title: title(metric)) } }
                            ForEach(AsoProgress.rates.filter { AsoProgress.rateGroup($0.key) == group.key && available.contains($0.numerator) && available.contains($0.denominator) }, id: \.key) { rate in
                                let value = reports.rate(rate.numerator, rate.denominator, date: row.date, days: days)
                                SavedDeltaCard(title: rate.title, value: value.change.map { AsoProgress.signed($0, digits: 1) + " pts" } ?? "Unknown", detail: "",
                                               beforeLabel: "Before \(value.before.map { AsoProgress.fixed($0, digits: 1) } ?? "—")", afterLabel: "After \(value.after.map { AsoProgress.fixed($0, digits: 1) } ?? "—")", explanation: rate.title,
                                               before: value.before, after: value.after, tone: tone(value.change))
                            }
                        }
                    }
                }
            }
            let mixed = AsoProgress.overlapping(row, among: baseRows, days: days), noted = row.dateKnown ? ChartNotes.within(notes, date: row.date, days: days) : []
            if !mixed.isEmpty {
                Text("Other listing changes fall inside this comparison window, so their effect is mixed in: " + mixed.map { "\($0.version) on \($0.date)" }.joined(separator: ", ") + ".")
                    .font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
            }
            if !noted.isEmpty {
                Text("Your notes inside this comparison window: " + noted.map { "\($0.date) \($0.text)" }.joined(separator: "; ") + ".")
                    .font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    /// Your own dated notes, such as a campaign or a price change, shown on the chart and beside comparisons they fall inside.
    private var notesCard: some View {
        Card(title: "Your chart notes", subtitle: "Mark what else happened, such as a campaign, a feature or a price change. Notes show on the chart and beside comparisons whose window they fall inside. They stay on this Mac.") {
            StorebenchFormGrid {
                StorebenchDateField("Date", selection: $noteDate, displayedComponents: .date)
                StorebenchTextField("Note", text: $noteText, hint: "Up to \(ChartNotes.textLimit) characters, such as Spring campaign started.")
            }
            StorebenchFormFooter {
                StorebenchCommand(title: "Add Note", running: "Saving…", busy: savingNote, unavailable: noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Write the note first." : nil, primary: true) { Task { await addNote() } }
            }
            StorebenchFeedback(text: noteStatus, height: 34)
            if notes.isEmpty { Text("No notes yet.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted) }
            else {
                VStack(alignment: .leading, spacing: StorebenchTheme.space(2)) {
                    ForEach(notes.reversed()) { note in
                        HStack(alignment: .firstTextBaseline, spacing: StorebenchTheme.space(2)) {
                            Text(note.date).font(.sbCallout.monospacedDigit()).foregroundStyle(StorebenchTheme.muted)
                            Text(note.text).font(.sbCallout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                            Button { Task { await removeNote(note) } } label: { StorebenchIcon(name: "close", size: 14) }
                                .buttonStyle(StorebenchButtonStyle(.quiet, size: .icon)).help("Remove Note").accessibilityLabel("Remove note from \(note.date)").storebenchWorking(savingNote)
                        }
                    }
                }
            }
        }.environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
    }
    private func addNote() async {
        guard let session, !savingNote else { return }
        savingNote = true; defer { savingNote = false }
        do {
            let note = try await session.addChartNote(accountId: account.id, appId: app.id, date: PeriodDates.text(noteDate), text: noteText)
            notes = try await session.chartNotes(accountId: account.id, appId: app.id); noteText = ""; noteStatus = "Note added for \(note.date)."
        } catch let failure as ChartNoteFailure { noteStatus = failure.message }
        catch { noteStatus = "The note could not be saved. Your text is still here; try again." }
    }
    private func removeNote(_ note: ChartNote) async {
        guard let session, !savingNote else { return }
        savingNote = true; defer { savingNote = false }
        do { try await session.removeChartNote(accountId: account.id, appId: app.id, id: note.id); noteStatus = "Note from \(note.date) removed." }
        catch let failure as ChartNoteFailure { noteStatus = failure.message }
        catch { noteStatus = "The note could not be removed. Try again." }
        notes = (try? await session.chartNotes(accountId: account.id, appId: app.id)) ?? notes
    }
    private func delta(_ value: AsoImpact, title: String) -> some View {
        let shown = AsoProgress.describe(value, label: title)
        func side(_ name: String, _ number: Double?, _ count: Int) -> String {
            let shown = number.map { number in value.basis == .daily ? AsoProgress.count(Double(AsoProgress.fixed(number, digits: 1)) ?? 0) + "/day" : AsoProgress.count(number) } ?? "Unknown"
            return "\(name) \(shown) · \(count)/\(days) days"
        }
        return SavedDeltaCard(title: title, value: shown.value, detail: shown.detail ?? "", beforeLabel: side("Before", value.before, value.beforeDays), afterLabel: side("After", value.after, value.afterDays), explanation: shown.title,
                              before: value.before, after: value.after, tone: tone(value.change))
    }
    private func tone(_ change: Double?) -> Color { change.map { $0 > 0 ? StorebenchTheme.color("color-success") : $0 < 0 ? StorebenchTheme.color("color-danger") : StorebenchTheme.ink } ?? StorebenchTheme.muted }

    private func load() async {
        guard let session else { return }
        let id = UUID(); loadId = id; loading = true
        defer { if loadId == id { loading = false } }
        var messages: [String] = [], loadedAnalytics: [AnalyticsPeriod] = [], loadedSales: [SalesPresentation.Period] = [], primary = ""
        do {
            let value = try await session.asoProgress(accountId: account.id, appId: app.id)
            guard loadId == id, !Task.isCancelled else { return }
            baseRows = AsoProgress.rows(value.revisions); locales = value.locales; primary = value.primaryLocale; chooseLocale(primary)
        } catch {
            guard loadId == id, !Task.isCancelled else { return }; baseRows = []; locales = []; locale = ""; messages.append("The saved listings could not be read.")
        }
        do { loadedAnalytics = try await session.analytics(accountId: account.id, appId: app.id) }
        catch { messages.append("Analytics reports are not prepared yet; Analytics measures show no days.") }
        guard loadId == id, !Task.isCancelled else { return }
        do { loadedSales = try await session.salesPresentation(account: account, appId: app.id) }
        catch { messages.append("Sales reports could not be read; Sales measures show no days.") }
        guard loadId == id, !Task.isCancelled else { return }
        do { notes = try await session.chartNotes(accountId: account.id, appId: app.id) }
        catch { messages.append("Your chart notes could not be read.") }
        guard loadId == id, !Task.isCancelled else { return }
        points = Dictionary(uniqueKeysWithValues: AsoProgress.metrics.map { ($0.key, AsoProgress.points($0.key, analytics: loadedAnalytics, sales: loadedSales)) })
        reports = AsoProgress.Reports(points)
        chooseMeasures(); status = messages.joined(separator: " ")
        history?.rememberRead(Read(rows: baseRows, locales: locales, primary: primary, points: points, status: status), readKey)
    }
    private func chooseLocale(_ primary: String) {
        if !keepChoices || !(locale.isEmpty || locales.contains(locale)) { locale = AsoProgress.initialLocale(locales, primary: primary) }
    }
    private func chooseMeasures() {
        let kept = measures.filter { !(points[$0] ?? []).isEmpty }
        measures = keepChoices && !kept.isEmpty ? kept : AsoProgress.initialMeasures(points)
    }
    /// Two years of daily measures decode away from the main thread.
    private func showRemembered() async {
        guard baseRows.isEmpty, points.isEmpty, let read = await history?.rememberedDecodedRead(readKey, as: Read.self), baseRows.isEmpty, points.isEmpty else { return }
        baseRows = read.rows; locales = read.locales; points = read.points; reports = AsoProgress.Reports(read.points); status = read.status
        chooseLocale(read.primary); chooseMeasures()
    }
}
