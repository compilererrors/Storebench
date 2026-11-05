import CryptoKit
import Foundation
import Testing
@testable import StorebenchCore

/// A synthetic App Store Connect: requests never leave the process.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    // Each test uses its own synthetic host, so parallel suites never share answers.
    nonisolated(unsafe) static var handlers: [String: (URLRequest) -> (Int, [String: String], Data)] = [:]
    nonisolated(unsafe) static var log: [String: [URLRequest]] = [:]
    static let lock = NSLock()
    static func handle(_ host: String, _ handler: @escaping (URLRequest) -> (Int, [String: String], Data)) { lock.withLock { handlers[host] = handler; log[host] = [] } }
    static func requests(_ host: String) -> [URLRequest] { lock.withLock { log[host] ?? [] } }
    /// A request's body: URLSession hands a protocol the body as a stream, not as `httpBody`.
    static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
        return data
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let host = request.url?.host ?? "", handler = Self.lock.withLock { Self.log[host, default: []].append(request); return Self.handlers[host] }
        let (status, headers, body) = handler?(request) ?? (501, [:], Data())
        // A negative status is a URLError code, such as -1001 for a connection that timed out.
        if status < 0 { client?.urlProtocol(self, didFailWithError: URLError(URLError.Code(rawValue: status))); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct AppStoreConnectTests {
    init() throws { _ = try TestIsolation.require() }
    let origin = URL(string: "https://client.appstoreconnect.test")!
    let key = P256.Signing.PrivateKey()
    var team: Account { Account(id: "synthetic-account", name: "Example Studio", keyId: "SAMPLE0001", keyType: "team", issuerId: "00000000-0000-4000-8000-000000000003", appIds: ["1000000001"], appNames: nil) }

    func client() throws -> AppStoreConnectClient {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubProtocol.self]
        return AppStoreConnectClient(token: try AppleToken(account: team, privateKeyPEM: key.pemRepresentation), origin: origin, configuration: configuration)
    }

    func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    @Test func tokensContainExpectedClaimsAndVerify() throws {
        let token = try AppleToken(account: team, privateKeyPEM: key.pemRepresentation).signed(issuedAt: Date(timeIntervalSince1970: 1_000))
        let parts = token.split(separator: ".").map(String.init)
        let decode = { (part: String) -> Data in Data(base64Encoded: part.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - part.count % 4) % 4))! }
        let header = try JSONSerialization.jsonObject(with: decode(parts[0])) as! [String: Any], claims = try JSONSerialization.jsonObject(with: decode(parts[1])) as! [String: Any]
        #expect(header["alg"] as? String == "ES256" && header["kid"] as? String == "SAMPLE0001")
        #expect(claims["iss"] as? String == "00000000-0000-4000-8000-000000000003" && claims["aud"] as? String == "appstoreconnect-v1")
        #expect(claims["exp"] as? Int == 1_000 + 900 && claims["sub"] == nil)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: decode(parts[2]))
        #expect(key.publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)))
        let individual = Account(id: "synthetic-personal", name: "Me", keyId: "SAMPLE0002", keyType: "individual", issuerId: nil, appIds: [], appNames: nil)
        let personal = try AppleToken(account: individual, privateKeyPEM: key.pemRepresentation).signed().split(separator: ".").map(String.init)
        let personalClaims = try JSONSerialization.jsonObject(with: decode(personal[1])) as! [String: Any]
        #expect(personalClaims["sub"] as? String == "user" && personalClaims["iss"] == nil)
    }

    @Test func listsFollowApplesCursorAndRetryTemporaryAnswers() async throws {
        let client = try client()
        var calls = 0
        StubProtocol.handle("client.appstoreconnect.test") { request in
            calls += 1
            if calls == 1 { return (503, ["Retry-After": "0"], Data()) }
            let cursor = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems?.first { $0.name == "cursor" }?.value
            return cursor == nil
                ? (200, [:], json(["data": [["type": "apps", "id": "1000000001", "attributes": ["name": "Sample App"]]], "links": ["next": "https://client.appstoreconnect.test/v1/apps?limit=1&cursor=Ag"]]))
                : (200, [:], json(["data": [["type": "apps", "id": "1000000002", "attributes": ["name": "Second App"]]], "links": [:]]))
        }
        let apps = try await client.list("/v1/apps?limit=1")
        #expect(apps.map(\.id) == ["1000000001", "1000000002"])
        #expect(apps[0].attributes?["name"]?.string == "Sample App")
        #expect(StubProtocol.requests("client.appstoreconnect.test").count == 3)
        #expect(StubProtocol.requests("client.appstoreconnect.test").allSatisfy { $0.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true })
    }

    @Test func readsAreSentAgainWhenTheConnectionStallsOrDrops() async throws {
        let client = try client()
        var calls = 0
        StubProtocol.handle("client.appstoreconnect.test") { _ in
            calls += 1
            if calls == 1 { return (URLError.Code.timedOut.rawValue, [:], Data()) }
            if calls == 2 { return (URLError.Code.networkConnectionLost.rawValue, [:], Data()) }
            return (200, [:], json(["data": [["type": "apps", "id": "1000000001", "attributes": ["name": "Sample App"]]], "links": [:]]))
        }
        #expect(try await client.list("/v1/apps").map(\.id) == ["1000000001"])
        let sent = StubProtocol.requests("client.appstoreconnect.test")
        #expect(sent.count == 3)
        #expect(sent.map(\.timeoutInterval) == [12, 30, 30])
        StubProtocol.handle("client.appstoreconnect.test") { _ in (URLError.Code.timedOut.rawValue, [:], Data()) }
        await #expect(throws: URLError.self) { try await client.list("/v1/apps") }
        #expect(StubProtocol.requests("client.appstoreconnect.test").count == 3)
        #expect(!AppStoreConnectClient.retriesConnection(URLError(.notConnectedToInternet), attempt: 0))
        #expect(!AppStoreConnectClient.retriesConnection(AppStoreConnectClient.Failure.status(500), attempt: 0))
        #expect(!AppStoreConnectClient.retriesConnection(URLError(.timedOut), attempt: 2))
    }

    @Test func refusesForeignPaginationAndFailedStatuses() async throws {
        let client = try client()
        StubProtocol.handle("client.appstoreconnect.test") { _ in (200, [:], json(["data": [], "links": ["next": "https://example.invalid/v1/apps?cursor=Ag"]])) }
        await #expect(throws: AppStoreConnectClient.Failure.invalidPagination) { try await client.list("/v1/apps") }
        StubProtocol.handle("client.appstoreconnect.test") { _ in (401, [:], Data()) }
        await #expect(throws: AppStoreConnectClient.Failure.status(401)) { try await client.get("/v1/apps/1000000001") }
        await #expect(throws: AppStoreConnectClient.Failure.invalidPath) { try await client.get("https://example.invalid/v1/apps") }
    }
}
