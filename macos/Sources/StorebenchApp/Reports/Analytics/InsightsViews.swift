import StorebenchCore
import SwiftUI

let analyticsMeasures: [(String, String)] = [("first", "First-time downloads"), ("redownload", "Redownloads"), ("updates", "Updates"), ("restores", "Restores"),
                                                     ("impressions", "Impressions"), ("views", "Product page views"), ("get", "Get / Buy / Pre-order taps"), ("other", "Other interactions")]

struct AnalyticsView: View {
    let account: Account, app: Account.App, session: WorkspaceSession?
    @State private var periods: [AnalyticsPeriod] = []
    @State private var state = "loading"
    @State private var kind = "downloads"
    private let initialKind: String?
    @State private var level = "standard"
    @State private var granularity = "DAILY"
    @State private var contextId = UUID()
    var onPublish: () -> Void = {}
    var openLocalizations: (() -> Void)? = nil
    @State private var choices = ViewPeriods()
    @Environment(\.recoveryNavigation) private var recovery
    @Environment(\.navigationPresentation) private var history
    private struct Choices: Equatable { var kind, level, granularity: String }
    private var readKey: String { "analytics/\(account.id)/\(app.id)" }
    init(account: Account, app: Account.App, session: WorkspaceSession?, initialKind: String? = nil, onPublish: @escaping () -> Void = {}, openLocalizations: (() -> Void)? = nil) {
        self.account = account; self.app = app; self.session = session; self.initialKind = initialKind; self.onPublish = onPublish
        _kind = State(initialValue: initialKind ?? "downloads")
        self.openLocalizations = openLocalizations
    }
    private func load() async {
        let context = contextId
        do {
            let value = try await session?.analytics(accountId: account.id, appId: app.id) ?? []
            guard !Task.isCancelled, contextId == context else { return }
            periods = value; history?.rememberRead(value, readKey)
            if initialKind == nil, !value.contains(where: { $0.kind == kind && $0.level == level && $0.granularity == granularity }), let first = value.first {
                kind = first.kind; level = first.level; granularity = first.granularity
            }
            state = "ready"
        } catch { if !Task.isCancelled, contextId == context { state = "failed" } }
    }

    private var available: [AnalyticsPeriod] { periods.filter { $0.kind == kind && $0.level == level && $0.granularity == granularity } }
    private var latest: String { available.map(\.endDate).max() ?? "" }
    private var selected: [AnalyticsPeriod] {
        let range = try? choices.range(.analyticsRange).resolve(latest: latest)
        return available.filter { range?.contains($0.date, end: $0.endDate) ?? true }
    }
    private var reportFilters: some View {
        StorebenchFormGrid(maximumColumns: 3) {
            StorebenchPicker("Saved report", selection: $kind) { SelectionOption("Downloads", value: "downloads"); SelectionOption("Discovery and engagement", value: "engagement") }
            StorebenchPicker("Detail", selection: $level) { SelectionOption("Standard", value: "standard"); SelectionOption("Detailed", value: "detailed") }
            StorebenchPicker("Granularity", selection: $granularity) {
                SelectionOption("Daily", value: "DAILY")
                if kind != "downloads" || level != "standard" { SelectionOption("Weekly", value: "WEEKLY"); SelectionOption("Monthly", value: "MONTHLY") }
            }
        }.environment(\.fieldHintHeight, 0)
    }

