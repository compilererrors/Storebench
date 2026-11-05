import CryptoKit
import Foundation

public enum ScreenshotFailure: Error, Equatable {
    case invalidImage(String), size(String), limit(String), stale, notFound, batch(String)

    public var message: String {
        switch self {
        case .invalidImage(let text), .size(let text), .limit(let text), .batch(let text): text
        case .stale: "Saved media changed in another window, import or upload. Your edits are still here. Reload the latest layout before saving again."
        case .notFound: "Screenshot language or size not found."
        }
    }
}

public enum ScreenshotSpecs {
    public static let maximum = 10, maximumBytes = 20_000_000, maximumBatchBytes = 50_000_000
    static let sizes: [String: [(Int, Int)]] = [
        "APP_DESKTOP": [(1280, 800), (1440, 900), (2560, 1600), (2880, 1800)], "APP_APPLE_TV": [(1920, 1080), (3840, 2160)], "APP_APPLE_VISION_PRO": [(3840, 2160)],
        "APP_IPHONE_67": [(1260, 2736), (1290, 2796), (1320, 2868)], "APP_IPHONE_65": [(1284, 2778), (1242, 2688)], "APP_IPHONE_61": [(1170, 2532), (1125, 2436), (1080, 2340)],
        "APP_IPHONE_58": [(1179, 2556), (1206, 2622)], "APP_IPHONE_55": [(1242, 2208)], "APP_IPHONE_47": [(750, 1334)],
        "APP_IPHONE_40": [(640, 1096), (640, 1136), (1136, 600), (1136, 640)], "APP_IPHONE_35": [(640, 920), (640, 960), (960, 600), (960, 640)],
        "APP_IPAD_PRO_3GEN_129": [(2064, 2752), (2048, 2732)], "APP_IPAD_PRO_129": [(2048, 2732)], "APP_IPAD_PRO_3GEN_11": [(1488, 2266), (1668, 2420), (1668, 2388), (1640, 2360)],
        "APP_IPAD_105": [(1668, 2224)], "APP_IPAD_97": [(1536, 2008), (1536, 2048), (2048, 1496), (2048, 1536), (768, 1004), (768, 1024), (1024, 748), (1024, 768)],
        "APP_WATCH_ULTRA": [(422, 514), (410, 502)], "APP_WATCH_SERIES_10": [(416, 496)], "APP_WATCH_SERIES_7": [(396, 484), (368, 448)], "APP_WATCH_SERIES_4": [(368, 448)], "APP_WATCH_SERIES_3": [(312, 390)],
    ]

    static func rotationAllowed(_ type: String) -> Bool {
        !["APP_DESKTOP", "APP_APPLE_TV", "APP_APPLE_VISION_PRO", "APP_IPHONE_40", "APP_IPHONE_35", "APP_IPAD_97"].contains(type) && !type.hasPrefix("APP_WATCH_")
    }

    public static func fits(_ type: String, width: Int, height: Int) -> Bool {
        (sizes[type] ?? []).contains { ($0.0 == width && $0.1 == height) || (rotationAllowed(type) && $0.0 == height && $0.1 == width) }
    }

    public static func sizesText(_ type: String) -> String { (sizes[type] ?? []).map { "\($0.0) × \($0.1)" }.joined(separator: ", ") }

    /// The display size an image belongs to, preferring sizes this language already has.
    public static func type(platform: String, width: Int, height: Int, existing: [String] = []) -> String? {
        let matches = StoreLocales.screenshotTypes(platform: platform, imported: existing).filter { type in
            (sizes[type] ?? []).contains { ($0.0 == width && $0.1 == height) || (rotationAllowed(type) && $0.0 == height && $0.1 == width) }
        }
        return matches.first { existing.contains($0) } ?? matches.first
    }

