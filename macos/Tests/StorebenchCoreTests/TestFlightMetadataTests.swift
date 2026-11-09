import Foundation
import Testing
@testable import StorebenchCore

final class SyntheticBetaMetadata: @unchecked Sendable {
    let lock = NSLock(), apple = SyntheticApple()
    var appItems: [[String: Any]], notesItems: [[String: Any]]
    var ownerMode = "omitted", relationshipOwner = "owned"
    var licenseForbidden = false, licenseAbsent = false, licenseDuplicate = false
    var reads = 0, notesReads = 0, licenseReads = 0
    var changeOnRead: Int?, changeNotesOnRead: Int?, changeLicenseOnRead: Int?
    var writes: [(String, String, [String: Any])] = []
    init() throws {
        let vector = try JSONSerialization.jsonObject(with: Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/testflight-metadata.json"))) as! [String: Any]
        appItems = [vector["metadataItem"] as! [String: Any]]; notesItems = [vector["notesItem"] as! [String: Any]]
    }
    func owned(_ items: [[String: Any]], relation: String) -> [[String: Any]] {
        items.map { value in
            var item = value
            switch ownerMode {
            case "omitted": item.removeValue(forKey: "relationships")
            case "foreign": item["relationships"] = [relation: ["data": ["type": relation == "app" ? "apps" : "builds", "id": "other-owner"]]]
            case "null": item["relationships"] = [relation: ["data": NSNull()]]
            case "array": item["relationships"] = [relation: ["data": [["type": relation == "app" ? "apps" : "builds", "id": relation == "app" ? "1000000001" : "build-7"]]]]
            default: break
            }
            return item
        }
    }
    func handle(_ request: URLRequest) -> (Int, [String: String], Data) {
        lock.withLock {
            let path = request.url!.path, method = request.httpMethod ?? "GET"
            if method != "GET" {
                let body = try! JSONSerialization.jsonObject(with: apple.body(request)) as! [String: Any], item = body["data"] as! [String: Any], attributes = item["attributes"] as! [String: Any]
                let type = item["type"] as! String
                var reply = item
                guard ["betaAppLocalizations", "betaBuildLocalizations", "betaLicenseAgreements"].contains(type) else { return (400, [:], Data()) }
                if type == "betaLicenseAgreements", method == "PATCH", path == "/v1/betaLicenseAgreements/license-1" { apple.license = attributes["agreementText"] as! String }
                else {
                    var values = type == "betaAppLocalizations" ? appItems : notesItems
                    if method == "POST", path == "/v1/\(type)" {
                        var created = item; created["id"] = "synthetic-created-\(values.count)"; values.append(created); reply = created
                    } else if method == "PATCH", let id = item["id"] as? String, path == "/v1/\(type)/\(id)", let index = values.firstIndex(where: { $0["id"] as? String == id }) {
                        var current = values[index]["attributes"] as! [String: Any]; for (key, value) in attributes { current[key] = value }; values[index]["attributes"] = current
                    } else { return (400, [:], Data()) }
                    if type == "betaAppLocalizations" { appItems = values } else { notesItems = values }
                }
                writes.append((method, path, body)); return apple.page(reply)
            }
            if path.hasPrefix("/v1/betaAppLocalizations/"), path.hasSuffix("/relationships/app") {
                return apple.page(relationshipOwner == "missing" ? NSNull() : ["type": "apps", "id": relationshipOwner == "owned" ? "1000000001" : "1000000002"])
            }
            if path.hasPrefix("/v1/betaBuildLocalizations/"), path.hasSuffix("/relationships/build") {
                return apple.page(["type": "builds", "id": relationshipOwner == "owned" ? "build-7" : "build-other"])
            }
            switch path {
            case "/v1/betaAppLocalizations":
                reads += 1
                if reads == changeOnRead { var fields = appItems[0]["attributes"] as! [String: Any]; fields["privacyPolicyUrl"] = "https://example.com/changed-privacy"; appItems[0]["attributes"] = fields }
                return apple.page(owned(appItems, relation: "app"))
            case "/v1/builds/build-7/betaBuildLocalizations":
                notesReads += 1
                if notesReads == changeNotesOnRead { var fields = notesItems[0]["attributes"] as! [String: Any]; fields["whatsNew"] = "Changed synthetic build notes"; notesItems[0]["attributes"] = fields }
                return apple.page(owned(notesItems, relation: "build"))
            case "/v1/apps/1000000001/betaLicenseAgreement":
                licenseReads += 1
                if licenseReads == changeLicenseOnRead { apple.license = "Changed synthetic terms" }
                if licenseForbidden { return (403, [:], Data()) }
                let item: [String: Any] = ["type": "betaLicenseAgreements", "id": "license-1", "attributes": ["agreementText": apple.license]]
                return apple.page(licenseAbsent ? NSNull() : licenseDuplicate ? [item, item] : item)
            case "/v1/betaLicenseAgreements/license-1/relationships/app":
                return apple.page(["type": "apps", "id": relationshipOwner == "owned" ? "1000000001" : "1000000002"])
            default: return apple.handle(request)
            }
        }
    }
}

@Suite(.serialized) struct TestFlightMetadataTests {
    init() throws { _ = try TestIsolation.require() }
    let app = "1000000001"
    func vector() throws -> JSONText { try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/testflight-metadata.json"))) }
    func resources(_ value: JSONText) throws -> [AppStoreConnectClient.Resource] { try JSONDecoder().decode([AppStoreConnectClient.Resource].self, from: value.data) }
    func request(_ account: Account, action: String = "save-beta-info") -> PublishRequest {
        var value = PublishRequest(accountId: account.id, appId: app, scope: .testflight, buildId: action == "save-build-notes" ? "build-7" : nil)
        value.testflightAction = action
        if action == "save-beta-info" { value.locale = "en-US"; value.betaDescription = "Updated synthetic description"; value.feedbackEmail = "FEEDBACK@example.com" }
        if action == "save-build-notes" { value.locale = "en-US"; value.whatsNew = "Updated synthetic notes" }
        if action == "save-beta-license" { value.agreementText = "Updated synthetic terms" }
        return value
    }
    func approve(_ session: WorkspaceSession, _ account: Account, _ client: AppStoreConnectClient, _ review: PublishReview) async throws -> PublishReview {
        try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: client)
    }
    @Test func linksPrivacyAndContentDigestsMatchWebVectors() throws {
        let value = try vector()
        for (key, validator) in [("metadataUrls", { try TestFlightMetadata.url($0, label: "Synthetic URL") }), ("metadataPolicies", TestFlightMetadata.privacyPolicy)] as [(String, (String) throws -> String)] {
            guard case .array(let items)? = value[key] else { throw JSONText.ParseFailure.invalid }
            for item in items {
                guard let input = item["input"]?.text else { #expect(item["valid"] == .bool(false)); continue }
                if item["valid"] == .bool(true) { #expect(try validator(input) == item["value"]?.text, "Reference accepts \(input)") }
                else { #expect(throws: PublishFailure.self, "Reference rejects \(input)") { try validator(input) } }
            }
        }
        for key in ["metadataDigests", "notesDigests"] {
            guard case .array(let items)? = value[key] else { throw JSONText.ParseFailure.invalid }
            for item in items {
                let resources = try resources(#require(item["resources"]))
                func digest() throws -> String { try key == "metadataDigests" ? TestFlightMetadata.appDigest(appId: app, locale: "en-US", resources: resources) : TestFlightMetadata.notesDigest(buildId: "build-7", locale: "en-US", resources: resources) }
                if item["valid"] == .bool(true) { #expect(try digest() == item["digest"]?.text) }
                else { #expect(throws: PublishFailure.self) { try digest() } }
            }
        }
    }
    @Test func requestValidationUsesWebLengthsTrimAndOptionalPresence() throws {
        let account = Account(id: "synthetic-account", name: "Synthetic account", keyId: "synthetic", keyType: "team", issuerId: "synthetic", appIds: [], appNames: nil)
        var value = request(account); value.betaDescription = "\u{feff}" + String(repeating: "😀", count: 2000) + "\u{feff}"; value.betaMarketingUrl = " \u{feff} "
        let checked = try value.validated()
        #expect(checked.betaDescription?.utf16.count == 4000 && checked.feedbackEmail == "feedback@example.com" && checked.betaMarketingUrl == "")
        #expect(PublishRequest(checked.json)?.json == checked.json)
        value.betaDescription! += "x"; #expect(throws: PublishFailure.self) { try value.validated() }
        for text in ["synthetic\u{b}text", "synthetic\u{7f}text", "\u{feff} "] { value.betaDescription = text; #expect(throws: PublishFailure.self) { try value.validated() } }
        value = request(account, action: "save-build-notes"); value.betaPrivacyPolicyUrl = ""; #expect(throws: PublishFailure.self) { try value.validated() }
        value = request(account); value.feedbackEmail = " feedback@example.com"; #expect(throws: PublishFailure.self) { try value.validated() }
        value = request(account, action: "save-build-notes"); value.locale = "ar-SA"; #expect(throws: PublishFailure.self) { try value.validated() }
    }
    @Test func omittedFieldsStaySavedAndChangesNeedOneExplicitApproval() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), model = try SyntheticBetaMetadata(), host = "beta-metadata-preserve.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        StubProtocol.handle(host) { model.handle($0) }
        let review = try await session.preparePublishing(account: account, request: request(account), client: client)
        #expect(model.writes.isEmpty && review.steps.count == 1)
        let step = try #require(review.steps.first)
        #expect(step.body?["data"]?["attributes"] == .object([("description", .string("Updated synthetic description")), ("feedbackEmail", .string("feedback@example.com"))]))
        #expect(step.after?.contains("https://example.com/privacy") == true && step.after?.contains("Synthetic privacy text") == true)
        #expect(try await approve(session, account, client, review).state == "complete")
        await #expect(throws: PublishFailure.used) { try await approve(session, account, client, review) }
        #expect(try await session.preparePublishing(account: account, request: request(account), client: client).steps.isEmpty)
        let saved = try await session.testFlightAppInformation(appId: app, client: client)
        #expect(saved.first?.marketingUrl == "https://example.com/synthetic" && saved.first?.tvOsPrivacyPolicy == "Synthetic privacy text\nSecond line")
    }
    @Test func optionalValuesCanBeReplacedButExistingValuesCannotBeCleared() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), model = try SyntheticBetaMetadata(), host = "beta-metadata-optional.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        StubProtocol.handle(host) { model.handle($0) }
        for field in TestFlightMetadata.optionalFields {
            var value = request(account)
            if field == "marketingUrl" { value.betaMarketingUrl = "" }; if field == "privacyPolicyUrl" { value.betaPrivacyPolicyUrl = "" }; if field == "tvOsPrivacyPolicy" { value.betaTvOsPrivacyPolicy = "\u{feff} " }
            await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: value, client: client) }
        }
        var replacement = request(account); replacement.betaMarketingUrl = "https://example.com/next"; replacement.betaTvOsPrivacyPolicy = " Updated synthetic privacy "
        let review = try await session.preparePublishing(account: account, request: replacement, client: client)
        #expect(review.steps.first?.body?["data"]?["attributes"]?["marketingUrl"] == .string("https://example.com/next"))
        #expect(review.steps.first?.body?["data"]?["attributes"]?["privacyPolicyUrl"] == nil)
        #expect(try await approve(session, account, client, review).state == "complete" && model.writes.count == 1)
    }
    @Test func missingLocalizationCreatesOnlyTheSelectedLanguage() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), model = try SyntheticBetaMetadata(), host = "beta-metadata-create.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        StubProtocol.handle(host) { model.handle($0) }
        var value = request(account); value.locale = "sv"; value.betaMarketingUrl = ""; value.betaPrivacyPolicyUrl = "https://example.com/new-privacy"
        let review = try await session.preparePublishing(account: account, request: value, client: client)
        #expect(review.steps.first?.method == "POST" && review.steps.first?.body?["data"]?["attributes"]?["locale"] == .string("sv"))
        #expect(review.steps.first?.body?["data"]?["attributes"]?["marketingUrl"] == nil)
        #expect(try await approve(session, account, client, review).state == "complete" && model.appItems.count == 2)
        #expect((model.appItems[0]["attributes"] as? [String: Any])?["description"] as? String == "Synthetic tester description å🎉")
    }
    @Test func foreignAmbiguousAndMalformedLanguageListsFailClosed() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), model = try SyntheticBetaMetadata(), host = "beta-metadata-scope.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        StubProtocol.handle(host) { model.handle($0) }
        for mode in ["foreign", "null", "array"] {
            model.ownerMode = mode
            await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: request(account), client: client) }
            await #expect(throws: PublishFailure.self) { try await session.whatToTest(appId: app, buildId: "build-7", client: client) }
        }
        model.ownerMode = "omitted"
        for mode in ["foreign", "missing"] { model.relationshipOwner = mode; await #expect(throws: PublishFailure.self) { try await session.testFlightAppInformation(appId: app, client: client) } }
        model.relationshipOwner = "owned"; model.ownerMode = "owned"
        let original = model.appItems[0]
        for mutation in ["duplicate-id", "duplicate-locale", "other-language-owner", "bad-attribute"] {
            model.appItems = [original]; var other = original
            if mutation == "duplicate-id" { model.appItems.append(other) }
            if mutation == "duplicate-locale" { other["id"] = "beta-other"; model.appItems.append(other) }
            if mutation == "other-language-owner" { other["id"] = "beta-other"; var fields = other["attributes"] as! [String: Any]; fields["locale"] = "sv"; other["attributes"] = fields; other["relationships"] = ["app": ["data": ["type": "apps", "id": "1000000002"]]]; model.appItems.append(other) }
            if mutation == "bad-attribute" { var fields = original["attributes"] as! [String: Any]; fields["marketingUrl"] = 2; model.appItems[0]["attributes"] = fields }
            await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: request(account), client: client) }
        }
        #expect(model.writes.isEmpty)
    }
    @Test func privacyChangesAtApprovalAndImmediatelyBeforeWriteStopPublication() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), model = try SyntheticBetaMetadata(), host = "beta-metadata-stale.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        StubProtocol.handle(host) { model.handle($0) }
        let initial = try await session.preparePublishing(account: account, request: request(account), client: client)
        model.changeOnRead = model.reads + 1
        await #expect(throws: PublishFailure.conflict) { try await approve(session, account, client, initial) }
        let late = try await session.preparePublishing(account: account, request: request(account), client: client)
        model.lock.withLock { var fields = model.appItems[0]["attributes"] as! [String: Any]; fields["privacyPolicyUrl"] = "https://example.com/privacy"; model.appItems[0]["attributes"] = fields }
        // Prepare again from the restored baseline, then change at the per-write check.
        let fresh = try await session.preparePublishing(account: account, request: request(account), client: client)
        model.changeOnRead = model.reads + 2
        #expect(try await approve(session, account, client, fresh).state == "failed")
        #expect(model.writes.isEmpty && late.id != fresh.id)
    }
    @Test func buildNotesAndLicenseRevalidateOwnedContentBeforeWriting() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), model = try SyntheticBetaMetadata(), host = "beta-metadata-notes-license.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        StubProtocol.handle(host) { model.handle($0) }
        #expect(try await session.whatToTest(appId: app, buildId: "build-7", client: client)["en-US"] == "Synthetic build notes å🎉")
        let notes = try await session.preparePublishing(account: account, request: request(account, action: "save-build-notes"), client: client)
        model.changeNotesOnRead = model.notesReads + 2
        #expect(try await approve(session, account, client, notes).state == "failed" && model.writes.isEmpty)
        let license = try await session.preparePublishing(account: account, request: request(account, action: "save-beta-license"), client: client)
        model.changeLicenseOnRead = model.licenseReads + 2
        #expect(try await approve(session, account, client, license).state == "failed" && model.writes.isEmpty)
        let fresh = try await session.preparePublishing(account: account, request: request(account, action: "save-beta-license"), client: client)
        #expect(try await approve(session, account, client, fresh).state == "complete" && model.writes.count == 1)
    }
    @Test func licenseErrorsDoNotPreventReadingAppInformation() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), model = try SyntheticBetaMetadata(), host = "beta-metadata-license-errors.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        StubProtocol.handle(host) { model.handle($0) }
        model.licenseForbidden = true
        #expect(try await session.testFlightAppInformation(appId: app, client: client).count == 1)
        await #expect(throws: AppStoreConnectClient.Failure.self) { try await session.testFlightBetaLicense(appId: app, client: client) }
        model.licenseForbidden = false; model.licenseAbsent = true
        #expect(try await session.testFlightBetaLicense(appId: app, client: client) == nil)
        model.licenseAbsent = false; model.licenseDuplicate = true
        await #expect(throws: PublishFailure.self) { try await session.testFlightBetaLicense(appId: app, client: client) }
        model.licenseDuplicate = false; model.relationshipOwner = "foreign"
        await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: request(account, action: "save-beta-license"), client: client) }
        #expect(model.writes.isEmpty)
    }
    @Test func writeVerifierRejectsExtraAttributesAndClearingOptionalValues() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), model = try SyntheticBetaMetadata(), host = "beta-metadata-write-guard.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        StubProtocol.handle(host) { model.handle($0) }
        let review = try await session.preparePublishing(account: account, request: request(account), client: client), step = try #require(review.steps.first)
        for extra in [("marketingUrl", JSONText.string("")), ("privacyPolicyUrl", .string("http://example.com")), ("unexpected", .bool(true))] {
            let data = JSONText.object([("type", .string("betaAppLocalizations")), ("id", .string("beta-app-1")), ("attributes", .object([("description", .string("Synthetic")), ("feedbackEmail", .string("feedback@example.com")), extra]))])
            await #expect(throws: PublishFailure.self) { try await session.verifyTestFlightContent(root: "betaAppLocalizations", method: "PATCH", parts: ["betaAppLocalizations", "beta-app-1"], data: data, guardValue: step.guardValue, appId: app, client: client) }
        }
        #expect(model.writes.isEmpty)
    }
    @Test func accountChangeDuringTheLastAppleReadPreventsTheApprovedWrite() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), model = try SyntheticBetaMetadata(), host = "beta-metadata-account-change.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        let database = EncryptedDocumentStore.databaseURL(root: root)
        StubProtocol.handle(host) { request in
            let result = model.handle(request)
            if request.url?.path == "/v1/betaAppLocalizations", model.reads == 3 {
                // A separate owned fixture connection changes the account at the asynchronous read boundary.
                let store = try! EncryptedDocumentStore(url: database, key: Data(0..<32), writable: true)
                try! store.transaction { read in
                    let document = try read("accounts", "all")!, items = WorkspaceSession.items(try JSONText.parse(document.payload))
                    return [.put(namespace: "accounts", key: "all", json: JSONText.array(items.map { $0["id"]?.text == account.id ? $0.setting("keyId", .string("SAMPLE0002")) : $0 }).data)]
                }
            }
            return result
        }
        let review = try await session.preparePublishing(account: account, request: request(account), client: client)
        #expect(try await approve(session, account, client, review).state == "failed")
        #expect(model.reads == 3 && model.writes.isEmpty)
    }
}
