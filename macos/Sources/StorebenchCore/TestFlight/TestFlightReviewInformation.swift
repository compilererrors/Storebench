import Foundation

/// App-scoped beta review details, saved encrypted until the user approves a Publish review.
public struct TestFlightReviewInformationDraft: Equatable, Sendable {
    public let fields: ReviewInformation
    public let revision: Int
}

extension ReviewInformation {
    /// Apple's field order is also the publishing guard's digest contract.
    var appleJSON: JSONText {
        .object([("contactFirstName", .string(contactFirstName)), ("contactLastName", .string(contactLastName)), ("contactPhone", .string(contactPhone)), ("contactEmail", .string(contactEmail)),
                 ("demoAccountRequired", .bool(demoAccountRequired)), ("demoAccountName", .string(demoAccountName)), ("demoAccountPassword", .string(demoAccountPassword)), ("notes", .string(notes))])
    }
    static func savedBetaFields(_ value: JSONText) throws -> ReviewInformation {
        guard case .object = value, limits.allSatisfy({ value[$0.0]?.text != nil }), case .bool? = value["demoAccountRequired"] else { throw PublishFailure.invalid("Saved TestFlight review information is invalid.") }
        return try ReviewInformation(value).validated()
    }
}

extension WorkspaceSession {
    func betaReviewDraftKey(_ accountId: String, _ appId: String) throws -> String {
        guard accountId.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil, appId.range(of: #"^\d+$"#, options: .regularExpression) != nil else { throw PublishFailure.invalid("Invalid TestFlight review identity.") }
        return "\(accountId):\(appId)"
    }
    public func testFlightReviewInformationDraft(accountId: String, appId: String) throws -> TestFlightReviewInformationDraft {
        let key = try betaReviewDraftKey(accountId, appId)
        return try storeAccess { store in
            guard let document = try store.document(namespace: "testflight_review_information_drafts", key: key) else { return TestFlightReviewInformationDraft(fields: ReviewInformation(), revision: 0) }
            return TestFlightReviewInformationDraft(fields: try ReviewInformation.savedBetaFields(JSONText.parse(document.payload)), revision: document.revision)
        }
    }
    public func saveTestFlightReviewInformationDraft(accountId: String, appId: String, fields: ReviewInformation, expectedRevision: Int) throws -> TestFlightReviewInformationDraft {
        let key = try betaReviewDraftKey(accountId, appId), checked = try fields.validated()
        guard expectedRevision >= 0, expectedRevision <= 9_007_199_254_740_991 else { throw PublishFailure.invalid("Reload the TestFlight review form before saving.") }
        return try storeAccess { store in
            try FileMutex.withLock(store.directory.appendingPathComponent("testflight_review_info_\(Apple.sha(key).prefix(40)).mutex")) {
                let current = try store.document(namespace: "testflight_review_information_drafts", key: key)
                guard (current?.revision ?? 0) == expectedRevision else { throw PublishFailure.invalid("TestFlight review information changed in another window. Reload and compare before saving.") }
                try store.transaction { latest in
                    guard try latest("testflight_review_information_drafts", key)?.revision == current?.revision else { throw PublishFailure.conflict }
                    return [.put(namespace: "testflight_review_information_drafts", key: key, json: checked.json.data)]
                }
                guard let saved = try store.document(namespace: "testflight_review_information_drafts", key: key) else { throw PublishFailure.conflict }
                return TestFlightReviewInformationDraft(fields: checked, revision: saved.revision)
            }
        }
    }
    func betaReviewDetail(appId: String, client: AppStoreConnectClient, planner: Planner? = nil) async throws -> AppStoreConnectClient.Resource? {
        let values = planner != nil ? try await planner!.get("/v1/apps/\(appId)/betaAppReviewDetail") : try await client.get("/v1/apps/\(appId)/betaAppReviewDetail")
        guard values.count <= 1 else { throw PublishFailure.invalid("Apple returned ambiguous beta review information for this app.") }
        guard let detail = values.first else { return nil }
        guard detail.type == "betaAppReviewDetails", detail.id.range(of: "^[A-Za-z0-9_-]{1,256}$", options: .regularExpression) != nil else { throw PublishFailure.invalid("Apple returned beta review information outside the selected app.") }
        if Planner.resource(detail)["relationships"]?["app"]?["data"] != nil {
            guard Apple.owned(detail, "app", "apps", appId) else { throw PublishFailure.invalid("Apple returned beta review information outside the selected app.") }
            return detail
        }
        let path = "/v1/betaAppReviewDetails/\(detail.id)/relationships/app", owners = planner != nil ? try await planner!.list(path) : try await client.list(path)
        guard owners.count == 1, owners[0].type == "apps", owners[0].id == appId else { throw PublishFailure.invalid("Apple did not confirm beta review information belongs to the selected app.") }
        var relationships = detail.relationships ?? [:]; relationships["app"] = .object(["data": .object(["type": .string("apps"), "id": .string(appId)])])
        return AppStoreConnectClient.Resource(type: detail.type, id: detail.id, attributes: detail.attributes, relationships: relationships)
    }
    public func testFlightReviewInformationFromApple(appId: String, client: AppStoreConnectClient) async throws -> ReviewInformation? {
        try requireFeedbackScope(appId: appId, client: client)
        let detail = try await betaReviewDetail(appId: appId, client: client)
        try requireFeedbackScope(appId: appId, client: client)
        return detail.map { ReviewInformation(Planner.resource($0)["attributes"]) }
    }
    public static func betaReviewDetailsDigest(appId: String, detail: AppStoreConnectClient.Resource) throws -> String {
        guard detail.type == "betaAppReviewDetails", !detail.id.isEmpty, Apple.owned(detail, "app", "apps", appId) else { throw PublishFailure.invalid("Apple did not confirm this app's beta review details.") }
        return JSONText.object([("appId", .string(appId)), ("id", .string(detail.id)), ("fields", ReviewInformation(Planner.resource(detail)["attributes"]).appleJSON)]).sha256
    }
    func planBetaReviewInformation(_ planner: Planner) async throws -> String {
        let request = planner.request, saved = try testFlightReviewInformationDraft(accountId: request.accountId, appId: request.appId)
        guard saved.revision > 0 else { throw PublishFailure.invalid("Enter TestFlight beta review contact and sign-in details first.") }
        let desired = try saved.fields.validated()
        planner.evidence.append(.object([("revision", .number(Double(saved.revision))), ("fields", desired.json)]))
        guard let current = try await betaReviewDetail(appId: request.appId, client: planner.client, planner: planner) else { throw PublishFailure.invalid("Apple has no beta review detail for this app yet. In App Store Connect, open the app's TestFlight tab, click Test Information under Additional in the sidebar and complete it. Then try again.") }
        let old = ReviewInformation(Planner.resource(current)["attributes"])
        guard case .object(let fields) = desired.json else { throw PublishFailure.invalid("Invalid beta review draft.") }
        let changes = fields.filter { old.json[$0.0] != $0.1 }
        if !changes.isEmpty {
            planner.add(.api, method: "PATCH", path: [.string("betaAppReviewDetails"), .string(current.id)], label: "Update TestFlight beta review details", detail: "Contact, demo account and reviewer notes. Password contents are hidden in this review.", before: old.display, after: desired.display,
                        body: .object([("data", .object([("type", .string("betaAppReviewDetails")), ("id", .string(current.id)), ("attributes", .object(changes))]))]),
                        guard: .object([("kind", .string("beta-review-details")), ("digest", .string(try Self.betaReviewDetailsDigest(appId: request.appId, detail: current)))]))
        }
        planner.notes.append("Apple uses these details when reviewing builds for external TestFlight testing. This action does not submit a build.")
        return "TestFlight beta review details"
    }
    func verifyBetaReviewInformation(method: String, parts: [String], data: JSONText?, guardValue: JSONText?, appId: String, client: AppStoreConnectClient) async throws {
        guard method == "PATCH", parts.count == 2, parts[0] == "betaAppReviewDetails", data?["type"]?.text == "betaAppReviewDetails", data?["id"]?.text == parts[1], data?["relationships"] == nil,
              case .object(let envelope)? = data, Set(envelope.map(\.0)) == ["type", "id", "attributes"], envelope.count == 3, case .object(let changes)? = data?["attributes"], !changes.isEmpty,
              changes.allSatisfy({ ReviewInformation.limits.map(\.0).contains($0.0) || $0.0 == "demoAccountRequired" }), Set(changes.map(\.0)).count == changes.count,
              guardValue?["kind"]?.text == "beta-review-details", let current = try await betaReviewDetail(appId: appId, client: client), current.id == parts[1],
              try Self.betaReviewDetailsDigest(appId: appId, detail: current) == guardValue?["digest"]?.text else { throw PublishFailure.write("TestFlight beta review details changed after review. Prepare a new review.") }
        guard case .object(let old) = ReviewInformation(Planner.resource(current)["attributes"]).json else { throw PublishFailure.write("Invalid beta review information.") }
        let updates = Dictionary(uniqueKeysWithValues: changes)
        _ = try ReviewInformation.savedBetaFields(.object(old.map { ($0.0, updates[$0.0] ?? $0.1) }))
    }
}