    public static func sizeError(platform: String, width: Int, height: Int) -> String {
        let types = StoreLocales.screenshotTypes(platform: platform).filter { !(sizes[$0] ?? []).isEmpty }
        let samples = types.prefix(platform == "IOS" ? 3 : 1).map { "\(StoreLocales.displayTypeName($0)): \(sizesText($0))" }.joined(separator: "; ")
        return "\(width) × \(height) px is not a supported \(platform == "MAC_OS" ? "Mac" : "App Store") screenshot size. \(samples). See Apple's screenshot specifications for all sizes."
    }

    public struct Image: Equatable, Sendable { public let sha256: String, width: Int, height: Int, contentType: String }

    /// Reads dimensions from bounded file headers, never from the file name.
    public static func validate(_ data: Data) throws -> Image {
        let bytes = [UInt8](data)
        guard bytes.count >= 33, bytes.count <= maximumBytes else { throw ScreenshotFailure.invalidImage("Choose a PNG or JPEG image up to 20 MB.") }
        func u32(_ at: Int) -> Int { Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16 | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3]) }
        func u16(_ at: Int) -> Int { Int(bytes[at]) << 8 | Int(bytes[at + 1]) }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        func checked(_ width: Int, _ height: Int, _ kind: String) throws { guard width >= 1, height >= 1, width <= 12000, height <= 12000, width * height <= 40_000_000 else { throw ScreenshotFailure.invalidImage("Invalid \(kind) dimensions.") } }
        if Array(bytes.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10] {
            guard String(bytes: bytes[12..<16], encoding: .ascii) == "IHDR", u32(8) == 13 else { throw ScreenshotFailure.invalidImage("Choose a PNG image under 20 MB.") }
            let width = u32(16), height = u32(20)
            try checked(width, height, "PNG")
            var transparent = bytes[25] == 4 || bytes[25] == 6, offset = 8
            while offset + 12 <= bytes.count {
                let length = u32(offset)
                if length > bytes.count - offset - 12 { break }
                if String(bytes: bytes[offset + 4..<offset + 8], encoding: .ascii) == "tRNS" { transparent = true }
                offset += length + 12
            }
            if transparent { throw ScreenshotFailure.invalidImage("Apple screenshots cannot contain transparency. Export an opaque PNG or JPEG.") }
            return Image(sha256: hash, width: width, height: height, contentType: "image/png")
        }
        guard bytes[0] == 0xff, bytes[1] == 0xd8, bytes[bytes.count - 2] == 0xff, bytes[bytes.count - 1] == 0xd9 else { throw ScreenshotFailure.invalidImage("Choose a valid PNG or JPEG image.") }
        var offset = 2
        while offset + 4 < bytes.count {
            guard bytes[offset] == 0xff else { throw ScreenshotFailure.invalidImage("Invalid JPEG image.") }
            while offset < bytes.count, bytes[offset] == 0xff { offset += 1 }
            guard offset < bytes.count else { break }
            let marker = bytes[offset]; offset += 1
            if marker == 0xd9 || marker == 0xda { break }
            if marker == 0x01 || (0xd0...0xd7).contains(marker) { continue }
            if offset + 2 > bytes.count { break }
            let length = u16(offset)
            if length < 2 || offset + length > bytes.count { break }
            // A rotated JPEG would show differently at Apple than its stored size suggests.
            if marker == 0xe1, try orientation(bytes, offset + 2, offset + length) > 1 { throw ScreenshotFailure.invalidImage("Rotate the screenshot before adding it: its EXIF orientation is not upright.") }
            if [0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf].contains(marker) {
                if length < 7 { break }
                let height = u16(offset + 3), width = u16(offset + 5)
                try checked(width, height, "JPEG")
                return Image(sha256: hash, width: width, height: height, contentType: "image/jpeg")
            }
            offset += length
        }
        throw ScreenshotFailure.invalidImage("Invalid JPEG image dimensions.")
    }

    static func orientation(_ bytes: [UInt8], _ start: Int, _ end: Int) throws -> Int {
        guard end - start >= 14, Array(bytes[start..<start + 6]) == Array("Exif\0\0".utf8) else { return 1 }
        let base = start + 6, order = String(bytes: bytes[base..<base + 2], encoding: .ascii)
        guard order == "II" || order == "MM" else { throw ScreenshotFailure.invalidImage("Invalid JPEG EXIF data.") }
        let little = order == "II"
        func u16(_ at: Int) throws -> Int { guard at + 2 <= bytes.count else { throw ScreenshotFailure.invalidImage("Invalid JPEG EXIF data.") }; return little ? Int(bytes[at]) | Int(bytes[at + 1]) << 8 : Int(bytes[at]) << 8 | Int(bytes[at + 1]) }
        func u32(_ at: Int) throws -> Int { guard at + 4 <= bytes.count else { throw ScreenshotFailure.invalidImage("Invalid JPEG EXIF data.") }; return little ? (try u16(at)) | (try u16(at + 2)) << 16 : (try u16(at)) << 16 | (try u16(at + 2)) }
        guard try u16(base + 2) == 42 else { throw ScreenshotFailure.invalidImage("Invalid JPEG EXIF data.") }
        let directory = base + (try u32(base + 4))
        guard directory + 2 <= end else { throw ScreenshotFailure.invalidImage("Invalid JPEG EXIF data.") }
        for index in 0..<(try u16(directory)) {
            let entry = directory + 2 + index * 12
            guard entry + 12 <= end else { throw ScreenshotFailure.invalidImage("Invalid JPEG EXIF data.") }
            if try u16(entry) == 0x0112 { return try u16(entry + 8) }
        }
        return 1
    }

    /// The saved file name: the original stem without path characters, with the format's extension.
    static func fileName(_ original: String, contentType: String) -> String {
        var stem = String(original.unicodeScalars.map { $0 == "\\" || $0 == "/" || $0.value < 0x20 || $0.value == 0x7f ? "_" : Character($0) })
        if let range = stem.range(of: #"\.(png|jpe?g)$"#, options: [.regularExpression, .caseInsensitive]) { stem.removeSubrange(range) }
        stem = String(decoding: Array(stem.utf16.prefix(95)), as: UTF16.self)
        return "\(stem.isEmpty ? "Screenshot" : stem).\(contentType == "image/jpeg" ? "jpg" : "png")"
    }

    /// The media layout and its signature, which detects layouts changed elsewhere.
    public static func layout(_ ids: [String], saved: (order: [String], hidden: [String])?) -> (order: [String], hidden: [String]) {
        let savedOrder = saved?.order ?? []
        let order = savedOrder.filter(ids.contains) + ids.filter { !savedOrder.contains($0) }
        return (order, order.filter { saved?.hidden.contains($0) == true })
    }

    public static func signature(_ layout: (order: [String], hidden: [String])) -> String {
        JSONText.object([("order", .array(layout.order.map { .string($0) })), ("hidden", .array(layout.hidden.sorted { Array($0.utf16).lexicographicallyPrecedes(Array($1.utf16)) }.map { .string($0) })), ("posterTimes", .object([]))]).stringify()
    }
}

