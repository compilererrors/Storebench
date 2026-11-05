import AppKit
import StorebenchCore
import SwiftUI
import UniformTypeIdentifiers

/// Shared Sales/ Pricing reporting controls; all file operations affect only the local report history.
@MainActor struct SalesReportsView: View {
    let account: Account, app: Account.App, session: WorkspaceSession?
    var blocked = false
    let onChanged: () async -> Void
    @FocusState private var periodFocused: Bool
    @State private var records: [SalesRecord] = []
    @Environment(\.confirmDestructive) private var confirm
    @State private var source: ReportingSource = .reporter
    @State private var reportingReady = false
    @State private var reportingBusy = false
    @State private var failed = false
    @State private var working = false
    @State private var periods = ViewPeriods()
    @State private var endingDay = PeriodDates.date(SalesReports.latestCompletedDay())!
    @State private var chosen: URL?
    @State private var issueCode: String?
    @State private var downloadIssue: String?
    @State private var status = ""
    @State private var page = 1
    @State private var operation: Task<Void, Never>?
    @State private var operationId: UUID?
    @State private var loadId = UUID()
    @State private var downloadJob: SalesDownloadJob?
    @State private var jobReadFailed = false
    @State private var refreshedJobId: String?
    @State private var pageSize = 20
    private var downloadRunning: Bool { downloadJob?.isActive == true }
    private var unavailable: Bool { blocked || working || reportingBusy || downloadRunning || session == nil }
    private var pages: Int { max(1, (records.count + pageSize - 1) / pageSize) }
    private var visible: [SalesRecord] { Array(records.reversed().dropFirst((min(page, pages) - 1) * pageSize).prefix(pageSize)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ReportingSetupView(account: account, app: app, session: session, source: $source, disabled: blocked || working || downloadRunning,
                               onReady: { reportingReady = $0 }, onBusy: { reportingBusy = $0 }, onUseFile: { choose() })
            Card(title: "Download sales reports", subtitle: "Daily Summary Sales Reports are saved locally. Days Apple has not delivered stay unknown.", help: "sales") {
                StorebenchCardSection(title: "Completed reporting days") {
                StorebenchFormGrid {
                StorebenchDateField("Ending day (Pacific reporting date)", selection: $endingDay, in: ...PeriodDates.date(SalesReports.latestCompletedDay())!, displayedComponents: .date)
                    .reportFocus("sales-download-period", available: !unavailable, focused: $periodFocused)
                    .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!).storebenchWorking(unavailable)
                PeriodDaysField(title: "Download completed reporting days", value: periods.daysBinding(.salesDownload, session: session)).storebenchWorking(unavailable)
                }
                }
                StorebenchActionGroup { downloadActions }
                if !reportingReady { Text("Connect reporting above, or import a report file, to update these figures.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted) }
                downloadProgress
                RecoveryActions(code: downloadIssue ?? (jobReadFailed ? "SB-REPORT-JOB" : downloadJob?.code), showMessage: true)
            }.id("sales-reports")
            Card(title: "Sales report file", subtitle: "Import an Apple Summary Sales Report or Storebench CSV. No Reporter connection or vendor number is needed.") {
                StorebenchActionGroup { fileActions }
                ScrollView { Text(chosen?.lastPathComponent ?? "No file selected").font(.sbCallout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(height: 44).accessibilityLabel("Selected report file")
                Text("CSV, TXT, TSV or GZ · 4 MB per file, 8 MB after decompression. Only this app's rows are saved. Summary CSV does not mark a day as checked by Apple.")
                    .font(.sbCaption).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
                if working { Button("Stop Waiting") { stop() }.storebenchWorking(blocked) }
                ScrollView { Text(status).font(.sbCallout).foregroundStyle(StorebenchTheme.muted).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(height: 64).accessibilityLabel("Sales report operation status")
                RecoveryActions(code: issueCode)
            }
            if failed {
                Card(title: "Saved report files could not be read", subtitle: "Existing reports are kept. Retry reading before exporting or removing a period.") {
                    StorebenchFormFooter {
                        Button("Read Saved Periods") { run { id in await load(id: id) } }.storebenchWorking(unavailable)
                    }
                }
            } else if !records.isEmpty {
                Card(title: "Saved sales periods", subtitle: "Sales and Pricing use the same saved reports. Removing a period affects only local history.") {
                    DisclosureGroup("Manage saved periods (\(records.count))") {
                        Button("Export Summary CSV") { export(nil, format: .summary) }.help("Export All Periods · Summary CSV").accessibilityLabel("Export All Periods · Summary CSV").storebenchWorking(unavailable)
                        StorebenchCollection(items: Array(records.reversed()).map { StorebenchCollectionEntry(id: $0.periodId, value: $0) }, title: { entry in let record = entry.value; return record.beginDate + " – " + record.endDate }, empty: "No saved sales periods yet. Download sales reports to save a period.") { entry in
                    let record = entry.value
                            VStack(alignment: .leading, spacing: 8) {
                                Text("\(record.beginDate) – \(record.endDate)\(record.noSales == true ? " · No sales" : "")").font(.sbHeadline)
                                StorebenchActionGroup { exportActions(record) }
                                Button("Remove Period…", role: .destructive) { remove(record) }.help("Remove Local Period").accessibilityLabel("Remove Local Period").storebenchWorking(unavailable)
                            }.padding(.vertical, 8)
                            StorebenchDivider()
                        }

                    }
                }
            }
        }
        .trackUnsavedChanges(chosen != nil, busy: working)
        .task(id: "\(account.id):\(app.id)") {
            loadId = UUID(); stop(); chosen = nil; records = []; failed = false; downloadJob = nil; downloadIssue = nil; jobReadFailed = false; refreshedJobId = nil
            let context = loadId
            await periods.load(session, scope: try? PeriodScope(accountId: account.id, appId: app.id)); if !Task.isCancelled { await load(); await readDownloadJob(context: context) }
        }
        .task(id: loadId) {
            let context = loadId
            await StorebenchPolling.repeating(every: .seconds(1), readFirst: false, while: { loadId == context }) {
                if downloadRunning { await readDownloadJob(context: context) }
            }
        }
        .onDisappear { loadId = UUID(); operationId = nil; operation?.cancel(); operation = nil }
    }

    private var downloadActions: some View {
        Group {
            if !jobReadFailed && reportingReady {
                Button { run { id in await download(id: id) } } label: { StorebenchBusyLabel("Download Reports", loading: downloadRunning ? "Downloading…" : "Working…", busy: working || downloadRunning) }.buttonStyle(StorebenchButtonStyle(.primary)).storebenchWorking(unavailable)
                    .help("Download the selected completed reporting days. Validated reports update local Sales history; missing reports remain unknown.")
            }
            Button("Use Latest Day") {
                if let date = PeriodDates.date(SalesReports.latestCompletedDay()) { endingDay = date }
            }.accessibilityLabel("Use Latest Completed Day").storebenchWorking(unavailable)
                .help("Set the ending day to the latest completed Pacific reporting date, then choose Download Reports.")
            Button(downloadRunning ? "Stop Download" : working ? "Stop, Use a File" : "Use a Report File") {
                if downloadRunning { Task { await cancelDownload() } } else { stop(); choose() }
            }.help(downloadRunning ? "Stop Download" : working ? "Stop and Use a Report File" : "Use a Report File").accessibilityLabel(downloadRunning ? "Stop Download" : working ? "Stop and Use a Report File" : "Use a Report File").storebenchWorking(blocked || reportingBusy || session == nil || downloadRunning && working)
        }
    }
    private var downloadProgress: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: Double(downloadJob?.checked ?? 0), total: Double(max(1, downloadJob?.total ?? 0))).accessibilityLabel("Sales download progress")
            ScrollView { Text(downloadProgressMessage).font(.sbCallout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(height: 88).accessibilityLabel("Saved Sales download status")
            StorebenchReadButton("Refresh Status") { await readDownloadJob(context: loadId) }.help("Refresh Download Status").accessibilityLabel("Refresh Download Status").storebenchWorking(blocked || working || session == nil)
        }
    }
    private var downloadProgressMessage: String {
        if jobReadFailed { return "Download status could not be verified. Refresh status before starting again. A download may still be running; saved reports are kept." }
        guard let job = downloadJob else { return "No saved Sales download. Started downloads keep their progress when you leave this view." }
        let prefix = "\(job.selection.beginDate) to \(job.selection.endDate) · \(job.checked) of \(job.total) days · \(job.withApp) app reports · \(job.noSales) without sales · \(job.withoutApp) without attributable rows · \(job.unavailable) unavailable. "
        switch job.state {
        case .running: return prefix + (job.phase == .saving ? "Saving the validated batch…" : "Downloading and checking reports…")
        case .complete:
            if let result = job.result, result.changes != nil { return prefix + AppSync.salesStatus(result.syncResult).detail }
            return prefix + "Report checking completed. Missing and unattributable reports stay unknown."
        case .failed: return prefix + (job.error ?? ReportingMessages.message("SB-REPORT-JOB"))
        case .cancelled: return prefix + "Download cancelled. Existing reports and completed saves are kept."
        }
    }
    private var fileActions: some View {
        Group {
            Button("Choose Report File…") { choose() }
            if chosen != nil {
                Button { run { id in await importFile(id: id) } } label: { StorebenchBusyLabel("Import Report", loading: "Working…", busy: working) }.buttonStyle(StorebenchButtonStyle(.primary))
                Button("Clear File") { if !unavailable { chosen = nil; issueCode = nil; status = "" } }
            }
        }.storebenchWorking(unavailable)
    }
    private func exportActions(_ record: SalesRecord) -> some View {
        Group {
            Button("Summary CSV") { export(record, format: .summary) }
            if record.source != nil {
                Button("Apple TXT") { export(record, format: .originalTxt) }
                Button("Apple GZ") { export(record, format: .originalGzip) }
                Button("Full CSV") { export(record, format: .originalCsv) }
            }
        }.storebenchWorking(unavailable)
    }

    private func run(_ action: @escaping @MainActor (UUID) async -> Void) {
        guard !unavailable else { return }
        let id = UUID(); operationId = id; working = true
        operation = Task {
            await action(id)
            if operationId == id { working = false; operationId = nil; operation = nil }
        }
    }
    private func stop() {
        guard working else { return }
        operation?.cancel(); operation = nil; operationId = nil; working = false
        issueCode = nil; status = "Stopped waiting. Any completed local save is kept; read the saved periods before retrying."
    }
    private func choose() {
        guard !blocked, !working, session != nil else { return }
        if chosen != nil, !EditorProtection.confirm(.confirmDiscard) { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.commaSeparatedText, .plainText, .gzip]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        chosen = url; issueCode = nil; status = "Choose Import Report to save this file locally."
    }
    private func load(id: UUID? = nil) async {
        guard let session else { return }
        let currentLoad = loadId
        do {
            let values = try await session.salesFileRecords(account: account, appId: app.id)
            guard loadId == currentLoad, !Task.isCancelled else { return }
            if id == nil || operationId == id { records = values; failed = false; page = min(page, pages) }
        } catch { if loadId == currentLoad, !Task.isCancelled, id == nil || operationId == id { failed = true } }
    }
    private func importFile(id: UUID) async {
        guard let session, let chosen else { return }
        do {
            let files = try await ReportFiles.readAsync([chosen], purpose: .sales)
            try Task.checkCancellation(); guard operationId == id else { return }
            let changes = try await session.importSalesFile(account: account, appId: app.id, data: files[0])
            guard operationId == id else { return }
            self.chosen = nil; issueCode = nil; status = "Saved locally: \(changes.added) new, \(changes.updated) updated, \(changes.unchanged) unchanged periods."
            await load(id: id); await onChanged()
        } catch { if operationId == id { issueCode = RecoveryIssue.sales(error); status = salesFileMessage(error) } }
    }
    private func download(id: UUID) async {
        guard let session else { return }
        downloadIssue = nil
        do {
            let selection = try SalesDownloadSelection(source: source, endDate: PeriodDates.text(endingDay), days: periods.days(.salesDownload))
            let result = try await session.startSalesDownload(account: account, appId: app.id, selection: selection)
            guard operationId == id else { return }
            downloadJob = result; jobReadFailed = false; issueCode = nil; status = "Following the saved Sales job. You can leave this view and return to its progress."
        } catch { if operationId == id { downloadIssue = RecoveryIssue.sales(error); status = salesFileMessage(error); await readDownloadJob(context: loadId) } }
    }
    private func readDownloadJob(context: UUID) async {
        guard let session else { return }
        do {
            let value = try await session.salesDownloadJob(account: account, appId: app.id)
            guard loadId == context, !Task.isCancelled else { return }
            downloadJob = value; jobReadFailed = false
            if let value, !value.isActive, refreshedJobId != value.id {
                refreshedJobId = value.id; await load()
                if loadId == context, !Task.isCancelled {
                    await onChanged()
                }
            }
        } catch { if loadId == context, !Task.isCancelled { jobReadFailed = true } }
    }
    private func cancelDownload() async {
        guard let session, let job = downloadJob, job.isActive, !blocked, !working else { return }
        let context = loadId; working = true
        do {
            _ = try await session.cancelSalesDownload(account: account, appId: app.id, id: job.id)
            if loadId == context { issueCode = nil; status = "Stop requested for this exact Sales job. Wait for its saved status before retrying." }
        } catch { if loadId == context { downloadIssue = RecoveryIssue.sales(error); status = salesFileMessage(error) } }
        if loadId == context { working = false; await readDownloadJob(context: context) }
    }
    private func export(_ record: SalesRecord?, format: SalesFileFormats.Format) {
        run { id in
            guard let session else { return }
            do {
                let data = try await session.exportSalesFile(account: account, appId: app.id, beginDate: record?.beginDate, endDate: record?.endDate, format: format)
                try Task.checkCancellation(); guard operationId == id else { return }
                let suffix = format == .originalGzip ? "txt.gz" : format == .originalTxt ? "txt" : "csv"
                let panel = NSSavePanel(); panel.allowedContentTypes = [format == .originalGzip ? .gzip : format == .originalTxt ? .plainText : .commaSeparatedText]
                panel.nameFieldStringValue = "sales-\(app.id)\(record.map { "-\($0.beginDate)-\($0.endDate)" } ?? "").\(suffix)"
                guard panel.runModal() == .OK, let url = panel.url, operationId == id else { return }
                try data.write(to: url, options: .atomic); issueCode = nil; status = "Exported the saved sales report."
            } catch { if operationId == id { issueCode = RecoveryIssue.sales(error); status = salesFileMessage(error) } }
        }
    }
    private func remove(_ record: SalesRecord) {
        guard !unavailable else { return }
        guard confirm(.removeReportPeriod, title: "Remove local sales period?", message: "Remove the saved report for \(record.beginDate) to \(record.endDate)? Other periods remain saved.", action: "Remove Local Period", keep: "Keep Report") else { return }
        run { id in
            guard let session else { return }
            do {
                try await session.removeSalesFilePeriod(account: account, appId: app.id, beginDate: record.beginDate, endDate: record.endDate)
                guard operationId == id else { return }
                issueCode = nil; status = "Removed the local sales period."; await load(id: id); await onChanged()
            } catch { if operationId == id { issueCode = RecoveryIssue.sales(error); status = salesFileMessage(error) } }
        }
    }
}

private extension SalesRecord { var periodId: String { "\(beginDate):\(endDate)" } }
private func salesFileMessage(_ error: Error) -> String {
    if let failure = error as? ReportJobFailure { return failure.message }
    if let failure = error as? SalesFileFailure { return failure.message }
    if let failure = error as? ReportFiles.Failure { return failure.message }
    if let failure = error as? SalesFailure { return failure.message }
    if let failure = error as? AccountFailure { return failure.message }
    if let failure = error as? CredentialAccessFailure { return failure.message }
    if error is CancellationError || (error as? URLError)?.code == .cancelled { return "Stopped waiting. Any completed local save is kept." }
    if let failure = error as? AppStoreConnectClient.Failure, case .status(let code) = failure, code == 401 || code == 403 { return "Apple did not accept this key for reporting. Use a Team key, Reporter or a report file." }
    if error as? ReporterClient.Failure == .expiredToken { return "The Reporter token has expired. Reconnect Reporter or import a report file." }
    return SalesFileFailure.storage.message
}
