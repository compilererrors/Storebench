import CryptoKit
import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct AppOverviewMaterialTests {
    init() throws { _ = try TestIsolation.require() }
    private let accountId = "synthetic-account", appId = "1000000001"
    private func fixture() throws -> JSONText { try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/app-material.json"))) }
    private func list(_ value: JSONText?) throws -> [JSONText] { try AppOverviewMaterial.array(value) }
    private func archive(_ value: JSONText, stamp: Int = 17) throws -> ArchivedRevision {
        try ConnectedApps.savedRevision(value, accountId: accountId, appId: appId, id: #require(value["id"]?.text), documentRevision: stamp)
    }
    private func detailJSON(_ detail: AppOverviewMaterial.Detail) -> JSONText {
        .object([("id", .string(detail.versionId)), ("languages", .array(detail.languages.map { language in
            .object([("id", .string(language.id)), ("label", .string(language.label)), ("fields", .array(language.fields.map { .object([("key", .string($0.key)), ("label", .string($0.label)), ("value", .string($0.value))]) })),
                     ("screenshotSets", .array(language.screenshotSets.map { set in .object([("displayType", .string(set.displayType)), ("screenshots", .array(set.screenshots.map { .object([("index", .number(Double($0.index))), ("image", $0.value)]) }))]) }))])
        }))])
    }
    @Test func importedBaselineHeadersAndInformationMatchPrimaryWithoutDraftOverlays() throws {
        let cases = try list(fixture()["baselines"]); #expect(cases.count == 6)
        for item in cases {
            let history = try list(item["history"]).map { try archive($0) }
            let value = try AppOverviewMaterial.Snapshot(accountId: accountId, appId: appId, history: history, plan: nil)
            #expect(value.latest?.id == item["latestId"]?.text && value.name(configured: "Synthetic configured app") == item["name"]?.text)
            #expect(value.bundleId == item["bundleId"]?.text && value.primaryLocale == item["primaryLocale"]?.text)
            let info = JSONText.array(value.information.map { .object([("locale", .string($0.locale)), ("name", .string($0.name)), ("subtitle", .string($0.subtitle))]) })
            #expect(info == item["information"])
        }
    }
    @Test func collectionSummariesIncludeEverySavedVersionWithoutDetailText() throws {
        let cases = try list(fixture()["pages"])
        for item in cases {
            let source = try archive(#require(item["revision"])), summaries = try AppOverviewMaterial.summaries(source)
            let ids = try list(source.value["versions"]).map { $0["id"]?.text }
            #expect(summaries.map { Optional($0.id) } == ids)
            #expect(!JSONText.array(summaries.map(\.json)).stringify().contains("Synthetic immutable description"))
        }
    }
    @Test func everyPageMatchesPrimaryAndContainsOnlyFiveSummaries() throws {
        let cases = try list(fixture()["pages"]); #expect(cases.count == 97)
        for item in cases {
            let source = try archive(#require(item["revision"])); guard case .number(let requested)? = item["requested"] else { throw RevisionHistoryFailure.invalid }
            let page = try AppOverviewMaterial.Page(source, requested: requested); try page.validateReceipt()
            #expect(page.json.stringify() == item["expected"]?.stringify() && page.documentRevision == 17 && page.versions.count <= 5)
            #expect(!page.json.stringify().contains("Synthetic immutable description") && !page.json.stringify().contains("sha256"))
        }
        for item in try list(fixture()["badPages"]) { #expect(throws: RevisionHistoryFailure.self) { try AppOverviewMaterial.Page(archive(item)).validateReceipt() } }
        let source = try archive(#require(cases.first?["revision"]))
        for request in [Double.nan, Double.infinity, -Double.infinity] { #expect(try AppOverviewMaterial.Page(source, requested: request).page == 1) }
        #expect(throws: RevisionHistoryFailure.invalid) { try AppOverviewMaterial.Page(archive(#require(cases.last?["revision"]), stamp: 0)).validateReceipt() }
    }
    @Test func completeDetailsPreserveFieldOrderTruthyValuesLegacyMediaAndExactGlobalImagePositions() throws {
        let fixture = try fixture(), cases = try list(fixture["details"]); #expect(cases.count >= 13)
        #expect(JSONText.array(AppOverviewMaterial.textFields.map { .object([("key", .string($0.0)), ("label", .string($0.1))]) }) == fixture["fields"])
        for item in cases {
            let raw = try #require(item["revision"]), versionId = try #require(item["versionId"]?.text)
            if item["rejected"] == .bool(true) {
                let version = try #require(try list(raw["versions"]).last)
                #expect(throws: RevisionHistoryFailure.self) { try AppOverviewMaterial.validateVersion(version, id: versionId) }
                continue
            }
            let source = try archive(raw), detail = try AppOverviewMaterial.Detail(source, versionId: versionId)
            #expect(detailJSON(detail).stringify() == item["expected"]?.stringify())
            #expect(detail.value == (try list(raw["versions"]).first { $0["id"]?.text == versionId }))
            #expect(detail.documentRevision == source.documentRevision && detail.revisionId == source.id)
            let shots = detail.languages.flatMap(\.screenshotSets).flatMap(\.screenshots)
            #expect(Set(shots.map(\.id)).count == shots.count)
            for shot in shots {
                #expect(shot.source.accountId == accountId && shot.source.appId == appId && shot.source.revisionId == source.id)
                #expect(shot.source.kind == .archivedScreenshot(index: shot.index, hash: try #require(shot.value["sha256"]?.text), documentRevision: source.documentRevision))
                #expect(shot.galleryItem.id == source.id + "/" + String(shot.index) && !shot.galleryItem.local)
            }
        }
        let invalid = JSONText.object([("id", .string("synthetic-version")), ("fields", .object([("description", .number(.nan))])), ("localizations", .array([]))])
        #expect(throws: RevisionHistoryFailure.invalid) { try AppOverviewMaterial.validateVersion(invalid, id: "synthetic-version") }
    }
    @Test func liveLabelsReviewEligibilityAndLiteralTargetMatchingMatchPrimary() throws {
        let fixture = try fixture(), cases = try list(fixture["live"]); #expect(cases.count == 37)
        let scope = try RecoveryGuidance.Scope(accountId: accountId, appId: appId)
        for item in cases {
            let raw = try #require(item["value"]), attrs = try #require(raw["attributes"])
            let entry = AppOverviewVersions.Entry(.init(id: try #require(raw["id"]?.text), platform: try #require(attrs["platform"]?.text), number: try #require(attrs["versionString"]?.text), state: try #require(item["rawState"]?.text)))
            #expect(entry.json.stringify() == item["expected"]?.stringify())
            if entry.inReview {
                let target = try AppOverviewVersions.Cancellation(scope: scope, version: entry)
                #expect(target.request.scope == .cancelSubmission && target.request.versionId == entry.id && target.request.accountId == accountId && target.request.appId == appId)
                #expect(target.href == "/apps/" + accountId + "/" + appId + "/publish?scope=cancel-submission&versionId=" + entry.id)
                #expect(target.allowed(current: scope, decision: .ready) && !target.allowed(current: nil, decision: .ready))
                #expect(!target.allowed(current: scope, decision: .wait, discardConfirmed: true) && !target.allowed(current: scope, decision: .confirmDiscard))
                #expect(target.allowed(current: scope, decision: .confirmDiscard, discardConfirmed: true))
            } else { #expect(throws: PublishFailure.self) { try AppOverviewVersions.Cancellation(scope: scope, version: entry) } }
        }
        let entries = [AppOverviewVersions.Entry(.init(id: "synthetic-target", platform: "IOS", number: "é", state: "IN_REVIEW")), AppOverviewVersions.Entry(.init(id: "synthetic-other", platform: "IOS", number: "2.0", state: "READY_FOR_REVIEW"))]
        for item in try list(fixture["targetChecks"]) {
            let targetVersion = try #require(item["targetVersion"])
            let plan = try #require(ReleasePlan(.object([("accountId", .string(accountId)), ("appId", .string(appId)), ("sourceRevisionId", .string("synthetic-source")), ("baseVersionId", .string("synthetic-base")), ("platform", .string("IOS")), ("targetVersion", targetVersion), ("updatedAt", .string("2026-01-01T00:00:00.000Z"))])))
            #expect(AppOverviewVersions.targetExists(plan, versions: entries) == (item["expected"] == .bool(true)))
        }
    }
    @Test func encryptedMaterialReadsKeepArchivedTextSeparateAndRejectStaleMissingForeignAndCanceledReads() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try await session.appOverviewMaterial(accountId: accountId, appId: appId), source = try #require(snapshot.latest)
        let detail = try await session.savedVersionDetail(accountId: accountId, appId: appId, revisionId: source.id, documentRevision: source.documentRevision, versionId: "version-1")
        let loaded = try await session.textDraft(accountId: accountId, appId: appId, revisionId: source.id, localizationId: "version-locale-1", scope: .version)
        var fields = loaded.fields; fields["description"] = "Synthetic unsaved archive replacement"
        try await session.saveTextDraft(accountId: accountId, appId: appId, revisionId: source.id, localizationId: "version-locale-1", scope: .version, fields: fields, fingerprint: loaded.fingerprint)
        let reread = try await session.savedVersionDetail(accountId: accountId, appId: appId, revisionId: source.id, documentRevision: source.documentRevision, versionId: "version-1")
        #expect(reread.value == detail.value && reread.languages[0].fields.first?.value != fields["description"])
        let page = try await session.savedVersionPage(accountId: accountId, appId: appId, revisionId: source.id, documentRevision: source.documentRevision, page: 1)
        #expect(page.versions.map(\.id) == ["version-1"])
        await #expect(throws: RevisionHistoryFailure.self) { try await session.savedVersionDetail(accountId: accountId, appId: "1000000002", revisionId: source.id, documentRevision: source.documentRevision, versionId: "version-1") }
        await #expect(throws: RevisionHistoryFailure.missing) { try await session.savedVersionDetail(accountId: accountId, appId: appId, revisionId: source.id, documentRevision: source.documentRevision, versionId: "synthetic-missing") }
        let canceled = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await session.savedVersionPage(accountId: accountId, appId: appId, revisionId: source.id, documentRevision: source.documentRevision, page: 1) }
        await #expect(throws: CancellationError.self) { try await canceled.value }
        try await session.storeAccess { store in try store.transaction { _ in [.put(namespace: "revisions", key: accountId + ":" + appId + ":" + source.id, json: source.value.data)] } }
        await #expect(throws: RevisionHistoryFailure.stale) { try await session.savedVersionPage(accountId: accountId, appId: appId, revisionId: source.id, documentRevision: source.documentRevision, page: 1) }
        await #expect(throws: RevisionHistoryFailure.stale) { try await session.savedVersionDetail(accountId: accountId, appId: appId, revisionId: source.id, documentRevision: source.documentRevision, versionId: "version-1") }
        let latest = try #require(try await session.appOverviewMaterial(accountId: accountId, appId: appId).latest)
        #expect(latest.documentRevision > source.documentRevision)
        #expect(try await session.deleteArchivedRevision(accountId: accountId, appId: appId, revisionId: latest.id, expectedRevision: latest.documentRevision))
        await #expect(throws: RevisionHistoryFailure.missing) { try await session.savedVersionDetail(accountId: accountId, appId: appId, revisionId: latest.id, documentRevision: latest.documentRevision, versionId: "version-1") }
        try Setup.replaceGeneration(root.appendingPathComponent("state-v2"))
        await #expect(throws: SessionFailure.changed) { try await session.appOverviewMaterial(accountId: accountId, appId: appId) }
    }
    @Test func liveReadsUseOwnedSyntheticAppleVersionsAndNeverWriteOrFallbackToTheArchive() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "app-overview.appstoreconnect.test"
        StubProtocol.handle(host) { apple.handle($0) }; let client = try PublishingTests().client(account, host: host)
        let initial = try await session.currentAppVersions(account: account, appId: appId, client: client); #expect(initial.map(\.id) == ["version-1"])
        apple.lock.withLock { apple.versions.append(apple.versions[0]) }
        await #expect(throws: PublishFailure.self) { try await session.currentAppVersions(account: account, appId: appId, client: client) }
        apple.lock.withLock { apple.versions.removeLast(); apple.versions[0]["relationships"] = ["app": ["data": ["type": "apps", "id": "1000000002"]]] }
        await #expect(throws: PublishFailure.self) { try await session.currentAppVersions(account: account, appId: appId, client: client) }
        apple.lock.withLock { apple.versions.removeAll() }
        #expect(try await session.currentAppVersions(account: account, appId: appId, client: client).isEmpty)
        StubProtocol.handle(host) { _ in (503, [:], Data()) }
        await #expect(throws: (any Error).self) { try await session.currentAppVersions(account: account, appId: appId, client: client) }
        #expect(apple.writes.isEmpty)
    }
    @Test func openingCancellationKeepsTheExactVersionAndStillRequiresFreshChoicesAndAnExplicitReview() throws {
        let scope = try RecoveryGuidance.Scope(accountId: accountId, appId: appId), selected = PublishingWorkspace.Version(id: "synthetic-selected", platform: "IOS", number: "2.0", state: "IN_REVIEW")
        let target = try AppOverviewVersions.Cancellation(scope: scope, version: .init(selected))
        var editor = PublishingWorkspace.Editor(accountId: accountId, appId: appId); try editor.restore(target.request)
        #expect(editor.action == .cancel && editor.versionId == selected.id && !editor.canPrepare)
        let other = PublishingWorkspace.Version(id: "synthetic-other", platform: "IOS", number: "1.0", state: "WAITING_FOR_REVIEW")
        func choices(_ versions: [PublishingWorkspace.Version]?) -> PublishingWorkspace.Snapshot { .init(accountId: accountId, appId: appId, versions: versions, sources: nil, builds: nil, profiles: nil, defaultProfile: nil, plan: nil) }
        try editor.receive(choices([other, selected])); let request = try editor.request(); #expect(editor.canPrepare && request == target.request)
        try editor.receive(choices(nil)); #expect(!editor.canPrepare && editor.versionId == selected.id)
        try editor.receive(choices([other])); #expect(!editor.canPrepare && editor.versionId == selected.id)
        try editor.receive(choices([other, selected])); #expect(editor.versionId == selected.id && editor.canPrepare)
    }
    @Test func anAccountChangedOrReadCanceledDuringTheAppleRequestCannotDeliverEarlierChoices() async throws {
        for cancel in [false, true] {
            let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
            let account = try #require(try await session.accounts().first), apple = SyntheticApple(), gate = AnalyticsJobDelayStubProtocol.Gate()
            let host = cancel ? "app-overview-canceled.appstoreconnect.test" : "app-overview-changed.appstoreconnect.test"
            AnalyticsJobDelayStubProtocol.register(host, gate: gate, bytes: apple.page(apple.versions).2, path: "/v1/apps/1000000001/appStoreVersions")
            let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [AnalyticsJobDelayStubProtocol.self]
            let client = AppStoreConnectClient(token: try AppleToken(account: account, privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation), origin: try #require(URL(string: "https://" + host)), configuration: configuration)
            let pending = Task { try await session.currentAppVersions(account: account, appId: appId, client: client) }
            try await AppIconsTests().wait { gate.pending == 1 }
            if cancel { pending.cancel() }
            else {
                try await session.storeAccess { store in
                    let changed = Account(id: account.id, name: account.name, keyId: "SYNTHKEY02", keyType: account.keyType, issuerId: account.issuerId, appIds: account.appIds, appNames: account.appNames)
                    try store.transaction { _ in [.put(namespace: "accounts", key: "all", json: JSONText.array([WorkspaceSession.json(changed)]).data)] }
                }
            }
            gate.release()
            if cancel { await #expect(throws: CancellationError.self) { try await pending.value } }
            else { await #expect(throws: PublishFailure.self) { try await pending.value } }
            #expect(apple.writes.isEmpty)
        }
    }
    @Test func closedSessionsRejectMaterialAndReopeningPreservesTheExactSavedSnapshot() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let vault = await session.vault, before = try await session.appOverviewMaterial(accountId: accountId, appId: appId), source = try #require(before.latest)
        let page = try await session.savedVersionPage(accountId: accountId, appId: appId, revisionId: source.id, documentRevision: source.documentRevision, page: 1)
        try await session.signOut()
        await #expect(throws: SessionFailure.closed) { try await session.appOverviewMaterial(accountId: accountId, appId: appId) }
        await #expect(throws: SessionFailure.closed) { try await session.savedVersionPage(accountId: accountId, appId: appId, revisionId: source.id, documentRevision: source.documentRevision, page: 1) }
        await #expect(throws: SessionFailure.closed) { try await session.savedVersionDetail(accountId: accountId, appId: appId, revisionId: source.id, documentRevision: source.documentRevision, versionId: "version-1") }
        let reopened = try WorkspaceSession(workspace: Workspace(root: root), vault: vault)
        let after = try await reopened.appOverviewMaterial(accountId: accountId, appId: appId), reread = try await reopened.savedVersionPage(accountId: accountId, appId: appId, revisionId: source.id, documentRevision: source.documentRevision, page: 1)
        #expect(after.latest?.value == before.latest?.value && reread.json == page.json && reread.documentRevision == page.documentRevision)
    }
}
