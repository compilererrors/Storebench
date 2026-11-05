import Foundation

/// The complete Apple prerequisites approved for one external beta submission.
public enum TestFlightBetaReview {
    public typealias Resource = AppStoreConnectClient.Resource
    public struct Readiness: Sendable { public let digest: String; public let autoNotifyEnabled: Bool }

    static func releaseID(_ build: Resource) throws -> String {
        guard let release = Apple.owner(build, "preReleaseVersion"), release.type == "preReleaseVersions", !release.id.isEmpty else {
            throw PublishFailure.invalid("Apple did not identify this build's TestFlight version.")
        }
        return release.id
    }
    static func submissions(_ items: [Resource], buildId: String) throws {
        guard items.allSatisfy({ $0.type == "betaAppReviewSubmissions" && Apple.within($0, "build", "builds", buildId) }) else {
            throw PublishFailure.invalid("Apple returned beta review submissions outside the selected build.")
        }
    }
    public static func readiness(appId: String, build: Resource, betaDetails: [Resource], declarations: [Resource], versions: [Resource], localizations: [Resource], reviewDetails: [Resource]) throws -> Readiness {
        guard WorkspaceSession.processedUnexpired(build), Apple.owned(build, "app", "apps", appId), build.attributes?["buildAudienceType"]?.string == "APP_STORE_ELIGIBLE" else {
            throw PublishFailure.invalid("Choose a processed, unexpired, App Store eligible build for beta review.")
        }
        guard case .bool(let encryption)? = build.attributes?["usesNonExemptEncryption"] else { throw PublishFailure.invalid("Answer the build's encryption question before submitting it for beta review.") }
        guard betaDetails.count == 1, let detail = betaDetails.first, detail.type == "buildBetaDetails", !detail.id.isEmpty else { throw PublishFailure.invalid("Apple did not confirm this build's beta testing state.") }
        if detail.relationships?["build"] != nil {
            guard Apple.owned(detail, "build", "builds", build.id) else { throw PublishFailure.invalid("Apple returned beta details outside the selected build.") }
        }
        if let linked = Planner.resource(build)["relationships"]?["buildBetaDetail"]?["data"] {
            guard linked["type"]?.text == "buildBetaDetails", TextSemantics.same(linked["id"]?.text, detail.id) else { throw PublishFailure.invalid("Apple returned inconsistent beta details for this build.") }
        }
        guard detail.attributes?["externalBuildState"]?.string == "READY_FOR_BETA_SUBMISSION", case .bool(let automatic)? = detail.attributes?["autoNotifyEnabled"] else {
            throw PublishFailure.invalid("Apple must confirm this build is ready for beta review and its automatic tester notification setting. Refresh TestFlight.")
        }
        let release = try releaseID(build)
        var declaration: Resource?
        if encryption {
            guard let linked = Apple.owner(build, "appEncryptionDeclaration"), linked.type == "appEncryptionDeclarations",
                  let approved = try WorkspaceSession.scopedDeclarations(declarations, appId: appId).first(where: { TextSemantics.same($0.id, linked.id) && $0.attributes?["appEncryptionDeclarationState"]?.string == "APPROVED" }) else {
                throw PublishFailure.invalid("Assign an approved encryption declaration belonging to this app before beta review.")
            }
            guard versions.count == 1, versions[0].type == "preReleaseVersions", TextSemantics.same(versions[0].id, release), let platform = versions[0].attributes?["platform"]?.string,
                  TestFlightEncryption.declarationFits(approved.attributes?["platform"]?.string, platform: platform) else {
                throw PublishFailure.invalid("The approved encryption declaration no longer matches this build's platform.")
            }
            declaration = approved
        }
        guard !localizations.isEmpty, localizations.allSatisfy({ $0.type == "betaAppLocalizations" && !$0.id.isEmpty && Apple.owned($0, "app", "apps", appId)
            && !TextSemantics.trim($0.attributes?["locale"]?.string ?? "").isEmpty && !TextSemantics.trim($0.attributes?["description"]?.string ?? "").isEmpty }),
              Set(localizations.map { Data($0.id.utf8) }).count == localizations.count,
              Set(localizations.map { Data(($0.attributes?["locale"]?.string ?? "").utf8) }).count == localizations.count else {
            throw PublishFailure.invalid("Every unique, app-owned TestFlight language needs a description before beta review.")
        }
        guard reviewDetails.count == 1, let reviewDetail = reviewDetails.first, reviewDetail.type == "betaAppReviewDetails", !reviewDetail.id.isEmpty, Apple.owned(reviewDetail, "app", "apps", appId) else {
            throw PublishFailure.invalid("Save complete TestFlight beta review contact and demo access details at Apple before submitting this build.")
        }
        let review = try ReviewInformation(Planner.resource(reviewDetail)["attributes"]).validated()
        func attribute(_ item: Resource, _ key: String) -> JSONText { TestFlightAccess.attribute(item, key) }
        let languages = localizations.map { item in
            let row = JSONText.array([.string(item.id)] + ["locale", "description", "feedbackEmail", "marketingUrl", "privacyPolicyUrl", "tvOsPrivacyPolicy"].map { attribute(item, $0) })
            return (row: row, sortKey: row.stringify())
        }
        let sorted = TestFlightAudience.ordered(languages, id: { $0.sortKey }).map(\.row)
        let snapshot = JSONText.object([
            ("build", .array([.string(build.id)] + ["version", "processingState", "expired", "buildAudienceType", "usesNonExemptEncryption"].map { attribute(build, $0) } + [.string(release)])),
            ("betaDetail", .array([.string(detail.id), attribute(detail, "externalBuildState"), .bool(automatic)])),
            ("declaration", declaration.map { .array([.string($0.id), attribute($0, "platform"), attribute($0, "appEncryptionDeclarationState")]) } ?? .null),
            ("localizations", .array(sorted)), ("details", .array([.string(reviewDetail.id), review.json]))])
        return Readiness(digest: snapshot.sha256, autoNotifyEnabled: automatic)
    }
    public static func assertNoActiveReview(appId: String, selected: Resource, active: [Resource]) throws {
        let release = try releaseID(selected)
        guard active.allSatisfy({ $0.type == "builds" && !TextSemantics.trim($0.id).isEmpty && Apple.owned($0, "app", "apps", appId) }), Set(active.map { Data($0.id.utf8) }).count == active.count else {
            throw PublishFailure.invalid("Apple returned unexpected in-review builds.")
        }
        for build in active {
            guard !TextSemantics.same(try releaseID(build), release) else { throw PublishFailure.invalid("A build of this TestFlight version is already in beta review. Wait for Apple's decision before submitting another build.") }
        }
    }
}

