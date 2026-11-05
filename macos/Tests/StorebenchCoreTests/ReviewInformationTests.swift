import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct ReviewInformationTests {
    init() throws { _ = try TestIsolation.require() }
    private let app = "1000000001"
    private func fixture() throws -> JSONText { try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/review-information.json"))) }
    private func rows(_ value: JSONText?) throws -> [JSONText] { guard case .array(let rows)? = value else { throw PublishFailure.invalid("Invalid synthetic App Review fixture.") }; return rows }
    private func resources(_ value: JSONText?) throws -> [AppStoreConnectClient.Resource] { try JSONDecoder().decode([AppStoreConnectClient.Resource].self, from: #require(value).data) }
    private func resource(_ value: JSONText?) throws -> AppStoreConnectClient.Resource { try JSONDecoder().decode(AppStoreConnectClient.Resource.self, from: #require(value).data) }
    private func fields(password: Bool = false) -> ReviewInformation {
        var value = ReviewInformation(); value.contactFirstName = "Synthetic"; value.contactLastName = "Reviewer"; value.contactPhone = "+1 555 0100"; value.contactEmail = "review@example.invalid"; value.notes = "Sample instructions"
        value.demoAccountRequired = password; value.demoAccountName = password ? "sample-demo" : ""; value.demoAccountPassword = password ? "synthetic-demo-password" : ""; return value
    }
    private func snapshot(revision: Int, notes: String = "Sample instructions", attachment: ReviewAttachment? = nil) -> ReviewInformationSnapshot {
        var value = fields(password: true); value.notes = notes
        return ReviewInformationSnapshot(accountId: "synthetic-account", appId: app, versionId: "version-1", versions: [.init(id: "version-1", name: "Mac 1.0", platform: "MAC_OS", state: "PREPARE_FOR_SUBMISSION")], fields: value, demoPasswordSaved: true, revision: revision, sandbox: [.init(key: "synthetic.entitlement", usage: "Sample explanation")], attachment: attachment, inheritedAttachmentFrom: nil, reusedFrom: nil, unavailablePreviousAttachments: [], appleAttachments: [], layout: .init())
    }
    private func detail(_ versionId: String = "version-1") -> [String: Any] {
        ["type": "appStoreReviewDetails", "id": "detail-1", "attributes": ["contactFirstName": "Synthetic", "contactLastName": "Reviewer", "contactPhone": "+1 555 0100", "contactEmail": "review@example.invalid", "notes": "Sample instructions", "demoAccountRequired": true, "demoAccountName": "sample-demo", "demoAccountPassword": "synthetic-demo-password"],
         "relationships": ["appStoreVersion": ["data": ["type": "appStoreVersions", "id": versionId]]]]
    }
    private func appleAttachment(state: String = "FAILED") -> [String: Any] {
        ["type": "appStoreReviewAttachments", "id": "attachment-1", "attributes": ["fileName": "sample.pdf", "fileSize": 17, "assetDeliveryState": ["state": state]], "relationships": ["appStoreReviewDetail": ["data": ["type": "appStoreReviewDetails", "id": "detail-1"]]]]
    }

    @Test func validatedFieldsAndPasswordFreePresentationMatchActualPrimary() throws {
        for row in try rows(fixture()["information"]) {
            let input = ReviewInformation(row["input"])
            if row["valid"] == .bool(true) { let checked = try input.validated(); #expect(checked.json == row["validated"]); #expect(checked.visibleJSON == row["visible"]); #expect(checked.visibleJSON["demoAccountPassword"] == nil) }
            else { #expect(throws: PublishFailure.self) { try input.validated() } }
        }
    }
    @Test func sandboxValidationAndPriorVersionSelectionMatchActualPrimary() throws {
        let data = try fixture(), versions = try resources(data["versions"])
        for row in try rows(data["sandbox"]) {
            if row["valid"] == .bool(true) { #expect(JSONText.array(try SandboxException.decode(row["input"]).map(\.json)) == row["expected"]) }
            else { #expect(throws: PublishFailure.self) { try SandboxException.decode(row["input"]) } }
        }
        for row in try rows(data["prior"]) { #expect(JSONText.array(ReviewInformation.priorVersions(versions, versionId: try #require(row["versionId"]?.text)).map { .string($0.id) }) == row["expected"]) }
    }
    @Test func selectedAndSubmissionAttachmentGuardsMatchActualPrimary() throws {
        let data = try fixture(), detailId = try #require(data["detailId"]?.text)
        for row in try rows(data["attachments"]) {
            let item = try resource(row["input"])
            if row["valid"] == .bool(true) { #expect(try ReviewInformation.attachmentDigest(item, detailId: detailId) == row["digest"]?.text) }
            else { #expect(throws: PublishFailure.self) { try ReviewInformation.attachmentDigest(item, detailId: detailId) } }
        }
        for row in try rows(data["batches"]) {
            let items = try resources(row["input"])
            if row["valid"] == .bool(true) { #expect(try WorkspaceSession.attachmentsDigest(items, detailId: detailId) == row["digest"]?.text) }
            else { #expect(throws: PublishFailure.self) { try WorkspaceSession.attachmentsDigest(items, detailId: detailId) } }
        }
        for row in try rows(data["detailCases"]) {
            let item = try resource(row["input"])
            if row["valid"] == .bool(true) { #expect(try WorkspaceSession.reviewInformationDigest(item) == row["digest"]?.text) }
            else { #expect(throws: PublishFailure.self) { try WorkspaceSession.reviewInformationDigest(item) } }
        }
    }
    @Test func latestSaveIsExplicitAndNeverExposesSavedOrReplacementPasswords() throws {
        var editor = ReviewInformationEditor(); #expect(!editor.loaded && !editor.dirty)
        editor.load(snapshot(revision: 1)); #expect(editor.fields.demoAccountPassword.isEmpty && !editor.dirty)
        editor.fields.notes = "Unsaved instructions"; editor.fields.demoAccountPassword = "synthetic-replacement"
        try editor.readLatest(snapshot(revision: 2, notes: "Other saved instructions"))
        #expect(editor.revision == 1 && editor.fields.notes == "Unsaved instructions")
        let comparison = editor.changes?.map { $0.saved + $0.edited }.joined() ?? ""
        #expect(!comparison.contains("synthetic-demo-password") && !comparison.contains("synthetic-replacement"))
        editor.chooseLatest(keepEdits: true); #expect(editor.revision == 2 && editor.dirty && editor.fields.demoAccountPassword == "synthetic-replacement")
        try editor.readLatest(snapshot(revision: 3)); editor.chooseLatest(keepEdits: false)
        #expect(editor.revision == 3 && !editor.dirty && editor.fields.demoAccountPassword.isEmpty)
        var foreign = snapshot(revision: 4); foreign = ReviewInformationSnapshot(accountId: "foreign", appId: app, versionId: foreign.versionId, versions: foreign.versions, fields: foreign.fields, demoPasswordSaved: true, revision: 4, sandbox: [], attachment: nil, inheritedAttachmentFrom: nil, reusedFrom: nil, unavailablePreviousAttachments: [], appleAttachments: [], layout: .init())
        #expect(throws: PublishFailure.self) { try editor.readLatest(foreign) }; #expect(editor.revision == 3)
    }
    @Test func attachmentBaselineChoicesAndAppleRefreshRetainUnrelatedEdits() throws {
        let first = ReviewAttachment(hash: String(repeating: "a", count: 64), fileName: "first.pdf", ext: "pdf", size: 17), second = ReviewAttachment(hash: String(repeating: "b", count: 64), fileName: "second.pdf", ext: "pdf", size: 18)
        var editor = ReviewInformationEditor(); editor.load(snapshot(revision: 1, attachment: first)); editor.fields.notes = "Unsaved"
        try editor.readLatest(snapshot(revision: 2, attachment: second)); editor.chooseLatest(keepEdits: true)
        #expect(editor.attachment == second && editor.fields.notes == "Unsaved")
        editor.removeAttachment(); try editor.readLatest(snapshot(revision: 3, attachment: first)); editor.chooseLatest(keepEdits: true)
        #expect(editor.attachment == nil && editor.dirty)
        try editor.refreshApple(snapshot(revision: 10, attachment: second)); #expect(editor.revision == 3 && editor.attachment == nil && editor.fields.notes == "Unsaved")
        try editor.stage(.init(name: "sample.PDF", data: Data("synthetic".utf8))); #expect(editor.upload?.name == "sample.PDF")
        #expect(throws: PublishFailure.self) { try editor.stage(.init(name: "sample.zip", data: Data("synthetic".utf8))) }
    }
    @Test func omittedSandboxPreservesSavedNotesAndExplicitEmptyClearsThem() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let notes = [SandboxException(key: "synthetic.entitlement", usage: "Sample explanation")]
        let first = try await session.saveReviewInformationDraft(accountId: "synthetic-account", appId: app, versionId: "version-1", fields: fields(), sandbox: notes, attachment: nil, keepAttachment: true, expectedRevision: 0)
        let second = try await session.saveReviewInformationDraft(accountId: "synthetic-account", appId: app, versionId: "version-1", fields: fields(), attachment: nil, keepAttachment: true, expectedRevision: first.revision)
        #expect(second.sandbox == notes && second.revision == 2)
        let third = try await session.saveReviewInformationDraft(accountId: "synthetic-account", appId: app, versionId: "version-1", fields: fields(), sandbox: [], attachment: nil, keepAttachment: true, expectedRevision: 2)
        #expect(third.sandbox.isEmpty && third.revision == 3)
    }
    @Test func concurrentDraftsRejectStaleWritersAndLayoutPatchesMergeUnderSharedMutex() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let other = try WorkspaceSession(workspace: Workspace(root: root), vault: await session.vault), values = fields(), app = app
        let results = await withTaskGroup(of: Bool.self) { group in
            for target in [session, other] { group.addTask { do { _ = try await target.saveReviewInformationDraft(accountId: "synthetic-account", appId: app, versionId: "version-1", fields: values, sandbox: [.init(key: "synthetic", usage: "Sample")], attachment: nil, keepAttachment: true, expectedRevision: 0); return true } catch { return false } } }
            var values: [Bool] = []; for await value in group { values.append(value) }; return values
        }
        #expect(results.filter { $0 }.count == 1)
        async let access = session.saveReviewInformationLayout(accountId: "synthetic-account", appId: app, section: .access, expanded: false)
        async let sandbox = other.saveReviewInformationLayout(accountId: "synthetic-account", appId: app, section: .sandbox, expanded: false)
        _ = try await (access, sandbox)
        let layout = try await session.reviewInformationLayout(accountId: "synthetic-account", appId: app); #expect(!layout.access && !layout.sandbox)
        let name = "review_info_view_" + JSONText.string("synthetic-account:\(app):view").rawSHA256.prefix(40) + ".mutex"
        let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("state-v2").appendingPathComponent(name).path)
        #expect((attributes[.size] as? NSNumber)?.intValue == 0)
    }
    @Test func ownedProcessBlocksDraftReplacementUntilCrashAndKeepsPermanentMutex() async throws {
        let root = try TestIsolation.require().appendingPathComponent("review-draft-lock-policy")
        let (session, _) = try DraftTests().session(directory: root)
        let reader = try WorkspaceSession(workspace: Workspace(root: root), vault: await session.vault)
        let name = "review_info_" + JSONText.string("synthetic-account:\(app):version-1").rawSHA256.prefix(40) + ".mutex"
        let mutex = root.appendingPathComponent("state-v2").appendingPathComponent(name)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("lock-ready").path))
        #expect(try FileMutex.tryLock(mutex) == nil)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: mutex.path)
        let inode = try #require(try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber), values = fields(), app = app
        defer { try? JobLock.exclusive(root.appendingPathComponent("lock-release"), "interrupt") }
        let pending = Task { try await session.saveReviewInformationDraft(accountId: "synthetic-account", appId: app, versionId: "version-1", fields: values, sandbox: [.init(key: "synthetic", usage: "Sample")], attachment: nil, keepAttachment: true, expectedRevision: 0) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await reader.reviewInformationDraft(accountId: "synthetic-account", appId: app, versionId: "version-1").revision == 0)
        try JobLock.exclusive(root.appendingPathComponent("lock-release"), "interrupt")
        let saved = try await pending.value; #expect(saved.revision == 1 && saved.sandbox.count == 1)
        #expect(try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber == inode)
    }
    @Test func ownedProcessProtectsAppLayoutWithoutExpiringAnOldTimestamp() async throws {
        let root = try TestIsolation.require().appendingPathComponent("review-layout-lock-policy")
        let (session, _) = try DraftTests().session(directory: root)
        let reader = try WorkspaceSession(workspace: Workspace(root: root), vault: await session.vault)
        let name = "review_info_view_" + JSONText.string("synthetic-account:\(app):view").rawSHA256.prefix(40) + ".mutex"
        let mutex = root.appendingPathComponent("state-v2").appendingPathComponent(name)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("lock-ready").path))
        #expect(try FileMutex.tryLock(mutex) == nil)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: mutex.path)
        let inode = try #require(try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber), app = app
        defer { try? JobLock.exclusive(root.appendingPathComponent("lock-release"), "interrupt") }
        let pending = Task { try await session.saveReviewInformationLayout(accountId: "synthetic-account", appId: app, section: .access, expanded: false) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await reader.reviewInformationLayout(accountId: "synthetic-account", appId: app).access)
        try JobLock.exclusive(root.appendingPathComponent("lock-release"), "interrupt")
        let saved = try await pending.value; #expect(!saved.access && saved.sandbox)
        #expect(try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber == inode)
    }
    @Test func savedPasswordIsRetainedWithoutReachingTheEditorAndPrepareFailureReturnsReceipt() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "review-receipt.appstoreconnect.test"
        apple.reviewDetails = [detail()]; StubProtocol.handle(host) { apple.handle($0) }
        let client = try PublishingTests().client(account, host: host)
        let loaded = try await session.reviewInformationSnapshot(account: account, appId: app, versionId: "version-1", client: client)
        #expect(loaded.demoPasswordSaved && loaded.fields.demoAccountPassword.isEmpty)
        var input = loaded.fields; input.notes = "Saved local instructions"
        apple.lock.withLock { var attrs = apple.versions[0]["attributes"] as! [String: Any]; attrs["appVersionState"] = "READY_FOR_SALE"; apple.versions[0]["attributes"] = attrs }
        let result = try await session.saveAndPrepareReviewInformation(account: account, appId: app, versionId: "version-1", fields: input, sandbox: [.init(key: "synthetic", usage: "Sample")], attachment: ("sample.pdf", Data("synthetic".utf8)), keepAttachment: false, expectedRevision: 0, client: client)
        #expect(result.saved.revision == 1 && result.review == nil && result.issue != nil && result.saved.fields.demoAccountPassword.isEmpty)
        let saved = try await session.reviewInformationDraft(accountId: account.id, appId: app, versionId: "version-1"); #expect(saved.fields.demoAccountPassword == "synthetic-demo-password" && saved.sandbox.count == 1)
        var editor = ReviewInformationEditor(); editor.load(loaded); try editor.acknowledge(result.saved); #expect(editor.revision == 1 && !editor.dirty && editor.selectedFile == nil && editor.snapshot?.demoPasswordSaved == true)
        #expect(apple.lock.withLock { apple.writes.isEmpty })
    }
    @Test func priorVersionReuseInheritsOnlyAuthenticatedSameAppMediaAndRejectsChangedSource() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "review-prior.appstoreconnect.test"
        var prior = apple.versions[0]; prior["id"] = "version-0"; var attributes = prior["attributes"] as! [String: Any]; attributes["versionString"] = "0.9"; prior["attributes"] = attributes; apple.versions.append(prior); apple.reviewDetails = [detail("version-0")]
        StubProtocol.handle(host) { request in
            if request.url?.path == "/v1/appStoreVersions/version-1/appStoreReviewDetail" { return (404, [:], Data()) }
            if request.url?.path == "/v1/appStoreVersions/version-0/appStoreReviewDetail" { return apple.lock.withLock { apple.page(apple.reviewDetails[0]) } }
            return apple.handle(request)
        }
        let client = try PublishingTests().client(account, host: host), notes = [SandboxException(key: "synthetic", usage: "Previous explanation")]
        _ = try await session.saveReviewInformationDraft(accountId: account.id, appId: app, versionId: "version-0", fields: fields(), sandbox: notes, attachment: ("sample.pdf", Data("synthetic".utf8)), keepAttachment: false, expectedRevision: 0)
        let loaded = try await session.reviewInformationSnapshot(account: account, appId: app, versionId: "version-1", client: client)
        #expect(loaded.reusedFrom != nil && loaded.inheritedAttachmentFrom == "version-0" && loaded.sandbox == notes && loaded.fields.demoAccountPassword.isEmpty && loaded.demoPasswordSaved)
        let receipt = try await session.saveReviewInformationLocally(account: account, appId: app, versionId: "version-1", fields: loaded.fields, sandbox: loaded.sandbox, attachment: nil, keepAttachment: true, expectedRevision: 0, inheritedAttachment: loaded.attachment, inheritFromVersionId: loaded.inheritedAttachmentFrom, client: client)
        #expect(receipt.attachment == loaded.attachment && receipt.revision == 1)
        _ = try await session.saveReviewInformationDraft(accountId: account.id, appId: app, versionId: "version-0", fields: fields(), sandbox: [], attachment: ("changed.pdf", Data("changed synthetic".utf8)), keepAttachment: false, expectedRevision: 1)
        await #expect(throws: PublishFailure.self) { try await session.saveReviewInformationDraft(accountId: account.id, appId: app, versionId: "version-2", fields: fields(), attachment: nil, keepAttachment: true, expectedRevision: 0, inheritedAttachment: loaded.attachment, inheritFromVersionId: "version-0") }
    }
    @Test func failedOrForeignReadsRemainUnknownAndDoNotReplaceEditorInputs() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "review-read-failure.appstoreconnect.test"
        StubProtocol.handle(host) { request in
            if request.url?.path == "/v1/appStoreVersions/version-1/appStoreReviewDetail" { return (503, [:], Data()) }
            return apple.handle(request)
        }
        let client = try PublishingTests().client(account, host: host)
        var editor = ReviewInformationEditor()
        do { editor.load(try await session.reviewInformationSnapshot(account: account, appId: app, versionId: "version-1", client: client)); Issue.record("An unavailable read became an empty draft") } catch { }
        #expect(!editor.loaded && editor.revision == 0)
        editor.load(snapshot(revision: 1)); editor.fields.notes = "Unsaved entries"
        do { try editor.readLatest(await session.reviewInformationSnapshot(account: account, appId: app, versionId: "version-1", client: client)); Issue.record("An unavailable read replaced the baseline") } catch { }
        #expect(editor.fields.notes == "Unsaved entries" && editor.revision == 1 && editor.latest == nil)
        apple.reviewDetails = [detail("foreign-version")]; StubProtocol.handle(host) { apple.handle($0) }
        await #expect(throws: PublishFailure.self) { try await session.reviewInformationSnapshot(account: account, appId: app, versionId: "version-1", client: client) }
        #expect(apple.writes.isEmpty)
    }
    @Test func invalidUploadsAndUnownedInheritedMetadataNeverCreateADraft() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        for name in ["sample.zip", "../sample.pdf", "sample\\u{0000}.pdf", String(repeating: "a", count: 201) + ".pdf"] {
            await #expect(throws: PublishFailure.self) { try await session.saveReviewInformationDraft(accountId: "synthetic-account", appId: app, versionId: "version-1", fields: fields(), attachment: (name, Data("synthetic".utf8)), keepAttachment: false, expectedRevision: 0) }
        }
        let metadata = ReviewAttachment(hash: String(repeating: "a", count: 64), fileName: "sample.pdf", ext: "pdf", size: 17)
        await #expect(throws: PublishFailure.self) { try await session.saveReviewInformationDraft(accountId: "synthetic-account", appId: app, versionId: "version-1", fields: fields(), attachment: nil, keepAttachment: true, expectedRevision: 0, inheritedAttachment: metadata, inheritFromVersionId: "version-0") }
        #expect(try await session.reviewInformationDraft(accountId: "synthetic-account", appId: app, versionId: "version-1").revision == 0)
    }
    @Test func failedAppleAttachmentsHaveSingleUseRemovalReviewAndDoNotDeleteLocalDraft() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "review-delete.appstoreconnect.test"
        apple.reviewDetails = [detail()]; apple.attachments = [appleAttachment()]; StubProtocol.handle(host) { apple.handle($0) }
        let client = try PublishingTests().client(account, host: host)
        let saved = try await session.saveReviewInformationDraft(accountId: account.id, appId: app, versionId: "version-1", fields: fields(), sandbox: [.init(key: "synthetic", usage: "Local explanation")], attachment: ("local.pdf", Data("synthetic".utf8)), keepAttachment: false, expectedRevision: 0)
        var request = PublishRequest(accountId: account.id, appId: app, scope: .reviewInfo, versionId: "version-1"); request.reviewAttachmentId = "attachment-1"
        let decoded = try #require(PublishRequest(request.json)).validated(); #expect(decoded.reviewAttachmentId == "attachment-1")
        let review = try await session.preparePublishing(account: account, request: request, client: client)
        #expect(review.steps.count == 1 && review.steps[0].method == "DELETE" && apple.writes.isEmpty)
        let done = try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: client)
        #expect(done.state == "complete" && apple.attachments.isEmpty && apple.writes.count == 1)
        #expect(try await session.reviewInformationDraft(accountId: account.id, appId: app, versionId: "version-1") == saved)
        await #expect(throws: PublishFailure.self) { try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: client) }
        #expect(apple.writes.count == 1)
    }
    @Test func changedAttachmentOrLocalSandboxStopsApprovalBeforeAnyAppleWrite() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "review-conflict.appstoreconnect.test"
        apple.reviewDetails = [detail()]; apple.attachments = [appleAttachment()]; StubProtocol.handle(host) { apple.handle($0) }
        let client = try PublishingTests().client(account, host: host)
        var request = PublishRequest(accountId: account.id, appId: app, scope: .reviewInfo, versionId: "version-1"); request.reviewAttachmentId = "attachment-1"
        let removal = try await session.preparePublishing(account: account, request: request, client: client)
        apple.lock.withLock { var attrs = apple.attachments[0]["attributes"] as! [String: Any]; attrs["fileSize"] = 18; apple.attachments[0]["attributes"] = attrs }
        await #expect(throws: PublishFailure.self) { try await session.approvePublishing(account: account, appId: app, id: removal.id, fingerprint: removal.fingerprint, client: client) }
        #expect(apple.writes.isEmpty)
        var edited = fields(password: true); edited.notes = "New instructions"
        _ = try await session.saveReviewInformationDraft(accountId: account.id, appId: app, versionId: "version-1", fields: edited, sandbox: [.init(key: "synthetic", usage: "First")], attachment: nil, keepAttachment: false, expectedRevision: 0)
        let publish = try await session.preparePublishing(account: account, request: .init(accountId: account.id, appId: app, scope: .reviewInfo, versionId: "version-1"), client: client)
        _ = try await session.saveReviewInformationDraft(accountId: account.id, appId: app, versionId: "version-1", fields: edited, sandbox: [.init(key: "synthetic", usage: "Changed")], attachment: nil, keepAttachment: false, expectedRevision: 1)
        await #expect(throws: PublishFailure.self) { try await session.approvePublishing(account: account, appId: app, id: publish.id, fingerprint: publish.fingerprint, client: client) }
        #expect(apple.writes.isEmpty)
    }
}
