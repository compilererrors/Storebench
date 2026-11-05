import Foundation

/// The TestFlight reads screens make, with the account's shared read client. A read that a refresh elsewhere cancelled is read again.
extension WorkspaceSession {
    private func testFlightRead<T>(_ account: Account, _ read: (AppStoreConnectClient) async throws -> T) async throws -> T {
        let client = try readClient(for: account)
        return try await AppStoreReadCache.rereadingAfterInvalidation { try await read(client) }
    }

    /// The testers given this build individually, and every tester of the app to choose from.
    public func individualBuildAccess(account: Account, appId: String, buildId: String) async throws -> (assigned: [TestFlightTester], testers: [TestFlightTester]) {
        try await testFlightRead(account) { client in
            async let assigned = individualBuildTesters(appId: appId, buildId: buildId, client: client)
            async let testers = allTesters(appId: appId, client: client)
            return try await (assigned, testers)
        }
    }
    public func testFlightGroups(account: Account, appId: String) async throws -> [TestFlightGroup] {
        try await testFlightRead(account) { try await testFlightGroups(appId: appId, client: $0) }
    }
    public func groupMembers(account: Account, appId: String, groupId: String) async throws -> (builds: [String], testers: [TestFlightTester]) {
        try await testFlightRead(account) { try await groupMembers(appId: appId, groupId: groupId, client: $0) }
    }
    public func allTesters(account: Account, appId: String) async throws -> [TestFlightTester] {
        try await testFlightRead(account) { try await allTesters(appId: appId, client: $0) }
    }
    public func testFlightAppInformation(account: Account, appId: String) async throws -> [TestFlightLocalization] {
        try await testFlightRead(account) { try await testFlightAppInformation(appId: appId, client: $0) }
    }
    public func testFlightBetaLicense(account: Account, appId: String) async throws -> String? {
        try await testFlightRead(account) { try await testFlightBetaLicense(appId: appId, client: $0) }
    }
    public func testFlightMetrics(account: Account, appId: String, buildId: String) async throws -> TestFlightMetrics {
        try await testFlightRead(account) { try await testFlightMetrics(appId: appId, buildId: buildId, client: $0) }
    }
}
