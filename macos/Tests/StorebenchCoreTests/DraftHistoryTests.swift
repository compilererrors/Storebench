import Foundation
import Testing
@testable import StorebenchCore

/// Earlier draft text stays findable after later saves change it, stored once however often it is saved.
@Suite(.serialized) struct DraftHistoryTests {
    init() throws { _ = try TestIsolation.require() }
    private let app = "1000000001", revision = "00000000-0000-4000-8000-000000000002", localization = "version-locale-1"

    private func save(_ session: WorkspaceSession, account: String, promotion: String) async throws {
        let loaded = try await session.textDraft(accountId: account, appId: app, revisionId: revision, localizationId: localization, scope: .version)
        var fields = loaded.fields; fields["promotionalText"] = promotion
        _ = try await session.saveTextDraft(accountId: account, appId: app, revisionId: revision, localizationId: localization, scope: .version, fields: fields, fingerprint: loaded.fingerprint)
    }

    @Test func everySaveKeepsTheEarlierTextOfTheFieldsItChanged() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first).id
        let imported = try await session.textDraft(accountId: account, appId: app, revisionId: revision, localizationId: localization, scope: .version).fields["promotionalText"] ?? ""
        try await save(session, account: account, promotion: "Synthetic first promotion")
        try await save(session, account: account, promotion: "Synthetic second promotion")
        let history = try await session.draftTextHistory(accountId: account, appId: app)
        let promotions = history.filter { $0.field == "promotionalText" }
        #expect(promotions.count == 2)
        #expect(promotions.map(\.after).contains("Synthetic second promotion") && promotions.map(\.before).contains("Synthetic first promotion"))
        #expect(promotions.contains { $0.before == imported && $0.after == "Synthetic first promotion" }, "The first save's earlier text is the imported text")
        #expect(history.allSatisfy { $0.revisionId == revision && $0.localizationId == localization })
        // Only changed fields are recorded.
        #expect(Set(history.map(\.field)) == ["promotionalText"])
    }

    @Test func theSameTextIsStoredOnceAndAnUnchangedSaveAddsNothing() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first).id
        for promotion in ["Synthetic A", "Synthetic B", "Synthetic A", "Synthetic B"] { try await save(session, account: account, promotion: promotion) }
        let values = try await session.storeAccess { try $0.documents(namespace: DraftHistory.values, prefix: "\(account):\(app):").count }
        #expect(values == 3, "The imported text, A and B, each once: \(values)")
        #expect(try await session.draftTextHistory(accountId: account, appId: app).count == 4)
        // An unchanged save adds nothing.
        let current = try await session.textDraft(accountId: account, appId: app, revisionId: revision, localizationId: localization, scope: .version)
        _ = try await session.saveTextDraft(accountId: account, appId: app, revisionId: revision, localizationId: localization, scope: .version, fields: current.fields, fingerprint: current.fingerprint)
        #expect(try await session.draftTextHistory(accountId: account, appId: app).count == 4)
    }
}
