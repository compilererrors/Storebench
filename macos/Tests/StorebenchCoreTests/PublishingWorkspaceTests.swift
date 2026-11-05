import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct PublishingWorkspaceTests {
    init() throws { _ = try TestIsolation.require() }
    private func fixture() throws -> JSONText { try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/publishing-workspace.json"))) }
    private func rows(_ value: JSONText?) throws -> [JSONText] { guard case .array(let values)? = value else { throw PublishFailure.invalid("Invalid synthetic publishing choices.") }; return values }
    private func versions(_ value: JSONText?) throws -> [PublishingWorkspace.Version] {
        try rows(value).map { .init(id: try #require($0["id"]?.text), platform: try #require($0["platform"]?.text), number: try #require($0["number"]?.text), state: try #require($0["state"]?.text), releaseType: $0["releaseType"]?.text ?? "", copyright: $0["copyright"]?.text ?? "") }
    }
    private func builds(_ value: JSONText?) throws -> [PublishingWorkspace.Build] {
        try rows(value).map { .init(id: try #require($0["id"]?.text), name: $0["name"]?.text ?? "", platform: try #require($0["platform"]?.text), number: try #require($0["number"]?.text)) }
    }
    private func plan() throws -> ReleasePlan {
        try #require(ReleasePlan(.object([("accountId", .string("synthetic-account")), ("appId", .string("1000000001")), ("sourceRevisionId", .string("source-1")), ("baseVersionId", .string("live-old")), ("platform", .string("IOS")), ("targetVersion", .string("2.0")), ("releaseType", .string("MANUAL")), ("updatedAt", .string("2026-01-01T00:00:00.000Z"))])))
    }
    private func snapshot(knownVersions: Bool = true, knownBuilds: Bool = true, sources: Bool = true) throws -> PublishingWorkspace.Snapshot {
        let fixture = try fixture()
        return .init(accountId: "synthetic-account", appId: "1000000001", versions: knownVersions ? try versions(fixture["versions"]) : nil, sources: sources ? [.init(id: "source-1", name: "Sample import", versions: [.init(id: "live-old", name: "iOS 1.0"), .init(id: "live-ready", name: "iOS 2.0")]), .init(id: "source-2", name: "Older sample", versions: [.init(id: "missing-version", name: "Old sample")])] : nil,
                     builds: knownBuilds ? try builds(fixture["builds"]) : nil, profiles: [.init(id: "profile-1", name: "Sample profile"), .init(id: "profile-2", name: "Other sample")], defaultProfile: "profile-1", plan: try plan())
    }
    private func review(id: String = "synthetic-review", scope: PublishRequest.Scope = .metadata, state: String = "prepared", expires: String = "2026-01-01T12:00:01.000Z", steps: Bool = true) throws -> PublishReview {
        try #require(PublishReview(.object([("id", .string(id)), ("title", .string("Sample publishing review")), ("fingerprint", .string(String(repeating: "a", count: 64))), ("createdAt", .string("2026-01-01T11:59:00.000Z")), ("expiresAt", .string(expires)), ("updatedAt", .string("2026-01-01T11:59:00.000Z")), ("request", PublishRequest(accountId: "synthetic-account", appId: "1000000001", scope: scope).json), ("state", .string(state)), ("notes", .array([])),
                                          ("steps", .array(steps ? [.object([("key", .string("0")), ("kind", .string("api")), ("label", .string("Sample step")), ("detail", .string("Synthetic data only")), ("method", .string("POST")), ("path", .array([.string("analyticsReportRequests")])), ("state", .string("pending"))])] : []))])))
    }
    @Test func defaultAppleTargetsAndMatchingBuildsUseActualPrimaryChoices() throws {
        let fixture = try fixture(), versions = try versions(fixture["versions"]), builds = try builds(fixture["builds"])
        let cases = try rows(fixture["initial"]); #expect(cases.count == 324)
        for row in cases {
            let scopeName = try #require(row["scope"]?.text)
            let scope = try #require(PublishRequest.Scope(rawValue: scopeName))
            let plan = row["planLabel"]?.text?.split(separator: " ", maxSplits: 1).map(String.init)
            let id = PublishingWorkspace.initialVersion(versions, scope: scope, requested: row["requested"]?.text, planPlatform: plan?.first, planNumber: plan?.last, reviewVersion: row["reviewVersion"]?.text)
            #expect(id == row["expected"]?.text)
        }
        for row in try rows(fixture["matching"]) { #expect(JSONText.array(PublishingWorkspace.matchingBuilds(builds, version: versions.first { $0.id == row["versionId"]?.text }).map { .string($0.id) }) == row["expected"]) }
    }
    @Test func historyLabelsExpiryAndAllPagesMatchActualPrimary() throws {
        let fixture = try fixture()
        guard case .number(let timestamp)? = fixture["now"] else { throw PublishFailure.invalid("Invalid synthetic clock.") }; let now = Date(timeIntervalSince1970: timestamp / 1000)
        let cases = try rows(fixture["history"]); #expect(cases.count == 45)
        for row in cases {
            let input = try #require(row["input"]), scopeName = try #require(input["scope"]?.text)
            let scope = try #require(PublishRequest.Scope(rawValue: scopeName))
            let value = try review(scope: scope, state: try #require(input["state"]?.text), expires: try #require(input["expiresAt"]?.text))
            #expect(PublishingReviewPresentation.label(value, now: now) == row["expected"]?.text)
            #expect(PublishingReviewPresentation.canApprove(value, now: now) == (value.state == "prepared" && value.expiresAt > "2026-01-01T12:00:00.000Z"))
        }
        #expect(!PublishingReviewPresentation.canApprove(try review(expires: "invalid"), now: now))
        #expect(!PublishingReviewPresentation.canApprove(try review(steps: false), now: now))
        let history = try (0..<27).map { try review(id: "synthetic-\($0)") }
        var displayed: [String] = []
        for number in 1...3 { let page = PublishingReviewPresentation.page(history, requested: number); #expect(page.page == number && page.pages == 3 && page.total == 27); displayed += page.items.map(\.id) }
        #expect(displayed == history.map(\.id))
        #expect(PublishingReviewPresentation.page(history, requested: 999).page == 3)
        #expect(PublishingReviewPresentation.page([], requested: 999).page == 1)
    }
    @Test func deletionAndArchivalUseDestructivePresentationWithoutChangingApproval() throws {
        var value = try review()
        let fingerprint = value.fingerprint, now = Date(timeIntervalSince1970: 1_767_268_800)
        func step(_ method: String, archived: Bool? = nil, kind: PublishStep.Kind = .api) -> PublishStep {
            let body = archived.map { JSONText.object([("data", .object([("attributes", .object([("archived", .bool($0))]))]))]) }
            return PublishStep(key: "synthetic-step", group: nil, label: "Synthetic change", detail: "Synthetic control presentation", before: nil, after: nil,
                               kind: kind, method: method, path: [.string("appScreenshots"), .string("synthetic-image")], body: body, asset: nil, guardValue: nil, state: "pending", resultId: nil)
        }
        #expect(!PublishingReviewPresentation.hasDestructiveChanges(value))
        for change in [step("DELETE"), step("PATCH", archived: true)] {
            value.steps = [value.steps[0], change]
            #expect(PublishingReviewPresentation.hasDestructiveChanges(value))
            #expect(value.state == "prepared" && value.fingerprint == fingerprint)
            #expect(PublishingReviewPresentation.canApprove(value, now: now))
            value.steps = [value.steps[0]]
        }
        for change in [step("PATCH", archived: false), step("POST", archived: true), step("DELETE", kind: .verify)] {
            value.steps = [change]
            #expect(!PublishingReviewPresentation.hasDestructiveChanges(value))
        }
        value.steps = [step("DELETE")]; value.state = "complete"
        #expect(!PublishingReviewPresentation.canApprove(value, now: now))
    }
    @Test func sourceAndLiveSelectionsRemainDistinctAndPlannedContentIsExplicit() throws {
        var editor = PublishingWorkspace.Editor(accountId: "synthetic-account", appId: "1000000001"); try editor.receive(snapshot())
        #expect(editor.versionId == "live-ready" && editor.sourceVersionId == "live-old" && editor.targetMode == "apple-version")
        var request = try editor.request(); #expect(request.scope == .metadata && request.revisionId == "source-1" && request.versionId == "live-old")
        try editor.choosePlannedMaterial(); request = try editor.request(); #expect(request.targetMode == "release-plan" && request.versionId == "live-old" && editor.destination?.id == "live-ready")
        editor.chooseSource("source-2"); #expect(editor.targetMode == "apple-version" && !editor.planSelected && !editor.canPrepare)
        editor.chooseSource("source-1"); editor.chooseSourceVersion("live-ready"); #expect(editor.targetMode == "apple-version" && !editor.planSelected && editor.canPrepare)
    }
    @Test func buildProfileAndActionChangesProduceScopedRequestsAndClearForeignBuilds() throws {
        var editor = PublishingWorkspace.Editor(accountId: "synthetic-account", appId: "1000000001"); try editor.receive(snapshot())
        editor.chooseAction(.submit); editor.chooseBuild("build-1"); var request = try editor.request(); #expect(request.versionId == "live-ready" && request.buildId == "build-1")
        editor.chooseBuild("build-2"); #expect(!editor.canPrepare)
        editor.chooseVersion("live-old"); #expect(editor.buildId.isEmpty && editor.builds.map(\.id) == ["build-3"])
        request = try editor.request(); #expect(request.buildId == nil && request.versionId == "live-old")
        editor.chooseAction(.pricing); editor.chooseProfile("profile-2"); #expect(try editor.request().profileId == "profile-2")
        editor.chooseProfile("missing"); #expect(!editor.canPrepare)
        editor.chooseAction(.analytics); editor.analyticsSnapshot = true; #expect(try editor.request().scope == .analyticsSnapshot)
        editor.chooseAction(.releaseVersion); #expect(editor.versionId == "live-ready", "An explicit matching plan takes precedence, as in the primary workbench.")
        editor.chooseAction(.cancel); #expect(editor.versionId == "live-ready")
    }
    @Test func refreshFailuresAndMissingSelectionsNeverReplaceUnsavedCopyrightOrRecordedIDs() throws {
        var editor = PublishingWorkspace.Editor(accountId: "synthetic-account", appId: "1000000001"); try editor.receive(snapshot())
        editor.chooseAction(.copyright); editor.copyright = "2026 Synthetic replacement"; let id = editor.versionId
        try editor.receive(snapshot(knownVersions: false)); #expect(editor.versionId == id && editor.copyright == "2026 Synthetic replacement" && editor.dirty && !editor.canPrepare)
        try editor.receive(snapshot()); #expect(editor.versionId == id && editor.copyright == "2026 Synthetic replacement" && editor.dirty && editor.canPrepare)
        var recorded = PublishRequest(accountId: editor.accountId, appId: editor.appId, scope: .metadata, revisionId: "deleted-source", versionId: "deleted-version")
        try editor.restore(recorded); try editor.receive(snapshot()); #expect(editor.revisionId == "deleted-source" && editor.sourceVersionId == "deleted-version" && !editor.canPrepare)
        recorded = PublishRequest(accountId: "foreign", appId: editor.appId, scope: .metadata)
        #expect(throws: PublishFailure.self) { try editor.restore(recorded) }
        var failed = PublishingWorkspace.Editor(accountId: "synthetic-account", appId: "1000000001"); try failed.receive(snapshot(knownVersions: false, knownBuilds: false, sources: false)); #expect(!failed.canPrepare)
        try failed.receive(snapshot()); #expect(failed.canPrepare && failed.sourceVersionId == "live-old")
        editor.chooseAction(.copyright); editor.copyright = "2026 é Studio"
        let copyright = try editor.request(); #expect(editor.matchesCopyright(copyright))
        editor.copyright = "2026 e\u{0301} Studio"; #expect(editor.dirty && !editor.matchesCopyright(copyright))
        editor.copyright = copyright.copyright!; editor.chooseVersion("live-old"); #expect(!editor.matchesCopyright(copyright))
    }
    @Test func liveCatalogUsesOwnedVersionsAndProcessedBuildsIncludingExpiredTestFlightAvailability() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "publishing-choices.appstoreconnect.test", app = "1000000001"
        apple.lock.withLock { var attrs = apple.builds[0]["attributes"] as! [String: Any]; attrs["expired"] = true; apple.builds[0]["attributes"] = attrs }
        StubProtocol.handle(host) { apple.handle($0) }
        let client = try PublishingTests().client(account, host: host), value = try await session.publishingWorkspace(account: account, appId: app, includeBuilds: true, client: client)
        #expect(value.versions?.map(\.id) == ["version-1"] && value.sources?.isEmpty == false && value.profiles?.isEmpty == false)
        #expect(value.builds?.map(\.id) == ["build-7"], "\(value.issues)")
        #expect(apple.writes.isEmpty)
        let draft = try await session.saveReleasePlan(account: account, appId: app, start: .empty(platform: "IOS", locale: "en-US"), sourceRevisionId: nil, baseVersionId: nil, targetVersion: "2.0", releaseType: "MANUAL", earliestReleaseDate: nil, expected: "null")
        let planned = try await session.publishingWorkspace(account: account, appId: app, client: client)
        #expect(planned.sources?.contains(where: { $0.id == draft.sourceRevisionId }) == true)
        try await session.removeReleasePlan(accountId: account.id, appId: app, expected: draft.token)
        let unplanned = try await session.publishingWorkspace(account: account, appId: app, client: client)
        #expect(unplanned.sources?.contains(where: { $0.id == draft.sourceRevisionId }) == false)
        #expect(apple.writes.isEmpty)
        apple.lock.withLock { apple.versions.append(apple.versions[0]) }
        let duplicate = try await session.publishingWorkspace(account: account, appId: app, client: client); #expect(duplicate.versions == nil && duplicate.issues.count == 1)
        apple.lock.withLock { apple.versions.removeLast(); apple.versions[0]["relationships"] = ["app": ["data": ["type": "apps", "id": "1000000002"]]] }
        let foreign = try await session.publishingWorkspace(account: account, appId: app, client: client); #expect(foreign.versions == nil)
        #expect(apple.writes.isEmpty)
    }
    @Test func independentCatalogFailuresRemainUnknownAndCannotEnableSubmission() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "publishing-choices-failure.appstoreconnect.test"
        StubProtocol.handle(host) { request in
            if request.url?.path == "/v1/builds" { return (503, [:], Data()) }; return apple.handle(request)
        }
        let value = try await session.publishingWorkspace(account: account, appId: "1000000001", includeBuilds: true, client: PublishingTests().client(account, host: host))
        #expect(value.versions != nil && value.builds == nil && value.issues.count == 1)
        var editor = PublishingWorkspace.Editor(accountId: account.id, appId: "1000000001"); try editor.receive(value); editor.chooseAction(.submit); #expect(!editor.canPrepare)
        #expect(apple.writes.isEmpty)
    }
    @Test func openingAndRecheckingSavedSelectionsDoesNotReplayOrChangeTheirOriginalFingerprint() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), host = "publishing-history-open.appstoreconnect.test", app = "1000000001"
        StubProtocol.handle(host) { apple.handle($0) }; let client = try PublishingTests().client(account, host: host)
        let request = PublishRequest(accountId: account.id, appId: app, scope: .versionCopyright, versionId: "version-1", copyright: "2026 Synthetic Studio")
        let prepared = try await session.preparePublishing(account: account, request: request, client: client)
        let opened = try await session.publishStatus(accountId: account.id, appId: app, id: prepared.id)
        #expect(opened.fingerprint == prepared.fingerprint && opened.request == request && apple.writes.isEmpty)
        let completed = try await session.approvePublishing(account: account, appId: app, id: opened.id, fingerprint: opened.fingerprint, client: client)
        #expect(completed.state == "complete" && apple.writes.count == 1)
        let seen = try await session.publishStatus(accountId: account.id, appId: app, id: completed.id); #expect(seen.state == "complete")
        let next = try await session.preparePublishing(account: account, request: seen.request, client: client)
        #expect(next.id != seen.id && apple.writes.count == 1)
        await #expect(throws: PublishFailure.self) { try await session.approvePublishing(account: account, appId: app, id: seen.id, fingerprint: seen.fingerprint, client: client) }
        #expect(apple.writes.count == 1)
    }
}
