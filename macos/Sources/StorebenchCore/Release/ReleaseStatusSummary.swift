import Foundation

/// One planned version's release status at a glance, outside the step guide: what the version as a whole still needs and, per
/// language, its local material and what App Store Connect shows. It is built from the last confirmed status, so it is only as
/// recent as `checkedAt`; Unknown stays Unknown and nothing here starts an Apple change.
public struct ReleaseStatusSummary: Sendable, Equatable {
    public struct Part: Sendable, Equatable, Identifiable {
        public let id, label, detail: String
        public let state: ReleaseReadiness.State
    }
    public struct Language: Sendable, Equatable, Identifiable {
        public let locale: String, parts: [Part]
        public var id: String { locale }
        /// The language's least finished part, which its row shows.
        public var state: ReleaseReadiness.State { ReleaseStatusSummary.worst(parts.map(\.state)) }
    }
    public let version: String, platform: String
    public let versionParts: [Part], languages: [Language]
    /// The first part that needs action, then the first that is unknown, needs a manual check or needs review; nil only when every part is verified or waiting.
    public let next: Part?
    public let checkedAt: Date

    /// The version-wide parts in the order the release runs through them.
    static let versionOrder = ["version", "app-configuration", "age-rating", "accessibility", "territories", "copyright", "review-info", "build", "export-compliance",
                               "submission", "release", "privacy", "tax"]
    static let languageParts: [(prefix: String, label: String)] = [("local:", "Text and Screenshots on This Mac"), ("editorial:", "Copied Wording"),
                                                                   ("apple-text:", "Version Text at Apple"), ("apple-info:", "App Information at Apple"),
                                                                   ("media:", "Screenshots at Apple")]

    public init(snapshot: ReleaseReadinessSnapshot, checkedAt: Date) {
        self.init(steps: snapshot.steps, version: snapshot.plan.targetVersion, platform: snapshot.plan.platform, checkedAt: checkedAt)
    }
    init(steps: [ReleaseReadiness.Step], version: String, platform: String, checkedAt: Date) {
        self.version = version; self.platform = platform; self.checkedAt = checkedAt
        let byId = Dictionary(steps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        versionParts = Self.versionOrder.compactMap { id in byId[id].map { Part(id: $0.id, label: $0.label, detail: $0.detail, state: $0.state) } }
        var locales: [String] = []
        for step in steps where step.id.hasPrefix("local:") {
            let code = String(step.id.dropFirst("local:".count))
            if !locales.contains(code) { locales.append(code) }
        }
        languages = locales.map { code in
            Language(locale: code, parts: Self.languageParts.compactMap { part in
                byId[part.prefix + code].map { Part(id: $0.id, label: part.label, detail: $0.detail, state: $0.state) }
            })
        }
        let ordered = versionParts + languages.flatMap(\.parts)
        next = [ReleaseReadiness.State.blocked, .unknown, .manual, .review].lazy.compactMap { state in ordered.first { $0.state == state } }.first
    }

    /// Needs action, then Unknown, Check manually, Review, Waiting for Apple and Verified.
    static func worst(_ states: [ReleaseReadiness.State]) -> ReleaseReadiness.State {
        let order: [ReleaseReadiness.State] = [.blocked, .unknown, .manual, .review, .waiting, .ready]
        return order.first { states.contains($0) } ?? .unknown
    }
}

extension WorkspaceSession {
    /// The summary of the app's saved release plan from its last confirmed status, or nil when there is no plan or no status yet.
    public func releaseStatusSummary(accountId: String, appId: String) -> ReleaseStatusSummary? {
        guard let plan = try? releasePlan(accountId: accountId, appId: appId),
              let saved = rememberedReleaseReadiness(accountId: accountId, appId: appId, planToken: plan.token) else { return nil }
        return ReleaseStatusSummary(snapshot: saved.snapshot, checkedAt: saved.checkedAt)
    }
}
