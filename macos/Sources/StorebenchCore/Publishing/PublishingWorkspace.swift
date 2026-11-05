import Foundation

/// Live Apple choices are kept separate from the saved material used for a metadata review.
public enum PublishingWorkspace {
    public struct Version: Sendable, Identifiable, Equatable, Codable {
        public let id, name, platform, number, state, releaseType, copyright: String
        public init(id: String, platform: String, number: String, state: String, releaseType: String = "", copyright: String = "") {
            self.id = id; self.platform = platform; self.number = number; self.state = state; self.releaseType = releaseType; self.copyright = copyright; name = "\(Releases.platformName(platform)) \(number)"
        }
    }
    public struct Choice: Sendable, Identifiable, Equatable {
        public let id, name: String
        public init(id: String, name: String) { self.id = id; self.name = name }
    }
    public struct Source: Sendable, Identifiable {
        public let id, name: String
        public let versions: [Choice]
        public init(id: String, name: String, versions: [Choice]) { self.id = id; self.name = name; self.versions = versions }
    }
    public struct Build: Sendable, Identifiable, Equatable {
        public let id, name, platform, number: String
        public init(id: String, name: String, platform: String, number: String) { self.id = id; self.name = name; self.platform = platform; self.number = number }
    }
    public struct Snapshot: Sendable {
        public let accountId, appId: String
        public let versions: [Version]?, sources: [Source]?, builds: [Build]?, profiles: [Choice]?
        public let defaultProfile: String?
        public let plan: ReleasePlan?
        public let issues: [String]
        public init(accountId: String, appId: String, versions: [Version]?, sources: [Source]?, builds: [Build]?, profiles: [Choice]?, defaultProfile: String?, plan: ReleasePlan?, issues: [String] = []) {
            self.accountId = accountId; self.appId = appId; self.versions = versions; self.sources = sources; self.builds = builds; self.profiles = profiles; self.defaultProfile = defaultProfile; self.plan = plan; self.issues = issues
        }
    }
    public enum Action: String, CaseIterable, Identifiable, Sendable {
        case release = "Version setup", metadata = "Languages & media", copyright = "Copyright", pricing = "Pricing", submit = "Add for Review", cancel = "Cancel Submission", releaseVersion = "Release this version", analytics = "Analytics reports"
        public var id: String { rawValue }
        public var scope: PublishRequest.Scope {
            switch self { case .release: .release; case .metadata: .metadata; case .copyright: .versionCopyright; case .pricing: .pricing; case .submit: .submit; case .cancel: .cancelSubmission; case .releaseVersion: .releaseVersion; case .analytics: .analyticsOngoing }
        }
        public init?(scope: PublishRequest.Scope) {
            guard let value = Self.allCases.first(where: { $0.scope == scope || $0 == .analytics && scope == .analyticsSnapshot }) else { return nil }; self = value
        }
    }
    static func equal(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }
    public static func initialVersion(_ versions: [Version], scope: PublishRequest.Scope, requested: String? = nil, planPlatform: String? = nil, planNumber: String? = nil, reviewVersion: String? = nil) -> String {
        if let reviewVersion, !reviewVersion.isEmpty, [.versionCopyright, .reviewInfo, .submit, .cancelSubmission, .releaseVersion].contains(scope) { return reviewVersion }
        if let requested, versions.contains(where: { $0.id == requested }) { return requested }
        if let planPlatform, let planNumber, let version = versions.first(where: { equal($0.platform, planPlatform) && equal($0.number, planNumber) }) { return version.id }
        return versions.first { item in
            if scope == .releaseVersion { return item.state == "PENDING_DEVELOPER_RELEASE" && item.releaseType == "MANUAL" }
            if scope == .cancelSubmission { return ["WAITING_FOR_REVIEW", "IN_REVIEW", "UNRESOLVED_ISSUES"].contains(item.state) }
            return Apple.editable.contains(item.state)
        }?.id ?? versions.first?.id ?? ""
    }
    public static func matchingBuilds(_ builds: [Build], version: Version?) -> [Build] {
        guard let version else { return [] }; return builds.filter { equal($0.platform, version.platform) && equal($0.number, version.number) }
    }
    public struct Editor: Sendable {
        public let accountId, appId: String
        public private(set) var snapshot: Snapshot?
        public private(set) var action: Action = .metadata
        public private(set) var versionId = "", revisionId = "", sourceVersionId = "", buildId = "", profileId = "", targetMode = "apple-version"
        public var copyright = ""
        public var analyticsSnapshot = false
        /// Set for the Asset Library upload of a Languages & media review; see `PublishRequest.mediaStage`.
        public var mediaStage: String?
        private var copyrightBaseline = ""
        public init(accountId: String, appId: String) { self.accountId = accountId; self.appId = appId }
        public var dirty: Bool { action == .copyright && !PublishingWorkspace.equal(copyright, copyrightBaseline) }
        public func matchesCopyright(_ request: PublishRequest?) -> Bool {
            guard let request, request.scope == .versionCopyright else { return true }
            return action == .copyright && request.accountId == accountId && request.appId == appId && request.versionId == versionId
                && request.copyright.map { PublishingWorkspace.equal($0, copyright) } == true
        }
        public var version: Version? { snapshot?.versions?.first { $0.id == versionId } }
        public var source: Source? { snapshot?.sources?.first { $0.id == revisionId } }
        public var builds: [Build] { matchingBuilds(snapshot?.builds ?? [], version: version) }
        public var planSelected: Bool { snapshot?.plan.map { $0.sourceRevisionId == revisionId && $0.baseVersionId == sourceVersionId } ?? false }
        public var destination: Version? {
            guard let snapshot else { return nil }
            if targetMode == "release-plan", planSelected, let plan = snapshot.plan { return snapshot.versions?.first { PublishingWorkspace.equal($0.platform, plan.platform) && PublishingWorkspace.equal($0.number, plan.targetVersion) } }
            return snapshot.versions?.first { $0.id == sourceVersionId }
        }
        public mutating func receive(_ value: Snapshot) throws {
            guard value.accountId == accountId, value.appId == appId else { throw PublishFailure.invalid("Publishing choices belong to another app. Your selections remain here.") }
            snapshot = value
            if versionId.isEmpty, value.versions != nil {
                versionId = initialVersion(value.versions ?? [], scope: action.scope, planPlatform: value.plan?.platform, planNumber: value.plan?.targetVersion)
                copyright = version?.copyright ?? ""; copyrightBaseline = copyright
            }
            if revisionId.isEmpty { revisionId = value.sources?.first?.id ?? ""; sourceVersionId = source?.versions.first?.id ?? "" }
            if profileId.isEmpty { profileId = value.defaultProfile ?? value.profiles?.first?.id ?? "" }
        }
        public mutating func chooseAction(_ value: Action) {
            guard action != value else { return }; action = value
            versionId = initialVersion(snapshot?.versions ?? [], scope: value.scope, planPlatform: snapshot?.plan?.platform, planNumber: snapshot?.plan?.targetVersion)
            copyright = version?.copyright ?? ""; copyrightBaseline = copyright; buildId = ""
        }
        public mutating func chooseVersion(_ id: String) { versionId = id; copyright = version?.copyright ?? ""; copyrightBaseline = copyright; buildId = "" }
        public mutating func chooseSource(_ id: String) { revisionId = id; sourceVersionId = source?.versions.first?.id ?? ""; targetMode = "apple-version" }
        public mutating func chooseSourceVersion(_ id: String) { sourceVersionId = id; targetMode = "apple-version" }
        public mutating func chooseTarget(_ mode: String) { targetMode = mode }
        public mutating func chooseBuild(_ id: String) { buildId = id }
        public mutating func chooseProfile(_ id: String) { profileId = id }
        public mutating func choosePlannedMaterial() throws {
            guard let plan = snapshot?.plan, let source = snapshot?.sources?.first(where: { $0.id == plan.sourceRevisionId }), source.versions.contains(where: { $0.id == plan.baseVersionId }) else { throw PublishFailure.invalid("Read the version plan and its saved source before reviewing its text and media.") }
            chooseAction(.metadata); revisionId = source.id; sourceVersionId = plan.baseVersionId; targetMode = "release-plan"
        }
        public mutating func restore(_ request: PublishRequest) throws {
            guard request.accountId == accountId, request.appId == appId, let action = Action(scope: request.scope) else { throw PublishFailure.invalid("Open this review in its app section to edit its selections.") }
            self.action = action
            if action == .metadata { revisionId = request.revisionId ?? ""; sourceVersionId = request.versionId ?? ""; targetMode = request.targetMode ?? "apple-version"; mediaStage = request.mediaStage }
            else { versionId = request.versionId ?? versionId }
            buildId = request.buildId ?? ""; profileId = request.profileId ?? profileId; analyticsSnapshot = request.scope == .analyticsSnapshot
            copyright = request.copyright ?? version?.copyright ?? ""; copyrightBaseline = copyright
        }
        public func request() throws -> PublishRequest {
            guard let snapshot else { throw PublishFailure.invalid("Read current publishing choices before preparing a review.") }
            let scope = action == .analytics && analyticsSnapshot ? PublishRequest.Scope.analyticsSnapshot : action.scope
            var request = PublishRequest(accountId: accountId, appId: appId, scope: scope)
            switch action {
            case .release: guard snapshot.versions != nil, snapshot.plan != nil else { throw PublishFailure.invalid("Read Apple's version status and save a version plan before preparing its review.") }
            case .metadata:
                guard snapshot.versions != nil, let source, source.versions.contains(where: { $0.id == sourceVersionId }), ["apple-version", "release-plan"].contains(targetMode),
                      targetMode != "release-plan" || planSelected, destination != nil else { throw PublishFailure.invalid("Choose saved source material and its existing Apple destination. Create a planned version first if it is missing.") }
                request.revisionId = revisionId; request.versionId = sourceVersionId; request.targetMode = targetMode; request.mediaStage = mediaStage
            case .pricing:
                guard snapshot.profiles?.contains(where: { $0.id == profileId }) == true else { throw PublishFailure.invalid("Read and choose an existing saved pricing profile.") }; request.profileId = profileId
            case .analytics: break
            default:
                guard snapshot.versions != nil, version != nil else { throw PublishFailure.invalid("Read and choose a current Apple version.") }; request.versionId = versionId
                if action == .copyright { request.copyright = copyright }
                if action == .submit {
                    guard snapshot.builds != nil, buildId.isEmpty || builds.contains(where: { $0.id == buildId }) else { throw PublishFailure.invalid("Read the processed builds and choose one matching this Apple version.") }
                    request.buildId = buildId.isEmpty ? nil : buildId
                }
            }
            return try request.validated()
        }
        public var canPrepare: Bool { (try? request()) != nil }
    }
}

