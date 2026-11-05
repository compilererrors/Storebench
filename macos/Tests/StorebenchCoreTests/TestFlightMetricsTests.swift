import CryptoKit
import Foundation
import Testing
@testable import StorebenchCore

@Suite struct TestFlightMetricsTests {
    init() throws { _ = try TestIsolation.require() }
    @Test func metricsMatchSyntheticReferenceResultsAndMissingCountsStayUnknown() throws {
        let file = try TestIsolation.require().appendingPathComponent("native-fixtures/testflight-metrics.json"), vector = try JSONText.parse(Data(contentsOf: file))
        let source = try #require(vector["source"]), page = try TestFlightMetrics.parse(source)
        let rows = page.metrics.points.map { point in JSONText.object([("series", .number(Double(point.series))), ("start", .string(point.start)), ("end", .string(point.end)),
            ("values", .object(TestFlightMetrics.names.map { ($0, point.values[$0].map(JSONText.number) ?? .null) }))]) }
        #expect(JSONText.array(rows) == vector["expected"]?["points"])
        #expect(page.metrics.seriesCount == 1 && page.next == nil)
        #expect(page.metrics.points[0].values["inviteCount"] == 0 && page.metrics.points[0].values["crashCount"] == nil)
        let invalidCounts: [JSONText] = [.null, .number(-1), .number(1.5), .string("3"), .number(9_007_199_254_740_992)]
        for count in invalidCounts {
            let row = JSONText.object([("start", .string("2026-01-01")), ("end", .string("2026-01-02")), ("values", .object([("crashCount", count)]))])
            let value = JSONText.object([("data", .array([.object([("dataPoints", .array([row]))])])), ("links", .object([]))])
            #expect(throws: AppStoreConnectClient.Failure.unreadableResponse) { try TestFlightMetrics.parse(value) }
        }
    }

    @Test func metricReadsValidateAccountOwnershipAndPagination() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first)
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubProtocol.self]
        StubProtocol.handle("metrics.appstoreconnect.test") { request in
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            if request.url!.path == "/v1/builds/build-1" {
                return (200, [:], Data(#"{"data":{"type":"builds","id":"build-1","relationships":{"app":{"data":{"type":"apps","id":"1000000001"}}}}}"#.utf8))
            }
            #expect(request.url!.path == "/v1/builds/build-1/metrics/betaBuildUsages")
            if request.url!.query?.contains("cursor=second") == true {
                return (200, [:], Data(#"{"data":[{"dataPoints":[{"start":"2026-02-01","end":"2026-02-02","values":{"installCount":3}}]}],"links":{}}"#.utf8))
            }
            return (200, [:], Data(#"{"data":[{"dataPoints":[{"start":"2026-01-01","end":"2026-01-02","values":{"installCount":0}}]}],"links":{"next":"https://metrics.appstoreconnect.test/v1/builds/build-1/metrics/betaBuildUsages?limit=200&cursor=second"}}"#.utf8))
        }
        let client = AppStoreConnectClient(token: try AppleToken(account: account, privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation), origin: URL(string: "https://metrics.appstoreconnect.test")!, configuration: configuration)
        let metrics = try await session.testFlightMetrics(appId: "1000000001", buildId: "build-1", client: client)
        #expect(metrics.seriesCount == 2 && metrics.points.map(\.series) == [2, 1])
        #expect(metrics.points.map { $0.values["installCount"] } == [3, 0])
        await #expect(throws: PublishFailure.self) { try await session.testFlightMetrics(appId: "999", buildId: "build-1", client: client) }
        StubProtocol.handle("foreign-metrics.appstoreconnect.test") { request in
            #expect(request.url!.path == "/v1/builds/build-1")
            return (200, [:], Data(#"{"data":{"type":"builds","id":"build-1","relationships":{"app":{"data":{"type":"apps","id":"999"}}}}}"#.utf8))
        }
        let foreignConfiguration = URLSessionConfiguration.ephemeral; foreignConfiguration.protocolClasses = [StubProtocol.self]
        let foreign = AppStoreConnectClient(token: try AppleToken(account: account, privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation), origin: URL(string: "https://foreign-metrics.appstoreconnect.test")!, configuration: foreignConfiguration)
        await #expect(throws: PublishFailure.self) { try await session.testFlightMetrics(appId: "1000000001", buildId: "build-1", client: foreign) }
        #expect(throws: AppStoreConnectClient.Failure.invalidPagination) {
            try client.nextCursor("https://example.invalid/v1/builds/build-1/metrics/betaBuildUsages?limit=200&cursor=second", initial: URLComponents(string: "/v1/builds/build-1/metrics/betaBuildUsages?limit=200")!, current: nil)
        }
    }
}
