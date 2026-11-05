import Foundation
import Testing
@testable import StorebenchCore

/// Views request only what they show, and owner checks come with the page instead of one request per item.
@Suite(.serialized) struct ViewReadPlanTests {
    init() throws { _ = try TestIsolation.require() }
    private let appId = "1000000001"
    /// Like Apple, the synthetic answer carries a resource's app linkage only when the request includes `app`.
    static func linkingOnlyWhenIncluded(_ request: URLRequest, _ response: (Int, [String: String], Data)) -> (Int, [String: String], Data) {
        let include = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "include" }?.value ?? ""
        guard !include.split(separator: ",").contains("app"), var object = try? JSONSerialization.jsonObject(with: response.2) as? [String: Any], var rows = object["data"] as? [[String: Any]] else { return response }
        for index in rows.indices { if var relations = rows[index]["relationships"] as? [String: Any] { relations["app"] = ["links": ["related": "synthetic"]]; rows[index]["relationships"] = relations } }
        object["data"] = rows
        return (response.0, response.1, (try? JSONSerialization.data(withJSONObject: object)) ?? response.2)
    }
    @Test func appInformationReadsOnlyTheCardsAViewShows() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first)
        let availability: Set<String> = ["/v1/apps/1000000001/appAvailabilityV2"]
        let categories: Set<String> = ["/v1/apps/1000000001", "/v1/apps/1000000001/appInfos", "/v1/appInfos/info-1", "/v1/appCategories", "/v1/apps/1000000001/appStoreVersions"]
        for (showCategories, showAvailability) in [(true, true), (true, false), (false, true)] {
            let apple = SyntheticApple(), host = "view-reads-information-\(showCategories)-\(showAvailability).appstoreconnect.test"
            StubProtocol.handle(host) { apple.handle($0) }
            let state = try await session.appInformationState(appId: appId, categories: showCategories, availability: showAvailability, client: PublishingTests().client(account, host: host))
            let paths = Set(StubProtocol.requests(host).map { $0.url!.path }.filter { !$0.hasPrefix("/v2/appAvailabilities/") })
            #expect(paths == (showCategories ? categories : []).union(showAvailability ? availability : []), "\(paths.sorted())")
            #expect(StubProtocol.requests(host).contains { $0.url!.path.hasPrefix("/v2/appAvailabilities/") } == showAvailability)
            #expect((state.categories != nil) == showCategories && state.territories.isEmpty == !showAvailability && state.categoryError == nil && state.availabilityError == nil)
            #expect(apple.writes.isEmpty)
        }
    }
    @Test func testFlightBuildsAndGroupsGetTheirOwnerWithThePage() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "view-reads-testflight-owner.appstoreconnect.test"
        StubProtocol.handle(host) { request in Self.linkingOnlyWhenIncluded(request, apple.handle(request)) }
        let client = try PublishingTests().client(account, host: host)
        #expect(try await session.testFlightBuilds(appId: appId, client: client).map(\.id) == ["build-7"])
        #expect(try await session.testFlightGroups(appId: appId, client: client).map(\.id) == ["group-1"])
        _ = try await session.publishingWorkspace(account: account, appId: appId, includeBuilds: true, client: client)
        let requests = StubProtocol.requests(host).map { $0.url!.path }
        #expect(!requests.contains { $0.hasSuffix("/relationships/app") }, "\(requests)")
        #expect(apple.writes.isEmpty)
    }
}
