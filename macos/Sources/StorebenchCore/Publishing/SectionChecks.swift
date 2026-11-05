import Foundation

/// What App Store Connect last showed for a section Apple can refuse a submission over and Storebench can read, such as
/// App Privacy or the app price. Kept on this Mac so Release shows it at once; every read of Apple replaces it.
public struct SectionCheck: Sendable, Equatable {
    /// The App Store Connect section a check belongs to.
    public typealias Area = AppleProblem.Area
    public let area: AppleProblem.Area
    public let answered: Bool
    public let detail: String
    public let checkedAt: String
    /// What else App Store Connect showed, such as the App Privacy answers or the tax conditions, so it can be shown while signed out.
    public var summary: String? = nil
}

extension WorkspaceSession {
    static let sectionChecksNamespace = "section_checks"

    /// The last section checks saved for one app, or what a later approved App Privacy or Tax Category review left. Apple is not contacted.
    public func sectionChecks(accountId: String, appId: String) throws -> [AppleProblem.Area: SectionCheck] {
        var result = try savedSectionChecks(accountId: accountId, appId: appId)
        var seen = Set<AppleProblem.Area>()
        for review in try publishHistory(accountId: accountId, appId: appId) where review.state == "complete" {
            guard let check = Self.approvedCheck(review), seen.insert(check.area).inserted else { continue }
            let newer = result[check.area].map { saved in (ReportTimestamps.date(check.checkedAt) ?? .distantPast) > (ReportTimestamps.date(saved.checkedAt) ?? .distantPast) } ?? true
            if newer { result[check.area] = check }
        }
        return result
    }
    private func savedSectionChecks(accountId: String, appId: String) throws -> [AppleProblem.Area: SectionCheck] {
        try storeAccess { store in
            var result: [AppleProblem.Area: SectionCheck] = [:]
            for item in Self.items(try PricingState.read(store, Self.sectionChecksNamespace).value?["checks"]) where item["accountId"]?.text == accountId && item["appId"]?.text == appId {
                guard let area = item["area"]?.text.flatMap(AppleProblem.Area.init), case .bool(let answered)? = item["answered"], let detail = item["detail"]?.text, let at = item["checkedAt"]?.text else { continue }
                result[area] = SectionCheck(area: area, answered: answered, detail: detail, checkedAt: at, summary: item["summary"]?.text)
            }
            return result
        }
    }

    /// Saves what App Store Connect showed for one section, replacing the earlier check, under the shared file lock.
    func recordSectionCheck(_ area: AppleProblem.Area, answered: Bool, detail: String, summary: String? = nil, accountId: String, appId: String) throws {
        guard try accounts().first(where: { $0.id == accountId })?.appIds.contains(appId) == true else { return }
        let at = ISO8601DateFormatter.storebench.string(from: Date())
        try storeAccess { store in
            try FileMutex.withLock(store.directory.appendingPathComponent("section_checks.mutex")) {
                let (document, value) = try PricingState.read(store, Self.sectionChecksNamespace)
                var checks = Self.items(value?["checks"]).filter { !($0["accountId"]?.text == accountId && $0["appId"]?.text == appId && $0["area"]?.text == area.rawValue) }
                checks.append(.object([("accountId", .string(accountId)), ("appId", .string(appId)), ("area", .string(area.rawValue)), ("answered", .bool(answered)),
                                       ("detail", .string(String(detail.prefix(200)))), ("checkedAt", .string(at))] + (summary.map { [("summary", JSONText.string(String($0.prefix(300))))] } ?? [])))
                try PricingState.replace(store, Self.sectionChecksNamespace, previous: document, value: .object([("schemaVersion", .number(1)), ("checks", .array(Array(checks.suffix(400))))]))
            }
        }
    }
}

extension WorkspaceSession {
    /// What an approved App Privacy or Tax Category review left in App Store Connect, at the time it completed; nil for other reviews.
    static func approvedCheck(_ review: PublishReview) -> SectionCheck? {
        let request = review.request
        guard let at = review.completedAt else { return nil }
        switch request.scope {
        case .appPrivacy where !review.steps.isEmpty:
            let published = request.appPrivacyPublish == true
            return SectionCheck(area: .privacy, answered: published, detail: published ? "Published" : "Not published", checkedAt: at, summary: request.appPrivacy?.summary)
        case .taxCategory:
            guard let applied = review.steps.last?.guardValue, let label = applied["label"]?.text else { return nil }
            return SectionCheck(area: .tax, answered: true, detail: label, checkedAt: at, summary: applied["conditions"]?.text)
        default: return nil
        }
    }
}
