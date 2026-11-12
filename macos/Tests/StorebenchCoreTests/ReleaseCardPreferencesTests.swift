import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct ReleaseCardPreferencesTests {
    init() throws { _ = try TestIsolation.require() }
    private func key(_ version: String, account: String = "synthetic-account", app: String = "1000000001") -> String {
        ReleaseCardPreferences.key(accountId: account, appId: app, platform: "MAC_OS", version: version)
    }
    @Test func newVersionsFollowTheDefaultAndExistingVersionsKeepTheirChoices() throws {
        let first = key("1.0"), second = key("2.0"), third = key("3.0")
        var preferences = try ReleaseCardPreferences().applying(.observe([first, second]))
        #expect(preferences.expanded(first) && preferences.expanded(second))
        preferences = try preferences.applying(.expanded([first], false))
        preferences = try ReleaseCardPreferences(json: preferences.json).applying(.observe([second, first]))
        #expect(!preferences.expanded(first) && preferences.expanded(second))
        preferences = try preferences.applying(.defaultExpanded(false)).applying(.observe([third]))
        #expect(!preferences.expanded(first) && preferences.expanded(second) && !preferences.expanded(third))
        preferences = try preferences.applying(.defaultExpanded(true)).applying(.observe([first, second, third, key("4.0")]))
        #expect(!preferences.expanded(first) && !preferences.expanded(third) && preferences.expanded(key("4.0")))
        #expect(first != key("1.0", account: "synthetic-other"))
        #expect(first != key("1.0", app: "1000000002"))
        #expect(try ReleaseCardPreferences(json: preferences.json) == preferences)
    }
    @Test func suggestionAnswersPersistWithoutChangingExistingReleaseChoices() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000), id = key("1.0")
        let minimized = try ReleaseCardPreferences().applying(.expanded([id], false))
        let yes = try minimized.applying(.answer(.yes, now))
        #expect(!yes.defaultExpanded && !yes.expanded(id) && !yes.canSuggest(at: now))
        let later = try ReleaseCardPreferences(json: minimized.applying(.answer(.later, now)).json)
        #expect(!later.canSuggest(at: now.addingTimeInterval(86_399)))
        #expect(later.canSuggest(at: now.addingTimeInterval(86_400)))
        let no = try ReleaseCardPreferences(json: minimized.applying(.answer(.no, now)).json)
        #expect(!no.canSuggest(at: now.addingTimeInterval(10_000_000)))
        #expect(try no.applying(.suggestions(true)).canSuggest(at: now))
        #expect(throws: ReleaseCardPreferences.Failure.self) { try minimized.applying(.expanded(["invalid"], true)) }
    }
    @Test func independentWindowsMergeChoicesAndInvalidSavedStateIsNeverOverwritten() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let other = try WorkspaceSession(workspace: Workspace(root: root), vault: await session.vault)
        let first = key("1.0"), second = key("2.0")
        _ = try await session.updateReleaseCardPreferences(.observe([first, second]))
        async let collapse = session.updateReleaseCardPreferences(.expanded([first], false))
        async let defaults = other.updateReleaseCardPreferences(.defaultExpanded(false))
        _ = try await (collapse, defaults)
        let saved = try await other.releaseCardPreferences()
        #expect(!saved.defaultExpanded && !saved.expanded(first) && saved.expanded(second))
        let store = try EncryptedDocumentStore(url: EncryptedDocumentStore.databaseURL(root: root), key: Data(0..<32), writable: true)
        let before = try store.document(namespace: "release_card_preferences", key: "current")
        _ = try await session.updateReleaseCardPreferences(.observe([second, first]))
        #expect(try store.document(namespace: "release_card_preferences", key: "current") == before)
        try store.transaction { _ in [.put(namespace: "release_card_preferences", key: "current", json: saved.json.setting("schemaVersion", .number(99)).data)] }
        let malformed = try store.document(namespace: "release_card_preferences", key: "current")
        await #expect(throws: ReleaseCardPreferences.Failure.self) { try await session.releaseCardPreferences() }
        await #expect(throws: ReleaseCardPreferences.Failure.self) { try await other.updateReleaseCardPreferences(.defaultExpanded(true)) }
        #expect(try store.document(namespace: "release_card_preferences", key: "current") == malformed)
    }
}
