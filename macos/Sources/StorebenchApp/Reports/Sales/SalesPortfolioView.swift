import StorebenchCore
import SwiftUI

struct SalesPortfolioView: View {
    let session: WorkspaceSession?
    let openApp: (String, String, SalesPresentation.Range?) -> Void
    @State private var apps: [SalesPortfolio.App] = []
    @State private var money: ReportMoney.Context?
    @State private var from = ""
    @State private var through = ""
    @State private var loading = false
    @State private var failed = false
    @State private var status = ""
    @State private var loadId = UUID()
    @Environment(\.navigationPresentation) private var history
    private struct Range: Equatable { var from, through: String }
    private struct Read { let apps: [SalesPortfolio.App], money: ReportMoney.Context?, status: String }
    private var range: SalesPresentation.Range? { try? .init(beginDate: from, endDate: through) }
    private var analysis: SalesPortfolio.Analysis? { range.flatMap { try? SalesPortfolio.analyze(apps, range: $0) } }
    var body: some View {
        let selected = analysis
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StorebenchPageHeader(title: "Sales across your apps", description: "Review the same reporting dates across all configured apps, then open an app for its country analysis.", eyebrow: "SALES AND TRENDS", actions: AnyView(
                    Button(loading ? "Reading…" : "Refresh Reports") { Task { await load() } }.help(loading ? "Reading…" : "Refresh Saved Reports").accessibilityLabel(loading ? "Reading…" : "Refresh Saved Reports").storebenchWorking(loading)
                ))
                if failed { Card(title: "Saved sales overview could not be read", subtitle: "Existing reports have not been changed. Refresh to retry.") { EmptyView() } }
                else if !apps.isEmpty {
                    if apps.contains(where: \.unavailable) { Text("Some app reports could not be read. Their coverage is unknown and their data is excluded.").foregroundStyle(StorebenchTheme.muted) }
                    if !from.isEmpty || !through.isEmpty {
                        Card(title: "Shared reporting range", subtitle: "Pacific date labels. Only whole saved periods count for each app.") {
                            HStack { StorebenchTextField("Start date · YYYY-MM-DD", text: $from); StorebenchTextField("End date · YYYY-MM-DD", text: $through) }
                        }
                        if let selected { summary(selected) } else { Text("Choose valid start and end dates in order.").foregroundStyle(StorebenchTheme.muted) }
                    }
                    StorebenchCollection(items: apps, title: { $0.title }, empty: "No apps with saved sales for these dates.") { app in
                        let row = selected?.rows.first { $0.id == app.id }
                        Card(title: app.title, subtitle: app.unavailable ? "Saved reports unavailable. Check local storage." : row.map { "\($0.paid) paid purchases · \($0.coveredDays)/\(selected?.requestedDays ?? 0) days covered · \($0.periods) periods" } ?? "No complete reports in this range.") {
                            AppIconView(accountId: app.accountId, appId: app.appId, name: app.title, session: session)
                            if row?.periods == 0 { Text("Open the app to download reports or import a file. Missing coverage remains unknown.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted) }
                            StorebenchFormFooter {
                                Button("View Sales") { openApp(app.accountId, app.appId, range) }.storebenchWorking(loading)
                            }
                        }
                    }
                } else if !loading { Text("Connect an account and select apps first.").foregroundStyle(StorebenchTheme.muted) }
                StorebenchFeedback(text: status, height: 40)
            }.modifier(StorebenchPageContent())
        }
        .task {
            if apps.isEmpty, let read = history?.rememberedRead("sales-portfolio", as: Read.self) { apps = read.apps; money = read.money; status = read.status }
            await load()
        }
        .historyValue("sales-portfolio", Binding(get: { Range(from: from, through: through) }, set: { from = $0.from; through = $0.through }))
        .onDisappear { loadId = UUID() }
        .trackUnsavedChanges(false, busy: loading)
    }
    private func summary(_ analysis: SalesPortfolio.Analysis) -> some View {
        let context = money ?? ReportMoney.Context(currency: "USD"), converted = ReportMoney.convert(analysis.proceeds, context: context)
        let complete = money != nil && analysis.moneyComplete && analysis.productsComplete && converted.complete
        return Card(title: "Sales portfolio", subtitle: "Proceeds keep their original currencies. Reference conversion does not confirm a payout.") {
            StorebenchMetricGrid {
            Fact(title: "Paid app purchases", value: String(analysis.paid))
            Fact(title: "Apps with complete coverage", value: "\(analysis.completeApps) / \(apps.count)", info: "Apps with a saved report for every day in the shared range.")
            Fact(title: "Estimated proceeds · \(context.currency)\(complete ? "" : " · Partial")", value: money == nil ? "—" : ReportMoney.label(converted.amount, currency: context.currency), info: "Reported proceeds converted to your display currency with dated reference rates. An estimate, not a payout.")
            Fact(title: "Saved report periods", value: String(analysis.rows.reduce(0) { $0 + $1.periods }))
            }
            Text(analysis.proceeds.map { "\($0.amount) \($0.currency)" }.joined(separator: " · ")).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text("Rate dates: \(converted.dates.isEmpty ? "same-currency amounts or no converted rates" : converted.dates.joined(separator: ", ")). Missing reports, product coverage and rates keep the estimate partial.").font(.sbCaption).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func load() async {
        guard !loading, let session else { return }; let id = UUID(); loadId = id; loading = true; defer { if loadId == id { loading = false } }
        do {
            let saved = try await session.salesPortfolio(); guard loadId == id, !Task.isCancelled else { return }
            apps = saved; failed = false
            let dates = saved.flatMap(\.periods).flatMap { [$0.beginDate, $0.endDate] }.sorted()
            if from.isEmpty, through.isEmpty { from = dates.first ?? ""; through = dates.last ?? "" }
            do {
                let context = try await session.portfolioMoney(apps: saved); guard loadId == id, !Task.isCancelled else { return }
                money = context; status = context.staleCurrencies.isEmpty ? "" : "Some reference currency rates are stale."
            } catch { guard loadId == id, !Task.isCancelled else { return }; money = nil; status = "Reference rates could not be read. Original amounts remain available." }
            history?.rememberRead(Read(apps: saved, money: money, status: status), "sales-portfolio")
        } catch { guard loadId == id, !Task.isCancelled else { return }; failed = true; money = nil; status = "The saved sales overview could not be read." }
    }
}
