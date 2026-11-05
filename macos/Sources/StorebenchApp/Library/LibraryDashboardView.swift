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
    /// Each plan's version as App Store Connect last reported it; shown at once from the last read, then read again.
    @State private var planStates: [String: LibraryOverview.PlanState] = [:]
    /// Plans App Store Connect has finished with, such as a version Ready for Distribution; listed with their app under Apple's state.
    @State private var closedPlans: [LibraryOverview.Release] = []
    private var unavailable: Bool { failed || snapshot == nil }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                StorebenchPageHeader(title: section.rawValue, description: section == .history ? "Every successful import and local version draft is retained separately. Choose an app to compare its saved revisions." : "Track progress across your apps, continue a release and check what needs syncing.", eyebrow: section == .history ? "SAVED REVISIONS" : "AT A GLANCE", actions: AnyView(HStack {
                    Spacer(minLength: 0)
                    Button("Manage Apps", action: manageApps).buttonStyle(StorebenchButtonStyle(.quiet))
                }), help: section == .history ? "" : "sync")
                if failed { Text("The saved library could not be confirmed. Previously read information remains here; refresh before opening an app.").foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true) }
                if let snapshot {
                    if snapshot.apps.isEmpty {
                        Card(title: "Get started", subtitle: "Three steps to your first release. Nothing is sent to Apple until you approve a review.", help: "sync") {
                            StorebenchSetupStep(number: 1, title: "Connect your Apple account", detail: "Add an App Store Connect API key so Storebench can see your apps. You can also do this later from Settings.") {
                                StorebenchActionGroup { Button("Connect Account", action: connect).buttonStyle(StorebenchButtonStyle(.primary)).help("Connect Apple Account").accessibilityLabel("Connect Apple Account") }
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
                            Card(title: "Continue preparing", subtitle: "Version plans saved on this Mac. Open one to continue where you left off.", help: "versions") {
                                // A few plans show directly as cards; only a longer list gets the browsing controls.
                                if snapshot.releases.count <= 3 {
                                    ForEach(snapshot.releases) { release in releaseCard(release, embedded: true) }
                                } else {
                                    StorebenchCollection(items: snapshot.releases, title: { $0.title }, subtitle: { LibraryOverview.planDescription($0.plan, state: planStates[$0.id]) + "\nEdited " + LibraryOverview.timestamp($0.plan.updatedAt) },
                                                         icon: { appIcon($0.app) }, maximumColumns: 3, minimumWidth: 340, empty: "No release plans yet.",
                                                         activate: { release in if !unavailable && !loading { navigate(release.app, section: .release, plan: release.plan) } }, action: "Continue release") { _ in EmptyView() }
                                }
                            }
                        }
                        // Plans still being prepared come first; a version Apple has released is only noted after them.
                        if !closedPlans.isEmpty { closedCard }
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
            if planStates.isEmpty { planStates = history?.rememberedRead("library-plan-states", as: [String: LibraryOverview.PlanState].self) ?? [:] }
            await StorebenchPolling.repeating(every: .seconds(2), while: { context == id }) { await load(id) }
        }
        // App Store Connect is read in the background for each saved plan, so a version Apple already released never stays listed as being prepared.
        .task(id: snapshot?.releases.map(\.plan.token) ?? []) { await checkPlans() }
        .onDisappear { context = UUID(); readGate.end() }
        .shortcutAction(.refresh, enabled: !loading && model.session != nil, identity: section.rawValue) { await load(context) }
        .trackUnsavedChanges(false, busy: loading)
    }
    private func releaseCard(_ release: LibraryOverview.Release, embedded: Bool = false) -> some View {
        StorebenchNavigationCard(title: release.title, description: LibraryOverview.planDescription(release.plan, state: planStates[release.id]) + "\nEdited " + LibraryOverview.timestamp(release.plan.updatedAt), action: "Continue release", tile: !embedded, descriptionLines: 2, embedded: embedded, activate: { navigate(release.app, section: .release, plan: release.plan) }) {
            AppIconView(accountId: release.app.account.id, appId: release.app.app.id, name: release.title, session: unavailable ? nil : model.session)
        }.storebenchWorking(unavailable || loading)
    }
    /// Versions App Store Connect has finished with, under Apple's state when they share one, each with its app's icon.
    private var closedCard: some View {
        let states = closedPlans.map { AppStoreNames.state(planStates[$0.id]?.state ?? "") }
        return Card(title: Set(states).count == 1 && !states[0].isEmpty ? states[0] : "Finished at Apple",
                    subtitle: "Their plans are closed. The text, screenshots and drafts stay saved on this Mac.", help: "versions") {
            ForEach(Array(zip(closedPlans, states)), id: \.0.id) { release, state in
                StorebenchNavigationCard(title: release.title, description: state.isEmpty ? "Finished at Apple" : "\(state) at Apple", action: "Open App", descriptionLines: 2, embedded: true,
                                         activate: { navigate(release.app, section: .overview) }) {
                    AppIconView(accountId: release.app.account.id, appId: release.app.app.id, name: release.title, session: unavailable ? nil : model.session)
                }.storebenchWorking(unavailable || loading)
            }
        }
    }
    private func appIcon(_ row: ConnectedApps.Row) -> AnyView {
        AnyView(AppIconView(accountId: row.account.id, appId: row.app.id, name: row.name, session: unavailable ? nil : model.session).id(row.id + "/" + row.accountToken))
    }
    private func navigate(_ row: ConnectedApps.Row, section: AppNavigation.Section, plan: ReleasePlan? = nil) {
        guard !unavailable, !loading, let destination = try? LibraryOverview.Destination(row: row, section: section, plan: plan) else { return }
        openApp(destination)
    }
    private func checkPlans() async {
        guard let releases = snapshot?.releases, !releases.isEmpty, let session = model.session else { return }
        let result = await session.releasePlanStates(releases)
        guard !Task.isCancelled, model.session === session else { return }
        planStates.merge(result.states) { _, new in new }
        history?.rememberRead(planStates, "library-plan-states")
        if !result.closed.isEmpty {
            closedPlans = result.closed
            await load(context)
        }
    }
    private func load(_ id: UUID) async {
        guard !readGate.active, let session = model.session else { return }
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
