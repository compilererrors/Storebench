import Foundation
import Testing
@testable import StorebenchCore

/// Text changed at App Store Connect after a draft took its text is told apart from a change made on this Mac, and waits for the person to choose.
@Suite(.serialized) struct AppleTextChangeTests {
    init() throws { _ = try TestIsolation.require() }

    private func origin(base: String, draft: String? = nil, kept: String? = nil) -> JSONText {
        .object([("id", .string("synthetic-locale")), ("base", .object([("promotionalText", .string(base))])),
                 ("draft", .object(draft.map { [("promotionalText", JSONText.string($0))] } ?? [])),
                 ("kept", .object(kept.map { [("promotionalText", JSONText.string(JSONText.string($0).rawSHA256))] } ?? []))])
    }
    private func issue(apple: String, saved: String, origin: JSONText) -> ReleaseMaterial.Issue? {
        ReleaseReadiness.textDifferences(["promotionalText"], apple: .object([("promotionalText", .string(apple))]), saved: .object([("promotionalText", .string(saved))]), origin: origin, scope: .version).first
    }

    @Test func eachDifferenceSaysWhereTheChangeWasMade() throws {
        // Changed only on this Mac: Save sends it.
        #expect(issue(apple: "Synthetic import", saved: "Synthetic mine", origin: origin(base: "Synthetic import", draft: "Synthetic mine"))?.section == "missing")
        // Changed only at App Store Connect, the draft still showing the import: Apple's text is offered, and Keep Mine sends the import's.
        let elsewhere = try #require(issue(apple: "Synthetic newer at Apple", saved: "Synthetic import", origin: origin(base: "Synthetic import")))
        #expect(elsewhere.changedAtApple && elsewhere.apple == "Synthetic newer at Apple" && elsewhere.localizationId == "synthetic-locale" && elsewhere.scope == .version)
        // Changed on both sides: the person chooses.
        let both = try #require(issue(apple: "Synthetic newer at Apple", saved: "Synthetic mine", origin: origin(base: "Synthetic import", draft: "Synthetic mine")))
        #expect(both.changedOnBothSides)
        // Keeping mine over that exact Apple text makes it an ordinary change to send; a newer Apple change asks again.
        #expect(issue(apple: "Synthetic newer at Apple", saved: "Synthetic mine", origin: origin(base: "Synthetic import", draft: "Synthetic mine", kept: "Synthetic newer at Apple"))?.section == "missing")
        #expect(issue(apple: "Synthetic newest at Apple", saved: "Synthetic mine", origin: origin(base: "Synthetic import", draft: "Synthetic mine", kept: "Synthetic newer at Apple"))?.changedOnBothSides == true)
        #expect(issue(apple: "Synthetic newer at Apple", saved: "Synthetic import", origin: origin(base: "Synthetic import", kept: "Synthetic newer at Apple"))?.section == "missing")
        // Matching text is no difference at all.
        #expect(issue(apple: "Synthetic same", saved: "Synthetic same", origin: origin(base: "Synthetic import", draft: "Synthetic same")) == nil)
    }

    @Test func eachChoiceCanBeComparedBeforeItIsMade() throws {
        // Changed only at App Store Connect: one comparison, from the text the draft took to App Store Connect's.
        let elsewhere = try #require(issue(apple: "Synthetic newer at Apple", saved: "Synthetic import", origin: origin(base: "Synthetic import")))
        #expect(elsewhere.comparisons == [.init(title: "Changed in App Store Connect", before: "Synthetic import", after: "Synthetic newer at Apple")])
        #expect(ReleaseMaterial.presented(elsewhere).comparisons == elsewhere.comparisons, "The presented check keeps its texts")
        // Changed on both sides: App Store Connect's change and this Mac's, each from the text the draft took.
        let both = try #require(issue(apple: "Synthetic newer at Apple", saved: "Synthetic mine", origin: origin(base: "Synthetic import", draft: "Synthetic mine")))
        #expect(both.comparisons == [.init(title: "Changed in App Store Connect", before: "Synthetic import", after: "Synthetic newer at Apple"),
                                     .init(title: "Changed on This Mac", before: "Synthetic import", after: "Synthetic mine")])
        #expect(both.base == "Synthetic import" && both.mine == "Synthetic mine" && both.apple == "Synthetic newer at Apple")
        // A change to send has nothing to choose, so nothing to compare.
        #expect(issue(apple: "Synthetic import", saved: "Synthetic mine", origin: origin(base: "Synthetic import", draft: "Synthetic mine"))?.comparisons.isEmpty == true)
    }

    @Test func sideBySideEachPanelKeepsItsWholeTextAndMarksOnlyItsOwnWords() {
        let mine = "Synthetic  draft text\nwith lines.", apple = "Synthetic newer text\nwith  lines and more."
        let sides = AsoProgress.sides(mine, apple)
        #expect(sides.before.map(\.text).joined() == mine && sides.after.map(\.text).joined() == apple, "Each panel shows its own text exactly")
        #expect(!sides.before.contains { $0.kind == .added } && !sides.after.contains { $0.kind == .removed })
        func marked(_ segments: [AsoTextSegment]) -> [String] { segments.filter { $0.kind != .same }.map { TextSemantics.trim($0.text) }.filter { !$0.isEmpty } }
        #expect(marked(sides.before) == ["draft", "lines."] && marked(sides.after) == ["newer", "lines and more."])
        // Matching texts mark nothing; an empty side is all one change on the other.
        #expect(marked(AsoProgress.sides(mine, mine).before).isEmpty && marked(AsoProgress.sides(mine, mine).after).isEmpty)
        #expect(AsoProgress.sides("", apple).after == [AsoTextSegment(kind: .added, text: apple)] && AsoProgress.sides("", apple).before.isEmpty)
    }

    @Test func usingAppStoreConnectTextOrKeepingMineOnlyChangesTheLocalDraft() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first).id
        let app = "1000000001", revision = "00000000-0000-4000-8000-000000000002", localization = "version-locale-1"
        try await session.useAppStoreConnectText(accountId: account, appId: app, revisionId: revision, localizationId: localization, scope: .version, values: ["promotionalText": "Synthetic newer at Apple"])
        #expect(try await session.textDraft(accountId: account, appId: app, revisionId: revision, localizationId: localization, scope: .version).fields["promotionalText"] == "Synthetic newer at Apple")
        try await session.keepDraftText(accountId: account, appId: app, revisionId: revision, localizationId: localization, scope: .version, apple: ["promotionalText": "Synthetic later at Apple"])
        let draft = try JSONText.parse(try #require(try await session.storeAccess { try $0.document(namespace: "drafts", key: "\(account):\(app):\(revision)") }).payload)
        #expect(draft["keptAppleText"]?[localization]?["promotionalText"]?.text == JSONText.string("Synthetic later at Apple").rawSHA256)
        await #expect(throws: DraftFailure.invalid) {
            try await session.useAppStoreConnectText(accountId: account, appId: app, revisionId: revision, localizationId: localization, scope: .version, values: ["name": "Not a version field"])
        }
        #expect(try await session.publishHistory(accountId: account, appId: app).isEmpty, "Nothing is sent to Apple")
    }
}
