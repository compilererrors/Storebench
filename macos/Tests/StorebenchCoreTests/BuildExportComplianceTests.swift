import Foundation
import Testing
@testable import StorebenchCore

/// Synthetic Apple declarations for one build: what the Release step reads, and creating a declaration through one review.
@Suite(.serialized) struct BuildExportComplianceTests {
    init() throws { _ = try TestIsolation.require() }
    let app = "1000000001"
    private enum Failure: Error { case synthetic }

    static func declaration(_ id: String, state: String, platform: String? = nil, description: String = "Synthetic encryption declaration", thirdParty: Bool = true) -> [String: Any] {
        var attributes: [String: Any] = ["appEncryptionDeclarationState": state, "appDescription": description, "containsProprietaryCryptography": false,
                                         "containsThirdPartyCryptography": thirdParty, "availableOnFrenchStore": true]
        if let platform { attributes["platform"] = platform }
        return ["type": "appEncryptionDeclarations", "id": id, "attributes": attributes, "relationships": ["app": ["data": ["type": "apps", "id": "1000000001"]]]]
    }

    /// Creates declarations the way Apple does now: without a platform, waiting for Apple's review.
    final class Creating: @unchecked Sendable {
        let model: SyntheticBetaDeclarations
        var created: [[String: Any]] = []
        var deniedReads = false
        /// Apple answers 404 on the app's own declaration path and for a build without a declaration.
        var appPathGone = false, linkMissing = false
        /// Apple's build list under the app sends relationship links without data, and owner reads per build can fail.
        var appleShapedBuilds = false
        var failing: String?
        private let record = NSLock()
        private var requested: [String] = []
        var paths: [String] { record.withLock { requested } }
        init() throws { model = try SyntheticBetaDeclarations(); model.declarations = [] }
        func handle(_ request: URLRequest) -> (Int, [String: String], Data) {
            let path = request.url!.path
            record.withLock { requested.append(path) }
            if path == failing { return (400, ["Content-Type": "application/json"], Data(#"{"errors":[]}"#.utf8)) }
            if appleShapedBuilds, path == "/v1/apps/1000000001/builds" {
                let linked = model.lock.withLock { model.apple.builds.map { build -> [String: Any] in
                    var item = build; let id = build["id"] as! String
                    item["relationships"] = ["app": ["links": ["related": "/v1/builds/\(id)/app"]], "preReleaseVersion": ["links": ["related": "/v1/builds/\(id)/preReleaseVersion"]]]
                    return item
                } }
                return (200, ["Content-Type": "application/json"], try! JSONSerialization.data(withJSONObject: ["data": linked, "links": [:]]))
            }
            if appleShapedBuilds, path.hasPrefix("/v1/builds/"), path.hasSuffix("/relationships/app") { return (404, ["Content-Type": "application/json"], Data(#"{"errors":[]}"#.utf8)) }
            if deniedReads, path == "/v1/apps/1000000001/appEncryptionDeclarations" { return (403, ["Content-Type": "application/json"], Data(#"{"errors":[]}"#.utf8)) }
            if appPathGone, path == "/v1/apps/1000000001/appEncryptionDeclarations" { return (404, ["Content-Type": "application/json"], Data(#"{"errors":[]}"#.utf8)) }
            if request.httpMethod == "GET", path == "/v1/appEncryptionDeclarations", request.url!.query?.contains("filter%5Bapp%5D=1000000001") == true || request.url!.query?.contains("filter[app]=1000000001") == true {
                return model.lock.withLock { (200, ["Content-Type": "application/json"], try! JSONSerialization.data(withJSONObject: ["data": model.declarations, "links": [:]])) }
            }
            if linkMissing, path == "/v1/builds/build-7/relationships/appEncryptionDeclaration" { return (404, ["Content-Type": "application/json"], Data(#"{"errors":[]}"#.utf8)) }
            guard request.httpMethod == "POST", path == "/v1/appEncryptionDeclarations" else { return model.handle(request) }
            return model.lock.withLock {
                let body = try! JSONSerialization.jsonObject(with: model.apple.body(request)) as! [String: Any], data = body["data"] as! [String: Any]
                var attributes = data["attributes"] as! [String: Any]; attributes["appEncryptionDeclarationState"] = "CREATED"
                let item: [String: Any] = ["type": "appEncryptionDeclarations", "id": "decl-new", "attributes": attributes, "relationships": ["app": ["data": ["type": "apps", "id": "1000000001"]]]]
                created.append(body); model.declarations.append(item)
                return (201, ["Content-Type": "application/json"], try! JSONSerialization.data(withJSONObject: ["data": item]))
            }
        }
    }

    func answers() -> EncryptionAnswers { EncryptionAlgorithms.standard.answers(description: "Encrypts the synthetic local library with an industry standard algorithm.", availableOnFrenchStore: true) }

    @Test func emptyFailedAndListedDeclarationsNameOneNextStep() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), synthetic = try Creating(), host = "build-export-states.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        StubProtocol.handle(host) { synthetic.handle($0) }

        let empty = try await session.buildExportCompliance(appId: app, buildId: "build-7", platform: "IOS", client: client)
        #expect(empty.declarations.isEmpty && empty.currentId == nil && empty.approved.isEmpty && empty.next == .create)

        synthetic.deniedReads = true
        do { _ = try await session.buildExportCompliance(appId: app, buildId: "build-7", platform: "IOS", client: client); Issue.record("A denied read must not look like an empty list.") }
        catch { #expect(AppInformation.loadMessage(error, subject: "this build's export compliance").contains("status 403")) }
        synthetic.deniedReads = false

        synthetic.model.declarations = [Self.declaration("decl-any", state: "APPROVED"), Self.declaration("decl-ios", state: "APPROVED", platform: "IOS"),
                                        Self.declaration("decl-mac", state: "APPROVED", platform: "MAC_OS"), Self.declaration("decl-pending", state: "IN_REVIEW")]
        let listed = try await session.buildExportCompliance(appId: app, buildId: "build-7", platform: "IOS", client: client)
        #expect(listed.approved.map(\.id) == ["decl-any", "decl-ios"] && listed.next == .choose)
        synthetic.model.linkedPage = ["type": "appEncryptionDeclarations", "id": "decl-any"]
        #expect(try await session.buildExportCompliance(appId: app, buildId: "build-7", platform: "IOS", client: client).next == .done)
        synthetic.model.linkedPage = ["type": "appEncryptionDeclarations", "id": "decl-pending"]
        #expect(try await session.buildExportCompliance(appId: app, buildId: "build-7", platform: "IOS", client: client).next == .waiting)
        synthetic.model.linkedPage = ["type": "appEncryptionDeclarations", "id": "decl-mac"]
        #expect(try await session.buildExportCompliance(appId: app, buildId: "build-7", platform: "IOS", client: client).next == .choose)
        #expect(synthetic.model.writes.isEmpty && synthetic.created.isEmpty)
    }

    @Test func aDeclarationWithoutAPlatformAppliesToEveryPlatformOfTheApp() async throws {
        #expect(TestFlightEncryption.declarationFits(nil, platform: "MAC_OS") && TestFlightEncryption.declarationFits(" ", platform: "MAC_OS"))
        #expect(TestFlightEncryption.declarationFits("MAC_OS", platform: "MAC_OS") && !TestFlightEncryption.declarationFits("IOS", platform: "MAC_OS"))
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), model = try SyntheticBetaDeclarations(), host = "build-export-platformless.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        model.declarations = [Self.declaration("decl-synthetic", state: "APPROVED")]
        StubProtocol.handle(host) { model.handle($0) }
        var request = PublishRequest(accountId: account.id, appId: app, scope: .testflight, buildId: "build-7"); request.testflightAction = "assign-encryption-declaration"; request.declarationId = "decl-synthetic"
        let review = try await session.preparePublishing(account: account, request: request, client: client)
        #expect(review.steps.map(\.label) == ["Assign approved encryption declaration"])
        #expect(try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: client).state == "complete")
        #expect(try await session.buildEncryptionDeclaration(appId: app, buildId: "build-7", client: client) == "decl-synthetic")
    }

    @Test func aNewDeclarationIsCreatedAndAttachedToTheBuildThroughOneReview() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), synthetic = try Creating(), host = "build-export-create.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        StubProtocol.handle(host) { synthetic.handle($0) }
        var request = PublishRequest(accountId: account.id, appId: app, scope: .exportCompliance, buildId: "build-7"); request.encryptionDeclaration = answers()

        let review = try await session.preparePublishing(account: account, request: request, client: client)
        #expect(review.steps.map(\.label) == ["Create app encryption declaration", "Attach declaration to build 7"])
        #expect(review.steps[1].before == "No declaration assigned" && review.steps[1].after == "The declaration created above")
        #expect(synthetic.created.isEmpty && synthetic.model.writes.isEmpty)

        let done = try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: client)
        #expect(done.state == "complete", "\(done.error ?? "")")
        #expect(synthetic.created.count == 1 && synthetic.model.writes.count == 1)
        let attributes = try #require((synthetic.created[0]["data"] as? [String: Any])?["attributes"] as? [String: Any])
        #expect(attributes["containsThirdPartyCryptography"] as? Bool == true && attributes["containsProprietaryCryptography"] as? Bool == false && attributes["availableOnFrenchStore"] as? Bool == true)
        let after = try await session.buildExportCompliance(appId: app, buildId: "build-7", platform: "IOS", client: client)
        #expect(after.currentId == "decl-new" && after.next == .waiting)
        await #expect(throws: PublishFailure.used) { try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: client) }
        #expect(try await session.preparePublishing(account: account, request: request, client: client).steps.isEmpty)
        #expect(synthetic.created.count == 1 && synthetic.model.writes.count == 1)
    }

    @Test func anExistingMatchingDeclarationIsAttachedAndAChangedBuildIsRefused() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), synthetic = try Creating(), host = "build-export-match.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        StubProtocol.handle(host) { synthetic.handle($0) }
        var request = PublishRequest(accountId: account.id, appId: app, scope: .exportCompliance, buildId: "build-7"); request.encryptionDeclaration = answers()
        synthetic.model.declarations = [Self.declaration("decl-match", state: "APPROVED", description: answers().appDescription)]
        let attach = try await session.preparePublishing(account: account, request: request, client: client)
        #expect(attach.steps.map(\.label) == ["Attach declaration to build 7"] && attach.steps[0].after == "Declaration decl-match")

        synthetic.model.linkedPage = ["type": "appEncryptionDeclarations", "id": "decl-other"]
        await #expect(throws: PublishFailure.conflict) { try await session.approvePublishing(account: account, appId: app, id: attach.id, fingerprint: attach.fingerprint, client: client) }
        #expect(synthetic.model.writes.isEmpty && synthetic.created.isEmpty)

        synthetic.model.declarations = [Self.declaration("decl-match", state: "APPROVED", platform: "MAC_OS", description: answers().appDescription)]
        await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: request, client: client) }
        var unanswered = synthetic.model.apple.builds[0]["attributes"] as! [String: Any]; unanswered["usesNonExemptEncryption"] = false
        synthetic.model.apple.builds[0]["attributes"] = unanswered; synthetic.model.declarations = []
        await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: request, client: client) }
        #expect(synthetic.model.writes.isEmpty && synthetic.created.isEmpty)
        var mixed = request; mixed.versionId = "version-1"
        #expect(throws: PublishFailure.self) { try mixed.validated() }
    }

    /// Manage Compliance on a build without an answer: App Store Connect answers Yes and attaches the declaration in one go.
    @Test func standardEncryptionInFranceIsSavedWhenAppleAnswers404ForTheAppPathAndTheMissingLink() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), synthetic = try Creating(), host = "build-export-404.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        StubProtocol.handle(host) { synthetic.handle($0) }
        synthetic.appPathGone = true; synthetic.linkMissing = true
        var attributes = synthetic.model.apple.builds[0]["attributes"] as! [String: Any]; attributes.removeValue(forKey: "usesNonExemptEncryption"); synthetic.model.apple.builds[0]["attributes"] = attributes
        // App Store Connect's two answers, with no description typed: Storebench writes the one Apple's API needs.
        var questions = EncryptionQuestionnaire(); questions.algorithms = EncryptionAlgorithms.standard.rawValue; questions.france = "yes"
        var request = PublishRequest(accountId: account.id, appId: app, scope: .exportCompliance, buildId: "build-7"); request.encryptionDeclaration = questions.answers
        let review = try await session.preparePublishing(account: account, request: request, client: client)
        #expect(review.steps.map(\.label) == ["Create app encryption declaration", "Set build encryption use", "Attach declaration to build 7"])
        let done = try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: client)
        #expect(done.state == "complete", "\(done.error ?? "")")
        let sent = (synthetic.created.first?["data"] as? [String: Any])?["attributes"] as? [String: Any]
        #expect(sent?["appDescription"] as? String == "Uses standard encryption algorithms in addition to the encryption within Apple's operating system. Available on the App Store in France.")
    }

