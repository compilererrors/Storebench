import CryptoKit
import Foundation
import Testing
@testable import StorebenchCore

/// Sends synthetic chunks incrementally so the test proves cancellation during reading, rather than after buffering.
final class FeedbackStreamStubProtocol: URLProtocol, @unchecked Sendable {
    private let stateLock = NSLock()
    private var stopped = false
    static let lock = NSLock()
    nonisolated(unsafe) static var sent: [String: Int] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let host = request.url!.host!
        Self.lock.withLock { Self.sent[host] = 0 }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png", "Content-Length": "8"])!, cacheStoragePolicy: .notAllowed)
        emit(0)
    }
    private func emit(_ index: Int) {
        guard !stateLock.withLock({ stopped }) else { return }
        if index == 32 { client?.urlProtocolDidFinishLoading(self); return }
        Self.lock.withLock { Self.sent[request.url!.host!, default: 0] += 1 }
        var data = Data(repeating: 7, count: 1_000_000)
        if index == 0 { data.replaceSubrange(0..<8, with: [137, 80, 78, 71, 13, 10, 26, 10]) }
        client?.urlProtocol(self, didLoad: data)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.01) { self.emit(index + 1) }
    }
    override func stopLoading() { stateLock.withLock { stopped = true } }
}

@Suite(.serialized) struct TestFlightFeedbackTests {
    init() throws { _ = try TestIsolation.require() }
    let app = "1000000001"
    func vector() throws -> JSONText { try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/testflight-feedback.json"))) }
    func client(_ account: Account, host: String, streaming: Bool = false, additionalHeaders: [String: String]? = nil) throws -> AppStoreConnectClient {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [streaming ? FeedbackStreamStubProtocol.self : StubProtocol.self]
        configuration.httpAdditionalHeaders = additionalHeaders
        return AppStoreConnectClient(token: try AppleToken(account: account, privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation), origin: URL(string: "https://\(host)")!, configuration: configuration)
    }
    func json(_ data: Any, next: String? = nil) -> Data { try! JSONSerialization.data(withJSONObject: ["data": data, "links": next.map { ["next": $0] } ?? [:]]) }
    func resource(_ type: String = "betaFeedbackScreenshotSubmissions", id: String = "feedback-synthetic", build: String = "build-synthetic", attributes: [String: Any] = [:]) -> [String: Any] {
        ["type": type, "id": id, "attributes": attributes, "relationships": ["build": ["data": ["type": "builds", "id": build]]]]
    }

    @Test func imageSelectionAndBuildLinkageMatchWebFixtures() throws {
        let value = try vector(), input = try JSONDecoder().decode(JSONValue.self, from: #require(value["input"]).data)
        guard case .number(let instant)? = value["now"] else { throw TestFlightFeedback.Failure.page }
        #expect(JSONText.array(TestFlightFeedback.images(input, now: Date(timeIntervalSince1970: instant)).map(\.json)) == value["images"])
        let resources = try JSONDecoder().decode([AppStoreConnectClient.Resource].self, from: #require(value["resources"]).data)
        #expect(JSONText.array(resources.map { TestFlightFeedback.buildId($0).map(JSONText.string) ?? .null }) == value["buildIds"])
        #expect(try TestFlightFeedback.submissions([resources[0]], kind: .screenshot).first?.comment == "Synthetic feedback å🎉")
        #expect(try TestFlightFeedback.submissions([resources[1]], kind: .crash).first?.comment == "No written crash comment.")
        #expect(throws: TestFlightFeedback.Failure.page) { try TestFlightFeedback.submissions([resources[0], resources[0]], kind: .screenshot) }
        #expect(throws: TestFlightFeedback.Failure.page) { try TestFlightFeedback.submissions([resources[1]], kind: .screenshot) }
        #expect(throws: TestFlightFeedback.Failure.page) { try TestFlightFeedback.submissions(Array(repeating: resources[0], count: 11), kind: .screenshot) }
        for value in ["", "../feedback", String(repeating: "a", count: 129), "feedback?app=other", "feedback\n"] { #expect(!TestFlightFeedback.validID(value)) }
    }

    @Test func pagesPinQueriesValidateOwnersAndKeepIndependentKinds() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), host = "feedback-pages.appstoreconnect.test", client = try client(account, host: host)
        StubProtocol.handle(host) { request in
            #expect(request.httpMethod == "GET")
            if request.url!.path == "/v1/builds/build-synthetic/app" { return (200, [:], json(["type": "apps", "id": app])) }
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            #expect(query.first { $0.name == "limit" }?.value == "10" && query.first { $0.name == "sort" }?.value == "-createdDate")
            if request.url!.path.hasSuffix("betaFeedbackCrashSubmissions") { return (403, [:], Data()) }
            if query.contains(where: { $0.name == "cursor" }) { return (200, [:], json([])) }
            return (200, [:], json([resource()], next: "?cursor=older&sort=-createdDate&limit=10"))
        }
        let first = try await session.testFlightFeedback(appId: app, kind: .screenshot, client: client)
        #expect(first.submissions.map(\.id) == ["feedback-synthetic"] && first.next == "older")
        let older = try await session.testFlightFeedback(appId: app, kind: .screenshot, cursor: first.next, client: client)
        #expect(older.submissions.isEmpty && older.next == nil)
        await #expect(throws: AppStoreConnectClient.Failure.status(403)) { try await session.testFlightFeedback(appId: app, kind: .crash, client: client) }
        for cursor in ["", "\n", String(repeating: "a", count: 2049)] {
            await #expect(throws: AppStoreConnectClient.Failure.invalidPagination) { try await session.testFlightFeedback(appId: app, kind: .screenshot, cursor: cursor, client: client) }
        }
        #expect(StubProtocol.requests(host).allSatisfy { $0.httpMethod == "GET" })
    }

    @Test func foreignUnlinkedDuplicateAndEmptyCursorPagesAreRefused() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), host = "feedback-guards.appstoreconnect.test", client = try client(account, host: host)
        StubProtocol.handle(host) { request in request.url!.path.hasSuffix("/app") ? (200, [:], json(["type": "apps", "id": "999"])) : (200, [:], json([resource()])) }
        await #expect(throws: TestFlightFeedback.Failure.ownership) { try await session.testFlightFeedback(appId: app, kind: .screenshot, client: client) }
        await #expect(throws: TestFlightFeedback.Failure.selection) { try await session.testFlightFeedback(appId: "999", kind: .screenshot, client: client) }
        StubProtocol.handle(host) { _ in (200, [:], json([resource(), resource()])) }
        await #expect(throws: TestFlightFeedback.Failure.page) { try await session.testFlightFeedback(appId: app, kind: .screenshot, client: client) }
        StubProtocol.handle(host) { _ in (200, [:], json([["type": "betaFeedbackScreenshotSubmissions", "id": "unlinked", "attributes": [:]]])) }
        await #expect(throws: TestFlightFeedback.Failure.page) { try await session.testFlightFeedback(appId: app, kind: .screenshot, client: client) }
        StubProtocol.handle(host) { _ in (200, [:], json([], next: "?cursor=older")) }
        await #expect(throws: AppStoreConnectClient.Failure.invalidPagination) { try await session.testFlightFeedback(appId: app, kind: .screenshot, client: client) }
        let initial = URLComponents(string: "/v1/apps/\(app)/betaFeedbackScreenshotSubmissions?limit=10&sort=-createdDate")!
        for next in ["https://example.invalid\(initial.string!)&cursor=older", "?limit=200&cursor=older", "?cursor=older&cursor=other", "?cursor=%0A", "?cursor=current", "?cursor=older#changed"] {
            #expect(throws: AppStoreConnectClient.Failure.invalidPagination) { try client.nextCursor(next, initial: initial, current: "current") }
        }
    }

