import Foundation
import Testing
@testable import StorebenchCore

@Suite struct ReportNavigationTests {
    init() throws { _ = try TestIsolation.require() }
    let scope = try! RecoveryGuidance.Scope(accountId: "synthetic-account", appId: "1000000001")
    @Test func financeExactFiscalRangesAcrossAlternativeAndRegionalDatasetsMatchPrimary() throws {
        let fixture = try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/financial-presentation.json")))
        guard case .array(let periodJSON)? = fixture["periods"], case .array(let vectors)? = fixture["navigationCases"] else { throw FinanceFailure.format }
        let periods = try periodJSON.map(FinancialPresentation.Period.init); #expect(vectors.count >= 12)
        for vector in vectors {
            let basis = vector["basis"]!.text!, fiscal = vector["fiscal"]!.text!
            let dates = ReportNavigation.financialDates(periods, basis: basis), range = try ReportNavigation.financialSalesRange(periods, basis: basis, fiscal: fiscal)
            #expect(JSONText.array(dates.map { .string($0.dateKey) }) == vector["dates"])
            #expect((range?.json ?? .null) == vector["range"], "Exact Finance Sales range: \(basis) / \(fiscal)")
        }
        #expect(try ReportNavigation.financialSalesRange(periods, basis: "synthetic-absent", fiscal: "all") == nil)
    }
    @Test func contextualSalesRangesStayScopedAndRespectDirtyAndBusyNavigation() throws {
        let range = try SalesPresentation.Range(beginDate: "2026-01-04", endDate: "2026-01-31"), request = ReportNavigation.SalesRequest(scope: scope, range: range)
        let foreignAccount = try RecoveryGuidance.Scope(accountId: "other-synthetic", appId: scope.appId), foreignApp = try RecoveryGuidance.Scope(accountId: scope.accountId, appId: "1000000002")
        #expect(request.initialRange(current: scope) == range)
        #expect(request.initialRange(current: nil) == nil && request.initialRange(current: foreignAccount) == nil && request.initialRange(current: foreignApp) == nil)
        #expect(request.allowed(current: scope, decision: .ready))
        #expect(!request.allowed(current: scope, decision: .confirmDiscard) && request.allowed(current: scope, decision: .confirmDiscard, discardConfirmed: true))
        #expect(!request.allowed(current: scope, decision: .wait, discardConfirmed: true))
        #expect(!request.allowed(current: foreignAccount, decision: .ready, discardConfirmed: true))
        #expect(ReportNavigation.SalesRequest(scope: scope, range: nil).initialRange(current: scope) == nil)
        #expect(request.id != ReportNavigation.SalesRequest(scope: scope, range: range).id)
    }
    @Test func savedDataCollapsesOnlyTheInitialToolsAndExplicitChoicesAndRecoveryRemainVisible() throws {
        var loaded = ReportNavigation.Tools(); loaded.loaded(hasData: true); #expect(!loaded.expanded)
        loaded.toggle(); loaded.loaded(hasData: true); #expect(loaded.expanded)
        var firstImport = ReportNavigation.Tools(hasData: false); firstImport.loaded(hasData: true); #expect(firstImport.expanded)
        var earlyChoice = ReportNavigation.Tools(); earlyChoice.toggle(); earlyChoice.loaded(hasData: false); #expect(!earlyChoice.expanded)
        for area in [RecoveryGuidance.Target.Area.sales, .analytics, .finance] {
            let target = try ReportNavigation.downloads(area), action = try #require(target.resolved(scope: scope))
            var tools = ReportNavigation.Tools(hasData: true)
            #expect(tools.open(action, current: scope, area: area) && tools.expanded)
            tools.loaded(hasData: true); #expect(tools.expanded)
            tools.toggle(); #expect(!tools.expanded)
            #expect(tools.open(action, current: scope, area: area) && tools.expanded)
            let missingScope = tools.open(action, current: nil, area: area)
            let foreignScope = tools.open(action, current: try RecoveryGuidance.Scope(accountId: "foreign-synthetic", appId: scope.appId), area: area)
            let foreignArea = tools.open(action, current: scope, area: area == .finance ? .sales : .finance)
            #expect(!missingScope && !foreignScope && !foreignArea)
            #expect(ReportNavigation.Tools.focus(action, current: scope, field: target.focus!, expanded: true, available: true))
            #expect(!ReportNavigation.Tools.focus(action, current: scope, field: target.focus!, expanded: false, available: true))
            #expect(!ReportNavigation.Tools.focus(action, current: scope, field: target.focus!, expanded: true, available: false))
            #expect(!ReportNavigation.Tools.focus(action, current: scope, field: "other-field", expanded: true, available: true))
        }
        #expect(throws: RecoveryGuidance.Failure.invalid) { try ReportNavigation.downloads(.pricing) }
    }
    @Test func currentPublicConnectionAndDownloadGuidanceOpensOnlyItsScopedReportTools() throws {
        let directory = try TestIsolation.require().appendingPathComponent("native-fixtures")
        let guidance = try JSONText.parse(Data(contentsOf: directory.appendingPathComponent("recovery-guidance.json")))
        let help = try JSONText.parse(Data(contentsOf: directory.appendingPathComponent("help-catalog.json")))
        let helpCatalog = try HelpCatalog(data: #require(help["catalog"]).data)
        let catalog = try RecoveryGuidance(data: #require(guidance["catalog"]).data, help: helpCatalog)
        var connectionCount = 0, anchorCount = 0
        for entry in catalog.entries.values {
            guard let action = entry.target.resolved(scope: scope) else { continue }
            for area in [RecoveryGuidance.Target.Area.sales, .analytics, .finance] {
                let target = try ReportNavigation.downloads(area)
                let connection = action.target.opensConnection && [.sales, .finance].contains(area)
                let matches = action.target.area == area && (connection || action.target.anchor == target.anchor)
                #expect(ReportNavigation.Tools.requested(action, current: scope, area: area) == matches)
                if matches { if action.target.opensConnection { connectionCount += 1 } else { anchorCount += 1 } }
            }
        }
        #expect(connectionCount > 0 && anchorCount > 0)
    }
}
