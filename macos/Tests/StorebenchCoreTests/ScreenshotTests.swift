import Foundation
import Testing
@testable import StorebenchCore

/// A synthetic PNG header: dimensions and color type are all the checks read.
func syntheticPNG(width: Int, height: Int, color: UInt8 = 2, seed: UInt8 = 0) -> Data {
    func be(_ value: Int) -> [UInt8] { [UInt8(value >> 24 & 0xff), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)] }
    var bytes: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10] + be(13) + Array("IHDR".utf8) + be(width) + be(height) + [8, color, 0, 0, 0] + [0, 0, 0, 0]
    bytes += be(1) + Array("IDAT".utf8) + [seed] + [0, 0, 0, 0] + be(0) + Array("IEND".utf8) + [0, 0, 0, 0]
    return Data(bytes)
}

func syntheticJPEG(width: Int, height: Int, orientation: UInt16? = nil) -> Data {
    var bytes: [UInt8] = [0xff, 0xd8]
    if let orientation {
        let exif: [UInt8] = Array("Exif\0\0".utf8) + Array("MM".utf8) + [0, 42, 0, 0, 0, 8, 0, 1, 0x01, 0x12, 0, 3, 0, 0, 0, 1, UInt8(orientation >> 8), UInt8(orientation & 0xff), 0, 0, 0, 0, 0, 0]
        bytes += [0xff, 0xe1, UInt8((exif.count + 2) >> 8), UInt8((exif.count + 2) & 0xff)] + exif
    }
    bytes += [0xff, 0xfe, 0, 10] + Array("synthetc".utf8)
    bytes += [0xff, 0xc0, 0, 17, 8, UInt8(height >> 8), UInt8(height & 0xff), UInt8(width >> 8), UInt8(width & 0xff), 3] + [UInt8](repeating: 0, count: 9)
    bytes += [0xff, 0xda, 0, 2, 0, 0, 0xff, 0xd9]
    return Data(bytes)
}

@Suite(.serialized) struct ScreenshotTests {
    init() throws { _ = try TestIsolation.require() }
    private func replacingFirstShot(_ source: JSONText, with shot: JSONText) throws -> JSONText {
        var versions = WorkspaceSession.items(source["versions"]), languages = WorkspaceSession.items(versions.first?["localizations"]), sets = WorkspaceSession.items(languages.first?["screenshotSets"])
        guard !versions.isEmpty, !languages.isEmpty, !sets.isEmpty else { throw DraftFailure.invalid }
        sets[0] = sets[0].setting("screenshots", .array([shot]))
        languages[0] = languages[0].setting("screenshotSets", .array(sets))
        versions[0] = versions[0].setting("localizations", .array(languages))
        return source.setting("versions", .array(versions))
    }