/// One screenshot size of one language: Apple's imported screenshots and local uploads, in the draft's order.
public struct ScreenshotSetDraft: Sendable {
    public struct Item: Identifiable, Sendable, Equatable { public let id, fileName, sha256: String; public let width, height: Int?; public let local: Bool }
    public let setId: String, displayType: String
    public let items: [Item]
    public let hidden: Set<String>
    public let signature: String
}

extension WorkspaceSession {
    static func uploads(_ draft: JSONText?) -> [(String, JSONText)] { if case .object(let pairs)? = draft?["uploads"] { pairs } else { [] } }
    static func strings(_ value: JSONText?) -> [String] { items(value).compactMap(\.text) }

    /// Reads every saved screenshot size of one language, including sizes added locally.
    public func screenshotCatalog(accountId: String, appId: String, revisionId: String, localizationId: String) throws -> [ScreenshotSetDraft] {
        try storeAccess { store in
            let key = try TextDrafts.key(accountId: accountId, appId: appId, revisionId: revisionId)
            guard let sourceDocument = try store.document(namespace: "revisions", key: key) else { throw DraftFailure.sourceMissing }
            let source = try parsedRevision(sourceDocument)
            let draft = try store.document(namespace: "drafts", key: key).map { try JSONText.parse($0.payload) }
            let revision = Self.overlay(source, draft: draft)
            guard let language = revision.versions.flatMap(\.localizations).first(where: { $0.id == localizationId }) else { throw ScreenshotFailure.notFound }
            return try language.screenshotSets.map { try Self.screenshotSetDraft(set: $0, draft: draft) }
        }
    }

