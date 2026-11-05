import StorebenchCore
import SwiftUI

/// File and download reviews remain local; presentation selects one financial dataset at a time.
struct FinanceView: View {
    let account: Account, app: Account.App, session: WorkspaceSession?
    var compareSales: ((ReportNavigation.SalesRequest) -> Void)? = nil
    @State private var periods: [FinancialPresentation.Period] = []
    @State private var money: ReportMoney.Context?
    @State private var moneyState = "loading"
    @State private var state = "loading"
    @State private var contextId = UUID()
    @State private var loadId = UUID()
    @Environment(\.navigationPresentation) private var history
    private struct Read: Codable { let periods: [FinancialPresentation.Period], money: ReportMoney.Context?, moneyState: String }
    private var readKey: String { "finance/\(account.id)/\(app.id)" }

    private func load() async {
        let context = contextId, id = UUID(); loadId = id
        if state != "ready" { money = nil; moneyState = "loading" }
        do {
            let reports = try await session?.financialReports(accountId: account.id, appId: app.id) ?? []
            let value = try FinancialPresentation.prepare(reports)
            guard !Task.isCancelled, contextId == context, loadId == id else { return }
            periods = value; state = "ready"
            if let session {
                do {
                    let currency = try await session.financialMoney(account: account, appId: app.id, periods: value)
                    guard !Task.isCancelled, contextId == context, loadId == id else { return }
                    money = currency; moneyState = "ready"
                } catch { if !Task.isCancelled, contextId == context, loadId == id { moneyState = "failed" } }
            } else { moneyState = "failed" }
            if contextId == context, loadId == id { history?.rememberRead(Read(periods: value, money: money, moneyState: moneyState), readKey) }
        } catch { if !Task.isCancelled, contextId == context, loadId == id { state = "failed" } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ReportContextView(kind: .finance, coverage: state == "failed" ? .unavailable : state == "ready" ? .saved(periods.map(\.endDate)) : .loading)
            switch state {
            case "failed": Card(title: "Saved financial reports could not be read", subtitle: "Read and validate saved reports before continuing.") { EmptyView() }
            case "ready" where periods.isEmpty: Card(title: "No financial reports yet", subtitle: "Import or download reports below. Missing reports are not zero proceeds.") { EmptyView() }
            case "ready": FinancialActivityView(periods: periods, money: money, moneyState: moneyState, compareSales: compareSales)
            default: FinancialActivityView.placeholder()
            }
            ReportTools(hasData: state == "ready" ? !periods.isEmpty : nil, area: .finance) {
                FinancialReportsView(account: account, app: app, session: session, onChanged: { await load() })
            }
        }
        .task(id: "\(account.id):\(app.id)") {
            contextId = UUID(); loadId = UUID()
            if let read = history?.rememberedRead(readKey, as: Read.self) { periods = read.periods; money = read.money; moneyState = read.moneyState; state = "ready" } else { periods = []; state = "loading" }
            await load()
        }
        .onDisappear { contextId = UUID(); loadId = UUID() }
    }
}