    @Test func legacyImagesRemainInTypedHistoryAndLayoutsWithoutInventingGeometry() async throws {
        let fixture = try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/app-material.json")))
        let vectors = WorkspaceSession.items(fixture["details"]).filter { $0["name"]?.text?.hasPrefix("legacy ") == true }
        #expect(vectors.count == 3)
        for vector in vectors {
            #expect(vector["rejected"] == nil && vector["expected"] != nil)
            let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
            let account = "synthetic-account", app = "1000000001", revision = "00000000-0000-4000-8000-000000000002"
            let source = try #require(vector["revision"]), bytes = try syntheticEditableScreenshot()
            let media = await session.media, hash = try media.write(bytes).hash
            let version = try #require(WorkspaceSession.items(source["versions"]).first)
            let language = try #require(WorkspaceSession.items(version["localizations"]).first), set = try #require(WorkspaceSession.items(language["screenshotSets"]).first)
            let original = try #require(WorkspaceSession.items(set["screenshots"]).first)
            let shot = original.setting("sha256", .string(hash)), updated = try replacingFirstShot(source, with: shot), frozen = updated.data, key = "\(account):\(app):\(revision)"
            try await session.storeAccess { store in
                try store.transaction { current in
                    guard try current("revisions", key)?.revision == 1 else { throw DraftFailure.stale }
                    return [.put(namespace: "revisions", key: key, json: frozen)]
                }
            }
            let saved = try #require(try await session.revisions(accountId: account, appId: app).first { $0.id == revision })
            let typed = try #require(saved.versions.first?.localizations.first?.screenshotSets.first?.screenshots.first)
            #expect((typed.width == nil) == (shot["width"] == nil) && (typed.height == nil) == (shot["height"] == nil))
            let roundTrip = try JSONText.parse(JSONEncoder().encode(typed))
            #expect((roundTrip["width"] == nil) == (shot["width"] == nil) && (roundTrip["height"] == nil) == (shot["height"] == nil))
            let layout = try await session.screenshotSet(accountId: account, appId: app, revisionId: revision, setId: "set-1")
            #expect(layout.items.count == 1 && layout.items[0].width == typed.width && layout.items[0].height == typed.height)
            let catalog = try await session.screenshotCatalog(accountId: account, appId: app, revisionId: revision, localizationId: "version-locale-1")
            #expect(catalog.first?.items == layout.items && catalog.first?.signature == layout.signature)
            let hidden = try await session.saveScreenshotLayout(accountId: account, appId: app, revisionId: revision, setId: "set-1", order: layout.items.map(\.id), hidden: ["shot-1"], expected: layout.signature)
            #expect(hidden.hidden == ["shot-1"] && hidden.items[0].width == typed.width && hidden.items[0].height == typed.height)
            let reader = try await session.openSavedMedia(.init(accountId: account, appId: app, revisionId: revision, itemId: "shot-1", kind: .screenshot(setId: "set-1")))
            defer { reader.close() }
            let originalBytes = try await reader.imageBytes(), decoded = try await ScreenshotRenderer.loadAsync(originalBytes)
            #expect(originalBytes == bytes)
            #expect(decoded.width == 16 && decoded.height == 8)
            let destination = root.appendingPathComponent("synthetic-legacy-original.png")
            try await reader.export(to: destination)
            #expect(try Data(contentsOf: destination) == bytes)
            #expect(try await session.storeAccess { try $0.document(namespace: "revisions", key: key)?.payload } == frozen)
            // Showing an old original is allowed; a new upload still requires both verified dimensions.
            _ = try await session.saveScreenshotLayout(accountId: account, appId: app, revisionId: revision, setId: "set-1", order: hidden.items.map(\.id), hidden: [], expected: hidden.signature)
            let target = try await session.addLanguage(accountId: account, appId: app, revisionId: revision, versionId: "version-1", locale: "sv", copyFrom: nil)
            let beforeCopy = try await session.storeAccess { try $0.document(namespace: "drafts", key: key)?.payload }
            await #expect(throws: ScreenshotFailure.self) { try await session.copyScreenshots(accountId: account, appId: app, revisionId: revision, targetId: target, sourceId: "version-locale-1") }
            #expect(try await session.storeAccess { try $0.document(namespace: "drafts", key: key)?.payload } == beforeCopy)
        }
    }

    @Test func presentInvalidImportedDimensionsAreRejected() throws {
        let fixture = try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/app-material.json")))
        let cases = WorkspaceSession.items(fixture["details"]).filter { $0["name"]?.text?.hasPrefix("invalid dimension ") == true || $0["name"]?.text?.hasPrefix("invalid width ") == true || $0["name"]?.text?.hasPrefix("invalid height ") == true }
        #expect(cases.count == 10)
        for item in cases {
            #expect(item["rejected"] == .bool(true))
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(Revision.self, from: #require(item["revision"]).data) }
        }
    }

    @Test func malformedUploadDimensionsCannotTrapOrReplaceALayoutDuringReadsAndCopies() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = "synthetic-account", app = "1000000001", revision = "00000000-0000-4000-8000-000000000002", key = "\(account):\(app):\(revision)"
        _ = try await session.addScreenshots(accountId: account, appId: app, revisionId: revision, localizationId: "version-locale-1", setId: "set-1", files: [("synthetic-upload.png", syntheticPNG(width: 1290, height: 2796))])
        let target = try await session.addLanguage(accountId: account, appId: app, revisionId: revision, versionId: "version-1", locale: "sv", copyFrom: nil)
        for invalid in [JSONText.null, .number(0), .number(0.5), .number(1e21)] {
            let frozen = try await session.storeAccess { store in
                let saved = try #require(try store.document(namespace: "drafts", key: key)), draft = try JSONText.parse(saved.payload)
                let uploads = WorkspaceSession.uploads(draft).map { ($0.0, $0.1.setting("width", invalid)) }
                let next = draft.setting("uploads", .object(uploads)).data
                try store.transaction { current in
                    guard try current("drafts", key)?.revision == saved.revision else { throw DraftFailure.stale }
                    return [.put(namespace: "drafts", key: key, json: next)]
                }
                return next
            }
            await #expect(throws: DraftFailure.invalid) { try await session.screenshotSet(accountId: account, appId: app, revisionId: revision, setId: "set-1") }
            await #expect(throws: DraftFailure.invalid) { try await session.screenshotCatalog(accountId: account, appId: app, revisionId: revision, localizationId: "version-locale-1") }
            await #expect(throws: DraftFailure.invalid) { try await session.copyScreenshots(accountId: account, appId: app, revisionId: revision, targetId: target, sourceId: "version-locale-1") }
            #expect(try await session.storeAccess { try $0.document(namespace: "drafts", key: key)?.payload } == frozen)
        }
    }

