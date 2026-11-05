import StorebenchCore
import SwiftUI

struct ConnectedAppsView: View {
    let model: LibraryModel
    let navigationMessage: String
    let openApp: (ConnectedApps.Row, String?) -> Void
    let recover: (ConnectedApps.Row, RecoveryGuidance.Action) -> Void
    let connect: () -> Void
    @State private var rows: [ConnectedApps.Row] = []
    @Environment(\.navigationPresentation) private var history
    @State private var ready = false
    @State private var failed = false
    @State private var loading = false
    @State private var readGate = PresentationWork()
    @State private var context = UUID()
    @State private var message = ""

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                StorebenchPageHeader(title: "Apps", description: "Saved revisions and download progress across your configured apps. Missing reports remain unknown.", eyebrow: "YOUR WORKSPACE", help: "sync")
                actions
                if failed { Text("The saved library could not be read. Previously read cards remain here; refresh before starting another download.").foregroundStyle(StorebenchTheme.muted) }
                if ready, rows.isEmpty {
                    Card(title: "No apps connected yet", subtitle: "Connect App Store Connect to bring your apps into this workspace.") {
                        StorebenchFormFooter {
                            Button("Connect Account", action: connect).help("Connect Apple Account").accessibilityLabel("Connect Apple Account")
                        }
                    }
                }
                if !rows.isEmpty {
                    StorebenchCardList(padded: true) {
                        StorebenchCollection(items: rows, title: { $0.name }, subtitle: { $0.account.name }, icon: { row in
                            AnyView(AppIconView(accountId: row.account.id, appId: row.app.id, name: row.name, session: failed ? nil : model.session).id(row.id + "/" + row.accountToken))
                        }, empty: "No connected apps.") { row in
                            ConnectedAppCard(row: row, session: model.session, unavailable: failed, openApp: { openApp(row, $0) }, recover: { recover(row, $0) }, changed: { Task { await load(context) } })
                                .id(row.id + "/" + row.accountToken)
                            if row.id != rows.last?.id { StorebenchDivider() }
                        }
                    }
                } else if !ready && !failed && model.session != nil { appsPlaceholder }
                StorebenchTextSlot(text: navigationMessage.isEmpty ? message : navigationMessage, height: 48, font: .sbCallout, color: StorebenchTheme.muted, live: true)
            }.modifier(StorebenchPageContent())
        }
        .task(id: model.session.map { ObjectIdentifier($0) }) {
            let id = UUID(); context = id; loading = false
            if !ready, let read = history?.rememberedRead("connected-apps", as: [ConnectedApps.Row].self) { rows = read; ready = true }
            await StorebenchPolling.repeating(every: .seconds(2), while: { context == id }) { await load(id) }
        }
        .onDisappear { context = UUID(); readGate.end() }
    }
    private var appsPlaceholder: some View {
        StorebenchCardList(padded: true) { StorebenchLoadingStatus(message: "Reading your apps…", surface: false) }
    }
    private var actions: some View {
        AllAppsSyncButton(session: failed || !ready ? nil : model.session, additionalActions: AnyView(Group {
            StorebenchReadButton("Refresh Apps") { await model.reloadAccounts(); await load(context) }.help("Refresh Connected Apps").accessibilityLabel("Refresh Connected Apps").storebenchWorking(loading || model.session == nil)
                .shortcutAction(.refresh, enabled: !loading && model.session != nil) { await model.reloadAccounts(); await load(context) }
            if model.session != nil { Button("Connect Account", action: connect).help("Connect Apple Account").accessibilityLabel("Connect Apple Account") }
        }))
    }
    private func load(_ id: UUID) async {
        guard !readGate.active, let session = model.session else { return }
        let ticket = readGate.begin(); if !ready { loading = true }
        defer { if readGate.accepts(ticket) { readGate.end() }; if context == id { loading = false } }
        do {
            let next = try await session.connectedApps()
            guard context == id, !Task.isCancelled, model.session === session else { return }
            if rows != next { rows = next }; ready = true; failed = false; message = ""
            history?.rememberRead(next, "connected-apps")
        } catch {
            guard context == id, !Task.isCancelled, model.session === session else { return }
            failed = true; message = "Saved library status could not be confirmed. Refresh to retry."
        }
    }
}

