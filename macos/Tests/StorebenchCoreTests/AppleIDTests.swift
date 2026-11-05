import CryptoKit
import Foundation
import Testing
@testable import StorebenchCore

/// A synthetic Apple sign-in and App Store Connect web service: SRP checked on the server side, synthetic answers only.
final class SyntheticAppleID: @unchecked Sendable {
    let lock = NSLock()
    let account = "tester@example.com", password = "synthetic password", salt: [UInt8] = Array(0x01...0x10), code = "123456"
    var clientValue: ProofNumber?, serverSecret = ProofNumber(bytes: [UInt8](repeating: 0x33, count: 32))
    var usages: [[String: Any]] = []
    var published = false
    /// The app's tax category and its conditions; nil while the app uses Apple's default.
    var taxCategory: String?
    var taxConditions: [String] = []
    var writes: [(String, String)] = []
    var counter = 0

    func json(_ status: Int, _ object: Any, _ headers: [String: String] = [:]) -> (Int, [String: String], Data) {
        (status, headers.merging(["Content-Type": "application/json"]) { a, _ in a }, try! JSONSerialization.data(withJSONObject: object))
    }
    var verifier: ProofNumber {
        let key = try! AppleIDProof.derive(password: password, salt: salt, iterations: 1000, protocol: "s2k")
        let x = ProofNumber(bytes: AppleIDProof.hash(ProofNumber(bytes: salt).bytes, AppleIDProof.hash(Array(":".utf8), key)))
        return AppleIDProof.modulus.power(AppleIDProof.generator, x)
    }
    var serverValue: ProofNumber {
        let n = AppleIDProof.modulus.modulus, k = ProofNumber(bytes: AppleIDProof.hash(n.bytes, AppleIDProof.generator.padded(256)))
        let sum = AppleIDProof.modulus.product(k, verifier) + AppleIDProof.modulus.power(AppleIDProof.generator, serverSecret)
        return sum < n ? sum : sum - n
    }
    func expectedProof(_ a: ProofNumber) -> [UInt8] {
        let n = AppleIDProof.modulus.modulus, b = serverValue
        let u = ProofNumber(bytes: AppleIDProof.hash(a.padded(256), b.padded(256)))
        let shared = AppleIDProof.modulus.power(AppleIDProof.modulus.product(a, AppleIDProof.modulus.power(verifier, u)), serverSecret)
        let hn = AppleIDProof.hash(n.bytes), hg = AppleIDProof.hash(AppleIDProof.generator.padded(256))
        return AppleIDProof.hash(zip(hn, hg).map { $0 ^ $1 }, AppleIDProof.hash(Array(account.utf8)), ProofNumber(bytes: salt).bytes, a.bytes, b.bytes, AppleIDProof.hash(shared.bytes))
    }

