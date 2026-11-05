import Foundation
import Testing
@testable import StorebenchCore

/// A synthetic self-contained H.264 movie: only the container atoms the checks read, with no real video data.
func syntheticMovie(width: Int = 886, height: Int = 1920, seconds: Int = 20, fps: Int = 30, seed: UInt8 = 0, audio: Bool = false) -> Data {
    func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
    func atom(_ type: String, _ payload: [UInt8]) -> [UInt8] { be32(payload.count + 8) + Array(type.utf8) + payload }
    let scale = 600
    let mvhd = atom("mvhd", [0, 0, 0, 0] + be32(0) + be32(0) + be32(scale) + be32(scale * seconds) + [UInt8](repeating: 0, count: 80))
    var matrix = [UInt8](repeating: 0, count: 36); matrix[0...3] = [0, 1, 0, 0]; matrix[16...19] = [0, 1, 0, 0]; matrix[32...35] = [64, 0, 0, 0]
    let tkhd = atom("tkhd", [0, 0, 0, 3] + [UInt8](repeating: 0, count: 36) + matrix + be32(width << 16) + be32(height << 16))
    let mdhd = atom("mdhd", [0, 0, 0, 0] + be32(0) + be32(0) + be32(scale) + be32(scale * seconds) + [0, 0, 0, 0])
    let hdlr = atom("hdlr", [0, 0, 0, 0] + be32(0) + Array("vide".utf8) + [UInt8](repeating: 0, count: 13))
    let dref = atom("dref", [0, 0, 0, 0] + be32(1) + atom("url ", [0, 0, 0, 1]))
    var entry = [UInt8](repeating: 0, count: 78); entry[7] = 1; entry[24] = UInt8(width >> 8); entry[25] = UInt8(width & 0xff); entry[26] = UInt8(height >> 8); entry[27] = UInt8(height & 0xff)
    let stsd = atom("stsd", [0, 0, 0, 0] + be32(1) + atom("avc1", entry))
    let stts = atom("stts", [0, 0, 0, 0] + be32(1) + be32(fps * seconds) + be32(scale / fps))
    let minf = atom("minf", atom("dinf", dref) + atom("stbl", stsd + stts))
    let audioTrack = audio ? atom("trak", atom("mdia", mdhd + atom("hdlr", [0, 0, 0, 0] + be32(0) + Array("soun".utf8) + [UInt8](repeating: 0, count: 13)) + atom("minf", atom("dinf", dref)))) : []
    let moov = atom("moov", mvhd + atom("trak", tkhd + atom("mdia", mdhd + hdlr + minf)) + audioTrack)
    return Data(atom("ftyp", Array("isom".utf8) + [0, 0, 0, 1]) + atom("mdat", [seed, 1, 2, 3, 4, 5, 6, 7]) + moov)
}

@Suite(.serialized) struct PreviewTests {
    init() throws { _ = try TestIsolation.require() }
    func file(_ data: Data, _ name: String) throws -> URL {
        let url = (try TestIsolation.require()).appendingPathComponent("storebench-preview-\(UUID().uuidString)-\(name)")
        try data.write(to: url); return url
    }

    @Test func containerMetadataMatchesSyntheticReferenceResults() throws {
        let url = try file(syntheticMovie(), "a.mp4"); defer { try? FileManager.default.removeItem(at: url) }
        let movie = try PreviewSpecs.read(url)
        #expect(movie == PreviewSpecs.Movie(width: 886, height: 1920, duration: 20, frameRate: 30, codec: "avc1"))
        try PreviewSpecs.validate(movie, type: "IPHONE_67", extension: "mp4")
        #expect(throws: PreviewFailure.invalid("Use 1200 × 1600 · portrait or landscape for this preview size.")) { try PreviewSpecs.validate(movie, type: "IPAD_105", extension: "mp4") }
        let short = try file(syntheticMovie(seconds: 10), "b.mp4"); defer { try? FileManager.default.removeItem(at: short) }
        #expect(throws: PreviewFailure.invalid("App previews must be 15–30 seconds long.")) { try PreviewSpecs.validate(try PreviewSpecs.read(short), type: "IPHONE_67", extension: "mp4") }
        #expect(PreviewSpecs.types(platform: "MAC_OS") == ["DESKTOP"] && PreviewSpecs.types(platform: "IOS").count == 12)
    }

    @Test func malformedStoredGeometryCannotTrapOrHideAnUploadedPreview() throws {
        let video = JSONText.object([("id", .string("synthetic-preview")), ("localizationId", .string("synthetic-language")), ("previewType", .string("IPHONE_67")),
            ("width", .number(886)), ("height", .number(1920)), ("duration", .number(20))])
        for field in ["width", "height"] {
            for invalid in [JSONText.null, .number(-1), .number(0), .number(0.5), .number(1e21), .number(.infinity), .number(.nan)] {
                let draft = JSONText.object([("previewUploads", .object([("synthetic-preview", video.setting(field, invalid))]))])
                #expect(throws: DraftFailure.invalid) { try WorkspaceSession.previewSetDraft(draft, localizationId: "synthetic-language", type: "IPHONE_67") }
            }
        }
        for invalid in [JSONText.null, .number(-1), .number(0), .number(.infinity), .number(.nan)] {
            let draft = JSONText.object([("previewUploads", .object([("synthetic-preview", video.setting("duration", invalid))]))])
            #expect(throws: DraftFailure.invalid) { try WorkspaceSession.previewSetDraft(draft, localizationId: "synthetic-language", type: "IPHONE_67") }
        }
        let valid = try WorkspaceSession.previewSetDraft(.object([("previewUploads", .object([("synthetic-preview", video)]))]), localizationId: "synthetic-language", type: "IPHONE_67")
        #expect(valid.items.count == 1 && valid.items.first?.width == 886 && valid.items.first?.height == 1920 && valid.items.first?.duration == 20)
    }

