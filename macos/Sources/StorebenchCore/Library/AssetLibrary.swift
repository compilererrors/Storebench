import Foundation

/// Apple supplies the specifications and placement policies at runtime.
public enum AssetLibrary {
    public enum Kind: String, Sendable, CaseIterable, Codable { case image, video
        public var resource: String { self == .image ? "appAssetLibraryImages" : "appAssetLibraryVideos" }
    }
    public enum Category: String, Sendable, CaseIterable, Codable { case listing = "APP_SCREENSHOTS_AND_PREVIEWS", creative = "CREATIVE_ASSETS"
        public var label: String { self == .listing ? "Screenshots and app previews" : "Creative Assets" }
    }
    public enum Surface: String, Sendable, CaseIterable {
        case versions = "APP_STORE_VERSIONS", customPages = "CUSTOM_PRODUCT_PAGES", events = "IN_APP_EVENTS", experiments = "PRODUCT_PAGE_OPTIMIZATIONS"
        public var label: String { switch self { case .versions: "App versions"; case .customPages: "Custom product pages"; case .events: "In-app events"; case .experiments: "Product page optimization" } }
        public var relationship: String { switch self { case .versions: "appStoreVersionLocalization"; case .customPages: "appCustomProductPageLocalization"; case .events: "appEventLocalization"; case .experiments: "appStoreVersionExperimentTreatmentLocalization" } }
        public var resource: String { switch self { case .versions: "appStoreVersionLocalizations"; case .customPages: "appCustomProductPageLocalizations"; case .events: "appEventLocalizations"; case .experiments: "appStoreVersionExperimentTreatmentLocalizations" } }
    }
    public struct Asset: Sendable, Identifiable, Equatable, Codable {
        public let id: String, kind: Kind, fileName: String, referenceName: String, category: String, state: String, specId: String?, modified: String?, details: String
        public let size: Int
        public var name: String { referenceName.isEmpty ? fileName : referenceName }
        public var ready: Bool { ["PREPARE_FOR_SUBMISSION", "APPROVED", "ACCEPTED"].contains(state) }
        public let value: JSONText
        public init(_ resource: AppStoreConnectClient.Resource, kind: Kind) throws {
            guard resource.type == kind.resource, validID(resource.id), let attrs = Planner.resource(resource)["attributes"],
                  let name = attrs["fileName"]?.text, let category = attrs["category"]?.text, Category(rawValue: category) != nil,
                  let state = attrs["state"]?.text, let size = integer(attrs["fileSize"]), size > 0 else { throw failure("Apple returned an invalid library asset.") }
            id = resource.id; self.kind = kind; fileName = name; referenceName = attrs["referenceName"]?.text ?? ""; self.category = category; self.state = state; self.size = size
            specId = attrs["specId"]?.text; modified = attrs["lastModifiedDate"]?.text
            details = diagnostics(attrs["stateDetails"]); value = Planner.resource(resource)
        }
    }
    public struct Target: Sendable, Identifiable, Equatable {
        public let id: String, name: String, platform: String, state: String, surface: Surface
        public init(id: String, name: String, platform: String, state: String, surface: Surface) { self.id = id; self.name = name; self.platform = platform; self.state = state; self.surface = surface }
        public var editable: Bool { Apple.editable.contains(state) || state == "DRAFT" }
        public var liveCreative: Bool { surface == .versions && ["READY_FOR_DISTRIBUTION", "READY_FOR_SALE"].contains(state) }
        public func allowsPlacement(_ asset: Asset, slot: Slot) -> Bool {
            editable || liveCreative && asset.state == "APPROVED" && asset.category == Category.creative.rawValue && slot.category == Category.creative.rawValue
        }
    }
    public struct Placement: Sendable, Identifiable, Equatable {
        public let id: String, type: String, group: String, assetId: String, kind: Kind, state: String, details: String
        public let value: JSONText
        public init(_ resource: AppStoreConnectClient.Resource) throws {
            let value = Planner.resource(resource), attrs = value["attributes"]
            let kind: Kind = attrs?["mediaType"]?.text == "IMAGE" ? .image : .video
            guard resource.type == "appAssetLibraryPlacements", validID(resource.id), ["IMAGE", "VIDEO"].contains(attrs?["mediaType"]?.text ?? ""),
                  let type = attrs?["placementType"]?.text, let group = attrs?["placementGroup"]?.text,
                  let owner = Apple.owner(resource, kind.rawValue), owner.type == kind.resource, validID(owner.id) else { throw failure("Apple returned an invalid library placement.") }
            id = resource.id; self.type = type; self.group = group; assetId = owner.id; self.kind = kind; state = attrs?["state"]?.text ?? "Unknown"; details = diagnostics(attrs?["stateDetails"]); self.value = value
        }
    }
    public struct Spec: Sendable, Identifiable, Equatable, Codable {
        public let id: String, kind: Kind, value: JSONText
        public var description: String {
            let d = value["dimensions"]
            func span(_ a: String, _ b: String) -> String { let x = integer(d?[a]) ?? 0, y = integer(d?[b]) ?? 0; return x == y ? String(x) : "\(x)–\(y)" }
            let formats = strings(value["fileExtensions"]).joined(separator: ", ")
            let size = integer(value["maxFileSize"]) ?? 0
            var text = "\(span("minWidth", "maxWidth")) × \(span("minHeight", "maxHeight")) px · \(formats) · up to \(size / 1_048_576) MiB"
            if kind == .image { text += value["alphaAllowed"] == .bool(true) ? " · transparency allowed" : " · no transparency" }
            if kind == .video { text += " · \(value["duration"]?["min"]?.text ?? "?")–\(value["duration"]?["max"]?.text ?? "?")"; if value["audioRequired"] == .bool(true) { text += " · audio required" } }
            return text
        }
        public func accepts(_ file: File) -> Bool {
            guard kind == file.kind, strings(value["fileExtensions"]).map({ $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }).contains(file.ext),
                  let max = integer(value["maxFileSize"]), file.size <= max,
                  let d = value["dimensions"], let minW = integer(d["minWidth"]), let maxW = integer(d["maxWidth"]), let minH = integer(d["minHeight"]), let maxH = integer(d["maxHeight"]),
                  (minW...maxW).contains(file.width), (minH...maxH).contains(file.height) else { return false }
            if let aspect = value["aspectRatio"]?.text {
                let parts = aspect.split(separator: ":").compactMap { Double($0) }
                guard parts.count == 2, parts[1] > 0, abs(Double(file.width) / Double(file.height) - parts[0] / parts[1]) <= 0.001 else { return false }
            }
            if kind == .image { return !file.hasAlpha || value["alphaAllowed"] == .bool(true) }
            guard let seconds = file.duration, let fps = file.frameRate, let duration = value["duration"], let low = durationSeconds(duration["min"]?.text), let high = durationSeconds(duration["max"]?.text),
                  seconds >= low, seconds <= high + 0.05, file.hasAudio || value["audioRequired"] == .bool(false) else { return false }
            return items(value["frameRates"]).contains { range in number(range["minFps"]).map { fps >= $0 } == true && number(range["maxFps"]).map { fps <= $0 + 0.01 } == true }
        }
    }
    public struct Slot: Sendable, Identifiable, Equatable {
        public let type: String, group: String, platform: String, category: String, specs: [String], limit: Int, limitGroups: [String]
        public var id: String { type + ":" + group }
        public var label: String { type.replacingOccurrences(of: "_", with: " ").localizedCapitalized + " · " + group.replacingOccurrences(of: "_", with: " ").localizedCapitalized }
    }
    public struct Catalog: Sendable, Equatable, Codable {
        public let value: JSONText, specs: [Spec]
        public init(_ resources: [AppStoreConnectClient.Resource]) throws {
            guard !resources.isEmpty, resources.allSatisfy({ $0.type == "appAssetLibraryRefData" }) else { throw failure("Apple's asset specifications are unavailable.") }
            var arrays: [(String, JSONText)] = []
            for key in ["features", "placementProfileGroups", "imageSpecs", "videoSpecs", "placementTypes", "displayClasses"] {
                var entries: [JSONText] = []
                for resource in resources {
                    guard case .array(let found)? = Planner.resource(resource)["attributes"]?[key] else { throw failure("Apple's asset specifications are incomplete.") }
                    entries += found
                }
                arrays.append((key, .array(entries)))
            }
            let catalogValue = JSONText.object(arrays)
            value = catalogValue
            specs = try [("imageSpecs", Kind.image), ("videoSpecs", Kind.video)].flatMap { key, kind in
                try items(catalogValue[key]).map { spec in
                    guard let id = spec["specId"]?.text, validID(id), let dimensions = spec["dimensions"],
                          let minW = integer(dimensions["minWidth"]), let maxW = integer(dimensions["maxWidth"]), let minH = integer(dimensions["minHeight"]), let maxH = integer(dimensions["maxHeight"]),
                          minW > 0, minH > 0, maxW >= minW, maxH >= minH, integer(spec["maxFileSize"]) != nil else { throw failure("Apple returned an invalid asset specification.") }
                    return Spec(id: id, kind: kind, value: spec)
                }
            }
            guard Set(specs.map(\.id)).count == specs.count else { throw failure("Apple returned duplicate asset specifications.") }
        }
        public func slots(surface: Surface, platform: String? = nil, category: String? = nil, specId: String? = nil) -> [Slot] {
            guard let feature = items(value["features"]).first(where: { $0["featureId"]?.text == surface.rawValue }) else { return [] }
            return items(feature["placementPolicies"]).flatMap { policy -> [Slot] in
                guard let type = policy["placementType"]?.text, let definition = items(value["placementTypes"]).first(where: { $0["placementTypeId"]?.text == type }) else { return [] }
                let categories = strings(definition["acceptsAssetCategories"])
                return items(definition["specMappings"]).flatMap { mapping -> [Slot] in
                    guard let group = mapping["placementGroupId"]?.text, let profile = items(value["placementProfileGroups"]).first(where: { $0["placementProfileGroupId"]?.text == group }),
                          let groupPlatform = profile["platform"]?.text, platform == nil || AssetLibrary.placementPlatforms(platform!).contains(groupPlatform),
                          let limit = items(policy["groupLimits"]).first(where: { strings($0["groupIds"]).contains(group) }), let count = integer(limit["maxCount"]), count > 0 else { return [] }
                    let specs = strings(mapping["specs"])
                    guard specId == nil || specs.contains(specId!) else { return [] }
                    return categories.filter { category == nil || $0 == category }.map { Slot(type: type, group: group, platform: groupPlatform, category: $0, specs: specs, limit: count, limitGroups: strings(limit["groupIds"])) }
                }
            }
        }
        public func matching(_ file: File) -> [Spec] {
            specs.filter { spec in spec.accepts(file) && items(value["placementTypes"]).contains { type in
                strings(type["acceptsAssetCategories"]).contains(file.category.rawValue) && items(type["specMappings"]).contains { strings($0["specs"]).contains(spec.id) }
            } }
        }
        public func editingTargets(category: Category) -> [ScreenshotEditing.Target] {
            var seen = Set<String>()
            return specs.filter { spec in spec.kind == .image && strings(spec.value["fileExtensions"]).contains(".png") && items(value["placementTypes"]).contains { type in
                strings(type["acceptsAssetCategories"]).contains(category.rawValue) && items(type["specMappings"]).contains { strings($0["specs"]).contains(spec.id) }
            } }.flatMap { spec in
                let d = spec.value["dimensions"]
                return [("minWidth", "minHeight"), ("maxWidth", "maxHeight")].compactMap { w, h -> ScreenshotEditing.Target? in
                    guard let width = integer(d?[w]), let height = integer(d?[h]), width <= ScreenshotEditing.maximumSide, height <= ScreenshotEditing.maximumSide, width * height <= ScreenshotEditing.maximumPixels,
                          seen.insert("\(width)x\(height)").inserted else { return nil }
                    return .init(type: spec.value["shortName"]?.text ?? spec.id, width: width, height: height)
                }
            }
        }
    }
    public struct Snapshot: Sendable, Codable {
        public let libraryId: String, assets: [Asset], catalog: Catalog
    }
    public enum Action: String, Sendable { case upload, rename, archive, restore, delete, poster, place, removePlacement, reorder, submit }
    public struct Change: Sendable, Equatable {
        public var action: Action, kind: Kind = .image, assetId: String?, fileId: String?, name: String?, timeCode: String?
        public var surface: Surface = .versions, targetId: String?, placementType: String?, placementGroup: String?, placementId: String?
        public var orderedIds: [String] = [], assetIds: [String] = [], platform: String?, submissionId: String?
        public var expectedPlacements: String?
        public init(action: Action) { self.action = action }
        var json: JSONText {
            var fields: [(String, JSONText)] = [("action", .string(action.rawValue)), ("kind", .string(kind.rawValue)), ("surface", .string(surface.rawValue)), ("orderedIds", .array(orderedIds.map(JSONText.string))), ("assetIds", .array(assetIds.map(JSONText.string)))]
            for (key, value) in [("assetId", assetId), ("fileId", fileId), ("name", name), ("timeCode", timeCode), ("targetId", targetId), ("placementType", placementType), ("placementGroup", placementGroup), ("placementId", placementId), ("platform", platform), ("submissionId", submissionId), ("expectedPlacements", expectedPlacements)] { if let value { fields.append((key, .string(value))) } }
            return .object(fields)
        }
        init(_ value: JSONText) throws {
            let allowed: Set<String> = ["action", "kind", "surface", "orderedIds", "assetIds", "assetId", "fileId", "name", "timeCode", "targetId", "placementType", "placementGroup", "placementId", "platform", "submissionId", "expectedPlacements"]
            guard case .object(let fields) = value, Set(fields.map(\.0)).count == fields.count, Set(fields.map(\.0)).isSubset(of: allowed),
                  fields.allSatisfy({ pair in ["orderedIds", "assetIds"].contains(pair.0) || pair.1.text != nil }),
                  case .array(let order)? = value["orderedIds"], order.allSatisfy({ $0.text != nil }), case .array(let assets)? = value["assetIds"], assets.allSatisfy({ $0.text != nil }) else { throw failure("Invalid Asset Library selection.") }
            guard let action = value["action"]?.text.flatMap(Action.init), let kind = value["kind"]?.text.flatMap(Kind.init), let surface = value["surface"]?.text.flatMap(Surface.init) else { throw failure("Choose an Asset Library action.") }
            self.init(action: action); self.kind = kind; self.surface = surface
            assetId = value["assetId"]?.text; fileId = value["fileId"]?.text; name = value["name"]?.text; timeCode = value["timeCode"]?.text; targetId = value["targetId"]?.text
            placementType = value["placementType"]?.text; placementGroup = value["placementGroup"]?.text; placementId = value["placementId"]?.text; platform = value["platform"]?.text; submissionId = value["submissionId"]?.text
            orderedIds = strings(value["orderedIds"]); assetIds = strings(value["assetIds"])
            expectedPlacements = value["expectedPlacements"]?.text
            _ = try validated()
        }
        func validated() throws -> Self {
            guard [assetId, fileId, targetId, placementId, submissionId, placementType, placementGroup].compactMap({ $0 }).allSatisfy(validID), orderedIds.allSatisfy(validID), assetIds.allSatisfy(validID),
                  Set(orderedIds).count == orderedIds.count, orderedIds.count <= 50, Set(assetIds).count == assetIds.count, assetIds.count <= 50 else { throw failure("Invalid Asset Library selection.") }
            if let name { _ = try referenceName(name) }
            if let expectedPlacements { guard action == .reorder, expectedPlacements.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw failure("The placement baseline is invalid.") } }
            if let timeCode { guard timeCode.range(of: "^[0-9]{2}:[0-5][0-9]:[0-5][0-9]:[0-9]{2}$", options: .regularExpression) != nil else { throw failure("Use HH:MM:SS:FF for the preview frame.") } }
            switch action {
            case .upload: guard fileId != nil else { throw failure("Choose a saved local asset.") }
            case .rename: guard assetId != nil, name != nil else { throw failure("Choose an asset and a reference name.") }
            case .archive, .restore, .delete: guard assetId != nil else { throw failure("Choose one library asset.") }
            case .poster: guard assetId != nil, kind == .video, timeCode != nil else { throw failure("Choose a video and preview frame.") }
            case .place: guard assetId != nil, targetId != nil, placementType != nil, placementGroup != nil else { throw failure("Choose an asset, destination and placement.") }
            case .removePlacement: guard targetId != nil, placementId != nil else { throw failure("Choose a placement and destination.") }
            case .reorder: guard surface != .events, targetId != nil, placementGroup != nil, !orderedIds.isEmpty else { throw failure("Choose a complete ordered placement group.") }
            case .submit: guard !assetIds.isEmpty, ["IOS", "MAC_OS", "TV_OS", "VISION_OS"].contains(platform ?? "") else { throw failure("Choose assets and a review platform.") }
            }
            return self
        }
    }
    static func failure(_ message: String) -> PublishFailure { .invalid(message) }
    /// App Store versions name their platform IOS, MAC_OS, TV_OS or VISION_OS, while Apple's placement profiles name the
    /// store that shows the media (AppAssetLibraryPlacementPlatform), such as MAC_APP_STORE. An iOS version also carries its
    /// iPad, Apple Watch and iMessage media, and a profile for ANY platform applies to every version.
    public static func placementPlatforms(_ versionPlatform: String) -> Set<String> {
        let stores: [String: Set<String>] = ["IOS": ["IPHONE_APP_STORE", "IPAD_APP_STORE", "WATCH_APP_STORE", "IMESSAGE_APP_STORE"], "MAC_OS": ["MAC_APP_STORE"], "TV_OS": ["TV_APP_STORE"], "VISION_OS": ["VISION_PRO_APP_STORE"]]
        return stores[versionPlatform, default: []].union([versionPlatform, "ANY"])
    }
    static func validID(_ text: String) -> Bool { text.range(of: "^[A-Za-z0-9_-]{1,256}$", options: .regularExpression) != nil }
    static func items(_ value: JSONText?) -> [JSONText] { if case .array(let xs)? = value { return xs }; return [] }
    static func strings(_ value: JSONText?) -> [String] { items(value).compactMap(\.text) }
    static func number(_ value: JSONText?) -> Double? { if case .number(let n)? = value, n.isFinite { return n }; return nil }
    static func integer(_ value: JSONText?) -> Int? { number(value).flatMap { $0 >= 0 && $0 <= 9_007_199_254_740_991 ? Int(exactly: $0) : nil } }
    static func durationSeconds(_ value: String?) -> Double? {
        guard let value, let regex = try? NSRegularExpression(pattern: "^PT(?:(\\d+(?:\\.\\d+)?)H)?(?:(\\d+(?:\\.\\d+)?)M)?(?:(\\d+(?:\\.\\d+)?)S)?$"), let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)), value != "PT" else { return nil }
        return [3600.0, 60, 1].enumerated().reduce(0) { sum, item in sum + (Range(match.range(at: item.offset + 1), in: value).flatMap { Double(value[$0]) } ?? 0) * item.element }
    }
    static func referenceName(_ text: String) throws -> String {
        guard text.utf16.count <= 200, !text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw failure("Use a reference name of up to 200 characters.") }; return text
    }
    static func diagnostics(_ value: JSONText?) -> String { items(value).prefix(10).map { detail in [detail["code"]?.text, detail["description"]?.text ?? detail["detail"]?.text].compactMap { $0 }.joined(separator: ": ") }.joined(separator: "\n") }
}
