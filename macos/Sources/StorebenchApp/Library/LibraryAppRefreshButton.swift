import StorebenchCore
import SwiftUI

/// Every library entry point discovers apps through the same account refresh before rereading its local projection.
struct LibraryAppRefreshButton: View {
    let model: LibraryModel
    let identity: String
    let reload: @MainActor () async -> Void
    var body: some View {
        StorebenchReadButton("Refresh Apps") { await refresh() }
            .help("Read all accessible apps from App Store Connect, including apps preparing their first release. Saved history stays on this Mac.")
            .storebenchWorking(model.refreshingApps || model.session == nil)
            .shortcutAction(.refresh, enabled: !model.refreshingApps && model.session != nil, identity: identity) { await refresh() }
    }
    private func refresh() async {
        guard let session = model.session else { return }
        do { _ = try await model.refreshApps() } catch { /* The shared model presents the refresh result. */ }
        guard model.session === session, !Task.isCancelled else { return }
        await reload()
    }
}
