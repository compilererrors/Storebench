import CryptoKit
import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct ReleaseReadinessSessionTests {
    init() throws { _ = try TestIsolation.require() }
    private let appId = "1000000001", revisionId = "00000000-0000-4000-8000-000000000002"
    private func plan(_ session: WorkspaceSession, account: Account) async throws -> ReleasePlan {
        try await session.saveReleasePlan(account: account, appId: appId, start: .reuse, sourceRevisionId: revisionId, baseVersionId: "version-1", targetVersion: "2.0", releaseType: "MANUAL", earliestReleaseDate: nil, expected: "null")
    }
    private func apple() -> SyntheticApple {
        let apple = SyntheticApple()
        apple.lock.withLock {
            // These checks cover the read-only fallback to the deprecated sets; placements are covered by ReleaseMediaStatusTests.
            apple.library = false
            var version = apple.versions[0]["attributes"] as! [String: Any]; version["versionString"] = "2.0"; version["copyright"] = "2026 Synthetic Publisher"; apple.versions[0]["attributes"] = version
            var build = apple.builds[0]["attributes"] as! [String: Any]; build["usesNonExemptEncryption"] = false; apple.builds[0]["attributes"] = build
            apple.rights = "DOES_NOT_USE_THIRD_PARTY_CONTENT"
            apple.reviewDetails = [["type": "appStoreReviewDetails", "id": "detail-1", "attributes": ["contactFirstName": "Synthetic", "contactLastName": "Reviewer", "contactEmail": "review@example.invalid", "contactPhone": "0000000000", "demoAccountRequired": false],
                "relationships": ["appStoreVersion": ["data": ["type": "appStoreVersions", "id": "version-1"]]]]]
        }; return apple
    }
    private func response(_ request: URLRequest, apple: SyntheticApple) -> (Int, [String: String], Data) {
        guard request.httpMethod == "GET" else { Issue.record("Release status attempted a write to the synthetic endpoint"); return (405, [:], Data()) }
        switch request.url!.path {
        case "/v1/appStoreVersions/version-1/build": return apple.lock.withLock { apple.page(apple.builds) }
        case "/v1/appStoreVersionLocalizations/version-locale-1/appPreviewSets": return apple.page([])
        case "/v1/appInfos/info-1/appInfoLocalizations": return apple.page([["type": "appInfoLocalizations", "id": "info-locale-1", "attributes": ["locale": "en-US", "name": "Sample App", "subtitle": "Sample subtitle"],
            "relationships": ["appInfo": ["data": ["type": "appInfos", "id": "info-1"]]]]])
        default: return apple.handle(request)
        }
    }
    private func state(_ snapshot: ReleaseReadinessSnapshot, _ id: String) throws -> ReleaseReadiness.State { try #require(snapshot.steps.first { $0.id == id }?.state) }
    private func documents(_ session: WorkspaceSession) async throws -> JSONText {
        try await session.storeAccess { store in
            .array(try ["revisions", "drafts", "release_plans", "publish_reviews"].flatMap { namespace in
                try store.documents(namespace: namespace).map { .array([.string(namespace), .string($0.key), .number(Double($0.revision)), .string(try JSONText.parse($0.payload).sha256)]) }
            })
        }
    }
    @Test func resourceStatesUseThePrimaryRolePrecedenceAndKeepMalformedStatesUnknown() {
        let vectors: [(String, [String: JSONValue], String)] = [
            ("appStoreVersions", ["appVersionState": .string(""), "appStoreState": .string("READY_FOR_DISTRIBUTION"), "state": .string("IN_REVIEW")], "READY_FOR_DISTRIBUTION"),
            ("appStoreVersions", ["appVersionState": .string("IN_REVIEW"), "appStoreState": .string("READY_FOR_DISTRIBUTION")], "IN_REVIEW"),
            ("appStoreVersions", ["state": .string("IN_REVIEW")], ""),
            ("appStoreVersions", ["appVersionState": .null, "appStoreState": .string("PREPARE_FOR_SUBMISSION")], "PREPARE_FOR_SUBMISSION"),
            ("appStoreVersions", ["appVersionState": .bool(false), "appStoreState": .string("PREPARE_FOR_SUBMISSION")], "PREPARE_FOR_SUBMISSION"),
            ("appStoreVersions", ["appVersionState": .number(0), "appStoreState": .string("PREPARE_FOR_SUBMISSION")], "PREPARE_FOR_SUBMISSION"),
            ("appStoreVersions", ["appVersionState": .bool(true), "appStoreState": .string("PREPARE_FOR_SUBMISSION")], ""),
            ("appInfos", ["state": .string(""), "appStoreState": .string("PREPARE_FOR_SUBMISSION")], "PREPARE_FOR_SUBMISSION"),
            ("appInfos", ["state": .string("REJECTED"), "appStoreState": .string("READY_FOR_DISTRIBUTION"), "appVersionState": .string("IN_REVIEW")], "REJECTED"),
            ("appInfos", ["state": .object([:]), "appStoreState": .string("PREPARE_FOR_SUBMISSION")], ""),
            ("appInfos", ["state": .array([]), "appStoreState": .string("PREPARE_FOR_SUBMISSION")], ""),
            ("builds", ["appVersionState": .string(""), "state": .string("VALID")], ""),
            ("builds", ["state": .string("VALID")], "VALID")
        ]
        for (type, attributes, expected) in vectors {
            let item = AppStoreConnectClient.Resource(type: type, id: "synthetic-state", attributes: attributes, relationships: nil)
            #expect(Apple.state(item).utf8.elementsEqual(expected.utf8))
        }
    }
    @Test func emptyStateAliasesRetainTheCorrectLiveVersionAndEditableAppInfo() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), plan = try await plan(session, account: account), apple = apple(), host = "readiness-state-alias.appstoreconnect.test"
        apple.lock.withLock {
            var fields = apple.versions[0]["attributes"] as! [String: Any]
            fields["appVersionState"] = ""; fields["appStoreState"] = "READY_FOR_DISTRIBUTION"; fields["state"] = "IN_REVIEW"
            apple.versions[0]["attributes"] = fields
        }
        StubProtocol.handle(host) { request in
            if request.url?.path == "/v1/apps/1000000001/appInfos" {
                return apple.page([
                    ["type": "appInfos", "id": "info-1", "attributes": ["state": "", "appStoreState": "PREPARE_FOR_SUBMISSION"], "relationships": ["app": ["data": ["type": "apps", "id": "1000000001"]]]],
                    ["type": "appInfos", "id": "info-live", "attributes": ["state": "READY_FOR_DISTRIBUTION"], "relationships": ["app": ["data": ["type": "apps", "id": "1000000001"]]]]
                ])
            }
            if request.url?.path == "/v1/appInfos/info-live/appInfoLocalizations" {
                return apple.page([["type": "appInfoLocalizations", "id": "info-live-locale", "attributes": ["locale": "en-US", "name": "Sample App", "subtitle": "Sample subtitle"],
                    "relationships": ["appInfo": ["data": ["type": "appInfos", "id": "info-live"]]]]])
            }
            return response(request, apple: apple)
        }
        let client = try PublishingTests().client(account, host: host), before = try await documents(session)
        let value = try await session.releaseReadiness(account: account, appId: appId, revisionId: revisionId, planToken: plan.token, client: client)
        #expect(try state(value, "app-configuration") == .ready); #expect(try state(value, "age-rating") == .ready)
        #expect(try state(value, "submission") == .ready); #expect(try state(value, "release") == .ready)
        let versions = try await session.currentAppVersions(account: account, appId: appId, client: client)
        #expect(versions.count == 1); #expect(versions.first?.state == "READY_FOR_DISTRIBUTION")
        #expect(try await documents(session) == before); #expect(apple.lock.withLock { apple.writes.isEmpty })
    }
    @Test func completeOwnedReadsKeepEverySavedDocumentAndAppleWriteHistoryUnchanged() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), plan = try await plan(session, account: account), apple = apple(), host = "readiness-complete.appstoreconnect.test"
        StubProtocol.handle(host) { response($0, apple: apple) }; let client = try PublishingTests().client(account, host: host), before = try await documents(session)
        let value = try await session.releaseReadiness(account: account, appId: appId, revisionId: revisionId, planToken: plan.token, client: client)
        #expect(value.scope.accountId == account.id && value.plan.token == plan.token && value.targetVersionId == "version-1")
        for id in ["plan", "version", "copyright", "review-info", "build", "export-compliance", "territories"] { #expect(try state(value, id) == .ready) }
        #expect(try state(value, "app-configuration") == .ready); #expect(try state(value, "age-rating") == .ready)
        #expect(try state(value, "media:en-US") == .review); #expect(try state(value, "local:en-US") == .blocked)
        #expect(try await documents(session) == before); #expect(apple.lock.withLock { apple.writes.isEmpty })
        let offline = try await session.releaseReadiness(account: account, appId: appId, revisionId: revisionId, planToken: plan.token, client: nil)
        #expect(try state(offline, "version") == .unknown); #expect(try state(offline, "local:en-US") == .blocked); #expect(offline.targetVersionId == nil)
        #expect(try await documents(session) == before)
    }
    @Test func partialForeignAndDuplicateRemoteReadsPreserveIndependentKnownObservations() async throws {
        for mode in ["information", "foreign-version", "incomplete-version", "duplicate-locale", "partial-media", "missing-version", "unrelated-category", "foreign-age"] {
            let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
            let account = try #require(try await session.accounts().first), plan = try await plan(session, account: account), apple = apple(), host = "readiness-\(mode).appstoreconnect.test"
            if mode == "foreign-version" { apple.lock.withLock { apple.versions[0]["relationships"] = ["app": ["data": ["type": "apps", "id": "1000000002"]]] } }
            if mode == "incomplete-version" { apple.lock.withLock { apple.versions[0]["attributes"] = ["platform": "IOS", "appVersionState": "PREPARE_FOR_SUBMISSION"] } }
            if mode == "missing-version" { apple.lock.withLock { apple.versions = [] } }
            if mode == "duplicate-locale" { apple.lock.withLock { apple.locales.append(apple.locales[0]) } }
            StubProtocol.handle(host) { request in
                let path = request.url!.path
                if mode == "information" && path == "/v1/apps/1000000001/appInfos" || mode == "partial-media" && path.hasSuffix("/appPreviewSets") { return (400, [:], Data()) }
                if mode == "unrelated-category" && path == "/v1/appInfos/info-1" { return apple.page(["type": "appInfos", "id": "info-1", "relationships": ["app": ["data": ["type": "apps", "id": "1000000001"]], "primaryCategory": ["data": ["type": "synthetic-invalid", "id": "GAMES"]]]]) }
                if mode == "foreign-age" && path.hasSuffix("/ageRatingDeclaration") { return apple.page(["type": "ageRatingDeclarations", "id": "age-1", "relationships": ["appInfo": ["data": ["type": "appInfos", "id": "synthetic-other-info"]]]]) }
                return response(request, apple: apple)
            }
            let value = try await session.releaseReadiness(account: account, appId: appId, revisionId: revisionId, planToken: plan.token, client: PublishingTests().client(account, host: host))
            #expect(try state(value, "territories") == .ready); #expect(try state(value, "local:en-US") == .blocked)
            switch mode {
            case "information": #expect(try state(value, "app-configuration") == .unknown); #expect(try state(value, "age-rating") == .unknown); #expect(try state(value, "version") == .ready)
            case "foreign-version", "incomplete-version": #expect(try state(value, "version") == .unknown); #expect(try state(value, "build") == .unknown)
            case "missing-version": #expect(try state(value, "version") == .blocked); #expect(try state(value, "build") == .unknown)
            case "unrelated-category": #expect(try state(value, "app-configuration") == .unknown); #expect(try state(value, "age-rating") == .ready)
            case "foreign-age": #expect(try state(value, "age-rating") == .unknown); #expect(try state(value, "app-configuration") == .ready)
            default: #expect(try state(value, "media:en-US") == .unknown); #expect(try state(value, "version") == .ready)
            }
            #expect(apple.lock.withLock { apple.writes.isEmpty })
        }
    }
    @Test func latePlanDraftAndEvenUnchangedDraftRevisionWritesRejectTheEarlierReadWithoutHoldingWriteLocks() async throws {
        for change in ["plan", "text", "same-draft"] {
            let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
            let account = try #require(try await session.accounts().first), plan = try await plan(session, account: account), apple = apple(), gate = AnalyticsJobDelayStubProtocol.Gate(), host = "readiness-late-\(change).appstoreconnect.test"
            defer { gate.release() }; StubProtocol.handle(host) { response($0, apple: apple) }
            AnalyticsJobDelayStubProtocol.register(host, gate: gate, bytes: apple.lock.withLock { apple.page(apple.versions).2 }, path: "/v1/apps/1000000001/appStoreVersions")
            let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [AnalyticsJobDelayStubProtocol.self, StubProtocol.self]
            let client = AppStoreConnectClient(token: try AppleToken(account: account, privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation), origin: try #require(URL(string: "https://" + host)), configuration: configuration)
            let pending = Task { try await session.releaseReadiness(account: account, appId: appId, revisionId: revisionId, planToken: plan.token, client: client) }
            try await AppIconsTests().wait { gate.pending > 0 }
            if change == "plan" { _ = try await session.saveReleasePlan(account: account, appId: appId, start: .reuse, sourceRevisionId: revisionId, baseVersionId: "version-1", targetVersion: "3.0", releaseType: "MANUAL", earliestReleaseDate: nil, expected: plan.token) }
            else if change == "text" {
                let text = try await session.textDraft(accountId: account.id, appId: appId, revisionId: revisionId, localizationId: "version-locale-1", scope: .version)
                _ = try await session.saveTextDraft(accountId: account.id, appId: appId, revisionId: revisionId, localizationId: "version-locale-1", scope: .version, fields: ["description": "Synthetic later save"], fingerprint: text.fingerprint)
            } else { try await session.mutateDraft(accountId: account.id, appId: appId, revisionId: revisionId) { draft, _ in (draft, ()) } }
            gate.release(); await #expect(throws: ReleaseTextFailure.stale) { try await pending.value }
            #expect(apple.lock.withLock { apple.writes.isEmpty })
        }
    }
    @Test func cancelledOrReconfiguredAccountsCannotReturnTheEarlierSnapshot() async throws {
        for cancel in [false, true] {
            let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
            let account = try #require(try await session.accounts().first), plan = try await plan(session, account: account), apple = apple(), gate = AnalyticsJobDelayStubProtocol.Gate(), host = cancel ? "readiness-cancel.appstoreconnect.test" : "readiness-account.appstoreconnect.test"
            defer { gate.release() }; StubProtocol.handle(host) { response($0, apple: apple) }
            AnalyticsJobDelayStubProtocol.register(host, gate: gate, bytes: apple.lock.withLock { apple.page(apple.versions).2 }, path: "/v1/apps/1000000001/appStoreVersions")
            let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [AnalyticsJobDelayStubProtocol.self, StubProtocol.self]
            let client = AppStoreConnectClient(token: try AppleToken(account: account, privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation), origin: try #require(URL(string: "https://" + host)), configuration: configuration)
            let pending = Task { try await session.releaseReadiness(account: account, appId: appId, revisionId: revisionId, planToken: plan.token, client: client) }
            try await AppIconsTests().wait { gate.pending > 0 }
            if cancel { pending.cancel() }
            else {
                try await session.storeAccess { store in
                    let changed = Account(id: account.id, name: account.name, keyId: "SYNTHKEY02", keyType: account.keyType, issuerId: account.issuerId, appIds: account.appIds, appNames: account.appNames)
                    try FileMutex.withLock(store.directory.appendingPathComponent("accounts.mutex")) { try store.transaction { _ in [.put(namespace: "accounts", key: "all", json: JSONText.array([WorkspaceSession.json(changed)]).data)] } }
                }
            }
            gate.release()
            if cancel { await #expect(throws: CancellationError.self) { try await pending.value } }
            else { await #expect(throws: PublishFailure.self) { try await pending.value } }
        }
    }
    @Test func mediaReadersRejectForeignSetsAssetsDuplicatesAndPartialReads() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first)
        for mode in ["complete", "foreign-set", "foreign-shot", "duplicate-size", "duplicate-shot", "partial-preview"] {
            let apple = apple(), host = "readiness-media-\(mode).appstoreconnect.test"
            apple.lock.withLock {
                if mode == "foreign-set" { apple.sets[0]["relationships"] = ["appStoreVersionLocalization": ["data": ["type": "appStoreVersionLocalizations", "id": "synthetic-other-locale"]]] }
                if mode == "foreign-shot" { apple.shots[0]["relationships"] = ["appScreenshotSet": ["data": ["type": "appScreenshotSets", "id": "synthetic-other-set"]]] }
                if mode == "duplicate-size" { apple.sets.append(apple.sets[0]) }
                if mode == "duplicate-shot" { apple.shots.append(apple.shots[0]) }
            }
            StubProtocol.handle(host) { request in if mode == "partial-preview", request.url!.path.hasSuffix("/appPreviewSets") { return (400, [:], Data()) }; return response(request, apple: apple) }
            let client = try PublishingTests().client(account, host: host)
            if mode == "complete" { let value = try await ReleaseMediaStatus.read(localizationId: "version-locale-1", client: client); #expect(value.screenshots.count == 1 && value.previews.isEmpty) }
            else { await #expect(throws: (any Error).self) { try await ReleaseMediaStatus.read(localizationId: "version-locale-1", client: client) } }
            #expect(apple.lock.withLock { apple.writes.isEmpty })
        }
    }
}
