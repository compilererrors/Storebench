import Foundation

public struct TestFlightBuild: Identifiable, Sendable, Equatable, Codable {
    public let id, version, platform, appVersion, processingState, uploadedDate, expirationDate, audience: String
    public let expired: Bool?, usesNonExemptEncryption: Bool?
    public let externalState, internalState, betaReviewState: String?
    public var autoNotifyEnabled: Bool? = nil
    public var canSetAutomaticNotification: Bool { processed && audience == "APP_STORE_ELIGIBLE" && autoNotifyEnabled != nil && ["READY_FOR_BETA_SUBMISSION", "WAITING_FOR_BETA_REVIEW", "IN_BETA_REVIEW"].contains(externalState ?? "") }
    public var canNotifyTesters: Bool { processed && audience == "APP_STORE_ELIGIBLE" && autoNotifyEnabled == false && externalState == "READY_FOR_BETA_TESTING" }

    public var reviewObservation: TestFlightObservation.ReviewState = .unknown
    public var exportState: TestFlightObservation.ExportState = .unknown
    public var preReleaseVersionId: String? = nil
    public var otherBuildInBetaReview = false
    public var betaDetailConfirmed = false
    public var rejected: Bool { betaReviewState == "REJECTED" || externalState == "BETA_REJECTED" }
    public var canManage: Bool { expired == false && !rejected }
    public var canCheckBetaReview: Bool { processed && audience == "APP_STORE_ELIGIBLE" && !rejected
        && [.noNonexempt, .approved].contains(exportState) && reviewObservation != .known && preReleaseVersionId != nil && !otherBuildInBetaReview }
    public var canSubmitForBetaReview: Bool { canCheckBetaReview && reviewObservation == .none && externalState == "READY_FOR_BETA_SUBMISSION" && autoNotifyEnabled != nil }
    public var betaReviewDescription: String {
        let status = reviewObservation == .known ? (betaReviewState ?? "").lowercased().replacingOccurrences(of: "_", with: " ") : reviewObservation == .none ? "Not submitted" : "Status unavailable"
        let reason = rejected ? " · Upload a new build to continue testing" : otherBuildInBetaReview ? " · Another build of this version is in beta review" : processed && audience == "APP_STORE_ELIGIBLE" && preReleaseVersionId == nil ? " · Build version unavailable at Apple" : processed && audience == "APP_STORE_ELIGIBLE" && reviewObservation != .known && (externalState != "READY_FOR_BETA_SUBMISSION" || autoNotifyEnabled == nil) ? " · Beta review readiness needs confirmation" : ""
        return "Beta App Review: " + status + reason
    }

    public var title: String { "Build \(version)\(appVersion.isEmpty ? "" : " · \(Releases.platformName(platform)) \(appVersion)")" }
    public var processed: Bool { processingState == "VALID" && expired == false }
    /// App Store Connect shows Missing Compliance until the build's encryption question is answered.
    public var missingCompliance: Bool {
        processed && (betaDetailConfirmed ? [externalState, internalState].contains("MISSING_EXPORT_COMPLIANCE") : usesNonExemptEncryption == nil)
    }
}

public struct TestFlightGroup: Identifiable, Sendable, Equatable, Codable {
    public let id, name: String
    public let internalGroup: Bool?, feedbackEnabled: Bool?, publicLinkEnabled: Bool?, hasAccessToAllBuilds: Bool?
    public let publicLink: String?
    /// Apple's tester limit for the public link; nil when the limit is off or unknown.
    public var publicLinkLimit: Int? = nil
}

public struct TestFlightTester: Identifiable, Sendable, Equatable, Codable {
    public let id, email, name, state: String
    public var inviteType: String? = nil
    public var canSendInvitation: Bool { TestFlightAppTesters.canSendInvitation(email: email, inviteType: inviteType, state: state) }
}

extension WorkspaceSession {
    static func processedUnexpired(_ build: AppStoreConnectClient.Resource) -> Bool {
        build.type == "builds" && build.attributes?["processingState"]?.string == "VALID" && build.attributes?["expired"] == .bool(false)
    }

    static func encryptionUseDigest(_ value: JSONValue?) throws -> String {
        switch value {
        case .bool(true)?: return Apple.sha("yes")
        case .bool(false)?: return Apple.sha("no")
        case nil, .null?: return Apple.sha("unanswered")
        default: throw PublishFailure.invalid("Apple did not confirm this build's encryption answer.")
        }
    }