extension WorkspaceSession {
    public func publishingWorkspace(account: Account, appId: String, includeBuilds: Bool = false, client: AppStoreConnectClient) async throws -> PublishingWorkspace.Snapshot {
        try requirePublishingAccount(account, appId: appId, client: client)
        var versions: [PublishingWorkspace.Version]?, sources: [PublishingWorkspace.Source]?, builds: [PublishingWorkspace.Build]?, profiles: [PublishingWorkspace.Choice]?, defaultProfile: String?, plan: ReleasePlan?, issues: [String] = []
        do {
            let saved = try revisions(accountId: account.id, appId: appId)
            plan = try releasePlan(accountId: account.id, appId: appId)
            sources = saved.filter { !$0.isLocalDraft || $0.id == plan?.sourceRevisionId }.map { .init(id: $0.id, name: "\($0.isLocalDraft ? "Local draft" : "Apple import") · \($0.importedAt.prefix(16).replacingOccurrences(of: "T", with: " ")) UTC", versions: $0.versions.map { .init(id: $0.id, name: $0.title) }) }
        } catch { issues.append("Saved source material or the release plan could not be read. Retry before preparing those changes.") }
        do { let saved = try pricingProfiles(); defaultProfile = saved.defaultId; profiles = saved.profiles.map { .init(id: $0.id, name: $0.name) } }
        catch { issues.append("Saved pricing profiles could not be read. Retry before preparing prices.") }
        do {
            versions = try await currentAppVersions(account: account, appId: appId, client: client)
        } catch { versions = nil; issues.append("Current Apple versions could not be read. Their status remains unknown; retry before preparing version changes.") }
        if includeBuilds {
            do {
                let page = try await client.listWithIncluded("/v1/builds?filter%5Bapp%5D=\(appId)&filter%5BprocessingState%5D=VALID&include=app%2CpreReleaseVersion&limit=200")
                let owned = try await scopedOwners(page.data, type: "builds", appId: appId, list: client.list)
                let prereleases = page.included.filter { $0.type == "preReleaseVersions" }
                guard Set(prereleases.map(\.id)).count == prereleases.count else { throw PublishFailure.invalid("Apple returned ambiguous build versions.") }
                builds = try owned.filter { $0.attributes?["processingState"]?.string == "VALID" && $0.attributes?["buildAudienceType"]?.string == "APP_STORE_ELIGIBLE" }.compactMap { item in
                    guard item.id.range(of: "^[A-Za-z0-9_-]{1,256}$", options: .regularExpression) != nil else { throw PublishFailure.invalid("Apple returned an invalid build choice.") }
                    guard let owner = Apple.owner(item, "preReleaseVersion"), owner.type == "preReleaseVersions", let prior = prereleases.first(where: { $0.id == owner.id }),
                          let platform = prior.attributes?["platform"]?.string, let number = prior.attributes?["version"]?.string else { return nil }
                    return .init(id: item.id, name: "Build \(item.attributes?["version"]?.string ?? item.id) · \(Releases.platformName(platform)) \(number)", platform: platform, number: number)
                }
            } catch { builds = nil; issues.append("Processed App Store builds could not be read. Retry before preparing an App Review submission.") }
        }
        try Task.checkCancellation()
        return .init(accountId: account.id, appId: appId, versions: versions, sources: sources, builds: builds, profiles: profiles, defaultProfile: defaultProfile, plan: plan, issues: issues)
    }
}
