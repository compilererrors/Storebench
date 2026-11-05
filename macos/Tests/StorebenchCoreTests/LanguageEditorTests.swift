import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct LanguageEditorTests {
    init() throws { _ = try TestIsolation.require() }
    let accountId = "synthetic-account", appId = "1000000001", revisionId = "00000000-0000-4000-8000-000000000002"
    private func read(_ session: WorkspaceSession) async throws -> [LanguageDrafts.Section] {
        try await session.languageTextDrafts(accountId: accountId, appId: appId, revisionId: revisionId, selections: [.init(id: "version-locale-1", scope: .version), .init(id: "info-locale-1", scope: .appInfo)])
    }
    private func field(_ editor: LanguageEditorState, _ key: String) throws -> LanguageEditorState.Field { try #require(editor.fields.first { $0.key == key }) }

    @Test func oneConfirmedSnapshotKeepsTypingDuringSaveAndImmutableImport() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        var editor = try LanguageEditorState(await read(session))
        let description = try field(editor, "description"), subtitle = try field(editor, "subtitle")
        let original = editor.original(description)
        try editor.change(description, to: "Synthetic first snapshot"); try editor.change(subtitle, to: "Synthetic joined subtitle")
        let entries = try editor.entries(); #expect(entries.count == 2)
        try editor.change(description, to: "Synthetic later typing")
        let receipt = try await session.saveLanguageDraft(accountId: accountId, appId: appId, revisionId: revisionId, entries: entries)
        try editor.confirmed(entries, fingerprints: receipt)
        #expect(editor.dirty && editor.saved(description) == "Synthetic first snapshot" && editor.value(description) == "Synthetic later typing")
        #expect(editor.original(description) == original && !editor.unsaved(subtitle))
        let remaining = try editor.entries(); #expect(remaining.count == 1 && remaining[0].selection.scope == .version)
        let latest = try await session.saveLanguageDraft(accountId: accountId, appId: appId, revisionId: revisionId, entries: remaining)
        try editor.confirmed(remaining, fingerprints: latest); #expect(!editor.dirty && editor.differsFromImport(description))
        try editor.restoreImport(description); #expect(editor.dirty && editor.value(description) == original)
        editor.discard(); #expect(!editor.dirty && editor.value(description) == "Synthetic later typing")
    }
    @Test func staleSaveAndLatestComparisonNeverRefreshOrWriteUntilChosen() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let initial = try await read(session); var editor = try LanguageEditorState(initial), other = editor
        let description = try field(editor, "description"), subtitle = try field(editor, "subtitle")
        try editor.change(description, to: "Synthetic losing description"); try editor.change(subtitle, to: "Synthetic losing subtitle")
        try other.change(description, to: "Synthetic other window")
        _ = try await session.saveLanguageDraft(accountId: accountId, appId: appId, revisionId: revisionId, entries: other.entries())
        let inputs = editor.values, tokens = editor.fingerprints, baseline = editor.baseline, signature = editor.signature
        await #expect(throws: DraftFailure.stale) { try await session.saveLanguageDraft(accountId: accountId, appId: appId, revisionId: revisionId, entries: editor.entries()) }
        let latest = try await read(session)
        try editor.compare(latest)
        #expect(TextDrafts.sameFields(editor.values[description.selection.id] ?? [:], inputs[description.selection.id] ?? [:]))
        #expect(editor.fingerprints == tokens && editor.baseline == baseline && editor.signature == signature)
        let documentBefore = try await session.storeAccess { try $0.document(namespace: "drafts", key: accountId + ":" + appId + ":" + revisionId) }
        editor.acceptLatest(keepEdits: true)
        #expect(editor.values == inputs && editor.dirty && editor.saved(description) == "Synthetic other window")
        let documentAfter = try await session.storeAccess { try $0.document(namespace: "drafts", key: accountId + ":" + appId + ":" + revisionId) }
        #expect(documentBefore?.revision == documentAfter?.revision && documentBefore?.payload == documentAfter?.payload)
        let entries = try editor.entries(), receipt = try await session.saveLanguageDraft(accountId: accountId, appId: appId, revisionId: revisionId, entries: entries)
        try editor.confirmed(entries, fingerprints: receipt); #expect(!editor.dirty)
        try editor.change(subtitle, to: "Synthetic unsaved alternative"); try editor.compare(await read(session)); editor.acceptLatest(keepEdits: false)
        #expect(!editor.dirty && editor.value(subtitle) == "Synthetic losing subtitle")
    }
    @Test func receiptsBoundsAndUnicodeRepresentationsKeepTheOriginalBaseline() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        var editor = try LanguageEditorState(await read(session)); let description = try field(editor, "description")
        try editor.change(description, to: "é"); let first = editor.signature; try editor.change(description, to: "e\u{301}")
        #expect(editor.signature != first)
        let entries = try editor.entries(), before = editor.baseline, token = editor.fingerprints
        #expect(throws: DraftFailure.stale) { try editor.confirmed(entries, fingerprints: [description.selection.id: String(repeating: "a", count: 64)]) }
        #expect(editor.baseline == before && editor.fingerprints == token && editor.value(description).utf8.elementsEqual("e\u{301}".utf8))
        #expect(throws: DraftFailure.invalid) { try editor.change(description, to: String(repeating: "😀", count: 5001)) }
        try editor.change(description, to: String(repeating: "😀", count: 5000)); #expect(try editor.entries().first?.fields["description"]?.utf16.count == 10_000)
        #expect(throws: PublishFailure.self) { try editor.publishingRequest(accountId: accountId, appId: appId, revisionId: revisionId, versionId: "version-1", targetMode: "apple-version") }
    }
    @Test func chosenLocaleIncludesAllInformationRecordsAndOnlyItsVersion() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try #require(try await session.revisions(accountId: accountId, appId: appId).first { $0.id == revisionId })
        var raw = try JSONText.parse(JSONEncoder().encode(source))
        let extra = JSONText.object([("id", .string("synthetic-extra-info")), ("fields", .object([])), ("localizations", .array([.object([("id", .string("synthetic-extra-locale")), ("fields", .object([("locale", .string("en-US")), ("name", .string("Synthetic alternate name"))]))])]))])
        raw = raw.setting("appInfos", .array(WorkspaceSession.items(raw["appInfos"]) + [extra]))
        let revision = try JSONDecoder().decode(Revision.self, from: raw.data)
        let chosen = try LanguageEditorState.selections(revision: revision, versionId: "version-1", locale: "en-US")
        #expect(chosen.map(\.id) == ["version-locale-1", "info-locale-1", "synthetic-extra-locale"])
        #expect(throws: DraftFailure.invalid) { try LanguageEditorState.selections(revision: revision, versionId: "synthetic-missing-version", locale: "en-US") }
        #expect(throws: DraftFailure.invalid) { try LanguageEditorState.selections(revision: revision, versionId: "version-1", locale: "sv") }
        _ = try await session.addLanguage(accountId: accountId, appId: appId, revisionId: revisionId, versionId: "version-1", locale: "sv", copyFrom: nil)
        let working = try await session.workspaceRevision(source, accountId: accountId, appId: appId)
        let added = try LanguageEditorState.selections(revision: working, versionId: "version-1", locale: "sv")
        #expect(added.count == 2 && added.last?.id == "local-app-info-sv")
    }
    @Test func unchangedCopiedFieldCanBeAcknowledgedWhileOtherFieldsRemainUnsaved() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await session.addLanguage(accountId: accountId, appId: appId, revisionId: revisionId, versionId: "version-1", locale: "sv", copyFrom: "en-US")
        let info = LanguageDrafts.Selection(id: "local-app-info-sv", scope: .appInfo)
        let original = try await read(session); var source = try LanguageEditorState(original)
        try source.change(field(source, "name"), to: "Synthetic revised name")
        _ = try await session.saveLanguageDraft(accountId: accountId, appId: appId, revisionId: revisionId, entries: source.entries())
        var editor = try LanguageEditorState(await session.languageTextDrafts(accountId: accountId, appId: appId, revisionId: revisionId, selections: [info]))
        let review = try #require(try await session.copiedTextReviews(accountId: accountId, appId: appId, revisionId: revisionId, localizationId: info.id, scope: .appInfo, versionId: "version-1")["name"])
        try editor.change(field(editor, "subtitle"), to: "Synthetic unsaved subtitle")
        #expect(editor.dirty && editor.canAcknowledge(review))
        let inputs = editor.values, tokens = editor.fingerprints
        try await session.acknowledgeCopiedText(accountId: accountId, appId: appId, revisionId: revisionId, review: review)
        #expect(editor.values == inputs && editor.fingerprints == tokens && editor.dirty)
        let after = try await session.languageTextDrafts(accountId: accountId, appId: appId, revisionId: revisionId, selections: [info])
        #expect(after[0].draft.fields == editor.baseline[info.id])
        try editor.change(field(editor, "name"), to: "Synthetic changed destination")
        #expect(!editor.sourceVisible(review) && !editor.canAcknowledge(review))
        #expect(try await session.copiedTextReviews(accountId: accountId, appId: appId, revisionId: revisionId, localizationId: info.id, scope: .appInfo, versionId: "synthetic-missing").isEmpty)
    }
    @Test func savedLanguageAndMediaPrepareAnExactReviewAndRequireOneApproval() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "joined-language-review.appstoreconnect.test"
        var editor = try LanguageEditorState(await read(session))
        try editor.change(field(editor, "description"), to: "Synthetic joined reviewed description")
        try editor.change(field(editor, "subtitle"), to: "Synthetic joined subtitle")
        #expect(throws: PublishFailure.self) { try editor.publishingRequest(accountId: accountId, appId: appId, revisionId: revisionId, versionId: "version-1", targetMode: "apple-version") }
        let entries = try editor.entries(), receipt = try await session.saveLanguageDraft(accountId: accountId, appId: appId, revisionId: revisionId, entries: entries)
        try editor.confirmed(entries, fingerprints: receipt)
        let set = try await session.screenshotSet(accountId: accountId, appId: appId, revisionId: revisionId, setId: "set-1")
        _ = try await session.saveScreenshotLayout(accountId: accountId, appId: appId, revisionId: revisionId, setId: "set-1", order: set.items.map(\.id), hidden: ["shot-1"], expected: set.signature)
        let info: [String: Any] = ["type": "appInfoLocalizations", "id": "info-locale-1", "attributes": ["locale": "en-US", "name": "Second synthetic app", "subtitle": "Sample subtitle"], "relationships": ["appInfo": ["data": ["type": "appInfos", "id": "info-1"]]]]
        StubProtocol.handle(host) { request in
            if request.url?.path == "/v1/appInfos/info-1/appInfoLocalizations" { return apple.page([info]) }
            if request.url?.path == "/v1/appInfoLocalizations/info-locale-1" {
                if request.httpMethod == "GET" { return apple.page(info) }
                guard request.httpMethod == "PATCH" else { return (404, [:], Data()) }
                let body = try? JSONSerialization.jsonObject(with: apple.body(request)) as? [String: Any]
                apple.lock.withLock { apple.writes.append(("PATCH", request.url!.path, body)) }; return apple.page(info)
            }
            return apple.handle(request)
        }
        let client = try PublishingTests().client(account, host: host)
        let request = try editor.publishingRequest(accountId: accountId, appId: appId, revisionId: revisionId, versionId: "version-1", targetMode: "apple-version")
        let destination = try await session.prepareLanguageListingReview(account: account, request: request, client: client)
        let review = destination.review
        #expect(!destination.versionSetup && destination.source == request)
        #expect(review.request == request && review.state == "prepared" && apple.writes.isEmpty)
        #expect(review.steps.contains { $0.label == "Update app information · en-US" })
        #expect(review.steps.contains { $0.label == "Update version text · en-US" })
        #expect(review.steps.contains { $0.label == "Remove screenshot · en-US" })
        #expect(review.steps.contains { $0.body?.stringify().contains("Synthetic joined reviewed description") == true })
        #expect(review.steps.contains { $0.body?.stringify().contains("Synthetic joined subtitle") == true })
        await #expect(throws: PublishFailure.expired) { try await session.approvePublishing(account: account, appId: appId, id: review.id, fingerprint: String(repeating: "0", count: 64), client: client) }
        #expect(apple.writes.isEmpty)
        let done = try await session.approvePublishing(account: account, appId: appId, id: review.id, fingerprint: review.fingerprint, client: client)
        #expect(done.state == "complete" && done.steps.allSatisfy { $0.state == "done" })
        let writes = apple.writes.count; #expect(writes >= 3)
        await #expect(throws: PublishFailure.used) { try await session.approvePublishing(account: account, appId: appId, id: review.id, fingerprint: review.fingerprint, client: client) }
        #expect(apple.writes.count == writes && !editor.dirty)
    }
    @Test func plannedLanguageUsesSeparateSetupAndMaterialApprovalAndHandlesTheCreationRace() async throws {
        for raced in [false, true] {
            let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
            let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "joined-language-plan-\(raced).appstoreconnect.test"
            _ = try await session.saveReleasePlan(account: account, appId: appId, start: .reuse, sourceRevisionId: revisionId, baseVersionId: "version-1", targetVersion: "2.0", releaseType: "MANUAL", earliestReleaseDate: nil, expected: "null")
            var editor = try LanguageEditorState(await read(session))
            try editor.change(field(editor, "description"), to: "Synthetic planned reviewed language")
            let entries = try editor.entries(), receipt = try await session.saveLanguageDraft(accountId: accountId, appId: appId, revisionId: revisionId, entries: entries)
            try editor.confirmed(entries, fingerprints: receipt)
            let set = try await session.screenshotSet(accountId: accountId, appId: appId, revisionId: revisionId, setId: "set-1")
            _ = try await session.saveScreenshotLayout(accountId: accountId, appId: appId, revisionId: revisionId, setId: "set-1", order: set.items.map(\.id), hidden: ["shot-1"], expected: set.signature)
            let importedName = editor.original(try field(editor, "name")), importedSubtitle = editor.original(try field(editor, "subtitle"))
            let info: [String: Any] = ["type": "appInfoLocalizations", "id": "info-locale-1", "attributes": ["locale": "en-US", "name": importedName, "subtitle": importedSubtitle], "relationships": ["appInfo": ["data": ["type": "appInfos", "id": "info-1"]]]]
            var versionReads = 0
            StubProtocol.handle(host) { request in
                let path = request.url!.path
                if path == "/v1/apps/1000000001/appStoreVersions" {
                    apple.lock.withLock {
                        versionReads += 1
                        if raced, versionReads == 2 {
                            apple.versions.append(["type": "appStoreVersions", "id": "synthetic-planned-version", "attributes": ["platform": "IOS", "versionString": "2.0", "releaseType": "MANUAL", "appVersionState": "PREPARE_FOR_SUBMISSION"], "relationships": ["app": ["data": ["type": "apps", "id": "1000000001"]]]])
                        }
                    }
                }
                let target = apple.lock.withLock { apple.versions.first { ($0["attributes"] as? [String: Any])?["versionString"] as? String == "2.0" }?["id"] as? String }
                if let target, path == "/v1/appStoreVersions/\(target)/appStoreVersionLocalizations" {
                    return apple.page([["type": "appStoreVersionLocalizations", "id": "synthetic-planned-locale", "attributes": ["locale": "en-US", "description": "Synthetic previous planned wording", "keywords": "sample,test"], "relationships": ["appStoreVersion": ["data": ["type": "appStoreVersions", "id": target]]]]])
                }
                if let target, path == "/v1/appStoreVersionLocalizations/synthetic-planned-locale", request.httpMethod == "GET" {
                    return apple.page(["type": "appStoreVersionLocalizations", "id": "synthetic-planned-locale", "attributes": ["locale": "en-US", "description": "Synthetic previous planned wording", "keywords": "sample,test"], "relationships": ["appStoreVersion": ["data": ["type": "appStoreVersions", "id": target]]]])
                }
                if request.httpMethod == "GET", ["/v1/appStoreVersionLocalizations/synthetic-planned-locale/appScreenshotSets", "/v1/appStoreVersionLocalizations/synthetic-planned-locale/appPreviewSets"].contains(path) {
                    return apple.page([])
                }
                if path == "/v1/appStoreVersionLocalizations/synthetic-planned-locale", request.httpMethod == "PATCH" {
                    let body = try? JSONSerialization.jsonObject(with: apple.body(request)) as? [String: Any]
                    apple.lock.withLock { apple.writes.append(("PATCH", path, body)) }
                    return apple.page(["type": "appStoreVersionLocalizations", "id": "synthetic-planned-locale", "attributes": ["locale": "en-US"], "relationships": ["appStoreVersion": ["data": ["type": "appStoreVersions", "id": target!]]]])
                }
                if path == "/v1/appInfos/info-1/appInfoLocalizations" { return apple.page([info]) }
                if path == "/v1/appInfoLocalizations/info-locale-1" { return apple.page(info) }
                return apple.handle(request)
            }
            let client = try PublishingTests().client(account, host: host)
            let request = try editor.publishingRequest(accountId: accountId, appId: appId, revisionId: revisionId, versionId: "version-1", targetMode: "release-plan")
            let destination = try await session.prepareLanguageListingReview(account: account, request: request, client: client)
            #expect(destination.matches(accountId: accountId, appId: appId, revisionId: revisionId, versions: ["version-1"], targetMode: "release-plan"))
            #expect(!destination.matches(accountId: "synthetic-foreign", appId: appId, revisionId: revisionId, versions: ["version-1"], targetMode: "release-plan"))
            #expect(!destination.matches(accountId: accountId, appId: appId, revisionId: revisionId, versions: ["version-1"], targetMode: "apple-version"))
            #expect(apple.writes.isEmpty && destination.versionSetup == !raced)
            let material: PublishReview
            if raced {
                material = destination.review
                #expect(material.request == request && material.steps.contains { $0.body?.stringify().contains("Synthetic planned reviewed language") == true })
                #expect(try await session.publishHistory(accountId: accountId, appId: appId).contains { $0.request.scope == .release && $0.steps.isEmpty })
            } else {
                let setup = destination.review
                #expect(setup.request.scope == .release && setup.steps.count == 1 && setup.steps[0].label == "Create iOS version 2.0")
                let created = try await session.approvePublishing(account: account, appId: appId, id: setup.id, fingerprint: setup.fingerprint, client: client)
                #expect(created.state == "complete" && apple.writes.count == 1 && apple.writes[0].1 == "/v1/appStoreVersions")
                let next = try await session.prepareLanguageListingReview(account: account, request: request, client: client)
                #expect(!next.versionSetup && next.review.request == request && apple.writes.count == 1)
                material = next.review
                #expect(material.steps.contains { $0.body?.stringify().contains("Synthetic planned reviewed language") == true })
            }
            let before = apple.writes.count
            let sent = try await session.approvePublishing(account: account, appId: appId, id: material.id, fingerprint: material.fingerprint, client: client)
            #expect(sent.state == "complete" && apple.writes.count > before)
            await #expect(throws: PublishFailure.used) { try await session.approvePublishing(account: account, appId: appId, id: material.id, fingerprint: material.fingerprint, client: client) }
            #expect(!editor.dirty)
        }
    }
}