    @Test func malformedSavedPreviewsFailClosedWithoutChangingEitherLanguage() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = "synthetic-account", app = "1000000001", revision = "00000000-0000-4000-8000-000000000002", key = "\(account):\(app):\(revision)"
        let url = try file(syntheticMovie(), "synthetic.mp4"); defer { try? FileManager.default.removeItem(at: url) }
        try await session.addPreview(accountId: account, appId: app, revisionId: revision, localizationId: "version-locale-1", type: "IPHONE_67", file: url)
        let loaded = try await session.previewSet(accountId: account, appId: app, revisionId: revision, localizationId: "version-locale-1", type: "IPHONE_67")
        let target = try await session.addLanguage(accountId: account, appId: app, revisionId: revision, versionId: "version-1", locale: "sv", copyFrom: nil)
        for invalid in [JSONText.null, .number(0), .number(0.5), .number(1e21)] {
            let frozen = try await session.storeAccess { store in
                let saved = try #require(try store.document(namespace: "drafts", key: key)), draft = try JSONText.parse(saved.payload)
                let uploads = WorkspaceSession.previewVideos(draft, localizationId: "version-locale-1", type: "IPHONE_67").map { ($0.0, $0.1.setting("height", invalid)) }
                let next = draft.setting("previewUploads", .object(uploads)).data
                try store.transaction { current in
                    guard try current("drafts", key)?.revision == saved.revision else { throw DraftFailure.stale }
                    return [.put(namespace: "drafts", key: key, json: next)]
                }; return next
            }
            await #expect(throws: DraftFailure.invalid) { try await session.previewSet(accountId: account, appId: app, revisionId: revision, localizationId: "version-locale-1", type: "IPHONE_67") }
            await #expect(throws: DraftFailure.invalid) { try await session.copyPreviews(accountId: account, appId: app, revisionId: revision, targetId: target, sourceId: "version-locale-1") }
            await #expect(throws: DraftFailure.invalid) {
                try await session.savePreviewLayout(accountId: account, appId: app, revisionId: revision, localizationId: "version-locale-1", type: "IPHONE_67",
                    order: loaded.items.map(\.id), hidden: loaded.items.map(\.id), posterTimes: [:], expected: loaded.signature)
            }
            #expect(try await session.storeAccess { try $0.document(namespace: "drafts", key: key)?.payload } == frozen)
        }
    }

    @Test func previewsAreAddedOrderedAndCopied() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first)
        let revision = "00000000-0000-4000-8000-000000000002", app = "1000000001"
        var urls: [URL] = []
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        for seed in 0..<4 { urls.append(try file(syntheticMovie(seed: UInt8(seed)), "clip\(seed).mp4")) }
        for url in urls.prefix(3) { try await session.addPreview(accountId: account.id, appId: app, revisionId: revision, localizationId: "version-locale-1", type: "IPHONE_67", file: url) }
        await #expect(throws: PreviewFailure.limit) { try await session.addPreview(accountId: account.id, appId: app, revisionId: revision, localizationId: "version-locale-1", type: "IPHONE_67", file: urls[3]) }
        let set = try await session.previewSet(accountId: account.id, appId: app, revisionId: revision, localizationId: "version-locale-1", type: "IPHONE_67")
        #expect(set.items.count == 3 && set.posterTimes.values.allSatisfy { $0 == 5 } && set.items.first?.fileName.hasSuffix("clip0.mp4") == true)
        #expect(try await session.mediaBytes(set.items[0].sha256) == syntheticMovie(seed: 0))

        let order = set.items.map(\.id).reversed() as [String]
        try await session.savePreviewLayout(accountId: account.id, appId: app, revisionId: revision, localizationId: "version-locale-1", type: "IPHONE_67", order: order, hidden: [order[0]], posterTimes: [order[1]: 12.5], expected: set.signature)
        await #expect(throws: PreviewFailure.stale) {
            try await session.savePreviewLayout(accountId: account.id, appId: app, revisionId: revision, localizationId: "version-locale-1", type: "IPHONE_67", order: order, hidden: [], posterTimes: [:], expected: set.signature)
        }
        await #expect(throws: PreviewFailure.self) {
            let fresh = try await session.previewSet(accountId: account.id, appId: app, revisionId: revision, localizationId: "version-locale-1", type: "IPHONE_67")
            try await session.savePreviewLayout(accountId: account.id, appId: app, revisionId: revision, localizationId: "version-locale-1", type: "IPHONE_67", order: order, hidden: [], posterTimes: [order[1]: 25], expected: fresh.signature)
        }
        let swedish = try await session.addLanguage(accountId: account.id, appId: app, revisionId: revision, versionId: "version-1", locale: "sv", copyFrom: nil)
        #expect(try await session.copyPreviews(accountId: account.id, appId: app, revisionId: revision, targetId: swedish, sourceId: "version-locale-1") == 2)
        #expect(try await session.copyPreviews(accountId: account.id, appId: app, revisionId: revision, targetId: swedish, sourceId: "version-locale-1") == 0)
        let copied = try await session.previewSet(accountId: account.id, appId: app, revisionId: revision, localizationId: swedish, type: "IPHONE_67")
        #expect(copied.items.map(\.sha256) == [order[1], order[2]].map { id in set.items.first { $0.id == id }!.sha256 } && copied.posterTimes[copied.items[0].id] == 12.5)
    }
}