struct ConnectedAppCard: View {
    let row: ConnectedApps.Row, session: WorkspaceSession?, unavailable: Bool
    let openApp: (String?) -> Void
    let recover: (RecoveryGuidance.Action) -> Void
    let changed: () -> Void
    @State private var expanded = false
    @State private var materialExpanded = false
    @State private var syncMounted = false
    @State private var materialMounted = false
    @State private var working = false
    @State private var message = ""
    @State private var context = UUID()
    @Environment(\.navigationPresentation) private var history
    @Environment(\.recoveryNavigation) private var parentRecovery
    @State private var historyOwner: NavigationPresentationContext?
    private struct DisclosureSnapshot { let sync: Bool, material: Bool }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StorebenchMetricGrid(maximumColumns: 3, minimumWidth: 260, workflow: true, spacing: 12) {
                StorebenchWorkflowCard(description: "\(row.account.name) · Apple ID \(row.app.id)\n\(row.historyLabel)", feedback: "", heading: {
                    StorebenchWorkflowHeading(title: row.name)
                }, action: {
                    Button { openApp(nil) } label: { StorebenchLabel("Open app", icon: "right", size: 14) }
                        .buttonStyle(StorebenchButtonStyle(.quiet, stretch: true)).storebenchWorking(working)
                        .opacity(unavailable || session == nil ? 0 : 1).allowsHitTesting(!unavailable && session != nil).accessibilityHidden(unavailable || session == nil)
                })
                StorebenchWorkflowCard(description: "Latest results for this app’s data sources.", feedback: working ? "Starting sync…" : message.isEmpty ? row.syncFeedback : message,
                    progress: row.sync?.isActive == true ? Double(row.sync?.counts.checked ?? 0) : nil, total: Double(row.sync?.counts.total ?? 7), accessory: true, heading: {
                    StorebenchWorkflowHeading(title: "Data sync", symbol: "refresh")
                }, action: {
                    HStack(spacing: 12) {
                        StorebenchDisclosureButton(isExpanded: $expanded) { Text(unavailable ? "Unavailable" : row.syncButtonLabel) }
                            .help(unavailable ? "Sync status unavailable" : row.syncLabel).accessibilityLabel(unavailable ? "Sync status unavailable" : row.syncLabel)
                        Button { if row.syncUnavailable { changed() } else { Task { await sync() } } } label: { StorebenchActivityIcon(size: 16, active: working || row.sync?.isActive == true) }
                            .buttonStyle(StorebenchButtonStyle(.secondary, size: .icon))
                            .storebenchWorking(working || (!row.syncUnavailable && !row.canSync))
                            .opacity(unavailable || session == nil ? 0 : 1).allowsHitTesting(!unavailable && session != nil).accessibilityHidden(unavailable || session == nil)
                            .accessibilityLabel(row.syncUnavailable ? "Refresh sync status" : row.needsRetry ? "Retry unfinished for " + row.name : "Sync data for " + row.name)
                            .accessibilityValue(working || row.sync?.isActive == true ? "Syncing" : "")
                            .help(row.syncUnavailable ? "Refresh sync status" : row.needsRetry ? "Retry unfinished sync" : "Sync app data")
                    }
                })
                StorebenchWorkflowCard(description: "Listing, versions, languages and media. Saved revisions stay local.", feedback: materialFeedback, heading: {
                    StorebenchWorkflowHeading(title: "App material", symbol: "screenshots")
                }, action: {
                    StorebenchDisclosureButton(isExpanded: $materialExpanded) { Text("App material tools") }
                })
            }
            if syncMounted || expanded {
                AppSyncCard(account: row.account, app: row.app, session: unavailable ? nil : session, changed: changed, openSource: { openApp($0) })
                    .padding(.top, 16).collectionVisibility(expanded)
            }
            if materialMounted || materialExpanded {
                MaterialImportCard(account: row.account, app: row.app, session: unavailable ? nil : session, changed: changed)
                    .padding(.top, 16).collectionVisibility(materialExpanded)
            }
        }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .environment(\.recoveryNavigation, RecoveryNavigation(scope: try? RecoveryGuidance.Scope(accountId: row.account.id, appId: row.app.id), navigate: { action in
            if action.target.requiresApp { recover(action) } else { parentRecovery.navigate?(action) }
        }))
        .onAppear { context = UUID(); working = false; restoreDisclosures() }
        .onDisappear { saveDisclosures(); context = UUID() }
        .onChange(of: expanded, initial: true) { if expanded { syncMounted = true }; saveDisclosures() }
        .onChange(of: materialExpanded, initial: true) { if materialExpanded { materialMounted = true }; saveDisclosures() }
        .onChange(of: history?.entry) { saveDisclosures(); restoreDisclosures() }
        .trackUnsavedChanges(false, busy: working)
    }
    private func restoreDisclosures() {
        historyOwner = history
        let saved = history.flatMap { $0.store.collection("sync-material:" + row.id, entry: $0.entry, as: DisclosureSnapshot.self) }
        expanded = saved?.sync ?? false
        materialExpanded = saved?.material ?? false
    }
    private func saveDisclosures() {
        guard let historyOwner else { return }
        historyOwner.store.saveCollection(DisclosureSnapshot(sync: expanded, material: materialExpanded), key: "sync-material:" + row.id, entry: historyOwner.entry)
    }
    private var materialFeedback: String {
        if row.materialUnavailable { return "Material status unavailable. Expand for recovery." }
        if let material = row.material { return "\(material.displayPhase) · \(material.completed) screenshots checked." }
        return "Each complete download saves a revision."
    }
    private func sync() async {
        guard !working, !unavailable, row.canSync, let session else { return }
        let id = context; working = true; message = ""; defer { if context == id { working = false } }
        do {
            try await session.validateConnectedApp(row)
            try Task.checkCancellation(); guard context == id else { return }
            _ = try await session.startSync(account: row.account, appId: row.app.id, mode: row.needsRetry ? .retry : .all)
            guard context == id, !Task.isCancelled else { return }; changed()
        } catch {
            guard context == id, !Task.isCancelled else { return }; message = "Sync could not start. Refresh its saved status and retry."; changed()
        }
    }
}
