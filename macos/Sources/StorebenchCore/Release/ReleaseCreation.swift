import Foundation

/// The latest version on a platform controls whether Apple can create the next one.
public enum ReleaseCreation {
    public struct Blocker: Sendable, Equatable {
        public let version: PublishingWorkspace.Version
        public let detail: String
    }
    public static func blocker(platform: String, number: String, versions: [PublishingWorkspace.Version]) -> Blocker? {
        let samePlatform = versions.filter { $0.platform == platform }
        guard !samePlatform.contains(where: { $0.number == number }),
              let latest = samePlatform.max(by: { $0.number.compare($1.number, options: .numeric) == .orderedAscending }) else { return nil }
        let released: Set<String> = ["READY_FOR_DISTRIBUTION", "READY_FOR_SALE", "REPLACED_WITH_NEW_VERSION"]
        if latest.state.isEmpty {
            return .init(version: latest, detail: "The current Apple state of \(latest.name) could not be confirmed. Refresh Status before creating \(number). Your local draft is kept.")
        }
        if !released.contains(latest.state) {
            let state = AppStoreNames.state(latest.state)
            return .init(version: latest, detail: "App Store Connect has \(latest.name) · \(state). Finish or resolve that version before creating \(number). Your local draft is kept.")
        }
        if latest.number.compare(number, options: .numeric) != .orderedAscending {
            return .init(version: latest, detail: "Choose a version number higher than \(latest.number), the latest version at Apple. Your local draft is kept.")
        }
        return nil
    }
    public static func versions(_ observation: JSONText?) -> [PublishingWorkspace.Version] {
        WorkspaceSession.items(observation).compactMap { item in
            guard let id = item["id"]?.text, let platform = item["platform"]?.text, let number = item["number"]?.text else { return nil }
            return .init(id: id, platform: platform, number: number, state: item["state"]?.text ?? "")
        }
    }
    public static func blocker(_ snapshot: ReleaseReadinessSnapshot) -> Blocker? {
        blocker(platform: snapshot.plan.platform, number: snapshot.plan.targetVersion, versions: versions(snapshot.observations["appleVersions"]))
    }
    /// Opens the selected platform's current version, rather than the general publishing page.
    public static func versionURL(appId: String, platform: String) -> URL? {
        let paths = ["IOS": "ios", "MAC_OS": "macos", "TV_OS": "tvos", "VISION_OS": "visionos"]
        guard !appId.isEmpty, appId.utf8.allSatisfy({ (48...57).contains($0) }), let path = paths[platform] else { return nil }
        return URL(string: "https://appstoreconnect.apple.com/apps/\(appId)/distribution/\(path)/version/inflight")
    }
}