    /// Apple refuses to create a declaration for standard encryption outside France. App Store Connect saves that answer on the
    /// build alone, so Save answers No for the build and never sends a declaration Apple would refuse.
    @Test func standardEncryptionOutsideFranceIsTheBuildAnswerAloneAndNeverADeclaration() async throws {
        var questions = EncryptionQuestionnaire(); questions.algorithms = EncryptionAlgorithms.standard.rawValue; questions.france = "no"
        #expect(questions.missing == nil && questions.needsDeclaration == false && questions.answers == nil)
        #expect(questions.nextStep.hasPrefix("Apple keeps no declaration for standard encryption outside France, so Save answers No"))
        questions.france = "yes"; #expect(questions.needsDeclaration == true)
        questions.algorithms = EncryptionAlgorithms.both.rawValue; questions.france = "no"; #expect(questions.needsDeclaration == true)
        #expect(EncryptionQuestionnaire(json: questions.json) == questions && EncryptionQuestionnaire(json: .object([("algorithms", .string("synthetic"))])) == EncryptionQuestionnaire())

        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), synthetic = try Creating(), host = "build-export-outside-france.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        StubProtocol.handle(host) { synthetic.handle($0) }
        var request = PublishRequest(accountId: account.id, appId: app, scope: .exportCompliance, buildId: "build-7")
        request.encryptionDeclaration = EncryptionAlgorithms.standard.answers(description: "Synthetic", availableOnFrenchStore: false)
        await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: request, client: client) }
        #expect(synthetic.created.isEmpty && synthetic.model.writes.isEmpty)

        try await session.saveEncryptionAnswers(questions, accountId: account.id, appId: app, buildId: "build-7")
        #expect(try await session.encryptionAnswers(accountId: account.id, appId: app, buildId: "build-7") == questions)
        try await session.saveEncryptionAnswers(EncryptionQuestionnaire(), accountId: account.id, appId: app, buildId: "build-7")
        #expect(try await session.encryptionAnswers(accountId: account.id, appId: app, buildId: "build-7") == nil)
    }

    @Test func aBuildWithoutAnAnswerIsAnsweredYesBeforeItsNewDeclarationIsAttached() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), synthetic = try Creating(), host = "build-export-unanswered.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        StubProtocol.handle(host) { synthetic.handle($0) }
        var attributes = synthetic.model.apple.builds[0]["attributes"] as! [String: Any]; attributes.removeValue(forKey: "usesNonExemptEncryption"); synthetic.model.apple.builds[0]["attributes"] = attributes
        var request = PublishRequest(accountId: account.id, appId: app, scope: .exportCompliance, buildId: "build-7"); request.encryptionDeclaration = answers()

        let review = try await session.preparePublishing(account: account, request: request, client: client)
        #expect(review.steps.map(\.label) == ["Create app encryption declaration", "Set build encryption use", "Attach declaration to build 7"])
        #expect(review.steps[1].before == "No answer at Apple" && review.steps[1].after == "Uses non-exempt encryption: Yes")
        #expect(synthetic.created.isEmpty && synthetic.model.writes.isEmpty)

        let done = try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: client)
        #expect(done.state == "complete", "\(done.error ?? "")")
        #expect(synthetic.created.count == 1 && synthetic.model.writes.count == 2)
        #expect((synthetic.model.apple.builds[0]["attributes"] as? [String: Any])?["usesNonExemptEncryption"] as? Bool == true)
        #expect(try await session.buildExportCompliance(appId: app, buildId: "build-7", platform: "IOS", client: client).currentId == "decl-new")
    }

    /// Apple's build list under the app links builds without naming their app or version. Every App Store Connect answer still
    /// prepares a complete review from one read of the chosen build, without reading the list or each build's owner.
    @Test func everyAnswerPreparesAReviewFromAppleShapedBuildReads() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), synthetic = try Creating(), host = "build-export-answers.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        StubProtocol.handle(host) { synthetic.handle($0) }
        synthetic.appleShapedBuilds = true
        for algorithms in EncryptionAlgorithms.allCases where !algorithms.exempt {
            for france in ["yes", "no"] {
                var questions = EncryptionQuestionnaire(); questions.algorithms = algorithms.rawValue; questions.france = france
                guard questions.needsDeclaration == true else { #expect(questions.answers == nil); continue }
                var request = PublishRequest(accountId: account.id, appId: app, scope: .exportCompliance, buildId: "build-7"); request.encryptionDeclaration = questions.answers
                let review = try await session.preparePublishing(account: account, request: request, client: client)
                #expect(review.steps.map(\.label) == ["Create app encryption declaration", "Attach declaration to build 7"], "\(algorithms.rawValue), France \(france)")
                let sent = review.steps.first?.body?["data"]?["attributes"]
                #expect(sent?["containsProprietaryCryptography"] == .bool([.proprietary, .both].contains(algorithms)) && sent?["containsThirdPartyCryptography"] == .bool([.standard, .both].contains(algorithms))
                        && sent?["availableOnFrenchStore"] == .bool(france == "yes") && sent?["appDescription"]?.text?.isEmpty == false, "\(algorithms.rawValue), France \(france)")
            }
        }
        // None of the algorithms: only Apple's operating system encryption, so the build answers No and needs no declaration.
        var questions = EncryptionQuestionnaire(); questions.algorithms = EncryptionAlgorithms.operatingSystem.rawValue
        #expect(questions.missing == nil && questions.answers == nil)
        var exempt = PublishRequest(accountId: account.id, appId: app, scope: .testflight, buildId: "build-7"); exempt.testflightAction = "set-encryption-use"; exempt.usesNonExemptEncryption = false
        let none = try await session.preparePublishing(account: account, request: exempt, client: client)
        #expect(none.steps.map(\.label) == ["Set build encryption use"] && none.steps[0].after == "Uses non-exempt encryption: No")
        #expect(none.steps[0].body?["data"]?["attributes"] == .object([("usesNonExemptEncryption", .bool(false))]) && none.steps[0].body?["data"]?["relationships"] == nil)
        #expect(!synthetic.paths.contains("/v1/apps/1000000001/builds") && !synthetic.paths.contains { $0.hasSuffix("/relationships/app") })
        #expect(synthetic.created.isEmpty && synthetic.model.writes.isEmpty)
        let done = try await session.approvePublishing(account: account, appId: app, id: none.id, fingerprint: none.fingerprint, client: client)
        #expect(done.state == "complete", "\(done.error ?? "")")
        #expect(synthetic.created.isEmpty && synthetic.model.writes.count == 1)
        #expect((synthetic.model.apple.builds[0]["attributes"] as? [String: Any])?["usesNonExemptEncryption"] as? Bool == false)
    }

    @Test func aFailedAppleReadNamesItsStatusAndPathInsteadOfAGenericMessage() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), synthetic = try Creating(), host = "build-export-failed-read.appstoreconnect.test", client = try PublishingTests().client(account, host: host)
        StubProtocol.handle(host) { synthetic.handle($0) }
        synthetic.failing = "/v1/preReleaseVersions/pre-1"
        var request = PublishRequest(accountId: account.id, appId: app, scope: .exportCompliance, buildId: "build-7"); request.encryptionDeclaration = answers()
        await #expect(throws: PublishFailure.invalid("App Store Connect answered status 400 for /v1/preReleaseVersions/pre-1. Nothing was sent to App Store Connect. Prepare the review again.")) {
            try await session.preparePublishing(account: account, request: request, client: client)
        }
        #expect(WorkspaceSession.preparationFailure(AppStoreConnectClient.Failure.status(403), read: "/v1/apps/1000000001/appEncryptionDeclarations") as? PublishFailure
                == .invalid("Apple did not allow this API key to read what this change needs (status 403 for /v1/apps/1000000001/appEncryptionDeclarations). Nothing was sent to App Store Connect."))
        #expect(WorkspaceSession.preparationFailure(CancellationError(), read: nil) is CancellationError)
        #expect(synthetic.created.isEmpty && synthetic.model.writes.isEmpty)
    }

    @Test func theQuestionnaireAsksAppStoreConnectsQuestionsInOrder() throws {
        #expect(EncryptionAlgorithms.allCases.map(\.label).last == "None of the algorithms mentioned above" && EncryptionAlgorithms.allCases.count == 4)
        var questions = EncryptionQuestionnaire()
        #expect(!questions.started && questions.missing == "Choose the type of encryption algorithms your app implements.")
        questions.algorithms = EncryptionAlgorithms.operatingSystem.rawValue
        #expect(questions.missing == nil && questions.answers == nil && questions.nextStep.hasPrefix("This build then doesn't use non-exempt encryption."))
        questions.algorithms = EncryptionAlgorithms.standard.rawValue
        #expect(questions.missing == "Choose whether your app is going to be available on the App Store in France.")
        questions.france = "yes"
        // As in App Store Connect, the algorithms and France are all it asks; Apple's description comes from those answers.
        #expect(questions.missing == nil)
        let answers = try #require(questions.answers)
        #expect(answers.containsThirdPartyCryptography && !answers.containsProprietaryCryptography && answers.availableOnFrenchStore)
        #expect(answers.appDescription == "Uses standard encryption algorithms in addition to the encryption within Apple's operating system. Available on the App Store in France.")
        #expect(try answers.validated() == answers)
        questions.description = "Synthetic transport encryption."
        #expect(questions.answers?.appDescription == "Synthetic transport encryption.")
        #expect(questions.nextStep.hasSuffix("Apple asks for your French encryption declaration."))
    }

    @Test func appStoreConnectCategoriesMapToTheBuildAnswerOrADeclaration() {
        #expect(EncryptionAlgorithms.operatingSystem.exempt && !EncryptionAlgorithms.standard.exempt)
        let both = EncryptionAlgorithms.both.answers(description: "Synthetic", availableOnFrenchStore: true)
        #expect(both.containsProprietaryCryptography && both.containsThirdPartyCryptography && both.availableOnFrenchStore)
        let proprietary = EncryptionAlgorithms.proprietary.answers(description: "Synthetic", availableOnFrenchStore: false)
        #expect(proprietary.containsProprietaryCryptography && !proprietary.containsThirdPartyCryptography)
        #expect(EncryptionAlgorithms.standard.documentation(availableOnFrenchStore: false) == "No documentation required in App Store Connect.")
        #expect(EncryptionAlgorithms.standard.documentation(availableOnFrenchStore: true).contains("French encryption declaration"))
        #expect(EncryptionAlgorithms.proprietary.documentation(availableOnFrenchStore: false).contains("CCATS") && !EncryptionAlgorithms.proprietary.documentation(availableOnFrenchStore: false).contains("French"))
    }

    private actor Attempts {
        var count = 0
        func next() -> Int { count += 1; return count }
    }
    @Test func aReadCancelledByAnotherRefreshIsReadAgainButOwnCancellationAndFailuresAreNot() async throws {
        let attempts = Attempts()
        let value = try await AppStoreReadCache.rereadingAfterInvalidation { () async throws -> String in
            if await attempts.next() == 1 { throw CancellationError() }
            return "synthetic"
        }
        let count = await attempts.count
        #expect(value == "synthetic" && count == 2)
        let failing = Attempts()
        await #expect(throws: Failure.synthetic) { try await AppStoreReadCache.rereadingAfterInvalidation { () async throws -> String in _ = await failing.next(); throw Failure.synthetic } }
        #expect(await failing.count == 1)
        let always = Attempts()
        await #expect(throws: CancellationError.self) { try await AppStoreReadCache.rereadingAfterInvalidation { () async throws -> String in _ = await always.next(); throw CancellationError() } }
        #expect(await always.count == 3)
        let own = Attempts()
        let task = Task { try await AppStoreReadCache.rereadingAfterInvalidation { () async throws -> String in _ = await own.next(); withUnsafeCurrentTask { $0?.cancel() }; throw CancellationError() } }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await own.count == 1)
    }
}
