import StorebenchCore
import SwiftUI

struct SalesView: View {
    let account: Account, app: Account.App, session: WorkspaceSession?
    var navigationRequest: ReportNavigation.SalesRequest? = nil
    var openSection: ((String) -> Void)? = nil
    var openReports: (() -> Void)? = nil
    @State private var readAt = Date()
    @State private var reports: [SalesPresentation.Period] = []
    @State private var loaded = false
    @State private var failed = false
    @State private var periods = ViewPeriods()
    @State private var money: ReportMoney.Context?
    @State private var moneyState = ""
    @State private var loadId = UUID()
    @State private var requestedRange: SalesPresentation.Range?
    @State private var chosenPeriod = "range"
    @Environment(\.recoveryNavigation) private var recovery
    @Environment(\.navigationPresentation) private var history
    @State private var restored = false
    private struct Choices: Equatable { var chosenPeriod: String; var requestedRange: SalesPresentation.Range? }
    private struct Read: Codable { let reports: [SalesPresentation.Period], readAt: Date, money: ReportMoney.Context?, moneyState: String }
    private var readKey: String { "sales/\(account.id)/\(app.id)" }

    private var latest: String { reports.last?.endDate ?? "" }
    private var range: SalesPresentation.Range? {
        SalesPresentation.selectedRange(reports, choice: periods.range(.salesRange), period: chosenPeriod, requested: requestedRange)
    }
    private var rangeBinding: Binding<PeriodRangeChoice> {
        Binding(get: { requestedRange.flatMap { try? PeriodDateRange(from: $0.beginDate, to: $0.endDate) }.map(PeriodRangeChoice.custom) ?? periods.range(.salesRange) },
                set: { requestedRange = nil; periods.choose(.salesRange, .range($0), session: session) })
    }
    private var reportBinding: Binding<String> {
        Binding(get: { chosenPeriod }, set: { value in
            guard chosenPeriod != value else { return }
            chosenPeriod = value; requestedRange = nil
            if let report = reports.first(where: { $0.id == value }), let dates = try? PeriodDateRange(from: report.beginDate, to: report.endDate) {
                periods.choose(.salesRange, .range(.custom(dates)), session: session)
            }
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if loaded && (failed || reports.isEmpty || range == nil) {
                Card(title: "Sales reports and dates", subtitle: "Download reports, then choose saved dates to analyze.", help: "report-availability", actions: AnyView(downloadAction)) { reportControls }
            }
            if failed { Card(title: "Saved reports could not be read", subtitle: "Existing reports have not been changed. Unavailable data is unknown.") { EmptyView() } }
            else if loaded && reports.isEmpty { Card(title: "No sales reports yet", subtitle: "Download or import reports below. Missing reports are not zero sales.") { EmptyView() } }
            else if loaded, let range { SalesAnalysisView(reports: reports, range: range, money: money, moneyState: moneyState, openSection: openSection, readAt: readAt, openReports: { openDownloads() }, filters: AnyView(reportControls), actions: AnyView(downloadAction)).id("sales-analysis-\(account.id)-\(app.id)") }
            else if loaded { Text("Choose valid reporting dates.").foregroundStyle(StorebenchTheme.muted) }
            else { SalesAnalysisView.placeholder(filters: AnyView(reportControls), actions: AnyView(downloadAction)) }
            ReportContextView(kind: .sales, coverage: failed ? .unavailable : loaded ? .saved(reports.map(\.endDate)) : .loading)
            ReportTools(hasData: loaded && !failed ? !reports.isEmpty : nil, area: .sales) {
                SalesReportsView(account: account, app: app, session: session, onChanged: { await load() })
            }
        }
        .historyValue("sales", Binding(get: { Choices(chosenPeriod: chosenPeriod, requestedRange: requestedRange) }, set: { chosenPeriod = $0.chosenPeriod; requestedRange = $0.requestedRange; restored = true }))
        .task(id: "\(account.id):\(app.id):\(navigationRequest?.id.uuidString ?? "saved")") {
            // A range requested by another view applies when the view opens; Back keeps the range restored for this entry instead.
            if let navigationRequest, !restored { requestedRange = navigationRequest.initialRange(current: try? RecoveryGuidance.Scope(accountId: account.id, appId: app.id)) }
            if !loaded, let read = history?.rememberedRead(readKey, as: Read.self) { reports = read.reports; readAt = read.readAt; money = read.money; moneyState = read.moneyState; loaded = true }
            await periods.load(session, scope: try? PeriodScope(accountId: account.id, appId: app.id)); if !Task.isCancelled { await load() }
        }
        .onDisappear { loadId = UUID() }
    }
    @ViewBuilder private var downloadAction: some View {
        if session != nil && recovery.navigate != nil {
            Button { openDownloads() } label: { StorebenchLabel("Download Reports…", icon: "refresh") }
                .buttonStyle(StorebenchButtonStyle(.primary))
                .help("Open Sales downloads, choose completed reporting days and download reports. Existing saved reports are kept.")
        }
    }
    private var reportControls: some View {
        VStack(alignment: .leading, spacing: StorebenchTheme.gap) {
                if loaded && !failed {
                    StorebenchAdaptiveText(text: SalesPresentation.freshness(reports, completedThrough: SalesReports.latestCompletedDay()).message, maximumHeight: 66, color: StorebenchTheme.muted)
                } else if !loaded { StorebenchLoadingStatus(message: "Reading saved reports…", surface: false) }
                StorebenchPicker("Saved report or date range", selection: reportBinding) {
                    SelectionOption("Date range", value: "range")
                    selectionOptions(reports) { SelectionOption("\($0.beginDate) – \($0.endDate)\($0.noSales ? " · No sales" : "")", value: $0.id) }
                }
                if chosenPeriod == "range" { PeriodRangeField(choice: rangeBinding, latest: latest) }
                PeriodPreferencesNotice(periods: periods)
        }
    }
    private func openDownloads() {
        if let openReports { openReports(); return }
        guard let target = try? ReportNavigation.downloads(.sales), let action = target.resolved(scope: recovery.scope) else { return }
        recovery.navigate?(action)
    }
    private func load() async {
        guard let session else { return }
        let id = UUID(); loadId = id
        if !loaded { moneyState = "Loading reference currency rates…"; money = nil }
        do {
            let saved = try await session.salesPresentation(account: account, appId: app.id)
            guard loadId == id, !Task.isCancelled else { return }; reports = saved; readAt = Date(); loaded = true; failed = false
            if chosenPeriod != "range", !saved.contains(where: { $0.id == chosenPeriod }) { chosenPeriod = "range" }
            if let currency = try? await session.displayCurrency(), loadId == id, !Task.isCancelled { money = .init(currency: currency) }
            do {
                let context = try await session.salesMoney(account: account, appId: app.id, periods: saved)
                guard loadId == id, !Task.isCancelled else { return }; money = context; moneyState = context.staleCurrencies.isEmpty ? "" : "Some reference rates are stale. Conversion remains informational."
            } catch { guard loadId == id, !Task.isCancelled else { return }; moneyState = "Reference rates could not be read. Original amounts and analysis export remain available." }
            history?.rememberRead(Read(reports: saved, readAt: readAt, money: money, moneyState: moneyState), readKey)
        } catch { guard loadId == id, !Task.isCancelled else { return }; failed = true; loaded = true; money = nil }
    }
}
