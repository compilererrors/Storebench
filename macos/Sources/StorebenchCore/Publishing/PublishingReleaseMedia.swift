import Foundation

/// Languages & media screenshots and app previews, published as Asset Library uploads, placements and ordering requests.
final class ReleaseMediaPlan: @unchecked Sendable {
    struct Library { let id: String, catalog: AssetLibrary.Catalog, assets: [String: AssetLibrary.Asset], known: [String: String] }
    struct Item { let originalId, hash, storage, ext, fileName: String; let width, height: Int; let assetId, poster: String? }
    let platform: String
    /// Only uploads files to Asset Library: nothing is added to the version and Apple's processing is not awaited.
    var uploadOnly = false
    var library: Library?
    /// Files reserved earlier in this review, by media kind and SHA-256, so a file shared by several languages is uploaded once.
    var reserved: [String: JSONText] = [:]
    /// Final placements by language and group, so screenshot and app preview passes order a shared group completely.
    var order: [String: [String: [JSONText]]] = [:]
    var placements: [String: [AssetLibrary.Placement]] = [:]
    init(platform: String) { self.platform = platform }
}

extension WorkspaceSession {
    /// The Asset Library file a saved file already is: the file chosen with Add from Asset Library, or the file an earlier Save
    /// from this Mac uploaded with the same SHA-256. Apple lists no content checksum for Asset Library files, so a file with only
    /// the same name and byte size is a different file and is uploaded; choose it with Add from Asset Library to use it instead.
    static func libraryAsset(_ item: ReleaseMediaPlan.Item, kind: AssetLibrary.Kind, library: ReleaseMediaPlan.Library) -> String? {
        if let id = item.assetId ?? library.known[kind.rawValue + ":" + item.hash], library.assets[id] != nil || item.assetId != nil { return id }
        return nil
    }

    /// Asset Library reservations this Mac created for release media in earlier reviews.
    func releaseReservations(accountId: String, appId: String) throws -> Set<String> {
        Set(try publishHistory(accountId: accountId, appId: appId).flatMap { review in review.steps.compactMap { step in
            step.kind == .api && step.method == "POST" && step.guardValue?["kind"]?.text == "release-media-reserve" ? step.resultId : nil
        } })
    }

