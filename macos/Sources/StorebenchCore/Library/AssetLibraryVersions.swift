import Foundation

/// Which App Store version was Ready for Distribution when an asset was last modified.
/// Only dated observations count: saved imports and Apple's current version list. A version is reported
/// only when the observations on both sides of the modification agree; anything that changed in between stays unknown.
public enum AssetLibraryVersions {
    public struct Version: Sendable, Equatable, Codable {
        public let platform, number, state: String
        public init(platform: String, number: String, state: String) { self.platform = platform; self.number = number; self.state = state }
    }
    public struct Observation: Sendable, Equatable, Codable {
        public let at: Date, versions: [Version]
        public init(at: Date, versions: [Version]) { self.at = at; self.versions = versions }
    }
    public struct Outcome: Sendable, Equatable {
        /// One short line per platform, such as "1.6 Ready for Distribution · 1.7 Pending Developer Release".
        public let summary: String
        /// How the answer was reached, naming the observations used.
        public let detail: String
        public let known: Bool
    }
    static let live: Set<String> = ["READY_FOR_DISTRIBUTION", "READY_FOR_SALE"]
    /// Approved by App Review but not yet on the App Store.
    static let approved: Set<String> = ["PENDING_DEVELOPER_RELEASE", "PENDING_APPLE_RELEASE", "PROCESSING_FOR_DISTRIBUTION", "PROCESSING_FOR_APP_STORE"]
    /// States a version reaches only after it was on the App Store.
    static let afterLive: Set<String> = ["REPLACED_WITH_NEW_VERSION", "REMOVED_FROM_SALE", "DEVELOPER_REMOVED_FROM_SALE"]

    /// Saved imports, oldest first. Local drafts and malformed dates are not observations.
    public static func observations(_ revisions: [Revision]) -> [Observation] {
        revisions.filter { !$0.isLocalDraft }.compactMap { revision in
            ISODateParser.date(revision.importedAt).map { at in
                Observation(at: at, versions: revision.versions.map { Version(platform: $0.platform, number: $0.number, state: $0.fields["appVersionState"]?.text ?? $0.fields["appStoreState"]?.text ?? "") })
            }
        }.sorted { $0.at < $1.at }
    }
    public static func observation(current: [PublishingWorkspace.Version], at: Date) -> Observation {
        Observation(at: at, versions: current.map { Version(platform: $0.platform, number: $0.number, state: $0.state) })
    }

    public static func outcome(modified: String?, observations: [Observation], timeZone: TimeZone = .current) -> Outcome {
        guard let modified, let at = ISODateParser.date(modified) else { return Outcome(summary: "Unknown", detail: "Apple did not return a modified date for this asset.", known: false) }
        let sorted = observations.sorted { $0.at < $1.at }
        guard let before = sorted.last(where: { $0.at <= at }) else {
            return Outcome(summary: "Unknown", detail: "No saved import or current version read is older than this change. Version history before " + (sorted.first.map { date($0.at, timeZone) } ?? "the first import") + " is not saved.", known: false)
        }
        guard let after = sorted.first(where: { $0.at >= at }) else {
            return Outcome(summary: "Unknown", detail: "The latest version history was read on \(date(before.at, timeZone)), before this change. Refresh Asset Library again to compare with Apple's current versions.", known: false)
        }
        let platforms = Array(Set((before.versions + after.versions).map(\.platform))).sorted()
        let span = before.at == after.at ? "on \(date(before.at, timeZone))" : "on \(date(before.at, timeZone)) and \(date(after.at, timeZone))"
        guard !platforms.isEmpty else { return Outcome(summary: "Unknown", detail: "No versions were saved \(span).", known: false) }
        var lines: [String] = [], details: [String] = [], known = true
        for platform in platforms {
            let prefix = platforms.count > 1 ? AppStoreNames.platform(platform) + " " : ""
            let earlier = before.versions.filter { $0.platform == platform }, later = after.versions.filter { $0.platform == platform }
            let earlierLive = Set(earlier.filter { live.contains($0.state) }.map(\.number)), laterLive = Set(later.filter { live.contains($0.state) }.map(\.number))
            var parts: [String] = []
            if !earlierLive.isEmpty && earlierLive == laterLive {
                parts += earlierLive.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { "\($0) Ready for Distribution" }
            } else if earlierLive.isEmpty && laterLive.isEmpty && !later.contains(where: { version in afterLive.contains(version.state) && !earlier.contains { $0.number == version.number && $0.state == version.state } }) {
                parts.append("No version Ready for Distribution")
            } else {
                known = false
                lines.append(prefix + "Unknown")
                details.append(prefix + "The version Ready for Distribution changed between the observations \(span) (\(list(earlierLive)) → \(list(laterLive))).")
                continue
            }
            var pendingUnknown: [String] = []
            for version in later where approved.contains(version.state) {
                if earlier.contains(where: { $0.number == version.number && $0.state == version.state }) { parts.append("\(version.number) \(AppStoreNames.state(version.state))") }
                else { pendingUnknown.append(version.number) }
            }
            for version in earlier where approved.contains(version.state) && !later.contains(where: { $0.number == version.number }) { pendingUnknown.append(version.number) }
            lines.append(prefix + parts.joined(separator: " · "))
            details.append(prefix + parts.joined(separator: " · ") + " in the observations \(span).")
            if !pendingUnknown.isEmpty {
                lines[lines.count - 1] += " · " + pendingUnknown.sorted().map { "\($0) approval unknown" }.joined(separator: " · ")
                details.append(prefix + "Whether " + pendingUnknown.sorted().joined(separator: ", ") + " was already approved at that time is unknown.")
            }
        }
        return Outcome(summary: lines.joined(separator: " · "), detail: (known ? "" : "Unknown parts are not guessed. ") + details.joined(separator: " "), known: known)
    }
    static func list(_ numbers: Set<String>) -> String { numbers.isEmpty ? "none" : numbers.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.joined(separator: ", ") }
    static func date(_ value: Date, _ timeZone: TimeZone) -> String { AppStoreNames.date(value, timeZone: timeZone) }
}