    @Test func privateImagesAndCrashLogsRecheckScopeWithoutSendingAPITokensToCDN() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), host = "feedback-files.appstoreconnect.test", client = try client(account, host: host, additionalHeaders: ["Authorization": "synthetic inherited header", "Cookie": "synthetic inherited cookie"])
        let png = Data([137, 80, 78, 71, 13, 10, 26, 10]) + Data("synthetic image bytes".utf8)
        StubProtocol.handle(host) { request in
            #expect(request.httpMethod == "GET")
            switch request.url!.path {
            case "/v1/builds/build-synthetic/app": return (200, [:], json(["type": "apps", "id": app]))
            case "/v1/betaFeedbackScreenshotSubmissions/feedback-synthetic": return (200, [:], json(resource(attributes: ["screenshots": [["url": "https://feedback-synthetic.mzstatic.com/image"]]])))
            case "/v1/betaFeedbackCrashSubmissions/crash-synthetic": return (200, [:], json(resource("betaFeedbackCrashSubmissions", id: "crash-synthetic")))
            case "/v1/betaFeedbackCrashSubmissions/crash-synthetic/crashLog": return (200, [:], json(["type": "betaCrashLogs", "id": "log-synthetic", "attributes": ["logText": "Synthetic crash log\n"]]))
            default: return (404, [:], Data())
            }
        }
        StubProtocol.handle("feedback-synthetic.mzstatic.com") { request in
            #expect(request.httpMethod == "GET" && request.value(forHTTPHeaderField: "Authorization") == nil && request.value(forHTTPHeaderField: "Cookie") == nil)
            return (200, ["Content-Type": "IMAGE/PNG; charset=binary"], png)
        }
        let image = try await session.testFlightFeedbackImage(appId: app, submissionId: "feedback-synthetic", index: 0, client: client)
        #expect(image.bytes == png && image.contentType == "image/png")
        #expect(try await session.testFlightCrashLog(appId: app, submissionId: "crash-synthetic", client: client) == Data("Synthetic crash log\n".utf8))
        await #expect(throws: TestFlightFeedback.Failure.selection) { try await session.testFlightFeedbackImage(appId: app, submissionId: "feedback-synthetic", index: 10, client: client) }
        StubProtocol.handle("feedback-synthetic.mzstatic.com") { _ in (200, ["Content-Type": "image/jpeg"], png) }
        await #expect(throws: TestFlightFeedback.Failure.image) { try await session.testFlightFeedbackImage(appId: app, submissionId: "feedback-synthetic", index: 0, client: client) }
        StubProtocol.handle("feedback-synthetic.mzstatic.com") { _ in (200, ["Content-Type": "text/plain"], png) }
        await #expect(throws: TestFlightFeedback.Failure.image) { try await session.testFlightFeedbackImage(appId: app, submissionId: "feedback-synthetic", index: 0, client: client) }
        #expect(StubProtocol.requests(host).allSatisfy { $0.httpMethod == "GET" })
    }

    @Test func expiredImagesInvalidLogsAndChangedCredentialsCannotBeReused() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), host = "feedback-expiry.appstoreconnect.test", client = try client(account, host: host)
        StubProtocol.handle(host) { request in
            if request.url!.path.hasSuffix("/app") { return (200, [:], json(["type": "apps", "id": app])) }
            if request.url!.path.hasSuffix("/crashLog") { return (200, [:], json(["type": "betaCrashLogs", "id": "log", "attributes": ["logText": "\u{FEFF} \n"]])) }
            if request.url!.path.contains("Crash") { return (200, [:], json(resource("betaFeedbackCrashSubmissions", id: "crash-synthetic"))) }
            return (200, [:], json(resource(attributes: ["screenshots": [["url": "https://feedback-expired.mzstatic.com/image", "expirationDate": "2000-01-01T00:00:00Z"]]])))
        }
        await #expect(throws: TestFlightFeedback.Failure.unavailable) { try await session.testFlightFeedbackImage(appId: app, submissionId: "feedback-synthetic", index: 0, client: client) }
        await #expect(throws: TestFlightFeedback.Failure.log) { try await session.testFlightCrashLog(appId: app, submissionId: "crash-synthetic", client: client) }
        var foreign = account; foreign = Account(id: foreign.id, name: foreign.name, keyId: "SAMPLE0009", keyType: foreign.keyType, issuerId: foreign.issuerId, appIds: foreign.appIds, appNames: nil)
        let changed = try self.client(foreign, host: host)
        let count = StubProtocol.requests(host).count
        await #expect(throws: PublishFailure.self) { try await session.testFlightFeedback(appId: app, kind: .screenshot, client: changed) }
        #expect(StubProtocol.requests(host).count == count)
    }

    @Test func incomingByteLimitCancelsAResponseWithFalseContentLength() async throws {
        let host = "feedback-stream.mzstatic.com", config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FeedbackStreamStubProtocol.self]
        let request = URLRequest(url: URL(string: "https://\(host)/synthetic")!)
        await #expect(throws: BoundedResponse.Failure.tooLarge) { try await BoundedResponse.read(request, configuration: config, maximumBytes: 10_000_000) }
        #expect(FeedbackStreamStubProtocol.lock.withLock { FeedbackStreamStubProtocol.sent[host, default: 0] } < 32)
        let apiHost = "feedback-stream-api.appstoreconnect.test", (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), client = try client(account, host: apiHost, streaming: true)
        await #expect(throws: BoundedResponse.Failure.tooLarge) { try await client.get("/v1/apps/\(app)") }
        #expect(FeedbackStreamStubProtocol.lock.withLock { FeedbackStreamStubProtocol.sent[apiHost, default: 0] } < 32)
    }

    @Test func mixedBuildOwnersInvalidateTheWholeFeedbackPage() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), host = "feedback-mixed.appstoreconnect.test", client = try client(account, host: host)
        StubProtocol.handle(host) { request in
            if request.url!.path.hasSuffix("/app") { return (200, [:], json(["type": "apps", "id": request.url!.path.contains("build-foreign") ? "999" : app])) }
            return (200, [:], json([resource(id: "feedback-first", build: "build-owned"), resource(id: "feedback-second", build: "build-owned"), resource(id: "feedback-foreign", build: "build-foreign")]))
        }
        await #expect(throws: TestFlightFeedback.Failure.ownership) { try await session.testFlightFeedback(appId: app, kind: .screenshot, client: client) }
        let validHost = "feedback-valid-mixed.appstoreconnect.test", validClient = try self.client(account, host: validHost)
        StubProtocol.handle(validHost) { request in
            if request.url!.path.hasSuffix("/app") { return (200, [:], json(["type": "apps", "id": app])) }
            return (200, [:], json([resource(id: "feedback-first", build: "build-owned"), resource(id: "feedback-second", build: "build-owned"), resource(id: "feedback-third", build: "build-other")]))
        }
        #expect(try await session.testFlightFeedback(appId: app, kind: .screenshot, client: validClient).submissions.count == 3)
        let reads = StubProtocol.requests(validHost)
        #expect(reads.filter { $0.url!.path == "/v1/builds/build-owned/app" }.count == 1)
        #expect(reads.filter { $0.url!.path == "/v1/builds/build-other/app" }.count == 1)
        #expect(reads.allSatisfy { $0.httpMethod == "GET" })
    }
}
