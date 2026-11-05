import Foundation
import Testing
@testable import StorebenchCore

/// An owned synthetic Apple response that pauses one approved write without blocking its task.
final class SessionPublishStubProtocol: URLProtocol, @unchecked Sendable {
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var responses: [String: (SyntheticApple, AnalyticsJobDelayStubProtocol.Gate)] = [:]
    static func register(_ host: String, apple: SyntheticApple, gate: AnalyticsJobDelayStubProtocol.Gate) throws {
        _ = try TestIsolation.require()
        registryLock.withLock { responses[host] = (apple, gate) }
    }
    private let stateLock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { registryLock.withLock { responses[request.url?.host ?? ""] != nil } }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let response = Self.registryLock.withLock({ Self.responses[request.url?.host ?? ""] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return
        }
        let deliver: @Sendable () -> Void = { [weak self] in
            guard let self, self.stateLock.withLock({ !self.stopped }) else { return }
            let result = response.0.handle(self.request)
            self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url: self.request.url!, statusCode: result.0, httpVersion: nil, headerFields: result.1)!, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: result.2); self.client?.urlProtocolDidFinishLoading(self)
        }
        if request.httpMethod == "PATCH", request.url?.path == "/v1/appStoreVersions/version-1" { response.1.add(deliver) }
        else { deliver() }
    }
    override func stopLoading() { stateLock.withLock { stopped = true } }
}
