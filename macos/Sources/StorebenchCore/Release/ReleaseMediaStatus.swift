import Foundation

/// A complete scoped read can establish delivery; only unchanged imported fingerprints establish equality.
public enum ReleaseMediaStatus {
    public typealias Resource = AppStoreConnectClient.Resource
    public struct Item: Sendable {
        public let id: String, delivery: String, fingerprint: String?
    }
    public struct MediaSet: Sendable {
        /// The deprecated display type, or the placement group for Asset Library placements.
        public let displayType: String, group: String?, items: [Item]
        /// A deprecated screenshot or preview set as Apple returns it.
        public init(displayType: String, items: [Resource]) {
            self.displayType = displayType; group = nil
            self.items = items.map { Item(id: $0.id, delivery: Apple.delivery($0), fingerprint: try? WorkspaceSession.screenshotAsset($0).sourceFingerprint) }
        }
        init(group: String, items: [Item]) { displayType = group; self.group = group; self.items = items }
    }
    public struct Snapshot: Sendable {
        public let screenshots, previews: [MediaSet]
        /// Apple lists no placements for this language, so its media was read from the deprecated sets.
        public let legacy: Bool
        let catalog: AssetLibrary.Catalog?, platform: String
        public init(screenshots: [MediaSet], previews: [MediaSet]) { self.init(screenshots: screenshots, previews: previews, legacy: false, catalog: nil, platform: "") }
        init(screenshots: [MediaSet], previews: [MediaSet], legacy: Bool, catalog: AssetLibrary.Catalog?, platform: String) {
            self.screenshots = screenshots; self.previews = previews; self.legacy = legacy; self.catalog = catalog; self.platform = platform
        }
    }
    public struct Status: Sendable {
        public let state: ReleaseReadiness.State, detail: String
        /// Selected media Apple does not have yet, such as "3 Mac screenshots".
        public var missing: [String] = []
        /// Selected media whose sizes no placement in Apple's current specifications accepts, with the sizes Apple takes.
        public var rejected: [String] = []
        public var json: JSONText { .object([("state", .string(state.rawValue)), ("detail", .string(detail))]) }
        /// The status with what Apple lacks, as the release check reads it.
        public var record: JSONText {
            var fields: [(String, JSONText)] = [("state", .string(state.rawValue)), ("detail", .string(detail))]
            if !missing.isEmpty { fields.append(("missing", .array(missing.map(JSONText.string)))) }
            if !rejected.isEmpty { fields.append(("rejected", .array(rejected.map(JSONText.string)))) }
            return .object(fields)
        }
    }
    typealias Dimensions = (width: Int, height: Int, ext: String?)
    static func dimensions(_ items: [JSONText]) -> [Dimensions] {
        items.compactMap { item in AssetLibrary.integer(item["width"]).flatMap { width in AssetLibrary.integer(item["height"]).map { (width, $0, nil) } } }
    }
    /// A local display size matches Apple's media by its imported placement group, by Apple's catalog for its file sizes, or by the deprecated display type.
    static func matches(_ set: MediaSet, type: String?, group: String?, files: [Dimensions], kind: AssetLibrary.Kind, apple: Snapshot) -> Bool {
        guard let setGroup = set.group else { return TextSemantics.same(set.displayType, type) }
        if let group { return setGroup == group }
        guard let catalog = apple.catalog, !files.isEmpty else { return false }
        return ReleaseMedia.groups(catalog, kind: kind, platform: apple.platform, files: files).contains(setGroup)
    }
    public static func status(locale: JSONText, draft: JSONText, apple: Snapshot?) -> Status {
        guard let apple else { return .init(state: .unknown, detail: "Apple screenshot or preview sets could not be read completely. Refresh before drawing a conclusion.") }
        let expected: [(type: String, group: String?, items: [JSONText])] = WorkspaceSession.items(locale["screenshotSets"]).compactMap { set in
            let id = set["id"]?.text ?? "", layout = draft["screenshotLayouts"]?[id]
            let all = WorkspaceSession.items(set["screenshots"]) + WorkspaceSession.uploads(draft).filter { TextSemantics.same($0.1["setId"]?.text, id) }.map(\.1)
            var positions: [Data: Int] = [:]
            for (index, item) in WorkspaceSession.strings(layout?["order"]).enumerated() { positions[Data(item.utf8)] = index }
            let hidden = Set(WorkspaceSession.strings(layout?["hidden"]).map { Data($0.utf8) })
            let items = all.enumerated().sorted { left, right in
                let lhs = positions[Data((left.element["id"]?.text ?? "").utf8)] ?? Int.max, rhs = positions[Data((right.element["id"]?.text ?? "").utf8)] ?? Int.max
                return lhs == rhs ? left.offset < right.offset : lhs < rhs
            }.map(\.element).filter { !hidden.contains(Data(($0["id"]?.text ?? "").utf8)) }
            return items.isEmpty ? nil : (set["displayType"]?.text ?? "", set["placementGroup"]?.text, items)
        }
        let videos: [JSONText]
        if case .object(let entries)? = draft["previewUploads"] {
            videos = entries.map(\.1).filter { item in
                guard TextSemantics.same(item["localizationId"]?.text, locale["id"]?.text) else { return false }
                let key = (locale["id"]?.text ?? "") + ":" + (item["previewType"]?.text ?? "")
                return !WorkspaceSession.strings(draft["previewLayouts"]?[key]?["hidden"]).contains { TextSemantics.same($0, item["id"]?.text) }
            }
        } else { videos = [] }
        func screenshotSet(_ set: (type: String, group: String?, items: [JSONText])) -> MediaSet? {
            apple.screenshots.first { matches($0, type: set.type, group: set.group, files: dimensions(set.items), kind: .image, apple: apple) && !$0.items.isEmpty }
        }
        let count = expected.reduce(0) { $0 + $1.items.count }
        if count == 0 { return .init(state: .blocked, detail: "No screenshots are selected locally for this language. Select material before checking the Apple version.") }
        let absentSets = expected.filter { screenshotSet($0) == nil }
        let absentVideos = videos.filter { video in !apple.previews.contains { matches($0, type: video["previewType"]?.text, group: nil, files: dimensions([video]), kind: .video, apple: apple) && !$0.items.isEmpty } }
        if !absentSets.isEmpty || !absentVideos.isEmpty {
            var status = Status(state: .blocked, detail: "A selected screenshot or preview display size is missing at Apple. Review the media upload before submission.")
            for set in absentSets {
                let name = set.type.isEmpty ? ReleaseMedia.label(set.group ?? "") : StoreLocales.displayTypeName(set.type), files = dimensions(set.items)
                status.missing.append("\(set.items.count) \(name) screenshot\(set.items.count == 1 ? "" : "s")")
                if let catalog = apple.catalog, !files.isEmpty, ReleaseMedia.groups(catalog, kind: .image, platform: apple.platform, files: files).isEmpty {
                    status.rejected.append(ReleaseMedia.sizes(name: name, files: files, accepted: ReleaseMedia.acceptedSizes(catalog, kind: .image, platform: apple.platform)))
                }
            }
            if !absentVideos.isEmpty { status.missing.append("\(absentVideos.count) app preview\(absentVideos.count == 1 ? "" : "s")") }
            return status
        }
        let remote = (apple.screenshots + apple.previews).flatMap(\.items)
        if remote.contains(where: { $0.delivery == "FAILED" }) { return .init(state: .blocked, detail: "Apple reports a failed screenshot or preview. Review the affected media set.") }
        if remote.contains(where: { !$0.delivery.isEmpty && $0.delivery != "COMPLETE" }) { return .init(state: .waiting, detail: "Apple is still processing a screenshot or preview. Check again after processing finishes." ) }
        if remote.contains(where: { $0.delivery.isEmpty }) { return .init(state: .unknown, detail: "Apple did not provide a delivery state for every screenshot and preview.") }
        if apple.legacy { return .init(state: .review, detail: "Apple lists this language's media only in the deprecated screenshot and preview sets, not as Asset Library placements. Check the media in App Store Connect before submission.") }
        let same = expected.count == apple.screenshots.filter { !$0.items.isEmpty }.count && expected.allSatisfy { set in
            guard let saved = screenshotSet(set), saved.items.count == set.items.count else { return false }
            return zip(set.items, saved.items).allSatisfy { image, item in
                guard TextSemantics.same(image["id"]?.text, item.id), let fingerprint = image["sourceFingerprint"]?.text, !fingerprint.isEmpty, let observed = item.fingerprint else { return false }
                return TextSemantics.same(fingerprint, observed)
            }
        }
        if same && videos.isEmpty && !apple.previews.contains(where: { !$0.items.isEmpty }) {
            return .init(state: .ready, detail: "\(count) ordered screenshot\(count == 1 ? "" : "s") match the saved imported assets at Apple; no previews are selected or present.")
        }
        return .init(state: .review, detail: "Apple has complete media for the selected display sizes, but the exact local files, order or previews have not been proven equal. Compare them in the Publish review.")
    }
    /// Asset Library placements first; the deprecated sets are read only when Apple lists no placements for this language.
    public static func read(localizationId: String, platform: String = "", client: AppStoreConnectClient) async throws -> Snapshot {
        guard AppOverviewMaterial.identifier(localizationId) else { throw ReleaseReadiness.Failure.invalid }
        var placed: (data: [Resource], included: [Resource])?
        do { placed = try await client.listWithIncluded("/v1/appStoreVersionLocalizations/\(localizationId)/placements?sort=placementGroupPosition&include=image,video&limit=200") }
        catch AppStoreConnectClient.Failure.status(let code) where [403, 404].contains(code) { placed = nil }
        if let placed, !placed.data.isEmpty {
            var ids = Set<Data>()
            guard placed.data.count <= 2000, placed.data.allSatisfy({ ids.insert(Data($0.id.utf8)).inserted && ($0.relationships?["appStoreVersionLocalization"] == nil || Apple.owned($0, "appStoreVersionLocalization", "appStoreVersionLocalizations", localizationId)) }),
                  let placements = try? placed.data.map(AssetLibrary.Placement.init) else { throw ReleaseReadiness.Failure.invalid }
            var resources: [String: Resource] = [:], assets: [String: AssetLibrary.Asset] = [:]
            for resource in placed.included {
                guard let kind = AssetLibrary.Kind.allCases.first(where: { $0.resource == resource.type }) else { continue }
                guard resources[resource.id] == nil, let asset = try? AssetLibrary.Asset(resource, kind: kind) else { throw ReleaseReadiness.Failure.invalid }
                resources[resource.id] = resource; assets[resource.id] = asset
            }
            let catalog = try? await AssetLibrary.Catalog(client.list("/v1/appAssetLibraryRefData"))
            func sets(_ type: String) -> [MediaSet] {
                var groups: [String] = []
                for placement in placements where placement.type == type && !groups.contains(placement.group) { groups.append(placement.group) }
                return groups.map { group in MediaSet(group: group, items: placements.filter { $0.type == type && $0.group == group }.map { placement in
                    let asset = assets[placement.assetId].flatMap { $0.kind == placement.kind ? $0 : nil }
                    return Item(id: placement.id, delivery: ReleaseMedia.delivery(asset: asset, placement: placement), fingerprint: asset?.kind == .image ? resources[placement.assetId].flatMap { try? WorkspaceSession.screenshotAsset($0).sourceFingerprint } : nil)
                }) }
            }
            try Task.checkCancellation()
            return Snapshot(screenshots: sets(ReleaseMedia.screenshot), previews: sets(ReleaseMedia.preview), legacy: false, catalog: catalog, platform: platform)
        }
        async let screenshots = readLegacy(localizationId: localizationId, screenshots: true, client: client)
        async let previews = readLegacy(localizationId: localizationId, screenshots: false, client: client)
        let (shots, videos) = try await (screenshots, previews)
        return Snapshot(screenshots: shots, previews: videos, legacy: (shots + videos).contains { !$0.items.isEmpty }, catalog: nil, platform: platform)
    }
    /// A read-only view of the deprecated sets for languages Apple has not moved to placements.
    private static func readLegacy(localizationId: String, screenshots: Bool, client: AppStoreConnectClient) async throws -> [MediaSet] {
        let setType = screenshots ? "appScreenshotSets" : "appPreviewSets", itemType = screenshots ? "appScreenshots" : "appPreviews"
        let display = screenshots ? "screenshotDisplayType" : "previewType", owner = screenshots ? "appScreenshotSet" : "appPreviewSet"
        let sets = try await client.list("/v1/appStoreVersionLocalizations/\(localizationId)/\(setType)?limit=200")
        var seen = Set<Data>(), ids = Set<Data>(), result: [MediaSet] = []
        guard sets.count <= 2000 else { throw ReleaseReadiness.Failure.invalid }
        for set in sets {
            try Task.checkCancellation()
            guard set.type == setType, AppOverviewMaterial.identifier(set.id), ids.insert(Data(set.id.utf8)).inserted,
                  Apple.within(set, "appStoreVersionLocalization", "appStoreVersionLocalizations", localizationId), let type = set.attributes?[display]?.string,
                  !type.isEmpty, type.utf16.count <= 80, seen.insert(Data(type.utf8)).inserted else { throw ReleaseReadiness.Failure.invalid }
            let items = try await client.list("/v1/\(setType)/\(set.id)/\(itemType)?limit=200")
            var itemIds = Set<Data>()
            guard items.count <= 2000, items.allSatisfy({ $0.type == itemType && AppOverviewMaterial.identifier($0.id) && itemIds.insert(Data($0.id.utf8)).inserted && Apple.within($0, owner, setType, set.id) }) else { throw ReleaseReadiness.Failure.invalid }
            result.append(.init(displayType: type, items: items))
        }
        try Task.checkCancellation(); return result
    }
}
