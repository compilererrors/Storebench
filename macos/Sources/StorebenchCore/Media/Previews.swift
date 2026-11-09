import Foundation

public enum PreviewFailure: Error, Equatable {
    case invalid(String), limit, stale, notFound

    public var message: String {
        switch self {
        case .invalid(let text): text
        case .limit: "This language and display size already has 3 app previews. Exclude an item and save the layout before adding another."
        case .stale: ScreenshotFailure.stale.message
        case .notFound: "Choose a preview size for this language and platform."
        }
    }
}

/// App preview rules and container metadata.
public enum PreviewSpecs {
    public static let maximum = 3, maximumBytes = 500_000_000
    static let sizes: [String: [(Int, Int)]] = [
        "IPHONE_67": [(886, 1920)], "IPHONE_65": [(886, 1920)], "IPHONE_61": [(886, 1920)], "IPHONE_58": [(886, 1920)], "IPHONE_55": [(1080, 1920)], "IPHONE_47": [(750, 1334)], "IPHONE_40": [(1080, 1920)],
        "IPAD_PRO_3GEN_129": [(1200, 1600)], "IPAD_PRO_3GEN_11": [(1200, 1600)], "IPAD_PRO_129": [(1200, 1600), (900, 1200)], "IPAD_105": [(1200, 1600)], "IPAD_97": [(900, 1200)],
        "DESKTOP": [(1920, 1080)], "APPLE_TV": [(1920, 1080)], "APPLE_VISION_PRO": [(3840, 2160)],
    ]
    static let order = ["IPHONE_67", "IPHONE_65", "IPHONE_61", "IPHONE_58", "IPHONE_55", "IPHONE_47", "IPHONE_40", "IPAD_PRO_3GEN_129", "IPAD_PRO_3GEN_11", "IPAD_PRO_129", "IPAD_105", "IPAD_97", "DESKTOP", "APPLE_TV", "APPLE_VISION_PRO"]

    public static func types(platform: String) -> [String] {
        let single = ["MAC_OS": "DESKTOP", "TV_OS": "APPLE_TV", "VISION_OS": "APPLE_VISION_PRO"]
        return order.filter { platform == "IOS" ? $0.hasPrefix("IPHONE_") || $0.hasPrefix("IPAD_") : $0 == single[platform] }
    }

    public static func dimensions(_ type: String) -> String {
        (sizes[type] ?? []).map { "\($0.0) × \($0.1)" }.joined(separator: " or ") + (type.hasPrefix("IPHONE_") || type.hasPrefix("IPAD_") ? " · portrait or landscape" : " · landscape")
    }

    public static func name(_ type: String) -> String { StoreLocales.displayTypeName("APP_\(type)") }

    public struct Movie: Equatable, Sendable {
        public let width: Int, height: Int; public let duration: Double, frameRate: Double; public let codec: String
        public let hasAudio: Bool
        public init(width: Int, height: Int, duration: Double, frameRate: Double, codec: String, hasAudio: Bool = false) {
            self.width = width; self.height = height; self.duration = duration; self.frameRate = frameRate; self.codec = codec; self.hasAudio = hasAudio
        }
    }

    struct Atom { let type: String; let payload: [UInt8] }

    static func atoms(_ bytes: ArraySlice<UInt8>) throws -> [Atom] {
        var result: [Atom] = [], offset = bytes.startIndex
        while offset < bytes.endIndex {
            guard offset + 8 <= bytes.endIndex, result.count <= 10_000 else { throw PreviewFailure.invalid("Invalid video container.") }
            var size = Int(u32(bytes, offset)), header = 8
            if size == 1 { guard offset + 16 <= bytes.endIndex else { throw PreviewFailure.invalid("Invalid video atom.") }; size = Int(u32(bytes, offset + 8)) << 32 | Int(u32(bytes, offset + 12)); header = 16 }
            if size == 0 { size = bytes.endIndex - offset }
            guard size >= header, offset + size <= bytes.endIndex else { throw PreviewFailure.invalid("Invalid video atom length.") }
            result.append(Atom(type: String(decoding: bytes[offset + 4..<offset + 8], as: UTF8.self), payload: Array(bytes[offset + header..<offset + size])))
            offset += size
        }
        return result
    }

