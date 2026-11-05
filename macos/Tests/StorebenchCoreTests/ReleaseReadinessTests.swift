import Foundation
import Testing
@testable import StorebenchCore

@Suite struct ReleaseReadinessTests {
    init() throws { _ = try TestIsolation.require() }
    private let scope = try! RecoveryGuidance.Scope(accountId: "synthetic-account", appId: "1000000001")
    private func fixture() throws -> JSONText { try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/release-readiness.json"))) }
    private func rows(_ value: JSONText?) throws -> [JSONText] { guard case .array(let rows)? = value else { throw ReleaseReadiness.Failure.invalid }; return rows }
    @Test func everyStatusDetailAndNextActionMatchesThePrimaryReleaseContract() throws {
        let cases = try rows(fixture()["cases"]); #expect(cases.count > 120)
        for item in cases {
            let input = try #require(item["input"]), name = try #require(item["name"]?.text)
            let steps = try ReleaseReadiness.steps(input, scope: scope)
            #expect(JSONText.array(steps.map(\.json)) == item["expected"], "Synthetic release status: \(name)")
            #expect(Set(steps.map(\.id)).count == steps.count)
            #expect(steps.allSatisfy { $0.href.hasPrefix(scope.root + "/") || $0.href == "https://appstoreconnect.apple.com/" })
        }
    }
    /// After a save, App Store Connect returns the saved text with its own line breaks and without trailing whitespace; that text is not only on this Mac.
    @Test func appleTextDifferingOnlyInLineBreaksAndOuterWhitespaceIsAlreadyInAppStoreConnect() throws {
        let input = try #require(try rows(fixture()["cases"]).first?["input"])
        func step(local whatsNew: String, _ promotional: String, apple appleWhatsNew: String, _ applePromotional: String) throws -> ReleaseReadiness.Step? {
            let local = try rows(input["local"]).map { item -> JSONText in
                guard item["material"]?["locale"]?.text == "en-US", let fields = item["fields"] else { return item }
                return item.setting("fields", fields.setting("whatsNew", .string(whatsNew)).setting("promotionalText", .string(promotional)))
            }
            let apple = try rows(input["appleLocales"]).map { item -> JSONText in
                guard item["locale"]?.text == "en-US", let fields = item["fields"] else { return item }
                return item.setting("fields", fields.setting("whatsNew", .string(appleWhatsNew)).setting("promotionalText", .string(applePromotional)))
            }
            return try ReleaseReadiness.steps(input.setting("local", .array(local)).setting("appleLocales", .array(apple)), scope: scope).first { $0.id == "apple-text:en-US" }
        }
        let saved = try #require(try step(local: "Fixes\r\n• Faster — search\r\n", "Synthetic promotion  ", apple: "Fixes\n• Faster — search", "Synthetic promotion"))
        #expect(saved.state == .ready && saved.issues.isEmpty)
        let differs = try #require(try step(local: "Fixes\n• Faster — search", "Synthetic promotion", apple: "Fixes\n• Slower — search", "Synthetic promotion"))
        #expect(differs.state == .blocked && differs.issues.map(\.field) == ["whatsNew"])
        #expect(ReleaseWizard.presented(differs).detail.hasPrefix("Only on this Mac, not in App Store Connect yet: "))
    }
    @Test func appInformationRecordsRequireMatchingLocalesAndExactText() throws {
        for item in try rows(fixture()["consistent"]) {
            let records = try rows(item["records"]).map { try rows($0) }, actual = try ReleaseReadiness.consistentAppInfoLocales(records)
            #expect(actual.map(JSONText.array) ?? .string("unknown") == item["expected"])
        }
    }
    @Test func boundedScopesAndObservationsFailClosedWithoutInventingVerifiedSteps() throws {
        let input = try #require(try rows(fixture()["cases"]).first?["input"])
        for invalid in [input.setting("root", .string("/apps/synthetic-other/1000000001")), input.setting("appleLocales", .null),
            input.setting("appConfiguration", .string("synthetic-invalid")), input.setting("attachedBuild", .string("synthetic-invalid")),
            input.setting("accessibility", .object([("drafts", .number(0.5)), ("published", .number(1))])),
            input.setting("currentAvailability", .object([("selected", .array([.string("SWE")])), ("unselected", .array([.string("SWE")]))])),
            input.setting("exportCompliance", .object([("kind", .string("synthetic-invalid"))]))] {
            #expect(throws: ReleaseReadiness.Failure.invalid) { try ReleaseReadiness.steps(invalid, scope: scope) }
        }
        let languages = try rows(input["local"])
        #expect(throws: ReleaseReadiness.Failure.invalid) { try ReleaseReadiness.steps(input.setting("local", .array(languages + [languages[0]])), scope: scope) }
    }
    @Test func anEarlierApprovedVersionCarriesTheAppsOneTimeAnswers() throws {
        let plan = try #require(ReleasePlan(.object([("accountId", .string("synthetic-account")), ("appId", .string("1000000001")),
            ("sourceRevisionId", .string("00000000-0000-4000-8000-000000000001")), ("baseVersionId", .string("synthetic-base")), ("platform", .string("IOS")),
            ("targetVersion", .string("2.0")), ("releaseType", .string("MANUAL")), ("updatedAt", .string("2026-01-01T00:00:00.000Z"))])))
        func step(_ id: String, _ state: ReleaseReadiness.State) -> ReleaseReadiness.Step { .init(id: id, label: id, detail: "", href: "", action: "", state: state, territories: nil, guideHref: nil) }
        func input(earlier: String) -> JSONText {
            .object([("appleVersions", .array([.object([("platform", .string("IOS")), ("number", .string("1.0")), ("state", .string(earlier))]),
                                               .object([("platform", .string("IOS")), ("number", .string("2.0")), ("state", .string("READY_FOR_SALE"))])])),
                     ("accessibility", .object([("drafts", .number(0)), ("published", .number(2))]))])
        }
        let steps = [step("privacy", .manual), step("tax", .manual), step("age-rating", .review), step("accessibility", .review), step("app-configuration", .blocked), step("submission", .review)]
        #expect(ReleaseReadiness.completedEarlier(steps, input: input(earlier: "READY_FOR_SALE"), plan: plan).map(\.state) == [.ready, .ready, .ready, .ready, .blocked, .review])
        // The target version's own state never proves an earlier approval.
        #expect(ReleaseReadiness.completedEarlier(steps, input: input(earlier: "PREPARE_FOR_SUBMISSION"), plan: plan).map(\.state) == [.manual, .manual, .ready, .ready, .blocked, .review])
        // App Privacy is done only when the saved check of App Store Connect showed the answers published.
        func privacy(_ answered: Bool) -> JSONText {
            input(earlier: "PREPARE_FOR_SUBMISSION").setting("privacyCheck", .object([("answered", .bool(answered)), ("detail", .string(answered ? "Published" : "Not published")), ("checkedAt", .string("2026-01-01T00:00:00.000Z"))]))
        }
        #expect(ReleaseReadiness.completedEarlier(steps, input: privacy(true), plan: plan).first?.state == .ready)
        #expect(ReleaseReadiness.completedEarlier(steps, input: privacy(false), plan: plan).first?.state == .manual)
        // Tax Category is done once App Store Connect showed a category, including Apple's default.
        let tax = input(earlier: "PREPARE_FOR_SUBMISSION").setting("taxCheck", .object([("answered", .bool(true)), ("detail", .string("Default · App Store software")), ("checkedAt", .string("2026-01-01T00:00:00.000Z"))]))
        #expect(ReleaseReadiness.completedEarlier(steps, input: tax, plan: plan).map(\.state).prefix(2) == [.manual, .ready])
    }
    @Test func completeLargeReleaseProjectionIncludesHiddenLanguagesAndCopiedWording() throws {
        let values = try rows(fixture()["benchmarks"]); #expect(values.count == 2)
        for (index, value) in values.enumerated() {
            let steps = try ReleaseReadiness.steps(#require(value["input"]), scope: scope)
            #expect(steps.count == (index == 0 ? 414 : 514))
            #expect(JSONText.array(steps.map(\.json)) == value["expected"])
            #expect(steps.filter { $0.id.hasPrefix("apple-text:") && $0.state == .ready }.count == 100)
            #expect(steps.filter { $0.id.hasPrefix("editorial:") }.count == (index == 0 ? 0 : 100))
        }
    }
}
