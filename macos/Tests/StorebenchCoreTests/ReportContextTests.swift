import Foundation
import Testing
@testable import StorebenchCore

@Suite struct ReportContextTests {
    init() throws { _ = try TestIsolation.require() }
    func fixture() throws -> (ReportContext, JSONText) {
        let value = try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/report-context.json")))
        return (try ReportContext(data: #require(value["catalog"]).data), value)
    }
    @Test func completeReportContextAndLatestCoverageMatchTheActualPrimaryContract() throws {
        let (catalog, fixture) = try fixture(), cases = WorkspaceSession.items(fixture["cases"])
        #expect(cases.count == 36)
        for row in cases {
            let kindText = try #require(row["kind"]?.text)
            let kind = try #require(ReportContext.Kind(rawValue: kindText))
            let dates = try WorkspaceSession.items(row["dates"]).map { try #require($0.text) }
            let scope = try RecoveryGuidance.Scope(accountId: #require(row["scope"]?["accountId"]?.text), appId: #require(row["scope"]?["appId"]?.text))
            #expect(try catalog.presentation(kind, coverage: .saved(dates)).json(scope: scope) == row["expected"])
        }
    }
    @Test func unavailableCoverageNeverClaimsNoSavedPeriodsAndInvalidDatesNeverBecomeZeroActivity() throws {
        let (catalog, _) = try fixture()
        for kind in ReportContext.Kind.allCases {
            let empty = try catalog.presentation(kind, coverage: .saved([])), loading = try catalog.presentation(kind, coverage: .loading), unavailable = try catalog.presentation(kind, coverage: .unavailable)
            #expect(empty.latest == "No saved periods yet.")
            #expect(loading.latest == "Reading saved report coverage…" && unavailable.latest == "Saved reporting coverage could not be read.")
            #expect(loading.coverage == empty.coverage && unavailable.coverage == empty.coverage)
            for date in ["2026-02-29", "2026-04-31", "2026-01-01T00:00:00Z", "", "2026-1-01", "2026-01-01\n"] {
                #expect(throws: ReportContext.Failure.invalid) { try catalog.presentation(kind, coverage: .saved(["2026-01-31", date])) }
            }
        }
    }
    @Test func relatedViewsAreScopedProtectedAndNeverCarryFiscalRangesOrDownloadActions() throws {
        let (catalog, _) = try fixture()
        let scope = try RecoveryGuidance.Scope(accountId: "synthetic-report-context", appId: "1000000001"), foreignAccount = try RecoveryGuidance.Scope(accountId: "synthetic-other", appId: scope.appId), foreignApp = try RecoveryGuidance.Scope(accountId: scope.accountId, appId: "1000000002")
        for kind in ReportContext.Kind.allCases {
            let value = try catalog.presentation(kind, coverage: .saved(["2026-02-28"]))
            #expect(value.related.count == 2 && !value.related.contains { $0.kind == kind })
            for related in value.related {
                let target = related.kind.target, action = try #require(target.resolved(scope: scope))
                #expect(target.requiresApp && target.anchor == nil && target.focus == nil && !target.opensConnection && !target.analyticsOngoing)
                #expect(target.resolved(scope: nil) == nil && action.allowed(current: scope, decision: .ready))
                #expect(!action.allowed(current: foreignAccount, decision: .ready) && !action.allowed(current: foreignApp, decision: .ready))
                #expect(!action.allowed(current: scope, decision: .confirmDiscard) && action.allowed(current: scope, decision: .confirmDiscard, discardConfirmed: true))
                #expect(!action.allowed(current: scope, decision: .wait, discardConfirmed: true))
                #expect(!ReportNavigation.Tools.requested(action, current: scope, area: target.area))
            }
            let help = try #require(value.help.resolved(scope: nil)); #expect(help.target.area == .help && help.target.helpTopic == "sales")
            #expect(help.allowed(current: nil, decision: .ready) && !help.allowed(current: nil, decision: .wait, discardConfirmed: true))
        }
        #expect(throws: RecoveryGuidance.Failure.invalid) { try ReportNavigation.section(.publishing) }
    }
    @Test func malformedOrIncompleteDefinitionsFailClosedAndLongPublicTextStaysLiteral() throws {
        let (_, fixture) = try fixture(), raw = try #require(fixture["catalog"]), source = try #require(WorkspaceSession.items(raw["sources"]).first)
        #expect(throws: ReportContext.Failure.invalid) { try ReportContext(data: raw.setting("schemaVersion", .number(2)).data) }
        #expect(throws: ReportContext.Failure.invalid) { try ReportContext(data: raw.setting("sources", .array([source, source, source])).data) }
        for field in ["kind", "label", "calendar", "purpose", "description", "limits"] {
            var rows = WorkspaceSession.items(raw["sources"]); rows[0] = source.setting(field, .string(""))
            #expect(throws: ReportContext.Failure.invalid) { try ReportContext(data: raw.setting("sources", .array(rows)).data) }
        }
        for text in ["Synthetic\ntext", "Synthetic\0text", String(repeating: "x", count: 4097)] {
            var rows = WorkspaceSession.items(raw["sources"]); rows[0] = source.setting("description", .string(text))
            #expect(throws: ReportContext.Failure.invalid) { try ReportContext(data: raw.setting("sources", .array(rows)).data) }
        }
        let text = String(repeating: "Synthetic report explanation · ", count: 100)
        var rows = WorkspaceSession.items(raw["sources"]); rows[0] = source.setting("description", .string(text))
        let long = try ReportContext(data: raw.setting("sources", .array(rows)).data)
        #expect(try long.presentation(.sales, coverage: .saved([])).description == text)
    }
}