    static func u32(_ bytes: ArraySlice<UInt8>, _ at: Int) -> UInt32 { UInt32(bytes[at]) << 24 | UInt32(bytes[at + 1]) << 16 | UInt32(bytes[at + 2]) << 8 | UInt32(bytes[at + 3]) }
    static func u32(_ bytes: [UInt8], _ at: Int) -> UInt32 { u32(bytes[...], at) }
    static func u16(_ bytes: [UInt8], _ at: Int) -> Int { Int(bytes[at]) << 8 | Int(bytes[at + 1]) }
    static func i32(_ bytes: [UInt8], _ at: Int) -> Int32 { Int32(bitPattern: u32(bytes, at)) }

    static func child(_ bytes: [UInt8], _ type: String) throws -> [UInt8] {
        guard let found = try atoms(bytes[...]).first(where: { $0.type == type }) else { throw PreviewFailure.invalid("The video is missing required metadata.") }
        return found.payload
    }

    static func timing(_ bytes: [UInt8]) throws -> (seconds: Double, scale: Double) {
        let version = bytes.first ?? 9
        guard version == 0 || version == 1, bytes.count >= (version == 1 ? 32 : 20) else { throw PreviewFailure.invalid("Invalid video duration.") }
        let scale = Double(u32(bytes, version == 1 ? 20 : 12))
        let ticks = version == 1 ? Double(UInt64(u32(bytes, 24)) << 32 | UInt64(u32(bytes, 28))) : Double(u32(bytes, 16))
        guard scale > 0, ticks > 0, ticks <= 9_007_199_254_740_991 else { throw PreviewFailure.invalid("Invalid video timing.") }
        return (ticks / scale, scale)
    }

    /// The movie's one video track, from its `moov` atom.
    public static func parse(moov: [UInt8]) throws -> Movie {
        let movie = try timing(try child(moov, "mvhd"))
        var result: Movie?, hasAudio = false
        for track in try atoms(moov[...]) where track.type == "trak" {
            let mdia = try child(track.payload, "mdia"), handler = try child(mdia, "hdlr")
            guard handler.count >= 12 else { throw PreviewFailure.invalid("Invalid media track.") }
            let handlerType = String(decoding: handler[8..<12], as: UTF8.self)
            if handlerType == "soun" {
                let minf = try child(mdia, "minf"), dref = try child(try child(minf, "dinf"), "dref")
                let references = dref.count >= 8 ? try atoms(dref[8...]) : []
                guard !references.isEmpty, references.allSatisfy({ $0.type == "url " && $0.payload.count >= 4 && u32($0.payload, 0) & 1 == 1 }) else { throw PreviewFailure.invalid("Upload a self-contained audio track.") }
                hasAudio = true
            }
            guard handlerType == "vide" else { continue }
            guard result == nil else { throw PreviewFailure.invalid("Use a video with one video track.") }
            let trackTiming = try timing(try child(mdia, "mdhd"))
            let minf = try child(mdia, "minf"), table = try child(minf, "stbl"), stsd = try child(table, "stsd")
            guard stsd.count >= 8, u32(stsd, 4) == 1 else { throw PreviewFailure.invalid("Use a single video format.") }
            guard let entry = try atoms(stsd[8...]).first, ["avc1", "avc3", "apch"].contains(entry.type), entry.payload.count >= 78 else { throw PreviewFailure.invalid("Use H.264 or ProRes 422 HQ video.") }
            // External data references are not supported for self-contained preview uploads.
            guard u16(entry.payload, 6) == 1 else { throw PreviewFailure.invalid("Upload a self-contained video file.") }
            let dref = try child(try child(minf, "dinf"), "dref"), references = dref.count >= 8 ? try atoms(dref[8...]) : []
            guard !references.isEmpty, references.allSatisfy({ $0.type == "url " && $0.payload.count >= 4 && u32($0.payload, 0) & 1 == 1 }) else { throw PreviewFailure.invalid("Upload a self-contained video file.") }
            var width = u16(entry.payload, 24), height = u16(entry.payload, 26)
            let tkhd = try child(track.payload, "tkhd"), matrix = tkhd.first == 1 ? 52 : 40
            guard tkhd.count >= matrix + 36 else { throw PreviewFailure.invalid("Invalid video track.") }
            if i32(tkhd, matrix) == 0 && abs(i32(tkhd, matrix + 4)) == 65536 { swap(&width, &height) }
            let stts = try child(table, "stts")
            guard stts.count >= 8, u32(stts, 4) >= 1, u32(stts, 4) <= 100_000, stts.count == 8 + Int(u32(stts, 4)) * 8 else { throw PreviewFailure.invalid("Invalid video frame timing.") }
            var frameRate = 0.0, samples = 0
            for offset in stride(from: 8, to: stts.count, by: 8) {
                let count = u32(stts, offset), delta = u32(stts, offset + 4)
                guard count > 0, delta > 0 else { throw PreviewFailure.invalid("Invalid video frame timing.") }
                samples += Int(count); frameRate = max(frameRate, trackTiming.scale / Double(delta))
            }
            guard samples > 0, abs(movie.seconds - trackTiming.seconds) <= 1 else { throw PreviewFailure.invalid("The video duration does not match its track. Export a flattened preview video.") }
            result = Movie(width: width, height: height, duration: movie.seconds, frameRate: frameRate, codec: entry.type)
        }
        guard let result else { throw PreviewFailure.invalid("The file contains no supported video track.") }
        return Movie(width: result.width, height: result.height, duration: result.duration, frameRate: result.frameRate, codec: result.codec, hasAudio: hasAudio)
    }

