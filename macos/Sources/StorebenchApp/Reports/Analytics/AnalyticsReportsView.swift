import AppKit
import StorebenchCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor struct AnalyticsReportsView: View {
    let account: Account, app: Account.App, session: WorkspaceSession?
    let onChanged: () async -> Void
    let onPublish: () -> Void
    @FocusState private var reportFocused: Bool
    @State private var saved: AnalyticsFileState?
    @Environment(\.confirmDestructive) private var confirm
    @State private var review: AnalyticsFileReview?
    @State private var stale = false
    @State private var chosen: [URL] = []
    @State private var mode = "apple"
    @State private var kind = "downloads"
    @State private var level = "standard"
    @State private var granularity = "DAILY"
    @State private var fileKind = "downloads"
    @State private var fileLevel = "standard"
    @State private var fileGranularity = "DAILY"
    @State private var processingDate = ""
    @State private var segments = 1
    @State private var complete = false
    @State private var working = false
    @State private var failed = false
    @State private var issueCode: String?
    @State private var downloadIssue: String?
    @State private var status = ""
    @State private var through = Date()
    @State private var periods = ViewPeriods()
    @State private var page = 1
    @State private var reviewPage = 1
    @State private var operation: Task<Void, Never>?
    @State private var operationId: UUID?
    @State private var contextId = UUID()
    @State private var catalog: AnalyticsCatalog?
    @State private var checkedSelection = ""
    @State private var requestId = ""
    @State private var downloadJob: AnalyticsDownloadJob?
    @State private var jobReadFailed = false
    @State private var refreshedJobId: String?
    @State private var pageSize = 20
    private var downloadRunning: Bool { downloadJob?.state == .running }
    private var unavailable: Bool { working || downloadRunning || session == nil }
    private var savedPages: Int { max(1, ((saved?.partitions.count ?? 0) + pageSize - 1) / pageSize) }
    private var visible: [AnalyticsPartition] { Array((saved?.partitions ?? []).reversed().dropFirst((min(page, savedPages) - 1) * pageSize).prefix(pageSize)) }
    private var standardDownloads: Bool { kind == "downloads" && level == "standard" }
    private var selectionKey: String { [kind, level, granularity, PeriodDates.text(through), String(periods.days(.analyticsDownload)), requestId].joined(separator: ":") }
    private var availability: AnalyticsCatalog.Availability? { checkedSelection == selectionKey ? catalog?.availability : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            downloadCard.id("analytics-download")
            importCard
            if let review { reviewCard(review) }
            if failed {
                Card(title: "Saved Analytics reports could not be read", subtitle: "Existing reports are kept. Read saved reports before exporting or removing a period.") {
                    StorebenchFormFooter {
                        Button("Read Saved Reports") { run { id in await load(id: id) } }.storebenchWorking(unavailable)
                    }
                }
            } else if let saved, !saved.partitions.isEmpty { savedCard(saved) }
        }
        .trackUnsavedChanges(!chosen.isEmpty || review != nil, busy: working)
        .task(id: "\(account.id):\(app.id)") {
            contextId = UUID(); let context = contextId
            operation?.cancel(); operation = nil; operationId = nil; working = true
            chosen = []; review = nil; saved = nil; failed = false; issueCode = nil; status = ""; complete = false
            catalog = nil; checkedSelection = ""; requestId = ""
            downloadJob = nil; downloadIssue = nil; jobReadFailed = false; refreshedJobId = nil
            await periods.load(session, scope: try? PeriodScope(accountId: account.id, appId: app.id)); if !Task.isCancelled { await load() }
            if contextId == context { working = false }
            await StorebenchPolling.repeating(every: .milliseconds(500), while: { contextId == context }) { await readDownloadJob(context: context) }
        }
        .onDisappear { contextId = UUID(); operationId = nil; operation?.cancel(); operation = nil }
        .onChange(of: kind) { constrain(); invalidate() }
        .onChange(of: level) { constrain(); invalidate() }
        .onChange(of: granularity) { invalidate() }
        .onChange(of: fileKind) { constrainFile(); invalidate() }
        .onChange(of: fileLevel) { constrainFile(); invalidate() }
        .onChange(of: fileGranularity) { invalidate() }
        .onChange(of: processingDate) { invalidate() }
        .onChange(of: segments) { invalidate() }
        .onChange(of: complete) { invalidate() }
        .onChange(of: mode) { invalidate() }
        .onChange(of: through) { invalidate() }
        .onChange(of: requestId) { invalidate() }
        .onChange(of: periods.days(.analyticsDownload)) { invalidate() }
    }
    private func constrain() { if standardDownloads { granularity = "DAILY" } }
    private func constrainFile() { if fileKind == "downloads" && fileLevel == "standard" { fileGranularity = "DAILY" } }
    private func invalidate() { guard !working else { return }; review = nil; stale = false; issueCode = nil; status = "" }
    private var reportFields: some View {
        StorebenchFormGrid(maximumColumns: 3) {
            StorebenchPicker("Apple report", selection: $kind) { SelectionOption("App Store Downloads", value: "downloads"); SelectionOption("Discovery and Engagement", value: "engagement") }
                .reportFocus("analytics-download-report", available: !unavailable && review == nil, focused: $reportFocused)
            StorebenchPicker("Detail level", selection: $level) { SelectionOption("Standard", value: "standard"); SelectionOption("Detailed", value: "detailed") }
            StorebenchPicker("Granularity", selection: $granularity) {
                SelectionOption("Daily", value: "DAILY")
                if !standardDownloads { SelectionOption("Weekly", value: "WEEKLY"); SelectionOption("Monthly", value: "MONTHLY") }
            }
        }.storebenchWorking(unavailable)
    }
    private var downloadCard: some View {
        Card(title: "Download Analytics reports", subtitle: "Downloads existing report instances. Missing reports and privacy-limited rows are not zero activity.", help: "analytics") {
            if review == nil {
            StorebenchCardSection(title: "Report type") { reportFields }
            StorebenchCardSection(title: "Generation and reporting dates") {
            StorebenchFormGrid {
            StorebenchPicker("Generation request", selection: $requestId) {
                SelectionOption("Automatic selection", value: "")
                selectionOptions(catalog?.requests ?? []) { request in
                    SelectionOption("\(request.stopped ? "Stopped" : request.accessType == "ONGOING" ? "Ongoing" : "Historical snapshot") · \(String(request.id.prefix(32)))\(request.id.count > 32 ? "…" : "")", value: request.id).help(request.id)
                }
            }.accessibilityValue(requestId.isEmpty ? "Automatic selection" : requestId)
            StorebenchDateField("Processed through (UTC)", selection: $through, in: ...Date(), displayedComponents: .date).environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
            PeriodDaysField(title: "Download processing days", value: periods.daysBinding(.analyticsDownload, session: session))
            }.storebenchWorking(unavailable)
            }
            StorebenchActionGroup { downloadActions }
            } else {
                Text("Save or discard the Analytics import review before downloading reports.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                Text(availabilityMessage).font(.sbCallout).foregroundStyle(StorebenchTheme.muted).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 88).accessibilityLabel("Analytics report availability")
            PeriodPreferencesNotice(periods: periods)
            Text("Report generation is separate. Open Publish, choose Analytics reports, prepare the review and explicitly approve ongoing generation or a historical snapshot. Apple normally prepares the first reports within 1–2 days.")
                .font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
            downloadProgress
            RecoveryActions(code: downloadIssue ?? (jobReadFailed ? "SB-REPORT-JOB" : downloadJob?.code), showMessage: true)
            if review == nil && chosen.isEmpty {
                StorebenchFormFooter {
                    Button("Open Setup Review") { if !unavailable { onPublish() } }.help("Open Publish for Analytics Setup").accessibilityLabel("Open Publish for Analytics Setup").storebenchWorking(unavailable)
                }
            } else if review == nil {
                Text("Preview or clear the selected report files before opening Publish.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private var downloadActions: some View {
        Group {
            Button("Check Reports") { run { id in await checkCatalog(id: id) } }.help("Check Available Reports").accessibilityLabel("Check Available Reports").storebenchWorking(unavailable)
            if availability?.needsSetup == true {
                if chosen.isEmpty { Button("Set Up Reports") { if !unavailable { onPublish() } }.help("Set Up Ongoing Reports").accessibilityLabel("Set Up Ongoing Reports").buttonStyle(StorebenchButtonStyle(.primary)).storebenchWorking(unavailable) }
            } else if !jobReadFailed {
                Button { run { id in await download(id: id) } } label: { StorebenchBusyLabel("Download Reports", loading: downloadRunning ? "Downloading…" : "Working…", busy: working || downloadRunning) }.buttonStyle(StorebenchButtonStyle(.primary)).storebenchWorking(unavailable)
            }
            if availability?.needsSetup != true && availability?.latestProcessingDate != nil {
                Button("Use Latest Period") {
                    if !unavailable, let info = availability, let text = info.latestProcessingDate, let date = PeriodDates.date(text) {
                        through = date; requestId = info.requestId ?? ""; issueCode = nil; status = "Latest processing date selected. Check availability or download reports."
                    }
                }.storebenchWorking(unavailable)
            }
            Button(downloadRunning ? "Stop Download" : working ? "Stop, Use Files" : "Use Report Files") {
                if downloadRunning { Task { await cancelDownload() } } else { stop(); choose() }
            }.help(downloadRunning ? "Stop Download" : working ? "Stop and Use Report Files" : "Use Report Files").accessibilityLabel(downloadRunning ? "Stop Download" : working ? "Stop and Use Report Files" : "Use Report Files").storebenchWorking(session == nil || (downloadRunning && working))
        }
    }
    private var availabilityMessage: String {
        guard catalog != nil else { return "Choose Check Reports to find the processing dates Apple has prepared for this selection." }
        guard let info = availability else { return "Your selection changed. Choose Check Reports again to update availability." }
        let dates = info.latestProcessingDate.map { "Latest processing date: \($0). \(info.matchingInstances) matching instances. " } ?? ""
        return dates + (info.failure?.message ?? "Select the period, then download. Processing dates describe when Apple prepared a report; missing activity stays unknown.")
    }
    private var downloadProgress: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: Double(downloadJob?.completed ?? 0), total: Double(max(1, downloadJob?.total ?? 0)))
                .accessibilityLabel(downloadRunning ? "Analytics download progress" : "Latest Analytics download")
            ScrollView {
                Text(downloadProgressMessage).font(.sbCallout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 88).accessibilityLabel("Saved Analytics download status")
            StorebenchReadButton("Refresh Status") { await readDownloadJob(context: contextId) }.help("Refresh Download Status").accessibilityLabel("Refresh Download Status").storebenchWorking(working || session == nil)
        }
    }
    private var downloadProgressMessage: String {
        if jobReadFailed { return "Download status could not be verified. Refresh status before starting again. A download may still be running; saved reports are kept." }
        guard let job = downloadJob else { return "No saved Analytics download. Started downloads keep their progress when you leave this view or reopen the app." }
        let prefix = "\(job.selection.kind) · \(job.selection.level) · \(job.selection.granularity.lowercased()) · through \(job.selection.endDate) · \(job.selection.days) processing days. \(job.completed) of \(job.total) instances · \(job.segments) segments · \(job.bytes / 1024) KB. "
        switch job.state {
        case .running: return prefix + (job.phase == .discovering ? "Finding existing report instances…" : job.phase == .saving ? "Saving complete report instances…" : "Downloading and checking report segments…")
        case .complete: return prefix + (job.result.map { AppSync.analyticsStatus($0, processingDays: job.selection.days).detail } ?? "Download completed.")
        case .failed: return prefix + (job.error ?? ReportingMessages.message("SB-REPORT-JOB"))
        case .cancelled: return prefix + "Download cancelled. Previously saved data and completed saves are kept."
        }
    }
    private var importCard: some View {
        Card(title: "Import Analytics reports", subtitle: "Select every segment from one Apple report instance. Preview all replacements before saving locally.", help: "imports") {
            StorebenchPicker("Import format", selection: $mode) { SelectionOption("Apple report segments", value: "apple"); SelectionOption("Storebench Analytics JSON", value: "json") }.storebenchWorking(unavailable)
            StorebenchActionGroup { fileActions }
            if chosen.isEmpty { Text("No files selected").font(.sbCallout).frame(height: 44) }
            ForEach(Array(chosen.enumerated()), id: \.offset) { index, url in
                StorebenchTextSlot(text: url.lastPathComponent, height: 44, font: .sbCallout, color: nil).accessibilityLabel("Selected Analytics file \(index + 1)")
            }
            if mode == "apple" {
                StorebenchCardSection(title: "Report type for these files", description: "These choices describe the selected files. Download and saved-analysis selections are separate.") {
                    StorebenchFormGrid(maximumColumns: 3) {
                        StorebenchPicker("File report", selection: $fileKind) { SelectionOption("App Store Downloads", value: "downloads"); SelectionOption("Discovery and Engagement", value: "engagement") }
                        StorebenchPicker("File detail level", selection: $fileLevel) { SelectionOption("Standard", value: "standard"); SelectionOption("Detailed", value: "detailed") }
                        StorebenchPicker("File granularity", selection: $fileGranularity) {
                            SelectionOption("Daily", value: "DAILY")
                            if fileKind != "downloads" || fileLevel != "standard" { SelectionOption("Weekly", value: "WEEKLY"); SelectionOption("Monthly", value: "MONTHLY") }
                        }
                    }.storebenchWorking(unavailable)
                }
                StorebenchTextField("Processing date (UTC) · YYYY-MM-DD", text: $processingDate).storebenchWorking(unavailable)
                StorebenchStepper("Segments in this instance: \(segments)", value: $segments, in: 1...20).storebenchWorking(unavailable)
                if !chosen.isEmpty { Toggle("I selected every segment from the same report instance.", isOn: $complete).storebenchWorking(unavailable) }
                if !chosen.isEmpty && (!complete || processingDate.isEmpty) { Text("Enter the processing date and confirm that every segment is selected to preview these files.").font(.sbCaption).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true) }
            } else { Text("JSON retains original processing dates, detail levels and granularities. Preview validates its contents and configured app.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted) }
            Text("CSV, TXT, TSV, GZ or JSON · up to 20 files and 10 MB total after decompression. Only this app's rows are saved. Standard and detailed reports, and daily, weekly and monthly periods remain separate.")
                .font(.sbCaption).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
            if working { Button("Stop Waiting") { stop() } }
            StorebenchTextSlot(text: status, height: 88, font: .sbCallout, color: StorebenchTheme.muted, live: true).accessibilityLabel("Analytics report operation status")
            RecoveryActions(code: issueCode)
        }
        .dropDestination(for: URL.self) { urls, _ in guard !unavailable else { return false }; select(urls); return true }
    }
    private var fileActions: some View {
        Group {
            Button("Choose Report Files…") { choose() }
            if !chosen.isEmpty && (mode != "apple" || (complete && !processingDate.isEmpty)) {
                Button { run { id in await previewFiles(id: id) } } label: { StorebenchBusyLabel("Preview Selected Files", loading: "Working…", busy: working) }.buttonStyle(StorebenchButtonStyle(.primary))
            }
            if !chosen.isEmpty { Button("Clear Files") { if !unavailable, EditorProtection.confirm(.confirmDiscard) { chosen = []; review = nil; complete = false; issueCode = nil; status = "" } } }
        }.storebenchWorking(unavailable)
    }
    private func reviewCard(_ value: AnalyticsFileReview) -> some View {
        let pages = max(1, (value.changes.count + pageSize - 1) / pageSize), changes = Array(value.changes.dropFirst((min(reviewPage, pages) - 1) * pageSize).prefix(pageSize))
        return Card(title: "Review Analytics import", subtitle: "Compare processing dates, rows and activity. Identical and older periods retain the saved data.") {
            StorebenchResultsPerPage(size: $pageSize).onChange(of: pageSize) { reviewPage = 1 }
            ForEach(changes) { change in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(change.date) · \(change.action.capitalized)").font(.sbHeadline)
                    Text("\(change.key)").font(.sbCaption).fixedSize(horizontal: false, vertical: true)
                    Text("Saved · \(change.beforeRows) rows · processed \(change.beforeProcessingDate ?? "not saved")").font(.sbCaption)
                    StorebenchTextSlot(text: change.beforeActivity.isEmpty ? "No saved partition" : change.beforeActivity, height: 56, font: .sbCallout, color: nil)
                    Text("Reviewed · \(change.afterRows) retained rows · incoming processed \(change.processingDate)").font(.sbCaption)
                    StorebenchTextSlot(text: change.afterActivity, height: 56, font: .sbCallout, color: nil)
                }
                StorebenchDivider()
            }
            HStack {
                if reviewPage > 1 { Button("Previous Page") { reviewPage = max(1, reviewPage - 1) } }
                Text("Page \(min(reviewPage, pages)) of \(pages)")
                if reviewPage < pages { Button("Next Page") { reviewPage = min(pages, reviewPage + 1) } }
            }.storebenchWorking(unavailable)
            if stale { Text("This review needs a new baseline. Preview the selected files again before saving.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted) }
            let changesSaved = value.changes.contains(where: { $0.action == "added" || $0.action == "replaced" })
            if !changesSaved { Text("These files would not change any saved report. Discard the review to keep the saved data.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted) }
            HStack {
                if !stale && changesSaved {
                    Button { run { id in await save(value, id: id) } } label: { StorebenchBusyLabel("Save Reviewed Import", loading: "Working…", busy: working) }.buttonStyle(StorebenchButtonStyle(.primary))
                }
                Button("Discard Review") { if !unavailable { review = nil; stale = false; issueCode = nil; status = "Review discarded. Saved reports are kept." } }
            }.storebenchWorking(unavailable)
        }
    }
    private func savedCard(_ value: AnalyticsFileState) -> some View {
        Card(title: "Saved Analytics periods", subtitle: "JSON exports the complete history. Original exports retain the selected period's source rows.") {
            DisclosureGroup("Manage saved reports (\(value.partitions.count))") {
                Button("Export History JSON") { export(nil, format: .historyJson) }.help("Export Complete History · JSON").accessibilityLabel("Export Complete History · JSON").storebenchWorking(unavailable)
                StorebenchCollection(items: Array(value.partitions.reversed()).map { StorebenchCollectionEntry(id: $0.key, value: $0) }, title: { entry in let item = entry.value; return item.date + " · " + item.kind + " · " + item.level }, empty: "No saved Analytics periods yet. Download Analytics reports to save a period.") { entry in
                    let item = entry.value
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(item.date) – \(AnalyticsReports.periodEnd(item.date, granularity: item.granularity)) · \(item.kind) · \(item.level) · \(item.granularity.lowercased())").font(.sbHeadline).fixedSize(horizontal: false, vertical: true)
                        Text("Processed \(item.processingDate) · \(item.source.rows.count) app rows · \(item.segments) original segments").font(.sbCaption)
                        StorebenchActionGroup { exportActions(item) }
                        if review == nil { Button("Remove Period…", role: .destructive) { remove(item, saved: value) }.help("Remove Local Period").accessibilityLabel("Remove Local Period").storebenchWorking(unavailable) }
                    }.padding(.vertical, 8)
                    StorebenchDivider()
                }

                Button("Read Saved Reports") { run { id in await load(id: id); await onChanged() } }.storebenchWorking(unavailable)
            }
        }
    }
    private func exportActions(_ item: AnalyticsPartition) -> some View {
        Group {
            Button("Full CSV") { export(item, format: .sourceCsv) }
            Button("Apple TXT") { export(item, format: .sourceTxt) }
            Button("Apple GZ") { export(item, format: .sourceGzip) }
        }.storebenchWorking(unavailable)
    }
    private func run(_ action: @escaping @MainActor (UUID) async -> Void) {
        guard !unavailable else { return }; let id = UUID(); operationId = id; working = true
        operation = Task { await action(id); if operationId == id { operation = nil; operationId = nil; working = false } }
    }
    private func stop() { guard working else { return }; operation?.cancel(); operation = nil; operationId = nil; working = false; issueCode = nil; status = "Stopped waiting. Any completed local save is kept; read saved reports before retrying." }
    private func choose() {
        guard !working, session != nil else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.commaSeparatedText, .plainText, .gzip, .json]; panel.allowsMultipleSelection = mode == "apple"
        guard panel.runModal() == .OK else { return }; select(panel.urls)
    }
    private func select(_ urls: [URL]) {
        guard !unavailable, !urls.isEmpty else { return }
        if (!chosen.isEmpty || review != nil), !EditorProtection.confirm(.confirmDiscard) { return }
        guard urls.count <= 20 else { issueCode = nil; status = "Choose at most 20 segments."; return }
        chosen = urls; complete = false; review = nil; stale = false
        mode = urls.count == 1 && urls[0].lastPathComponent.lowercased().range(of: #"\.json(?:\.gz)?$"#, options: .regularExpression) != nil ? "json" : "apple"
        issueCode = nil; status = "Use Apple's instance metadata and complete segment count, then preview before saving."
    }
    private func input() async throws -> AnalyticsFileInput {
        let files = try await ReportFiles.readAsync(chosen, purpose: .reports)
        let metadata = mode == "apple" ? try AnalyticsMetadata(kind: fileKind, level: fileLevel, granularity: fileGranularity, processingDate: processingDate) : nil
        return AnalyticsFileInput(files: files, metadata: metadata, segments: segments, complete: complete)
    }
    private func load(id: UUID? = nil) async {
        guard let session else { return }; let context = contextId
        do {
            let value = try await session.savedAnalyticsFiles(account: account, appId: app.id)
            guard contextId == context, !Task.isCancelled, id == nil || operationId == id else { return }
            saved = value; failed = false; page = min(page, savedPages)
        } catch { if contextId == context, !Task.isCancelled, id == nil || operationId == id { saved = nil; failed = true } }
    }
    private func previewFiles(id: UUID) async {
        guard let session else { return }
        do {
            let files = try await input(); try Task.checkCancellation(); guard operationId == id else { return }
            let value = try await session.previewAnalyticsFiles(account: account, appId: app.id, input: files)
            guard operationId == id else { return }; review = value; reviewPage = 1; stale = false
            issueCode = nil; status = "\(value.changes.filter { $0.action == "added" }.count) to add, \(value.changes.filter { $0.action == "replaced" }.count) to replace, \(value.changes.filter { $0.action == "unchanged" || $0.action == "older" }.count) to skip. Compare before saving."
        } catch { if operationId == id { review = nil; issueCode = RecoveryIssue.analytics(error); status = analyticsReportMessage(error) } }
    }
    private func save(_ value: AnalyticsFileReview, id: UUID) async {
        guard let session else { return }
        do {
            let files = try await input(); try Task.checkCancellation(); guard operationId == id else { return }
            _ = try await session.saveAnalyticsFiles(value, input: files)
            guard operationId == id else { return }; review = nil; chosen = []; complete = false; issueCode = nil; status = "Saved locally. Identical and older periods were retained."
            await load(id: id); await onChanged()
        } catch { if operationId == id { stale = true; issueCode = RecoveryIssue.analytics(error); status = analyticsReportMessage(error) } }
    }
    private func download(id: UUID) async {
        guard let session else { return }
        downloadIssue = nil
        checkedSelection = ""
        do {
            let selected = try AnalyticsDownloadSelection(kind: kind, level: level, granularity: granularity, endDate: PeriodDates.text(through), days: periods.days(.analyticsDownload), requestId: requestId.isEmpty ? nil : requestId)
            let value = try await session.startAnalyticsDownload(account: account, appId: app.id, selection: selected)
            guard operationId == id else { return }
            downloadJob = value; jobReadFailed = false; issueCode = nil; status = "Following the saved download job. You can leave this view and return to its progress."
        } catch { if operationId == id { downloadIssue = RecoveryIssue.analytics(error); status = analyticsReportMessage(error); await readDownloadJob(context: contextId) } }
    }
    private func readDownloadJob(context: UUID) async {
        guard let session else { return }
        do {
            let value = try await session.analyticsDownloadJob(account: account, appId: app.id)
            guard contextId == context, !Task.isCancelled else { return }
            downloadJob = value; jobReadFailed = false
            if let value, value.state != .running, refreshedJobId != value.id {
                refreshedJobId = value.id; await load(); if contextId == context, !Task.isCancelled { await onChanged() }
                if value.state == .failed, ["SB-ANALYTICS-SETUP", "SB-ANALYTICS-INACTIVE"].contains(value.code ?? ""), !working, catalog == nil {
                    run { id in await checkCatalog(id: id) }
                }
            }
        } catch { if contextId == context, !Task.isCancelled { jobReadFailed = true } }
    }
    private func cancelDownload() async {
        guard let session, let job = downloadJob, job.state == .running, !working else { return }
        let context = contextId; working = true
        do {
            _ = try await session.cancelAnalyticsDownload(account: account, appId: app.id, id: job.id)
            if contextId == context { issueCode = nil; status = "Stop requested for this exact download. Completed saves are kept; wait for its saved status before retrying." }
        } catch { if contextId == context { downloadIssue = RecoveryIssue.analytics(error); status = analyticsReportMessage(error) } }
        if contextId == context { working = false; await readDownloadJob(context: context) }
    }
    private func checkCatalog(id: UUID) async {
        guard let session else { return }; let selection = selectionKey
        checkedSelection = ""
        do {
            let days = SalesReports.days(ending: PeriodDates.text(through), count: periods.days(.analyticsDownload))
            let value = try await session.availableAnalyticsCatalog(account: account, appId: app.id, kind: kind, processingDays: days,
                client: try await session.client(for: account), level: level, granularity: granularity, requestId: requestId.isEmpty ? nil : requestId)
            guard operationId == id, !Task.isCancelled, selectionKey == selection else { return }
            catalog = value; checkedSelection = selection; downloadIssue = nil; status = "Availability checked. No report files downloaded."
        } catch { if operationId == id { downloadIssue = RecoveryIssue.analytics(error); status = analyticsReportMessage(error) } }
    }
    private func export(_ item: AnalyticsPartition?, format: AnalyticsFileFormats.Format) {
        run { id in
            guard let session else { return }
            let panel = NSSavePanel(); panel.allowedContentTypes = [format == .historyJson ? .json : format == .sourceCsv ? .commaSeparatedText : format == .sourceGzip ? .gzip : .plainText]
            let suffix = format == .historyJson ? "json" : format == .sourceCsv ? "csv" : format == .sourceGzip ? "txt.gz" : "txt"
            panel.nameFieldStringValue = "analytics\(item.map { "-\($0.kind)-\($0.date)" } ?? "").\(suffix)"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try await session.writeAnalyticsFile(account: account, appId: app.id, key: item?.key, format: format, to: url)
                guard operationId == id else { return }; issueCode = nil; status = "Exported saved Analytics data."
            } catch { if operationId == id { issueCode = RecoveryIssue.analytics(error); status = analyticsReportMessage(error) } }
        }
    }
    private func remove(_ item: AnalyticsPartition, saved: AnalyticsFileState) {
        guard !unavailable, review == nil else { return }
        guard confirm(.removeReportPeriod, title: "Remove local Analytics period?", message: "Remove \(item.key)? Other datasets and periods remain saved; Apple is unchanged.", action: "Remove Local Period", keep: "Keep Period") else { return }
        run { id in
            guard let session else { return }
            do { try await session.removeAnalyticsFilePeriod(saved, key: item.key); guard operationId == id else { return }; issueCode = nil; status = "Removed the local period."; await load(id: id); await onChanged() }
            catch { if operationId == id { issueCode = RecoveryIssue.analytics(error); status = analyticsReportMessage(error) } }
        }
    }
}

private func analyticsReportMessage(_ error: Error) -> String {
    if let value = error as? ReportJobFailure { return value.message }
    if let value = error as? AnalyticsFailure { return value.message }
    if let value = error as? AnalyticsFileFailure { return value.message }
    if let value = error as? ReportFiles.Failure { return value.message }
    if let value = error as? ReportTables.ExportFailure { return value.message }
    if let value = error as? AccountFailure { return value.message }
    if let value = error as? CredentialAccessFailure { return value.message }
    if error is CancellationError || (error as? URLError)?.code == .cancelled { return "Stopped waiting. Any completed save is kept." }
    if let value = error as? AppStoreConnectClient.Failure, case .status(let code) = value, code == 401 || code == 403 { return AnalyticsFailure.access.message }
    return AnalyticsFailure.download.message
}
