import CryptoKit
import Foundation
import Testing
import StorebenchTestSupport
@testable import StorebenchCore

typealias SyntheticApple = StorebenchTestSupport.SyntheticApple

extension WorkspaceSession {
    func waitForLibraryProcessing(_ wait: LibraryProcessingWait) { libraryProcessingWait = wait }
}

@Suite(.serialized) struct PublishingTests {
    init() throws { _ = try TestIsolation.require() }
    func client(_ account: Account, host: String) throws -> AppStoreConnectClient {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubProtocol.self]
        return AppStoreConnectClient(token: try AppleToken(account: account, privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation), origin: URL(string: "https://\(host)")!, configuration: configuration)
    }

    @Test func agreementFailureAfterApprovalRetainsOnlyPublicGuidanceAndConsumesReview() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "agreement-publishing.appstoreconnect.test", app = "1000000001"
        apple.setVersionState("READY_FOR_DISTRIBUTION")
        let body = JSONText.object([("errors", .array([.object([("code", .string("FORBIDDEN.REQUIRED_AGREEMENTS_MISSING_OR_EXPIRED")), ("detail", .string("Synthetic upstream text must not be saved"))])]))]).data
        StubProtocol.handle(host) { request in
            if request.httpMethod == "GET" { return apple.handle(request) }
            return (403, ["Content-Type": "application/json"], body)
        }
        _ = try await session.saveReleasePlan(account: account, appId: app, start: .empty(platform: "IOS", locale: "en-US"), sourceRevisionId: nil, baseVersionId: nil, targetVersion: "2.0", releaseType: "MANUAL", earliestReleaseDate: nil, expected: "null")
        let client = try client(account, host: host)
        let review = try await session.preparePublishing(account: account, request: PublishRequest(accountId: account.id, appId: app, scope: .release), client: client)
        #expect(StubProtocol.requests(host).allSatisfy { $0.httpMethod == "GET" })
        let result = try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: client)
        #expect(result.state == "failed")
        #expect(result.error?.contains("Apple requires updated terms") == true)
        #expect(result.error?.contains("Synthetic upstream text") == false)
        #expect(result.error?.contains("prepare a new review") == true)
        #expect(StubProtocol.requests(host).filter { $0.httpMethod != "GET" }.count == 1)
        await #expect(throws: PublishFailure.used) { try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: client) }
        #expect(StubProtocol.requests(host).filter { $0.httpMethod != "GET" }.count == 1)
    }

    @Test func publishingRefusesAnotherClientOrChangedConfiguredCredentials() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "account-scope.appstoreconnect.test", app = "1000000001"
        StubProtocol.handle(host) { apple.handle($0) }
        let current = try client(account, host: host)
        let foreignAccount = Account(id: "another-synthetic-account", name: "Synthetic other account", keyId: "SAMPLE0002", keyType: account.keyType, issuerId: account.issuerId, appIds: [app], appNames: nil)
        let foreign = try client(foreignAccount, host: host)
        let request = PublishRequest(accountId: account.id, appId: app, scope: .versionCopyright, versionId: "version-1", copyright: "2026 Synthetic Studio")
        await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: request, client: foreign) }
        #expect(try await session.publishHistory(accountId: account.id, appId: app).isEmpty)
        let review = try await session.preparePublishing(account: account, request: request, client: current)
        await #expect(throws: PublishFailure.self) { try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: foreign) }
        try await session.storeAccess { store in
            try store.transaction { read in
                let document = try #require(try read("accounts", "all")), items = WorkspaceSession.items(try JSONText.parse(document.payload))
                return [.put(namespace: "accounts", key: "all", json: JSONText.array(items.map { $0["id"]?.text == account.id ? $0.setting("keyId", .string("SAMPLE0002")) : $0 }).data)]
            }
        }
        await #expect(throws: PublishFailure.self) { try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: current) }
        #expect(apple.writes.isEmpty)
        #expect(try await session.publishReview(accountId: account.id, appId: app, id: review.id).state == "prepared")
    }

    @Test func aPlannedVersionIsCreatedOnlyAfterOneApproval() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "release.appstoreconnect.test"
        apple.setVersionState("READY_FOR_DISTRIBUTION")
        StubProtocol.handle(host) { apple.handle($0) }
        _ = try await session.saveReleasePlan(account: account, appId: "1000000001", start: .empty(platform: "IOS", locale: "en-US"), sourceRevisionId: nil, baseVersionId: nil, targetVersion: "2.0", releaseType: "MANUAL", earliestReleaseDate: nil, expected: "null")
        let client = try client(account, host: host)
        let review = try await session.preparePublishing(account: account, request: PublishRequest(accountId: account.id, appId: "1000000001", scope: .release), client: client)
        #expect(review.title == "Create version 2.0" && review.steps.map(\.label) == ["Create iOS version 2.0"] && apple.writes.isEmpty)
        await #expect(throws: PublishFailure.expired) { try await session.approvePublishing(account: account, appId: "1000000001", id: review.id, fingerprint: String(repeating: "0", count: 64), client: client) }
        #expect(apple.writes.isEmpty)
        let done = try await session.approvePublishing(account: account, appId: "1000000001", id: review.id, fingerprint: review.fingerprint, client: client)
        #expect(done.state == "complete" && done.steps.allSatisfy { $0.state == "done" } && done.steps[0].resultId == "version-new-1")
        #expect(apple.writes.count == 1 && apple.writes[0].1 == "/v1/appStoreVersions")
        let attributes = (apple.writes[0].2?["data"] as? [String: Any])?["attributes"] as? [String: Any]
        #expect(attributes?["versionString"] as? String == "2.0" && attributes?["releaseType"] as? String == "MANUAL" && attributes?["platform"] as? String == "IOS")
        await #expect(throws: PublishFailure.used) { try await session.approvePublishing(account: account, appId: "1000000001", id: review.id, fingerprint: review.fingerprint, client: client) }
        #expect(try await session.publishHistory(accountId: account.id, appId: "1000000001").first?.state == "complete")
    }

    /// A Save that stopped before its upload leaves a reservation at Apple. The next review removes this Mac's own leftover and
    /// reserves the file again, so old attempts never block saving.
    @Test func aStoppedUploadIsCleanedUpByTheNextReview() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "material-retry.appstoreconnect.test", revision = "00000000-0000-4000-8000-000000000002"
        StubProtocol.handle(host) { apple.handle($0) }
        let png = syntheticPNG(width: 1290, height: 2796, seed: 7)
        var blobFails = true
        StubProtocol.handle("synthetic.blobstore.apple.com") { request in
            apple.lock.withLock {
                if blobFails { return (500, [:], Data()) }
                apple.uploaded = apple.body(request); return (200, [:], Data())
            }
        }
        _ = try await session.addScreenshots(accountId: account.id, appId: "1000000001", revisionId: revision, localizationId: "version-locale-1", setId: "set-1", files: [("retry.png", png)])
        let set = try await session.screenshotSet(accountId: account.id, appId: "1000000001", revisionId: revision, setId: "set-1")
        try await session.saveScreenshotLayout(accountId: account.id, appId: "1000000001", revisionId: revision, setId: "set-1", order: set.items.map(\.id), hidden: ["shot-1"], expected: set.signature)
        let client = try client(account, host: host)
        let request = PublishRequest(accountId: account.id, appId: "1000000001", scope: .metadata, revisionId: revision, versionId: "version-1")

        let first = try await session.preparePublishing(account: account, request: request, client: client)
        let stopped = try await session.approvePublishing(account: account, appId: "1000000001", id: first.id, fingerprint: first.fingerprint, client: client)
        #expect(stopped.state == "failed")
        #expect(apple.lock.withLock { apple.libraryImages.map { ($0["id"] as! String, ($0["attributes"] as! [String: Any])["state"] as! String) }.last.map { $0.1 } } == "AWAITING_UPLOAD")

        apple.lock.withLock { blobFails = false }
        let retry = try await session.preparePublishing(account: account, request: request, client: client)
        #expect(retry.steps.map(\.label).contains("Remove unfinished upload · retry.png"))
        #expect(retry.steps.firstIndex { $0.label == "Remove unfinished upload · retry.png" }! < retry.steps.firstIndex { $0.label == "Upload retry.png · en-US" }!)
        let done = try await session.approvePublishing(account: account, appId: "1000000001", id: retry.id, fingerprint: retry.fingerprint, client: client)
        #expect(done.state == "complete", "\(done.error ?? "")")
        #expect(apple.uploaded == png)
        let states = apple.lock.withLock { apple.libraryImages.map { ($0["attributes"] as! [String: Any])["state"] as! String } }
        #expect(!states.contains("AWAITING_UPLOAD"))
        // Nothing is left to clean up afterwards.
        #expect(try await session.preparePublishing(account: account, request: request, client: client).steps.allSatisfy { !$0.label.hasPrefix("Remove unfinished upload") })
    }

    /// Every file is uploaded before the review waits for Apple's processing, and a file an earlier Save left processing is
    /// waited for instead of uploaded again.
    @Test func filesUploadBeforeProcessingIsAwaitedAndProcessingFilesAreNotUploadedAgain() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "material-processing.appstoreconnect.test", revision = "00000000-0000-4000-8000-000000000002"
        StubProtocol.handle(host) { apple.handle($0) }
        StubProtocol.handle("synthetic.blobstore.apple.com") { request in apple.lock.withLock { apple.uploaded = apple.body(request) }; return (200, [:], Data()) }
        let files = [("first.png", syntheticPNG(width: 1290, height: 2796, seed: 11)), ("second.png", syntheticPNG(width: 1290, height: 2796, seed: 12))]
        _ = try await session.addScreenshots(accountId: account.id, appId: "1000000001", revisionId: revision, localizationId: "version-locale-1", setId: "set-1", files: files)
        let set = try await session.screenshotSet(accountId: account.id, appId: "1000000001", revisionId: revision, setId: "set-1")
        try await session.saveScreenshotLayout(accountId: account.id, appId: "1000000001", revisionId: revision, setId: "set-1", order: set.items.map(\.id), hidden: ["shot-1"], expected: set.signature)
        let client = try client(account, host: host)
        let request = PublishRequest(accountId: account.id, appId: "1000000001", scope: .metadata, revisionId: revision, versionId: "version-1")

        let first = try await session.preparePublishing(account: account, request: request, client: client)
        let media = first.steps.map(\.label).filter { $0.contains("first.png") || $0.contains("second.png") }
        #expect(media == ["Upload first.png · en-US", "Upload first.png", "Complete upload · first.png", "Upload second.png · en-US", "Upload second.png", "Complete upload · second.png", "Verify first.png", "Verify second.png"])

        // Apple is still processing when the review checks the first file, and every read of it fails until the wait ends:
        // the review stops there.
        await session.waitForLibraryProcessing(LibraryProcessingWait(limit: .seconds(1), retry: .milliseconds(10), poll: .milliseconds(10)))
        apple.lock.withLock { apple.processingAfterCommit = true; apple.failProcessingReads = true }
        let stopped = try await session.approvePublishing(account: account, appId: "1000000001", id: first.id, fingerprint: first.fingerprint, client: client)
        #expect(stopped.state == "failed" && stopped.steps.first { $0.state == "failed" }?.label == "Verify first.png")
        #expect(stopped.error?.contains("still processing") == true, "\(stopped.error ?? "")")

        // The next review waits for both processing files instead of reserving and uploading them again.
        apple.lock.withLock { apple.failProcessingReads = false }
        let retry = try await session.preparePublishing(account: account, request: request, client: client)
        let labels = retry.steps.map(\.label)
        #expect(labels.contains("Verify first.png") && labels.contains("Verify second.png"))
        #expect(!labels.contains { $0.hasPrefix("Upload first.png") || $0.hasPrefix("Upload second.png") || $0.hasPrefix("Remove unfinished upload") })
        apple.lock.withLock { apple.finishProcessingOnRead = true }
        let done = try await session.approvePublishing(account: account, appId: "1000000001", id: retry.id, fingerprint: retry.fingerprint, client: client)
        #expect(done.state == "complete", "\(done.error ?? "")")
        #expect(apple.lock.withLock { apple.placements.count } == 2)
        #expect(PublishingReviewPresentation.progress(stopped).hasPrefix("6 of ") && PublishingReviewPresentation.progress(stopped).contains("Stopped at: Verify first.png"))
    }

    @Test func anAssetLibraryUploadOnlyUploadsAndTheSaveAfterItAddsTheFiles() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "upload-stage.appstoreconnect.test", revision = "00000000-0000-4000-8000-000000000002"
        StubProtocol.handle(host) { apple.handle($0) }
        let png = syntheticPNG(width: 1290, height: 2796, seed: 44)
        StubProtocol.handle("synthetic.blobstore.apple.com") { request in apple.lock.withLock { apple.uploaded = apple.body(request) }; return (200, [:], Data()) }
        let text = try await session.textDraft(accountId: account.id, appId: "1000000001", revisionId: revision, localizationId: "version-locale-1", scope: .version)
        var fields = text.fields; fields["promotionalText"] = "Synthetic promotion"
        try await session.saveTextDraft(accountId: account.id, appId: "1000000001", revisionId: revision, localizationId: "version-locale-1", scope: .version, fields: fields, fingerprint: text.fingerprint)
        _ = try await session.addScreenshots(accountId: account.id, appId: "1000000001", revisionId: revision, localizationId: "version-locale-1", setId: "set-1", files: [("staged.png", png)])
        let set = try await session.screenshotSet(accountId: account.id, appId: "1000000001", revisionId: revision, setId: "set-1")
        try await session.saveScreenshotLayout(accountId: account.id, appId: "1000000001", revisionId: revision, setId: "set-1", order: set.items.map(\.id), hidden: ["shot-1"], expected: set.signature)
        let client = try client(account, host: host)

        // The upload neither changes the version nor waits for Apple's processing, so a slow file cannot stop it.
        var upload = PublishRequest(accountId: account.id, appId: "1000000001", scope: .metadata, revisionId: revision, versionId: "version-1"); upload.mediaStage = PublishRequest.uploadStage
        let staged = try await session.preparePublishing(account: account, request: upload, client: client)
        #expect(staged.title.hasPrefix("Upload to Asset Library") && staged.steps.map(\.label) == ["Upload staged.png · en-US", "Upload staged.png", "Complete upload · staged.png"])
        #expect(ReleaseMediaProgress(staged)?.files.map(ReleaseMediaProgress(staged)!.status) == ["Upload to Asset Library"])
        let uploaded = try await session.approvePublishing(account: account, appId: "1000000001", id: staged.id, fingerprint: staged.fingerprint, client: client)
        #expect(uploaded.state == "complete" && apple.uploaded == png, "\(uploaded.error ?? "")")
        #expect(!apple.writes.contains { $0.1.hasPrefix("/v1/appAssetLibraryPlacement") || $0.1.hasPrefix("/v1/appStoreVersionLocalizations") })
        #expect(ReleaseMediaProgress(uploaded)?.summary == "1 of 1 files in Asset Library")
        await #expect(throws: PublishFailure.noChanges) { try await session.preparePublishing(account: account, request: upload, client: client) }

        // Save then adds the uploaded file to the version with the text, without uploading it again, even when Apple's read of
        // the language leaves out its version link.
        apple.lock.withLock { apple.localeReadsOmitOwner = true }
        let save = try await session.preparePublishing(account: account, request: PublishRequest(accountId: account.id, appId: "1000000001", scope: .metadata, revisionId: revision, versionId: "version-1"), client: client)
        #expect(!save.steps.contains { $0.kind == .upload } && save.steps.contains { $0.label == "Add screenshot · en-US" } && save.steps.contains { $0.label == "Update version text · en-US" })
        let saved = try await session.approvePublishing(account: account, appId: "1000000001", id: save.id, fingerprint: save.fingerprint, client: client)
        #expect(saved.state == "complete", "\(saved.error ?? "")")
        #expect(ReleaseMediaProgress(saved)?.files.map(ReleaseMediaProgress(saved)!.status) == ["Added to this version"])
    }

    @Test func applesRefusalBecomesProblemsWithCodesFieldsAndPlacesToFixThem() throws {
        let body = try JSONSerialization.data(withJSONObject: ["errors": [
            ["status": "409", "code": "STATE_ERROR.ENTITY_STATE_INVALID", "title": "Synthetic private title", "detail": "Synthetic App Name is missing things",
             "meta": ["associatedErrors": [
                "/v1/ageRatingDeclarations/synthetic-1": [["code": "ENTITY_ERROR.ATTRIBUTE.REQUIRED", "detail": "synthetic detail", "source": ["pointer": "/data/attributes/lootBox"]]],
                "/v1/appStoreReviewDetails/synthetic-2": [["code": "ENTITY_ERROR.ATTRIBUTE.REQUIRED", "source": ["pointer": "/data/attributes/contactEmail"]]],
                "/v1/syntheticThings/synthetic-3": [["code": "ENTITY_ERROR.SYNTHETIC_UNKNOWN"], ["code": "lowercase-not-a-code"], ["code": "ENTITY_ERROR.ATTRIBUTE.REQUIRED", "source": ["pointer": "/data/attributes/x?token=synthetic"]]]]]]]])
        let problems = AppleProblem.parse(data: body, contentType: "application/json")
        let areas: [String] = problems.map { $0.area.rawValue }
        #expect(areas.count == 4 && Set(areas) == ["age-rating", "review-info", "other"])
        #expect(problems.first { $0.area == .ageRating }?.label == "Loot boxes or randomized items" && problems.first { $0.area == .reviewInformation }?.label == "Email")
        #expect(AppleProblem.Area.ageRating.check == "age-rating" && AppleProblem.Area.other.check == nil && AppleProblem.Area.privacy.action == "Answer App Privacy" && AppleProblem.Area.tax.action == "Choose Tax Category")
        // Unsafe field paths and malformed codes never become codes, resources or fields; Apple's reason is kept apart as one plain line.
        let text = problems.map { "\($0.code) \($0.resource ?? "") \($0.field ?? "")" }.joined()
        #expect(!text.contains("Synthetic") && !text.contains("token") && !text.contains("lowercase"))
        #expect(problems.first { $0.area == .ageRating }?.detail == "synthetic detail")
        #expect(AppleProblem(code: "ENTITY_ERROR.ATTRIBUTE.INVALID", resource: nil, field: nil, detail: "Line one\n\u{0007}line\ttwo ").detail == "Line one line two")
        #expect(problems.allSatisfy { AppleProblem(json: $0.json) == $0 })
        #expect(AppleProblem.summary(problems, status: 409).hasPrefix("Apple needs 4 answers before it accepts this change, in Age Ratings, App Review Information, Other."))
        #expect(AppleProblem.parse(data: Data("not json".utf8), contentType: "application/json").isEmpty)
        // Apple's state codes that name a whole section get its words and the place to fix it.
        let privacy = AppleProblem(code: "STATE_ERROR.APP_DATA_USAGES_REQUIRED", resource: nil, field: nil), price = AppleProblem(code: "STATE_ERROR.APP_PRICING_REQUIRED", resource: nil, field: nil)
        #expect(privacy.area == .privacy && privacy.label == "App Privacy answers are not published")
        #expect(price.area == .pricing && price.label == "No price is set" && AppleProblem.Area.pricing.action == "Open Pricing")
        #expect(AppleProblem(code: "STATE_ERROR.SYNTHETIC_THING_REQUIRED", resource: nil, field: nil).label == "Synthetic thing required")
    }

    /// A refusal that names no field still belongs to the record the write sent, and its one reason is the stop's sentence.
    @Test func aRefusalWithoutAFieldBelongsToTheSentRecordAndSaysApplesReason() throws {
        let body = try JSONSerialization.data(withJSONObject: ["errors": [["status": "409", "code": "ENTITY_ERROR.ATTRIBUTE.INVALID", "detail": "Synthetic declarations need another answer."]]])
        let problems = AppleProblem.parse(data: body, contentType: "application/json", resource: "appEncryptionDeclarations")
        #expect(problems.count == 1 && problems[0].area == .exportCompliance && problems[0].resource == "appEncryptionDeclarations")
        #expect(AppleProblem.summary(problems, status: 409) == "Apple refused this change in Export Compliance: Synthetic declarations need another answer.")
        #expect(AppleProblem.parse(data: body, contentType: "application/json", resource: "not a name?")[0].area == .other)
        #expect(AppleProblem(json: problems[0].json) == problems[0])
        let pointed = AppleProblem(code: "ENTITY_ERROR.ATTRIBUTE.INVALID", resource: nil, field: "availableOnFrenchStore")
        #expect(pointed.area == .exportCompliance && pointed.label == "Available on the App Store in France")
    }

    @Test func unansweredAgeRatingsAreNamedBeforeAddForReview() throws {
        var answers: [(String, JSONText)] = AgeRating.frequency.map { ($0.0, .string("NONE")) } + AgeRating.boolean.map { ($0.0, .bool(false)) }
        #expect(AgeRating.unanswered(.object(answers)).isEmpty)
        answers.removeAll { $0.0 == "lootBox" }; answers.append(("gambling", .null))
        #expect(Set(AgeRating.unanswered(.object(answers))) == ["lootBox", "gambling"])
        // Age restricted social media is asked only when the app has social media.
        answers = answers.map { $0.0 == "socialMedia" ? ($0.0, .bool(true)) : $0 }.filter { $0.0 != "socialMediaAgeRestricted" }
        #expect(AgeRating.unanswered(.object(answers)).contains("socialMediaAgeRestricted"))
    }

    @Test func independentMediaAndTextSyncsLeaveNoDuplicateChangesForStep3() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "split-stages.appstoreconnect.test", revision = "00000000-0000-4000-8000-000000000002"
        StubProtocol.handle(host) { request in
            let response = apple.handle(request)
            // This journey observes Apple's saved text on the next read, just as it observes completed media placements.
            if request.httpMethod == "PATCH", request.url?.path.hasPrefix("/v1/appStoreVersionLocalizations/") == true {
                apple.lock.withLock {
                    let data = apple.writes.last?.2?["data"] as? [String: Any]
                    var attributes = apple.locales[0]["attributes"] as! [String: Any]
                    for (key, value) in (data?["attributes"] as? [String: Any]) ?? [:] { attributes[key] = value }
                    apple.locales[0]["attributes"] = attributes
                }
            }
            return response
        }
        let png = syntheticPNG(width: 1290, height: 2796, seed: 46)
        StubProtocol.handle("synthetic.blobstore.apple.com") { request in apple.lock.withLock { apple.uploaded = apple.body(request) }; return (200, [:], Data()) }
        let text = try await session.textDraft(accountId: account.id, appId: "1000000001", revisionId: revision, localizationId: "version-locale-1", scope: .version)
        var fields = text.fields; fields["promotionalText"] = "Synthetic split promotion"
        try await session.saveTextDraft(accountId: account.id, appId: "1000000001", revisionId: revision, localizationId: "version-locale-1", scope: .version, fields: fields, fingerprint: text.fingerprint)
        _ = try await session.addScreenshots(accountId: account.id, appId: "1000000001", revisionId: revision, localizationId: "version-locale-1", setId: "set-1", files: [("split.png", png)])
        let set = try await session.screenshotSet(accountId: account.id, appId: "1000000001", revisionId: revision, setId: "set-1")
        try await session.saveScreenshotLayout(accountId: account.id, appId: "1000000001", revisionId: revision, setId: "set-1", order: set.items.map(\.id), hidden: ["shot-1"], expected: set.signature)
        let client = try client(account, host: host)
        func request(_ stage: String) -> PublishRequest { var request = PublishRequest(accountId: account.id, appId: "1000000001", scope: .metadata, revisionId: revision, versionId: "version-1"); request.mediaStage = stage; return request }

        let screenshots = try await session.preparePublishing(account: account, request: request(PublishRequest.screenshotsStage), client: client)
        #expect(screenshots.title.hasPrefix("Save to App Previews and Screenshots") && screenshots.steps.contains { $0.label == "Add screenshot · en-US" })
        #expect(!screenshots.steps.contains { $0.label.hasPrefix("Update version text") })
        #expect(screenshots.notes.contains { $0.hasSuffix("Any remaining text and Copyright can be synced individually or in step 3; matching content is not sent again.") })
        let texts = try await session.preparePublishing(account: account, request: request(PublishRequest.textStage), client: client)
        #expect(texts.steps.contains { $0.label == "Update version text · en-US" })
        #expect(!texts.steps.contains { $0.path.first?.text?.hasPrefix("appAssetLibrary") == true || $0.kind == .upload || $0.kind == .verify })

        let saved = try await session.approvePublishing(account: account, appId: "1000000001", id: screenshots.id, fingerprint: screenshots.fingerprint, client: client)
        #expect(saved.state == "complete", "\(saved.error ?? "")")
        #expect(!apple.writes.contains { $0.1.hasPrefix("/v1/appStoreVersionLocalizations") })
        // Saved again with nothing new, the screenshots Save has nothing to send.
        await #expect(throws: PublishFailure.noChanges) { try await session.preparePublishing(account: account, request: request(PublishRequest.screenshotsStage), client: client) }
        #expect(try await session.approvePublishing(account: account, appId: "1000000001", id: texts.id, fingerprint: texts.fingerprint, client: client).state == "complete")
        let writes = apple.lock.withLock { apple.writes.count }
        var combined = request(PublishRequest.textStage); combined.mediaStage = nil
        let remaining = try await session.preparePublishing(account: account, request: combined, client: client)
        #expect(remaining.steps.isEmpty, "Step 3 must not send text or screenshots already synced individually")
        #expect(apple.lock.withLock { apple.writes.count } == writes, "Comparing completed syncs only reads Apple")
    }

    @Test func missingCopyrightHasAnInAppFixAndSyncsWithoutResendingTheListing() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "copyright-fix.appstoreconnect.test", app = "1000000001"
        StubProtocol.handle(host) { apple.handle($0) }
        let client = try client(account, host: host)
        do {
            _ = try await session.preparePublishing(account: account, request: .init(accountId: account.id, appId: app, scope: .submit, versionId: "version-1"), client: client)
            Issue.record("Missing Copyright must block submission")
        } catch PublishFailure.refused(_, let problems) {
            #expect(problems.map(\.area) == [.copyright] && problems.first?.area.action == "Open Copyright")
        }
        #expect(apple.lock.withLock { apple.writes.isEmpty })
        let copyright = try await session.preparePublishing(account: account, request: .init(accountId: account.id, appId: app, scope: .versionCopyright,
            versionId: "version-1", copyright: "2026 Synthetic Studio"), client: client)
        #expect(copyright.steps.count == 1 && copyright.steps.first?.path == [.string("appStoreVersions"), .string("version-1")])
        #expect(apple.lock.withLock { apple.writes.isEmpty }, "Preparing a fix must still require explicit approval")
        #expect(try await session.approvePublishing(account: account, appId: app, id: copyright.id, fingerprint: copyright.fingerprint, client: client).state == "complete")
        let saved = apple.lock.withLock { (apple.writes.count, (apple.versions[0]["attributes"] as? [String: Any])?["copyright"] as? String) }
        #expect(saved.0 == 1 && saved.1 == "2026 Synthetic Studio")
    }

    @Test func step3SendsANameOnlyOnThisMacEvenWithoutADraftAsItsCheckReportsIt() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "step3-app-information.appstoreconnect.test"
        apple.appInfoName = "Synthetic older name"
        StubProtocol.handle(host) { apple.handle($0) }
        var request = PublishRequest(accountId: account.id, appId: "1000000001", scope: .metadata, revisionId: "00000000-0000-4000-8000-000000000002", versionId: "version-1")
        request.mediaStage = PublishRequest.textStage
        let review = try await session.preparePublishing(account: account, request: request, client: try client(account, host: host))
        let info = try #require(review.steps.first { $0.label == "Update app information · en-US" })
        #expect(info.detail == "name" && info.after?.contains("Sample App Updated") == true && info.before?.contains("Synthetic older name") == true && apple.writes.isEmpty)
    }

    @Test func step2AddsALanguageNewToTheVersionWithItsTextAndSaysSo() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "split-new-language.appstoreconnect.test", revision = "00000000-0000-4000-8000-000000000002"
        StubProtocol.handle(host) { apple.handle($0) }
        _ = try await session.addLanguage(accountId: account.id, appId: "1000000001", revisionId: revision, versionId: "version-1", locale: "sv", copyFrom: "en-US")
        var request = PublishRequest(accountId: account.id, appId: "1000000001", scope: .metadata, revisionId: revision, versionId: "version-1"); request.mediaStage = PublishRequest.screenshotsStage
        let review = try await session.preparePublishing(account: account, request: request, client: try client(account, host: host))
        let added = try #require(review.steps.first { $0.label == "Add language · sv" })
        #expect(added.body?["data"]?["attributes"]?["description"]?.text?.isEmpty == false)
        #expect(review.notes.contains { $0.contains("also adds sv with its text") && $0.hasSuffix("Only remaining text and Copyright changes need another review; matching content is not sent again.") })
    }

    /// Uploaded in App Store Connect, so no Save from this Mac knows it: Apple lists it with the same name and size as `png`.
    func webLibraryImage(_ apple: SyntheticApple, _ png: Data) {
        apple.libraryImages.append(["type": "appAssetLibraryImages", "id": "image-web", "attributes": ["fileName": "staged.png", "fileSize": png.count, "category": "APP_SCREENSHOTS_AND_PREVIEWS", "state": "PREPARE_FOR_SUBMISSION", "specId": "spec-iphone",
            "imageAsset": ["templateUrl": "https://is1-ssl.mzstatic.com/image/thumb/synthetic/{w}x{h}bb.{f}", "width": 1290, "height": 2796]], "relationships": ["assetLibrary": ["data": ["type": "appAssetLibraries", "id": "library-1"]]]])
    }

    @Test func aFileWithOnlyTheSameNameAndSizeIsUploadedInsteadOfReused() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "library-name-only.appstoreconnect.test", revision = "00000000-0000-4000-8000-000000000002"
        StubProtocol.handle(host) { apple.handle($0) }
        let png = syntheticPNG(width: 1290, height: 2796, seed: 45)
        webLibraryImage(apple, png)
        _ = try await session.addScreenshots(accountId: account.id, appId: "1000000001", revisionId: revision, localizationId: "version-locale-1", setId: "set-1", files: [("staged.png", png)])
        let set = try await session.screenshotSet(accountId: account.id, appId: "1000000001", revisionId: revision, setId: "set-1")
        try await session.saveScreenshotLayout(accountId: account.id, appId: "1000000001", revisionId: revision, setId: "set-1", order: set.items.map(\.id), hidden: ["shot-1"], expected: set.signature)
        var upload = PublishRequest(accountId: account.id, appId: "1000000001", scope: .metadata, revisionId: revision, versionId: "version-1"); upload.mediaStage = PublishRequest.uploadStage
        let review = try await session.preparePublishing(account: account, request: upload, client: try client(account, host: host))
        #expect(review.steps.contains { $0.guardValue?["kind"]?.text == "release-media-reserve" })
        #expect(!review.steps.contains { $0.body?.stringify().contains("image-web") == true })
    }

    @Test func aFileChosenFromAssetLibraryIsAddedWithoutUploadingItAgain() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "library-match.appstoreconnect.test", revision = "00000000-0000-4000-8000-000000000002"
        StubProtocol.handle(host) { apple.handle($0) }
        let png = syntheticPNG(width: 1290, height: 2796, seed: 45)
        webLibraryImage(apple, png)
        _ = try await session.addScreenshotsWithReceipt(accountId: account.id, appId: "1000000001", revisionId: revision, localizationId: "version-locale-1", setId: "set-1", files: [("staged.png", png)], assetIds: ["image-web"])
        let set = try await session.screenshotSet(accountId: account.id, appId: "1000000001", revisionId: revision, setId: "set-1")
        try await session.saveScreenshotLayout(accountId: account.id, appId: "1000000001", revisionId: revision, setId: "set-1", order: set.items.map(\.id), hidden: ["shot-1"], expected: set.signature)
        let client = try client(account, host: host)
        var upload = PublishRequest(accountId: account.id, appId: "1000000001", scope: .metadata, revisionId: revision, versionId: "version-1"); upload.mediaStage = PublishRequest.uploadStage
        await #expect(throws: PublishFailure.noChanges) { try await session.preparePublishing(account: account, request: upload, client: client) }
        let save = try await session.preparePublishing(account: account, request: PublishRequest(accountId: account.id, appId: "1000000001", scope: .metadata, revisionId: revision, versionId: "version-1"), client: client)
        #expect(!save.steps.contains { $0.kind == .upload || $0.guardValue?["kind"]?.text == "release-media-reserve" } && save.steps.contains { $0.label == "Add screenshot · en-US" })
        // Apple adds the file but its answer is lost: the Save finds the placement instead of adding the file a second time.
        apple.lock.withLock { apple.losePlacementAnswers = 1 }
        let saved = try await session.approvePublishing(account: account, appId: "1000000001", id: save.id, fingerprint: save.fingerprint, client: client)
        #expect(saved.state == "complete", "\(saved.error ?? "")")
        #expect(apple.lock.withLock { apple.placements.filter { (($0["relationships"] as? [String: Any])?["image"] as? [String: Any]).flatMap { $0["data"] as? [String: Any] }?["id"] as? String == "image-web" }.count } == 1)
        #expect(apple.lock.withLock { apple.placements.contains { (($0["relationships"] as? [String: Any])?["image"] as? [String: Any]).flatMap { $0["data"] as? [String: Any] }?["id"] as? String == "image-web" } })
    }

    @Test @MainActor func removingEveryScreenshotPreparesOnlyVersionRemovalAndKeepsTheLibraryOriginal() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "clear-media.appstoreconnect.test"
        let revisionId = "00000000-0000-4000-8000-000000000002"
        StubProtocol.handle(host) { apple.handle($0) }
        let revision = try #require(try await session.revisions(accountId: account.id, appId: "1000000001").first { $0.id == revisionId })
        let localization = try #require(revision.versions.first?.localizations.first { $0.id == "version-locale-1" })
        let model = MediaListingEditor(scope: .init(accountId: account.id, appId: "1000000001", revisionId: revisionId), localization: localization, platform: "IOS", session: session)
        await model.load(); model.removeAllScreenshots()
        #expect((await model.run()).complete)
        let client = try client(account, host: host)
        let request = PublishRequest(accountId: account.id, appId: "1000000001", scope: .metadata, revisionId: revisionId, versionId: "version-1")
        let review = try await session.preparePublishing(account: account, request: request, client: client)
        #expect(apple.writes.isEmpty)
        #expect(review.steps.filter { $0.method == "DELETE" }.map { $0.path.first?.text } == ["appAssetLibraryPlacements"])
        #expect(!review.steps.contains { $0.kind == .upload || $0.label.hasPrefix("Add screenshot") })
        let result = try await session.approvePublishing(account: account, appId: "1000000001", id: review.id, fingerprint: review.fingerprint, client: client)
        #expect(result.state == "complete")
        #expect(apple.lock.withLock { apple.placements.isEmpty && apple.libraryImages.map { $0["id"] as? String } == ["image-1"] })
        await #expect(throws: PublishFailure.self) {
            try await session.approvePublishing(account: account, appId: "1000000001", id: review.id, fingerprint: review.fingerprint, client: client)
        }
    }

    @Test func mediaBatchesKeepReservationsDeletesAndFinalOrderAcrossLostPlacementAnswers() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "batch-media.appstoreconnect.test"
        let app = "1000000001", revision = "00000000-0000-4000-8000-000000000002"
        apple.lock.withLock {
            let original = apple.placements[0]
            for index in 1..<5 { var extra = original; extra["id"] = "synthetic-old-placement-\(index)"; apple.placements.append(extra) }
            apple.readsOmitUploadOperations = true; apple.losePlacementAnswers = 1
        }
        StubProtocol.handle(host) { apple.handle($0) }
        final class Uploads: @unchecked Sendable { let lock = NSLock(); var data: [Data] = [] }
        let uploads = Uploads()
        StubProtocol.handle("synthetic.blobstore.apple.com") { request in
            #expect(request.httpMethod == "PUT" && request.value(forHTTPHeaderField: "Authorization") == nil)
            let data = StubProtocol.body(request); uploads.lock.withLock { uploads.data.append(data) }; return (200, [:], Data())
        }
        let files = (0..<5).map { ("synthetic-batch-\($0).png", syntheticPNG(width: 1290, height: 2796, seed: UInt8($0 + 70))) }
        _ = try await session.addScreenshots(accountId: account.id, appId: app, revisionId: revision, localizationId: "version-locale-1", setId: "set-1", files: files)
        let layout = try await session.screenshotSet(accountId: account.id, appId: app, revisionId: revision, setId: "set-1")
        _ = try await session.saveScreenshotLayout(accountId: account.id, appId: app, revisionId: revision, setId: "set-1", order: layout.items.map(\.id), hidden: ["shot-1"], expected: layout.signature)
        let client = try client(account, host: host), request = PublishRequest(accountId: account.id, appId: app, scope: .metadata, revisionId: revision, versionId: "version-1")
        let prepared = try await session.preparePublishing(account: account, request: request, client: client)
        #expect(apple.writes.isEmpty)
        let result = try await session.approvePublishing(account: account, appId: app, id: prepared.id, fingerprint: prepared.fingerprint, client: client)
        #expect(result.state == "complete", "\(result.error ?? "")")
        let writes = apple.lock.withLock { apple.writes }
        let firstCommit = try #require(writes.firstIndex { $0.0 == "PATCH" && $0.1.hasPrefix("/v1/appAssetLibraryImages/") })
        #expect(!writes[..<firstCommit].filter { $0.0 == "POST" && $0.1 == "/v1/appAssetLibraryImages" }.isEmpty)
        let lastRemoval = try #require(writes.lastIndex { $0.0 == "DELETE" && $0.1.hasPrefix("/v1/appAssetLibraryPlacements/") })
        let firstPlacement = try #require(writes.firstIndex { $0.0 == "POST" && $0.1 == "/v1/appAssetLibraryPlacements" })
        #expect(lastRemoval < firstPlacement && writes.filter { $0.0 == "POST" && $0.1 == "/v1/appAssetLibraryPlacements" }.count == 5)
        #expect(writes.last?.1 == "/v1/appAssetLibraryPlacementOrderingRequests")
        let names = apple.lock.withLock {
            apple.placements.map { placement in
                let asset = (((placement["relationships"] as? [String: Any])?["image"] as? [String: Any])?["data"] as? [String: Any])?["id"] as? String
                return (apple.libraryImages.first { $0["id"] as? String == asset }?["attributes"] as? [String: Any])?["fileName"] as? String
            }
        }
        #expect(names == files.map { Optional($0.0) })
        #expect(uploads.lock.withLock { Set(uploads.data) } == Set(files.map(\.1)))
        #expect(result.steps.allSatisfy { $0.state == "done" && ($0.guardValue?["kind"]?.text != "release-media-reserve" || $0.resultId != nil) })
        #expect(apple.lock.withLock { apple.libraryImages.contains { $0["id"] as? String == "image-1" } })
    }

    @Test func aFailedMediaPipelineDrainsAdmittedWorkAndNeverUploadsItsFailedReservation() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "batch-media-failure.appstoreconnect.test"
        let app = "1000000001", revision = "00000000-0000-4000-8000-000000000002"
        StubProtocol.handle("synthetic.blobstore.apple.com") { _ in (200, [:], Data()) }
        StubProtocol.handle(host) { request in
            if request.httpMethod == "POST" && request.url?.path == "/v1/appAssetLibraryImages" {
                let data = StubProtocol.body(request)
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let item = json["data"] as? [String: Any],
                   (item["attributes"] as? [String: Any])?["fileName"] as? String == "synthetic-fail-0.png" { return (403, [:], Data()) }
                var copy = request; copy.httpBodyStream = nil; copy.httpBody = data; return apple.handle(copy)
            }
            return apple.handle(request)
        }
        let files = (0..<6).map { ("synthetic-fail-\($0).png", syntheticPNG(width: 1290, height: 2796, seed: UInt8($0 + 80))) }
        _ = try await session.addScreenshots(accountId: account.id, appId: app, revisionId: revision, localizationId: "version-locale-1", setId: "set-1", files: files)
        let layout = try await session.screenshotSet(accountId: account.id, appId: app, revisionId: revision, setId: "set-1")
        _ = try await session.saveScreenshotLayout(accountId: account.id, appId: app, revisionId: revision, setId: "set-1", order: layout.items.map(\.id), hidden: ["shot-1"], expected: layout.signature)
        let client = try client(account, host: host), request = PublishRequest(accountId: account.id, appId: app, scope: .metadata, revisionId: revision, versionId: "version-1")
        let prepared = try await session.preparePublishing(account: account, request: request, client: client)
        let failed = try await session.approvePublishing(account: account, appId: app, id: prepared.id, fingerprint: prepared.fingerprint, client: client)
        #expect(failed.state == "failed" && !failed.steps.contains { $0.state == "running" })
        let failedReservation = try #require(failed.steps.first { $0.guardValue?["kind"]?.text == "release-media-reserve" && $0.state == "failed" })
        #expect(failedReservation.guardValue?["asset"]?["fileName"] == .string("synthetic-fail-0.png"))
        #expect(failed.steps.filter { $0.group == failedReservation.key && $0.key != failedReservation.key }.allSatisfy { $0.state == "pending" })
        let successful = failed.steps.filter { $0.guardValue?["kind"]?.text == "release-media-reserve" && $0.state == "done" }
        #expect(successful.count >= 3 && successful.allSatisfy { $0.resultId != nil })
        for upload in failed.steps where upload.kind == .upload && upload.state == "done" {
            #expect(successful.contains { $0.key == upload.group })
        }
        #expect(apple.lock.withLock { apple.writes.allSatisfy {
            $0.0 == "POST" && $0.1 == "/v1/appAssetLibraryImages" || $0.0 == "PATCH" && $0.1.hasPrefix("/v1/appAssetLibraryImages/")
        } })
        await #expect(throws: PublishFailure.used) { try await session.approvePublishing(account: account, appId: app, id: failed.id, fingerprint: failed.fingerprint, client: client) }
    }

    @Test func textAndScreenshotsArePublishedAsReviewedAndChangesConflict() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "material.appstoreconnect.test", revision = "00000000-0000-4000-8000-000000000002"
        StubProtocol.handle(host) { apple.handle($0) }
        let png = syntheticPNG(width: 1290, height: 2796, seed: 42)
        StubProtocol.handle("synthetic.blobstore.apple.com") { request in
            #expect(request.httpMethod == "PUT" && request.value(forHTTPHeaderField: "Authorization") == nil)
            apple.lock.withLock { apple.uploaded = apple.body(request) }
            return (200, [:], Data())
        }
        let text = try await session.textDraft(accountId: account.id, appId: "1000000001", revisionId: revision, localizationId: "version-locale-1", scope: .version)
        var fields = text.fields; fields["promotionalText"] = "Synthetic promotion"; fields["whatsNew"] = "Synthetic release notes"
        try await session.saveTextDraft(accountId: account.id, appId: "1000000001", revisionId: revision, localizationId: "version-locale-1", scope: .version, fields: fields, fingerprint: text.fingerprint)
        _ = try await session.addScreenshots(accountId: account.id, appId: "1000000001", revisionId: revision, localizationId: "version-locale-1", setId: "set-1", files: [("new.png", png)])
        let set = try await session.screenshotSet(accountId: account.id, appId: "1000000001", revisionId: revision, setId: "set-1")
        try await session.saveScreenshotLayout(accountId: account.id, appId: "1000000001", revisionId: revision, setId: "set-1", order: set.items.map(\.id), hidden: ["shot-1"], expected: set.signature)

        let client = try client(account, host: host)
        let request = PublishRequest(accountId: account.id, appId: "1000000001", scope: .metadata, revisionId: revision, versionId: "version-1")
        let review = try await session.preparePublishing(account: account, request: request, client: client)
        #expect(review.steps.map(\.label) == ["Update version text · en-US", "Upload new.png · en-US", "Upload new.png", "Complete upload · new.png", "Verify new.png", "Remove screenshot · en-US", "Add screenshot · en-US"])

        // Apple changes after the review was prepared: approval is refused and nothing is written.
        let conflictReview = review
        apple.lock.withLock { var attributes = apple.locales[0]["attributes"] as! [String: Any]; attributes["description"] = "Changed in App Store Connect"; apple.locales[0]["attributes"] = attributes }
        await #expect(throws: PublishFailure.conflict) { try await session.approvePublishing(account: account, appId: "1000000001", id: conflictReview.id, fingerprint: conflictReview.fingerprint, client: client) }
        #expect(apple.writes.isEmpty)
        #expect(try await session.publishReview(accountId: account.id, appId: "1000000001", id: conflictReview.id).state == "conflict")

        let fresh = try await session.preparePublishing(account: account, request: request, client: client)
        // The upload follows the operations from the reservation response, even when reading the image again omits them.
        apple.lock.withLock { apple.readsOmitUploadOperations = true }
        let done = try await session.approvePublishing(account: account, appId: "1000000001", id: fresh.id, fingerprint: fresh.fingerprint, client: client)
        #expect(done.state == "complete", "\(done.error ?? "")")
        #expect(apple.uploaded == png)
        // The file is saved once in Asset Library and committed with `uploaded` alone; removal takes only the placement off the version.
        let complete = apple.writes.first { $0.0 == "PATCH" && $0.1.hasPrefix("/v1/appAssetLibraryImages/") }?.2?["data"] as? [String: Any]
        #expect(complete?["attributes"] as? [String: Bool] == ["uploaded": true])
        #expect(apple.writes.allSatisfy { !ReleaseMedia.legacyRoots.contains($0.1.split(separator: "/").dropFirst().first.map(String.init) ?? "") })
        let placed = apple.lock.withLock { apple.placements.map { ((($0["relationships"] as? [String: Any])?["image"] as? [String: Any])?["data"] as? [String: Any])?["id"] as? String } }
        #expect(placed == ["image-new-1"] && apple.lock.withLock { apple.libraryImages.map { $0["id"] as! String } } == ["image-1", "image-new-1"])

        // A later review places the uploaded file instead of uploading it again; the order follows the saved layout.
        let earlier = try await session.screenshotSet(accountId: account.id, appId: "1000000001", revisionId: revision, setId: "set-1").items.map(\.id)
        _ = try await session.addScreenshots(accountId: account.id, appId: "1000000001", revisionId: revision, localizationId: "version-locale-1", setId: "set-1", files: [("second.png", syntheticPNG(width: 1290, height: 2796, seed: 43))])
        let edited = try await session.screenshotSet(accountId: account.id, appId: "1000000001", revisionId: revision, setId: "set-1")
        let added = try #require(earlier.first { $0 != "shot-1" }), second = try #require(edited.items.map(\.id).first { !earlier.contains($0) })
        try await session.saveScreenshotLayout(accountId: account.id, appId: "1000000001", revisionId: revision, setId: "set-1", order: [second, added, "shot-1"], hidden: ["shot-1"], expected: edited.signature)
        let next = try await session.preparePublishing(account: account, request: request, client: client)
        #expect(next.steps.filter { $0.path.first?.text?.hasPrefix("appAssetLibrary") == true }.map(\.label) == ["Upload second.png · en-US", "Upload second.png", "Complete upload · second.png", "Verify second.png", "Add screenshot · en-US", "Set screenshots order · en-US · Iphone Synthetic Profile"])
        let ordered = try await session.approvePublishing(account: account, appId: "1000000001", id: next.id, fingerprint: next.fingerprint, client: client)
        #expect(ordered.state == "complete", "\(ordered.error ?? "")")
        #expect(apple.lock.withLock { apple.placements.map { $0["id"] as! String } } == ["placement-new-4", "placement-new-2"])
        let textWrite = apple.writes.first { $0.1 == "/v1/appStoreVersionLocalizations/version-locale-1" }?.2?["data"] as? [String: Any]
        #expect((textWrite?["attributes"] as? [String: Any])?["promotionalText"] as? String == "Synthetic promotion")
        // The app's only version is its first: Apple has no What's New there, so it is not sent.
        #expect((textWrite?["attributes"] as? [String: Any])?["whatsNew"] == nil)
        // Once Apple holds an earlier version of the platform, What's New is sent with the rest of the text.
        apple.lock.withLock { apple.versions.append(["type": "appStoreVersions", "id": "version-0", "attributes": ["platform": "IOS", "versionString": "0.9", "appVersionState": "READY_FOR_SALE", "releaseType": "MANUAL"], "relationships": ["app": ["data": ["type": "apps", "id": "1000000001"]]]]) }
        let notes = try await session.preparePublishing(account: account, request: request, client: client)
        #expect(try await session.approvePublishing(account: account, appId: "1000000001", id: notes.id, fingerprint: notes.fingerprint, client: client).state == "complete")
        let notesWrite = apple.writes.last { $0.1 == "/v1/appStoreVersionLocalizations/version-locale-1" }?.2?["data"] as? [String: Any]
        #expect((notesWrite?["attributes"] as? [String: Any])?["whatsNew"] as? String == "Synthetic release notes")
    }

    @Test func versionMediaWaitsWhileAppleListsItOnlyInTheDeprecatedSets() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "legacy-media.appstoreconnect.test", revision = "00000000-0000-4000-8000-000000000002"
        apple.lock.withLock { apple.placements = [] }
        StubProtocol.handle(host) { apple.handle($0) }
        _ = try await session.addScreenshots(accountId: account.id, appId: "1000000001", revisionId: revision, localizationId: "version-locale-1", setId: "set-1", files: [("new.png", syntheticPNG(width: 1290, height: 2796, seed: 7))])
        let set = try await session.screenshotSet(accountId: account.id, appId: "1000000001", revisionId: revision, setId: "set-1")
        try await session.saveScreenshotLayout(accountId: account.id, appId: "1000000001", revisionId: revision, setId: "set-1", order: set.items.map(\.id), hidden: ["shot-1"], expected: set.signature)
        let client = try client(account, host: host), request = PublishRequest(accountId: account.id, appId: "1000000001", scope: .metadata, revisionId: revision, versionId: "version-1")
        do { _ = try await session.preparePublishing(account: account, request: request, client: client); Issue.record("Deprecated set media must block the review") }
        catch let failure as PublishFailure { #expect(failure.message.contains("outside Asset Library")) }
        #expect(apple.writes.isEmpty)

        // Once Apple lists no deprecated media for that display size, the same draft is placed through Asset Library and nothing is removed.
        apple.lock.withLock { apple.shots = [] }
        let review = try await session.preparePublishing(account: account, request: request, client: client)
        #expect(review.steps.contains { $0.label == "Add screenshot · en-US" } && !review.steps.contains { $0.method == "DELETE" })
        #expect(review.steps.allSatisfy { !ReleaseMedia.legacyRoots.contains($0.path.first?.text ?? "") })
    }

    @Test func copyrightAnalyticsAndPricesArePublishedWithTheirGuards() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "more.appstoreconnect.test", app = "1000000001"
        StubProtocol.handle(host) { apple.handle($0) }
        let client = try client(account, host: host)

        let copyright = try await session.preparePublishing(account: account, request: PublishRequest(accountId: account.id, appId: app, scope: .versionCopyright, versionId: "version-1", copyright: " 2026 Synthetic Studio "), client: client)
        #expect(copyright.steps.map(\.after) == ["2026 Synthetic Studio"])
        apple.lock.withLock { var attributes = apple.versions[0]["attributes"] as! [String: Any]; attributes["copyright"] = "2025 Someone Else"; apple.versions[0]["attributes"] = attributes }
        await #expect(throws: PublishFailure.conflict) { try await session.approvePublishing(account: account, appId: app, id: copyright.id, fingerprint: copyright.fingerprint, client: client) }
        let again = try await session.preparePublishing(account: account, request: PublishRequest(accountId: account.id, appId: app, scope: .versionCopyright, versionId: "version-1", copyright: "2026 Synthetic Studio"), client: client)
        #expect(try await session.approvePublishing(account: account, appId: app, id: again.id, fingerprint: again.fingerprint, client: client).state == "complete")

        let analytics = try await session.preparePublishing(account: account, request: PublishRequest(accountId: account.id, appId: app, scope: .analyticsOngoing), client: client)
        #expect(try await session.approvePublishing(account: account, appId: app, id: analytics.id, fingerprint: analytics.fingerprint, client: client).state == "complete")
        #expect(apple.writes.last?.1 == "/v1/analyticsReportRequests")

        // A Swedish country draft becomes one manual schedule; the US base price and its point stay as they are.
        _ = try await session.saveCountryDrafts(accountId: account.id, appId: app, amounts: [("SWE", "SEK", "49")], startDate: nil, endDate: nil)
        let prices = try await session.preparePublishing(account: account, request: PublishRequest(accountId: account.id, appId: app, scope: .pricing), client: client)
        #expect(prices.steps.count == 1 && prices.steps[0].after == "SWE: 49 SEK · Now → ongoing\nUSA: 4.99 USD · Now → ongoing")
        let done = try await session.approvePublishing(account: account, appId: app, id: prices.id, fingerprint: prices.fingerprint, client: client)
        #expect(done.state == "complete", "\(done.error ?? "")")
        let body = apple.writes.last?.2
        let included = body?["included"] as? [[String: Any]]
        #expect(included?.compactMap { (($0["relationships"] as? [String: Any])?["appPricePoint"] as? [String: Any])?["data"] as? [String: Any] }.compactMap { $0["id"] as? String } == ["pp-swe-49", "pp-usa-499"])
        #expect(included?.first?["id"] as? String == "${price-0}")
    }

    @Test func missingComplianceIsAnsweredAndBuildsJoinGroupsThroughReviews() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "testflight.appstoreconnect.test", app = "1000000001"
        StubProtocol.handle(host) { apple.handle($0) }
        let client = try client(account, host: host)
        let builds = try await session.testFlightBuilds(appId: app, client: client)
        #expect(builds.map(\.title) == ["Build 7 · iOS 2.0"] && builds[0].missingCompliance)
        var request = PublishRequest(accountId: account.id, appId: app, scope: .testflight, buildId: "build-7")
        request.testflightAction = "set-encryption-use"; request.usesNonExemptEncryption = false
        let review = try await session.preparePublishing(account: account, request: request, client: client)
        #expect(review.steps.map(\.before) == ["No answer at Apple"] && review.steps.map(\.after) == ["Uses non-exempt encryption: No"])
        #expect(try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: client).state == "complete")
        #expect(try await session.testFlightBuilds(appId: app, client: client).first?.missingCompliance == false)

        let groups = try await session.testFlightGroups(appId: app, client: client)
        #expect(groups.map(\.name) == ["Synthetic testers"])
        var assign = PublishRequest(accountId: account.id, appId: app, scope: .testflight, buildId: "build-7"); assign.testflightAction = "add-build"; assign.groupId = "group-1"
        let assignment = try await session.preparePublishing(account: account, request: assign, client: client)
        #expect(try await session.approvePublishing(account: account, appId: app, id: assignment.id, fingerprint: assignment.fingerprint, client: client).state == "complete")
        let members = try await session.groupMembers(appId: app, groupId: "group-1", client: client)
        #expect(members.builds == ["build-7"] && members.testers.map(\.email) == ["tester@example.com"])
        let again = try await session.preparePublishing(account: account, request: assign, client: client)
        #expect(again.steps.isEmpty)
    }

    @Test func appReviewInformationIsPublishedWithItsAttachment() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "review.appstoreconnect.test", app = "1000000001"
        StubProtocol.handle(host) { apple.handle($0) }
        StubProtocol.handle("synthetic.blobstore.apple.com") { request in apple.lock.withLock { apple.uploaded = apple.body(request) }; return (200, [:], Data()) }
        var fields = ReviewInformation()
        fields.contactFirstName = " Synthetic "; fields.contactLastName = "Reviewer"; fields.contactPhone = "+1 555 0100"; fields.contactEmail = "review@example.com"; fields.notes = "Synthetic notes"
        let pdf = Data("%PDF-1.4 synthetic".utf8)
        let saved = try await session.saveReviewInformationDraft(accountId: account.id, appId: app, versionId: "version-1", fields: fields, attachment: ("guide.pdf", pdf), keepAttachment: false, expectedRevision: 0)
        #expect(saved.revision == 1 && saved.fields.contactFirstName == "Synthetic" && saved.attachment?.fileName == "guide.pdf")
        await #expect(throws: PublishFailure.self) { try await session.saveReviewInformationDraft(accountId: account.id, appId: app, versionId: "version-1", fields: fields, attachment: nil, keepAttachment: true, expectedRevision: 0) }

        let client = try client(account, host: host)
        let review = try await session.preparePublishing(account: account, request: PublishRequest(accountId: account.id, appId: app, scope: .reviewInfo, versionId: "version-1"), client: client)
        #expect(review.steps.map(\.label) == ["Add App Review Information", "Attach guide.pdf for App Review", "Upload guide.pdf", "Complete guide.pdf", "Verify guide.pdf"])
        #expect(review.steps[0].after?.contains("Demo account required: No") == true)
        let done = try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: client)
        #expect(done.state == "complete", "\(done.error ?? "")")
        #expect(apple.uploaded == pdf)
        let created = apple.writes.first { $0.1 == "/v1/appStoreReviewDetails" }?.2?["data"] as? [String: Any]
        #expect((created?["attributes"] as? [String: Any])?["contactFirstName"] as? String == "Synthetic")
    }

    @Test func existingReviewInformationAndAttachmentAcceptScopedProofWithoutReverseLinks() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "review-links.appstoreconnect.test", app = "1000000001"
        var fields = ReviewInformation()
        fields.contactFirstName = "Synthetic"; fields.contactLastName = "Reviewer"; fields.contactPhone = "+1 555 0100"; fields.contactEmail = "review@example.com"; fields.notes = "Earlier synthetic notes"
        apple.reviewDetails = [["type": "appStoreReviewDetails", "id": "detail-1", "attributes": try JSONSerialization.jsonObject(with: fields.json.data),
                                "relationships": ["appStoreVersion": ["data": ["type": "appStoreVersions", "id": "version-1"]]]]]
        apple.reviewReadsOmitOwner = true
        StubProtocol.handle(host) { apple.handle($0) }
        StubProtocol.handle("synthetic.blobstore.apple.com") { request in apple.lock.withLock { apple.uploaded = apple.body(request) }; return (200, [:], Data()) }
        fields.notes = "Updated synthetic notes"
        let pdf = Data("%PDF-1.4 synthetic review links".utf8)
        _ = try await session.saveReviewInformationDraft(accountId: account.id, appId: app, versionId: "version-1", fields: fields, attachment: ("guide.pdf", pdf), keepAttachment: false, expectedRevision: 0)
        let client = try client(account, host: host)
        let review = try await session.preparePublishing(account: account, request: .init(accountId: account.id, appId: app, scope: .reviewInfo, versionId: "version-1"), client: client)
        #expect(apple.writes.isEmpty)
        #expect(review.steps.first?.method == "PATCH")
        let done = try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: client)
        #expect(done.state == "complete", "\(done.error ?? "")")
        #expect(done.errorCode == nil && apple.uploaded == pdf)
        #expect((apple.reviewDetails.first?["attributes"] as? [String: Any])?["notes"] as? String == fields.notes)
        #expect(apple.writes.contains { $0.0 == "PATCH" && $0.1 == "/v1/appStoreReviewDetails/detail-1" })
        #expect(apple.writes.contains { $0.0 == "PATCH" && $0.1 == "/v1/appStoreReviewAttachments/attachment-1" })
        #expect(StubProtocol.requests(host).contains { $0.url?.query?.contains("include=appStoreVersion") == true })
    }

    @Test func reviewOwnershipGuardStopsConflictingLinksAndPersistsItsSpecificFailure() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "review-scope.appstoreconnect.test", app = "1000000001"
        var fields = ReviewInformation()
        fields.contactFirstName = "Synthetic"; fields.contactLastName = "Reviewer"; fields.contactPhone = "+1 555 0100"; fields.contactEmail = "review@example.com"
        apple.reviewDetails = [["type": "appStoreReviewDetails", "id": "detail-1", "attributes": try JSONSerialization.jsonObject(with: fields.json.data)]]
        StubProtocol.handle(host) { apple.handle($0) }
        fields.notes = "Updated synthetic notes"
        _ = try await session.saveReviewInformationDraft(accountId: account.id, appId: app, versionId: "version-1", fields: fields, attachment: nil, keepAttachment: true, expectedRevision: 0)
        let client = try client(account, host: host)
        let prepared = try await session.preparePublishing(account: account, request: .init(accountId: account.id, appId: app, scope: .reviewInfo, versionId: "version-1"), client: client)
        // The version's forward read remains unchanged; only the direct read now contradicts the app-scoped proof.
        var other = apple.reviewDetails[0]
        other["relationships"] = ["appStoreVersion": ["data": ["type": "apps", "id": "1000000002"]]]
        apple.reviewDirectResource = other
        let stopped = try await session.approvePublishing(account: account, appId: app, id: prepared.id, fingerprint: prepared.fingerprint, client: client)
        #expect(stopped.state == "failed" && stopped.errorCode == "SB-PUBLISH-SCOPE")
        #expect(stopped.error == PublishFailure.ownership.message && apple.writes.isEmpty)
        let saved = try await session.publishReview(accountId: account.id, appId: app, id: prepared.id)
        #expect(saved.errorCode == stopped.errorCode && PublishReview(stopped.json)?.errorCode == stopped.errorCode)
        await #expect(throws: PublishFailure.used) { try await session.approvePublishing(account: account, appId: app, id: prepared.id, fingerprint: prepared.fingerprint, client: client) }
    }

    @Test func reviewOwnershipRequiresTheExactResourceUnderAnApprovedApp() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), app = "1000000001"
        for variant in ["unlisted", "malformed", "foreign", "foreign-attachment", "unlisted-attachment"] {
            let apple = SyntheticApple(), host = "review-\(variant).appstoreconnect.test"
            let type = variant.hasSuffix("attachment") ? "appStoreReviewAttachments" : "appStoreReviewDetails"
            apple.reviewDetails = [["type": "appStoreReviewDetails", "id": "detail-1", "attributes": [:]]]
            var item: [String: Any] = ["type": type, "id": "unlisted-1", "attributes": [:]]
            if variant == "malformed" { item["relationships"] = ["appStoreVersion": ["data": ["id": "version-1"]]] }
            if variant == "foreign" { item["relationships"] = ["appStoreVersion": ["data": ["type": "appStoreVersions", "id": "foreign-version"]]] }
            if variant == "foreign-attachment" { item["relationships"] = ["appStoreReviewDetail": ["data": ["type": "apps", "id": "1000000002"]]] }
            let direct = item
            StubProtocol.handle(host) { request in
                if request.url?.path == "/v1/\(type)/unlisted-1" { return apple.page(direct) }
                if request.url?.path == "/v1/appStoreVersions/foreign-version" {
                    return apple.page(["type": "appStoreVersions", "id": "foreign-version", "relationships": ["app": ["data": ["type": "apps", "id": "1000000002"]]]])
                }
                return apple.handle(request)
            }
            await #expect(throws: PublishFailure.ownership) { try await session.ownedResource(type, "unlisted-1", appId: app, client: client(account, host: host), checked: OwnershipCache()) }
            #expect(apple.writes.isEmpty)
        }
    }

    @Test func appInformationAndRegionsAreChangedWithTheirGuards() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "info.appstoreconnect.test", app = "1000000001"
        StubProtocol.handle(host) { apple.handle($0) }
        let client = try client(account, host: host)
        let state = try await session.appInformationState(appId: app, client: client)
        #expect(state.contentRights == nil && (state.categories?["primaryCategory"] ?? nil) == "GAMES" && state.territories.map(\.id) == ["SWE", "USA"])

        var request = PublishRequest(accountId: account.id, appId: app, scope: .appInformation)
        request.contentRightsDeclaration = "DOES_NOT_USE_THIRD_PARTY_CONTENT"
        var selection = Dictionary(uniqueKeysWithValues: AppInformation.categoryFields.map { ($0, String?.none) }); selection["primaryCategory"] = "PRODUCTIVITY"
        request.categorySelection = selection
        let review = try await session.preparePublishing(account: account, request: request, client: client)
        #expect(review.steps.map(\.label) == ["Update content rights declaration", "Update App Store categories"] && review.steps[1].after == "Primary category: Productivity")
        #expect(try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: client).state == "complete")
        #expect(apple.primary == "PRODUCTIVITY" && apple.rights as? String == "DOES_NOT_USE_THIRD_PARTY_CONTENT")

        var region = PublishRequest(accountId: account.id, appId: app, scope: .availability); region.territoryId = "SWE"; region.territoryAvailable = false
        let regionReview = try await session.preparePublishing(account: account, request: region, client: client)
        #expect(regionReview.steps.map(\.after) == ["Not selected for distribution"])
        #expect(try await session.approvePublishing(account: account, appId: app, id: regionReview.id, fingerprint: regionReview.fingerprint, client: client).state == "complete")
        #expect(!apple.sweden)
        var bad = PublishRequest(accountId: account.id, appId: app, scope: .appInformation)
        var invalid = selection; invalid["primaryCategory"] = nil; bad.categorySelection = invalid
        await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: bad, client: client) }
    }

    @Test func ageRatingAnswersAreChangedOnlyWhereTheyDiffer() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "age.appstoreconnect.test", app = "1000000001"
        StubProtocol.handle(host) { apple.handle($0) }
        let client = try client(account, host: host)
        #expect(try await session.ageRatingAnswers(appId: app, client: client)["advertising"] == .bool(false))
        var request = PublishRequest(accountId: account.id, appId: app, scope: .ageRating)
        request.ageRatingChanges = [("violenceCartoonOrFantasy", .string("INFREQUENT")), ("advertising", .bool(false))]
        let review = try await session.preparePublishing(account: account, request: request, client: client)
        #expect(review.steps.map(\.after) == ["Cartoon or fantasy violence: infrequent"])
        #expect(try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: client).state == "complete")
        #expect(apple.ageAnswers["violenceCartoonOrFantasy"] as? String == "INFREQUENT")
        var invalid = PublishRequest(accountId: account.id, appId: app, scope: .ageRating); invalid.ageRatingChanges = [("violenceRealistic", .string("SOMETIMES"))]
        await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: invalid, client: client) }
    }

    @Test func accessibilityDraftsAreCreatedThenPublished() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "access.appstoreconnect.test", app = "1000000001"
        StubProtocol.handle(host) { apple.handle($0) }
        let client = try client(account, host: host)
        var save = PublishRequest(accountId: account.id, appId: app, scope: .accessibility)
        save.accessibilityAction = "save-draft"; save.accessibilityFamily = "MAC"
        save.accessibilityAnswers = AccessibilityDeclarations.applicable("MAC").map { ($0.key, $0.key == "supportsVoiceover") }
        let draft = try await session.preparePublishing(account: account, request: save, client: client)
        #expect(draft.steps.map(\.label) == ["Create accessibility draft"] && draft.steps[0].after?.contains("Larger Text") == false)
        #expect(try await session.approvePublishing(account: account, appId: app, id: draft.id, fingerprint: draft.fingerprint, client: client).state == "complete")
        var publish = PublishRequest(accountId: account.id, appId: app, scope: .accessibility); publish.accessibilityAction = "publish-draft"; publish.accessibilityFamily = "MAC"
        let review = try await session.preparePublishing(account: account, request: publish, client: client)
        #expect(try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: client).state == "complete")
        #expect(try await session.accessibilityDeclarations(appId: app, client: client).first?.state == "PUBLISHED")
        var incomplete = save; incomplete.accessibilityAnswers = [("supportsVoiceover", true)]
        await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: incomplete, client: client) }
    }

    @Test func exportComplianceDeclarationsAndDocumentsAreSentOnce() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "export.appstoreconnect.test", app = "1000000001"
        StubProtocol.handle(host) { apple.handle($0) }
        StubProtocol.handle("synthetic.blobstore.apple.com") { request in apple.lock.withLock { apple.uploaded = apple.body(request) }; return (200, [:], Data()) }
        let client = try client(account, host: host)
        var answers = EncryptionAnswers(); answers.appDescription = " Uses standard HTTPS only. "; answers.containsThirdPartyCryptography = true; answers.availableOnFrenchStore = true
        var request = PublishRequest(accountId: account.id, appId: app, scope: .exportCompliance); request.encryptionDeclaration = answers
        let review = try await session.preparePublishing(account: account, request: request, client: client)
        #expect(review.steps.first?.after?.hasPrefix("App description: Uses standard HTTPS only.") == true)
        #expect(try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: client).state == "complete")
        #expect(try await session.preparePublishing(account: account, request: request, client: client).steps.isEmpty)

        let pdf = Data("%PDF-1.7 synthetic declaration".utf8)
        await #expect(throws: PublishFailure.self) { try await session.stageEncryptionDocument(accountId: account.id, appId: app, declarationId: "decl-1", expectedRevision: 0, fileName: "not.pdf", data: Data("plain".utf8)) }
        let staged = try await session.stageEncryptionDocument(accountId: account.id, appId: app, declarationId: "decl-1", expectedRevision: 0, fileName: "Declaration.pdf", data: pdf)
        var document = PublishRequest(accountId: account.id, appId: app, scope: .exportDocument); document.declarationId = "decl-1"; document.documentRevision = staged.revision
        let upload = try await session.preparePublishing(account: account, request: document, client: client)
        #expect(upload.steps.map(\.label) == ["Reserve Declaration.pdf at Apple", "Upload Declaration.pdf", "Complete Declaration.pdf", "Verify Declaration.pdf"])
        let done = try await session.approvePublishing(account: account, appId: app, id: upload.id, fingerprint: upload.fingerprint, client: client)
        #expect(done.state == "complete", "\(done.error ?? "")")
        #expect(apple.uploaded == pdf)
    }

    @Test func testFlightGroupsTestersAndInformationAreChangedThroughReviews() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "testflight-actions.appstoreconnect.test", app = "1000000001"
        StubProtocol.handle(host) { apple.handle($0) }
        let client = try client(account, host: host)
        func publish(_ configure: (inout PublishRequest) -> Void, build: String? = nil) async throws -> PublishReview {
            var request = PublishRequest(accountId: account.id, appId: app, scope: .testflight, buildId: build); configure(&request)
            let review = try await session.preparePublishing(account: account, request: request, client: client)
            return try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: client)
        }

        var mixed = PublishRequest(accountId: account.id, appId: app, scope: .testflight); mixed.testflightAction = "create-group"; mixed.groupName = "Beta"; mixed.agreementText = "Terms"
        await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: mixed, client: client) }

        #expect(try await publish { $0.testflightAction = "create-group"; $0.groupName = "External beta"; $0.internalGroup = false }.state == "complete")
        let external = try #require(apple.groups.last?["id"] as? String)
        #expect(try await publish { $0.testflightAction = "rename-group"; $0.groupId = external; $0.groupName = "Public beta" }.state == "complete")
        #expect(try await publish { $0.testflightAction = "set-group-setting"; $0.groupId = external; $0.groupSetting = "public-link-limit"; $0.groupSettingValue = .number(500) }.state == "complete")
        #expect((apple.groups.last?["attributes"] as? [String: Any])?["name"] as? String == "Public beta" && (apple.groups.last?["attributes"] as? [String: Any])?["publicLinkLimit"] as? Int == 500)

        #expect(try await publish { $0.testflightAction = "invite-tester"; $0.groupId = external; $0.testerEmail = "new.tester@example.com" }.state == "complete")
        let invited = try #require(apple.testers.last?["id"] as? String)
        #expect(apple.groupTesters[external] == [invited])
        #expect(try await publish { $0.testflightAction = "add-tester"; $0.groupId = external; $0.testerId = "tester-1" }.state == "complete")
        #expect(try await publish { $0.testflightAction = "send-invitation"; $0.testerId = invited }.state == "complete")
        var installed = PublishRequest(accountId: account.id, appId: app, scope: .testflight); installed.testflightAction = "send-invitation"; installed.testerId = "tester-1"
        await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: installed, client: client) }

        #expect(try await publish({ $0.testflightAction = "save-build-notes"; $0.locale = "en-US"; $0.whatsNew = "Try the synthetic flow." }, build: "build-7").state == "complete")
        #expect(try await publish({ $0.testflightAction = "save-build-notes"; $0.locale = "en-US"; $0.whatsNew = "Try the second synthetic flow." }, build: "build-7").state == "complete")
        #expect((apple.betaBuildLocales[0]["attributes"] as? [String: Any])?["whatsNew"] as? String == "Try the second synthetic flow.")
        #expect(try await publish { $0.testflightAction = "save-beta-info"; $0.locale = "en-US"; $0.betaDescription = "A synthetic app."; $0.feedbackEmail = "feedback@example.com" }.state == "complete")
        #expect(try await publish { $0.testflightAction = "save-beta-license"; $0.agreementText = "Updated synthetic terms." }.state == "complete")
        #expect(apple.license == "Updated synthetic terms.")
        #expect(try await publish({ $0.testflightAction = "set-encryption-use"; $0.usesNonExemptEncryption = false }, build: "build-7").state == "complete")
        apple.lock.withLock { apple.betaExternalState = "READY_FOR_BETA_SUBMISSION" }
        #expect(try await publish({ $0.testflightAction = "submit-beta-review" }, build: "build-7").state == "complete")
        apple.lock.withLock { apple.betaExternalState = "READY_FOR_BETA_TESTING" }
        #expect(try await publish({ $0.testflightAction = "notify-build-testers" }, build: "build-7").state == "complete")
        var resubmit = PublishRequest(accountId: account.id, appId: app, scope: .testflight, buildId: "build-7"); resubmit.testflightAction = "submit-beta-review"
        #expect(try await session.preparePublishing(account: account, request: resubmit, client: client).steps.isEmpty)

        var rename = PublishRequest(accountId: account.id, appId: app, scope: .testflight); rename.testflightAction = "rename-group"; rename.groupId = external; rename.groupName = "Renamed"
        let stale = try await session.preparePublishing(account: account, request: rename, client: client)
        apple.lock.withLock { var attributes = apple.groups.last!["attributes"] as! [String: Any]; attributes["name"] = "Changed elsewhere"; apple.groups[apple.groups.count - 1]["attributes"] = attributes }
        let writes = apple.writes.count
        await #expect(throws: PublishFailure.conflict) { try await session.approvePublishing(account: account, appId: app, id: stale.id, fingerprint: stale.fingerprint, client: client) }
        #expect(try await session.publishReview(accountId: account.id, appId: app, id: stale.id).state == "conflict")
        #expect(apple.writes.count == writes)

        #expect(try await publish { $0.testflightAction = "remove-tester"; $0.groupId = external; $0.testerId = "tester-1" }.state == "complete")
        #expect(try await publish { $0.testflightAction = "remove-app-tester"; $0.testerId = invited }.state == "complete")
        #expect(try await publish { $0.testflightAction = "delete-group"; $0.groupId = external }.state == "complete")
        #expect(apple.groups.map { $0["id"] as! String } == ["group-1"] && apple.testers.map { $0["id"] as! String } == ["tester-1"])
    }

    @Test func inAppPurchaseAndSubscriptionPricesArePublishedWithTheirSchedules() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "product-prices.appstoreconnect.test", app = "1000000001"
        StubProtocol.handle(host) { apple.handle($0) }
        let client = try client(account, host: host)
        let catalog = try await session.priceProducts(appId: app, client: client)
        #expect(catalog.purchases?.map(\.name) == ["Coins"] && catalog.subscriptions?.map(\.group) == ["Premium"])
        let tomorrow = ReportTables.dayFormat.string(from: Date().addingTimeInterval(86_400))
        func publish(_ configure: (inout PublishRequest) -> Void) async throws -> PublishReview {
            var request = PublishRequest(accountId: account.id, appId: app, scope: .productPricing); configure(&request)
            let review = try await session.preparePublishing(account: account, request: request, client: client)
            return try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: client)
        }

        var both = PublishRequest(accountId: account.id, appId: app, scope: .productPricing)
        both.purchasePrice = PurchasePriceChange(productId: "iap-1", territory: "USA", pricePointId: "iap-pp-usa-099", startDate: nil)
        both.subscriptionPrice = SubscriptionPriceChange(productId: "sub-1", territory: "USA", pricePointId: "sub-pp-usa-599", startDate: tomorrow, planType: nil, preserveCurrentPrice: true)
        await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: both, client: client) }
        var dated = PublishRequest(accountId: account.id, appId: app, scope: .productPricing); dated.purchasePrice = PurchasePriceChange(productId: "iap-1", territory: "USA", pricePointId: "iap-pp-usa-099", startDate: tomorrow)
        await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: dated, client: client) }

        #expect(try await publish { $0.purchasePrice = PurchasePriceChange(productId: "iap-1", territory: "USA", pricePointId: "iap-pp-usa-099", startDate: nil) }.state == "complete")
        let first = try await session.productPriceSchedule(appId: app, productId: "iap-1", client: client)
        #expect(first.schedule.baseTerritory == "USA" && first.schedule.rows.map(\.customerPrice) == ["0.99"])
        #expect(try await publish { $0.purchasePrice = PurchasePriceChange(productId: "iap-1", territory: "USA", pricePointId: "iap-pp-usa-199", startDate: tomorrow) }.state == "complete")
        let scheduled = try await session.productPriceSchedule(appId: app, productId: "iap-1", client: client)
        #expect(scheduled.schedule.rows.map(\.customerPrice) == ["0.99", "1.99"])
        let phases = ProductPricing.phases(scheduled.schedule.rows, today: ReportTables.dayFormat.string(from: Date()))
        #expect(scheduled.schedule.rows.map { phases[$0.key] } == [.current, .future])

        // Prices per country or region join the same reviewed schedule; a price point from another country is refused before any write.
        let later2 = ReportTables.dayFormat.string(from: Date().addingTimeInterval(3 * 86_400))
        var byCountry = PublishRequest(accountId: account.id, appId: app, scope: .productPricing)
        byCountry.purchasePrice = PurchasePriceChange(productId: "iap-1", territory: "USA", pricePointId: "iap-pp-usa-099", startDate: later2, territoryPoints: ["SWE": "iap-pp-swe-10"])
        let countryReview = try await session.preparePublishing(account: account, request: byCountry, client: client)
        var included: [JSONText] = []
        if case .array(let items)? = countryReview.steps.first?.body?["included"] { included = items }
        #expect(included.contains { $0["id"]?.text == "new-price-SWE" && $0["relationships"]?["inAppPurchasePricePoint"]?["data"]?["id"]?.text == "iap-pp-swe-10" })
        var foreign = byCountry; foreign.purchasePrice?.territoryPoints = ["SWE": "iap-pp-usa-199"]
        await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: foreign, client: client) }

        #expect(try await publish { $0.subscriptionPrice = SubscriptionPriceChange(productId: "sub-1", territory: "USA", pricePointId: "sub-pp-usa-599", startDate: tomorrow, planType: nil, preserveCurrentPrice: true) }.state == "complete")
        #expect(apple.subscriptionPrices.count == 2)

        var later = PublishRequest(accountId: account.id, appId: app, scope: .productPricing)
        later.subscriptionPrice = SubscriptionPriceChange(productId: "sub-1", territory: "USA", pricePointId: "sub-pp-usa-499", startDate: ReportTables.dayFormat.string(from: Date().addingTimeInterval(2 * 86_400)), planType: nil, preserveCurrentPrice: false)
        let stale = try await session.preparePublishing(account: account, request: later, client: client)
        apple.lock.withLock { apple.subscriptionPrices.removeLast() }
        let writes = apple.writes.count
        await #expect(throws: PublishFailure.conflict) { try await session.approvePublishing(account: account, appId: app, id: stale.id, fingerprint: stale.fingerprint, client: client) }
        #expect(apple.writes.count == writes)
    }
    @Test func listingReviewIncludesOnlyItsSelectedLanguage() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "language-scope.appstoreconnect.test"
        let app = "1000000001", revision = "00000000-0000-4000-8000-000000000002"
        _ = try await session.addLanguage(accountId: account.id, appId: app, revisionId: revision, versionId: "version-1", locale: "sv", copyFrom: "en-US")
        apple.appInfoName = "Synthetic remote name"
        StubProtocol.handle(host) { apple.handle($0) }
        let client = try client(account, host: host)
        var request = PublishRequest(accountId: account.id, appId: app, scope: .metadata, targetMode: "apple-version", revisionId: revision, versionId: "version-1")
        request.mediaStage = PublishRequest.textStage; request.listingLocale = "en-US"
        #expect(try PublishRequest(request.json)?.validated() == request)
        let english = try await session.preparePublishing(account: account, request: request, client: client)
        #expect(!english.steps.isEmpty && english.steps.allSatisfy { $0.label.contains("en-US") })
        #expect(english.request.listingLocale == "en-US" && apple.writes.isEmpty)
        request.listingLocale = "sv"
        let swedish = try await session.preparePublishing(account: account, request: request, client: client)
        #expect(!swedish.steps.isEmpty && swedish.steps.allSatisfy { $0.label.contains("sv") })
        #expect(apple.writes.isEmpty)
        request.listingLocale = "unsupported"
        #expect(throws: PublishFailure.self) { try request.validated() }
        request.listingLocale = "de-DE"
        await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: request, client: client) }
    }

    @Test(arguments: ["marketingUrl", "supportUrl"])
    func reviewedURLRemovalSendsNullAndDoesNotResendMatchingText(_ field: String) async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "nullable-\(field.lowercased()).appstoreconnect.test"
        let app = "1000000001", revisionId = "00000000-0000-4000-8000-000000000002"
        let source = try #require(try await session.revisions(accountId: account.id, appId: app).first { $0.id == revisionId })
        let revision = try await session.workspaceRevision(source, accountId: account.id, appId: app)
        let selections = try LanguageEditorState.selections(revision: revision, versionId: "version-1", locale: "en-US")
        var text = try LanguageEditorState(await session.languageTextDrafts(accountId: account.id, appId: app, revisionId: revisionId, selections: selections))
        try text.change(try #require(text.fields.first { $0.key == field }), to: "")
        try text.change(try #require(text.fields.first { $0.key == "promotionalText" }), to: "Synthetic new promotional copy.")
        let entries = try text.entries(), receipt = try await session.saveLanguageDraft(accountId: account.id, appId: app, revisionId: revisionId, entries: entries)
        try text.confirmed(entries, fingerprints: receipt)
        var versionFields = Dictionary(uniqueKeysWithValues: text.fields.filter { $0.selection.scope == .version }.map { ($0.key, text.value($0)) })
        versionFields["locale"] = "en-US"; versionFields[field] = "https://example.com/previous"; versionFields["promotionalText"] = "Synthetic previous promotional copy."
        apple.locales[0]["attributes"] = versionFields
        var infoFields = Dictionary(uniqueKeysWithValues: text.fields.filter { $0.selection.scope == .appInfo }.map { ($0.key, text.value($0)) })
        infoFields["locale"] = "en-US"
        let info: [String: Any] = ["type": "appInfoLocalizations", "id": "info-locale-1", "attributes": infoFields,
            "relationships": ["appInfo": ["data": ["type": "appInfos", "id": "info-1"]]]]
        StubProtocol.handle(host) { request in
            if request.httpMethod == "GET", request.url?.path == "/v1/appInfos/info-1/appInfoLocalizations" { return apple.page([info]) }
            if request.httpMethod == "PATCH", request.url?.path == "/v1/appStoreVersionLocalizations/version-locale-1",
               let body = (try? JSONSerialization.jsonObject(with: apple.body(request))) as? [String: Any],
               let data = body["data"] as? [String: Any], let fields = data["attributes"] as? [String: Any] {
                guard fields[field] is NSNull else {
                    return (422, [:], JSONText.object([("errors", .array([.object([("code", .string("ENTITY_ERROR.ATTRIBUTE.TYPE")),
                        ("detail", .string("Synthetic URL must be a valid URI or null."))])]))]).data)
                }
                var attributes = apple.locales[0]["attributes"] as! [String: Any]
                for (key, value) in fields { attributes[key] = value }
                apple.locales[0]["attributes"] = attributes
                apple.writes.append(("PATCH", "/v1/appStoreVersionLocalizations/version-locale-1", body))
                return apple.page(apple.locales[0])
            }
            return apple.handle(request)
        }
        let client = try client(account, host: host)
        var request = try text.publishingRequest(accountId: account.id, appId: app, revisionId: revisionId, versionId: "version-1", targetMode: "apple-version")
        request.listingLocale = "en-US"; request.mediaStage = PublishRequest.textStage
        let prepared = try await session.prepareLanguageListingReview(account: account, request: request, client: client)
        #expect(apple.writes.isEmpty && prepared.review.steps.count == 1)
        #expect(prepared.review.steps.first?.after?.contains(field + ": Not Set") == true)
        let completed = try await session.approvePublishing(account: account, appId: app, id: prepared.review.id, fingerprint: prepared.review.fingerprint, client: client)
        #expect(completed.state == "complete", "\(completed.error ?? "")")
        #expect(apple.writes.count == 1)
        let saved = try await session.prepareLanguageListingReview(account: account, request: request, client: client)
        #expect(saved.review.steps.isEmpty && apple.writes.count == 1)
        #expect(StubProtocol.requests(host).allSatisfy { !($0.url?.path.contains("Screenshot") ?? true) })
    }

    @Test func aVersionSetupRaceStillComparesTheLanguageBeforeReportingItMatches() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "synthetic-language-setup-race.appstoreconnect.test"
        let app = "1000000001", revision = "00000000-0000-4000-8000-000000000002"
        _ = try await session.saveReleasePlan(account: account, appId: app, start: .reuse, sourceRevisionId: revision, baseVersionId: "version-1",
            targetVersion: "2.0", releaseType: "MANUAL", earliestReleaseDate: nil, expected: "null")
        let text = try await session.textDraft(accountId: account.id, appId: app, revisionId: revision, localizationId: "version-locale-1", scope: .version)
        var fields = text.fields; fields["description"] = "Synthetic text that still needs to sync after version setup."
        _ = try await session.saveTextDraft(accountId: account.id, appId: app, revisionId: revision, localizationId: "version-locale-1", scope: .version, fields: fields, fingerprint: text.fingerprint)
        var attributes = apple.versions[0]["attributes"] as! [String: Any]; attributes["versionString"] = "2.0"; apple.versions[0]["attributes"] = attributes
        StubProtocol.handle(host) { request in
            if request.httpMethod == "GET", request.url?.path == "/v1/apps/1000000001/appStoreVersions" {
                return apple.lock.withLock { apple.counter += 1; return apple.page(apple.counter == 1 ? [] : apple.versions) }
            }
            return apple.handle(request)
        }
        var request = PublishRequest(accountId: account.id, appId: app, scope: .metadata, targetMode: "release-plan", revisionId: revision, versionId: "version-1")
        request.listingLocale = "en-US"; request.mediaStage = PublishRequest.textStage
        let compared = try await session.prepareLanguageListingReview(account: account, request: request, client: try client(account, host: host))
        #expect(!compared.versionSetup && compared.review.request == request && !compared.review.steps.isEmpty)
        #expect(compared.review.steps.contains { $0.after?.contains(fields["description"]!) == true })
        #expect(apple.counter >= 3 && apple.writes.isEmpty, "A setup race must not count as already-synced text or send an unapproved change")
    }

    @Test func nullableURLsKeepEmptyTextDistinctAndInvalidAddressesFailValidation() throws {
        let fields = [("marketingUrl", ""), ("supportUrl", ""), ("privacyPolicyUrl", ""), ("privacyChoicesUrl", ""), ("promotionalText", "")]
        let updated = JSONText.object(WorkspaceSession.publishedTextAttributes(fields))
        for (field, _) in fields where field.hasSuffix("Url") { #expect(updated[field] == .null) }
        #expect(updated["promotionalText"] == .string(""))
        let created = JSONText.object(WorkspaceSession.publishedTextAttributes(fields, creating: true))
        #expect(created["marketingUrl"] == nil && created["supportUrl"] == nil && created["privacyPolicyUrl"] == nil && created["privacyChoicesUrl"] == nil)
        #expect(created["promotionalText"] == .string(""))
        #expect(throws: PublishFailure.self) { try WorkspaceSession.publishedText([("marketingUrl", "not a public URL")], appInfo: false) }
    }

    @Test func britishTextPreparesWithoutScreenshotsOrMediaRequests() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "british-text-only.appstoreconnect.test"
        let revision = "00000000-0000-4000-8000-000000000002"
        _ = try await session.addLanguage(accountId: account.id, appId: "1000000001", revisionId: revision, versionId: "version-1", locale: "en-GB", copyFrom: "en-US")
        apple.sets = []; apple.shots = []; apple.placements = []; apple.libraryImages = []
        StubProtocol.handle(host) { apple.handle($0) }
        var request = PublishRequest(accountId: account.id, appId: "1000000001", scope: .metadata, targetMode: "apple-version", revisionId: revision, versionId: "version-1")
        request.mediaStage = PublishRequest.textStage; request.listingLocale = "en-GB"
        let prepared = try await session.prepareLanguageListingReview(account: account, request: request, client: try client(account, host: host))
        #expect(!prepared.review.steps.isEmpty && prepared.review.request == request)
        #expect(prepared.review.steps.allSatisfy { $0.label.contains("en-GB") && $0.kind == .api })
        #expect(apple.writes.isEmpty, "Preparing text must not send anything without Publish approval")
        #expect(StubProtocol.requests(host).allSatisfy { $0.httpMethod == "GET" && !($0.url?.path.contains("Screenshot") ?? true) && !($0.url?.path.contains("AssetLibrar") ?? true) })
    }

    @Test(arguments: ["apple-version", "release-plan"])
    func britishTextSavesAndSyncsOnceWithoutReleaseReadinessOrMedia(_ targetMode: String) async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "british-partial-\(targetMode).appstoreconnect.test"
        let app = "1000000001", revisionId = "00000000-0000-4000-8000-000000000002"
        _ = try await session.addLanguage(accountId: account.id, appId: app, revisionId: revisionId, versionId: "version-1", locale: "en-GB", copyFrom: "en-US")
        if targetMode == "release-plan" {
            _ = try await session.saveReleasePlan(account: account, appId: app, start: .reuse, sourceRevisionId: revisionId, baseVersionId: "version-1",
                targetVersion: "2.0", releaseType: "MANUAL", earliestReleaseDate: nil, expected: "null")
            var attributes = apple.versions[0]["attributes"] as! [String: Any]; attributes["versionString"] = "2.0"; apple.versions[0]["attributes"] = attributes
        }
        let source = try #require(try await session.revisions(accountId: account.id, appId: app).first { $0.id == revisionId })
        let revision = try await session.workspaceRevision(source, accountId: account.id, appId: app)
        let selections = try LanguageEditorState.selections(revision: revision, versionId: "version-1", locale: "en-GB")
        var text = try LanguageEditorState(await session.languageTextDrafts(accountId: account.id, appId: app, revisionId: revisionId, selections: selections))
        let description = try #require(text.fields.first { $0.key == "description" })
        try text.change(description, to: "Synthetic British copy saved independently of submission.")
        let entries = try text.entries(), receipt = try await session.saveLanguageDraft(accountId: account.id, appId: app, revisionId: revisionId, entries: entries)
        try text.confirmed(entries, fingerprints: receipt)
        #expect(!text.dirty && StubProtocol.requests(host).isEmpty)
        var infoFields = Dictionary(uniqueKeysWithValues: text.fields.filter { $0.selection.scope == .appInfo }.map { ($0.key, text.value($0)) })
        infoFields["locale"] = "en-GB"
        let info: [String: Any] = ["type": "appInfoLocalizations", "id": "synthetic-british-info", "attributes": infoFields,
            "relationships": ["appInfo": ["data": ["type": "appInfos", "id": "info-1"]]]]
        apple.locales.append(["type": "appStoreVersionLocalizations", "id": "synthetic-british-text", "attributes": ["locale": "en-GB", "description": "Synthetic earlier British copy"],
            "relationships": ["appStoreVersion": ["data": ["type": "appStoreVersions", "id": "version-1"]]]])
        apple.sets = []; apple.shots = []; apple.placements = []; apple.libraryImages = []; apple.ageAnswers = [:]
        #expect((apple.versions[0]["attributes"] as? [String: Any])?["copyright"] == nil && apple.reviewDetails.isEmpty)
        StubProtocol.handle(host) { request in
            if request.url?.path == "/v1/appInfos/info-1/appInfoLocalizations" { return apple.page([info]) }
            if request.url?.path == "/v1/appInfoLocalizations/synthetic-british-info" { return apple.page(info) }
            if request.httpMethod == "PATCH", request.url?.path == "/v1/appStoreVersionLocalizations/synthetic-british-text" {
                let body = try! JSONSerialization.jsonObject(with: StubProtocol.body(request)) as! [String: Any]
                return apple.lock.withLock {
                    let index = apple.locales.firstIndex { $0["id"] as? String == "synthetic-british-text" }!
                    var attributes = apple.locales[index]["attributes"] as! [String: Any]
                    for (field, value) in (body["data"] as! [String: Any])["attributes"] as! [String: Any] { attributes[field] = value }
                    apple.locales[index]["attributes"] = attributes
                    apple.writes.append(("PATCH", "/v1/appStoreVersionLocalizations/synthetic-british-text", body))
                    return apple.page(apple.locales[index])
                }
            }
            return apple.handle(request)
        }
        let client = try client(account, host: host)
        var request = try text.publishingRequest(accountId: account.id, appId: app, revisionId: revisionId, versionId: "version-1", targetMode: targetMode)
        request.listingLocale = "en-GB"; request.mediaStage = PublishRequest.textStage
        let before = try await session.storeAccess { try $0.document(namespace: "drafts", key: account.id + ":" + app + ":" + revisionId)?.payload }
        let prepared = try await session.prepareLanguageListingReview(account: account, request: request, client: client)
        #expect(apple.writes.isEmpty && !prepared.review.steps.isEmpty)
        #expect(prepared.review.steps.allSatisfy { $0.kind == .api && $0.path == [.string("appStoreVersionLocalizations"), .string("synthetic-british-text")] })
        let completed = try await session.approvePublishing(account: account, appId: app, id: prepared.review.id, fingerprint: prepared.review.fingerprint, client: client)
        #expect(completed.state == "complete", "\(completed.error ?? "")")
        #expect(apple.writes.count == 1 && apple.writes.first?.1 == "/v1/appStoreVersionLocalizations/synthetic-british-text")
        #expect(try await session.storeAccess { try $0.document(namespace: "drafts", key: account.id + ":" + app + ":" + revisionId)?.payload } == before)
        let matching = try await session.prepareLanguageListingReview(account: account, request: request, client: client)
        #expect(matching.review.steps.isEmpty && apple.writes.count == 1)
        #expect(StubProtocol.requests(host).allSatisfy { !($0.url?.path.contains("Screenshot") ?? true) && !($0.url?.path.contains("AssetLibrar") ?? true) })
        await #expect(throws: PublishFailure.used) { try await session.approvePublishing(account: account, appId: app, id: prepared.review.id, fingerprint: prepared.review.fingerprint, client: client) }
        #expect(apple.writes.count == 1)
    }

}
