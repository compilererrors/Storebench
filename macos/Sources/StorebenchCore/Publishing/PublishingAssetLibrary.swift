import Foundation

/// How long a Save waits for Apple to process uploaded Asset Library files, and how often it asks.
struct LibraryProcessingWait: Sendable {
    /// Apple processes the uploaded files in parallel; a large batch can take several minutes.
    var limit: Duration = .seconds(900)
    /// The pause before asking again after a dropped connection or a busy Apple read.
    var retry: Duration = .seconds(5)
    /// The pause between reads while Apple is still processing the file.
    var poll: Duration = .seconds(2)
}

extension WorkspaceSession {
    func verifyLibraryProcessing(path: String, guardValue: JSONText, appId: String, client: AppStoreConnectClient) async throws {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 3, [AssetLibrary.Kind.image.resource, AssetLibrary.Kind.video.resource].contains(parts[1]) else { throw PublishFailure.conflict }
        let reader = libraryReader(appId: appId, client: client), kind: AssetLibrary.Kind = parts[1] == AssetLibrary.Kind.image.resource ? .image : .video
        let wait = libraryProcessingWait, deadline = ContinuousClock.now.advanced(by: wait.limit)
        while ContinuousClock.now < deadline {
            // A dropped connection or a busy Apple read is asked again; only Apple's answer about the file ends the wait.
            let asset: AssetLibrary.Asset
            do { asset = try await reader.asset(parts[2], kind: kind) }
            catch let error as URLError where error.code != .cancelled { try await Task.sleep(for: wait.retry); continue }
            catch AppStoreConnectClient.Failure.status(let code) where code == 429 || code >= 500 { try await Task.sleep(for: wait.retry); continue }
            if asset.ready {
                guard let spec = asset.specId, AssetLibrary.strings(guardValue["specIds"]).contains(spec) else { throw AssetLibrary.failure("Apple matched this file to a different specification. Refresh Asset Library before placing it.") }; return
            }
            guard !["FAILED", "REJECTED", "ARCHIVED"].contains(asset.state) else { throw AssetLibrary.failure("Apple could not process this library asset. Read its status details before preparing another review.") }
            try await Task.sleep(for: wait.poll)
        }
        throw AssetLibrary.failure("Apple is still processing this file after 15 minutes. The upload is kept: prepare the review again later, and it waits for Apple instead of uploading the file again.")
    }
    func libraryReader(_ planner: Planner) -> LibraryReader { LibraryReader(appId: planner.request.appId, get: planner.get, list: planner.list) }
    static func libraryAssetDigest(_ asset: AssetLibrary.Asset) -> String {
        let fields = ["fileName", "fileSize", "category", "referenceName", "previewFrameTimeCode", "state", "specId", "stateDetails"]
        return JSONText.array([.string(asset.id), .string(asset.kind.rawValue), .object(fields.map { ($0, asset.value["attributes"]?[$0] ?? .null) })]).sha256
    }
    static func libraryBody(_ type: String, id: JSONText? = nil, attributes: JSONText? = nil, relationships: JSONText? = nil) -> JSONText {
        var fields: [(String, JSONText)] = [("type", .string(type))]
        if let id { fields.append(("id", id)) }; if let attributes { fields.append(("attributes", attributes)) }; if let relationships { fields.append(("relationships", relationships)) }
        return .object([("data", .object(fields))])
    }
    func libraryReservation(file: AssetLibrary.File, accountId: String, appId: String) throws -> String? {
        let history = try publishHistory(accountId: accountId, appId: appId)
        let deleted = Set(history.flatMap { review in review.steps.compactMap { step -> String? in
            guard review.request.scope == .assetLibrary, step.kind == .api, step.method == "DELETE", step.state == "done", step.path.count == 2, step.path[0].text == file.kind.resource else { return nil }; return step.path[1].text
        } })
        for review in history where review.request.scope == .assetLibrary && review.request.assetLibraryChange?.fileId == file.id {
            if let step = review.steps.first(where: { $0.kind == .api && $0.method == "POST" && $0.path == [.string(file.kind.resource)] }), let id = step.resultId, !deleted.contains(id) { return id }
        }
        return nil
    }
    func planAssetLibrary(_ planner: Planner) async throws -> String {
        let request = planner.request, reader = libraryReader(planner)
        guard let change = request.assetLibraryChange else { throw AssetLibrary.failure("Choose an Asset Library action.") }
        func guardValue(_ kind: String, _ pairs: [(String, JSONText)] = []) -> JSONText { .object([("kind", .string(kind)), ("change", change.json)] + pairs) }
        func add(method: String, root: String, id: JSONText? = nil, label: String, detail: String, before: String? = nil, after: String? = nil, attributes: JSONText? = nil, relationships: JSONText? = nil, guard kind: String, evidence: [(String, JSONText)] = []) {
            planner.add(.api, method: method, path: [.string(root)] + (id.map { [$0] } ?? []), label: label, detail: detail, before: before, after: after,
                        body: method == "DELETE" ? nil : Self.libraryBody(root, id: id, attributes: attributes, relationships: relationships), guard: guardValue(kind, evidence))
        }
        if change.action == .upload {
            let file = try libraryFile(accountId: request.accountId, appId: request.appId, id: change.fileId!), description = try describeLibraryFile(accountId: request.accountId, appId: request.appId, id: file.id)
            guard change.kind == file.kind else { throw AssetLibrary.failure("Choose the saved file's matching media type.") }
            planner.evidence.append(file.json)
            let library = try await reader.library(), catalog = try await reader.catalog(), matches = catalog.matching(file)
            guard !matches.isEmpty else { throw AssetLibrary.failure("This file does not match Apple's current dimensions, format, transparency, audio or duration requirements. Check Specifications before uploading.") }
            let reservation = try libraryReservation(file: file, accountId: request.accountId, appId: request.appId)
            var resourceId: JSONText
            let uploadGuard = guardValue("asset-library-upload", [("file", file.json), ("asset", description)])
            if let reservation {
                let asset = try await reader.asset(reservation, kind: file.kind)
                guard asset.fileName == file.fileName, asset.size == file.size, asset.category == file.category.rawValue else { throw AssetLibrary.failure("The earlier upload reservation changed. Review it in Asset Library before continuing.") }
                if asset.state == "UPLOAD_COMPLETE" || asset.ready {
                    planner.notes.append("This file is already uploaded. Refresh Asset Library to follow processing or create placements. It will not be uploaded again."); return "Asset already uploaded"
                }
                guard asset.state == "AWAITING_UPLOAD" else { throw AssetLibrary.failure("The earlier upload cannot be resumed. Review its Apple status and remove it before uploading a replacement.") }
                resourceId = .string(reservation)
                planner.notes.append("Reuse Storebench's earlier reservation and send the complete saved file again. No duplicate reservation is created.")
            } else {
                let uncertain = try publishHistory(accountId: request.accountId, appId: request.appId).contains { review in
                    review.request.scope == .assetLibrary && review.request.assetLibraryChange?.fileId == file.id && review.approvedAt != nil && review.steps.contains { step in
                        step.kind == .api && step.method == "POST" && step.path == [.string(file.kind.resource)] && step.resultId == nil && ["running", "failed"].contains(step.state)
                    }
                }
                if uncertain {
                    let candidates = try await reader.assets(libraryId: library, kind: file.kind).filter { $0.fileName == file.fileName && $0.size == file.size && $0.category == file.category.rawValue && $0.referenceName == file.referenceName }
                    guard candidates.isEmpty else { throw AssetLibrary.failure("An interrupted reservation may already exist at Apple, but its identity was not saved. Refresh Asset Library and review the matching asset before retrying; Storebench will not create an automatic duplicate.") }
                    planner.notes.append("An earlier reservation could not be confirmed. No matching file is currently visible in Apple's library. This approval creates a new reservation and does not replay the earlier review.")
                }
                let attributes = JSONText.object([("fileName", .string(file.fileName)), ("fileSize", .number(Double(file.size))), ("category", .string(file.category.rawValue)), ("referenceName", .string(file.referenceName))] + (file.kind == .video ? file.timeCode.map { [("previewFrameTimeCode", JSONText.string($0))] } ?? [] : []))
                let key = planner.add(.api, method: "POST", path: [.string(file.kind.resource)], label: "Reserve library \(file.kind.rawValue)", detail: "\(file.fileName) · \(file.width) × \(file.height) px · \(file.size) bytes · \(file.category.label)", after: file.referenceName,
                                      body: Self.libraryBody(file.kind.resource, attributes: attributes, relationships: .object([("assetLibrary", Apple.relationship("appAssetLibraries", .string(library)))])), guard: guardValue("asset-library-reserve", [("file", file.json), ("asset", description), ("libraryId", .string(library)), ("catalogDigest", .string(catalog.value.sha256))]))
                resourceId = Apple.ref(key)
            }
            planner.add(.upload, path: [.string(file.kind.resource), resourceId], label: "Upload saved original", detail: "Send \(file.size) encrypted local bytes to Apple's reserved upload addresses.", asset: description, guard: uploadGuard)
            add(method: "PATCH", root: file.kind.resource, id: resourceId, label: "Finish library upload", detail: file.fileName, attributes: .object([("uploaded", .bool(true))]), guard: "asset-library-upload", evidence: [("file", file.json), ("asset", description)])
            planner.add(.verify, path: [.string(file.kind.resource), resourceId], label: "Verify Apple processing", detail: "Wait for a usable asset and confirm Apple's matched specification.", guard: guardValue("asset-library-processed", [("specIds", .array(matches.map { .string($0.id) }))]))
            planner.notes.append("Uploading saves the file in Asset Library. Placement and App Review submission are separate approved changes.")
            return "Upload to Asset Library"
        }
        if change.action == .submit { return try await planLibrarySubmission(planner, reader: reader, change: change) }
        if change.action == .removePlacement || change.action == .reorder || change.action == .place {
            let target = try await reader.target(change.targetId!, surface: change.surface), placements = try await reader.placements(target: target)
            guard target.editable || target.liveCreative && change.action != .reorder else { throw AssetLibrary.failure("This destination is not editable. Live versions accept approved creative assets; choose an editable destination to reorder screenshots or previews.") }
            let digest = JSONText.array(placements.map(\.value)).sha256
            var evidence: [(String, JSONText)] = [("placementsDigest", .string(digest)), ("targetState", .string(target.state)), ("targetPlatform", .string(target.platform))]
            if !target.editable { planner.notes.append("This change updates the creative asset placement on the live App Store page. The original stays in Asset Library.") }
            if change.action == .removePlacement {
                guard let placement = placements.first(where: { $0.id == change.placementId }) else { throw AssetLibrary.failure("The placement no longer belongs to this destination.") }
                if !target.editable {
                    let asset = try await reader.asset(placement.assetId, kind: placement.kind), catalog = try await reader.catalog()
                    guard asset.category == AssetLibrary.Category.creative.rawValue,
                          catalog.slots(surface: target.surface, platform: target.platform, category: asset.category, specId: asset.specId).contains(where: { $0.type == placement.type && $0.group == placement.group }) else { throw AssetLibrary.failure("Only creative asset placements can be removed from a live version.") }
                    evidence += [("assetDigest", .string(Self.libraryAssetDigest(asset))), ("catalogDigest", .string(catalog.value.sha256))]
                }
                add(method: "DELETE", root: "appAssetLibraryPlacements", id: .string(placement.id), label: "Remove placement", detail: target.name, before: "\(placement.type) · \(placement.group) · \(placement.assetId)", after: "The asset remains in the library.", guard: "asset-library-placement", evidence: evidence)
            } else if change.action == .reorder {
                let group = placements.filter { $0.group == change.placementGroup }
                if let expected = change.expectedPlacements { guard AssetLibrary.orderDigest(group) == expected else { throw AssetLibrary.failure("Apple's placement order changed. Read and compare the latest placements before preparing an upload.") } }
                guard group.count == change.orderedIds.count, Set(group.map(\.id)) == Set(change.orderedIds) else { throw AssetLibrary.failure("Include every placement in this group exactly once.") }
                if group.map(\.id) != change.orderedIds {
                    add(method: "POST", root: "appAssetLibraryPlacementOrderingRequests", label: "Set placement order", detail: target.name + " · " + change.placementGroup!, before: group.map(\.assetId).joined(separator: "\n"), after: change.orderedIds.compactMap { id in group.first { $0.id == id }?.assetId }.joined(separator: "\n"), attributes: .object([("placementGroup", .string(change.placementGroup!))]),
                        relationships: .object([(target.surface.relationship, Apple.relationship(target.surface.resource, .string(target.id))), ("orderedPlacements", .object([("data", .array(change.orderedIds.map { .object([("type", .string("appAssetLibraryPlacements")), ("id", .string($0))]) }))]))]), guard: "asset-library-placement", evidence: evidence)
                }
            } else {
                let asset = try await reader.asset(change.assetId!, kind: change.kind), catalog = try await reader.catalog()
                guard asset.ready, let specId = asset.specId, catalog.specs.contains(where: { $0.id == specId && $0.kind == asset.kind }), let slot = catalog.slots(surface: target.surface, platform: target.platform.isEmpty ? nil : target.platform, category: asset.category, specId: specId).first(where: { $0.type == change.placementType && $0.group == change.placementGroup }) else { throw AssetLibrary.failure("This processed asset is not compatible with the selected placement.") }
                guard target.allowsPlacement(asset, slot: slot) else { throw AssetLibrary.failure("Live versions require an approved creative asset. Screenshots and previews must be changed in an editable version.") }
                guard placements.filter({ $0.type == slot.type && slot.limitGroups.contains($0.group) }).count < slot.limit else { throw AssetLibrary.failure("This destination has reached Apple's limit for this placement group.") }
                guard !placements.contains(where: { $0.type == slot.type && $0.group == slot.group && $0.assetId == asset.id }) else { return "Asset is already placed" }
                evidence += [("assetDigest", .string(Self.libraryAssetDigest(asset))), ("catalogDigest", .string(catalog.value.sha256))]
                add(method: "POST", root: "appAssetLibraryPlacements", label: "Place \(asset.name)", detail: target.name, before: "No placement", after: slot.label, attributes: .object([("placementType", .string(slot.type)), ("placementGroup", .string(slot.group))]),
                    relationships: .object([(asset.kind.rawValue, Apple.relationship(asset.kind.resource, .string(asset.id))), (target.surface.relationship, Apple.relationship(target.surface.resource, .string(target.id)))]), guard: "asset-library-placement", evidence: evidence)
            }
            return "Change Asset Library placement"
        }
        let asset = try await reader.asset(change.assetId!, kind: change.kind), digest = Self.libraryAssetDigest(asset)
        switch change.action {
        case .rename:
            if asset.referenceName != change.name { add(method: "PATCH", root: asset.kind.resource, id: .string(asset.id), label: "Rename library asset", detail: asset.fileName, before: asset.referenceName, after: change.name, attributes: .object([("referenceName", .string(change.name!))]), guard: "asset-library-asset", evidence: [("digest", .string(digest))]) }
        case .poster:
            guard asset.ready, asset.state != "APPROVED" else { throw AssetLibrary.failure("Choose a processed video that has not been approved. Apple locks poster frames after approval.") }
            add(method: "PATCH", root: asset.kind.resource, id: .string(asset.id), label: "Change preview frame", detail: asset.name, before: asset.value["attributes"]?["previewFrameTimeCode"]?.text ?? "Apple default", after: change.timeCode, attributes: .object([("previewFrameTimeCode", .string(change.timeCode!))]), guard: "asset-library-asset", evidence: [("digest", .string(digest))])
        case .archive:
            guard asset.state == "APPROVED" else { throw AssetLibrary.failure("Only an approved asset can be archived.") }
            let uses = try await reader.uses(asset)
            add(method: "PATCH", root: asset.kind.resource, id: .string(asset.id), label: "Archive library asset", detail: "\(asset.name) · used by \(uses.count) placements", before: asset.state + (uses.isEmpty ? "" : "\nPlacements using this asset: " + uses.map(\.id).joined(separator: ", ")), after: "ARCHIVED", attributes: .object([("archived", .bool(true))]), guard: "asset-library-asset", evidence: [("digest", .string(digest)), ("usesDigest", .string(JSONText.array(uses.map(Planner.resource)).sha256))])
        case .restore:
            guard asset.state == "ARCHIVED" else { throw AssetLibrary.failure("Only an archived asset can be restored.") }
            add(method: "PATCH", root: asset.kind.resource, id: .string(asset.id), label: "Restore library asset", detail: asset.name, before: "ARCHIVED", after: "Available for new placements", attributes: .object([("archived", .bool(false))]), guard: "asset-library-asset", evidence: [("digest", .string(digest))])
        case .delete:
            guard asset.state == "PREPARE_FOR_SUBMISSION" else { throw AssetLibrary.failure("Apple permits deletion only while an asset is prepared for submission. Archive approved assets instead.") }
            guard try await reader.uses(asset).isEmpty else { throw AssetLibrary.failure("This asset is used by placements. Remove those placements in separate reviews before deleting the file.") }
            add(method: "DELETE", root: asset.kind.resource, id: .string(asset.id), label: "Delete library asset", detail: asset.name, before: "\(asset.fileName) · \(asset.state)", after: "Removed from Apple's library", guard: "asset-library-asset", evidence: [("digest", .string(digest))])
        default: throw AssetLibrary.failure("Unsupported Asset Library action.")
        }
        return "Manage Asset Library asset"
    }

