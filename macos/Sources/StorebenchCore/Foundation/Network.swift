import Foundation

/// Guarded test runs (`STOREBENCH_TEST_MODE=1`) may only reach synthetic doubles: any session without a registered
/// test protocol gets one that refuses every request, so a missed injection fails closed instead of reaching a real service.
enum Network {
    static var testMode: Bool { ProcessInfo.processInfo.environment["STOREBENCH_TEST_MODE"] == "1" }

    static func guarded(_ configuration: URLSessionConfiguration) -> URLSessionConfiguration {
        guard testMode else { return configuration }
        guard (try? TestIsolation.require()) != nil else { configuration.protocolClasses = [RefusedRequest.self]; return configuration }
        let classes = configuration.protocolClasses ?? []
        if !classes.contains(where: { String(describing: $0).hasSuffix("StubProtocol") }) { configuration.protocolClasses = [RefusedRequest.self] }
        return configuration
    }
}

final class RefusedRequest: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