    private var analysisFilters: some View {
        StorebenchCardSection(title: "Saved reports and activity dates", description: "These choices apply to the summary, breakdown, chart and top lists in this card. Activity dates use UTC; downloads use separate processing dates.") {
            reportFilters
            PeriodRangeField(choice: choices.rangeBinding(.analyticsRange, session: session), latest: latest)
            PeriodPreferencesNotice(periods: choices)
        }
    }
    @ViewBuilder private var downloadAction: some View {
        if session != nil && recovery.navigate != nil {
            Button {
                if let action = (try? ReportNavigation.downloads(.analytics))?.resolved(scope: recovery.scope) { recovery.navigate?(action) }
            } label: { StorebenchLabel("Download Reports…", icon: "refresh") }
                .help("Open Analytics downloads and check reports available from Apple. Analysis dates and saved figures are kept.")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if state == "failed" || (state == "ready" && periods.isEmpty) {
                Card(title: "Saved Analytics analysis", subtitle: "Choose downloaded reports and activity dates.", actions: AnyView(downloadAction)) { analysisFilters }
            }
            switch state {
            case "failed": Card(title: "Saved Analytics reports could not be read", subtitle: "Existing reports have not been changed.") { EmptyView() }
            case "ready" where periods.isEmpty: Card(title: "No Analytics reports yet", subtitle: "Import reports or download existing instances once Apple has prepared them.") { EmptyView() }
            case "ready":
                AnalyticsActivityView(periods: selected, kind: kind, openLocalizations: openLocalizations, filters: AnyView(analysisFilters), actions: AnyView(downloadAction))
            default: AnalyticsActivityView.placeholder(filters: AnyView(analysisFilters), actions: AnyView(downloadAction))
            }
            ReportContextView(kind: .analytics, coverage: state == "failed" ? .unavailable : state == "ready" ? .saved(periods.map(\.endDate)) : .loading)
            ReportTools(hasData: state == "ready" ? !periods.isEmpty : nil, area: .analytics) {
                AnalyticsReportsView(account: account, app: app, session: session, onChanged: { await load() }, onPublish: onPublish)
            }
        }
        .task(id: "\(account.id):\(app.id)") {
            contextId = UUID()
            if let read = history?.rememberedRead(readKey, as: [AnalyticsPeriod].self) { periods = read; state = "ready" } else { periods = []; state = "loading" }
            await choices.load(session, scope: try? PeriodScope(accountId: account.id, appId: app.id)); if !Task.isCancelled { await load() }
        }
        .historyValue("analytics", Binding(get: { Choices(kind: kind, level: level, granularity: granularity) }, set: { kind = $0.kind; level = $0.level; granularity = $0.granularity }))
        .onDisappear { contextId = UUID() }
        .onChange(of: kind) { if kind == "downloads" && level == "standard" { granularity = "DAILY" } }
        .onChange(of: level) { if kind == "downloads" && level == "standard" { granularity = "DAILY" } }
    }
}

struct ReviewsView: View {
    let account: Account, app: Account.App, session: WorkspaceSession?
    var blocked = false
    var onRelease: () -> Void = {}
    @State private var reviews: [CustomerReview] = []
    @State private var hasSnapshot = false
    @State private var state = "loading"
    @State private var downloading = false
    @State private var downloadIssue: String?
    @State private var status = ""
    @State private var evidence: Set<String> = []
    @State private var contextId = UUID()
    @State private var downloadJob: ReviewsDownloadJob?
    @State private var jobReadFailed = false
    @State private var refreshedJobId: String?
    @Environment(\.navigationPresentation) private var history
    private struct Read: Codable { let reviews: [CustomerReview], hasSnapshot: Bool }
    private var readKey: String { "reviews/\(account.id)/\(app.id)" }
    private var downloadRunning: Bool { downloadJob?.isActive == true }