    /// The ordered screenshots of one set, including local uploads and the saved hidden selection.
    public func screenshotSet(accountId: String, appId: String, revisionId: String, setId: String) throws -> ScreenshotSetDraft {
        try storeAccess { store in
            let key = try TextDrafts.key(accountId: accountId, appId: appId, revisionId: revisionId)
            guard let sourceDocument = try store.document(namespace: "revisions", key: key) else { throw DraftFailure.sourceMissing }
            let draft = try store.document(namespace: "drafts", key: key).map { try JSONText.parse($0.payload) }
            return try Self.screenshotSetDraft(revision: Self.overlay(parsedRevision(sourceDocument), draft: draft), draft: draft, setId: setId)
        }
    }

    static func screenshotSetDraft(source: JSONText, draft: JSONText?, setId: String) throws -> ScreenshotSetDraft {
        try screenshotSetDraft(revision: Self.overlay(try JSONDecoder().decode(Revision.self, from: source.data), draft: draft), draft: draft, setId: setId)
    }

    private static func screenshotSetDraft(revision: Revision, draft: JSONText?, setId: String) throws -> ScreenshotSetDraft {
        guard let set = revision.versions.flatMap({ $0.localizations.flatMap(\.screenshotSets) }).first(where: { $0.id == setId }) else { throw ScreenshotFailure.notFound }
        return try Self.screenshotSetDraft(set: set, draft: draft)
    }

    private static func screenshotSetDraft(set: Revision.ScreenshotSet, draft: JSONText?) throws -> ScreenshotSetDraft {
        let setId = set.id
        var items = set.screenshots.map { ScreenshotSetDraft.Item(id: $0.id, fileName: $0.fileName, sha256: $0.sha256, width: $0.width, height: $0.height, local: false) }
        for (id, upload) in Self.uploads(draft) where upload["setId"]?.text == setId {
            guard let hash = upload["sha256"]?.text, case .number(let width)? = upload["width"], case .number(let height)? = upload["height"],
                  width > 0, height > 0, width <= 9_007_199_254_740_991, height <= 9_007_199_254_740_991, let w = Int(exactly: width), let h = Int(exactly: height) else { throw DraftFailure.invalid }
            items.append(.init(id: id, fileName: upload["fileName"]?.text ?? "", sha256: hash, width: w, height: h, local: true))
    }
        let saved = draft?["screenshotLayouts"]?[setId].map { (order: Self.strings($0["order"]), hidden: Self.strings($0["hidden"])) }
        let layout = ScreenshotSpecs.layout(items.map(\.id), saved: saved)
        let ordered = layout.order.compactMap { id in items.first { $0.id == id } }
        return ScreenshotSetDraft(setId: setId, displayType: set.displayType, items: ordered, hidden: Set(layout.hidden), signature: ScreenshotSpecs.signature(layout))
    }

