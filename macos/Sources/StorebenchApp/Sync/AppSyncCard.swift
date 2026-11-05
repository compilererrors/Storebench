import StorebenchCore
import SwiftUI

struct AppSyncViewScope: Equatable {
    var visible = true
    let account: Account
    let appId: String
    let sessionId: ObjectIdentifier?
}

struct AppSyncCard: View {
    @Environment(\.collectionVisible) private var visible
    let account: Account, app: Account.App, session: WorkspaceSession?
    let changed: () -> Void, openSource: (String) -> Void
    @State private var job: SyncJob?
    @State private var activeSyncId: String?
    @State private var working = false
    @State private var unreadable = false
    @State private var message = ""
    @State private var pollingOwner: AppSyncViewScope?
    @State private var context = UUID()
    @State private var readRequest = UUID()
    private var active: Bool { job?.isActive == true }
    private var aggregateActive: Bool { activeSyncId != nil }
    private var items: [SyncItem] { job?.items ?? AppSync.pending() }

    var body: some View {
        let stoppingJob = activeSyncId
        return Card(title: "Sync app data", subtitle: "Downloads into local history. Financial reports keep their local review; app changes are approved in App Store changes.", help: "sync", actions: AnyView(
            StorebenchReadButton("Refresh Status") { await load(expected: context) }.storebenchWorking(working || session == nil).help("Read the latest saved progress. Does not start another download or contact Apple.")
        )) {
            if let steps = SyncSetupGuide.steps(job?.items) { setupGuide(steps) }
            StorebenchTextSlot(text: message.isEmpty ? summary : message, height: StorebenchTheme.measure("fieldHint"), font: .sbCallout, color: unreadable ? StorebenchTheme.color("color-danger") : StorebenchTheme.muted, live: true)
            StorebenchStatusList {
                ForEach(Array(items.enumerated()), id: \.element.key) { index, item in
                    StorebenchStatusRow(title: item.title, detail: item.displayDetail, separator: index < items.count - 1) {
                        StorebenchSyncBadge(state: item.state)
                    } action: {
                        Button("Open") { openSource(item.key) }
                            .help("Open " + item.title + " to check its data, setup and available reports.")
                            .accessibilityLabel("Open " + item.title)
                    } details: {
                        RecoveryActions(code: item.code, module: item.key == "finance" ? .finance : nil, compact: true)
                    }
                }
            }
            StorebenchFormFooter { actions }
        }
        .task(id: AppSyncViewScope(visible: visible, account: account, appId: app.id, sessionId: session.map { ObjectIdentifier($0) })) {
            let scope = AppSyncViewScope(account: account, appId: app.id, sessionId: session.map { ObjectIdentifier($0) })
            if pollingOwner != scope {
                context = UUID(); pollingOwner = scope
            job = nil; activeSyncId = nil; working = false; unreadable = false; message = ""
            }
            let expected = context
            guard visible else { return }
            await StorebenchPolling.repeating(every: .milliseconds(750), while: { context == expected }) { await load(expected: expected) }
        }
        .onDisappear { context = UUID() }
        .shortcutAction(.syncApp, enabled: !working && !aggregateActive && !unreadable && session != nil, identity: account.id + "/" + app.id) { await start(.all) }
        .shortcutAction(.retry, enabled: !working && !aggregateActive && !unreadable && job?.canRetry == true && session != nil, identity: account.id + "/" + app.id) { await start(.retry) }
        .shortcutAction(.refresh, enabled: !working && session != nil, priority: 20, identity: account.id + "/" + app.id) { await load(expected: context) }
        .shortcutAction(.stop, enabled: active && stoppingJob != nil && !working, identity: stoppingJob ?? "") {
            if let id = stoppingJob, activeSyncId == id { await stop(id) }
        }
    }
    private var actions: some View {
        Group {
            if !unreadable && session != nil {
                Button { Task { await start(.all) } } label: { StorebenchLabel(aggregateActive ? "Syncing…" : SyncJob.Mode.all.title, icon: "refresh", busy: working || aggregateActive) }.buttonStyle(StorebenchButtonStyle(.primary)).storebenchWorking(working || aggregateActive).help(SyncJob.Mode.all.help)
            }
            if active {
                Button("Stop") { if let id = activeSyncId { Task { await stop(id) } } }
                    .storebenchWorking(working || activeSyncId == nil).help("Stop this sync. Finished sources and previously saved data are kept.")
            } else if job?.canRetry == true && !unreadable && session != nil {
                Button(SyncJob.Mode.retry.title) { Task { await start(.retry) } }.storebenchWorking(working || aggregateActive).help(SyncJob.Mode.retry.help)
            }
            if !unreadable && session != nil {
                StorebenchMenu("More", icon: "settings") {
                    Button(SyncJob.Mode.refresh.title) { Task { await start(.refresh) } }.help(SyncJob.Mode.refresh.help)
                    Button("Check Setup") { Task { await setup() } }.help("Check API access and reporting connections. Does not download reports or set up Analytics generation.")
                }.storebenchWorking(working || aggregateActive)
            }
        }
    }
    @ViewBuilder private func setupGuide(_ steps: [SyncSetupGuide.Step]) -> some View {
        let first = steps.first { $0.state == .todo }?.id
        StorebenchCardSection(title: "Set up report sync") {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                StorebenchSetupStep(number: index + 1, title: step.title, detail: step.detail, done: step.state == .done) {
                    if step.state == .todo {
                        StorebenchActionGroup {
                            if step.id == "check" { if !unreadable && session != nil { Button(step.action) { Task { await setup() } }.buttonStyle(StorebenchButtonStyle(step.id == first ? .primary : .secondary)).storebenchWorking(working || aggregateActive) } }
                            else if step.id == "sync" { if !unreadable && session != nil { Button(step.action) { Task { await start(.all) } }.buttonStyle(StorebenchButtonStyle(step.id == first ? .primary : .secondary)).storebenchWorking(working || aggregateActive) } }
                            else if let source = step.source { Button(step.action) { openSource(source) }.buttonStyle(StorebenchButtonStyle(step.id == first ? .primary : .secondary)) }
                        }
                    }
                }
            }
        }
    }
    private var summary: String {
        guard let job else { return "No saved sync result. Missing activity stays unknown." }
        if job.statusOnly { return "Setup checked. Report data has not been downloaded by this check." }
        return SyncSourceSummary(job: job).text + (active ? " · \(job.counts.checked) of \(job.counts.total) checked" : " · Last sync " + LibraryOverview.timestamp(job.updatedAt))
    }
    private func label(_ state: SyncItem.State) -> String {
        switch state { case .pending: "Pending"; case .unchecked: "Unchecked"; case .running: "Syncing"; case .synced: "Synced"; case .partial: "Partial"; case .attention: "Attention"; case .waiting: "Waiting"; case .ready: "Ready"; case .failed: "Failed" }
    }
    private func load(expected: UUID) async {
        guard let session, context == expected else { return }
        let request = UUID(); readRequest = request
        do {
            let presentation = try await session.syncPresentation(account: account, appId: app.id)
            let next = presentation.status
            guard context == expected, readRequest == request, !Task.isCancelled else { return }
            let finished = job?.isActive == true && next?.isActive == false
            if job != next { job = next }; activeSyncId = presentation.activeJobId; unreadable = false
            if message.hasPrefix("Saved sync status could not be read.") { message = "" }
            if finished { changed() }
        } catch { if context == expected, readRequest == request, !Task.isCancelled { unreadable = true; message = "Saved sync status could not be read. Choose Refresh Status before starting another sync. Saved data is kept." } }
    }
    private func start(_ mode: SyncJob.Mode) async {
        guard let session, !working, !aggregateActive, !unreadable else { return }
        let expected = context; readRequest = UUID(); working = true; message = ""; defer { if context == expected { working = false } }
        do { let next = try await session.startSync(account: account, appId: app.id, mode: mode); if context == expected, !Task.isCancelled { readRequest = UUID(); job = next; activeSyncId = next.isActive ? next.id : nil } }
        catch { if context == expected, !Task.isCancelled { message = "Sync could not start. Reload the saved status and try again. Saved data is kept."; await load(expected: expected) } }
    }
    private func stop(_ id: String) async {
        guard let session, !working else { return }; let expected = context; readRequest = UUID(); working = true; defer { if context == expected { working = false } }
        do { let next = try await session.cancelSync(account: account, appId: app.id, id: id); if context == expected, !Task.isCancelled { readRequest = UUID(); job = next; message = "Stopping this sync. Finished sources and saved data are kept." } }
        catch { if context == expected, !Task.isCancelled { message = "This sync could not be stopped. Reload its status and try again." } }
    }
    private func setup() async {
        guard let session, !working, !active, !unreadable else { return }; let expected = context; readRequest = UUID(); working = true; message = ""; defer { if context == expected { working = false } }
        do { let next = try await session.refreshSyncSetup(account: account, appId: app.id); if context == expected, !Task.isCancelled { readRequest = UUID(); job = next } }
        catch { if context == expected, !Task.isCancelled { message = "Setup could not be checked. Check the account's API access and try again. Saved data is kept." } }
    }
}