    /// Build and group lists may carry only a link to their app; the owner is confirmed before use.
    func scopedOwners(_ items: [AppStoreConnectClient.Resource], type: String, appId: String, list: (String) async throws -> [AppStoreConnectClient.Resource]) async throws -> [AppStoreConnectClient.Resource] {
        guard !appId.isEmpty, items.allSatisfy({ $0.type == type && !TextSemantics.trim($0.id).isEmpty }), Set(items.map { Data($0.id.utf8) }).count == items.count else { throw PublishFailure.invalid("Apple returned unexpected TestFlight resources.") }
        var result: [AppStoreConnectClient.Resource] = []
        for item in items {
            if Planner.resource(item)["relationships"]?["app"]?["data"] != nil {
                guard Apple.owned(item, "app", "apps", appId) else { throw PublishFailure.invalid("Apple returned TestFlight resources outside the selected app.") }
            } else {
                let owners = try await list("/v1/\(type)/\(TextSemantics.pathComponent(item.id))/relationships/app")
                guard owners.count == 1, owners[0].type == "apps", owners[0].id == appId else { throw PublishFailure.invalid("Apple did not confirm this TestFlight resource belongs to the selected app.") }
            }
            var relationships = item.relationships ?? [:]
            relationships["app"] = .object(["data": .object(["type": .string("apps"), "id": .string(appId)])])
            result.append(AppStoreConnectClient.Resource(type: item.type, id: item.id, attributes: item.attributes, relationships: relationships))
        }
        return result
    }

    func appBuilds(appId: String, client: AppStoreConnectClient, planner: Planner? = nil) async throws -> [AppStoreConnectClient.Resource] {
        let list = { (path: String) in planner != nil ? try await planner!.list(path) : try await client.list(path) }
        return try await scopedOwners(try await list("/v1/apps/\(appId)/builds?limit=200"), type: "builds", appId: appId, list: list)
    }