    /// Saves a new order and selection for one set, only onto the layout the editor loaded.
    @discardableResult public func saveScreenshotLayout(accountId: String, appId: String, revisionId: String, setId: String, order: [String], hidden: [String], expected: String) throws -> ScreenshotSetDraft {
        try mutateDraft(accountId: accountId, appId: appId, revisionId: revisionId) { draft, sourceJSON in
            let revision = Self.overlay(try JSONDecoder().decode(Revision.self, from: sourceJSON.data), draft: draft)
            guard let set = revision.versions.flatMap({ $0.localizations.flatMap(\.screenshotSets) }).first(where: { $0.id == setId }) else { throw ScreenshotFailure.notFound }
            let available = set.screenshots.map(\.id) + Self.uploads(draft).filter { $0.1["setId"]?.text == setId }.map(\.0)
            let saved = draft["screenshotLayouts"]?[setId].map { (order: Self.strings($0["order"]), hidden: Self.strings($0["hidden"])) }
            guard ScreenshotSpecs.signature(ScreenshotSpecs.layout(available, saved: saved)) == expected else { throw ScreenshotFailure.stale }
            let unique = Set(available)
            guard unique.count == available.count, order.count == available.count, Set(order).count == available.count, order.allSatisfy(unique.contains),
                  Set(hidden).count == hidden.count, hidden.allSatisfy(unique.contains) else { throw DraftFailure.invalid }
            guard Set(available).subtracting(hidden).count <= ScreenshotSpecs.maximum else { throw ScreenshotFailure.limit("Select no more than 10 screenshots per language and display size.") }
            let layout = JSONText.object([("order", .array(order.map { .string($0) })), ("hidden", .array(hidden.map { .string($0) }))])
            let next = draft.setting("screenshotLayouts", (draft["screenshotLayouts"] ?? .object([])).setting(setId, layout))
            return (next, try Self.screenshotSetDraft(source: sourceJSON, draft: next, setId: setId))
        }
    }

    /// Adds screenshots to one language: each image goes to its set (`setId`), or to the display size its dimensions match.
    /// The whole batch is validated before anything is saved; nothing is sent to App Store Connect.
    public func addScreenshots(accountId: String, appId: String, revisionId: String, localizationId: String, setId: String?, files: [(name: String, data: Data)]) throws -> Int {
        try addScreenshotsWithReceipt(accountId: accountId, appId: appId, revisionId: revisionId, localizationId: localizationId, setId: setId, files: files).count
    }

