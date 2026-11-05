import Foundation
import Testing
@testable import StorebenchCore

@Suite struct AppNavigationTests {
    init() throws { _ = try TestIsolation.require() }
    private let scope = try! RecoveryGuidance.Scope(accountId: "synthetic-account", appId: "1000000001")
    private func fixture() throws -> JSONText { try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/app-navigation.json"))) }
    private func scope(_ value: JSONText) throws -> RecoveryGuidance.Scope { try .init(accountId: #require(value["accountId"]?.text), appId: #require(value["appId"]?.text)) }
    private func context(_ value: JSONText?, scope: RecoveryGuidance.Scope) throws -> AppNavigation.Context? {
        guard let value, value != .null else { return nil }
        return try .init(scope: scope, locale: value["locale"]?.text, version: value["version"]?.text, draft: value["draft"] == .string("1"))
    }
    @Test func allPrimarySectionsAndEditorDestinationsMatchTheActualNavigation() throws {
        let fixture = try fixture()
        guard case .array(let sections)? = fixture["sections"], case .array(let cases)? = fixture["cases"] else { throw AppNavigation.Failure.invalid }
        #expect(sections.count == 34 && cases.count == 816)
        for row in sections {
            let key = try #require(row["key"]?.text), section = try #require(AppNavigation.Section(key: key))
            #expect(section.rawValue == row["label"]?.text && section.group.key == row["group"]?.text)
        }
        #expect(Set(AppNavigation.Section.allCases.map(\.key)).count == AppNavigation.Section.allCases.count)
        for row in cases {
            let source = try scope(#require(row["source"])), target = try scope(#require(row["scope"]))
            let key = try #require(row["section"]?.text), section = try #require(AppNavigation.Section(key: key))
            let destination = AppNavigation.Destination(source: source, scope: target, section: section, context: try context(row["context"], scope: source), switchingApp: row["switchingApp"] == .bool(true))
            #expect(destination.href == row["expected"]?.text, "Primary destination: \(key)")
            #expect(destination.allowed(current: source, decision: .ready))
            #expect(!destination.allowed(current: nil, decision: .ready))
            #expect(!destination.allowed(current: source, decision: .wait, discardConfirmed: true))
            #expect(!destination.allowed(current: source, decision: .confirmDiscard))
            #expect(destination.allowed(current: source, decision: .confirmDiscard, discardConfirmed: true))
            if row["switchingApp"] == .bool(true) || section == .keywords { #expect(destination.context?.version == nil && destination.context?.draft != true) }
            if !section.usesLanguage { #expect(destination.context == nil) }
        }
    }
    @Test func selectedSavedLanguageAndAttachedDraftVersionMatchTheActualLanguageWorkspace() throws {
        guard case .array(let cases)? = try fixture()["selections"] else { throw AppNavigation.Failure.invalid }
        #expect(cases.count == 96)
        for row in cases {
            let current = try scope(#require(row["scope"])), key = try #require(row["section"]?.text), section = try #require(AppNavigation.Section(key: key))
            let versions = try JSONDecoder().decode([Revision.Version].self, from: #require(row["versions"]).data)
            let infos = try JSONDecoder().decode([Revision.AppInfo].self, from: #require(row["appInfos"]).data)
            let selection = AppNavigation.selection(scope: current, versions: versions, appInfos: infos, context: try context(row["context"], scope: current), section: section, planVersionId: row["planVersionId"]?.text)
            #expect(selection.json == row["expected"], "Primary saved selection: \(key)")
            #expect(selection.locales.isEmpty ? selection.locale.isEmpty : selection.locales.contains(selection.locale))
        }
    }
    @Test func contextCannotUseAForeignOwnerOrKeepVersionChoicesOutsideEditorViews() throws {
        let foreign = try RecoveryGuidance.Scope(accountId: "synthetic-other", appId: scope.appId)
        let context = try AppNavigation.Context(scope: foreign, locale: "sv", version: "version-1", draft: true)
        let destination = AppNavigation.Destination(source: scope, scope: scope, section: .media, context: context)
        #expect(destination.context == nil && !destination.allowed(current: foreign, decision: .ready))
        let own = try AppNavigation.Context(scope: scope, locale: "sv", version: "version-1", draft: true)
        let keywords = try #require(own.forSection(.keywords, scope: scope))
        #expect(keywords.locale == "sv" && keywords.version == nil && !keywords.draft)
        #expect(own.forSection(.sales, scope: scope) == nil)
        #expect(keywords.forSection(.media, scope: scope)?.version == nil)
        let differentApp = try RecoveryGuidance.Scope(accountId: scope.accountId, appId: "1000000002")
        #expect(own.forSection(.localizations, scope: differentApp)?.locale == "sv")
        #expect(own.forSection(.localizations, scope: differentApp)?.version == nil)
        let material = Revision.Version(id: "version-1", fields: [:], localizations: [.init(id: "saved-en", fields: ["locale": .text("en-US")], screenshotSets: [])])
        let selection = AppNavigation.selection(scope: scope, versions: [material], appInfos: [], context: context, section: .media)
        #expect(selection.locale == "en-US" && selection.versionId == "version-1")
    }
    @Test func unsupportedLanguagesAndUnboundedOrControlContainingVersionsAreRejected() throws {
        for locale in ["", "synthetic-unknown", "sv\n", "sv\0"] { #expect(throws: AppNavigation.Failure.invalid) { try AppNavigation.Context(scope: scope, locale: locale) } }
        for version in ["", "version\n", "version\0", String(repeating: "v", count: 257)] { #expect(throws: AppNavigation.Failure.invalid) { try AppNavigation.Context(scope: scope, version: version) } }
        #expect(AppNavigation.Section(key: "synthetic-unknown") == nil)
    }
}
