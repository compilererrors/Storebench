import StorebenchCore
import SwiftUI

/// The Saves made from a Release step, newest first, read from the publishing history on this Mac. They stay after a
/// restart, so the result of an earlier Save is never lost when the step shows or prepares another review.
struct ReleaseRecentSaves: View {
    let account: Account, app: Account.App, session: WorkspaceSession?
    let scopes: Set<PublishRequest.Scope>
    var limit = 5
    @State private var saves: [PublishReview]?

    var body: some View {
        Card(title: "Recent saves", subtitle: "Saves to App Store Connect from this Mac, newest first. Open one to see how far it got and why it stopped.") {
            if let saves {
                if saves.isEmpty { Text("Nothing has been saved to App Store Connect from this step yet.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted) }
                ForEach(saves, id: \.id) { item in
                    DisclosureGroup {
                        ForEach(Array(PublishingReviewPresentation.facts(item).enumerated()), id: \.offset) { _, fact in
                            StorebenchFact(label: fact.label, value: fact.value, problem: fact.problem)
                        }
                    } label: {
                        Text("\(PublishingReviewPresentation.label(item, now: Date())) · \(item.title) · \(PublishingReviewPresentation.started(item))")
                    }
                }
            } else {
                StorebenchLoadingStatus(message: "Reading saved results…", surface: false)
            }
        }
        // A running Save advances in the background, so the list is read again while it shows.
        .task(id: app.id) { await StorebenchPolling.repeating(every: .seconds(3), while: { true }) { await load() } }
    }

    private func load() async {
        guard let session, let history = try? await session.publishHistory(accountId: account.id, appId: app.id) else { return }
        var recent = Array(history.filter { scopes.contains($0.request.scope) && $0.state != "prepared" }.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
        // A Save left running by an app that quit is read through its status, which marks it stopped.
        for index in recent.indices where recent[index].state == "running" {
            if let current = try? await session.publishStatus(accountId: account.id, appId: app.id, id: recent[index].id) { recent[index] = current }
        }
        saves = recent
    }
}
