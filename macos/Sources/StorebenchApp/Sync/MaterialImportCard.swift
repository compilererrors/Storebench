import StorebenchCore
import SwiftUI

@MainActor struct MaterialImportCard: View {
    @Environment(\.collectionVisible) private var visible
    let account: Account, app: Account.App, session: WorkspaceSession?
    let changed: () -> Void
    /// Beside Sync app data, which starts the same import, the card shows only while an import runs or needs attention.
    var onlyWhenNeeded = false
    @State private var job: ImportJob?
    @State private var working = false
    @State private var readFailed = false
    @State private var status = ""
    @State private var issueCode: String?
    @State private var pollingOwner: AppSyncViewScope?
    @State private var context = UUID()
    @State private var refreshed: String?
    @State private var readRequest = UUID()

    private var needed: Bool {
        !onlyWhenNeeded || readFailed || !status.isEmpty || issueCode != nil || job.map { $0.isActive || $0.state == .failed || $0.code != nil } == true
    }
    var body: some View {
        Group {
            if needed { card } else { Color.clear.frame(height: 0).accessibilityHidden(true) }
        }
        .task(id: AppSyncViewScope(visible: visible, account: account, appId: app.id, sessionId: session.map { ObjectIdentifier($0) })) {
            let scope = AppSyncViewScope(account: account, appId: app.id, sessionId: session.map { ObjectIdentifier($0) })
            if pollingOwner != scope {
                context = UUID(); pollingOwner = scope
            job = nil; readFailed = false; status = ""; issueCode = nil; refreshed = nil; working = false
            }
            let expected = context
            guard visible else { return }
            await StorebenchPolling.repeating(every: .milliseconds(500), while: { context == expected }) { await read(expected: expected) }
        }
        .onDisappear { context = UUID() }
    }
    private var card: some View {
        Card(title: "Sync app material", subtitle: "Downloads app details, versions, languages and screenshots. Saves a new revision when Apple material changed; local drafts stay saved.", help: "sync") {
            StorebenchActionGroup { actions }
            StorebenchFeedback(text: message, height: StorebenchTheme.measure("fieldHint"))
                .accessibilityLabel("Saved app material import status")
            RecoveryActions(code: readFailed ? ImportFailure.status.code : issueCode ?? job?.code)
            Text("Started imports continue when you leave this view. An interrupted import checks its assigned saved revision before retrying.")
                .font(.sbCaption).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var actions: some View {
        Group {
            if !readFailed && session != nil {
                Button { Task { await start() } } label: { StorebenchLabel("Sync App Material", icon: "refresh", busy: working || job?.isActive == true) }
                    .frame(minWidth: 150).buttonStyle(StorebenchButtonStyle(.primary)).storebenchWorking(working || job?.isActive == true)
            }
            StorebenchReadButton("Refresh Import Status") { await read(expected: context) }.storebenchWorking(working || session == nil)
            if job?.isActive == true {
                Button("Stop Import") {
                    guard let job, job.isActive else { return }; Task { await stop(job.id) }
                }.storebenchWorking(working || session == nil)
            }
        }
    }
    private var message: String {
        if readFailed { return ImportFailure.status.message }
        if !status.isEmpty { return status }
        guard let job else { return status.isEmpty ? "No saved import job. Sync app material to download the current App Store listing." : status }
        let prefix = "\(job.displayPhase) · \(job.completed) screenshots checked. "
        switch job.state {
        case .running: return prefix + "Downloading into a local snapshot. You can leave this view and return to saved progress."
        case .cancelling: return prefix + "Waiting for this exact import to stop. Earlier saved revisions are kept."
        case .complete: return prefix + "Open History or the saved app views to read the revision."
        case .failed: return prefix + (job.error ?? ImportFailure.download.message)
        case .cancelled: return prefix + "Import cancelled. Earlier saved revisions and local drafts are kept."
        }
    }
    private func read(expected: UUID) async {
        guard let session, context == expected else { return }
        let request = UUID(); readRequest = request
        do {
            let saved = try await session.importJob(account: account, appId: app.id)
            guard context == expected, readRequest == request, !Task.isCancelled else { return }
            if saved?.id != job?.id { status = ""; issueCode = nil }
            job = saved; readFailed = false
            if let saved, saved.state == .complete, refreshed != saved.id { refreshed = saved.id; changed() }
        } catch { if context == expected, readRequest == request, !Task.isCancelled { readFailed = true } }
    }
    private func start() async {
        guard let session, !working, !readFailed else { return }
        let expected = context; readRequest = UUID(); working = true; status = ""; issueCode = nil
        do {
            let saved = try await session.startImport(account: account, appId: app.id)
            if context == expected, !Task.isCancelled { readRequest = UUID(); job = saved; readFailed = false }
        } catch { if context == expected { issueCode = ImportFailure(error).code; status = ImportFailure(error).message } }
        if context == expected { working = false; await read(expected: expected) }
    }
    private func stop(_ id: String) async {
        guard let session, !working else { return }
        let expected = context; readRequest = UUID(); working = true; status = ""; issueCode = nil
        do { _ = try await session.cancelImport(account: account, appId: app.id, id: id) }
        catch { if context == expected { issueCode = ImportFailure(error).code; status = ImportFailure(error).message } }
        if context == expected { working = false; await read(expected: expected) }
    }
}