    /// `assetIds` names, per file, the Asset Library file it already is at Apple, so a Save adds that file instead of uploading it again.
    public func addScreenshotsWithReceipt(accountId: String, appId: String, revisionId: String, localizationId: String, setId: String?, files: [(name: String, data: Data)], assetIds: [String?] = []) throws -> MediaAdditionReceipt {
        guard !files.isEmpty else { throw ScreenshotFailure.batch("Choose at least one screenshot.") }
        guard assetIds.isEmpty || assetIds.count == files.count, assetIds.allSatisfy({ $0.map(AssetLibrary.validID) ?? true }) else { throw ScreenshotFailure.batch("Choose the Asset Library files again.") }
        guard files.count <= ScreenshotSpecs.maximum else { throw ScreenshotFailure.batch("Choose no more than 10 images. Save any exclusions first to free slots.") }
        guard files.allSatisfy({ !$0.data.isEmpty && $0.data.count <= ScreenshotSpecs.maximumBytes }) else { throw ScreenshotFailure.batch("Each screenshot must be nonempty and no larger than 20 MB.") }
        guard files.reduce(0, { $0 + $1.data.count }) <= ScreenshotSpecs.maximumBatchBytes else { throw ScreenshotFailure.batch("Choose up to 50 MB of images at a time. You can add the rest in another batch.") }
        let images = try files.map { (file: $0, image: try ScreenshotSpecs.validate($0.data)) }
        return try mutateDraft(accountId: accountId, appId: appId, revisionId: revisionId) { draft, sourceJSON in
            let source = try JSONDecoder().decode(Revision.self, from: sourceJSON.data)
            var updated = draft, affected: [String] = []
            func locale() -> (Revision.Version, Revision.Localization)? {
                for version in Self.overlay(source, draft: updated).versions {
                    if let match = version.localizations.first(where: { setId != nil ? $0.screenshotSets.contains { $0.id == setId } : $0.id == localizationId }) { return (version, match) }
                }
                return nil
            }
            guard let (version, selected) = locale() else { throw ScreenshotFailure.notFound }
            let platform = version.fields["platform"].map(Self.text) ?? "", fixed = selected.screenshotSets.first { $0.id == setId }?.displayType
            let typed = try images.map { item -> (file: (name: String, data: Data), image: ScreenshotSpecs.Image, type: String) in
                // A chosen size still has to match the image, so Apple never receives a screenshot of the wrong size.
                let matching = ScreenshotSpecs.type(platform: platform, width: item.image.width, height: item.image.height, existing: fixed.map { [$0] } ?? selected.screenshotSets.map(\.displayType))
                guard let type = fixed.flatMap({ ScreenshotSpecs.fits($0, width: item.image.width, height: item.image.height) ? $0 : nil }) ?? (fixed == nil ? matching : nil) else {
                    throw ScreenshotFailure.size(ScreenshotSpecs.sizeError(platform: platform, width: item.image.width, height: item.image.height))
                }
                return (item.file, item.image, type)
            }
            for (offset, item) in typed.enumerated() {
                var set = locale()?.1.screenshotSets.first { $0.displayType == item.type }
                if set == nil {
                    updated = updated.setting("addedScreenshotSets", .array(Self.items(updated["addedScreenshotSets"]) + [.object([("id", .string("local-set-\(UUID().uuidString.lowercased())")), ("localizationId", .string(selected.id)), ("displayType", .string(item.type))])]))
                    set = locale()?.1.screenshotSets.first { $0.displayType == item.type }
                }
                guard let set else { throw ScreenshotFailure.notFound }
                if !affected.contains(set.id) { affected.append(set.id) }
                let id = "local-\(UUID().uuidString.lowercased())"
                let existing = set.screenshots.map(\.id) + Self.uploads(updated).filter { $0.1["setId"]?.text == set.id }.map(\.0)
                let current = updated["screenshotLayouts"]?[set.id]
                let hidden = Self.strings(current?["hidden"])
                guard Set(existing).subtracting(hidden).count < ScreenshotSpecs.maximum else {
                    throw ScreenshotFailure.limit("This language and display size already has 10 screenshots. Exclude an item and save the layout before adding another. No images in this batch were added.")
                }
                let upload = JSONText.object([("setId", .string(set.id)), ("id", .string(id)), ("sha256", .string(item.image.sha256)), ("fileName", .string(ScreenshotSpecs.fileName(item.file.name, contentType: item.image.contentType))),
                                              ("width", .number(Double(item.image.width))), ("height", .number(Double(item.image.height))), ("contentType", .string(item.image.contentType))]
                                             + (assetIds.isEmpty ? [] : assetIds[offset].map { [("assetId", JSONText.string($0))] } ?? []))
                updated = updated.setting("uploads", (updated["uploads"] ?? .object([])).setting(id, upload))
                let order = current.map { Self.strings($0["order"]) } ?? existing
                let layout = JSONText.object([("order", .array((order.contains(id) ? order : order + [id]).map { .string($0) })), ("hidden", .array(hidden.map { .string($0) }))])
                updated = updated.setting("screenshotLayouts", (updated["screenshotLayouts"] ?? .object([])).setting(set.id, layout))
            }
            for item in typed { guard try media.write(item.file.data, limit: 50_000_000).hash == item.image.sha256 else { throw ScreenshotFailure.invalidImage("Draft image hash changed during save.") } }
            let changes = try affected.map { id in
                let before = selected.screenshotSets.contains { $0.id == id } ? try Self.screenshotSetDraft(source: sourceJSON, draft: draft, setId: id) : nil
                return MediaCatalogChange(before: before.map(MediaLayoutDraft.screenshots), after: .screenshots(try Self.screenshotSetDraft(source: sourceJSON, draft: updated, setId: id)))
            }
            return (updated, MediaAdditionReceipt(scope: .init(accountId: accountId, appId: appId, revisionId: revisionId), count: typed.count, changes: changes))
        }
    }

