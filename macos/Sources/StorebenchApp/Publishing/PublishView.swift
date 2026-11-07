import Foundation
import StorebenchCore
import SwiftUI

struct PublishView: View {
    let account: Account, app: Account.App, session: WorkspaceSession?
    var initialRequest: PublishRequest? = nil
    var initialReview: PublishReview? = nil
    @State private var history: [PublishReview]?
    @State private var historyPage = 1
    @State private var historyIssue = ""
    @State private var historyReading = false
    @State private var panelBusy = false
    @State private var opening: String?
    @Environment(\.navigationPresentation) private var presentation
    private var readKey: String { "publish-history/\(account.id)/\(app.id)" }
    private var busy: Bool { panelBusy || historyReading }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PublishActionPanel(account: account, app: app, session: session, actions: PublishingWorkspace.Action.allCases, initialRequest: initialRequest, initialReview: initialReview,
                               history: .init(opening: $opening, reading: historyReading, busyChanged: { panelBusy = $0 }, changed: { await loadHistory() }))
            Card(title: "Publishing history", subtitle: "Reopen a review to inspect its exact changes and completed steps. An expired or used review is never replayed.", actions: AnyView(
                Button("Refresh History") { Task { await loadHistory() } }.storebenchWorking(busy)
            )) {
                Text(historyIssue).font(.sbCallout).foregroundStyle(StorebenchTheme.muted).frame(minHeight: 20, alignment: .leading)
                if let history {
                    StorebenchCollection(items: history, title: { $0.title }, sorts: [.init(id: "date", label: "Created", less: { $0.createdAt < $1.createdAt })], empty: "No publishing reviews yet. Reviews you prepare appear here.") { item in
                        StorebenchStatusRow(title: item.title, detail: "\(item.createdAt.prefix(16).replacingOccurrences(of: "T", with: " ")) UTC · \(item.steps.filter { $0.state == "done" }.count) of \(item.steps.count) steps", separator: false) {
                            StorebenchTextSlot(text: PublishingReviewPresentation.label(item, now: Date()), height: StorebenchTheme.controlHeight, font: .sbCaption, color: StorebenchTheme.muted, centered: true)
                        } action: {
                            Button("Open Review") { opening = item.id }.storebenchWorking(busy)
                        } details: { EmptyView() }
                    }

                } else { Text("Publishing history has not been read.").foregroundStyle(StorebenchTheme.muted) }
            }
        }
        .task {
            if history == nil { history = presentation?.rememberedRead(readKey, as: [PublishReview].self) }
            await loadHistory()
        }
    }
    private func loadHistory() async {
        guard !historyReading, let session else { return }; historyReading = true; defer { historyReading = false }
        do { let items = try await session.publishHistory(accountId: account.id, appId: app.id); try Task.checkCancellation(); history = items; historyPage = PublishingReviewPresentation.page(items, requested: historyPage).page; historyIssue = ""; presentation?.rememberRead(items, readKey) }
        catch { historyIssue = "Publishing history could not be read. Previously read entries are retained; retry." }
    }
}