    /// Reads only atom headers and the bounded `moov` atom from a file; media payloads are never decoded.
    public static func read(_ url: URL) throws -> Movie {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let size = Int(try file.seekToEnd())
        guard size >= 32, size <= 500 * 1024 * 1024 else { throw PreviewFailure.invalid("Choose a valid MP4, M4V or MOV video.") }
        func readAt(_ offset: Int, _ length: Int) throws -> [UInt8] { try file.seek(toOffset: UInt64(offset)); return [UInt8](try file.read(upToCount: length) ?? Data()) }
        var moov: [UInt8]?, media = false, count = 0, offset = 0
        while offset < size {
            let header = try readAt(offset, min(16, size - offset))
            count += 1
            guard header.count >= 8, count <= 10_000 else { throw PreviewFailure.invalid("Invalid video container.") }
            var length = Int(u32(header, 0)), skip = 8
            if length == 1 { guard header.count >= 16 else { throw PreviewFailure.invalid("Invalid video atom.") }; length = Int(u32(header, 8)) << 32 | Int(u32(header, 12)); skip = 16 }
            if length == 0 { length = size - offset }
            guard length >= skip, offset + length <= size else { throw PreviewFailure.invalid("Invalid video atom length.") }
            let type = String(decoding: header[4..<8], as: UTF8.self)
            if type == "mdat" && length > skip { media = true }
            if type == "moov" {
                guard moov == nil, length <= 8_000_000 else { throw PreviewFailure.invalid("Unsupported video metadata. Export a flattened video.") }
                moov = try readAt(offset + skip, length - skip)
                guard moov?.count == length - skip else { throw PreviewFailure.invalid("Incomplete video metadata.") }
            }
            offset += length
        }
        guard let moov, media else { throw PreviewFailure.invalid("The video has no movie or media data.") }
        return try parse(moov: moov)
    }

    public static func validate(_ movie: Movie, type: String, extension ext: String) throws {
        guard movie.duration >= 15, movie.duration <= 30.05 else { throw PreviewFailure.invalid("App previews must be 15–30 seconds long.") }
        guard ["avc1", "avc3", "apch"].contains(movie.codec), movie.codec != "apch" || ext == "mov" else { throw PreviewFailure.invalid("Use H.264 in MP4, M4V or MOV, or ProRes 422 HQ in MOV.") }
        guard movie.frameRate > 0, movie.frameRate <= 30.01 else { throw PreviewFailure.invalid("App previews support up to 30 frames per second.") }
        let rotation = type.hasPrefix("IPHONE_") || type.hasPrefix("IPAD_")
        guard (sizes[type] ?? []).contains(where: { (movie.width == $0.0 && movie.height == $0.1) || (rotation && movie.width == $0.1 && movie.height == $0.0) }) else {
            throw PreviewFailure.invalid("Use \(dimensions(type)) for this preview size.")
        }
    }

    /// The media layout signature for previews, which includes poster frames.
    public static func signature(order: [String], hidden: [String], posterTimes: [String: Double]) -> String {
        let english = Locale(identifier: "en")
        return JSONText.object([("order", .array(order.map { .string($0) })), ("hidden", .array(hidden.sorted { Array($0.utf16).lexicographicallyPrecedes(Array($1.utf16)) }.map { .string($0) })),
                                ("posterTimes", .object(posterTimes.sorted { $0.key.compare($1.key, locale: english) == .orderedAscending }.map { ($0.key, .number($0.value)) }))]).stringify()
    }
}