    /// One build with its app and pre-release version linked, in one read. Apple's build list under the app sends only links,
    /// which would cost a read per build to confirm its owner and leave its platform unknown.
    func appBuild(appId: String, buildId: String?, client: AppStoreConnectClient, planner: Planner? = nil) async throws -> AppStoreConnectClient.Resource? {
        guard let buildId, buildId.range(of: "^[A-Za-z0-9_-]{1,256}$", options: .regularExpression) != nil, appId.range(of: #"^\d+$"#, options: .regularExpression) != nil else { return nil }
        let path = "/v1/builds?filter%5Bapp%5D=\(appId)&filter%5Bid%5D=\(buildId)&include=app%2CpreReleaseVersion&limit=200"
        let list = { (path: String) in planner != nil ? try await planner!.list(path) : try await client.list(path) }
        let page = planner != nil ? try await planner!.listWithIncluded(path) : try await client.listWithIncluded(path)
        return try await scopedOwners(page.data, type: "builds", appId: appId, list: list).first { $0.id == buildId }
    }

    /// Apple's owner linkage comes with the page, so ownership needs no read per group.
    func appGroups(appId: String, client: AppStoreConnectClient, planner: Planner? = nil) async throws -> [AppStoreConnectClient.Resource] {
        let list = { (path: String) in planner != nil ? try await planner!.list(path) : try await client.list(path) }
        return try await scopedOwners(try await list("/v1/betaGroups?filter%5Bapp%5D=\(appId)&include=app&limit=200"), type: "betaGroups", appId: appId, list: list)
    }

    /// The app's builds, newest upload first, with versions and beta states from Apple's included resources.
    public func testFlightBuilds(appId: String, client: AppStoreConnectClient) async throws -> [TestFlightBuild] {
        try requireFeedbackScope(appId: appId, client: client)
        let page = try await client.listWithIncluded("/v1/builds?filter%5Bapp%5D=\(appId)&include=app%2CpreReleaseVersion%2CbetaAppReviewSubmission%2CbuildBetaDetail&limit=200")
        let builds = try await scopedOwners(page.data, type: "builds", appId: appId) { try await client.list($0) }
        let declarations = try? await WorkspaceSession.declarationReads(appId) { try await client.list($0) }
        let result = try TestFlightObservation.models(appId: appId, builds: builds, included: page.included, declarations: declarations)
        try requireFeedbackScope(appId: appId, client: client)
        return result
    }

    public func testFlightGroups(appId: String, client: AppStoreConnectClient) async throws -> [TestFlightGroup] {
        try requireFeedbackScope(appId: appId, client: client)
        let groups = try await appGroups(appId: appId, client: client)
        for group in groups { try TestFlightGroups.validate(group) }
        let result = groups.map { group in
            func flag(_ name: String) -> Bool? { if case .bool(let value)? = group.attributes?[name] { return value }; return nil }
            return TestFlightGroup(id: group.id, name: group.attributes?["name"]?.string ?? "Unnamed group", internalGroup: flag("isInternalGroup"), feedbackEnabled: flag("feedbackEnabled"),
                                   publicLinkEnabled: flag("publicLinkEnabled"), hasAccessToAllBuilds: flag("hasAccessToAllBuilds"), publicLink: group.attributes?["publicLink"]?.string,
                                   publicLinkLimit: flag("publicLinkLimitEnabled") == true ? group.attributes?["publicLinkLimit"].flatMap { if case .number(let value) = $0, value.isFinite, value.rounded() == value, (1...10_000).contains(value) { return Int(value) }; return nil } : nil)
        }
        try requireFeedbackScope(appId: appId, client: client)
        return result
    }

    public func groupMembers(appId: String, groupId: String, client: AppStoreConnectClient) async throws -> (builds: [String], testers: [TestFlightTester]) {
        try requireFeedbackScope(appId: appId, client: client)
        guard let group = try await appGroups(appId: appId, client: client).first(where: { TextSemantics.same($0.id, groupId) }) else { throw PublishFailure.invalid("This group does not belong to the selected app.") }
        try TestFlightGroups.validate(group)
        let values = try await scopedGroupMembers(appId: appId, groupId: groupId, client: client)
        let builds = values.builds.map(\.id)
        let testers = values.testers.map { tester in
            TestFlightTester(id: tester.id, email: tester.attributes?["email"]?.string ?? "Tester", name: [tester.attributes?["firstName"]?.string, tester.attributes?["lastName"]?.string].compactMap { $0 }.joined(separator: " "), state: tester.attributes?["state"]?.string ?? "")
        }
        try requireFeedbackScope(appId: appId, client: client)
        return (builds, testers)
    }

    /// TestFlight reviews: export compliance answer, group build access and build expiry.
    func planTestFlight(_ planner: Planner) async throws -> String {
        if ["upload-build", "delete-build-upload", "delete-failed-upload"].contains(planner.request.testflightAction ?? "") { return try await planBuildDelivery(planner) }
        if let title = try await planMoreTestFlight(planner) { return title }
        let request = planner.request, client = planner.client
        guard let build = try await appBuild(appId: request.appId, buildId: request.buildId, client: client, planner: planner) else { throw PublishFailure.invalid("Choose a build belonging to this app.") }
        let name = "build \(build.attributes?["version"]?.string ?? build.id)"
        switch request.testflightAction {
        case "set-encryption-use":
            guard Self.processedUnexpired(build) else { throw PublishFailure.invalid("Choose a processed, unexpired build for export compliance.") }
            guard let answer = request.usesNonExemptEncryption else { throw PublishFailure.invalid("Explicitly answer whether this build uses non-exempt encryption.") }
            let old = build.attributes?["usesNonExemptEncryption"]
            let digest = try Self.encryptionUseDigest(old)
            if old != .bool(answer) {
                let before: String
                if case .bool(let value)? = old { before = value ? "Uses non-exempt encryption: Yes" : "Uses non-exempt encryption: No" } else { before = "No answer at Apple" }
                planner.add(.api, method: "PATCH", path: [.string("builds"), .string(build.id)], label: "Set build encryption use", detail: "\(name.capitalized) · Export compliance classification", before: before,
                            after: "Uses non-exempt encryption: \(answer ? "Yes" : "No")", body: .object([("data", .object([("type", .string("builds")), ("id", .string(build.id)), ("attributes", .object([("usesNonExemptEncryption", .bool(answer))]))]))]),
                            guard: .object([("kind", .string("build-encryption-use")), ("digest", .string(digest))]))
            }
            planner.notes.append("Choose this answer based on your app's actual encryption use and Apple's export compliance guidance. A non-exempt build may also need an approved declaration and documentation.")
            return "Export compliance answer · \(name)"
        default: throw PublishFailure.invalid("Choose a TestFlight action.")
        }
    }
}
