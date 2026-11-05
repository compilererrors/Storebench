import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct SavedMediaTests {
    init() throws { _ = try TestIsolation.require() }
    private func screenshot(_ session: WorkspaceSession, account: String, bytes: Data) async throws -> SavedMediaSource {
        _ = try await session.addScreenshots(accountId: account, appId: "1000000001", revisionId: "00000000-0000-4000-8000-000000000002", localizationId: "version-locale-1", setId: "set-1", files: [("synthetic-original.png", bytes)])
        let set = try await session.screenshotSet(accountId: account, appId: "1000000001", revisionId: "00000000-0000-4000-8000-000000000002", setId: "set-1")
        return SavedMediaSource(accountId: account, appId: "1000000001", revisionId: "00000000-0000-4000-8000-000000000002", itemId: try #require(set.items.last?.id), kind: .screenshot(setId: "set-1"))
    }

    @Test func requestsClampToExactEofWithoutOverflowOrLargeAllocations() throws {
        #expect(try MediaReadPolicy.end(length: 100, offset: 80, requested: Int.max, toEnd: false) == 100)
        #expect(try MediaReadPolicy.end(length: 100, offset: 80, requested: 1, toEnd: true) == 100)
        #expect(try MediaReadPolicy.next(length: 100, current: 100, end: 100) == nil)
        #expect(try MediaReadPolicy.next(length: 3_000_000, current: 100, end: 3_000_000) == 100..<1_048_676)
        for offset in [-1, 101, Int64.max] {
            #expect(throws: SavedMediaFailure.range) { try MediaReadPolicy.end(length: 100, offset: Int64(offset), requested: 1, toEnd: false) }
        }
        #expect(throws: SavedMediaFailure.range) { try MediaReadPolicy.end(length: 100, offset: 0, requested: -1, toEnd: false) }
        #expect(throws: SavedMediaFailure.range) { try MediaReadPolicy.next(length: 100, current: 60, end: 50) }
        #expect(MediaReadPolicy.posterMaximum(duration: 20) == 19.99)
        #expect(MediaReadPolicy.poster(19.99, duration: 20) == 19.99)
        #expect(MediaReadPolicy.poster(500, duration: 20) == 19.99 && MediaReadPolicy.poster(-1, duration: 20) == 0)
        #expect(MediaReadPolicy.poster(.nan, duration: 20) == 5 && MediaReadPolicy.posterMaximum(duration: .infinity) == 0)
    }

    @Test func namesPreserveUnicodeWithoutPathsControlsOrBrokenGraphemes() {
        #expect(MediaReadPolicy.exportName("../synthetic\\clip\n.MOV", extension: "mov") == ".._synthetic_clip_.mov")
        let name = MediaReadPolicy.exportName(String(repeating: "👩‍🔬", count: 40) + ".png", extension: "png")
        #expect(name.hasSuffix(".png") && name.dropLast(4).utf16.count <= 150)
        #expect(name.dropLast(4).allSatisfy { $0 == "👩‍🔬" })
        #expect(MediaReadPolicy.exportName("", extension: "jpg") == "Media.jpg")
    }

    @Test func lateAndCancelledRequestsCannotDeliverOrFinishTheirReplacements() {
        var tickets = MediaRequestTickets<String>()
        let first = tickets.begin("synthetic-request"), other = tickets.begin("synthetic-other")
        tickets.cancel("synthetic-request")
        #expect(!tickets.contains("synthetic-request", token: first) && tickets.contains("synthetic-other", token: other))
        let replacement = tickets.begin("synthetic-request")
        let lateFinish = tickets.finish("synthetic-request", token: first)
        #expect(!lateFinish && tickets.contains("synthetic-request", token: replacement))
        let finished = tickets.finish("synthetic-request", token: replacement), duplicate = tickets.finish("synthetic-request", token: replacement)
        #expect(finished && !duplicate && tickets.contains("synthetic-other", token: other))
        tickets.cancelAll(); #expect(!tickets.contains("synthetic-other", token: other))
    }

    @Test func originalImageReadsAreScopedBoundedAndUseAnOpaqueExactAddress() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first)
        let bytes = syntheticPNG(width: 1290, height: 2796) + Data(repeating: 37, count: MediaReadPolicy.chunkBytes * 2 + 31)
        let source = try await screenshot(session, account: account.id, bytes: bytes), reader = try await session.openSavedMedia(source)
        defer { reader.close() }
        #expect(reader.length == bytes.count && reader.contentType == "public.png" && reader.fileName == "synthetic-original.png")
        #expect(reader.accepts(reader.address))
        #expect(!reader.accepts(URL(string: "https://example.invalid/synthetic.mp4")) && !reader.accepts(URL(fileURLWithPath: root.appendingPathComponent("synthetic.mp4").path)))
        #expect(!reader.address.absoluteString.contains(account.id) && !reader.address.absoluteString.contains(reader.hash))
        let range = MediaReadPolicy.chunkBytes - 7..<MediaReadPolicy.chunkBytes + 19
        #expect(try await reader.read(range) == bytes.subdata(in: range))
        #expect(try await reader.imageBytes() == bytes)
        await #expect(throws: SavedMediaFailure.range) { try await reader.read(0..<bytes.count) }
        await #expect(throws: SavedMediaFailure.range) { try await reader.read(0..<0) }
        await #expect(throws: SavedMediaFailure.range) { try await reader.read(bytes.count..<bytes.count + 1) }
        let foreign = SavedMediaSource(accountId: "synthetic-foreign", appId: source.appId, revisionId: source.revisionId, itemId: source.itemId, kind: source.kind)
        await #expect(throws: RevisionHistoryFailure.invalid) { try await session.openSavedMedia(foreign) }
        let wrongSet = SavedMediaSource(accountId: account.id, appId: source.appId, revisionId: source.revisionId, itemId: source.itemId, kind: .screenshot(setId: "synthetic-other-set"))
        await #expect(throws: ScreenshotFailure.notFound) { try await session.openSavedMedia(wrongSet) }
        reader.close()
        await #expect(throws: SavedMediaFailure.changed) { try await reader.read(0..<1) }
    }

    @Test func encryptedOriginalExportsPreserveDestinationsAfterAuthenticationFailure() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first)
        let bytes = syntheticPNG(width: 1290, height: 2796) + Data(repeating: 41, count: MediaReadPolicy.chunkBytes * 2)
        let source = try await screenshot(session, account: account.id, bytes: bytes), reader = try await session.openSavedMedia(source)
        defer { reader.close() }
        let destination = root.appendingPathComponent("synthetic-export.png")
        try await reader.export(to: destination)
        #expect(try Data(contentsOf: destination) == bytes)
        #expect((try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let preserved = Data("Synthetic existing destination".utf8); try preserved.write(to: destination)
        let media = await session.media, encrypted = try media.fileURL(reader.hash), file = try FileHandle(forUpdating: encrypted)
        let offset = UInt64(EncryptedMediaStore.headerLength + EncryptedMediaStore.chunkLength + EncryptedMediaStore.tagLength + 7)
        try file.seek(toOffset: offset); let byte = try #require(try file.read(upToCount: 1)?.first)
        try file.seek(toOffset: offset); try file.write(contentsOf: Data([byte ^ 1])); try file.close()
        await #expect(throws: EncryptedMediaStore.Failure.authentication) { try await reader.export(to: destination) }
        #expect(try Data(contentsOf: destination) == preserved)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".storebench-export-") }.isEmpty)
    }

    @Test func removedCatalogEntriesCannotContinueReadingOrExporting() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first)
        let source = try await screenshot(session, account: account.id, bytes: syntheticPNG(width: 1290, height: 2796)), reader = try await session.openSavedMedia(source)
        defer { reader.close() }
        try await session.removeScreenshotUpload(accountId: account.id, appId: source.appId, revisionId: source.revisionId, uploadId: source.itemId)
        await #expect(throws: SavedMediaFailure.missing) { try await reader.read(0..<1) }
        let destination = root.appendingPathComponent("synthetic-kept.png"), preserved = Data("Synthetic retained bytes".utf8)
        try preserved.write(to: destination)
        await #expect(throws: SavedMediaFailure.missing) { try await reader.export(to: destination) }
        #expect(try Data(contentsOf: destination) == preserved)
    }

    @Test func previewReadsAndPosterSavesKeepOriginalBytesAndHundredthPrecision() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), bytes = syntheticMovie()
        let file = root.appendingPathComponent("synthetic-preview.mp4"); try bytes.write(to: file)
        let revision = "00000000-0000-4000-8000-000000000002", app = "1000000001"
        try await session.addPreview(accountId: account.id, appId: app, revisionId: revision, localizationId: "version-locale-1", type: "IPHONE_67", file: file)
        let set = try await session.previewSet(accountId: account.id, appId: app, revisionId: revision, localizationId: "version-locale-1", type: "IPHONE_67"), item = try #require(set.items.first)
        let reader = try await session.openSavedMedia(SavedMediaSource(accountId: account.id, appId: app, revisionId: revision, itemId: item.id, kind: .preview(localizationId: "version-locale-1", type: "IPHONE_67")))
        defer { reader.close() }
        #expect(reader.contentType == "public.mpeg-4" && reader.duration == 20 && reader.fileName == "synthetic-preview.mp4")
        #expect(try await reader.read(0..<bytes.count) == bytes)
        await #expect(throws: SavedMediaFailure.format) { try await reader.imageBytes() }
        let saved = try await session.savePreviewLayout(accountId: account.id, appId: app, revisionId: revision, localizationId: "version-locale-1", type: "IPHONE_67", order: [item.id], hidden: [], posterTimes: [item.id: 19.99], expected: set.signature)
        #expect(saved.posterTimes[item.id] == 19.99)
        let destination = root.appendingPathComponent("synthetic-downloaded.mp4"); try await reader.export(to: destination)
        #expect(try Data(contentsOf: destination) == bytes)
    }

    @Test func concurrentIntervalsAndCancellationRemainOwnedAndIdleReadersDoNotBlockSignOut() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), bytes = syntheticPNG(width: 1290, height: 2796) + Data(repeating: 43, count: MediaReadPolicy.chunkBytes * 2)
        let source = try await screenshot(session, account: account.id, bytes: bytes), reader = try await session.openSavedMedia(source)
        defer { reader.close() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for offset in [0, 1, MediaReadPolicy.chunkBytes - 9, MediaReadPolicy.chunkBytes + 7] {
                group.addTask { () async throws -> Void in
                    let result = try await reader.read(offset..<offset + 31)
                    #expect(result == bytes.subdata(in: offset..<offset + 31))
                }
            }
            try await group.waitForAll()
        }
        let destination = root.appendingPathComponent("synthetic-cancelled.png"), preserved = Data("Synthetic preserved output".utf8); try preserved.write(to: destination)
        let owned = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await reader.export(to: destination)
        }
        await #expect(throws: CancellationError.self) { try await owned.value }
        #expect(try Data(contentsOf: destination) == preserved && session.lifetime.activeCount == 0)
        try await session.signOut()
        await #expect(throws: SessionFailure.closed) { try await reader.read(0..<1) }
        #expect(session.lifetime.activeCount == 0)
    }
}
