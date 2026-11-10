import AppKit
import StorebenchCore
import SwiftUI

struct AIHistorySection: View {
    let session: WorkspaceSession?
    @State private var entries: [AIHistoryEntry] = []
    @State private var appNames: [String: String] = [:]
    @State private var selected: AIHistoryEntry?
    @State private var loading = false
    @State private var status = ""
    var body: some View {
        StorebenchFormSection("AI History", icon: "history", description: "Requests and results stay on this Mac, including previous card variants. Open a request to inspect its brief, instructions, screenshots and response.") {
            StorebenchCollection(items: entries, title: { $0.title }, subtitle: { entry in
                (appNames[entry.accountId + ":" + entry.appId] ?? "App") + " · " + entry.provider.title + " · " + entry.stateTitle + " · " + entry.createdAt.formatted(date: .abbreviated, time: .shortened)
            }, preferenceID: "ai-history", empty: loading ? "Reading saved AI requests…" : "No AI requests are saved for your connected apps yet. Generate cards or translate text to start this history.", activate: { selected = $0 }, action: "View Request") { _ in EmptyView() }
            StorebenchTextSlot(text: status, height: 44, font: .sbCallout, color: StorebenchTheme.muted, live: true)
            StorebenchFormFooter {
                Button("Refresh History") { Task { await load() } }.storebenchControlID("ai-history.refresh").storebenchWorking(loading)
                    .help("Read saved requests, including those completed in another window")
            }
        }.task { await load() }
            .sheet(item: $selected) { entry in
                AIHistoryDetail(session: session, entry: entry, appName: appNames[entry.accountId + ":" + entry.appId] ?? "App", close: { selected = nil })
            }
    }
    private func load() async {
        guard !loading, let session else { return }; loading = true; defer { loading = false }
        do {
            var values: [AIHistoryEntry] = [], names: [String: String] = [:]
            for account in try await session.accounts() {
                for app in account.apps {
                    values += try await session.aiHistory(accountId: account.id, appId: app.id)
                    names[account.id + ":" + app.id] = app.name
                }
            }
            entries = values.sorted { $0.createdAt > $1.createdAt }; appNames = names
            status = "\(entries.count) saved requests. Refresh to see the latest progress; completed results are retained."
        } catch { status = "History could not be read. Saved requests are kept; try Refresh History again." }
    }
}

struct AIHistoryDetail: View {
    let session: WorkspaceSession?, entry: AIHistoryEntry, appName: String, close: () -> Void
    @State private var job: AIJob?
    @State private var status = ""
    var body: some View {
        StorebenchDialog(title: "AI Request", wide: true, height: 760, close: close) {
            StorebenchCardSection(title: entry.title) {
                StorebenchFormGrid {
                    metadata("App", appName)
                    metadata("Task", entry.purpose == "cards" ? "Create AI Cards" : "Translate Text")
                    metadata("AI Service", entry.provider.title)
                    metadata("Model", entry.provider == .apple ? "On-Device Model · Managed by macOS" : entry.model)
                    metadata("Created", entry.createdAt.formatted(date: .complete, time: .standard))
                    metadata("Status", job?.state.title ?? entry.stateTitle)
                    metadata("Screenshots", "\(entry.imageCount)")
                    if let start = job?.startedAt, let end = job?.finishedAt { metadata("Duration", "\(Int(max(0, end.timeIntervalSince(start)))) seconds") }
                }
            }
            if let job {
                if let failure = job.failure { StorebenchTextSlot(text: failure.message, height: 64, font: .sbCallout, color: StorebenchTheme.color("color-danger")) }
                if job.request.purpose == "cards" {
                    let input = (try? JSONText.parse(Data(job.request.input.utf8))) ?? .null
                    StorebenchCardSection(title: "Brief") {
                        StorebenchAdaptiveText(text: input["brief"]?.text ?? "The original brief is unavailable.")
                        if let directions = try? AICardDirection.selected(in: input), input["directions"] != nil {
                            StorebenchAdaptiveText(text: "Creative Directions: " + directions.map(\.title).joined(separator: ", "), font: .sbCaption, color: StorebenchTheme.muted)
                        }
                    }
                }
                DisclosureGroup {
                    if let execution = job.execution {
                        StorebenchAdaptiveText(text: execution.format, font: .sbCaption, color: StorebenchTheme.muted)
                        StorebenchTextSlot(text: execution.instructions, height: 180, font: .sbCallout)
                        StorebenchTextSlot(text: execution.input, height: 180, font: .sbCallout)
                    } else {
                        Text(job.connection.provider == .apple ? "This older request predates exact native prompt recording. Its saved brief, image text and result are shown below; the original native instructions cannot be reconstructed exactly." : "This older request retains its original instructions and input.")
                            .font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
                        if job.connection.provider != .apple { StorebenchTextSlot(text: job.request.instructions, height: 180, font: .sbCallout) }
                        StorebenchTextSlot(text: job.request.input, height: 180, font: .sbCallout)
                    }
                } label: { Text("Sent Instructions").storebenchControlID("ai-history.instructions") }
                if !job.request.images.isEmpty {
                    DisclosureGroup("Submitted Screenshots") {
                        Text(entry.provider == .apple ? "Apple Intelligence used the recognized text below. It did not receive image pixels." : "These are the reduced images submitted to the selected AI service. Original screenshots in your card sets stay unchanged.")
                            .font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
                        StorebenchMetricGrid(maximumColumns: 2, minimumWidth: 240) {
                            ForEach(Array(job.request.images.enumerated()), id: \.offset) { index, source in
                                StorebenchCardSection(title: "Screenshot \(index + 1)") {
                                    if let image = NSImage(data: source.data) {
                                        Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 220).accessibilityLabel("Submitted screenshot \(index + 1)")
                                    }
                                    if !source.text.isEmpty { StorebenchTextSlot(text: source.text, height: 100, font: .sbCaption) }
                                }
                            }
                        }
                    }
                }
                if let result = job.result {
                    DisclosureGroup { StorebenchTextSlot(text: result.stringify(), height: 240, font: .sbCallout) }
                    label: { Text("Saved Response").storebenchControlID("ai-history.response") }
                }
            } else { StorebenchTextSlot(text: status.isEmpty ? "Reading saved request…" : status, height: 54, font: .sbCallout, color: StorebenchTheme.muted, live: true) }
        } actions: {
            Text("History is stored in your encrypted local workspace. Opening a request does not contact the AI service.").font(.sbCaption).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
        }.task {
            do { job = try await session?.aiHistoryJob(accountId: entry.accountId, appId: entry.appId, id: entry.id) }
            catch { status = "This saved request could not be opened. Close this view and refresh the history." }
        }
    }
    private func metadata(_ title: String, _ value: String) -> some View {
        StorebenchFormField(label: title) { StorebenchAdaptiveText(text: value) }
    }
}