    /// Fresh scope, body and stale-state checks run immediately before every approved library write.
    func verifyLibraryWrite(method: String, parts: [String], body: JSONText?, guardValue: JSONText?, appId: String, client: AppStoreConnectClient) async throws {
        if let guardValue, guardValue["kind"]?.text?.hasPrefix("release-media-") == true { try await verifyReleaseMediaWrite(method: method, parts: parts, body: body, guardValue: guardValue, appId: appId, client: client); return }
        guard let guardValue, let value = guardValue["change"], let kind = guardValue["kind"]?.text else { throw PublishFailure.write("Asset Library writes require a reviewed selection.") }
        let change = try AssetLibrary.Change(value), reader = libraryReader(appId: appId, client: client), account = client.token.account.id
        let root = parts[0]
        if kind == "asset-library-reserve" {
            let file = try libraryFile(accountId: account, appId: appId, id: change.fileId!), catalog = try await reader.catalog(), library = try await reader.library()
            guard method == "POST", parts.count == 1, root == file.kind.resource, guardValue["libraryId"]?.text == library, guardValue["catalogDigest"]?.text == catalog.value.sha256, !catalog.matching(file).isEmpty,
                  guardValue["file"] == file.json, guardValue["asset"] == (try describeLibraryFile(accountId: account, appId: appId, id: file.id)), try libraryReservation(file: file, accountId: account, appId: appId) == nil else { throw PublishFailure.conflict }
            let attrs = JSONText.object([("fileName", .string(file.fileName)), ("fileSize", .number(Double(file.size))), ("category", .string(file.category.rawValue)), ("referenceName", .string(file.referenceName))] + (file.kind == .video ? file.timeCode.map { [("previewFrameTimeCode", JSONText.string($0))] } ?? [] : []))
            guard body == Self.libraryBody(root, attributes: attrs, relationships: .object([("assetLibrary", Apple.relationship("appAssetLibraries", .string(library)))])) else { throw PublishFailure.write("Unsupported library reservation.") }
            return
        }
        if kind == "asset-library-upload" {
            guard parts.count == 2, method == "PATCH", change.action == .upload, root == change.kind.resource else { throw PublishFailure.write("Unsupported library upload commit.") }
            let asset = try await reader.asset(parts[1], kind: root == AssetLibrary.Kind.image.resource ? .image : .video)
            try verifyLibraryUpload(asset, guardValue: guardValue, accountId: account, appId: appId)
            guard body == Self.libraryBody(root, id: .string(parts[1]), attributes: .object([("uploaded", .bool(true))])) else { throw PublishFailure.write("Unsupported library upload commit.") }; return
        }
        if kind == "asset-library-asset" {
            guard parts.count == 2, parts[1] == change.assetId, root == change.kind.resource else { throw PublishFailure.write("Unsupported library asset change.") }
            let asset = try await reader.asset(parts[1], kind: change.kind)
            guard Self.libraryAssetDigest(asset) == guardValue["digest"]?.text else { throw PublishFailure.conflict }
            let attrs: JSONText?
            switch change.action {
            case .rename: attrs = .object([("referenceName", .string(change.name!))])
            case .poster: guard asset.ready, asset.state != "APPROVED" else { throw PublishFailure.conflict }; attrs = .object([("previewFrameTimeCode", .string(change.timeCode!))])
            case .archive: guard asset.state == "APPROVED", try await JSONText.array(reader.uses(asset).map(Planner.resource)).sha256 == guardValue["usesDigest"]?.text else { throw PublishFailure.conflict }; attrs = .object([("archived", .bool(true))])
            case .restore: guard asset.state == "ARCHIVED" else { throw PublishFailure.conflict }; attrs = .object([("archived", .bool(false))])
            case .delete: guard asset.state == "PREPARE_FOR_SUBMISSION", try await reader.uses(asset).isEmpty else { throw PublishFailure.conflict }; attrs = nil
            default: throw PublishFailure.write("Unsupported library asset change.")
            }
            guard method == (change.action == .delete ? "DELETE" : "PATCH"), body == attrs.map({ Self.libraryBody(root, id: .string(asset.id), attributes: $0) }) else { throw PublishFailure.write("Unsupported library asset change.") }; return
        }
        if kind == "asset-library-placement" {
            var request = PublishRequest(accountId: account, appId: appId, scope: .assetLibrary); request.assetLibraryChange = change
            let fresh = Planner(client: client, request: request)
            _ = try await planAssetLibrary(fresh)
            guard fresh.steps.count == 1, let step = fresh.steps.first, method == step.method, parts == (try Self.apiPath(step.path, ids: [:])).split(separator: "/").dropFirst().map(String.init), body == step.body, guardValue == step.guardValue else { throw PublishFailure.conflict }; return
        }
        if kind.hasPrefix("asset-library-review") { try await verifyLibrarySubmission(method: method, parts: parts, body: body, guardValue: guardValue, appId: appId, client: client); return }
        throw PublishFailure.write("Unsupported Asset Library write.")
    }
    func verifyLibraryUpload(_ asset: AssetLibrary.Asset, guardValue: JSONText?, accountId: String, appId: String) throws {
        guard let fileId = guardValue?["change"]?["fileId"]?.text else { throw PublishFailure.conflict }
        let file = try libraryFile(accountId: accountId, appId: appId, id: fileId)
        guard asset.kind == file.kind, asset.state == "AWAITING_UPLOAD", asset.fileName == file.fileName, asset.size == file.size, asset.category == file.category.rawValue,
              asset.referenceName == file.referenceName, try libraryReservation(file: file, accountId: accountId, appId: appId) == asset.id,
              guardValue?["file"] == file.json, guardValue?["asset"] == (try describeLibraryFile(accountId: accountId, appId: appId, id: fileId)) else { throw PublishFailure.conflict }
    }
}