    func releaseMediaLibrary(_ planner: Planner, media: ReleaseMediaPlan) async throws -> ReleaseMediaPlan.Library {
        if let library = media.library { return library }
        let request = planner.request, reader = libraryReader(planner), id: String
        do { id = try await reader.library() }
        catch AppStoreConnectClient.Failure.status(let code) where [403, 404].contains(code) {
            throw PublishFailure.invalid("Screenshots and app previews are published through Asset Library, which this app or API key cannot use. Use a key with the Account Holder, Admin or App Manager role.")
        }
        let catalog = try await reader.catalog()
        let assets = try await reader.assets(libraryId: id, kind: .image) + reader.assets(libraryId: id, kind: .video)
        guard Set(assets.map(\.id)).count == assets.count else { throw AssetLibrary.failure("Apple returned ambiguous library asset identities.") }
        // Files that earlier approved reviews uploaded, so a retry or another language places them instead of uploading again.
        var known: [String: String] = [:]
        for review in try publishHistory(accountId: request.accountId, appId: request.appId).reversed() {
            for step in review.steps where step.kind == .api && step.method == "POST" && step.state == "done" && step.guardValue?["kind"]?.text == "release-media-reserve" {
                if let id = step.resultId, let hash = step.guardValue?["asset"]?["hash"]?.text, let root = step.path.first?.text, let kind = AssetLibrary.Kind.allCases.first(where: { $0.resource == root }) { known[kind.rawValue + ":" + hash] = id }
            }
        }
        let library = ReleaseMediaPlan.Library(id: id, catalog: catalog, assets: Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) }), known: known)
        media.library = library
        // A review that stopped before its upload leaves a reservation Apple keeps waiting for. Only this Mac's own reservations
        // are removed, in this same review; they were never uploaded or placed, and the files are reserved again below.
        let own = try releaseReservations(accountId: request.accountId, appId: request.appId)
        for asset in assets where asset.state == "AWAITING_UPLOAD" && own.contains(asset.id) {
            planner.add(.api, method: "DELETE", path: [.string(asset.kind.resource), .string(asset.id)], label: "Remove unfinished upload · \(asset.fileName)",
                        detail: "An earlier review reserved this file but stopped before uploading it. It was never placed.", before: "\(asset.fileName) · waiting for upload", after: "Removed from Asset Library",
                        guard: .object([("kind", .string("release-media-abandoned")), ("assetId", .string(asset.id)), ("fileName", .string(asset.fileName)), ("size", .number(Double(asset.size)))]))
        }
        return library
    }

    static func releaseReservation(_ kind: AssetLibrary.Kind, asset: JSONText, poster: String?, library: String) -> JSONText? {
        guard let fileName = asset["fileName"]?.text, case .number(let size)? = asset["size"] else { return nil }
        let attributes: [(String, JSONText)] = [("fileName", .string(fileName)), ("fileSize", .number(size)), ("category", .string(AssetLibrary.Category.listing.rawValue))] + (kind == .video ? poster.map { [("previewFrameTimeCode", JSONText.string($0))] } ?? [] : [])
        return libraryBody(kind.resource, attributes: .object(attributes), relationships: .object([("assetLibrary", Apple.relationship("appAssetLibraries", .string(library)))]))
    }

    static func releasePlacement(_ kind: AssetLibrary.Kind, type: String, group: String, asset: JSONText, locale: JSONText) -> JSONText {
        libraryBody("appAssetLibraryPlacements", attributes: .object([("placementType", .string(type)), ("placementGroup", .string(group))]),
                    relationships: .object([(kind.rawValue, Apple.relationship(kind.resource, asset)), ("appStoreVersionLocalization", Apple.relationship("appStoreVersionLocalizations", locale))]))
    }

    static func releaseOrdering(group: String, placements: [JSONText], locale: JSONText) -> JSONText {
        libraryBody("appAssetLibraryPlacementOrderingRequests", attributes: .object([("placementGroup", .string(group))]),
                    relationships: .object([("orderedPlacements", .object([("data", .array(placements.map { .object([("type", .string("appAssetLibraryPlacements")), ("id", $0)]) }))])),
                                            ("appStoreVersionLocalization", Apple.relationship("appStoreVersionLocalizations", locale))]))
    }

    /// One language and display size: upload missing files once, remove unwanted placements, add new ones and set the order.
    func planPlacements(_ planner: Planner, media: ReleaseMediaPlan, remoteLocale: JSONText, localeName: String, kind: AssetLibrary.Kind, displayType: String, group stored: String?, items: [ReleaseMediaPlan.Item], related: [ReleaseMediaPlan.Item], revisionId: String) async throws {
        let request = planner.request, reader = libraryReader(planner), type = ReleaseMedia.placementType(kind)
        let noun = kind == .image ? "screenshot" : "app preview", plural = kind == .image ? "screenshots" : "app previews"
        if stored == nil && items.isEmpty && related.isEmpty { return }
        let library = try await releaseMediaLibrary(planner, media: media)
        var all: [AssetLibrary.Placement] = []
        if let localeId = remoteLocale.text {
            if let cached = media.placements[localeId] { all = cached } else {
                all = try await reader.placements(target: .init(id: localeId, name: localeName, platform: media.platform, state: "", surface: .versions)); media.placements[localeId] = all
            }
        }
        let group: String
        if let stored { group = stored } else {
            // The selected files decide the group. With nothing selected, the set's other files or their current placements identify it.
            let sized = items.isEmpty ? related.filter { $0.width > 0 && $0.height > 0 } : items
            var candidates = sized.isEmpty ? [] : ReleaseMedia.groups(library.catalog, kind: kind, platform: media.platform, files: sized.map { ($0.width, $0.height, $0.ext) })
            if items.isEmpty && candidates.isEmpty {
                for placement in all where placement.type == type && !candidates.contains(placement.group) && related.contains(where: { $0.originalId == placement.id || $0.assetId == placement.assetId }) { candidates.append(placement.group) }
            }
            if items.isEmpty && candidates.count != 1 { return }
            guard candidates.count == 1 else {
                throw PublishFailure.invalid(candidates.isEmpty ? ReleaseMedia.unplaced(library.catalog, kind: kind, platform: media.platform, displayType: displayType, localeName: localeName, files: sized.map { ($0.fileName, $0.width, $0.height, $0.ext) })
                                             : "Several App Store placement groups accept the selected \(StoreLocales.displayTypeName(displayType)) \(plural) for \(localeName): \(candidates.map(ReleaseMedia.label).joined(separator: ", ")). Place them from Asset Library instead.")
            }
            group = candidates[0]
        }
        guard let slot = library.catalog.slots(surface: .versions, platform: media.platform.isEmpty ? nil : media.platform, category: AssetLibrary.Category.listing.rawValue).first(where: { $0.type == type && $0.group == group }) else {
            throw PublishFailure.invalid("Apple's current specifications have no \(plural) placement for \(ReleaseMedia.label(group)).")
        }
        let current = all.filter { $0.type == type && $0.group == group }
        if current.isEmpty && items.isEmpty { return }
        if current.isEmpty, let localeId = remoteLocale.text {
            // Apple has not moved this language's media to placements: Storebench reads the deprecated sets but never changes them.
            let setType = kind == .image ? "appScreenshotSets" : "appPreviewSets", field = kind == .image ? "screenshotDisplayType" : "previewType"
            for set in try await planner.list("/v1/appStoreVersionLocalizations/\(localeId)/\(setType)?limit=200") where set.type == setType && TextSemantics.same(set.attributes?[field]?.string, displayType) {
                guard AppOverviewMaterial.identifier(set.id), try await planner.list("/v1/\(setType)/\(set.id)/\(kind == .image ? "appScreenshots" : "appPreviews")?limit=200").isEmpty else {
                    throw PublishFailure.invalid("App Store Connect still lists \(displayType) \(plural) for \(localeName) outside Asset Library. Storebench does not change those deprecated sets. Remove them in App Store Connect, then prepare a new review.")
                }
            }
        }
        let others = all.filter { $0.type == type && slot.limitGroups.contains($0.group) && $0.group != group }.count
        guard others + items.count <= slot.limit else { throw PublishFailure.invalid("Apple allows up to \(slot.limit) \(plural) for \(ReleaseMedia.label(group)) in \(localeName).") }

        var kept = Set<String>()
        let inLibrary = items.map { Self.libraryAsset($0, kind: kind, library: library) }
        let matched = items.enumerated().map { index, item -> (item: ReleaseMediaPlan.Item, placement: AssetLibrary.Placement?) in
            let known = inLibrary[index]
            let placement = current.first { !kept.contains($0.id) && ($0.id == item.originalId || known != nil && $0.assetId == known) }
            if let placement { kept.insert(placement.id); planner.settle(item.fileName) }
            return (item, placement)
        }
        func name(_ placement: AssetLibrary.Placement) -> String { library.assets[placement.assetId]?.name ?? placement.assetId }
        var assets: [Int: JSONText] = [:]
        // Apple processes files in parallel, so every file is uploaded before the review waits for any of them.
        var verifications: [(id: JSONText, fileName: String, group: String?)] = []
        for (index, entry) in matched.enumerated() where entry.placement == nil {
            let item = entry.item, key = kind.rawValue + ":" + item.hash
            if let id = inLibrary[index], let asset = library.assets[id], asset.kind == kind, asset.ready, asset.category == AssetLibrary.Category.listing.rawValue, slot.specs.contains(asset.specId ?? "") {
                // An upload alone has nothing to do for a file Apple already holds; a Save still adds it to the version below.
                if media.uploadOnly { planner.settle(item.fileName) }
                assets[index] = .string(id); continue
            }
            // An earlier Save uploaded this file and Apple is still processing it: wait for it instead of uploading it again.
            if let id = inLibrary[index], let asset = library.assets[id], asset.kind == kind, asset.state == "UPLOAD_COMPLETE", asset.category == AssetLibrary.Category.listing.rawValue {
                verifications.append((.string(id), item.fileName, nil)); media.reserved[key] = .string(id); assets[index] = .string(id); continue
            }
            if let ref = media.reserved[key] { assets[index] = ref; continue }
            let described = try describeAsset(revisionId: revisionId, hash: item.hash, storage: item.storage, ext: item.ext, fileName: item.fileName, accountId: request.accountId, appId: request.appId)
            guard let body = Self.releaseReservation(kind, asset: described, poster: item.poster, library: library.id), case .number(let size)? = described["size"] else { throw PublishFailure.invalid("Invalid publishing asset.") }
            let uploadGuard = JSONText.object([("kind", .string("release-media-upload")), ("asset", described)])
            let reservation = planner.add(.api, method: "POST", path: [.string(kind.resource)], label: "Upload \(item.fileName) · \(localeName)", detail: "\(ReleaseMedia.label(group)) · \(String(format: "%.2f", size / 1_000_000)) MB · saved once in Asset Library",
                                          body: body, guard: .object([("kind", .string("release-media-reserve")), ("asset", described), ("libraryId", .string(library.id)), ("poster", item.poster.map(JSONText.string) ?? .null)]))
            planner.steps[planner.steps.count - 1].group = reservation
            let id = Apple.ref(reservation)
            planner.add(.upload, path: [.string(kind.resource), id], label: "Upload \(item.fileName)", detail: "\(localeName) · \(ReleaseMedia.label(group))", asset: described, guard: uploadGuard, group: reservation)
            planner.add(.api, method: "PATCH", path: [.string(kind.resource), id], label: "Complete upload · \(item.fileName)", detail: "Ask Apple to process the uploaded file.",
                        body: Self.libraryBody(kind.resource, id: id, attributes: .object([("uploaded", .bool(true))])), guard: uploadGuard, group: reservation)
            verifications.append((id, item.fileName, reservation))
            media.reserved[key] = id; assets[index] = id
        }
        if media.uploadOnly { return }
        for verification in verifications {
            planner.add(.verify, path: [.string(kind.resource), verification.id], label: "Verify \(verification.fileName)", detail: "Wait for Apple to finish processing the file for \(ReleaseMedia.label(group)).",
                        guard: .object([("kind", .string("asset-library-processed")), ("specIds", .array(slot.specs.map(JSONText.string))), ("fileName", .string(verification.fileName))]), group: verification.group)
        }
        // Removal takes the file off this version only; it stays in Asset Library.
        for placement in current where !kept.contains(placement.id) {
            planner.add(.api, method: "DELETE", path: [.string("appAssetLibraryPlacements"), .string(placement.id)], label: "Remove \(noun) · \(localeName)", detail: "\(ReleaseMedia.label(group)) · \(name(placement))",
                        before: name(placement), after: "Removed from this version. The file stays in Asset Library.",
                        guard: .object([("kind", .string("release-media-delete")), ("localizationId", remoteLocale), ("placementId", .string(placement.id)), ("placementType", .string(type)), ("placementGroup", .string(group))]))
        }
        if kind == .video {
            for (index, entry) in matched.enumerated() {
                guard let poster = entry.item.poster, let id = entry.placement?.assetId ?? assets[index]?.text, let asset = library.assets[id], asset.value["attributes"]?["previewFrameTimeCode"]?.text != poster else { continue }
                guard asset.ready, asset.state != "APPROVED" else { throw PublishFailure.invalid("Apple locks the poster frame of an approved app preview. Upload \(entry.item.fileName) again to use another poster frame.") }
                guard try await reader.uses(asset).count <= 1 else { throw PublishFailure.invalid("\(entry.item.fileName) is also placed elsewhere, so its poster frame is shared. Change it in Asset Library.") }
                var change = AssetLibrary.Change(action: .poster); change.kind = .video; change.assetId = asset.id; change.timeCode = poster
                planner.add(.api, method: "PATCH", path: [.string(kind.resource), .string(asset.id)], label: "Update poster frame · \(localeName)", detail: entry.item.fileName,
                            before: asset.value["attributes"]?["previewFrameTimeCode"]?.text ?? "Apple default", after: poster,
                            body: Self.libraryBody(kind.resource, id: .string(asset.id), attributes: .object([("previewFrameTimeCode", .string(poster))])),
                            guard: .object([("kind", .string("asset-library-asset")), ("change", try change.validated().json), ("digest", .string(Self.libraryAssetDigest(asset)))]))
            }
        }
        var final: [JSONText] = []
        for (index, entry) in matched.enumerated() {
            if let placement = entry.placement { final.append(.string(placement.id)); continue }
            guard let asset = assets[index] else { continue }
            final.append(Apple.ref(planner.add(.api, method: "POST", path: [.string("appAssetLibraryPlacements")], label: "Add \(noun) · \(localeName)", detail: ReleaseMedia.label(group), before: "Not on this version", after: entry.item.fileName,
                                               body: Self.releasePlacement(kind, type: type, group: group, asset: asset, locale: remoteLocale),
                                               guard: .object([("kind", .string("release-media-placement")), ("mediaKind", .string(kind.rawValue)), ("placementType", .string(type)), ("placementGroup", .string(group))]))))
        }
        // Ordering covers the whole group in this language, including placements of the other media type.
        let localeKey = remoteLocale.stringify()
        media.order[localeKey, default: [:]][type] = final
        var types = [ReleaseMedia.screenshot, ReleaseMedia.preview]
        for placement in all where placement.group == group && !types.contains(placement.type) { types.append(placement.type) }
        let ordered = types.flatMap { other in other == type ? final : media.order[localeKey]?[other] ?? all.filter { $0.type == other && $0.group == group }.map { .string($0.id) } }
        let existing = all.filter { $0.group == group && (kept.contains($0.id) || $0.type != type) }.map { JSONText.string($0.id) }
        if ordered.count > 1 && ordered != existing {
            planner.add(.api, method: "POST", path: [.string("appAssetLibraryPlacementOrderingRequests")], label: "Set \(plural) order · \(localeName) · \(ReleaseMedia.label(group))",
                        detail: "\(final.count) \(plural) in the saved local order.", before: current.map(name).joined(separator: "\n"), after: items.map(\.fileName).joined(separator: "\n"),
                        body: Self.releaseOrdering(group: group, placements: ordered, locale: remoteLocale), guard: .object([("kind", .string("release-media-order")), ("placementGroup", .string(group))]))
        }
    }

    /// Streams a reviewed file to the library reservation created earlier in the same approved review.
    /// `reserved` holds the upload operations from the reservation's creation response, as Apple documents them. A later read
    /// supplies them only when that response is not available, for example after a restart.
    func uploadReleaseMedia(path: String, step: PublishStep, reserved operations: JSONValue? = nil, accountId: String, appId: String, client: AppStoreConnectClient, grant: PublishGrant) async throws {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 3, let kind = AssetLibrary.Kind.allCases.first(where: { $0.resource == parts[1] }), let asset = step.asset, step.guardValue?["asset"] == asset else { throw PublishFailure.conflict }
        let reserved = try await libraryReader(appId: appId, client: client).asset(parts[2], kind: kind)
        guard reserved.state == "AWAITING_UPLOAD", reserved.fileName == asset["fileName"]?.text, asset["size"] == .number(Double(reserved.size)), let resource = try await client.get(path).first, resource.id == reserved.id else { throw PublishFailure.conflict }
        try await uploadAsset(asset, operations: operations ?? resource.attributes?["uploadOperations"], accountId: accountId, appId: appId, client: client, grant: grant)
    }

    /// The placement Apple already made for a reviewed "Add screenshot" or "Add app preview" step, for a write whose answer was lost.
    func placedReleaseMedia(body: JSONText?, guardValue: JSONText?, appId: String, client: AppStoreConnectClient) async throws -> String? {
        let relationships = body?["data"]?["relationships"]
        guard guardValue?["kind"]?.text == "release-media-placement", let type = guardValue?["placementType"]?.text, let group = guardValue?["placementGroup"]?.text,
              let kind = guardValue?["mediaKind"]?.text.flatMap(AssetLibrary.Kind.init), let asset = relationships?[kind.rawValue]?["data"]?["id"]?.text,
              let locale = relationships?["appStoreVersionLocalization"]?["data"]?["id"]?.text else { return nil }
        let target = AssetLibrary.Target(id: locale, name: "", platform: "", state: "", surface: .versions)
        return try await libraryReader(appId: appId, client: client).placements(target: target).first { $0.assetId == asset && $0.type == type && $0.group == group }?.id
    }

    /// Fresh ownership, state, limit and body checks immediately before each approved version media write.
    func verifyReleaseMediaWrite(method: String, parts: [String], body: JSONText?, guardValue: JSONText, appId: String, client: AppStoreConnectClient) async throws {
        let reader = libraryReader(appId: appId, client: client), account = client.token.account.id, root = parts.first ?? "", data = body?["data"], checked = OwnershipCache()
        func target(_ id: String?) async throws -> AssetLibrary.Target {
            guard let id else { throw PublishFailure.write("Unsupported App Store media change.") }
            let locale = try await ownedResource("appStoreVersionLocalizations", id, appId: appId, client: client, checked: checked)
            guard let owner = checked.owner(locale, "appStoreVersion"), owner.type == "appStoreVersions" else { throw PublishFailure.write("Apple publishing resource has no approved app owner.") }
            let version = try await ownedResource(owner.type, owner.id, appId: appId, client: client, checked: checked)
            guard Apple.editable.contains(Apple.state(version)) else { throw PublishFailure.write("This Apple version is no longer editable. Prepare a new review.") }
            return .init(id: id, name: "", platform: version.attributes?["platform"]?.string ?? "", state: Apple.state(version), surface: .versions)
        }
        func relation(_ name: String) -> (type: String, id: String)? {
            guard let item = data?["relationships"]?[name]?["data"], let type = item["type"]?.text, let id = item["id"]?.text else { return nil }
            return (type, id)
        }
        let kind = AssetLibrary.Kind.allCases.first { $0.resource == root }
        switch guardValue["kind"]?.text {
        case "release-media-reserve":
            guard method == "POST", parts.count == 1, let kind, let asset = guardValue["asset"], let hash = asset["hash"]?.text, let storage = asset["storage"]?.text, (storage == "preview") == (kind == .video),
                  let ext = asset["extension"]?.text, let fileName = asset["fileName"]?.text, let revisionId = asset["revisionId"]?.text, let library = guardValue["libraryId"]?.text,
                  body == Self.releaseReservation(kind, asset: asset, poster: guardValue["poster"]?.text, library: library) else { throw PublishFailure.write("Unsupported Asset Library reservation.") }
            guard try describeAsset(revisionId: revisionId, hash: hash, storage: storage, ext: ext, fileName: fileName, accountId: account, appId: appId) == asset, try await reader.library() == library else { throw PublishFailure.conflict }
        case "release-media-upload":
            guard method == "PATCH", parts.count == 2, let kind, let asset = guardValue["asset"], body == Self.libraryBody(root, id: .string(parts[1]), attributes: .object([("uploaded", .bool(true))])) else { throw PublishFailure.write("Unsupported Asset Library upload commit.") }
            let reserved = try await reader.asset(parts[1], kind: kind)
            guard reserved.state == "AWAITING_UPLOAD", reserved.fileName == asset["fileName"]?.text, asset["size"] == .number(Double(reserved.size)) else { throw PublishFailure.conflict }
        case "release-media-abandoned":
            guard method == "DELETE", parts.count == 2, let kind, body == nil, parts[1] == guardValue["assetId"]?.text else { throw PublishFailure.write("Unsupported Asset Library cleanup.") }
            let asset = try await reader.asset(parts[1], kind: kind)
            guard asset.state == "AWAITING_UPLOAD", asset.fileName == guardValue["fileName"]?.text, guardValue["size"] == .number(Double(asset.size)),
                  try releaseReservations(accountId: account, appId: appId).contains(asset.id) else { throw PublishFailure.conflict }
        case "release-media-delete":
            guard method == "DELETE", parts.count == 2, root == "appAssetLibraryPlacements", body == nil, parts[1] == guardValue["placementId"]?.text else { throw PublishFailure.write("Unsupported App Store media removal.") }
            let place = try await target(guardValue["localizationId"]?.text)
            guard try await reader.placements(target: place).contains(where: { $0.id == parts[1] && $0.type == guardValue["placementType"]?.text && $0.group == guardValue["placementGroup"]?.text }) else { throw PublishFailure.conflict }
        case "release-media-placement":
            guard method == "POST", parts.count == 1, root == "appAssetLibraryPlacements", let type = guardValue["placementType"]?.text, let group = guardValue["placementGroup"]?.text,
                  let kind = guardValue["mediaKind"]?.text.flatMap(AssetLibrary.Kind.init), let link = relation(kind.rawValue), link.type == kind.resource,
                  let locale = relation("appStoreVersionLocalization"), locale.type == "appStoreVersionLocalizations",
                  body == Self.releasePlacement(kind, type: type, group: group, asset: .string(link.id), locale: .string(locale.id)) else { throw PublishFailure.write("Unsupported App Store media placement.") }
            let place = try await target(locale.id), asset = try await reader.asset(link.id, kind: kind), catalog = try await reader.catalog()
            guard asset.ready, let spec = asset.specId, let slot = catalog.slots(surface: .versions, platform: place.platform.isEmpty ? nil : place.platform, category: asset.category, specId: spec).first(where: { $0.type == type && $0.group == group }) else {
                throw AssetLibrary.failure("Apple processed this file for a different display size. Refresh Asset Library and prepare a new review.")
            }
            let placements = try await reader.placements(target: place)
            guard placements.filter({ $0.type == type && slot.limitGroups.contains($0.group) }).count < slot.limit, !placements.contains(where: { $0.type == type && $0.group == group && $0.assetId == asset.id }) else { throw PublishFailure.conflict }
        case "release-media-order":
            guard method == "POST", parts.count == 1, root == "appAssetLibraryPlacementOrderingRequests", let group = guardValue["placementGroup"]?.text, let locale = relation("appStoreVersionLocalization"),
                  locale.type == "appStoreVersionLocalizations", case .array(let entries)? = data?["relationships"]?["orderedPlacements"]?["data"] else { throw PublishFailure.write("Unsupported App Store media order.") }
            let ids = entries.compactMap { $0["id"]?.text }
            guard ids.count == entries.count, Set(ids).count == ids.count, body == Self.releaseOrdering(group: group, placements: ids.map(JSONText.string), locale: .string(locale.id)) else { throw PublishFailure.write("Unsupported App Store media order.") }
            guard Set(try await reader.placements(target: target(locale.id)).filter { $0.group == group }.map(\.id)) == Set(ids) else { throw PublishFailure.conflict }
        default: throw PublishFailure.write("Unsupported App Store media change.")
        }
    }
}