    /// Downloads from App Store Connect and merges into the saved history; nothing is sent to Apple.
    private var downloadCard: some View {
        Card(title: "Download reviews", subtitle: "New and changed reviews are saved. Reviews Apple no longer returns stay saved.", help: "reviews") {
            StorebenchActionGroup { downloadActions }
            ProgressView().opacity(downloadRunning ? 1 : 0).frame(height: 16).accessibilityLabel("Review download progress").accessibilityHidden(!downloadRunning)
            ScrollView { Text(downloadProgressMessage).font(.sbCallout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(height: 88).accessibilityLabel("Saved review download status")
            RecoveryActions(code: downloadIssue ?? (jobReadFailed ? "SB-REPORT-JOB" : downloadJob?.code), showMessage: true)
            ScrollView { Text(status).font(.sbCallout).foregroundStyle(StorebenchTheme.muted).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(height: 44).accessibilityLabel("Review download operation status")
        }
    }

    private var downloadActions: some View {
        Group {
            if !jobReadFailed && session != nil {
                Button(downloadRunning ? "Download Running" : downloading ? "Working…" : "Download Reviews") { Task { await download() } }
                    .buttonStyle(StorebenchButtonStyle(.primary)).storebenchWorking(blocked || downloading || downloadRunning)
            }
            if downloadRunning && session != nil { Button("Stop Download") { Task { await stopDownload() } }.storebenchWorking(blocked || downloading) }
            if session != nil { Button("Refresh Status") { Task { await readDownloadJob(context: contextId) } }.help("Refresh Download Status").accessibilityLabel("Refresh Download Status").storebenchWorking(blocked || downloading) }
        }
    }
    private var downloadProgressMessage: String {
        if jobReadFailed { return "Download status could not be verified. Refresh status before starting again. A download may still be running; saved reviews are kept." }
        guard let job = downloadJob else { return "No saved review download. Started downloads keep their progress when you leave this view." }
        let prefix = "\(job.pages) pages · \(job.reviews) reviews checked. "
        switch job.state {
        case .running: return prefix + (job.phase == .saving ? "Saving validated reviews…" : "Downloading and checking reviews…")
        case .complete:
            guard let result = job.result else { return prefix + "Download completed." }
            return prefix + "\(result.added) new, \(result.updated) updated, \(result.unchanged) unchanged. " + (result.limited ? "Older pages may still be missing." : "Previously saved reviews are kept.")
        case .failed: return prefix + (job.error ?? ReportingMessages.message("SB-REPORT-JOB"))
        case .cancelled: return prefix + "Download cancelled. Existing reviews and completed saves are kept."
        }
    }

    private func download() async {
        guard let session, !blocked, !downloading, !downloadRunning, !jobReadFailed else { return }
        let context = contextId; downloading = true; downloadIssue = nil
        do {
            let job = try await session.startReviewsDownload(account: account, appId: app.id)
            guard contextId == context, !Task.isCancelled else { return }
            downloadJob = job; jobReadFailed = false; status = "Following the saved review job. You can leave this view and return to its progress."
        } catch { if contextId == context { downloadIssue = RecoveryIssue.reviews(error); status = "Review download could not start. Refresh status before retrying."; await readDownloadJob(context: context) } }
        if contextId == context { downloading = false }
    }
    private func loadReviews(context: UUID) async {
        do {
            let value = try await session?.savedReviewsFiles(account: account, appId: app.id).snapshot
            guard contextId == context, !Task.isCancelled else { return }; reviews = value?.reviews ?? []; hasSnapshot = value != nil; state = "ready"
            history?.rememberRead(Read(reviews: reviews, hasSnapshot: hasSnapshot), readKey)
        } catch { if contextId == context, !Task.isCancelled { state = "failed" } }
    }
    private func readDownloadJob(context: UUID) async {
        guard let session else { return }
        do {
            let value = try await session.reviewsDownloadJob(account: account, appId: app.id)
            guard contextId == context, !Task.isCancelled else { return }; downloadJob = value; jobReadFailed = false
            if let value, !value.isActive, refreshedJobId != value.id { refreshedJobId = value.id; await loadReviews(context: context) }
        } catch { if contextId == context, !Task.isCancelled { jobReadFailed = true } }
    }
    private func stopDownload() async {
        guard let session, let job = downloadJob, job.isActive, !blocked, !downloading else { return }
        let context = contextId; downloading = true; downloadIssue = nil
        do {
            _ = try await session.cancelReviewsDownload(account: account, appId: app.id, id: job.id)
            if contextId == context { status = "Stop requested for this exact review job. Wait for its saved status before retrying." }
        } catch { if contextId == context { downloadIssue = RecoveryIssue.reviews(error); status = "The stop request could not be confirmed. Refresh the existing download status." } }
        if contextId == context { downloading = false; await readDownloadJob(context: context) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            downloadCard
            ReviewsFilesView(account: account, app: app, session: session, blocked: blocked || downloading, refreshToken: refreshedJobId ?? "", onChanged: { await loadReviews(context: contextId) })
            switch state {
            case "failed": Card(title: "Saved reviews could not be read", subtitle: "Existing reviews have not been changed.") { EmptyView() }
            case "ready":
                if hasSnapshot { ReviewsDashboardView(reviews: reviews, onRelease: onRelease, evidence: $evidence) }
                else { Card(title: "No reviews saved yet", subtitle: "Download reviews or import a saved snapshot.") { EmptyView() } }
                ReviewThemesCard(account: account, app: app, session: session, reviews: reviews, evidence: $evidence)
            default: StorebenchPlaceholderCard(rows: 6)
            }
        }
        .task(id: "\(account.id):\(app.id)") {
            // The evidence chosen for a theme stays with this history entry; saved reviews last read show while they are read again.
            contextId = UUID(); downloadJob = nil
            jobReadFailed = false; refreshedJobId = nil; downloading = false; downloadIssue = nil
            if let read = history?.rememberedRead(readKey, as: Read.self) { reviews = read.reviews; hasSnapshot = read.hasSnapshot; state = "ready" } else { reviews = []; hasSnapshot = false; state = "loading" }
            let context = contextId; await loadReviews(context: context); if !Task.isCancelled { await readDownloadJob(context: context) }
        }
        .task(id: contextId) {
            let context = contextId
            await StorebenchPolling.repeating(every: .seconds(1), readFirst: false, while: { contextId == context }) {
                if downloadRunning { await readDownloadJob(context: context) }
            }
        }
        .historyValue("reviews-evidence", $evidence)
        .onDisappear { contextId = UUID(); downloading = false }
    }
}
