import Foundation
import Testing
@testable import StorebenchCore

@Suite struct AppInformationEditorTests {
    init() throws { _ = try TestIsolation.require() }
    private func fixture() throws -> JSONText { try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/app-information.json"))) }
    private func rows(_ value: JSONText?) throws -> [JSONText] { guard case .array(let values)? = value else { throw PublishFailure.invalid("Invalid synthetic app information fixture.") }; return values }
    private func resources(_ value: JSONText?) throws -> [AppStoreConnectClient.Resource] { try JSONDecoder().decode([AppStoreConnectClient.Resource].self, from: #require(value).data) }
    private func strings(_ value: JSONText?) throws -> [String] { try rows(value).map { try #require($0.text) } }
    private func answers(_ value: JSONText?) throws -> [String: JSONText] { guard case .object(let pairs)? = value else { throw PublishFailure.invalid("Invalid synthetic answers.") }; return Dictionary(uniqueKeysWithValues: pairs) }
    private func selection(_ value: JSONText?) -> [String: String?] { Dictionary(uniqueKeysWithValues: AppInformation.categoryFields.map { ($0, value?[$0]?.text) }) }
    private func state(_ fixture: JSONText, categories: [String: String?]? = nil, categoryError: String? = nil) throws -> AppInformationState {
        AppInformationState(contentRights: "DOES_NOT_USE_THIRD_PARTY_CONTENT", categories: categories ?? selection(fixture["selection"]), catalog: try AppInformation.catalog(resources(fixture["catalog"])), territories: [], platforms: ["IOS", "MAC_OS"], categoryError: categoryError, availableInNewTerritories: true)
    }
    private func declarations(_ value: JSONText?) throws -> [AccessibilityDeclarationView] {
        try rows(value).map { row in
            let raw = try answers(row["answers"])
            let values = raw.compactMap { key, value -> (String, Bool)? in guard case .bool(let flag) = value else { return nil }; return (key, flag) }
            return AccessibilityDeclarationView(id: try #require(row["id"]?.text), family: try #require(row["family"]?.text), state: try #require(row["state"]?.text), answers: Dictionary(uniqueKeysWithValues: values))
        }
    }

    @Test func localDraftRestoresPartialInputsBeforeOrAfterAppleReads() throws {
        let fixture = try fixture(), baseline = try state(fixture)
        var edited = AppInformationEditor(); edited.receive(baseline); edited.receiveAgeAnswers([:]); edited.receiveDeclarations([])
        edited.chooseRights("USES_THIRD_PARTY_CONTENT")
        edited.chooseCategory("primaryCategory", "PRODUCTIVITY")
        edited.chooseAge(AgeRating.frequency[0].0, .string(AgeRating.frequencyValues[0]))
        let feature = try #require(AccessibilityDeclarations.applicable("MAC").first)
        edited.chooseAccessibility("MAC", feature.key, true)
        let saved = edited.localDraft
        var early = AppInformationEditor(); early.restoreLocalDraft(saved)
        early.receive(baseline); early.receiveAgeAnswers([:]); early.receiveDeclarations([])
        #expect(early.localDraft == saved && early.dirty)
        var late = AppInformationEditor(); late.receive(baseline); late.receiveAgeAnswers([:]); late.receiveDeclarations([])
        late.restoreLocalDraft(saved)
        #expect(late.localDraft == saved && late.dirty)
        #expect(late.ageChanges == edited.ageChanges && late.answers(for: "MAC")[feature.key] == true)
    }

    @Test func clearedAccessibilityAnswersStayClearedWhenDraftReopens() throws {
        let feature = try #require(AccessibilityDeclarations.applicable("MAC").first)
        let declarations = [AccessibilityDeclarationView(id: "synthetic-declaration", family: "MAC", state: "DRAFT", answers: [feature.key: true])]
        var edited = AppInformationEditor(); edited.receiveDeclarations(declarations)
        edited.chooseAccessibility("MAC", feature.key, nil)
        #expect(edited.answers(for: "MAC").isEmpty)
        let saved = edited.localDraft
        var early = AppInformationEditor(); early.restoreLocalDraft(saved); early.receiveDeclarations(declarations)
        #expect(early.answers(for: "MAC").isEmpty && early.dirty)
        var late = AppInformationEditor(); late.receiveDeclarations(declarations); late.restoreLocalDraft(saved)
        #expect(late.answers(for: "MAC").isEmpty && late.dirty)
    }

    @Test func categoryChangesAndPlatformChoicesMatchPrimaryEditor() throws {
        let fixture = try fixture(), baseline = try state(fixture)
        for row in try rows(fixture["information"]) {
            var editor = AppInformationEditor(); editor.receive(baseline); editor.chooseRights(try #require(row["rights"]?.text))
            for edit in try rows(row["edits"]) { let id = try #require(edit["id"]?.text); editor.chooseCategory(try #require(edit["field"]?.text), id.isEmpty ? nil : id) }
            #expect(editor.categories == (try selection(row["categories"])))
            #expect(Set(editor.categories.keys) == Set(AppInformation.categoryFields))
            let request = editor.informationRequest(accountId: "synthetic-account", appId: "1000000001"), expected = try #require(row["expected"])
            #expect(request?.contentRightsDeclaration == expected["contentRightsDeclaration"]?.text)
            if expected["categorySelection"] != nil { #expect(request?.categorySelection == (try selection(expected["categorySelection"]))) } else { #expect(request?.categorySelection == nil) }
            #expect(editor.informationChanged == (expected.stringify() != "{}"))
        }
        let catalog = try AppInformation.catalog(resources(fixture["catalog"]))
        for row in try rows(fixture["platformChoices"]) { #expect(AppInformation.choices(catalog, platforms: try strings(row["platforms"])).map(\.id) == (try strings(row["expected"]))) }
        for invalid in try rows(fixture["invalidCatalogs"]) { #expect(throws: PublishFailure.self) { try AppInformation.catalog(resources(invalid)) } }
    }

    @Test func explicitAgeChangesClearRevertAndValidateLikePrimaryEditor() throws {
        let fixture = try fixture(), baseline = try answers(fixture["ages"])
        for row in try rows(fixture["ageCases"]) {
            var editor = AppInformationEditor(); editor.receiveAgeAnswers(baseline)
            for edit in try rows(row["edits"]) { editor.chooseAge(try #require(edit["key"]?.text), edit["value"]) }
            #expect(editor.ageChanges == (try answers(row["expected"])))
            #expect(editor.orderedAgeChanges.count == editor.ageChanges.count)
        }
        for row in try rows(fixture["ageValidation"]) {
            let changes = try answers(row["input"]).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
            if row["valid"] == .bool(true) { try AgeRating.validate(changes) } else { #expect(throws: PublishFailure.self) { try AgeRating.validate(changes) } }
        }
        var editor = AppInformationEditor(); editor.receiveAgeAnswers(["contests": .string("INFREQUENT_OR_MILD")])
        #expect(editor.ageValue("contests") == .string("INFREQUENT_OR_MILD"))
        editor.chooseAge("contests", .string("FREQUENT")); editor.chooseAge("contests", nil)
        #expect(editor.ageChanges.isEmpty && editor.ageValue("contests") == .string("INFREQUENT_OR_MILD"))
        editor.chooseAge("contests", .string("FREQUENT")); editor.ageFailed(); editor.chooseAge("contests", .string("NONE"))
        #expect(!editor.ageReady && editor.ageChanges["contests"] == .string("FREQUENT") && editor.dirty)
        editor.receiveAgeAnswers(["contests": .string("FREQUENT")]); #expect(editor.ageReady && editor.ageChanges.isEmpty && !editor.dirty)
    }

    @Test func availabilityValidationDigestAndSupportedRegionsMatchPrimaryReader() async throws {
        let fixture = try fixture(), (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), app = "1000000001"
        for (index, row) in try rows(fixture["availabilityCases"]).enumerated() {
            let host = "app-settings-availability-\(index).appstoreconnect.test"
            let availability = try #require(row["availability"]), territories = try #require(row["territories"])
            StubProtocol.handle(host) { request in
                let data = request.url!.path.hasSuffix("appAvailabilityV2") ? availability : territories
                return (200, [:], JSONText.object([("data", data)]).data)
            }
            let client = try PublishingTests().client(account, host: host)
            if row["valid"] == .bool(true) {
                let snapshot = try await session.availabilitySnapshot(appId: app, client: client)
                #expect(snapshot.digest == row["digest"]?.text)
                #expect(snapshot.territories.filter(\.supportsOrdinaryChange).map(\.id) == (try strings(row["ordinary"])))
                #expect(snapshot.availableInNewTerritories == true)
            } else { await #expect(throws: PublishFailure.self) { try await session.availabilitySnapshot(appId: app, client: client) } }
        }
    }

    @Test func accessibilityReaderRejectsInvalidOwnersAndAnswersLikePrimary() throws {
        let fixture = try fixture()
        for row in try rows(fixture["accessibilityCases"]) {
            let raw = try resources(row["resources"])
            if row["valid"] == .bool(true) { #expect(try AccessibilityDeclarations.scoped(raw, appId: "1000000001").count == raw.count) }
            else { #expect(throws: PublishFailure.self) { try AccessibilityDeclarations.scoped(raw, appId: "1000000001") } }
        }
    }

    @Test func independentRefreshesRetainEditsAndNeverCopyPublishedAccessibilityIntoDrafts() throws {
        let fixture = try fixture(), current = try state(fixture)
        let firstAccessibility = try #require(rows(fixture["accessibilityCases"]).first)
        let baseline = try declarations(firstAccessibility["expected"])
        var editor = AppInformationEditor(); editor.receive(current); editor.receiveAgeAnswers(try answers(fixture["ages"])); editor.receiveDeclarations(baseline)
        #expect(!editor.dirty && editor.answers(for: "IPAD").isEmpty && !editor.canSaveAccessibility("IPAD"))
        editor.chooseRights("USES_THIRD_PARTY_CONTENT"); editor.chooseCategory("primaryCategory", "PRODUCTIVITY"); editor.chooseAge("kidsAgeBand", .null)
        editor.chooseAccessibility("IPHONE", "supportsVoiceover", false); editor.chooseAccessibility("MAC", "supportsVoiceover", false)
        #expect(editor.answers(for: "IPHONE")["supportsVoiceover"] == false && editor.answers(for: "MAC")["supportsVoiceover"] == false)
        editor.receive(current); editor.receiveDeclarations(baseline)
        #expect(editor.rights == "USES_THIRD_PARTY_CONTENT" && editor.categories["primaryCategory"] == "PRODUCTIVITY" && editor.ageChanges["kidsAgeBand"] == .null)
        #expect(editor.answers(for: "IPHONE")["supportsVoiceover"] == false && editor.answers(for: "MAC")["supportsVoiceover"] == false)
        editor.accessibilityFailed(); #expect(!editor.canSaveAccessibility("IPHONE") && !editor.canPublishAccessibility("IPHONE") && editor.dirty)
        editor.receiveDeclarations(baseline)
        let published = AccessibilityDeclarationView(id: "synthetic-published", family: "IPHONE", state: "PUBLISHED", answers: ["supportsVoiceover": true])
        editor.receiveDeclarations([published]); #expect(editor.answers(for: "IPHONE")["supportsVoiceover"] == false)
        var clean = AppInformationEditor(); clean.receiveDeclarations(baseline); clean.receiveDeclarations([published])
        #expect(clean.answers(for: "IPHONE").isEmpty && !clean.dirty)
        let watch = AccessibilityDeclarationView(id: "synthetic-watch", family: "APPLE_WATCH", state: "DRAFT", answers: Dictionary(uniqueKeysWithValues: AccessibilityDeclarations.features.map { ($0.key, true) }))
        clean.receiveDeclarations([watch]); #expect(clean.answers(for: "APPLE_WATCH").count == AccessibilityDeclarations.applicable("APPLE_WATCH").count && !clean.dirty)
        clean.chooseAccessibility("APPLE_WATCH", "supportsVoiceover", false)
        let savedWatch = AccessibilityDeclarationView(id: watch.id, family: watch.family, state: watch.state, answers: clean.answers(for: "APPLE_WATCH"))
        clean.receiveDeclarations([savedWatch]); #expect(!clean.dirty && clean.canSaveAccessibility("APPLE_WATCH"))
    }

    @Test func failedCategoryReadsRetainOriginalBaselineUntilRetry() throws {
        let fixture = try fixture(); var editor = AppInformationEditor(); editor.receive(try state(fixture)); editor.chooseCategory("primaryCategory", "PRODUCTIVITY")
        let unavailable = AppInformationState(contentRights: "DOES_NOT_USE_THIRD_PARTY_CONTENT", categories: nil, catalog: [], territories: [], categoryError: "Synthetic unavailable categories", availabilityError: "Synthetic unavailable regions")
        editor.receive(unavailable)
        #expect(editor.categoryChanged && editor.dirty && !editor.informationChanged && editor.informationRequest(accountId: "synthetic-account", appId: "1000000001") == nil)
        editor.chooseCategory("primaryCategory", "BUSINESS"); #expect(editor.categories["primaryCategory"] == "PRODUCTIVITY")
        editor.chooseRights("USES_THIRD_PARTY_CONTENT")
        #expect(editor.informationRequest(accountId: "synthetic-account", appId: "1000000001")?.categorySelection == nil)
        editor.receive(try state(fixture)); #expect(editor.categories["primaryCategory"] == "PRODUCTIVITY" && editor.categoryChanged)
        var saved = try selection(fixture["selection"]); saved.updateValue("PRODUCTIVITY", forKey: "primaryCategory")
        editor.receive(try state(fixture, categories: saved)); #expect(!editor.categoryChanged && editor.dirty)
        editor.informationFailed(); #expect(!editor.informationChanged && editor.dirty)
        editor.receive(AppInformationState(contentRights: "USES_THIRD_PARTY_CONTENT", categories: saved, catalog: [], territories: [])); #expect(!editor.dirty)
        try AppInformation.validate(editor.categories)
    }

    @Test func partialAppInformationFailuresPreserveRightsAndExposeUnknownSections() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), app = "1000000001"
        for problem in ["foreign-info", "different-info", "duplicate-catalog", "foreign-version", "missing-platform", "unavailable-regions", "foreign-app"] {
            let host = "app-settings-\(problem).appstoreconnect.test", apple = SyntheticApple()
            StubProtocol.handle(host) { request in
                let response = apple.handle(request), path = request.url!.path
                guard var object = try? JSONSerialization.jsonObject(with: response.2) as? [String: Any] else { return response }
                if problem == "foreign-info" && path.hasSuffix("/appInfos") { object["data"] = [["type": "apps", "id": "foreign", "attributes": [:]]] }
                if problem == "different-info" && path == "/v1/appInfos/info-1", var data = object["data"] as? [String: Any] { data["id"] = "different-info"; object["data"] = data }
                if problem == "duplicate-catalog" && path == "/v1/appCategories", let rows = object["data"] as? [[String: Any]], let first = rows.first { object["data"] = rows + [first] }
                if problem == "foreign-version" && path.hasSuffix("/appStoreVersions") { object["data"] = [["type": "apps", "id": "foreign", "attributes": [:]]] }
                if problem == "missing-platform" && path.hasSuffix("/appStoreVersions"), var rows = object["data"] as? [[String: Any]], var attributes = rows[0]["attributes"] as? [String: Any] {
                    attributes.removeValue(forKey: "platform"); rows[0]["attributes"] = attributes; object["data"] = rows
                }
                if problem == "unavailable-regions" && path.hasSuffix("appAvailabilityV2") { return (404, [:], Data()) }
                if problem == "foreign-app" && path == "/v1/apps/\(app)" { object["data"] = ["type": "apps", "id": "1000000002", "attributes": [:]] }
                return (response.0, response.1, try! JSONSerialization.data(withJSONObject: object))
            }
            let client = try PublishingTests().client(account, host: host)
            if problem == "foreign-app" { await #expect(throws: PublishFailure.self) { try await session.appInformationState(appId: app, client: client) }; continue }
            let state = try await session.appInformationState(appId: app, client: client)
            if problem == "unavailable-regions" { #expect(state.categories != nil && state.availabilityError != nil && state.availableInNewTerritories == nil && state.territories.isEmpty) }
            else { #expect(state.categories == nil && state.catalog.isEmpty && state.categoryError != nil && state.availableInNewTerritories == true && state.territories.count == 2) }
            #expect(apple.writes.isEmpty)
        }
    }

    @Test func ageReadsDistinguishEmptyAnswersFromMissingOrUnrelatedDeclarations() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first)
        for problem in ["empty-answers", "missing-answers", "empty-id", "null-owner", "foreign-owner"] {
            let apple = SyntheticApple(), host = "app-settings-age-\(problem).appstoreconnect.test"
            StubProtocol.handle(host) { request in
                guard request.url!.path.hasSuffix("ageRatingDeclaration") else { return apple.handle(request) }
                var value: [String: Any] = ["type": "ageRatingDeclarations", "id": "synthetic-age", "attributes": [:]]
                if problem == "missing-answers" { value.removeValue(forKey: "attributes") }
                if problem == "empty-id" { value["id"] = "" }
                if problem == "null-owner" { value["relationships"] = ["appInfo": ["data": NSNull()]] }
                if problem == "foreign-owner" { value["relationships"] = ["appInfo": ["data": ["type": "appInfos", "id": "foreign-info"]]] }
                return apple.page(value)
            }
            let client = try PublishingTests().client(account, host: host)
            if problem == "empty-answers" { #expect(try await session.ageRatingAnswers(appId: "1000000001", client: client).isEmpty) }
            else { await #expect(throws: PublishFailure.self) { try await session.ageRatingAnswers(appId: "1000000001", client: client) } }
            #expect(apple.writes.isEmpty)
        }
    }

    @Test func optionalAgeAnswersUseGuardedReviewsAndRejectChangesAfterPreparation() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "app-settings-age-review.appstoreconnect.test", app = "1000000001"
        StubProtocol.handle(host) { apple.handle($0) }; let client = try PublishingTests().client(account, host: host)
        var editor = AppInformationEditor(); editor.receiveAgeAnswers(try await session.ageRatingAnswers(appId: app, client: client))
        editor.chooseAge("kidsAgeBand", .null); editor.chooseAge("ageRatingOverrideV2", .string("THIRTEEN_PLUS")); editor.chooseAge("koreaAgeRatingOverride", .string("FIFTEEN_PLUS")); editor.chooseAge("developerAgeRatingInfoUrl", .string("https://example.com/synthetic-age"))
        var request = PublishRequest(accountId: account.id, appId: app, scope: .ageRating); request.ageRatingChanges = editor.orderedAgeChanges
        let review = try await session.preparePublishing(account: account, request: request, client: client)
        #expect(review.steps.count == 1 && apple.writes.isEmpty && editor.dirty)
        apple.lock.withLock { apple.ageAnswers["advertising"] = true }
        await #expect(throws: PublishFailure.self) { try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: client) }
        #expect(apple.writes.isEmpty && editor.ageChanges.count == 4)
        let fresh = try await session.preparePublishing(account: account, request: request, client: client)
        let completed = try await session.approvePublishing(account: account, appId: app, id: fresh.id, fingerprint: fresh.fingerprint, client: client)
        #expect(completed.state == "complete" && apple.writes.count == 1)
        editor.receiveAgeAnswers(try await session.ageRatingAnswers(appId: app, client: client)); #expect(editor.ageChanges.isEmpty && !editor.dirty)
        await #expect(throws: PublishFailure.self) { try await session.approvePublishing(account: account, appId: app, id: fresh.id, fingerprint: fresh.fingerprint, client: client) }
        #expect(apple.writes.count == 1)
    }
}