    /// Removes a local upload from its set. Apple's imported screenshots are excluded with the layout instead.
    public func removeScreenshotUpload(accountId: String, appId: String, revisionId: String, uploadId: String) throws {
        try mutateDraft(accountId: accountId, appId: appId, revisionId: revisionId) { draft, _ in
            guard uploadId.hasPrefix("local-"), case .object(let uploads)? = draft["uploads"], let upload = uploads.first(where: { $0.0 == uploadId })?.1, let setId = upload["setId"]?.text else { throw ScreenshotFailure.notFound }
            var updated = draft.setting("uploads", .object(uploads.filter { $0.0 != uploadId }))
            if let layout = updated["screenshotLayouts"]?[setId] {
                let next = JSONText.object([("order", .array(Self.strings(layout["order"]).filter { $0 != uploadId }.map { .string($0) })), ("hidden", .array(Self.strings(layout["hidden"]).filter { $0 != uploadId }.map { .string($0) }))])
                updated = updated.setting("screenshotLayouts", (updated["screenshotLayouts"] ?? .object([])).setting(setId, next))
            }
            return (updated, ())
        }
    }
}

extension WorkspaceSession {
    /// Copies another language's included screenshots into this language, size by size, reusing the same files.
    /// Repeating the copy adds nothing twice, and images hidden in the target stay hidden.
    public func copyScreenshots(accountId: String, appId: String, revisionId: String, targetId: String, sourceId: String) throws -> Int {
        try copyScreenshotsWithReceipt(accountId: accountId, appId: appId, revisionId: revisionId, targetId: targetId, sourceId: sourceId).count
    }

