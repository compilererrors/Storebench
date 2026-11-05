import Foundation

/// TestFlight changes beyond builds: groups, testers, invitations, beta review, notices and tester information.
/// Each step's guard names the Apple state it was planned against; the write check reads that state again.
public enum TestFlightActions {
    public static let buildLocales = ["da", "de-DE", "el", "en-AU", "en-CA", "en-GB", "en-US", "es-ES", "es-MX", "fi", "fr-CA", "fr-FR", "id", "it", "ja", "ko", "ms", "nl-NL", "no",
                                      "pt-BR", "pt-PT", "ru", "sv", "th", "tr", "vi", "zh-Hans", "zh-Hant"]
    static let groupActions: Set<String> = ["create-group", "rename-group", "set-group-setting", "delete-group", "invite-tester", "add-tester", "remove-tester"]
    static let all: Set<String> = groupActions.union(["set-encryption-use", "add-build", "remove-build", "expire-build", "submit-beta-review", "notify-build-testers", "save-build-notes",
                                                      "save-beta-info", "save-beta-license", "send-invitation", "remove-app-tester", "upload-build", "delete-build-upload", "delete-failed-upload", "assign-individual-tester", "remove-individual-tester", "invite-individual-tester", "set-auto-notify", "save-beta-review-details", "assign-encryption-declaration"])
}

/// TestFlight test information for one language: what testers see and where their feedback goes.
public struct TestFlightLocalization: Sendable, Equatable, Codable {
    public let locale, description, feedbackEmail, marketingUrl, privacyPolicyUrl, tvOsPrivacyPolicy: String
    public init(locale: String, description: String, feedbackEmail: String, marketingUrl: String = "", privacyPolicyUrl: String = "", tvOsPrivacyPolicy: String = "") {
        self.locale = locale; self.description = description; self.feedbackEmail = feedbackEmail
        self.marketingUrl = marketingUrl; self.privacyPolicyUrl = privacyPolicyUrl; self.tvOsPrivacyPolicy = tvOsPrivacyPolicy
    }
}

extension WorkspaceSession {
    /// The app's TestFlight test information per language and its beta license agreement.
    public func testFlightInformation(appId: String, client: AppStoreConnectClient) async throws -> (localizations: [TestFlightLocalization], license: String?) {
        let items = try await testFlightAppInformation(appId: appId, client: client)
        return (items, try await testFlightBetaLicense(appId: appId, client: client))
    }

    /// What to Test for one build, by language.
    public func whatToTest(appId: String, buildId: String, client: AppStoreConnectClient) async throws -> [String: String] {
        try requireFeedbackScope(appId: appId, client: client)
        guard try await appBuilds(appId: appId, client: client).contains(where: { $0.id == buildId }) else { throw PublishFailure.invalid("Choose a build belonging to this app.") }
        let items = try await betaLocalizations(ownerId: buildId, type: "betaBuildLocalizations", client: client)
        var result: [String: String] = [:]
        for item in items {
            guard let locale = item.attributes?["locale"]?.string else { throw PublishFailure.invalid("Apple did not confirm the current TestFlight language.") }
            _ = try TestFlightMetadata.notesDigest(buildId: buildId, locale: locale, resources: items)
            result[locale] = try TestFlightMetadata.string(item, "whatsNew")
        }
        try requireFeedbackScope(appId: appId, client: client)
        return result
    }

    /// Everyone testing this app through TestFlight, by email.
    public func allTesters(appId: String, client: AppStoreConnectClient) async throws -> [TestFlightTester] {
        try requireFeedbackScope(appId: appId, client: client)
        let items = try await appTesters(appId: appId, client: client)
        try requireFeedbackScope(appId: appId, client: client)
        return items.map(TestFlightAppTesters.model).sorted { $0.email.lowercased() < $1.email.lowercased() }
    }

    static func linkages(_ type: String, _ id: String) -> JSONText { .object([("data", .array([.object([("type", .string(type)), ("id", .string(id))])]))]) }

    func appTesters(appId: String, client: AppStoreConnectClient, planner: Planner? = nil) async throws -> [AppStoreConnectClient.Resource] {
        let items = planner != nil ? try await planner!.list("/v1/betaTesters?filter%5Bapps%5D=\(appId)&limit=200") : try await client.list("/v1/betaTesters?filter%5Bapps%5D=\(appId)&limit=200")
        return try await scopedTesters(items, appId: appId) { path in planner != nil ? try await planner!.list(path) : try await client.list(path) }
    }

    /// Plans the TestFlight actions that are not about a single build's export compliance or group access.
    func planMoreTestFlight(_ planner: Planner) async throws -> String? {
        if planner.request.testflightAction == "save-beta-review-details" { return try await planBetaReviewInformation(planner) }
        if planner.request.testflightAction == "assign-encryption-declaration" { return try await planBuildDeclaration(planner) }
        if let title = try await planBuildAccess(planner) { return title }
        if let title = try await planTestFlightContent(planner) { return title }
        if let title = try await planBuildAudience(planner) { return title }
        if let title = try await planTestFlightGroup(planner) { return title }
        if let title = try await planAppTesterChange(planner) { return title }
        return try await planBetaSubmission(planner)
    }
}
