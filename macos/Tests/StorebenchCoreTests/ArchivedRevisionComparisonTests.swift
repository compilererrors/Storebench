import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct ArchivedRevisionComparisonTests {
    init() throws { _ = try TestIsolation.require() }
    private let older = "00000000-0000-4000-8000-000000000001", newer = "00000000-0000-4000-8000-000000000002"
    private func fixture() throws -> JSONText { try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/revision-history.json"))) }
    private func list(_ value: JSONText?) throws -> [JSONText] { guard case .array(let values)? = value else { throw RevisionHistoryFailure.invalid }; return values }
    private func archive(_ value: JSONText, documentRevision: Int) throws -> ArchivedRevision {
        try ArchivedRevision(value, accountId: "synthetic-account", appId: "1000000001", id: #require(value["id"]?.text), documentRevision: documentRevision)
    }
    private func check(_ shots: [LibraryChooser.Shot], expected: [JSONText], revision: ArchivedRevision) throws {
        #expect(shots.count == expected.count && Set(shots.map(\.id)).count == shots.count)
        for (shot, expected) in zip(shots, expected) {
            guard case .number(let rawIndex)? = expected["index"], let index = Int(exactly: rawIndex) else { throw RevisionHistoryFailure.invalid }
            let image = try #require(expected["image"])
            #expect(shot.index == index && shot.value == image && shot.id == revision.id + "/" + String(index))
            #expect(shot.source.accountId == "synthetic-account" && shot.source.appId == "1000000001" && shot.source.revisionId == revision.id)
            #expect(shot.source.itemId == image["id"]?.text && shot.galleryItem.id == shot.id && !shot.galleryItem.local)
            #expect(shot.source.kind == .archivedScreenshot(index: index, hash: try #require(image["sha256"]?.text), documentRevision: revision.documentRevision))
        }
    }
    @Test func completePrimaryChangesAndGalleryPositionsMatchIncludingDuplicateKeysAndTitles() throws {
        let vectors = try list(fixture()["vectors"]); #expect(vectors.count >= 39)
        for vector in vectors where vector["rejected"] != .bool(true) {
            let before = try archive(#require(vector["before"]), documentRevision: 17), after = try archive(#require(vector["after"]), documentRevision: 23)
            let comparison = try ArchivedRevisionComparison(before: before, after: after), expected = try list(vector["galleries"])
            #expect(comparison.changes.count == expected.count)
            #expect(JSONText.array(comparison.changes.map(\.value.json)).stringify() == vector["expected"]?.stringify())
            for (change, expected) in zip(comparison.changes, expected) {
                #expect(change.value.json.stringify() == expected["change"]?.stringify())
                try check(change.beforeScreenshots, expected: list(expected["before"]), revision: before)
                try check(change.afterScreenshots, expected: list(expected["after"]), revision: after)
            }
        }
        let benchmark = try #require(fixture()["benchmark"])
        let before = try archive(#require(benchmark["before"]), documentRevision: 2), after = try archive(#require(benchmark["after"]), documentRevision: 3)
        let comparison = try ArchivedRevisionComparison(before: before, after: after), expected = try list(benchmark["galleries"])
        #expect(comparison.changes.count == 1400 && comparison.changes.filter { !$0.beforeScreenshots.isEmpty }.count == 200)
        for (change, expected) in zip(comparison.changes, expected) {
            try check(change.beforeScreenshots, expected: list(expected["before"]), revision: before)
            try check(change.afterScreenshots, expected: list(expected["after"]), revision: after)
        }
    }
    @Test func comparisonRequiresPositiveDocumentRevisionsAndTheSameAccountAndApp() throws {
        let vectors = try list(fixture()["vectors"]), first = try #require(vectors.first), before = try #require(first["before"]), after = try #require(first["after"])
        for invalid in [0, -1] {
            #expect(throws: RevisionHistoryFailure.invalid) { try ArchivedRevisionComparison(before: archive(before, documentRevision: invalid), after: archive(after, documentRevision: 1)) }
            #expect(throws: RevisionHistoryFailure.invalid) { try ArchivedRevisionComparison(before: archive(before, documentRevision: 1), after: archive(after, documentRevision: invalid)) }
        }
        for name in ["foreign account", "foreign app"] {
            let vector = try #require(vectors.first { $0["name"]?.text == name }), foreign = try #require(vector["after"])
            let source = try ConnectedApps.savedRevision(foreign, accountId: #require(foreign["account"]?["id"]?.text), appId: #require(foreign["app"]?["id"]?.text), id: #require(foreign["id"]?.text), documentRevision: 1)
            #expect(throws: RevisionHistoryFailure.invalid) { try ArchivedRevisionComparison(before: archive(before, documentRevision: 1), after: source) }
        }
    }
    private func seed(_ session: WorkspaceSession, name: String) async throws -> [String: Data] {
        let vector = try #require(try list(fixture()["vectors"]).first { $0["name"]?.text == name })
        let original = try Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/chooser-image.png"))
        let second = original + Data([37]), third = original + Data([38])
        var media: [String: Data] = [:]
        var hashes: [String] = []
        for bytes in [original, second, third] {
            let hash = try await session.media.write(bytes).hash; hashes.append(hash); media[hash] = bytes
        }
        for side in ["before", "after"] {
            let source = try #require(vector[side]), id = try #require(source["id"]?.text)
            let json = Data(source.stringify().replacingOccurrences(of: String(repeating: "b", count: 64), with: hashes[1]).replacingOccurrences(of: String(repeating: "c", count: 64), with: hashes[2]).utf8)
            try await session.storeAccess { store in
                try store.transaction { _ in [.put(namespace: "revisions", key: "synthetic-account:1000000001:" + id, json: json)] }
            }
        }
        return media
    }
    @Test func scopedGalleryPreservesEveryOriginalAndOrderAcrossLocalDraftChanges() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let media = try await seed(session, name: "repeated hashes with distinct saved screenshot ids")
        let comparison = try await session.archivedRevisionComparison(accountId: "synthetic-account", appId: "1000000001", beforeId: older, afterId: newer)
        let change = try #require(comparison.changes.first { $0.value.type == "screenshots" })
        #expect(change.beforeScreenshots.count == 1 && change.afterScreenshots.count == 3)
        #expect(change.afterScreenshots.map(\.source.itemId) == ["shot-1", "synthetic-shot-2", "synthetic-shot-3"])
        #expect(change.afterScreenshots.first?.galleryItem.sha256 == change.afterScreenshots.last?.galleryItem.sha256)
        _ = try await session.addScreenshots(accountId: "synthetic-account", appId: "1000000001", revisionId: comparison.after.id, localizationId: "version-locale-1", setId: "set-1", files: [("synthetic-local.png", syntheticPNG(width: 1290, height: 2796))])
        let set = try await session.screenshotSet(accountId: "synthetic-account", appId: "1000000001", revisionId: comparison.after.id, setId: "set-1")
        _ = try await session.saveScreenshotLayout(accountId: "synthetic-account", appId: "1000000001", revisionId: comparison.after.id, setId: "set-1", order: Array(set.items.map(\.id).reversed()), hidden: set.items.map(\.id), expected: set.signature)
        for (index, shot) in (change.beforeScreenshots + change.afterScreenshots).enumerated() {
            let reader = try await session.openSavedMedia(shot.source); defer { reader.close() }
            let original = try #require(media[shot.galleryItem.sha256])
            #expect(try await reader.imageBytes() == original)
            let destination = root.appendingPathComponent("synthetic-history-original-\(index).png")
            try await reader.export(to: destination)
            #expect(try Data(contentsOf: destination) == original)
        }
        #expect(session.lifetime.activeCount == 0)
        let again = try await session.archivedRevisionComparison(accountId: "synthetic-account", appId: "1000000001", beforeId: comparison.before.id, afterId: comparison.after.id)
        #expect(again.changes.map(\.value.json) == comparison.changes.map(\.value.json))
    }
    @Test func sameSectionTitlesSelectTheExactVersionImages() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let media = try await seed(session, name: "identical section titles retain separate version galleries")
        let comparison = try await session.archivedRevisionComparison(accountId: "synthetic-account", appId: "1000000001", beforeId: older, afterId: newer)
        let changes = comparison.changes.filter { $0.value.type == "screenshots" }
        #expect(changes.count == 2 && changes[0].value.section == changes[1].value.section && changes[0].value.label == changes[1].value.label)
        #expect(changes.map { $0.afterScreenshots.map(\.index) } == [[0, 1], [2, 3]])
        #expect(changes[0].afterScreenshots[1].galleryItem.sha256 != changes[1].afterScreenshots[0].galleryItem.sha256)
        for shot in changes.flatMap(\.afterScreenshots) {
            let reader = try await session.openSavedMedia(shot.source); defer { reader.close() }
            #expect(try await reader.imageBytes() == media[shot.galleryItem.sha256])
        }
    }
    @Test func legacyImagesWithoutDimensionsDecodeAndExportButInvalidProvidedDimensionsAreRejected() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let media = try await seed(session, name: "missing archived image dimensions")
        let comparison = try await session.archivedRevisionComparison(accountId: "synthetic-account", appId: "1000000001", beforeId: older, afterId: newer)
        let shots = try #require(comparison.changes.first { $0.value.type == "screenshots" }?.afterScreenshots)
        #expect(shots.count == 2 && shots.allSatisfy { $0.width == 0 && $0.height == 0 })
        for (index, shot) in shots.enumerated() {
            let reader = try await session.openSavedMedia(shot.source); defer { reader.close() }
            let bytes = try await reader.imageBytes(), decoded = try await ScreenshotRenderer.loadAsync(bytes)
            #expect(decoded.width == 1 && decoded.height == 1 && bytes == media[shot.galleryItem.sha256])
            let destination = root.appendingPathComponent("synthetic-legacy-original-\(index).png")
            try await reader.export(to: destination); #expect(try Data(contentsOf: destination) == bytes)
        }
        let archive = comparison.after.value
        for invalid in [JSONText.number(0), .number(-1), .number(1.5), .number(9_007_199_254_740_992), .null, .string("1")] {
            let json = Data(archive.stringify().replacingOccurrences(of: "\"contentType\":\"image/png\"", with: "\"width\":\(invalid.stringify()),\"contentType\":\"image/png\"").utf8)
            try await session.storeAccess { store in
                try store.transaction { _ in [.put(namespace: "revisions", key: "synthetic-account:1000000001:" + newer, json: json)] }
            }
            let refreshed = try await session.archivedRevisionComparison(accountId: "synthetic-account", appId: "1000000001", beforeId: older, afterId: newer)
            let shot = try #require(refreshed.changes.first { $0.value.type == "screenshots" }?.afterScreenshots.first)
            await #expect(throws: SavedMediaFailure.format) { try await session.openSavedMedia(shot.source) }
        }
        #expect(session.lifetime.activeCount == 0)
    }
    @Test func replacedDeletedForeignCancelledAndClosedSourcesCannotReadOrReplaceAnExport() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await seed(session, name: "screenshot order and duplicates")
        let comparison = try await session.archivedRevisionComparison(accountId: "synthetic-account", appId: "1000000001", beforeId: older, afterId: newer)
        let shot = try #require(comparison.changes.first { $0.value.type == "screenshots" }?.afterScreenshots.first)
        let reader = try await session.openSavedMedia(shot.source); defer { reader.close() }
        try await session.storeAccess { store in
            let key = "synthetic-account:1000000001:" + comparison.after.id, saved = try #require(try store.document(namespace: "revisions", key: key))
            try store.transaction { _ in [.put(namespace: "revisions", key: key, json: saved.payload)] }
        }
        await #expect(throws: SavedMediaFailure.changed) { try await reader.read(0..<1) }
        let destination = root.appendingPathComponent("synthetic-preserved-original.png"), preserved = Data("Synthetic existing destination".utf8)
        try preserved.write(to: destination)
        await #expect(throws: SavedMediaFailure.changed) { try await reader.export(to: destination) }
        #expect(try Data(contentsOf: destination) == preserved)
        let fresh = try await session.archivedRevisionComparison(accountId: "synthetic-account", appId: "1000000001", beforeId: comparison.before.id, afterId: comparison.after.id)
        #expect(fresh.after.documentRevision == comparison.after.documentRevision + 1)
        let freshShot = try #require(fresh.changes.first { $0.value.type == "screenshots" }?.afterScreenshots.first)
        let freshReader = try await session.openSavedMedia(freshShot.source); defer { freshReader.close() }
        #expect(try await session.deleteArchivedRevision(accountId: "synthetic-account", appId: "1000000001", revisionId: fresh.after.id, expectedRevision: fresh.after.documentRevision))
        await #expect(throws: RevisionHistoryFailure.missing) { try await freshReader.read(0..<1) }
        await #expect(throws: RevisionHistoryFailure.missing) { try await freshReader.export(to: destination) }
        #expect(try Data(contentsOf: destination) == preserved)
        await #expect(throws: RevisionHistoryFailure.invalid) { try await session.archivedRevisionComparison(accountId: "synthetic-foreign", appId: "1000000001", beforeId: comparison.before.id, afterId: comparison.before.id) }
        let cancelled = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await session.archivedRevisionComparison(accountId: "synthetic-account", appId: "1000000001", beforeId: comparison.before.id, afterId: comparison.before.id) }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        try await session.signOut()
        await #expect(throws: SessionFailure.closed) { try await session.archivedRevisionComparison(accountId: "synthetic-account", appId: "1000000001", beforeId: comparison.before.id, afterId: comparison.before.id) }
        #expect(session.lifetime.activeCount == 0)
    }
}
