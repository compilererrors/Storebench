import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) @MainActor struct TransferEditorSessionTests {
    init() throws { _ = try TestIsolation.require() }
    @Test func aRealSyntheticLanguageImportRetainsEveryCommittedComparisonAndReadsSavedValuesWithoutAdoptingThem() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), app = "1000000001"
        let original = try await session.exportTransfer(accountId: account.id, appId: app, kind: .languages)
        let reference = try #require(original.rows.first { $0[3] == "version" && $0[4] == "description" })
        let languages = ["sv", "fr-FR", "de-DE", "es-ES", "it", "pt-BR", "pt-PT", "ja", "ko", "zh-Hans", "zh-Hant", "nl-NL", "da", "fi", "no"]
        let table = Delimited.Table(columns: original.columns, rows: languages.map { [app, reference[1], $0, "version", "description", "Synthetic imported description for \($0)\n\(String(repeating: "Synthetic text 日本語 😀\n", count: 10))"] })
        let bytes = try Transfer.text(.languages, table, format: .csv).data(using: .utf8)!
        let model = try TransferEditor(account: account, appId: app, kind: .languages, session: session)
        let chosen = await model.choose(read: { .init(data: bytes, format: .csv) })
        #expect(chosen, "Synthetic import status: \(model.status)")
        let before = try #require(model.preview); #expect(before.changes.count > 100 && !before.saved)
        #expect(await model.apply()); let receipt = try #require(model.lastSave)
        #expect(receipt.preview.saved && receipt.preview.changes == before.changes && receipt.preview.totalRows == table.rows.count)
        let all = (1...TransferReviewPage(changes: receipt.preview.changes, page: 1).pages).flatMap { TransferReviewPage(changes: receipt.preview.changes, page: $0).changes }
        #expect(all == before.changes && all.last == before.changes.last)
        #expect(await model.readSavedData()); let saved = try #require(model.savedData)
        for row in table.rows { #expect(saved.rows.contains(row)) }
        #expect(model.lastSave?.preview.changes == before.changes && model.preview == nil)
        #expect(await model.apply() == false)
        let noReviews = try await session.storeAccess { @Sendable store in try store.documents(namespace: "publish_reviews").isEmpty }
        #expect(noReviews)
    }
    @Test func aConcurrentLocalEditBlocksTheOldImportUntilItsNewPreviewIsExplicitlyChosen() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), app = "1000000001"
        var table = try await session.exportTransfer(accountId: account.id, appId: app, kind: .languages)
        let index = try #require(table.rows.firstIndex { $0[3] == "version" && $0[4] == "keywords" })
        table.rows[index][5] = "sample,test,synthetic"
        let bytes = try Transfer.text(.languages, table, format: .json).data(using: .utf8)!
        let model = try TransferEditor(account: account, appId: app, kind: .languages, session: session)
        #expect(await model.choose(read: { .init(data: bytes, format: .json) })); let before = try #require(model.preview)
        var concurrent = table; concurrent.rows[index][5] = "sample,test,concurrent"
        let fresh = try await session.importTransfer(account: account, appId: app, kind: .languages, table: concurrent)
        _ = try await session.importTransfer(account: account, appId: app, kind: .languages, table: concurrent, fingerprint: fresh.fingerprint)
        #expect(await model.apply() == false); #expect(model.saveBlocked && model.preview == before && model.lastSave == nil)
        #expect(await model.apply() == false)
        let unchanged = try await session.exportTransfer(accountId: account.id, appId: app, kind: .languages)
        #expect(unchanged.rows[index][5] == "sample,test,concurrent")
        #expect(await model.recheck()); #expect(model.preview?.fingerprint != before.fingerprint && model.preview?.changes.first?.before == "sample,test,concurrent")
        #expect(await model.apply()); #expect(model.lastSave?.preview.saved == true)
    }
}
