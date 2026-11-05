import Foundation

/// Reads are scoped through app-owned collections, including every page, before a resource can be selected.
struct LibraryReader: Sendable {
    let appId: String
    let get: @Sendable (String) async throws -> [AppStoreConnectClient.Resource]
    let list: @Sendable (String) async throws -> [AppStoreConnectClient.Resource]
    func children(_ path: String, type: String, parent: (String, String, String)? = nil) async throws -> [AppStoreConnectClient.Resource] {
        let result = try await list(path)
        guard Set(result.map(\.id)).count == result.count, result.allSatisfy({ item in
            guard item.type == type, AssetLibrary.validID(item.id) else { return false }
            guard let parent else { return true }
            return item.relationships?[parent.0] == nil || Apple.owned(item, parent.0, parent.1, parent.2)
        }) else { throw AssetLibrary.failure("Apple returned library material outside the selected app.") }
        return result
    }
    func library() async throws -> String {
        let found = try await get("/v1/apps/\(appId)/assetLibrary")
        guard found.count == 1, found[0].type == "appAssetLibraries", AssetLibrary.validID(found[0].id), found[0].relationships?["app"] == nil || Apple.owned(found[0], "app", "apps", appId) else { throw AssetLibrary.failure("Asset Library is unavailable for this app or API role.") }
        return found[0].id
    }
    func assets(libraryId: String, kind: AssetLibrary.Kind) async throws -> [AssetLibrary.Asset] {
        let items = try await children("/v1/appAssetLibraries/\(libraryId)/\(kind == .image ? "images" : "videos")?limit=200", type: kind.resource, parent: ("assetLibrary", "appAssetLibraries", libraryId))
        return try items.map { try AssetLibrary.Asset($0, kind: kind) }
    }
    func asset(_ id: String, kind: AssetLibrary.Kind) async throws -> AssetLibrary.Asset {
        let library = try await library()
        guard try await assets(libraryId: library, kind: kind).contains(where: { $0.id == id }) else { throw AssetLibrary.failure("The library asset no longer belongs to this app.") }
        let resources = try await get("/v1/\(kind.resource)/\(id)")
        guard resources.count == 1, resources[0].id == id, resources[0].relationships?["assetLibrary"] == nil || Apple.owned(resources[0], "assetLibrary", "appAssetLibraries", library) else { throw AssetLibrary.failure("The library asset changed ownership.") }
        return try AssetLibrary.Asset(resources[0], kind: kind)
    }
    func targets(_ surface: AssetLibrary.Surface) async throws -> [AssetLibrary.Target] {
        var result: [AssetLibrary.Target] = []
        func append(_ locales: [AppStoreConnectClient.Resource], parent: AppStoreConnectClient.Resource, prefix: String, state: String, platform: String) {
            for locale in locales { result.append(.init(id: locale.id, name: "\(prefix) · \(locale.attributes?["locale"]?.string ?? locale.id)", platform: platform, state: state, surface: surface)) }
        }
        switch surface {
        case .versions:
            for version in try await children("/v1/apps/\(appId)/appStoreVersions?include=app&limit=200", type: "appStoreVersions", parent: ("app", "apps", appId)) {
                let locales = try await children("/v1/appStoreVersions/\(version.id)/appStoreVersionLocalizations?limit=200", type: surface.resource, parent: ("appStoreVersion", "appStoreVersions", version.id))
                append(locales, parent: version, prefix: "\(Releases.platformName(version.attributes?["platform"]?.string ?? "")) \(version.attributes?["versionString"]?.string ?? "")", state: Apple.state(version), platform: version.attributes?["platform"]?.string ?? "")
            }
        case .customPages:
            for page in try await children("/v1/apps/\(appId)/appCustomProductPages?limit=200", type: "appCustomProductPages", parent: ("app", "apps", appId)) {
                for version in try await children("/v1/appCustomProductPages/\(page.id)/appCustomProductPageVersions?limit=200", type: "appCustomProductPageVersions", parent: ("appCustomProductPage", "appCustomProductPages", page.id)) {
                    let locales = try await children("/v1/appCustomProductPageVersions/\(version.id)/appCustomProductPageLocalizations?limit=200", type: surface.resource, parent: ("appCustomProductPageVersion", "appCustomProductPageVersions", version.id))
                    append(locales, parent: version, prefix: page.attributes?["name"]?.string ?? page.id, state: Apple.state(version), platform: version.attributes?["platform"]?.string ?? "")
                }
            }
        case .events:
            for event in try await children("/v1/apps/\(appId)/appEvents?limit=200", type: "appEvents", parent: ("app", "apps", appId)) {
                let locales = try await children("/v1/appEvents/\(event.id)/localizations?limit=200", type: surface.resource, parent: ("appEvent", "appEvents", event.id))
                append(locales, parent: event, prefix: event.attributes?["referenceName"]?.string ?? event.id, state: event.attributes?["eventState"]?.string ?? "", platform: event.attributes?["platform"]?.string ?? "")
            }
        case .experiments:
            for experiment in try await children("/v1/apps/\(appId)/appStoreVersionExperimentsV2?limit=200", type: "appStoreVersionExperiments", parent: ("app", "apps", appId)) {
                for treatment in try await children("/v2/appStoreVersionExperiments/\(experiment.id)/appStoreVersionExperimentTreatments?limit=200", type: "appStoreVersionExperimentTreatments", parent: ("appStoreVersionExperimentV2", "appStoreVersionExperiments", experiment.id)) {
                    let locales = try await children("/v1/appStoreVersionExperimentTreatments/\(treatment.id)/appStoreVersionExperimentTreatmentLocalizations?limit=200", type: surface.resource, parent: ("appStoreVersionExperimentTreatment", "appStoreVersionExperimentTreatments", treatment.id))
                    append(locales, parent: experiment, prefix: "\(experiment.attributes?["name"]?.string ?? experiment.id) · \(treatment.attributes?["name"]?.string ?? treatment.id)", state: Apple.state(experiment), platform: experiment.attributes?["platform"]?.string ?? "")
                }
            }
        }
        guard Set(result.map(\.id)).count == result.count else { throw AssetLibrary.failure("Apple returned duplicate placement destinations.") }
        return result
    }
    func target(_ id: String, surface: AssetLibrary.Surface) async throws -> AssetLibrary.Target {
        guard let target = try await targets(surface).first(where: { $0.id == id }) else { throw AssetLibrary.failure("The placement destination no longer belongs to this app.") }; return target
    }
    func placements(target: AssetLibrary.Target) async throws -> [AssetLibrary.Placement] {
        try await children("/v1/\(target.surface.resource)/\(target.id)/placements?sort=placementGroupPosition&include=image,video&limit=200", type: "appAssetLibraryPlacements", parent: (target.surface.relationship, target.surface.resource, target.id)).map(AssetLibrary.Placement.init)
    }
    func uses(_ asset: AssetLibrary.Asset) async throws -> [AppStoreConnectClient.Resource] {
        try await children("/v1/\(asset.kind.resource)/\(asset.id)/placements?limit=200", type: "appAssetLibraryPlacements", parent: (asset.kind.rawValue, asset.kind.resource, asset.id))
    }
    func catalog() async throws -> AssetLibrary.Catalog { try await AssetLibrary.Catalog(list("/v1/appAssetLibraryRefData")) }
}

