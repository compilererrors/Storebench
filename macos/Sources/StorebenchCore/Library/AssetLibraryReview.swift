import Foundation

extension WorkspaceSession {
    /// A version also submits its assigned library media. Its approval must name and recheck that material.
    func versionLibraryReview(reader: LibraryReader, version: AppStoreConnectClient.Resource) async throws -> (digest: String, descriptions: [String]) {
        do { _ = try await reader.library() }
        catch AppStoreConnectClient.Failure.status(404) { return (JSONText.null.sha256, []) }
        let locales = try await reader.children("/v1/appStoreVersions/\(version.id)/appStoreVersionLocalizations?limit=200", type: "appStoreVersionLocalizations", parent: ("appStoreVersion", "appStoreVersions", version.id))
        var material: [JSONText] = [], descriptions: [String] = []
        for locale in locales {
            let target = AssetLibrary.Target(id: locale.id, name: locale.attributes?["locale"]?.string ?? locale.id, platform: version.attributes?["platform"]?.string ?? "", state: Apple.state(version), surface: .versions)
            let placements = try await reader.placements(target: target)
            for placement in placements {
                let asset = try await reader.asset(placement.assetId, kind: placement.kind)
                guard ["PREPARE_FOR_SUBMISSION", "REJECTED", "READY_FOR_REVIEW", "ACCEPTED", "APPROVED"].contains(asset.state), asset.specId != nil else { throw AssetLibrary.failure("A library asset assigned to this version is not ready for review. Read its processing status in Asset Library.") }
                material.append(.array([.string(locale.id), .string(placement.id), .string(placement.type), .string(placement.group), .string(Self.libraryReviewAssetDigest(asset))]))
                descriptions.append("\(target.name) · \(placement.type) · \(placement.group) · \(asset.name) · \(asset.fileName)")
            }
        }
        return (JSONText.array(material).sha256, descriptions)
    }
    static let libraryApprovedVersions: Set<String> = ["READY_FOR_DISTRIBUTION", "READY_FOR_SALE", "PENDING_DEVELOPER_RELEASE"]
    static func libraryReviewAssetDigest(_ asset: AssetLibrary.Asset) -> String {
        let fields = ["fileName", "fileSize", "category", "referenceName", "previewFrameTimeCode", "specId", "stateDetails"]
        return JSONText.array([.string(asset.id), .string(asset.kind.rawValue), .object(fields.map { ($0, asset.value["attributes"]?[$0] ?? .null) })]).sha256
    }
    func libraryReviewContext(reader: LibraryReader, change: AssetLibrary.Change, currentSubmission: String? = nil) async throws -> (assets: [AssetLibrary.Asset], submissions: [AppStoreConnectClient.Resource]) {
        let versions = try await reader.children("/v1/apps/\(reader.appId)/appStoreVersions?include=app&limit=200", type: "appStoreVersions", parent: ("app", "apps", reader.appId))
        guard versions.contains(where: { $0.attributes?["platform"]?.string == change.platform && Self.libraryApprovedVersions.contains(Apple.state($0)) }) else { throw AssetLibrary.failure("Standalone asset review requires an approved app version on this platform. For a first version, place the assets on that version and submit the version from App Store changes.") }
        var assets: [AssetLibrary.Asset] = []
        let library = try await reader.library()
        let available = try await reader.assets(libraryId: library, kind: .image) + reader.assets(libraryId: library, kind: .video)
        for id in change.assetIds {
            let matches = available.filter { $0.id == id }
            guard matches.count == 1 else { throw AssetLibrary.failure("A selected asset has an unknown or ambiguous media type.") }
            let asset = try await reader.asset(id, kind: matches[0].kind)
            guard (["PREPARE_FOR_SUBMISSION", "REJECTED"].contains(asset.state) || currentSubmission != nil && asset.state == "READY_FOR_REVIEW"), asset.specId != nil else { throw AssetLibrary.failure("Choose processed assets that are ready for a new review.") }
            for placement in try await reader.uses(asset) {
                for surface in AssetLibrary.Surface.allCases {
                    if let owner = Apple.owner(placement, surface.relationship) {
                        guard owner.type == surface.resource else { throw PublishFailure.conflict }
                        let target = try await reader.target(owner.id, surface: surface)
                        guard !["WAITING_FOR_REVIEW", "IN_REVIEW", "READY_FOR_REVIEW", "UNRESOLVED_ISSUES"].contains(target.state) else { throw AssetLibrary.failure("An asset is assigned to material in an active submission. Submit it with that material or wait for the review to finish.") }
                    }
                }
            }
            assets.append(asset)
        }
        let submissions = try await reader.children("/v1/apps/\(reader.appId)/reviewSubmissions?limit=200", type: "reviewSubmissions", parent: ("app", "apps", reader.appId))
        for submission in submissions where ["READY_FOR_REVIEW", "WAITING_FOR_REVIEW", "IN_REVIEW", "UNRESOLVED_ISSUES"].contains(Apple.state(submission)) {
            if submission.id == currentSubmission { continue }
            let members = try await reader.children("/v1/reviewSubmissions/\(submission.id)/items?limit=200", type: "reviewSubmissionItems", parent: ("reviewSubmission", "reviewSubmissions", submission.id))
            guard !members.contains(where: { member in ["appAssetLibraryImage", "appAssetLibraryVideo"].contains { change.assetIds.contains(Apple.owner(member, $0)?.id ?? "") } }) else { throw AssetLibrary.failure("A selected asset already belongs to an active review submission.") }
        }
        return (assets, submissions)
    }
    func planLibrarySubmission(_ planner: Planner, reader: LibraryReader, change: AssetLibrary.Change) async throws -> String {
        let context = try await libraryReviewContext(reader: reader, change: change)
        var baseline: [AppStoreConnectClient.Resource] = [], submission: JSONText
        if let id = change.submissionId {
            guard let item = context.submissions.first(where: { $0.id == id }), Apple.state(item) == "READY_FOR_REVIEW", item.attributes?["platform"]?.string == change.platform else { throw AssetLibrary.failure("Choose a draft review submission for this platform.") }
            baseline = try await reader.children("/v1/reviewSubmissions/\(id)/items?limit=200", type: "reviewSubmissionItems", parent: ("reviewSubmission", "reviewSubmissions", id))
            submission = .string(id)
        } else {
            let key = planner.add(.api, method: "POST", path: [.string("reviewSubmissions")], label: "Create asset review submission", detail: "\(change.platform!) · \(context.assets.count) library assets",
                                  body: Self.libraryBody("reviewSubmissions", attributes: .object([("platform", .string(change.platform!))]), relationships: .object([("app", Apple.relationship("apps", .string(planner.request.appId)))])), guard: .object([("kind", .string("asset-library-review-create")), ("change", change.json)]))
            submission = Apple.ref(key)
        }
        let evidence: [(String, JSONText)] = [("change", change.json), ("assets", .array(context.assets.map { .string(Self.libraryReviewAssetDigest($0)) })), ("baseline", .array(baseline.map(Planner.resource)))]
        for asset in context.assets {
            let relationship = asset.kind == .image ? "appAssetLibraryImage" : "appAssetLibraryVideo"
            planner.add(.api, method: "POST", path: [.string("reviewSubmissionItems")], label: "Add \(asset.name) for review", detail: "\(asset.fileName) · \(asset.kind.rawValue) · \(asset.category)",
                        body: Self.libraryBody("reviewSubmissionItems", relationships: .object([("reviewSubmission", Apple.relationship("reviewSubmissions", submission)), (relationship, Apple.relationship(asset.kind.resource, .string(asset.id)))])),
                        guard: .object([("kind", .string("asset-library-review-item")), ("assetId", .string(asset.id))] + evidence))
        }
        planner.add(.api, method: "PATCH", path: [.string("reviewSubmissions"), submission], label: "Submit assets for App Review", detail: "Submit every listed asset with \(baseline.count) existing draft items on \(change.platform!).", before: "Draft review submission", after: context.assets.map(\.name).joined(separator: "\n") + (baseline.isEmpty ? "" : "\nExisting items: " + baseline.map(\.id).joined(separator: ", ")),
                    body: Self.libraryBody("reviewSubmissions", id: submission, attributes: .object([("submitted", .bool(true))])), guard: .object([("kind", .string("asset-library-review-final"))] + evidence))
        planner.notes.append("All selected assets are reviewed with the latest approved version on this platform. Creative Assets must be suitable for a 4+ audience. Existing draft items listed in this review are submitted together.")
        return "Submit Asset Library assets for review"
    }
    func verifyLibrarySubmission(method: String, parts: [String], body: JSONText?, guardValue: JSONText, appId: String, client: AppStoreConnectClient) async throws {
        let change = try AssetLibrary.Change(guardValue["change"]!), reader = libraryReader(appId: appId, client: client), kind = guardValue["kind"]?.text
        guard change.action == .submit else { throw PublishFailure.write("Unsupported asset review selection.") }
        let submissions = try await reader.children("/v1/apps/\(appId)/reviewSubmissions?limit=200", type: "reviewSubmissions", parent: ("app", "apps", appId))
        if kind == "asset-library-review-create" {
            _ = try await libraryReviewContext(reader: reader, change: change)
            guard method == "POST", parts == ["reviewSubmissions"], change.submissionId == nil,
                  body == Self.libraryBody("reviewSubmissions", attributes: .object([("platform", .string(change.platform!))]), relationships: .object([("app", Apple.relationship("apps", .string(appId)))])) else { throw PublishFailure.write("Unsupported asset review creation.") }; return
        }
        let submissionId = kind == "asset-library-review-final" ? parts.last : body?["data"]?["relationships"]?["reviewSubmission"]?["data"]?["id"]?.text
        guard let submissionId, let submission = submissions.first(where: { $0.id == submissionId }), Apple.state(submission) == "READY_FOR_REVIEW", submission.attributes?["platform"]?.string == change.platform,
              change.submissionId == nil || change.submissionId == submissionId else { throw PublishFailure.conflict }
        let baseline = AssetLibrary.items(guardValue["baseline"])
        let members = try await reader.children("/v1/reviewSubmissions/\(submissionId)/items?limit=200", type: "reviewSubmissionItems", parent: ("reviewSubmission", "reviewSubmissions", submissionId))
        let baselineIds = baseline.compactMap { $0["id"]?.text }
        func memberAsset(_ item: AppStoreConnectClient.Resource) -> (id: String, kind: AssetLibrary.Kind)? {
            let image = Apple.owner(item, "appAssetLibraryImage"), video = Apple.owner(item, "appAssetLibraryVideo")
            guard (image == nil) != (video == nil), let link = image ?? video else { return nil }
            let kind: AssetLibrary.Kind = image == nil ? .video : .image, relation = image == nil ? "appAssetLibraryVideo" : "appAssetLibraryImage"
            guard link.type == kind.resource else { return nil }
            for (name, value) in item.relationships ?? [:] where ![relation, "reviewSubmission"].contains(name) {
                guard case .object(let object) = value, object["data"] == nil || object["data"] == .null else { return nil }
            }
            return (link.id, kind)
        }
        guard baseline.allSatisfy({ previous in members.contains { Planner.resource($0) == previous } }), members.allSatisfy({ baselineIds.contains($0.id) || memberAsset($0).map { change.assetIds.contains($0.id) } == true }) else { throw PublishFailure.conflict }
        let current = try await libraryReviewContext(reader: reader, change: change, currentSubmission: submissionId).assets
        guard members.filter({ !baselineIds.contains($0.id) }).allSatisfy({ member in memberAsset(member).map { linked in current.contains { $0.id == linked.id && $0.kind == linked.kind } } == true }) else { throw PublishFailure.conflict }
        guard current.map({ Self.libraryReviewAssetDigest($0) }) == AssetLibrary.strings(guardValue["assets"]), current.filter({ $0.state == "READY_FOR_REVIEW" }).allSatisfy({ asset in members.contains { memberAsset($0).map { $0.id == asset.id && $0.kind == asset.kind } == true } }) else { throw PublishFailure.conflict }
        let versions = try await reader.children("/v1/apps/\(appId)/appStoreVersions?include=app&limit=200", type: "appStoreVersions", parent: ("app", "apps", appId))
        guard versions.contains(where: { $0.attributes?["platform"]?.string == change.platform && Self.libraryApprovedVersions.contains(Apple.state($0)) }) else { throw PublishFailure.conflict }
        if kind == "asset-library-review-item" {
            guard let assetId = guardValue["assetId"]?.text, let asset = current.first(where: { $0.id == assetId }), !members.contains(where: { memberAsset($0)?.id == assetId }), method == "POST", parts == ["reviewSubmissionItems"] else { throw PublishFailure.conflict }
            let relation = asset.kind == .image ? "appAssetLibraryImage" : "appAssetLibraryVideo"
            guard body == Self.libraryBody("reviewSubmissionItems", relationships: .object([("reviewSubmission", Apple.relationship("reviewSubmissions", .string(submissionId))), (relation, Apple.relationship(asset.kind.resource, .string(assetId)))])) else { throw PublishFailure.conflict }
        } else {
            let added = members.filter { !baselineIds.contains($0.id) }
            guard kind == "asset-library-review-final", added.count == change.assetIds.count, Set(added.compactMap { memberAsset($0)?.id }) == Set(change.assetIds),
                  method == "PATCH", parts == ["reviewSubmissions", submissionId], body == Self.libraryBody("reviewSubmissions", id: .string(submissionId), attributes: .object([("submitted", .bool(true))])) else { throw PublishFailure.conflict }
        }
    }
}
