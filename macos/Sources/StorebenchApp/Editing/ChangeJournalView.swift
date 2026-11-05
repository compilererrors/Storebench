import StorebenchCore
import SwiftUI

/// Listing changes and their exact report evidence, with one protected local note per entry.
struct ChangeJournalView: View {
    let account: Account, app: Account.App, session: WorkspaceSession?
    var initialEventId: String? = nil
    @State private var events: [JournalEvent] = []
    @State private var selected: String?
    @State private var status = ""
    @State private var filter = "all"
    @State private var analytics: [AnalyticsPeriod] = []
    @State private var sales: [SalesPresentation.Period] = []
    @State private var loading = false
    @State private var loadId = UUID()
    @Environment(\.editorProtection) private var protection
    @Environment(\.navigationPresentation) private var history
    private struct Choices: Equatable { var selected: String?; var filter: String }
    private struct Read: Codable { let events: [JournalEvent], analytics: [AnalyticsPeriod], sales: [SalesPresentation.Period], status: String }
    private var readKey: String { "change-journal/\(account.id)/\(app.id)" }
    private var shown: [JournalEvent] { events.filter { filter == "all" || $0.source == filter } }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Card(title: "Change Journal", subtitle: "Imports, drafts, release plans and reviewed Apple changes, newest first. Dates show what Storebench saw or sent, not when Apple published it.", actions: AnyView(
                Button("Read Latest") { if protection?.allowLeaving() != false { Task { await load() } } }.help("Read Latest Journal and Reports").accessibilityLabel("Read Latest Journal and Reports").storebenchWorking(loading)
            )) {
                StorebenchChoicePicker("Show", selection: $filter, options: [("all", "All"), ("import", "Imported"), ("draft", "Drafts"), ("release-plan", "Release plan"), ("publish", "App Store changes")])
                StorebenchCollection(items: shown, title: { $0.title }, subtitle: summary, focusedID: initialEventId,
                                     empty: loading && events.isEmpty ? "Reading saved entries…" : events.isEmpty ? "No journal entries yet. Entries appear when you read from Apple, save a draft or release plan, or send a reviewed change." : "No entries of this kind. Choose All to see every entry.") { event in
                    if selected != event.id {
                        StorebenchFormFooter {
                            Button { select(event.id) } label: { StorebenchLabel("View Entry", icon: "next", size: 16) }
                                .storebenchWorking(loading)
                        }
                    }
                }
                StorebenchFeedback(text: status, height: 34)
            }
            if let selected, let event = events.first(where: { $0.id == selected }) { detail(event).id(event.id) }
        }
        .trackUnsavedChanges(false, busy: loading)
        .task { showRemembered(); await load() }
        .historyValue("change-journal", Binding(get: { Choices(selected: selected, filter: filter) }, set: { selected = $0.selected; filter = $0.filter }))
        .onDisappear { loadId = UUID() }
    }
    private func select(_ id: String) { guard selected != id, !loading, protection?.allowLeaving() != false else { return }; selected = id }
    private func summary(_ event: JournalEvent) -> String {
        let stage = ["observed": "Seen in a sync", "draft": "Saved on this Mac", "prepared": "Review prepared", "approved": "Approved", "sent": "Sent to App Store Connect"][event.stage] ?? event.stage
        var parts = [stage]
        if !event.time.isEmpty { parts.append("\(event.time.prefix(16).replacingOccurrences(of: "T", with: " ")) UTC") }
        if let after = event.occurrenceAfter { parts.append("changed after \(after.prefix(10))") }
        if !event.locales.isEmpty { parts.append(event.locales.joined(separator: ", ")) }
        parts.append("\(event.changes.count) changes"); return parts.joined(separator: " · ")
    }
    private func detail(_ event: JournalEvent) -> some View {
        Card(title: event.title, subtitle: summary(event)) {
            DisclosureGroup("Recorded before and after values · \(event.changes.count)") {
                ScrollView { VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(event.changes.enumerated()), id: \.offset) { _, change in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(change.label).font(.sbHeadline)
                            Text("Before: \(change.before.isEmpty ? "No saved value" : change.before)")
                            Text("After: \(change.after.isEmpty ? "No saved value" : change.after)")
                        }.font(.sbCallout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true); StorebenchDivider()
                    }
                }.frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 260)
            }
            AsoOutcomeView(account: account, app: app, session: session, event: event, events: events, analytics: analytics, sales: sales, openJournal: select, readGeneration: loadId.uuidString)
        }
    }
    private func load() async {
        guard let session, !loading else { return }
        let id = UUID(); loadId = id; loading = true
        defer { if loadId == id { loading = false } }
        var errors: [String] = []
        do { let value = try await session.changeJournal(accountId: account.id, appId: app.id); guard loadId == id, !Task.isCancelled else { return }; events = value }
        catch { guard loadId == id, !Task.isCancelled else { return }; events = []; errors.append("change journal") }
        do { let value = try await session.analytics(accountId: account.id, appId: app.id); guard loadId == id, !Task.isCancelled else { return }; analytics = value }
        catch { guard loadId == id, !Task.isCancelled else { return }; analytics = []; errors.append("Analytics reports") }
        do { let value = try await session.salesPresentation(account: account, appId: app.id); guard loadId == id, !Task.isCancelled else { return }; sales = value }
        catch { guard loadId == id, !Task.isCancelled else { return }; sales = []; errors.append("original Sales reports") }
        guard loadId == id, !Task.isCancelled else { return }
        if selected == nil, let initialEventId, events.contains(where: { $0.id == initialEventId }) { selected = initialEventId }
        status = errors.isEmpty ? "" : "Unavailable saved data: \(errors.joined(separator: ", ")). Missing reports remain unknown. Read again before interpreting a comparison."
        history?.rememberRead(Read(events: events, analytics: analytics, sales: sales, status: status), readKey)
    }
    private func showRemembered() {
        guard events.isEmpty, let read = history?.rememberedRead(readKey, as: Read.self) else { return }
        events = read.events; analytics = read.analytics; sales = read.sales; status = read.status
    }
}
