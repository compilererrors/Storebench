import StorebenchCore
import SwiftUI

/// Set Up Reports: what Sales and Trends, Payments and Financial Reports and Analytics need before their data appears, one step at a time.
/// Each step shows the same page as its menu item; the checks come from the latest setup check or sync of this app.
struct ReportsGuideView: View {
    let account: Account, app: Account.App, session: WorkspaceSession?
    @Environment(\.openSection) private var openSection
    @State private var items: [SyncItem]?
    @State private var reading = false
    @State private var step: String?

    var body: some View {
        let steps = SyncSetupGuide.progress(items)
        let next = steps.first { $0.state == .todo }?.id
        StorebenchStepPage(title: "Set Up Reports steps", steps: steps.enumerated().map { index, step in
            .init(id: step.id, number: index + 1, title: step.title, purpose: step.detail, complete: step.state == .done, current: step.id == next,
                  needed: step.state == .unknown ? ["Check Setup in the sync card below to see whether this is done."] : [])
        }, selected: $step, actions: AnyView(StorebenchReadButton("Refresh") { await load() }.storebenchWorking(session == nil || reading)), guide: .setUpReports) { id in
            content(id)
        }
        .task { await load() }
        .onChange(of: step) { Task { await load() } }
    }

    @ViewBuilder private func content(_ id: String) -> some View {
        switch id {
        case "reports": SalesView(account: account, app: app, session: session, navigationRequest: nil, openSection: { target in openSection?(target == "pricing" ? .pricing : .localizations) }, openReports: {})
        case "analytics": AnalyticsView(account: account, app: app, session: session, initialKind: nil, onPublish: { openSection?(.publish) }, openLocalizations: { openSection?(.localizations) })
        case "fiscal": FinanceView(account: account, app: app, session: session, compareSales: { _ in openSection?(.sales) })
        default: AppSyncCard(account: account, app: app, session: session, changed: { Task { await load() } }, openSource: { source in
            if let target = SyncSetupGuide.progress(items).first(where: { $0.source == source })?.id { step = target }
        })
        }
    }

    private func load() async {
        guard let session, !reading else { return }
        reading = true; defer { reading = false }
        items = (try? await session.syncPresentation(account: account, appId: app.id))?.status?.items
    }
}

/// On Analytics, Sales and Trends and Payments and Financial Reports: while setup is missing, says how many steps are left and opens the guide.
struct ReportsSetupNotice: View {
    let account: Account, app: Account.App, session: WorkspaceSession?
    @Environment(\.openSection) private var openSection
    @State private var left: Int?

    var body: some View {
        Group {
            if let left, left > 0 {
                StorebenchNotice(title: left == 1 ? "1 setup step left" : "\(left) setup steps left",
                                 description: "Some reports cannot be downloaded yet. Set Up Reports takes you through what is missing.", icon: "info") {
                    if let openSection { Button("Set Up Reports") { openSection(.setUpReports) }.buttonStyle(StorebenchButtonStyle(.primary)) }
                }
            }
        }
        .task(id: account.id + "/" + app.id) {
            guard let session, let items = (try? await session.syncPresentation(account: account, appId: app.id))?.status?.items else { return }
            left = SyncSetupGuide.steps(items)?.filter { $0.state == .todo && $0.id != "sync" }.count ?? 0
        }
    }
}
