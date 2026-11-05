import Foundation
import Testing
@testable import StorebenchCore

/// Each release step reads only the Apple parts it shows; the rest arrive in the background and merge into the same status.
@Suite(.serialized) struct ReleaseReadinessPartsTests {
    init() throws { _ = try TestIsolation.require() }
    private let appId = "1000000001", revisionId = "00000000-0000-4000-8000-000000000002"
    private enum Failure: Error { case synthetic }
    private func plan(_ session: WorkspaceSession, account: Account, target: String = "2.0") async throws -> ReleasePlan {
        try await session.saveReleasePlan(account: account, appId: appId, start: .reuse, sourceRevisionId: revisionId, baseVersionId: "version-1", targetVersion: target, releaseType: "MANUAL", earliestReleaseDate: nil, expected: "null")
    }
    private func apple() -> SyntheticApple {
        let apple = SyntheticApple()
        apple.lock.withLock {
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
    /// The Apple area a synthetic request belongs to.
    private func area(_ path: String) -> String {
        if path == "/v1/apps/1000000001/appStoreVersions" { return "versions" }
        if path == "/v1/appStoreVersions/version-1/appStoreVersionLocalizations" { return "version-languages" }
        if path.hasPrefix("/v1/appStoreVersionLocalizations/") || path.hasPrefix("/v1/appScreenshotSets/") || path.hasPrefix("/v1/appPreviewSets/") || path == "/v1/appAssetLibraryRefData" { return "media" }
        if path == "/v1/apps/1000000001/appInfos" { return "app-infos" }
        if path.hasSuffix("/appInfoLocalizations") { return "app-info-text" }
        if path == "/v1/apps/1000000001" || path == "/v1/appInfos/info-1" { return "categories" }
        if path.hasSuffix("/ageRatingDeclaration") { return "age-rating" }
        if path.hasSuffix("/accessibilityDeclarations") { return "accessibility" }
        if path.hasSuffix("/appAvailabilityV2") || path.hasPrefix("/v2/appAvailabilities/") { return "availability" }
        if path.hasSuffix("/appStoreReviewDetail") || path.hasPrefix("/v1/appStoreReviewDetails/") { return "review" }
        if path.hasSuffix("/build") || path.hasPrefix("/v1/builds") || path.hasSuffix("/appEncryptionDeclarations") { return "build" }
        return "other " + path
    }
    private func state(_ snapshot: ReleaseReadinessSnapshot, _ id: String) throws -> ReleaseReadiness.State { try #require(snapshot.steps.first { $0.id == id }?.state) }

    @Test func openingEachStepRequestsOnlyItsOwnAppleReads() async throws {
        let expected: [String: Set<String>] = [
            "plan": ["versions"], "release": ["versions"], "listing": ["versions", "version-languages", "media"],
            "send": ["versions", "version-languages", "app-infos", "app-info-text"], "build": ["versions", "build"], "review-information": ["versions", "review"],
            "submit": ["versions", "app-infos", "categories", "age-rating", "accessibility", "availability"],
        ]
        #expect(Set(expected.keys) == Set(ReleaseWizard.phaseIds))
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), plan = try await plan(session, account: account)
        // What each step shows; every other Apple check stays Unknown until it is read.
        let shown: [String: [String]] = [
            "plan": ["version", "copyright", "submission"], "release": ["version", "release"], "listing": ["media:en-US"], "send": ["apple-text:en-US", "apple-info:en-US"],
            "build": ["build", "export-compliance"], "review-information": ["review-info"], "submit": ["app-configuration", "age-rating", "accessibility", "territories"],
        ]
        let apple = ["media:en-US", "apple-text:en-US", "apple-info:en-US", "build", "export-compliance", "review-info", "app-configuration", "age-rating", "accessibility", "territories"]
        for phase in ReleaseWizard.phaseIds {
            let synthetic = self.apple(), host = "readiness-parts-\(phase).appstoreconnect.test"
            StubProtocol.handle(host) { response($0, apple: synthetic) }
            let value = try await session.releaseReadiness(account: account, appId: appId, revisionId: revisionId, planToken: plan.token,
                                                           client: PublishingTests().client(account, host: host), parts: ReleaseWizard.reads(phase))
            let areas = Set(StubProtocol.requests(host).map { area($0.url!.path) })
            #expect(areas == expected[phase], "\(phase) requested \(areas.sorted())")
            #expect(value.parts == ReleaseWizard.reads(phase) && value.targetVersionId == "version-1")
            for id in shown[phase]! { #expect(try state(value, id) != .unknown, "\(phase) did not verify \(id)") }
            for id in apple where !shown[phase]!.contains(id) { #expect(try state(value, id) == .unknown, "\(phase) showed unread \(id)") }
            #expect(try state(value, "local:en-US") == .blocked)
            #expect(synthetic.lock.withLock { synthetic.writes.isEmpty })
        }
    }
    @Test func partsMergeIntoTheEarlierStatusOnlyForTheSameTargetAndMaterial() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), plan = try await plan(session, account: account), synthetic = apple(), host = "readiness-parts-merge.appstoreconnect.test"
        StubProtocol.handle(host) { response($0, apple: synthetic) }
        let client = try PublishingTests().client(account, host: host)
        func read(_ parts: ReleaseReadiness.Parts) async throws -> ReleaseReadinessSnapshot {
            try await session.releaseReadiness(account: account, appId: appId, revisionId: revisionId, planToken: plan.token, client: client, parts: parts)
        }
        let full = try await read(.all)
        var merged = try await read(ReleaseWizard.reads("build"))
        merged = try await read(ReleaseWizard.reads("submit")).merging(merged)
        #expect(merged.parts == ReleaseWizard.reads("build").union(ReleaseWizard.reads("submit")))
        for id in ["build", "export-compliance", "territories"] { #expect(try state(merged, id) == .ready) }
        #expect(try state(merged, "accessibility") == .review)
        #expect(try state(merged, "review-info") == .unknown && state(merged, "media:en-US") == .unknown)
        merged = try await read(ReleaseWizard.reads("listing")).merging(merged)
        merged = try await read(ReleaseWizard.reads("send")).merging(merged)
        merged = try await read(ReleaseWizard.reads("review-information")).merging(merged)
        #expect(merged.parts == .all)
        #expect(merged.steps.map(\.json) == full.steps.map(\.json) && merged.targetVersionId == full.targetVersionId && merged.targetState == full.targetState)
        // A remembered status keeps its observations for a later partial read.
        let saved = try ReleaseReadinessSnapshot.saved(merged.json(checkedAt: Date()), accountId: account.id, appId: appId, planToken: plan.token).snapshot
        #expect(saved.parts == .all)
        let resumed = try await read([.accessibility]).merging(saved)
        #expect(resumed.steps.map(\.json) == full.steps.map(\.json))
        // Version-scoped parts never carry to another target version; app-level parts do.
        synthetic.lock.withLock { var version = synthetic.versions[0]["attributes"] as! [String: Any]; version["versionString"] = "3.0"; synthetic.versions[0]["attributes"] = version }
        let moved = try await read([.versions]).merging(full)
        #expect(moved.targetVersionId == nil)
        for id in ["build", "review-info", "apple-text:en-US", "media:en-US"] { #expect(try state(moved, id) == .unknown) }
        #expect(try state(moved, "territories") == .ready && state(moved, "accessibility") == .review)
        #expect(synthetic.lock.withLock { synthetic.writes.isEmpty })
    }
    @Test func savedMediaStatusesDoNotCarryToChangedMaterial() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), plan = try await plan(session, account: account), synthetic = apple(), host = "readiness-parts-material.appstoreconnect.test"
        StubProtocol.handle(host) { response($0, apple: synthetic) }
        let client = try PublishingTests().client(account, host: host)
        let earlier = try await session.releaseReadiness(account: account, appId: appId, revisionId: revisionId, planToken: plan.token, client: client, parts: .all)
        let text = try await session.textDraft(accountId: account.id, appId: appId, revisionId: revisionId, localizationId: "version-locale-1", scope: .version)
        _ = try await session.saveTextDraft(accountId: account.id, appId: appId, revisionId: revisionId, localizationId: "version-locale-1", scope: .version, fields: ["description": "Synthetic later save"], fingerprint: text.fingerprint)
        let later = try await session.releaseReadiness(account: account, appId: appId, revisionId: revisionId, planToken: plan.token, client: client, parts: [.versions]).merging(earlier)
        #expect(later.materialSignature != earlier.materialSignature)
        #expect(try state(earlier, "media:en-US") != .unknown && state(later, "media:en-US") == .unknown)
        #expect(try state(later, "build") == .ready && later.parts == ReleaseReadiness.Parts.all.subtracting(.media))
    }
    @Test func theAttachedBuildIsConfirmedByTheAppFilteredPageWithoutAnOwnerRead() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), plan = try await plan(session, account: account), synthetic = apple(), host = "readiness-parts-owner.appstoreconnect.test"
        StubProtocol.handle(host) { request in ViewReadPlanTests.linkingOnlyWhenIncluded(request, response(request, apple: synthetic)) }
        let value = try await session.releaseReadiness(account: account, appId: appId, revisionId: revisionId, planToken: plan.token, client: PublishingTests().client(account, host: host), parts: ReleaseWizard.reads("build"))
        #expect(try state(value, "build") == .ready && state(value, "export-compliance") == .ready)
        #expect(!StubProtocol.requests(host).contains { $0.url!.path.hasSuffix("/relationships/app") })
    }
    @MainActor @Test func theOpenStepIsReadFirstAndTheRestFillsInBoundedBatches() async throws {
        let plan = try #require(ReleasePlan(.object([("accountId", .string("synthetic-account")), ("appId", .string("1000000001")),
            ("sourceRevisionId", .string(revisionId)), ("baseVersionId", .string("synthetic-base")), ("platform", .string("IOS")),
            ("targetVersion", .string("2.0")), ("releaseType", .string("MANUAL")), ("updatedAt", .string("2026-01-01T00:00:00.000Z"))])))
        let owner = ReleasePlanEditor(accountId: plan.accountId, appId: plan.appId, initial: .init(date: Date(timeIntervalSince1970: 2_000_000_000)),
                                      read: { plan }, save: { _, _ in throw Failure.synthetic }, remove: { _ in throw Failure.synthetic })
        await owner.load()
        let value = try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/release-readiness.json")))
        guard case .array(let cases)? = value["cases"], let input = cases.first?["input"] else { throw Failure.synthetic }
        let scope = try RecoveryGuidance.Scope(accountId: plan.accountId, appId: plan.appId), steps = try ReleaseReadiness.steps(input, scope: scope)
        var requested: [ReleaseReadiness.Parts] = [], running = 0, widest = 0, remembered = 0
        let model = ReleaseReadinessEditor(planEditor: owner, readParts: { _, parts in
            requested.append(parts); running += 1; widest = max(widest, running); defer { running -= 1 }
            for _ in 0..<5 { await Task.yield() }
            return .init(scope: scope, plan: plan, steps: steps, materialSignature: "synthetic-saved-material", targetVersionId: "synthetic-version", targetState: nil, parts: parts)
        }, remember: { _, _ in remembered += 1 })
        model.focus = ReleaseWizard.reads("review-information")
        #expect(await model.refresh())
        #expect(requested == [ReleaseWizard.reads("review-information")] && model.filling && remembered == 0)
        let deadline = ContinuousClock.now + .seconds(5)
        while model.filling { guard ContinuousClock.now < deadline else { throw Failure.synthetic }; try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.checkedParts == .all && remembered == 1 && widest <= 2)
        let background = Array(requested.dropFirst())
        #expect(background.allSatisfy { $0.isDisjoint(with: ReleaseWizard.reads("review-information")) })
        #expect(background.reduce(ReleaseReadiness.Parts()) { $0.union($1) } == ReleaseReadiness.Parts.all.subtracting(ReleaseWizard.reads("review-information")))
        #expect(background.first == [.accessibility] && background.last == [.media])
    }
}
