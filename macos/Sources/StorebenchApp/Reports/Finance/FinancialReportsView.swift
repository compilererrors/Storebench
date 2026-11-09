import AppKit
import StorebenchCore
import SwiftUI
import UniformTypeIdentifiers

/// Finance downloads and files use an explicit local review; changing Apple still belongs to Publish.
@MainActor struct FinancialReportsView: View {
    let account: Account, app: Account.App, session: WorkspaceSession?
    let onChanged: () async -> Void
    @FocusState private var periodFocused: Bool
    private enum Review {
        case file(FinancialFileReview), download(FinancialDownload)
        var changes: [FinancialReports.Change] { switch self { case .file(let value): value.changes; case .download(let value): value.changes } }
    }
    @State private var saved: FinancialFileState?
    @Environment(\.confirmDestructive) private var confirm
    @State private var review: Review?
    @State private var staleReview = false
    @State private var chosen: [URL] = []
    @State private var regions: [String] = []
    @State private var complete = false
    @State private var source: ReportingSource = .reporter
    @State private var reportingReady = false
    @State private var reportingBusy = false
    @State private var working = false
    @State private var failed = false
    @State private var issueCode: String?
    @State private var downloadIssue: String?
    @State private var status = ""
    @State private var region = "ZZ"
    @State private var periods = ViewPeriods()
    @State private var fiscalYear = FinancialReports.latestClosedPeriod().year
    @State private var fiscalPeriod = FinancialReports.latestClosedPeriod().period
    @State private var page = 1
    @State private var reviewPage = 1
    @State private var operation: Task<Void, Never>?
    @State private var operationId: UUID?
    @State private var contextId = UUID()
    @State private var downloadJob: FinancialDownloadJob?
    @State private var jobReadFailed = false
    @State private var refreshedJobId: String?
    @State private var pageSize = 20
    private var downloadRunning: Bool { downloadJob?.isActive == true }
    private var unavailable: Bool { working || reportingBusy || downloadRunning || session == nil }
    private var savedPages: Int { max(1, ((saved?.reports.count ?? 0) + pageSize - 1) / pageSize) }
    private var visible: [FinancialReport] { Array((saved?.reports ?? []).reversed().dropFirst((min(page, savedPages) - 1) * pageSize).prefix(pageSize)) }
    private var jsonHint: Bool { chosen.count == 1 && chosen[0].lastPathComponent.lowercased().range(of: #"\.json(?:\.gz)?$"#, options: .regularExpression) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ReportingSetupView(account: account, app: app, session: session, source: $source, disabled: working || downloadRunning || review != nil,
                               onReady: { reportingReady = $0 }, onBusy: { reportingBusy = $0 }, onUseFile: { choose() })
            downloadCard.id("financial-download")
            importCard
            if let review { reviewCard(review) }
            if failed {
                Card(title: "Saved financial reports could not be read", subtitle: "Existing reports are kept. Read them before exporting or removing a period.") {
                    StorebenchFormFooter {
                        Button("Read Saved Reports") { run { id in await load(id: id) } }.storebenchWorking(unavailable)
                    }
                }
            } else if let saved, !saved.reports.isEmpty { managementCard(saved) }
        }
        .trackUnsavedChanges(!chosen.isEmpty || review != nil, busy: working)
        .task(id: "\(account.id):\(app.id)") {
            contextId = UUID(); operation?.cancel(); operationId = nil; operation = nil; working = true
            let context = contextId
            chosen = []; regions = []; complete = false; review = nil; saved = nil; failed = false; issueCode = nil; status = ""; downloadJob = nil; downloadIssue = nil; refreshedJobId = nil; jobReadFailed = false
            await periods.load(session, scope: try? PeriodScope(accountId: account.id, appId: app.id)); if !Task.isCancelled { await load(); await readDownloadJob(context: context); await readSyncedReview() }
            if contextId == context { working = false }
        }
        .task(id: contextId) {
            let context = contextId
            await StorebenchPolling.repeating(every: .seconds(1), readFirst: false, while: { contextId == context }) {
                if downloadRunning { await readDownloadJob(context: context) }
            }
        }
        .onDisappear { contextId = UUID(); operationId = nil; operation?.cancel(); operation = nil }
        .onChange(of: regions) { invalidate() }
        .onChange(of: complete) { invalidate() }
    }

    private var downloadCard: some View {
        Card(title: "Download financial reports", subtitle: "Apple's fiscal periods differ from calendar months. Downloaded reports are reviewed before saving locally.", help: "finance") {
            if review == nil {
            StorebenchCardSection(title: "Fiscal period and scope") {
                StorebenchFormGrid {
            StorebenchStepper("Apple fiscal year: \(fiscalYear)", value: $fiscalYear, in: 2001...(Calendar(identifier: .gregorian).component(.year, from: Date()) + 1))
            StorebenchPicker("Ending fiscal period", selection: $fiscalPeriod) { selectionOptions(1...12) { SelectionOption("Period \($0)", value: $0) } }
                .reportFocus("finance-download-period", available: !unavailable && review == nil, focused: $periodFocused)
            PeriodDaysField(title: "Download fiscal periods", value: periods.daysBinding(.financePeriods, session: session), maximum: 24, presets: [1, 3, 6, 12, 24], fiscal: true)
            StorebenchPicker("Report region", selection: $region) { selectionOptions(FinancialReports.downloadRegions) { SelectionOption(FinancialReports.regionName($0), value: $0) } }
                }.storebenchWorking(unavailable)
            }
            if !reportingReady { Text("Set up the Reporter connection above to download reports, or use a report file.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true) }
            StorebenchActionGroup { downloadActions }
            } else {
                Text("Save or discard the financial report review before downloading reports.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
            }
            StorebenchTextLink("Apple fiscal calendar", destination: URL(string: "https://appstoreconnect.apple.com/WebObjects/iTunesConnect.woa/wa/jumpTo?page=fiscalcalendar")!)
            downloadProgress
            RecoveryActions(code: downloadIssue ?? downloadRecoveryCode, module: .finance, showMessage: true)
            PeriodPreferencesNotice(periods: periods)
        }
    }
    private var downloadActions: some View {
        Group {
            if !jobReadFailed && reportingReady {
                Button { run { id in await download(id: id) } } label: { StorebenchBusyLabel("Download Reports", loading: downloadRunning ? "Downloading…" : "Working…", busy: working || downloadRunning) }.buttonStyle(StorebenchButtonStyle(.primary)).storebenchWorking(unavailable)
            }
            if chosen.isEmpty { Button("Read Synced Review") { run { id in await readSyncedReview(id: id) } }.storebenchWorking(unavailable) }
            Button(downloadRunning ? "Stop Download" : working ? "Stop, Use a File" : "Use a Report File") {
                if downloadRunning { Task { await cancelDownload() } } else { stop(); choose() }
            }.help(downloadRunning ? "Stop Download" : working ? "Stop and Use a Report File" : "Use a Report File").accessibilityLabel(downloadRunning ? "Stop Download" : working ? "Stop and Use a Report File" : "Use a Report File").storebenchWorking(reportingBusy || session == nil || downloadRunning && working)
        }
    }
    private var downloadProgress: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: Double(downloadJob?.completed ?? 0), total: Double(max(1, downloadJob?.total ?? 0))).accessibilityLabel("Financial download progress")
            ScrollView { Text(downloadProgressMessage).font(.sbCallout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(height: 88).accessibilityLabel("Saved financial download status")
            StorebenchReadButton("Refresh Status") { await readDownloadJob(context: contextId) }.help("Refresh Download Status").accessibilityLabel("Refresh Download Status").storebenchWorking(working || session == nil)
        }
    }
    private var downloadRecoveryCode: String? {
        if jobReadFailed { return "SB-REPORT-JOB" }
        if let code = downloadJob?.code { return code }
        if let job = downloadJob, job.state == .complete, let result = job.result, result.reports == 0 {
            if !result.unavailable.isEmpty { return "SB-REPORT-UNAVAILABLE" }
            if !result.noApp.isEmpty { return "SB-FINANCE-SCOPE" }
        }
        return nil
    }
    private var downloadProgressMessage: String {
        if jobReadFailed { return "Download status could not be verified. Refresh status before starting again. A download may still be running; saved reports are kept." }
        guard let job = downloadJob else { return "No saved financial download. Started downloads keep their progress when you leave this view." }
        let prefix = "Fiscal \(job.selection.year)-\(job.selection.period) · \(FinancialReports.regionName(job.selection.region)) · \(job.completed) of \(job.total) periods · \(job.bytes / 1024) KB. "
        switch job.state {
        case .running: return prefix + (job.phase == .preparing ? "Preparing the local review…" : "Downloading and checking reports…")
        case .complete: return prefix + "\(job.result?.reports ?? 0) downloaded periods; \(job.result?.noApp.count ?? 0) without attributable rows; \(job.result?.unavailable.count ?? 0) unavailable. Open any waiting review before saving. Missing periods stay unknown."
        case .failed: return prefix + (job.code.flatMap { NativeRecoveryCatalog.shared?.message($0, module: .finance) } ?? job.error ?? ReportingMessages.message("SB-REPORT-JOB"))
        case .cancelled: return prefix + "Download cancelled. Existing reports and any completed review are kept."
        }
    }

    private var importCard: some View {
        Card(title: "Import financial reports", subtitle: "Complete Apple files or Storebench JSON; no vendor number or key is needed for file import.", help: "imports") {
            StorebenchActionGroup { fileActions }
            if chosen.isEmpty { Text("No files selected").font(.sbCallout).frame(height: 44) }
            ForEach(Array(chosen.enumerated()), id: \.offset) { index, url in
                VStack(alignment: .leading, spacing: 6) {
                    StorebenchTextSlot(text: url.lastPathComponent, height: 44, font: .sbCallout, color: nil).accessibilityLabel("Selected report file \(index + 1)")
                    if !jsonHint {
                        StorebenchPicker("Report region · file \(index + 1)", selection: Binding(get: { index < regions.count ? regions[index] : "" }, set: { value in if index < regions.count { regions[index] = value } })) {
                            SelectionOption("Choose the report region", value: "")
                            SelectionOption(FinancialReports.regionName("ALL"), value: "ALL")
                            selectionOptions(FinancialReports.regions) { SelectionOption("\(FinancialReports.regionName($0)) · \($0)", value: $0) }
                        }.storebenchFormColumn().storebenchWorking(unavailable)
                    }
                }
            }
            if jsonHint { Text("JSON restores its original fiscal periods and report regions. Preview checks the file's contents.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted) }
            else if !chosen.isEmpty { StorebenchToggle("Each file is a complete report for the selected region and fiscal period.", isOn: $complete).storebenchWorking(unavailable) }
            Text("CSV, TXT, TSV, GZ or JSON · up to 20 files and 10 MB total after decompression. Only direct transactions for this app are saved. Summary, detailed and regional datasets remain separate. Compare amounts before replacing an exact fiscal period and region.")
                .font(.sbCaption).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
            if working { Button("Stop Waiting") { stop() } }
            StorebenchTextSlot(text: status, height: 80, font: .sbCallout, color: StorebenchTheme.muted, live: true).accessibilityLabel("Financial report operation status")
            RecoveryActions(code: issueCode, module: .finance)
        }
    }
    private var fileActions: some View {
        Group {
            Button("Choose Report Files…") { choose() }
            if !chosen.isEmpty { Button { run { id in await previewFiles(id: id) } } label: { StorebenchBusyLabel("Preview Selected Files", loading: "Working…", busy: working) }.buttonStyle(StorebenchButtonStyle(.primary)) }
            if !chosen.isEmpty { Button("Clear Files") { if !unavailable, EditorProtection.confirm(.confirmDiscard) { chosen = []; regions = []; complete = false; review = nil; issueCode = nil; status = "" } } }
        }.storebenchWorking(unavailable)
    }
    private func invalidate() { guard !working else { return }; review = nil; staleReview = false; issueCode = nil; status = "" }

    private func reviewCard(_ value: Review) -> some View {
        let changes = value.changes, pages = max(1, (changes.count + pageSize - 1) / pageSize)
        let visible = Array(changes.dropFirst((min(reviewPage, pages) - 1) * pageSize).prefix(pageSize))
        return Card(title: "Review financial reports", subtitle: "Compare each fiscal period and report scope before saving. Other periods and datasets are kept.") {
            StorebenchResultsPerPage(size: $pageSize).onChange(of: pageSize) { reviewPage = 1 }
            ForEach(visible) { change in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(change.label) · \(change.action.capitalized)").font(.sbHeadline).fixedSize(horizontal: false, vertical: true)
                    Text("Saved").font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
                    StorebenchTextSlot(text: change.before, height: 64, font: .sbCallout, color: nil)
                    Text("Reviewed report").font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
                    StorebenchTextSlot(text: change.after, height: 64, font: .sbCallout, color: nil)
                }
                StorebenchDivider()
            }
            HStack {
                if reviewPage > 1 { Button("Previous Page") { reviewPage = max(1, reviewPage - 1) } }
                Text("Page \(min(reviewPage, pages)) of \(pages)")
                if reviewPage < pages { Button("Next Page") { reviewPage = min(pages, reviewPage + 1) } }
            }.storebenchWorking(working)
            if staleReview { Text("This review needs a new baseline. Preview the selected files again, or discard the download and explicitly download again.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted) }
            if value.changes.allSatisfy({ $0.action == "unchanged" }) { Text("These reports match the saved reports. Discard the review to keep the saved data.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted) }
            StorebenchActionGroup { reviewActions(value) }
        }
    }
    private func reviewActions(_ value: Review) -> some View {
        Group {
            if !staleReview && !value.changes.allSatisfy({ $0.action == "unchanged" }) {
                Button { run { id in await save(value, id: id) } } label: { StorebenchBusyLabel("Save Reviewed Reports", loading: "Working…", busy: working) }.buttonStyle(StorebenchButtonStyle(.primary))
            }
            Button("Discard Review") { run { id in await discard(value, id: id) } }
        }.storebenchWorking(unavailable)
    }

    private func managementCard(_ value: FinancialFileState) -> some View {
        Card(title: "Saved financial periods", subtitle: "Export original source rows or the complete JSON history. Removal affects only local financial reports.") {
            DisclosureGroup("Manage saved reports (\(value.reports.count))") {
                Button("Export History JSON") { export(nil, format: .historyJson) }.help("Export Complete History · JSON").accessibilityLabel("Export Complete History · JSON").storebenchWorking(unavailable)
                StorebenchCollection(items: Array(value.reports.reversed()).map { StorebenchCollectionEntry(id: $0.key, value: $0) }, title: { entry in let record = entry.value; return record.beginDate + " – " + record.endDate + " · " + FinancialReports.regionName(record.region) }, empty: "No saved financial periods yet. Download financial reports to save a period.") { entry in
                    let record = entry.value
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(record.beginDate) – \(record.endDate) · \(FinancialReports.regionName(record.region))").font(.sbHeadline).fixedSize(horizontal: false, vertical: true)
                        StorebenchActionGroup { exportActions(record) }
                        if review == nil { Button("Remove Report…", role: .destructive) { remove(record, saved: value) }.help("Remove Local Report").accessibilityLabel("Remove Local Report").storebenchWorking(unavailable) }
                    }.padding(.vertical, 8)
                    StorebenchDivider()
                }

                Button("Read Saved Reports") { run { id in await load(id: id); await onChanged() } }.storebenchWorking(unavailable)
            }
        }
    }
    private func exportActions(_ report: FinancialReport) -> some View {
        Group {
            Button("Full CSV") { export(report, format: .sourceCsv) }
            Button("Apple TXT") { export(report, format: .sourceTxt) }
            Button("Apple GZ") { export(report, format: .sourceGzip) }
        }.storebenchWorking(unavailable)
    }

    private func run(_ action: @escaping @MainActor (UUID) async -> Void) {
        guard !unavailable else { return }
        let id = UUID(); operationId = id; working = true
        operation = Task { await action(id); if operationId == id { working = false; operationId = nil; operation = nil } }
    }
    private func stop() {
        guard working else { return }
        operation?.cancel(); operation = nil; operationId = nil; working = false
        issueCode = nil; status = "Stopped waiting. Any completed local save is kept; read saved reports before retrying."
    }
    private func choose() {
        guard !working, session != nil else { return }
        if (!chosen.isEmpty || review != nil), !EditorProtection.confirm(.confirmDiscard) { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.commaSeparatedText, .plainText, .gzip, .json]; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        guard panel.urls.count <= 20 else { issueCode = nil; status = "Choose at most 20 report files."; return }
        let urls = panel.urls, previous = review
        run { id in
            do { if case .download(let download)? = previous { try await session?.clearPendingFinancialDownload(download) } }
            catch { if operationId == id { issueCode = RecoveryIssue.finance(error); status = financialReportMessage(error) }; return }
            guard operationId == id else { return }
            review = nil; staleReview = false; chosen = urls; regions = urls.map { _ in urls.count == 1 ? "ALL" : "" }; complete = false
            issueCode = nil; status = "Choose Preview Selected Files, compare the amounts, then save the reviewed reports."
        }
    }
    private func input() async throws -> FinancialFileInput { FinancialFileInput(files: try await ReportFiles.readAsync(chosen, purpose: .reports), regions: regions, complete: complete) }
    private func readSyncedReview(id: UUID? = nil) async {
        guard let session else { return }
        let context = contextId
        do {
            let pending = try await session.pendingFinancialDownload(accountId: account.id, appId: app.id)
            guard contextId == context, !Task.isCancelled, id == nil || operationId == id, review == nil, chosen.isEmpty else { return }
            if let pending {
                review = .download(pending); reviewPage = 1; staleReview = false
                issueCode = nil; status = "Downloaded financial reports are ready for local review. Compare the fiscal dates and amounts before saving. \(pending.unavailable.count) periods remain unavailable; \(pending.noApp.count) without attributable app rows remain unknown."
            } else if id != nil { issueCode = nil; status = "No unexpired financial sync review is waiting. Download reports or choose a file." }
        } catch { if contextId == context, !Task.isCancelled, id == nil || operationId == id { issueCode = RecoveryIssue.finance(error); status = financialReportMessage(error) } }
    }
    private func discard(_ value: Review, id: UUID) async {
        do { if case .download(let download) = value { try await session?.clearPendingFinancialDownload(download) } }
        catch { if operationId == id { issueCode = RecoveryIssue.finance(error); status = financialReportMessage(error) }; return }
        guard operationId == id else { return }
        review = nil; staleReview = false; issueCode = nil; status = "Review discarded. Existing saved reports are kept."
    }
    private func load(id: UUID? = nil) async {
        guard let session else { return }
        let context = contextId
        do {
            let value = try await session.savedFinancialFiles(account: account, appId: app.id)
            guard contextId == context, !Task.isCancelled, id == nil || operationId == id else { return }
            saved = value; failed = false; page = min(page, savedPages)
        } catch { if contextId == context, !Task.isCancelled, id == nil || operationId == id { saved = nil; failed = true } }
    }
    private func previewFiles(id: UUID) async {
        guard let session else { return }
        do {
            let bytes = try await input(); try Task.checkCancellation(); guard operationId == id else { return }
            let value = try await session.previewFinancialFiles(account: account, appId: app.id, input: bytes)
            guard operationId == id else { return }
            review = .file(value); reviewPage = 1; staleReview = false
            issueCode = nil; status = "\(value.changes.filter { $0.action == "added" }.count) to add, \(value.changes.filter { $0.action == "replaced" }.count) to replace, \(value.changes.filter { $0.action == "unchanged" }.count) unchanged. \(value.noAppFiles) files without this app's rows were skipped. Review before saving."
        } catch { if operationId == id { issueCode = RecoveryIssue.finance(error); status = financialReportMessage(error); review = nil } }
    }
    private func download(id: UUID) async {
        guard let session else { return }
        downloadIssue = nil
        do {
            let selection = try FinancialDownloadSelection(json: .object([("source", .string(source.rawValue)), ("year", .number(Double(fiscalYear))),
                ("period", .number(Double(fiscalPeriod))), ("periods", .number(Double(periods.days(.financePeriods)))), ("region", .string(region))]))
            let value = try await session.startFinancialDownload(account: account, appId: app.id, selection: selection)
            guard operationId == id else { return }
            downloadJob = value; jobReadFailed = false; issueCode = nil; status = "Following the saved financial job. You can leave this view and return to its progress."
            if !value.isActive { await readDownloadJob(context: contextId) }
        } catch { if operationId == id { downloadIssue = RecoveryIssue.finance(error); status = financialReportMessage(error); await readDownloadJob(context: contextId) } }
    }
    private func readDownloadJob(context: UUID) async {
        guard let session else { return }
        do {
            let value = try await session.financialDownloadJob(account: account, appId: app.id)
            guard contextId == context, !Task.isCancelled else { return }
            downloadJob = value; jobReadFailed = false
            if let value, !value.isActive, refreshedJobId != value.id {
                refreshedJobId = value.id
                if value.state == .complete, value.result?.reviewId != nil { await readSyncedReview() }
                if contextId == context, !Task.isCancelled { await onChanged() }
            }
        } catch { if contextId == context, !Task.isCancelled { jobReadFailed = true } }
    }
    private func cancelDownload() async {
        guard let session, let job = downloadJob, job.isActive, !working else { return }
        let context = contextId; working = true
        do {
            _ = try await session.cancelFinancialDownload(account: account, appId: app.id, id: job.id)
            if contextId == context { issueCode = nil; status = "Stop requested for this exact financial job. Wait for its saved status before retrying." }
        } catch { if contextId == context { downloadIssue = RecoveryIssue.finance(error); status = financialReportMessage(error) } }
        if contextId == context { working = false; await readDownloadJob(context: context) }
    }
    private func save(_ value: Review, id: UUID) async {
        guard let session else { return }
        do {
            let changes: [FinancialReports.Change]
            switch value {
            case .file(let value):
                let bytes = try await input(); try Task.checkCancellation(); guard operationId == id else { return }
                changes = try await session.saveFinancialFiles(value, input: bytes)
            case .download(let value):
                changes = try await session.saveFinancial(value)
            }
            guard operationId == id else { return }
            review = nil; chosen = []; regions = []; complete = false; staleReview = false
            issueCode = nil; status = "Saved locally: \(changes.filter { $0.action == "added" }.count) added, \(changes.filter { $0.action == "replaced" }.count) replaced, \(changes.filter { $0.action == "unchanged" }.count) unchanged."
            await load(id: id); await onChanged()
        } catch { if operationId == id { issueCode = RecoveryIssue.finance(error); status = financialReportMessage(error); staleReview = true } }
    }
    private func export(_ report: FinancialReport?, format: FinancialFileFormats.Format) {
        run { id in
            guard let session else { return }
            do {
                let bytes = try await session.exportFinancialFile(account: account, appId: app.id, key: report?.key, format: format)
                try Task.checkCancellation(); guard operationId == id else { return }
                let suffix = format == .historyJson ? "json" : format == .sourceCsv ? "csv" : format == .sourceGzip ? "txt.gz" : "txt"
                let panel = NSSavePanel(); panel.allowedContentTypes = [format == .historyJson ? .json : format == .sourceCsv ? .commaSeparatedText : format == .sourceGzip ? .gzip : .plainText]
                panel.nameFieldStringValue = "financial\(report.map { "-\($0.beginDate)-\($0.endDate)-\($0.region)" } ?? "").\(suffix)"
                guard panel.runModal() == .OK, let url = panel.url, operationId == id else { return }
                try bytes.write(to: url, options: .atomic); issueCode = nil; status = "Exported the saved financial report."
            } catch { if operationId == id { issueCode = RecoveryIssue.finance(error); status = financialReportMessage(error) } }
        }
    }
    private func remove(_ report: FinancialReport, saved: FinancialFileState) {
        guard !unavailable, review == nil else { return }
        guard confirm(.removeReportPeriod, title: "Remove local financial report?", message: "Remove \(report.beginDate) to \(report.endDate), \(FinancialReports.regionName(report.region))? Other periods and report datasets remain saved.", action: "Remove Local Report", keep: "Keep Report") else { return }
        run { id in
            guard let session else { return }
            do {
                try await session.removeFinancialFilePeriod(saved, key: report.key)
                guard operationId == id else { return }
                issueCode = nil; status = "Removed the local financial report."; await load(id: id); await onChanged()
            } catch { if operationId == id { issueCode = RecoveryIssue.finance(error); status = financialReportMessage(error) } }
        }
    }
}

private func financialReportMessage(_ error: Error) -> String {
    if let value = error as? ReportJobFailure { return value.message }
    if let value = error as? FinanceFailure { return value.message }
    if let value = error as? FinancialFileFailure { return value.message }
    if let value = error as? ReportFiles.Failure { return value.message }
    if let value = error as? ReportTables.ExportFailure { return value.message }
    if let value = error as? AccountFailure { return value.message }
    if let value = error as? CredentialAccessFailure { return value.message }
    if error is CancellationError || (error as? URLError)?.code == .cancelled { return "Stopped waiting. Any completed local save is kept." }
    if let failure = error as? AppStoreConnectClient.Failure, case .status(let code) = failure, code == 401 || code == 403 { return FinanceFailure.access.message }
    if error as? ReporterClient.Failure == .expiredToken { return "The Reporter token has expired. Reconnect Reporter or import a report file." }
    return FinancialFileFailure.storage.message
}