public struct PreviewSetDraft: Sendable {
    public struct Item: Identifiable, Sendable, Equatable {
        public let id, fileName, sha256, ext: String; public let width, height: Int; public let duration: Double
        public init(id: String, fileName: String, sha256: String, ext: String, width: Int, height: Int, duration: Double) { self.id = id; self.fileName = fileName; self.sha256 = sha256; self.ext = ext; self.width = width; self.height = height; self.duration = duration }
    }
    public let items: [Item]
    public let hidden: Set<String>
    public let posterTimes: [String: Double]
    public let signature: String
}

extension WorkspaceSession {
    static func previewVideos(_ draft: JSONText?, localizationId: String, type: String) -> [(String, JSONText)] {
        guard case .object(let videos)? = draft?["previewUploads"] else { return [] }
        return videos.filter { $0.1["localizationId"]?.text == localizationId && $0.1["previewType"]?.text == type }
    }

    static func previewLayout(_ draft: JSONText?, ids: [String], key: String) -> (order: [String], hidden: [String], posterTimes: [String: Double]) {
        let saved = draft?["previewLayouts"]?[key]
        let layout = ScreenshotSpecs.layout(ids, saved: saved.map { (order: strings($0["order"]), hidden: strings($0["hidden"])) })
        var times: [String: Double] = [:]
        for id in layout.order { if case .number(let time)? = saved?["posterTimes"]?[id] { times[id] = time } else { times[id] = 5 } }
        return (layout.order, layout.hidden, times)
    }

    /// One language's previews for one display size, in the saved order with poster frames.
    public func previewSet(accountId: String, appId: String, revisionId: String, localizationId: String, type: String) throws -> PreviewSetDraft {
        let key = try TextDrafts.key(accountId: accountId, appId: appId, revisionId: revisionId)
        return try storeAccess { store in
            let draft = try store.document(namespace: "drafts", key: key).map { try JSONText.parse($0.payload) }
            return try Self.previewSetDraft(draft, localizationId: localizationId, type: type)
        }
    }

    static func previewSetDraft(_ draft: JSONText?, localizationId: String, type: String) throws -> PreviewSetDraft {
        let videos = Self.previewVideos(draft, localizationId: localizationId, type: type)
        let available = try videos.map { id, video -> PreviewSetDraft.Item in
            guard case .number(let width)? = video["width"], case .number(let height)? = video["height"], case .number(let duration)? = video["duration"],
                  width > 0, height > 0, width <= 9_007_199_254_740_991, height <= 9_007_199_254_740_991,
                  let w = Int(exactly: width), let h = Int(exactly: height), duration.isFinite, duration > 0 else { throw DraftFailure.invalid }
            return .init(id: id, fileName: video["fileName"]?.text ?? "", sha256: video["sha256"]?.text ?? "", ext: video["extension"]?.text ?? "mp4", width: w, height: h, duration: duration)
        }
        let layout = Self.previewLayout(draft, ids: videos.map(\.0), key: "\(localizationId):\(type)")
        let items = layout.order.compactMap { id in available.first { $0.id == id } }
        return PreviewSetDraft(items: items, hidden: Set(layout.hidden), posterTimes: layout.posterTimes, signature: PreviewSpecs.signature(order: layout.order, hidden: layout.hidden, posterTimes: layout.posterTimes))
    }

    func previewVersion(_ draft: JSONText, _ sourceJSON: JSONText, localizationId: String, type: String) throws {
        let revision = Self.overlay(try JSONDecoder().decode(Revision.self, from: sourceJSON.data), draft: draft)
        guard let version = revision.versions.first(where: { $0.localizations.contains { $0.id == localizationId } }),
              PreviewSpecs.types(platform: version.fields["platform"].map(Self.text) ?? "").contains(type) else { throw PreviewFailure.notFound }
    }

    static func addingPreview(_ draft: JSONText, video: JSONText, id: String, key: String, existing: [String], posterTime: Double = 5) throws -> JSONText {
        let saved = draft["previewLayouts"]?[key]
        let order = saved.map { strings($0["order"]) } ?? existing, hidden = strings(saved?["hidden"])
        guard Set(existing).subtracting(hidden).count < PreviewSpecs.maximum else { throw PreviewFailure.limit }
        var times: [(String, JSONText)] = []
        if case .object(let pairs)? = saved?["posterTimes"] { times = pairs }
        times.append((id, .number(posterTime)))
        let layout = JSONText.object([("order", .array((order + [id]).map { .string($0) })), ("hidden", .array(hidden.map { .string($0) })), ("posterTimes", .object(times))])
        return draft.setting("previewUploads", (draft["previewUploads"] ?? .object([])).setting(id, video))
            .setting("previewLayouts", (draft["previewLayouts"] ?? .object([])).setting(key, layout))
    }