extension WorkspaceSession {
    func betaSubmissionReadiness(appId: String, build: AppStoreConnectClient.Resource, client: AppStoreConnectClient, planner: Planner? = nil) async throws -> TestFlightBetaReview.Readiness {
        let list = { (path: String) in planner != nil ? try await planner!.list(path) : try await client.list(path) }
        let get = { (path: String) in planner != nil ? try await planner!.get(path) : try await client.get(path) }
        let details = try await get("/v1/builds/\(TextSemantics.pathComponent(build.id))/buildBetaDetail")
        var declarations: [AppStoreConnectClient.Resource] = [], versions: [AppStoreConnectClient.Resource] = []
        if build.attributes?["usesNonExemptEncryption"] == .bool(true) {
            declarations = try await WorkspaceSession.declarationReads(appId) { try await list($0) }
            versions = try await get("/v1/preReleaseVersions/\(TextSemantics.pathComponent(try TestFlightBetaReview.releaseID(build)))")
        }
        let locales = try await betaLocalizations(ownerId: appId, type: "betaAppLocalizations", client: client, planner: planner)
        let review = try await betaReviewDetail(appId: appId, client: client, planner: planner)
        return try TestFlightBetaReview.readiness(appId: appId, build: build, betaDetails: details, declarations: declarations, versions: versions, localizations: locales, reviewDetails: review.map { [$0] } ?? [])
    }
    func assertNoActiveBetaReview(appId: String, selected: AppStoreConnectClient.Resource, client: AppStoreConnectClient, planner: Planner? = nil) async throws {
        let list = { (path: String) in planner != nil ? try await planner!.list(path) : try await client.list(path) }
        for state in ["WAITING_FOR_REVIEW", "IN_REVIEW"] {
            var query = URLComponents(); query.queryItems = [URLQueryItem(name: "filter[app]", value: appId), URLQueryItem(name: "filter[betaAppReviewSubmission.betaReviewState]", value: state), URLQueryItem(name: "limit", value: "200")]
            let active = try await scopedOwners(list("/v1/builds?\(query.percentEncodedQuery!)"), type: "builds", appId: appId, list: list)
            try TestFlightBetaReview.assertNoActiveReview(appId: appId, selected: selected, active: active)
        }
    }
    func planBetaSubmission(_ planner: Planner) async throws -> String? {
        let request = planner.request
        guard request.testflightAction == "submit-beta-review" else { return nil }
        guard let build = try await appBuilds(appId: request.appId, client: planner.client, planner: planner).first(where: { $0.id == request.buildId }) else { throw PublishFailure.invalid("Choose a build belonging to this app.") }
        let name = "build \(build.attributes?["version"]?.string ?? build.id)", title = "Submit \(name) for beta review"
        let submissions = try await planner.list("/v1/betaAppReviewSubmissions?filter%5Bbuild%5D=\(TextSemantics.pathComponent(build.id))&limit=200")
        try TestFlightBetaReview.submissions(submissions, buildId: build.id)
        if let existing = submissions.first {
            planner.notes.append("Apple already has a beta review submission for this build: \((existing.attributes?["betaReviewState"]?.string ?? "status unavailable").replacingOccurrences(of: "_", with: " ").lowercased()).")
            return title
        }
        let ready = try await betaSubmissionReadiness(appId: request.appId, build: build, client: planner.client, planner: planner)
        try await assertNoActiveBetaReview(appId: request.appId, selected: build, client: planner.client, planner: planner)
        planner.add(.api, method: "POST", path: [.string("betaAppReviewSubmissions")], label: "Submit build to TestFlight App Review", detail: "\(name.capitalizedFirst) · Automatic tester notification: \(ready.autoNotifyEnabled ? "On" : "Off") · Apple decides whether external testing is approved",
                    before: "No beta review submission", after: "Submitted to Apple for beta review",
                    body: .object([("data", .object([("type", .string("betaAppReviewSubmissions")), ("relationships", .object([("build", Apple.relationship("builds", .string(build.id)))]))]))]),
                    guard: .object([("kind", .string("beta-review-final")), ("digest", .string(ready.digest))]))
        planner.notes.append("Apple checks beta review information and export compliance when the request is sent. Approval and tester distribution are decided by Apple.")
        return title
    }
    func verifyBetaSubmission(method: String, parts: [String], body: JSONText?, guardValue: JSONText?, appId: String, client: AppStoreConnectClient) async throws {
        func keys(_ value: JSONText?, _ expected: Set<String>) -> Bool { guard case .object(let fields)? = value else { return false }; return fields.count == expected.count && Set(fields.map(\.0)) == expected }
        guard method == "POST", parts == ["betaAppReviewSubmissions"], keys(body, ["data"]), keys(body?["data"], ["type", "relationships"]), body?["data"]?["type"]?.text == "betaAppReviewSubmissions",
              keys(body?["data"]?["relationships"], ["build"]), let id = body?["data"]?["relationships"]?["build"]?["data"]?["id"]?.text, !id.isEmpty,
              body?["data"]?["relationships"]?["build"] == Apple.relationship("builds", .string(id)), keys(guardValue, ["kind", "digest"]), guardValue?["kind"]?.text == "beta-review-final",
              let digest = guardValue?["digest"]?.text, digest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw PublishFailure.write("Unsupported TestFlight beta review submission.") }
        guard let build = try await appBuilds(appId: appId, client: client).first(where: { TextSemantics.same($0.id, id) }) else { throw PublishFailure.write("TestFlight build no longer belongs to this app.") }
        let submissions = try await client.list("/v1/betaAppReviewSubmissions?filter%5Bbuild%5D=\(TextSemantics.pathComponent(id))&limit=200")
        try TestFlightBetaReview.submissions(submissions, buildId: id)
        guard submissions.isEmpty, try await betaSubmissionReadiness(appId: appId, build: build, client: client).digest == digest else { throw PublishFailure.write("TestFlight beta review prerequisites changed after approval. Prepare a new review.") }
        try await assertNoActiveBetaReview(appId: appId, selected: build, client: client)
    }
}