    public func copyScreenshotsWithReceipt(accountId: String, appId: String, revisionId: String, targetId: String, sourceId: String) throws -> MediaAdditionReceipt {
        try mutateDraft(accountId: accountId, appId: appId, revisionId: revisionId) { draft, sourceJSON in
            let source = try JSONDecoder().decode(Revision.self, from: sourceJSON.data)
            let revision = Self.overlay(source, draft: draft)
            guard targetId != sourceId, let version = revision.versions.first(where: { $0.localizations.contains { $0.id == targetId } }),
                  let target = version.localizations.first(where: { $0.id == targetId }), let original = version.localizations.first(where: { $0.id == sourceId }) else {
                throw ScreenshotFailure.batch("Choose another language in the same version.")
            }
            var updated = draft, copied = 0, affected: [String] = []
            for from in original.screenshotSets {
                struct Image { let id, sha256, fileName, contentType: String; let width, height: Int?; let archive: Bool }
                var images = from.screenshots.map { Image(id: $0.id, sha256: $0.sha256, fileName: $0.fileName, contentType: $0.contentType == "image/jpeg" ? "image/jpeg" : "image/png", width: $0.width, height: $0.height, archive: true) }
                for (id, upload) in Self.uploads(draft) where upload["setId"]?.text == from.id {
                    guard let hash = upload["sha256"]?.text, case .number(let width)? = upload["width"], case .number(let height)? = upload["height"],
                          width > 0, height > 0, width <= 9_007_199_254_740_991, height <= 9_007_199_254_740_991, let w = Int(exactly: width), let h = Int(exactly: height) else { throw DraftFailure.invalid }
                    images.append(Image(id: id, sha256: hash, fileName: upload["fileName"]?.text ?? "", contentType: upload["contentType"]?.text == "image/jpeg" ? "image/jpeg" : "image/png", width: w, height: h, archive: upload["archiveSource"] == .bool(true)))
                }
                let layout = draft["screenshotLayouts"]?[from.id], hiddenIds = Set(Self.strings(layout?["hidden"]))
                if let layout {
                    let positions = Dictionary(Self.strings(layout["order"]).enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
                    images = images.enumerated().sorted { (positions[$0.element.id] ?? Int.max, $0.offset) < (positions[$1.element.id] ?? Int.max, $1.offset) }.map(\.element)
                }
                images = images.filter { !hiddenIds.contains($0.id) }
                guard !images.isEmpty else { continue }
                var targetSetId = target.screenshotSets.first { $0.displayType == from.displayType }?.id
                let archived = target.screenshotSets.first { $0.displayType == from.displayType }?.screenshots ?? []
                if targetSetId == nil {
                    let id = "local-set-\(UUID().uuidString.lowercased())"
                    updated = updated.setting("addedScreenshotSets", .array(Self.items(updated["addedScreenshotSets"]) + [.object([("id", .string(id)), ("localizationId", .string(targetId)), ("displayType", .string(from.displayType))])]))
                    targetSetId = id
                }
                let setId = targetSetId!
                var existing: [String: Int] = [:]
                for hash in archived.map(\.sha256) + Self.uploads(updated).filter({ $0.1["setId"]?.text == setId }).compactMap({ $0.1["sha256"]?.text }) { existing[hash, default: 0] += 1 }
                for image in images {
                    if let count = existing[image.sha256], count > 0 { existing[image.sha256] = count - 1; continue }
                    guard let width = image.width, let height = image.height else { throw ScreenshotFailure.batch("The original image has no saved dimensions. View or download its original before adding it as a new screenshot.") }
                    let ids = archived.map(\.id) + Self.uploads(updated).filter { $0.1["setId"]?.text == setId }.map(\.0)
                    let current = updated["screenshotLayouts"]?[setId], hidden = Self.strings(current?["hidden"])
                    guard Set(ids).subtracting(hidden).count < ScreenshotSpecs.maximum else {
                        throw ScreenshotFailure.limit("This language and display size already has 10 screenshots. Exclude an item and save the layout before adding another.")
                    }
                    let id = "local-\(UUID().uuidString.lowercased())"
                    var fields: [(String, JSONText)] = [("id", .string(id)), ("setId", .string(setId)), ("sha256", .string(image.sha256)), ("fileName", .string(image.fileName)),
                                                        ("width", .number(Double(width))), ("height", .number(Double(height))), ("contentType", .string(image.contentType))]
                    if image.archive { fields.append(("archiveSource", .bool(true))) }
                    updated = updated.setting("uploads", (updated["uploads"] ?? .object([])).setting(id, .object(fields)))
                    let order = current.map { Self.strings($0["order"]) } ?? ids
                    updated = updated.setting("screenshotLayouts", (updated["screenshotLayouts"] ?? .object([])).setting(setId, .object([("order", .array((order + [id]).map { .string($0) })), ("hidden", .array(hidden.map { .string($0) }))])))
                    copied += 1
                    if !affected.contains(setId) { affected.append(setId) }
                }
            }
            let changes = try affected.map { id in
                let before = target.screenshotSets.contains { $0.id == id } ? try Self.screenshotSetDraft(source: sourceJSON, draft: draft, setId: id) : nil
                return MediaCatalogChange(before: before.map(MediaLayoutDraft.screenshots), after: .screenshots(try Self.screenshotSetDraft(source: sourceJSON, draft: updated, setId: id)))
            }
            return (updated, MediaAdditionReceipt(scope: .init(accountId: accountId, appId: appId, revisionId: revisionId), count: copied, changes: changes))
        }
    }
}