    func handle(_ request: URLRequest) -> (Int, [String: String], Data) {
        lock.lock(); defer { lock.unlock() }
        let url = request.url!, method = request.httpMethod ?? "GET", body = (try? JSONSerialization.jsonObject(with: StubProtocol.body(request))) as? [String: Any] ?? [:]
        let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
        switch (method, url.path) {
        case ("HEAD", "/logout"): return (302, ["Location": "https://idmsa.appleid.test/auth/signin?widgetKey=syntheticwidgetkey"], Data())
        case ("GET", "/appleauth/auth/signin"):
            guard url.query?.contains("widgetKey=syntheticwidgetkey") == true else { return json(400, [:]) }
            return (200, ["X-Apple-HC-Bits": "4", "X-Apple-HC-Challenge": "synthetic"], Data())
        case ("POST", "/appleauth/auth/signin/init"):
            guard body["accountName"] as? String == account, let a = (body["a"] as? String).flatMap({ Data(base64Encoded: $0) }) else { return json(401, [:]) }
            clientValue = ProofNumber(bytes: Array(a))
            return json(200, ["iteration": 1000, "salt": Data(salt).base64EncodedString(), "protocol": "s2k", "b": Data(serverValue.bytes).base64EncodedString(), "c": "synthetic-c"])
        case ("POST", "/appleauth/auth/signin/complete"):
            guard let a = clientValue, request.value(forHTTPHeaderField: "X-Apple-HC")?.hasPrefix("1:4:") == true,
                  (body["m1"] as? String).flatMap({ Data(base64Encoded: $0) }).map(Array.init) == expectedProof(a) else { return json(401, [:]) }
            return json(409, [:], ["X-Apple-ID-Session-Id": "synthetic-session", "scnt": "synthetic-scnt"])
        case ("GET", "/appleauth/auth"):
            guard request.value(forHTTPHeaderField: "scnt") == "synthetic-scnt" else { return json(401, [:]) }
            return json(200, ["trustedPhoneNumbers": [["id": 1, "numberWithDialCode": "+1 (•••) •••-••00"]], "securityCode": ["length": 6]])
        case ("POST", "/appleauth/auth/verify/trusteddevice/securitycode"):
            return ((body["securityCode"] as? [String: Any])?["code"] as? String) == code ? (204, [:], Data()) : json(400, [:])
        case ("GET", "/appleauth/auth/2sv/trust"):
            return (204, ["Set-Cookie": "myacinfo=synthetic-session-cookie; Path=/; Secure"], Data())
        case ("GET", "/olympus/v1/session"):
            guard url.host == "connect.appleid.test" || cookie.contains("myacinfo") else { return json(401, [:]) }
            return json(200, ["provider": ["providerId": 12345, "name": "Synthetic Team"], "availableProviders": [["providerId": 12345, "name": "Synthetic Team"]]], ["Set-Cookie": "itctx=synthetic-team; Path=/; Secure"])
        case ("POST", "/olympus/v1/session"): return json(200, [:])
        case ("GET", "/iris/v1/apps/1000000001"): return json(200, ["data": ["type": "apps", "id": "1000000001"]])
        case ("GET", "/iris/v1/apps/1000000001/dataUsages"): return json(200, ["data": usages, "links": [:]])
        case ("GET", "/iris/v1/apps/1000000001/dataUsagePublishState"): return json(200, ["data": ["type": "appDataUsagesPublishState", "id": "publish-1", "attributes": ["published": published]]])
        case ("POST", "/iris/v1/appDataUsages"):
            writes.append((method, url.path)); counter += 1; published = false
            let created: [String: Any] = ["type": "appDataUsages", "id": "usage-\(counter)", "relationships": ((body["data"] as? [String: Any])?["relationships"] as? [String: Any] ?? [:]).filter { $0.key != "app" }]
            usages.append(created); return json(201, ["data": created])
        case ("DELETE", let path) where path.hasPrefix("/iris/v1/appDataUsages/"):
            writes.append((method, path)); published = false
            usages.removeAll { "/iris/v1/appDataUsages/\($0["id"] as! String)" == path }; return (204, [:], Data())
        case ("PATCH", "/iris/v1/appDataUsagesPublishState/publish-1"):
            writes.append((method, url.path)); published = ((body["data"] as? [String: Any])?["attributes"] as? [String: Any])?["published"] as? Bool ?? false
            return json(200, ["data": ["type": "appDataUsagesPublishState", "id": "publish-1", "attributes": ["published": published]]])
        case ("GET", "/v1/apps/1000000001"): return json(200, ["data": ["type": "apps", "id": "1000000001"]])
        case ("GET", "/iris/v1/taxCategories"):
            func many(_ type: String, _ ids: [String]) -> [String: Any] { ["data": ids.map { ["type": type, "id": $0] }] }
            func category(_ id: String, _ name: String, required: Bool = false, subcategories: [String] = [], conditions: [String] = []) -> [String: Any] {
                ["type": "taxCategories", "id": id, "attributes": ["name": name, "productType": "APPLICATION", "subcategoryRequired": required],
                 "relationships": ["subcategories": many("taxCategories", subcategories), "conditions": many("taxConditions", conditions)]]
            }
            return json(200, ["data": [category("C001", "App Store software"), category("C002", "Synthetic Category", required: true, subcategories: ["C003", "C004"], conditions: ["T1"])],
                              "included": [category("C003", "Synthetic Subcategory", conditions: ["T2"]), category("C004", "Other Synthetic Subcategory"),
                                           ["type": "taxConditions", "id": "T1", "attributes": ["name": "Synthetic Condition"]], ["type": "taxConditions", "id": "T2", "attributes": ["name": "Other Synthetic Condition"]]],
                              "links": [:]])
        case ("GET", "/iris/v1/appTaxCategories/1000000001"):
            guard let taxCategory else { return json(404, ["errors": [["status": "404", "code": "NOT_FOUND"]]]) }
            return json(200, ["data": ["type": "appTaxCategories", "id": "1000000001", "relationships": ["category": ["data": ["type": "taxCategories", "id": taxCategory]],
                                                                                                       "enabledConditions": ["data": taxConditions.map { ["type": "taxConditions", "id": $0] }]]]])
        case ("POST", "/iris/v1/appTaxCategories"), ("PATCH", "/iris/v1/appTaxCategories/1000000001"):
            writes.append((method, url.path))
            let links = (body["data"] as? [String: Any])?["relationships"] as? [String: Any] ?? [:]
            guard method == "PATCH" || ((links["app"] as? [String: Any])?["data"] as? [String: Any])?["id"] as? String == "1000000001",
                  let category = ((links["category"] as? [String: Any])?["data"] as? [String: Any])?["id"] as? String else { return json(409, [:]) }
            taxCategory = category
            taxConditions = ((links["enabledConditions"] as? [String: Any])?["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            return json(method == "POST" ? 201 : 200, ["data": ["type": "appTaxCategories", "id": "1000000001"]])
        default: return json(404, ["errors": [["status": "404", "code": "NOT_FOUND"]]])
        }
    }
}

@Suite(.serialized) struct AppleIDTests {
    init() throws { _ = try TestIsolation.require() }
    let app = "1000000001"
    static func configuration() -> URLSessionConfiguration { let value = URLSessionConfiguration.ephemeral; value.protocolClasses = [StubProtocol.self]; return value }

    @Test func proofMatchesTheReferenceVectorForBothPasswordProtocols() throws {
        let proof = AppleIDProof(account: "tester@example.com", secret: [UInt8](repeating: 0x11, count: 32))
        let salt: [UInt8] = Array(0x01...0x10)
        let s2k = try proof.respond(password: "synthetic password", salt: salt, iterations: 1000, protocol: "s2k", serverValue: ProofNumber(hex: "6277329c7c1ebfdba8abe0d73000cda2cb4d38d1ec1c2a17aeb06470e868b05ecbfb55e31f7448f5a3c8371740c97243bad38ed841d1699bbc3e8ba927c15cc7acce4169b75078e453a5498ea53d1013f0f4b726f6f394407d80ec2840966bdc5a1c7afdb6d66fb1f4ca4ebe22b7c0d5c7a9ce16ce32dac8640c6debab4c6e59cdb0f2e64393e62593db766ab11429acb7158cbf09ee7e3b6c7a570163f37ec195c74cd0c272e90734c67e2df2ba4de00b541f424bbe20cd5f6a5803d6578276c7cd66ee73ca7e01ca6fcae9a9e2320b9dd5fda1c2bfbc4364a96033414424a4d7b3d5f6b397a09683350ef6e60ea21bd366073f99f6233e44d79c3a7c451a1d").bytes)
        #expect(Data(s2k.m1).map { String(format: "%02x", $0) }.joined() == "e8c979fb3e19dc34857c0764d41a0b63577b963da5e68d471579273635c6a067")
        #expect(Data(s2k.m2).map { String(format: "%02x", $0) }.joined() == "b19875f33b4bc07152ffe51727a6310e424e95f063ef5fdc7a2626de2288b76b")
        let fo = try proof.respond(password: "synthetic password", salt: salt, iterations: 1000, protocol: "s2k_fo", serverValue: ProofNumber(hex: "5238e019d2708d4dcf5634c312d3d63a66e388b0923c36364768476f87a25909813dc64f1acfc4c141690a6df96251a2512ea78641fbf0609df7d881e9080057d0d7547544e48d2c378820fa31e014efcf0d4bfbc40ab78189ff99a40d739f8db69853aa0b865457d64971790daac9b45b95cfc4d4e2b58a7d996e212a3ec21842cd3201e7407c97c84c9053cd75837eda7700ad0981c9212366003475605660ee6cac14086b107a560e90cb78f357c58d495430120b88a73678bbcc7ea1e81b683271777e0fc161fd8d0b459f9be3e875dd78f8fdf3be43cf808089ad4cb3d7a5a1f9fa8bf4f25dd9403067d8e68f7d923609d03b5a827426ec9e6c38e304df").bytes)
        #expect(Data(fo.m1).map { String(format: "%02x", $0) }.joined() == "01715e5de34d98b16ab43f288812222b95325b2784fe487d48b06566d22ece26")
        #expect(throws: AppleIDProof.Failure.invalidChallenge) { try proof.respond(password: "x", salt: salt, iterations: 10, protocol: "s2k", serverValue: AppleIDProof.modulus.modulus.bytes) }
        #expect(throws: AppleIDProof.Failure.unsupportedProtocol) { try proof.respond(password: "x", salt: salt, iterations: 10, protocol: "plain", serverValue: [2]) }
        let stamp = try #require(AppleIDProof.hashcash(bits: 10, challenge: "synthetic"))
        #expect(stamp.hasPrefix("1:10:") && stamp.contains(":synthetic::"))
        let digest = Array(Insecure.SHA1.hash(data: Data(stamp.utf8)))
        #expect(digest[0] == 0 && digest[1] >> 6 == 0)
    }

    @Test func signInChecksThePasswordProofAndTheTwoFactorCodeAndKeepsOnlyAppleCookies() async throws {
        let apple = SyntheticAppleID(), origins = AppleIDOrigins(identity: URL(string: "https://idmsa.appleid.test")!, connect: URL(string: "https://connect.appleid.test")!)
        StubProtocol.handle("idmsa.appleid.test") { apple.handle($0) }; StubProtocol.handle("connect.appleid.test") { apple.handle($0) }
        #expect(throws: AppleIDFailure.rejected) { try AppleIDSignIn(appleId: "tester@example.com", origins: AppleIDOrigins(identity: URL(string: "https://idmsa.example.com")!, connect: origins.connect)) }
        let wrong = try AppleIDSignIn(appleId: "Tester@Example.com ", origins: origins, configuration: Self.configuration())
        await #expect(throws: AppleIDFailure.rejected) { try await wrong.signIn(password: "not the password") }
        let flow = try AppleIDSignIn(appleId: "tester@example.com", origins: origins, configuration: Self.configuration())
        let challenge = try #require(try await flow.signIn(password: apple.password))
        #expect(challenge.codeLength == 6 && challenge.deviceCode && challenge.phones.map(\.id) == [1])
        await #expect(throws: AppleIDFailure.codeRefused("400")) { try await flow.verify(code: "000000") }
        let session = try await flow.verify(code: apple.code)
        #expect(session.appleId == "tester@example.com" && session.teams == [.init(id: "12345", name: "Synthetic Team")])
        #expect(Set(session.cookies.map(\.name)) == ["myacinfo", "itctx"])
        let stored = try #require(AppleWebSession(session.json.stringify()))
        #expect(stored == session && !session.json.stringify().contains(apple.password))
    }

    @Test func appPrivacyIsSavedOrPublishedOnlyThroughAnApprovedReviewAndStaleAnswersSendNothing() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticAppleID()
        StubProtocol.handle("privacy.appleid.test") { apple.handle($0) }; StubProtocol.handle("privacy-api.appstoreconnect.test") { apple.handle($0) }
        let web = AppleWebSession(appleId: "tester@example.com", teams: [.init(id: "12345", name: "Synthetic Team")], cookies: [.init(name: "myacinfo", value: "synthetic", domain: "privacy.appleid.test", path: "/", expires: nil, secure: true)],
                                  origins: AppleIDOrigins(identity: URL(string: "https://idmsa.appleid.test")!, connect: URL(string: "https://privacy.appleid.test")!), signedInAt: "2026-10-31T00:00:00.000Z")
        try await session.routeAppleWeb(web) { Self.configuration() }
        let configuration = Self.configuration()
        let client = AppStoreConnectClient(token: try AppleToken(account: account, privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation), origin: URL(string: "https://privacy-api.appstoreconnect.test")!, configuration: configuration)
        func prepare(_ answers: AppPrivacyAnswers, publish: Bool = true) async throws -> PublishReview {
            var request = PublishRequest(accountId: account.id, appId: app, scope: .appPrivacy); request.appPrivacy = answers
            if publish { request.appPrivacyPublish = true }
            return try await session.preparePublishing(account: account, request: request, client: client)
        }
        let empty = try await session.appPrivacyState(account: account, appId: app)
        #expect(empty.answers == nil && empty.published == false)

        let collected = AppPrivacyAnswers(collects: true, items: [.init(category: "NAME", purposes: ["APP_FUNCTIONALITY"], linked: true), .init(category: "CRASH_DATA", purposes: ["APP_FUNCTIONALITY", "ANALYTICS"], linked: false, tracking: true)])
        await #expect(throws: PublishFailure.self) { try await prepare(AppPrivacyAnswers(collects: true, items: [.init(category: "NAME")])) }
        let saving = try await prepare(collected, publish: false)
        #expect(saving.steps.map(\.method) == ["POST", "POST", "POST", "POST", "POST"] && apple.writes.isEmpty)
        #expect(try await session.approvePublishing(account: account, appId: app, id: saving.id, fingerprint: saving.fingerprint, client: client).state == "complete")
        let saved = try await session.appPrivacyState(account: account, appId: app)
        #expect(saved.answers == collected && saved.published == false)
        #expect(try await prepare(collected, publish: false).steps.isEmpty)
        let review = try await prepare(collected)
        #expect(review.steps.map(\.method) == ["PATCH"])
        #expect(try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: client).state == "complete")
        let after = try await session.appPrivacyState(account: account, appId: app)
        #expect(after.answers == collected && after.published == true)
        let check = try #require(try await session.sectionChecks(accountId: account.id, appId: app)[.privacy])
        #expect(check.answered && check.detail == "Published" && check.summary == "2 data types")
        #expect(try await prepare(collected).steps.isEmpty)

        let none = try await prepare(AppPrivacyAnswers(collects: false))
        #expect(none.steps.map(\.method) == ["DELETE", "DELETE", "DELETE", "DELETE", "DELETE", "POST", "PATCH"])
        apple.lock.withLock { apple.usages.removeLast() }
        let writes = apple.writes.count
        await #expect(throws: PublishFailure.conflict) { try await session.approvePublishing(account: account, appId: app, id: none.id, fingerprint: none.fingerprint, client: client) }
        #expect(apple.writes.count == writes)
        let fresh = try await prepare(AppPrivacyAnswers(collects: false))
        #expect(try await session.approvePublishing(account: account, appId: app, id: fresh.id, fingerprint: fresh.fingerprint, client: client).state == "complete")
        #expect(try await session.appPrivacyState(account: account, appId: app).answers == AppPrivacyAnswers(collects: false))
    }
    @Test func taxCategoryIsSavedOnlyThroughAnApprovedReviewAndStaleChoicesSendNothing() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticAppleID()
        StubProtocol.handle("tax.appleid.test") { apple.handle($0) }; StubProtocol.handle("tax-api.appstoreconnect.test") { apple.handle($0) }
        let web = AppleWebSession(appleId: "tester@example.com", teams: [.init(id: "12345", name: "Synthetic Team")], cookies: [.init(name: "myacinfo", value: "synthetic", domain: "tax.appleid.test", path: "/", expires: nil, secure: true)],
                                  origins: AppleIDOrigins(identity: URL(string: "https://idmsa.appleid.test")!, connect: URL(string: "https://tax.appleid.test")!), signedInAt: "2026-10-31T00:00:00.000Z")
        try await session.routeAppleWeb(web) { Self.configuration() }
        let client = AppStoreConnectClient(token: try AppleToken(account: account, privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation), origin: URL(string: "https://tax-api.appstoreconnect.test")!, configuration: Self.configuration())
        func prepare(_ choice: TaxCategoryChoice) async throws -> PublishReview {
            var request = PublishRequest(accountId: account.id, appId: app, scope: .taxCategory); request.taxCategory = choice
            return try await session.preparePublishing(account: account, request: request, client: client)
        }
        func approve(_ review: PublishReview) async throws -> String {
            try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: client).state
        }
        let start = try await session.taxCategoryState(account: account, appId: app)
        #expect(!start.configured && start.label == "Default · App Store software")
        #expect(start.catalog.top.map(\.id) == ["C001", "C002"] && start.catalog.selectable("C001") && !start.catalog.selectable("C002") && start.catalog.conditions(for: "C003") == ["T2", "T1"])
        #expect(try await session.sectionChecks(accountId: account.id, appId: app)[.tax]?.answered == true)

