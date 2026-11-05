import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct TransferTests {
    init() throws { _ = try TestIsolation.require() }
    @Test func languageRowsArePreviewedThenImportedOntoThePreviewedDraft() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), app = "1000000001"
        let table = try await session.exportTransfer(accountId: account.id, appId: app, kind: .languages)
        let row = try #require(table.rows.firstIndex { $0[3] == "version" && $0[4] == "keywords" })
        var edited = table
        edited.rows[row][5] = "sample,test,synthetic"
        edited.rows.append([app, table.rows[row][1], "sv", "version", "description", "=Svensk beskrivning"])
        for format in TransferFormat.allCases { #expect(try Transfer.parse(.languages, Transfer.text(.languages, edited, format: format), format: format) == edited) }

        let preview = try await session.importTransfer(account: account, appId: app, kind: .languages, table: edited)
        #expect(!preview.saved && preview.added == 1 && preview.changes.contains { $0.after == "sample,test,synthetic" && $0.before == "sample,test" })
        #expect(preview.changes.contains { $0.label.hasPrefix("Swedish") && $0.before == "Language not added yet" })
        await #expect(throws: TransferFailure.changed) { try await session.importTransfer(account: account, appId: app, kind: .languages, table: edited, fingerprint: String(repeating: "0", count: 64)) }
        let saved = try await session.importTransfer(account: account, appId: app, kind: .languages, table: edited, fingerprint: preview.fingerprint)
        #expect(saved.saved && saved.changes == preview.changes)
        let after = try await session.exportTransfer(accountId: account.id, appId: app, kind: .languages)
        #expect(after.rows.contains { $0[2] == "sv" && $0[4] == "description" && $0[5] == "=Svensk beskrivning" })
        await #expect(throws: TransferFailure.changed) { try await session.importTransfer(account: account, appId: app, kind: .languages, table: edited, fingerprint: preview.fingerprint) }

        var foreign = edited; foreign.rows[0][0] = "999"
        await #expect(throws: TransferFailure.self) { try await session.importTransfer(account: account, appId: app, kind: .languages, table: foreign) }
    }

    @Test func pricesAndReleasePlansImportWithTheirRules() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), app = "1000000001"
        let currencies = ["USA": "USD", "SWE": "SEK"]
        let prices = Delimited.Table(columns: Transfer.columns[.prices]!, rows: [[app, "SWE", "SEK", "49", "", ""], [app, "USA", "USD", "3.99", "2026-12-01", "2026-12-24"]])
        let preview = try await session.importTransfer(account: account, appId: app, kind: .prices, table: prices, currencies: currencies)
        #expect(preview.changes.map(\.label) == ["SWE · Country override", "USA · 2026-12-01 to 2026-12-24"])
        _ = try await session.importTransfer(account: account, appId: app, kind: .prices, table: prices, currencies: currencies, fingerprint: preview.fingerprint)
        #expect(try await session.pricingDrafts(accountId: account.id, appId: app).map(\.amount).sorted() == ["3.99", "49"])
        var wrong = prices; wrong.rows[0][2] = "EUR"
        await #expect(throws: TransferFailure.invalid("Country or currency does not match Apple's catalog: SWE.")) { try await session.importTransfer(account: account, appId: app, kind: .prices, table: wrong, currencies: currencies) }
        try await session.protectPrices(accountId: account.id, appId: app, prices: [(territory: "SWE", customerPrice: "55", currency: "SEK")])
        await #expect(throws: TransferFailure.self) { try await session.importTransfer(account: account, appId: app, kind: .prices, table: prices, currencies: currencies) }

        let revision = try #require(try await session.revisions(accountId: account.id, appId: app).first { !$0.isLocalDraft })
        let version = try #require(revision.versions.first)
        let release = Delimited.Table(columns: Transfer.columns[.release]! + Transfer.releaseOptions, rows: [[app, revision.id, version.id, "9.9", "AFTER_APPROVAL", ""]])
        let plan = try await session.importTransfer(account: account, appId: app, kind: .release, table: release)
        #expect(plan.changes.contains { $0.label == "New version number" && $0.after == "9.9" })
        _ = try await session.importTransfer(account: account, appId: app, kind: .release, table: release, fingerprint: plan.fingerprint)
        let saved = try #require(try await session.releasePlan(accountId: account.id, appId: app))
        #expect(saved.targetVersion == "9.9" && saved.releaseType == "AFTER_APPROVAL")
    }
}