struct AllAppsSyncButton: View {
    let session: WorkspaceSession?
    var showHeading = false
    var additionalActions: AnyView? = nil
    @State private var working = false
    @State private var status = ""
    @State private var context = UUID()
    @State private var activity: SyncActivitySummary?
    @State private var readRequest = UUID()
    @State private var readFailed = false
    private var active: Bool { (activity?.activeApps ?? 0) > 0 }
    private var progressVisible: Bool { working || activity?.fractionChecked != nil }
    private var progressLabel: String {
        if working { return "Starting app syncs…" }
        let label = activity?.progressLabel ?? "Reading sync results…"
        return readFailed ? "Last known: " + label : label
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showHeading {
                StorebenchHeader { heading } actions: { button }
            } else {
                StorebenchActionGroup(alignment: .trailing) { button; if let additionalActions { additionalActions } }
            }
            StorebenchTextSlot(text: feedback, height: 32, font: .sbCaption, color: StorebenchTheme.muted, live: true)
            ProgressView(value: working ? 0 : activity?.fractionChecked ?? 0, total: 1) {
                StorebenchTextSlot(text: progressLabel, height: 18, font: .sbCaption, color: StorebenchTheme.muted, live: true)
            }
            .progressViewStyle(StorebenchProgressStyle())
            .frame(height: 32)
            .opacity(progressVisible ? 1 : 0)
            .accessibilityLabel("All apps sync progress")
            .accessibilityValue(progressLabel)
            .accessibilityHidden(!progressVisible)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .task(id: session.map { ObjectIdentifier($0) }) {
                context = UUID(); let expected = context
                working = false; status = ""; activity = nil; readFailed = false
                await StorebenchPolling.repeating(every: .seconds(1), while: { context == expected }) { await loadActivity(expected: expected) }
            }
            .onDisappear { context = UUID() }
            .shortcutAction(.syncAll, enabled: !working && !active && session != nil) { await start() }
    }
    private var heading: some View {
        VStack(alignment: .leading, spacing: 4) {
            StorebenchTextSlot(text: "Data status", height: 22, font: .sbTitle3)
            StorebenchTextSlot(text: "Latest source results across your apps. Expand an app to see what needs attention.", height: 38, font: .sbCallout, color: StorebenchTheme.muted)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var feedback: String {
        if readFailed { return "Sync results could not be read. Open an app to refresh its status." }
        if working { return "Starting app syncs…" }
        return [activity?.text ?? "Reading sync results…", status].filter { !$0.isEmpty }.joined(separator: " · ")
    }
    @ViewBuilder private var button: some View {
        if session != nil {
            Button { Task { await start() } } label: { StorebenchLabel(working ? "Starting syncs…" : active ? "Syncing apps…" : "Sync all apps", icon: "refresh", busy: working || active) }
                .buttonStyle(StorebenchButtonStyle(.primary)).storebenchWorking(working || active)
                .help("Sync missing or updated data for every connected app. Reuses recent checks and saved reports; keeps local edits and does not publish changes.")
        }
    }
    private func loadActivity(expected: UUID) async {
        guard let session, context == expected else { return }
        let request = UUID(); readRequest = request
        do {
            let next = try await session.syncActivitySummary()
            guard context == expected, readRequest == request, !Task.isCancelled else { return }
            activity = next; readFailed = false
        } catch {
            guard context == expected, readRequest == request, !Task.isCancelled else { return }
            readFailed = true
        }
    }
    private func start() async {
        guard let session, !working, !active else { return }; let expected = context; working = true; status = ""; defer { if context == expected { working = false } }
        do { let result = try await session.startAllSync(); if context == expected, !Task.isCancelled { status = result.failed > 0 ? "\(result.failed) app syncs could not start" : "" } }
        catch { if context == expected, !Task.isCancelled { status = "App syncs could not be started. Open each app's Overview to check its status." } }
        await loadActivity(expected: expected)
    }
}