    /// Adds an app preview video: its container is checked, then the file is encrypted into local media. Nothing is sent to Apple.
    public func addPreview(accountId: String, appId: String, revisionId: String, localizationId: String, type: String, file: URL) async throws {
        _ = try await addPreviewWithReceipt(accountId: accountId, appId: appId, revisionId: revisionId, localizationId: localizationId, type: type, file: file)
    }

    public func addPreviewWithReceipt(accountId: String, appId: String, revisionId: String, localizationId: String, type: String, file: URL) async throws -> MediaAdditionReceipt {
        let fileName = String(String(file.lastPathComponent.unicodeScalars.map { $0 == "\\" || $0 == "/" || $0.value < 0x20 || $0.value == 0x7f ? "_" : Character($0) }).utf16.prefix(100)) ?? "Preview.mp4"
        let ext = (fileName.split(separator: ".").last.map(String.init) ?? "").lowercased()
        guard ["mp4", "mov", "m4v"].contains(ext) else { throw PreviewFailure.invalid("Choose an MP4, M4V or MOV video.") }
        let key = "\(localizationId):\(type)"
        // Checked before the long encryption, and again in the draft write.
        let current = try previewSet(accountId: accountId, appId: appId, revisionId: revisionId, localizationId: localizationId, type: type)
        guard current.items.filter({ !current.hidden.contains($0.id) }).count < PreviewSpecs.maximum else { throw PreviewFailure.limit }
        let lease = try lifetime.admit(.transfer); defer { lease.finish() }
        let media = self.media, access = sessionRequestCheck()
        let (movie, saved) = try await mediaFileWork.run {
            try SessionContext.$lease.withValue(lease) {
                try access(); try Task.checkCancellation()
                let movie = try PreviewSpecs.read(file)
                try PreviewSpecs.validate(movie, type: type, extension: ext)
                let saved = try media.write(fileAt: file, limit: PreviewSpecs.maximumBytes)
                try access(); try Task.checkCancellation()
                return (movie, saved)
            }
        }
        try Task.checkCancellation()
        return try SessionContext.$lease.withValue(lease) { try mutateDraft(accountId: accountId, appId: appId, revisionId: revisionId) { draft, source in
            try previewVersion(draft, source, localizationId: localizationId, type: type)
            let id = "preview-\(UUID().uuidString.lowercased())"
            let video = JSONText.object([("id", .string(id)), ("localizationId", .string(localizationId)), ("previewType", .string(type)), ("fileName", .string(fileName)), ("extension", .string(ext)),
                                         ("width", .number(Double(movie.width))), ("height", .number(Double(movie.height))), ("duration", .number(movie.duration)), ("frameRate", .number(movie.frameRate)),
                                         ("codec", .string(movie.codec)), ("bytes", .number(Double(saved.length))), ("sha256", .string(saved.hash))])
            let next = try Self.addingPreview(draft, video: video, id: id, key: key, existing: Self.previewVideos(draft, localizationId: localizationId, type: type).map(\.0))
            let change = MediaCatalogChange(before: .previews(localizationId: localizationId, type: type, draft: try Self.previewSetDraft(draft, localizationId: localizationId, type: type)),
                                            after: .previews(localizationId: localizationId, type: type, draft: try Self.previewSetDraft(next, localizationId: localizationId, type: type)))
            return (next, MediaAdditionReceipt(scope: .init(accountId: accountId, appId: appId, revisionId: revisionId), count: 1, changes: [change]))
        } }
    }

