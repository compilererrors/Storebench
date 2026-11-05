import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct LibraryChooserTests {
    init() throws { _ = try TestIsolation.require() }
    func fixture() throws -> JSONText { try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/library-chooser.json"))) }
    func list(_ value: JSONText?) throws -> [JSONText] { guard case .array(let values)? = value else { throw RevisionHistoryFailure.invalid }; return values }
    func populateMedia(_ session: WorkspaceSession) async throws {
        let bytes = try Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/chooser-image.png"))
        _ = try await session.media.write(bytes)
    }
    func row(_ item: JSONText) throws -> ConnectedApps.Row {
        let accountId = try #require(item["accountId"]?.text), appId = try #require(item["appId"]?.text)
        let account = Account(id: accountId, name: "Synthetic chooser account", keyId: "SYNTHKEY01", keyType: "individual", issuerId: nil, appIds: [appId], appNames: [appId: item["configured"]?.text ?? "Synthetic configured app"])
        let latest = item["latest"] == .null ? nil : item["latest"]
        return try ConnectedApps.Row(account: account, app: #require(account.apps.first), savedName: latest?["app"]?["name"]?.text, revisionCount: latest == nil ? 0 : 1, latestImportedAt: latest?["importedAt"]?.text)
    }
    @Test func identicalPollsStayEqualButChangedArchiveRevisionsInvalidatePresentation() throws {
        var checked = 0
        for item in try list(fixture()["projections"]) {
            let row = try row(item), latest = item["latest"] == .null ? nil : item["latest"]
            let original = try LibraryChooser.Entry(row: row, latest: latest)
            let repeated = try LibraryChooser.Entry(row: row, latest: latest)
            #expect(original == repeated)
            if original.screenshots?.isEmpty == false {
                let updated = try LibraryChooser.Entry(row: row, latest: latest, documentRevision: 2)
                #expect(updated != original && updated.languages == original.languages)
                checked += 1
            }
        }
        #expect(checked > 0)
    }
    @Test func allPrimaryGlobalSectionsAndProtectedScopeDestinationsMatchTheActualRegistry() throws {
        let fixture = try fixture(), sections = try list(fixture["sections"])
        #expect(sections.count == 29 && LibraryChooser.sections.count == 29)
        for (section, expected) in zip(LibraryChooser.sections, sections) {
            #expect(section.key == expected["key"]?.text && section.rawValue == expected["label"]?.text && section.group.key == expected["group"]?.text)
            #expect(LibraryChooser.selected(LibraryChooser.selection(section)) == section)
            #expect(LibraryOverview.content(selection: LibraryChooser.selection(section), connecting: false, hasApp: false) == .chooser(section))
            #expect(LibraryOverview.content(selection: LibraryChooser.selection(section), connecting: true, hasApp: true) == .connection)
        }
        #expect(LibraryChooser.selected("library:section:synthetic-unknown") == nil)
        let cases = try list(fixture["destinations"]); #expect(cases.count == 58)
        for item in cases {
            let row = try row(item), key = try #require(item["section"]?.text), section = try #require(AppNavigation.Section(key: key))
            let destination = try LibraryOverview.Destination(row: row, section: section)
            #expect(destination.href == item["expected"]?.text && !destination.href.contains("?"))
            #expect(destination.allowed(accounts: [row.account], decision: .ready))
            #expect(!destination.allowed(accounts: [row.account], decision: .wait, discardConfirmed: true))
            #expect(!destination.allowed(accounts: [], decision: .ready))
            #expect(!destination.allowed(accounts: [row.account], decision: .confirmDiscard))
            #expect(destination.allowed(accounts: [row.account], decision: .confirmDiscard, discardConfirmed: true))
        }
    }
    @Test func latestArchiveNamesLiteralLanguagesAndEveryImageMatchTheActualPrimary() throws {
        let cases = try list(fixture()["projections"]); #expect(cases.count == 10)
        for item in cases {
            let latest = item["latest"] == .null ? nil : item["latest"], entry = try LibraryChooser.Entry(row: row(item), latest: latest)
            #expect(try entry.languages?.map(JSONText.string) == list(item["languages"]))
            #expect(try entry.screenshots?.map(\.value) == list(item["screenshots"]))
            #expect(try entry.preview?.map(\.value) == list(item["preview"]))
            for expected in try list(item["names"]) {
                let key = try #require(expected["section"]?.text), section = try #require(AppNavigation.Section(key: key))
                #expect(TextSemantics.same(entry.name(for: section), expected["expected"]?.text))
            }
            if let images = entry.screenshots {
                #expect(Set(images.map(\.id)).count == images.count)
                for (index, image) in images.enumerated() {
                    #expect(image.index == index && image.source.accountId == entry.row.account.id && image.source.appId == entry.row.app.id)
                    #expect(image.galleryItem.id == image.id && image.galleryItem.sha256 == image.value["sha256"]?.text)
                }
            }
        }
    }
    @Test func unknownHistoryDoesNotInventEmptyLanguagesOrImages() throws {
        let first = try #require(list(fixture()["projections"]).first), known = try row(first)
        let unknown = try ConnectedApps.Row(account: known.account, app: known.app, savedName: nil, revisionCount: nil)
        let entry = try LibraryChooser.Entry(row: unknown, latest: nil)
        #expect(entry.languages == nil && entry.screenshots == nil && entry.preview == nil)
        let latest = try #require(list(fixture()["projections"])[1]["latest"])
        #expect(throws: ConnectedApps.Failure.self) { try LibraryChooser.Entry(row: unknown, latest: latest) }
        #expect(throws: ConnectedApps.Failure.self) { try LibraryChooser.Entry(row: known, latest: latest) }
    }
    @Test func archivedGalleryReadsOriginalsAcrossDraftEditsAndRejectsChangedSource() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        try await populateMedia(session)
        let entry = try #require(try await session.libraryChooser(.media).first), image = try #require(entry.screenshots?.first)
        let reader = try await session.openSavedMedia(image.source); defer { reader.close() }
        let original = try await reader.imageBytes()
        _ = try await session.addScreenshots(accountId: image.source.accountId, appId: image.source.appId, revisionId: image.source.revisionId, localizationId: "version-locale-1", setId: "set-1", files: [("synthetic-added.png", syntheticPNG(width: 1290, height: 2796))])
        let set = try await session.screenshotSet(accountId: image.source.accountId, appId: image.source.appId, revisionId: image.source.revisionId, setId: "set-1")
        _ = try await session.saveScreenshotLayout(accountId: image.source.accountId, appId: image.source.appId, revisionId: image.source.revisionId, setId: "set-1", order: set.items.map(\.id), hidden: set.items.map(\.id), expected: set.signature)
        #expect(try await reader.imageBytes() == original)
        #expect(try await session.libraryChooser(.media).first?.screenshots?.count == entry.screenshots?.count)
        try await session.storeAccess { store in
            let key = image.source.accountId + ":" + image.source.appId + ":" + image.source.revisionId
            let document = try store.document(namespace: "revisions", key: key), saved = try #require(document)
            try store.transaction { _ in [.put(namespace: "revisions", key: key, json: saved.payload)] }
        }
        await #expect(throws: SavedMediaFailure.changed) { try await reader.read(0..<1) }
        let kept = root.appendingPathComponent("synthetic-original-kept.png"), bytes = Data("Synthetic kept bytes".utf8); try bytes.write(to: kept)
        await #expect(throws: SavedMediaFailure.changed) { try await reader.export(to: kept) }
        #expect(try Data(contentsOf: kept) == bytes)
    }
    @Test func galleryRejectsForeignScopeIndicesAndHashesWithoutFetchingAnything() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        try await populateMedia(session)
        let entry = try #require(try await session.libraryChooser(.media).first), image = try #require(entry.screenshots?.first)
        guard case .archivedScreenshot(_, let hash, let revision) = image.source.kind else { Issue.record("Wrong archive source"); return }
        for kind in [SavedMediaSource.Kind.archivedScreenshot(index: -1, hash: hash, documentRevision: revision), .archivedScreenshot(index: Int.max, hash: hash, documentRevision: revision), .archivedScreenshot(index: 0, hash: String(repeating: "f", count: 64), documentRevision: revision)] {
            let source = SavedMediaSource(accountId: image.source.accountId, appId: image.source.appId, revisionId: image.source.revisionId, itemId: image.source.itemId, kind: kind)
            await #expect(throws: SavedMediaFailure.missing) { try await session.openSavedMedia(source) }
        }
        let foreign = SavedMediaSource(accountId: "synthetic-foreign", appId: image.source.appId, revisionId: image.source.revisionId, itemId: image.source.itemId, kind: image.source.kind)
        await #expect(throws: RevisionHistoryFailure.invalid) { try await session.openSavedMedia(foreign) }
        let reader = try await session.openSavedMedia(image.source); reader.close()
        await #expect(throws: SavedMediaFailure.changed) { try await reader.read(0..<1) }
        try Setup.replaceGeneration(root.appendingPathComponent("state-v2"))
        await #expect(throws: SessionFailure.changed) { try await session.libraryChooser(.localizations) }
    }
    @Test func pricingKeepsConfiguredNamesWithoutInterpretingUnknownArchiveAsEmpty() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let entries = try await session.libraryChooser(.pricing)
        #expect(!entries.isEmpty)
        for entry in entries { #expect(entry.row.revisionCount == nil && entry.screenshots == nil && entry.languages == nil) }
        await #expect(throws: ConnectedApps.Failure.self) { try await session.libraryChooser(.sales) }
        let read = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await session.libraryChooser(.localizations) }
        await #expect(throws: CancellationError.self) { try await read.value }
    }
}
