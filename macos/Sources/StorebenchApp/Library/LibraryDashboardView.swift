import StorebenchCore
import SwiftUI

struct LibraryDashboardView: View {
    let model: LibraryModel, section: LibraryOverview.Section
    let navigationMessage: String
    let openApp: (LibraryOverview.Destination) -> Void
    let openSource: (ConnectedApps.Row, String?) -> Void
    let recover: (ConnectedApps.Row, RecoveryGuidance.Action) -> Void
    let connect: () -> Void
    let manageApps: () -> Void
    @State private var snapshot: LibraryOverview.Snapshot?
    @Environment(\.navigationPresentation) private var history
    @State private var loading = false
    @State private var failed = false
    @State private var readGate = PresentationWork()
    @State private var context = UUID()
    private var unavailable: Bool { failed || snapshot == nil }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: StorebenchTheme.gap) {
                StorebenchPageHeader(title: section.rawValue, description: section == .history ? "Every successful import and local version draft is retained separately. Choose an app to compare its saved revisions." : "Track progress across your apps, continue a release and check what needs syncing.", eyebrow: section == .history ? "SAVED REVISIONS" : "AT A GLANCE", actions: AnyView(HStack {
                    Spacer(minLength: 0)
                    LibraryAppRefreshButton(model: model, identity: section.rawValue) { await load(context, wait: true); await ScreenReads.reading(fresh: true) { await checkPlans(fresh: true) } }
                    Button("Manage Apps", action: manageApps).buttonStyle(StorebenchButtonStyle(.quiet))
                }), feedback: AnyView(StorebenchFeedback(text: model.appRefreshMessage, height: 34, error: model.appRefreshFailed)), help: section == .history ? "" : "sync")
                if section == .overview { SampleDataNotice(model: model) }
                if failed { Text("The saved library could not be confirmed. Previously read information remains here; refresh before opening an app.").foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true) }
                if let snapshot {
                    if snapshot.apps.isEmpty {
                        Card(title: "Get started", subtitle: "Three steps to your first release. Nothing is sent to Apple until you approve a review.", help: "sync") {
                            StorebenchSetupStep(number: 1, title: "Connect your Apple account", detail: "Add an App Store Connect API key so Storebench can see your apps. You can also do this later from Settings, or load sample data to look around first.") {
                                StorebenchActionGroup {
                                    Button("Connect Account", action: connect).buttonStyle(StorebenchButtonStyle(.primary)).help("Connect Apple Account").accessibilityLabel("Connect Apple Account")
                                    LoadSampleDataButton(model: model)
                                }
                            }
                            StorebenchSetupStep(number: 2, title: "Sync your apps", detail: "Downloads each app's App Store text, screenshots and versions. It only reads from Apple.")
                            StorebenchSetupStep(number: 3, title: "Start a release", detail: "Open an app and choose Release. It takes you through a new version step by step.")
                        }
                    } else if section == .history {
                        StorebenchCardList(padded: true) {
                            StorebenchCollection(items: snapshot.apps, title: { $0.name }, subtitle: { $0.account.name + "\n" + $0.historyLabel + ($0.latestImportedAt.map { " · Latest " + LibraryOverview.timestamp($0) } ?? "") },
                                                 icon: appIcon, empty: "No apps yet. Connect an Apple account from Settings.",
                                                 activate: { row in if !unavailable && !loading { navigate(row, section: .history) } }, action: "Compare revisions") { _ in EmptyView() }
                        }
                    } else {
                        // Getting started stays until the first app is synced and has a release, each step checked once done.
                        let synced = (snapshot.materialApps ?? 0) > 0, released = (snapshot.releaseCount ?? 0) > 0
                        if !(synced && released) {
                            Card(title: "Get started", subtitle: "Three steps to your first release. Nothing is sent to Apple until you approve a review.", help: "sync") {
                                StorebenchSetupStep(number: 1, title: "Connect your Apple account", detail: "\(snapshot.apps.count) \(snapshot.apps.count == 1 ? "app" : "apps") from \(snapshot.accountCount) \(snapshot.accountCount == 1 ? "account" : "accounts"). Add more in Settings → Apple accounts.", done: true)
                                StorebenchSetupStep(number: 2, title: "Sync your apps", detail: synced ? "Your apps' App Store text, screenshots and versions are on this Mac." : "Choose Sync all apps below. It downloads each app's App Store text, screenshots and versions, and only reads from Apple.", done: synced)
                                StorebenchSetupStep(number: 3, title: "Start a release", detail: "Open an app and choose Release, or Create Release below. It takes you through a new version step by step.", done: released)
                            }
                        }
                        StorebenchMetricGrid(balanced: true) {
                            Fact(title: "Configured apps", value: String(snapshot.apps.count), hint: "Across \(snapshot.accountCount) \(snapshot.accountCount == 1 ? "account" : "accounts")")
                            Fact(title: "Apps with material", value: snapshot.materialApps.map(String.init) ?? "Unknown", hint: "Imported or started locally", info: "Apps with saved App Store text, screenshots or a local version draft.")
                            Fact(title: "Awaiting material", value: snapshot.awaitingMaterialApps.map(String.init) ?? "Unknown", hint: "Import or start a new version", info: "Configured apps without saved App Store text or screenshots yet. Sync an app to bring them in.")
                            Fact(title: "Release plans", value: snapshot.releaseCount.map(String.init) ?? "Unknown", hint: "Saved plans being prepared")
                        }
                        if snapshot.plansUnavailable {
                            Card(title: "Saved release plans unavailable", subtitle: "Refresh before choosing a plan. Existing saved plans have not been changed.") { EmptyView() }
                        } else if snapshot.releases.isEmpty {
                            StorebenchNotice(title: "No release plans yet", description: "Choose an app to prepare a new version with its text, languages and media.") {
                                StorebenchMenu("Create Release", icon: "release") { ForEach(snapshot.apps) { row in Button(row.name) { navigate(row, section: .release) } } }.storebenchWorking(unavailable || loading)
                            }
                        } else {
                            ReleaseOverviewList(releases: snapshot.releases, session: model.session, unavailable: unavailable || loading, icon: appIcon) {
                                navigate($0.app, section: .release, plan: $0.plan)
                            }
                        }
                        StorebenchCardList(padded: true, spacing: StorebenchTheme.gap) {
                            AllAppsSyncButton(session: unavailable ? nil : model.session, showHeading: true).frame(maxWidth: .infinity, alignment: .leading)
                            StorebenchCollection(items: snapshot.apps, title: { $0.name }, subtitle: { $0.account.name }, icon: appIcon, empty: "No apps yet. Connect an Apple account from Settings.") { row in
                                StorebenchDivider()
                                ConnectedAppCard(row: row, session: model.session, unavailable: unavailable, openApp: { openSource(row, $0) }, recover: { recover(row, $0) }, changed: { Task { await load(context) } })
                                    .id(row.id + "/" + row.accountToken)
                            }
                        }
                    }
                }
                StorebenchTextSlot(text: navigationMessage, height: 48, font: .sbCallout, color: StorebenchTheme.muted, live: true)
            }.modifier(StorebenchPageContent())
        }
        .task(id: section) {
            let id = UUID(); context = id; loading = false
            if snapshot == nil { snapshot = history?.rememberedRead("library-overview", as: LibraryOverview.Snapshot.self) }
            await StorebenchPolling.repeating(every: .seconds(2), while: { context == id }) { await load(id) }
        }
        // App Store Connect is read in the background for each saved plan, so a version Apple already released never stays listed as being prepared.
        .task(id: snapshot?.releases.map(\.plan.token) ?? []) { await checkPlans() }
        .onDisappear { context = UUID(); readGate.end() }
        .trackUnsavedChanges(false, busy: loading)
    }
    private func appIcon(_ row: ConnectedApps.Row) -> AnyView {
        AnyView(AppIconView(accountId: row.account.id, appId: row.app.id, name: row.name, session: unavailable ? nil : model.session).id(row.id + "/" + row.accountToken))
    }
    private func navigate(_ row: ConnectedApps.Row, section: AppNavigation.Section, plan: ReleasePlan? = nil) {
        guard !unavailable, !loading, let destination = try? LibraryOverview.Destination(row: row, section: section, plan: plan) else { return }
        openApp(destination)
    }
    private func checkPlans(fresh: Bool = false) async {
        guard let session = model.session else { return }
        await session.refreshReleaseOverviews(maxAge: fresh ? 0 : 60)
        guard !Task.isCancelled, model.session === session else { return }
        await load(context, wait: true)
    }
    private func load(_ id: UUID, wait: Bool = false) async {
        while wait && readGate.active {
            guard context == id, !Task.isCancelled else { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard context == id, !Task.isCancelled, !readGate.active, let session = model.session else { return }
        let ticket = readGate.begin(); if snapshot == nil { loading = true }
        defer { if readGate.accepts(ticket) { readGate.end() }; if context == id { loading = false } }
        do {
            let next = try await session.libraryOverview()
            guard context == id, !Task.isCancelled, model.session === session else { return }
            if snapshot != next { snapshot = next }; failed = false
            history?.rememberRead(next, "library-overview")
        } catch {
            guard context == id, !Task.isCancelled, model.session === session else { return }
            failed = true
        }
    }
}