    @Test func imagesAreReadFromTheirHeaders() throws {
        #expect(try ScreenshotSpecs.validate(syntheticPNG(width: 1290, height: 2796)).contentType == "image/png")
        #expect(throws: ScreenshotFailure.self) { try ScreenshotSpecs.validate(syntheticPNG(width: 1290, height: 2796, color: 6)) }
        let jpeg = try ScreenshotSpecs.validate(syntheticJPEG(width: 2796, height: 1290))
        #expect(jpeg.width == 2796 && jpeg.height == 1290 && jpeg.contentType == "image/jpeg")
        #expect(throws: ScreenshotFailure.invalidImage("Rotate the screenshot before adding it: its EXIF orientation is not upright.")) { try ScreenshotSpecs.validate(syntheticJPEG(width: 1290, height: 2796, orientation: 6)) }
        #expect(ScreenshotSpecs.type(platform: "IOS", width: 2796, height: 1290) == "APP_IPHONE_67")
        #expect(ScreenshotSpecs.type(platform: "IOS", width: 1000, height: 1000) == nil)
        #expect(ScreenshotSpecs.fileName("../Hem/skärm.PNG", contentType: "image/png") == ".._Hem_skärm.png")
    }

    @Test func catalogKeepsEveryImportedAndAddedSizeWithItsExactSavedLayout() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = "synthetic-account", app = "1000000001", revision = "00000000-0000-4000-8000-000000000002", language = "version-locale-1"
        _ = try await session.addScreenshots(accountId: account, appId: app, revisionId: revision, localizationId: language, setId: nil,
            files: [("synthetic-phone.png", syntheticPNG(width: 1290, height: 2796)), ("synthetic-tablet.png", syntheticPNG(width: 2048, height: 2732))])
        let initial = try await session.screenshotCatalog(accountId: account, appId: app, revisionId: revision, localizationId: language)
        #expect(initial.count == 2)
        for set in initial {
            let order = Array(set.items.map(\.id).reversed())
            _ = try await session.saveScreenshotLayout(accountId: account, appId: app, revisionId: revision, setId: set.setId, order: order,
                hidden: Array(order.prefix(1)), expected: set.signature)
        }
        let saved = try await session.screenshotCatalog(accountId: account, appId: app, revisionId: revision, localizationId: language)
        #expect(saved.map(\.setId) == initial.map(\.setId))
        for set in saved {
            let single = try await session.screenshotSet(accountId: account, appId: app, revisionId: revision, setId: set.setId)
            #expect(set.displayType == single.displayType && set.items == single.items && set.hidden == single.hidden && set.signature == single.signature)
            #expect(set.items.map(\.id) == initial.first(where: { $0.setId == set.setId })?.items.map(\.id).reversed().map { $0 })
        }
        await #expect(throws: ScreenshotFailure.notFound) { try await session.screenshotCatalog(accountId: account, appId: app, revisionId: revision, localizationId: "synthetic-missing-language") }
    }

    @Test func uploadsJoinTheirSizeAndTheLayoutKeepsTenSelected() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first)
        let revision = "00000000-0000-4000-8000-000000000002", app = "1000000001"
        let added = try await session.addScreenshots(accountId: account.id, appId: app, revisionId: revision, localizationId: "version-locale-1", setId: nil,
                                                     files: [("first.png", syntheticPNG(width: 1290, height: 2796, seed: 1)), ("ipad.png", syntheticPNG(width: 2064, height: 2752, seed: 2))])
        #expect(added == 2)
        let iphone = try await session.screenshotSet(accountId: account.id, appId: app, revisionId: revision, setId: "set-1")
        #expect(iphone.items.map(\.id).first == "shot-1" && iphone.items.count == 2 && iphone.items.last?.local == true && iphone.items.last?.fileName == "first.png")
        #expect(try await session.mediaBytes(try #require(iphone.items.last?.sha256)) == syntheticPNG(width: 1290, height: 2796, seed: 1))
        // The iPad image created its own size for this language.
        let source = try #require(try await session.revisions(accountId: account.id, appId: app).first { $0.id == revision })
        let workspace = try await session.workspaceRevision(source, accountId: account.id, appId: app)
        #expect(workspace.versions.first?.localizations.first?.screenshotSets.map(\.displayType) == ["APP_IPHONE_67", "APP_IPAD_PRO_3GEN_129"])

        await #expect(throws: ScreenshotFailure.self) {
            try await session.addScreenshots(accountId: account.id, appId: app, revisionId: revision, localizationId: "version-locale-1", setId: "set-1", files: [("wrong.png", syntheticPNG(width: 1000, height: 1000))])
        }

        let reversed = iphone.items.map(\.id).reversed() as [String]
        try await session.saveScreenshotLayout(accountId: account.id, appId: app, revisionId: revision, setId: "set-1", order: reversed, hidden: ["shot-1"], expected: iphone.signature)
        let saved = try await session.screenshotSet(accountId: account.id, appId: app, revisionId: revision, setId: "set-1")
        #expect(saved.items.map(\.id) == reversed && saved.hidden == ["shot-1"])
        await #expect(throws: ScreenshotFailure.stale) {
            try await session.saveScreenshotLayout(accountId: account.id, appId: app, revisionId: revision, setId: "set-1", order: reversed, hidden: [], expected: iphone.signature)
        }
        // Eight more fill the ten selected slots (one is excluded); the next is refused and the batch adds nothing.
        _ = try await session.addScreenshots(accountId: account.id, appId: app, revisionId: revision, localizationId: "version-locale-1", setId: "set-1",
                                             files: (0..<9).map { ("more-\($0).png", syntheticPNG(width: 1290, height: 2796, seed: UInt8(10 + $0))) })
        await #expect(throws: ScreenshotFailure.self) {
            try await session.addScreenshots(accountId: account.id, appId: app, revisionId: revision, localizationId: "version-locale-1", setId: "set-1", files: [("extra.png", syntheticPNG(width: 1290, height: 2796, seed: 99))])
        }
        let full = try await session.screenshotSet(accountId: account.id, appId: app, revisionId: revision, setId: "set-1")
        #expect(full.items.count == 11 && full.items.count - full.hidden.count == 10)
    }

    @Test func copyingScreenshotsBetweenLanguagesIsRepeatable() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first)
        let revision = "00000000-0000-4000-8000-000000000002", app = "1000000001"
        let swedish = try await session.addLanguage(accountId: account.id, appId: app, revisionId: revision, versionId: "version-1", locale: "sv", copyFrom: nil)
        _ = try await session.addScreenshots(accountId: account.id, appId: app, revisionId: revision, localizationId: "version-locale-1", setId: "set-1", files: [("second.png", syntheticPNG(width: 1290, height: 2796, seed: 3))])
        #expect(try await session.copyScreenshots(accountId: account.id, appId: app, revisionId: revision, targetId: swedish, sourceId: "version-locale-1") == 2)
        #expect(try await session.copyScreenshots(accountId: account.id, appId: app, revisionId: revision, targetId: swedish, sourceId: "version-locale-1") == 0)
        let source = try #require(try await session.revisions(accountId: account.id, appId: app).first { $0.id == revision })
        let set = try #require(try await session.workspaceRevision(source, accountId: account.id, appId: app).versions.first?.localizations.first { $0.id == swedish }?.screenshotSets.first)
        let copied = try await session.screenshotSet(accountId: account.id, appId: app, revisionId: revision, setId: set.id)
        #expect(copied.items.map(\.fileName) == ["sample.png", "second.png"] && copied.items.allSatisfy(\.local))
        await #expect(throws: ScreenshotFailure.self) { try await session.copyScreenshots(accountId: account.id, appId: app, revisionId: revision, targetId: swedish, sourceId: swedish) }
    }
}