    /// Saves preview order, selection and poster frames, only onto the layout the editor loaded.
    @discardableResult public func savePreviewLayout(accountId: String, appId: String, revisionId: String, localizationId: String, type: String, order: [String], hidden: [String], posterTimes: [String: Double], expected: String) throws -> PreviewSetDraft {
        try mutateDraft(accountId: accountId, appId: appId, revisionId: revisionId) { draft, _ in
            let key = "\(localizationId):\(type)", videos = Self.previewVideos(draft, localizationId: localizationId, type: type)
            let current = Self.previewLayout(draft, ids: videos.map(\.0), key: key)
            guard PreviewSpecs.signature(order: current.order, hidden: current.hidden, posterTimes: current.posterTimes) == expected else { throw PreviewFailure.stale }
            let ids = Set(videos.map(\.0))
            guard order.count == ids.count, Set(order) == ids, Set(hidden).count == hidden.count, Set(hidden).isSubset(of: ids), Set(posterTimes.keys).isSubset(of: ids) else { throw DraftFailure.invalid }
            guard ids.subtracting(hidden).count <= PreviewSpecs.maximum else { throw PreviewFailure.invalid("Select no more than 3 app previews per language and display size.") }
            for (id, time) in posterTimes {
                guard case .number(let duration)? = videos.first(where: { $0.0 == id })?.1["duration"], time.isFinite, time >= 0, time < duration else { throw PreviewFailure.invalid("Choose a poster frame within the video’s duration.") }
            }
            let layout = JSONText.object([("order", .array(order.map { .string($0) })), ("hidden", .array(hidden.map { .string($0) })),
                                          ("posterTimes", .object(order.compactMap { id in posterTimes[id].map { (id, .number($0)) } }))])
            let next = draft.setting("previewLayouts", (draft["previewLayouts"] ?? .object([])).setting(key, layout))
            return (next, try Self.previewSetDraft(next, localizationId: localizationId, type: type))
        }
    }

    /// Copies another language's included previews, reusing the same files; repeating it adds nothing twice.
    public func copyPreviews(accountId: String, appId: String, revisionId: String, targetId: String, sourceId: String) throws -> Int {
        try copyPreviewsWithReceipt(accountId: accountId, appId: appId, revisionId: revisionId, targetId: targetId, sourceId: sourceId).count
    }

    public func copyPreviewsWithReceipt(accountId: String, appId: String, revisionId: String, targetId: String, sourceId: String) throws -> MediaAdditionReceipt {
        try mutateDraft(accountId: accountId, appId: appId, revisionId: revisionId) { draft, sourceJSON in
            let revision = Self.overlay(try JSONDecoder().decode(Revision.self, from: sourceJSON.data), draft: draft)
            guard targetId != sourceId, let version = revision.versions.first(where: { $0.localizations.contains { $0.id == targetId } }),
                  version.localizations.contains(where: { $0.id == sourceId }) else { throw PreviewFailure.invalid("Choose another language in the same version.") }
            var updated = draft, copied = 0, affected: [String] = []
            for type in PreviewSpecs.types(platform: version.fields["platform"].map(Self.text) ?? "") {
                let originals = Self.previewVideos(draft, localizationId: sourceId, type: type)
                _ = try Self.previewSetDraft(draft, localizationId: sourceId, type: type)
                let layout = draft["previewLayouts"]?["\(sourceId):\(type)"], hidden = Set(Self.strings(layout?["hidden"]))
                let included = (layout.map { Self.strings($0["order"]) } ?? originals.map(\.0)).filter { !hidden.contains($0) }.compactMap { id in originals.first { $0.0 == id } }
                var existing: [String: Int] = [:]
                for video in Self.previewVideos(updated, localizationId: targetId, type: type) { if let hash = video.1["sha256"]?.text { existing[hash, default: 0] += 1 } }
                for (originalId, original) in included {
                    guard let hash = original["sha256"]?.text else { continue }
                    if let count = existing[hash], count > 0 { existing[hash] = count - 1; continue }
                    let id = "preview-\(UUID().uuidString.lowercased())"
                    guard case .object(var fields) = original else { continue }
                    fields = fields.map { $0.0 == "id" ? ($0.0, .string(id)) : $0.0 == "localizationId" ? ($0.0, .string(targetId)) : $0 }
                    var time = 5.0
                    if case .number(let saved)? = layout?["posterTimes"]?[originalId] { time = saved }
                    updated = try Self.addingPreview(updated, video: .object(fields), id: id, key: "\(targetId):\(type)", existing: Self.previewVideos(updated, localizationId: targetId, type: type).map(\.0), posterTime: time)
                    copied += 1
                    if !affected.contains(type) { affected.append(type) }
                }
            }
            let changes = try affected.map { type in
                MediaCatalogChange(before: .previews(localizationId: targetId, type: type, draft: try Self.previewSetDraft(draft, localizationId: targetId, type: type)),
                                   after: .previews(localizationId: targetId, type: type, draft: try Self.previewSetDraft(updated, localizationId: targetId, type: type)))
            }
            return (updated, MediaAdditionReceipt(scope: .init(accountId: accountId, appId: appId, revisionId: revisionId), count: copied, changes: changes))
        }
    }
}