        // A category whose subcategory is required, a condition it does not offer and a request with other changes are refused before any write.
        await #expect(throws: PublishFailure.self) { try await prepare(.init(category: "C002")) }
        await #expect(throws: PublishFailure.self) { try await prepare(.init(category: "C001", conditions: ["T1"])) }
        var mixed = PublishRequest(accountId: account.id, appId: app, scope: .appPrivacy); mixed.taxCategory = .init(category: "C001")
        await #expect(throws: PublishFailure.self) { try await session.preparePublishing(account: account, request: mixed, client: client) }

        let create = try await prepare(.init(category: "C003", conditions: ["T1"]))
        #expect(create.steps.map(\.method) == ["POST"] && apple.writes.isEmpty)
        #expect(try await approve(create) == "complete")
        let saved = try await session.taxCategoryState(account: account, appId: app)
        #expect(saved.configured && saved.category == "C003" && saved.conditions == ["T1"] && saved.label == "Synthetic Category · Synthetic Subcategory")
        #expect(try await prepare(.init(category: "C003", conditions: ["T1"])).steps.isEmpty)

        // A choice approved after the category changed at Apple sends nothing.
        let change = try await prepare(.init(category: "C001"))
        #expect(change.steps.map(\.method) == ["PATCH"])
        apple.lock.withLock { apple.taxConditions = [] }
        let writes = apple.writes.count
        await #expect(throws: PublishFailure.conflict) { try await approve(change) }
        #expect(apple.writes.count == writes)
        let fresh = try await prepare(.init(category: "C001"))
        #expect(try await approve(fresh) == "complete")
        let after = try await session.taxCategoryState(account: account, appId: app)
        #expect(after.category == "C001" && after.conditions.isEmpty && apple.writes.map(\.0) == ["POST", "PATCH"])
    }
    @Test func theSignInServiceSavesThePasswordOnlyAfterAppleAcceptsItAndKeepsTheSessionAfterTheCode() async throws {
        let fixture = try await AccountLifecycleTests().fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let session = fixture.session, id = fixture.account.id, apple = SyntheticAppleID()
        let origins = AppleIDOrigins(identity: URL(string: "https://idmsa.appleid.test")!, connect: URL(string: "https://connect.appleid.test")!)
        StubProtocol.handle("idmsa.appleid.test") { apple.handle($0) }; StubProtocol.handle("connect.appleid.test") { apple.handle($0) }
        await #expect(throws: AppleIDFailure.rejected) {
            try await session.signInAppleID("tester@example.com", password: "not the password", savePassword: true, accountId: id, writer: fixture.writer, origins: origins, configuration: Self.configuration())
        }
        #expect(try await session.savedAppleIDPassword(accountId: id, writer: fixture.writer) == nil)
        let step = try await session.signInAppleID("tester@example.com", password: apple.password, savePassword: true, accountId: id, writer: fixture.writer, origins: origins, configuration: Self.configuration())
        guard case .verify(let pending) = step else { Issue.record("Expected a two-factor step."); return }
        #expect(pending.codeLength == 6 && pending.deviceCode && pending.phones.map(\.id) == [1])
        #expect(try await session.savedAppleIDPassword(accountId: id, writer: fixture.writer)?.password == apple.password)
        #expect(try await session.appleIDAccount(accountId: id, writer: fixture.writer) == nil)
        let account = try await session.verifyAppleID(pending, code: apple.code, phone: nil, writer: fixture.writer)
        #expect(account.appleId == "tester@example.com" && !account.teams.isEmpty)
        #expect(try await session.appleIDAccount(accountId: id, writer: fixture.writer) == account)
    }

    @Test func aSavedPasswordStaysInTheKeychainItemOnlyAndIsRemovedWhenTurnedOff() async throws {
        let fixture = try await AccountLifecycleTests().fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let session = fixture.session, id = fixture.account.id, secret = "synthetic password 7f3a"
        #expect(try await session.savedAppleIDPassword(accountId: id, writer: fixture.writer) == nil)
        await #expect(throws: AppleIDFailure.rejected) { try await session.saveAppleIDPassword("", appleId: "tester@example.com", accountId: id, writer: fixture.writer) }
        try await session.saveAppleIDPassword(secret, appleId: "tester@example.com", accountId: id, writer: fixture.writer)
        let saved = try #require(try await session.savedAppleIDPassword(accountId: id, writer: fixture.writer))
        #expect(saved.appleId == "tester@example.com" && saved.password == secret)
        // No file in the workspace holds the password; only the Keychain item does.
        let files = FileManager.default.enumerator(at: fixture.root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        #expect(files.allSatisfy { (try? Data(contentsOf: $0)).map { $0.range(of: Data(secret.utf8)) == nil } ?? true })
        try await session.saveAppleIDPassword(nil, appleId: "tester@example.com", accountId: id, writer: fixture.writer)
        #expect(try await session.savedAppleIDPassword(accountId: id, writer: fixture.writer) == nil)
    }

    @Test func aBackupLeavesTheAppleIDSessionAndSavedPasswordOutSoARestoreAsksToSignInAgain() async throws {
        let fixture = try await AccountLifecycleTests().fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        chmod(fixture.root.path, 0o700)
        let session = fixture.session, id = fixture.account.id
        let web = AppleWebSession(appleId: "tester@example.com", teams: [.init(id: "12345", name: "Synthetic Team")], cookies: [.init(name: "myacinfo", value: "synthetic-backup-cookie", domain: "backup.appleid.test", path: "/", expires: nil, secure: true)],
                                  origins: AppleIDOrigins(identity: URL(string: "https://idmsa.appleid.test")!, connect: URL(string: "https://backup.appleid.test")!), signedInAt: "2026-11-04T00:00:00.000Z")
        try await session.saveAppleIDSession(web, accountId: id, writer: fixture.writer)
        try await session.saveAppleIDPassword("synthetic backup password", appleId: "tester@example.com", accountId: id, writer: fixture.writer)
        let parent = (try TestIsolation.require()).appendingPathComponent("storebench-appleid-backups-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: parent) }
        let backup = parent.appendingPathComponent("backup"), restored = parent.appendingPathComponent("restored")
        _ = try await session.createBackup(destination: backup, password: BackupTests.passphrase)
        let writer = VaultWriter(dataRoot: parent, storage: MemoryVaultStorage())
        _ = try Backups.restore(backup, to: restored, password: BackupTests.passphrase, writer: writer)
        // Only the restored database key record reaches the credential storage; the Apple ID entries stay with the original workspace.
        #expect(try writer.read().entries.keys.sorted() == [CredentialVault.databaseEntry(root: restored)])
        let reopened = try WorkspaceSession(workspace: Workspace(root: restored), vault: try writer.read(), password: BackupTests.passphrase)
        #expect(try await reopened.accounts().map(\.id) == [id])
        #expect(try await reopened.appleIDSession(accountId: id) == nil)
        #expect(try await session.appleIDSession(accountId: id, writer: fixture.writer)?.appleId == "tester@example.com")
    }

    @Test func withPasswordStorageTheSessionAndSavedPasswordStayEncryptedInItsVaultAndKeychainIsNotUsed() async throws {
        let fixture = try await AccountLifecycleTests().fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let storage = PasswordVaultStorage(dataRoot: fixture.root); try storage.create(password: "synthetic-password-storage")
        let writer = VaultWriter(dataRoot: fixture.root, storage: storage), entries = try fixture.writer.read().entries
        _ = try writer.update { for (key, value) in entries { $0[key] = value } }
        let session = try WorkspaceSession(workspace: Workspace(root: fixture.root), vault: try writer.read(), credentialWriter: writer)
        let id = fixture.account.id, secret = "synthetic password 2c9e", cookie = "synthetic-cookie-5b1d", keychain = fixture.storage.counts
        let web = AppleWebSession(appleId: "tester@example.com", teams: [.init(id: "12345", name: "Synthetic Team")], cookies: [.init(name: "myacinfo", value: cookie, domain: "storage.appleid.test", path: "/", expires: nil, secure: true)],
                                  origins: AppleIDOrigins(identity: URL(string: "https://idmsa.appleid.test")!, connect: URL(string: "https://storage.appleid.test")!), signedInAt: "2026-11-04T00:00:00.000Z")
        try await session.saveAppleIDSession(web, accountId: id, writer: writer)
        try await session.saveAppleIDPassword(secret, appleId: "tester@example.com", accountId: id, writer: writer)
        #expect(try await session.appleIDSession(accountId: id, writer: writer)?.appleId == "tester@example.com")
        #expect(try await session.savedAppleIDPassword(accountId: id, writer: writer)?.password == secret)
        // Both entries are in the password-protected vault, encrypted; the Keychain stand-in is neither read nor written.
        #expect(try writer.read().entries.keys.contains { $0.hasPrefix("appleid:") } && writer.read().entries.keys.contains { $0.hasPrefix("appleidpassword:") })
        #expect(fixture.storage.counts.reads == keychain.reads && fixture.storage.counts.writes == keychain.writes)
        let files = FileManager.default.enumerator(at: fixture.root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        #expect(files.contains(storage.url))
        #expect(files.allSatisfy { (try? Data(contentsOf: $0)).map { $0.range(of: Data(secret.utf8)) == nil && $0.range(of: Data(cookie.utf8)) == nil } ?? true })
        try await session.signOutAppleID(accountId: id, writer: writer)
        try await session.saveAppleIDPassword(nil, appleId: "tester@example.com", accountId: id, writer: writer)
        #expect(try await session.appleIDSession(accountId: id, writer: writer) == nil)
        #expect(try await session.savedAppleIDPassword(accountId: id, writer: writer) == nil)
    }
}