extension WorkspaceSession {
    func libraryReader(appId: String, client: AppStoreConnectClient) -> LibraryReader { LibraryReader(appId: appId, get: client.get, list: client.list) }
    public func assetLibrary(account: Account, appId: String, client: AppStoreConnectClient) async throws -> AssetLibrary.Snapshot {
        try requirePublishingAccount(account, appId: appId, client: client)
        let reader = libraryReader(appId: appId, client: client), library = try await reader.library()
        let images = try await reader.assets(libraryId: library, kind: .image), videos = try await reader.assets(libraryId: library, kind: .video), catalog = try await reader.catalog()
        guard Set((images + videos).map(\.id)).count == images.count + videos.count else { throw AssetLibrary.failure("Apple returned ambiguous library asset identities.") }
        try requirePublishingAccount(account, appId: appId, client: client)
        return .init(libraryId: library, assets: images + videos, catalog: catalog)
    }
    public func assetLibraryTargets(account: Account, appId: String, surface: AssetLibrary.Surface, client: AppStoreConnectClient) async throws -> [AssetLibrary.Target] {
        try requirePublishingAccount(account, appId: appId, client: client)
        let result = try await libraryReader(appId: appId, client: client).targets(surface)
        try requirePublishingAccount(account, appId: appId, client: client); return result
    }
    public func assetLibraryPlacements(account: Account, appId: String, target: AssetLibrary.Target, client: AppStoreConnectClient) async throws -> [AssetLibrary.Placement] {
        try requirePublishingAccount(account, appId: appId, client: client)
        let reader = libraryReader(appId: appId, client: client), confirmed = try await reader.target(target.id, surface: target.surface), result = try await reader.placements(target: confirmed)
        try requirePublishingAccount(account, appId: appId, client: client); return result
    }
    public func assetLibraryUses(account: Account, appId: String, asset: AssetLibrary.Asset, client: AppStoreConnectClient) async throws -> [AssetLibrary.Placement] {
        try requirePublishingAccount(account, appId: appId, client: client)
        let reader = libraryReader(appId: appId, client: client), confirmed = try await reader.asset(asset.id, kind: asset.kind), resources = try await reader.uses(confirmed)
        try requirePublishingAccount(account, appId: appId, client: client); return try resources.map(AssetLibrary.Placement.init)
    }
    public func assetLibraryReviewChoices(account: Account, appId: String, platform: String, client: AppStoreConnectClient) async throws -> [PublishingWorkspace.Choice] {
        try requirePublishingAccount(account, appId: appId, client: client)
        let submissions = try await libraryReader(appId: appId, client: client).children("/v1/apps/\(appId)/reviewSubmissions?limit=200", type: "reviewSubmissions", parent: ("app", "apps", appId))
        try requirePublishingAccount(account, appId: appId, client: client)
        return submissions.filter { Apple.state($0) == "READY_FOR_REVIEW" && $0.attributes?["platform"]?.string == platform }.map { .init(id: $0.id, name: "Draft \($0.id)") }
    }
}
