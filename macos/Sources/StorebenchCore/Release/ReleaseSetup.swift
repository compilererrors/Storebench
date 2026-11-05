import Foundation

/// Suggests how to set up a version from what is saved: continue the version still being prepared at Apple,
/// copy the latest version into the next number, or start the first version. Suggestions only fill inputs;
/// nothing is saved or sent until the plan is created.
public enum ReleaseSetup {
    /// Apple states in which a version can still be edited and submitted.
    public static let inProgress: Set<String> = ["PREPARE_FOR_SUBMISSION", "READY_FOR_REVIEW", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED", "INVALID_BINARY"]

    public struct Candidate: Sendable {
        public let revision: Revision, version: Revision.Version
        public var rawState: String { version.fields["appVersionState"]?.text ?? version.fields["appStoreState"]?.text ?? "" }
        public var inProgress: Bool { !revision.isLocalDraft && ReleaseSetup.inProgress.contains(rawState) }
    }

    /// Imported versions, newest import first; local drafts follow and are only offered for copying.
    public static func candidates(_ history: [Revision]) -> [Candidate] {
        let imported = history.filter { !$0.isLocalDraft }.sorted { $0.importedAt > $1.importedAt }, drafts = history.filter(\.isLocalDraft)
        return (imported + drafts).flatMap { revision in
            revision.versions.sorted { left, right in
                guard let a = parts(left.number), let b = parts(right.number) else { return left.number > right.number }
                return higher(a, b)
            }.map { Candidate(revision: revision, version: $0) }
        }
    }

    /// The suggested start for an app with this history and no saved plan.
    public static func suggestion(_ history: [Revision], date: Date) -> ReleasePlanInputs {
        let candidates = candidates(history)
        // Older imports can describe versions that have since been released or removed.
        let latest = candidates.first { !$0.revision.isLocalDraft }?.revision.id
        let all = candidates.filter { $0.revision.id == latest || (latest == nil && $0.revision.isLocalDraft) }
        // A version still being prepared at Apple is the one to work on.
        if let current = all.first(where: \.inProgress) { return inputs(.reuse, current, history: history, date: date) }
        let released: Set<String> = ["READY_FOR_SALE", "READY_FOR_DISTRIBUTION", "REPLACED_WITH_NEW_VERSION"]
        if let latest = all.first(where: { released.contains($0.rawState) }) ?? all.first { return inputs(.copy, latest, history: history, date: date) }
        return ReleasePlanInputs(start: .empty(platform: "IOS", locale: "en-US"), targetVersion: "1.0", date: date)
    }

    /// Inputs for a start and a base version, with the version number and release method filled in.
    public static func inputs(_ start: ReleaseStart, _ base: Candidate, history: [Revision], date: Date) -> ReleasePlanInputs {
        let fields = base.version.fields, type = fields["releaseType"]?.text.flatMap { value in Releases.releaseTypes.contains { $0.0 == value } ? value : nil } ?? "MANUAL"
        let earliest = fields["earliestReleaseDate"]?.text.flatMap(Releases.parsedDate).flatMap { $0 > Date() ? $0 : nil } ?? date
        return ReleasePlanInputs(start: start, sourceRevisionId: base.revision.id, baseVersionId: base.version.id,
                                 targetVersion: suggestedNumber(start, base: base, history: history), releaseType: type, date: earliest)
    }

    /// Continuing keeps the version's own number; a copy takes the next free number; a first version is 1.0.
    public static func suggestedNumber(_ start: ReleaseStart, base: Candidate?, history: [Revision]) -> String {
        switch start {
        case .reuse: return base?.version.number ?? ""
        case .copy:
            guard let base else { return "" }
            return nextNumber(after: base.version.number, taken: taken(history, platform: base.version.platform))
        case .empty(let platform, _):
            return nextNumber(after: "0.9", taken: taken(history, platform: platform), firstVersion: true)
        }
    }

    static func taken(_ history: [Revision], platform: String) -> Set<String> {
        Set(history.filter { !$0.isLocalDraft }.flatMap(\.versions).filter { $0.platform == platform }.map(\.number))
    }

    static func parts(_ number: String) -> [Int]? {
        let pieces = number.split(separator: ".", omittingEmptySubsequences: false)
        let values = pieces.compactMap { Int($0) }
        return !values.isEmpty && values.count == pieces.count ? values : nil
    }
    static func higher(_ left: [Int], _ right: [Int]) -> Bool {
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0, b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    /// The next free number above `number` and above every taken one, as Apple requires: 1.0 → 1.1, 2.3.4 → 2.3.5.
    /// A first version starts at 1.0.
    public static func nextNumber(after number: String, taken: Set<String>, firstVersion: Bool = false) -> String {
        if firstVersion, !taken.contains("1.0"), taken.compactMap(parts).allSatisfy({ !higher($0, [1, 0]) }) { return "1.0" }
        let highest = taken.compactMap(parts).max { higher($1, $0) }
        var start = number
        if let highest, parts(number).map({ higher(highest, $0) }) ?? true { start = highest.map(String.init).joined(separator: ".") }
        var values = start.split(separator: ".").compactMap { Int($0) }
        guard !values.isEmpty, values.count == start.split(separator: ".", omittingEmptySubsequences: false).count else { return taken.contains("1.0") ? "" : "1.0" }
        if values.count == 1 { values.append(0) }
        for _ in 0..<1_000 {
            values[values.count - 1] += 1
            let candidate = values.map(String.init).joined(separator: ".")
            if !taken.contains(candidate) { return candidate }
        }
        return ""
    }

    /// "macOS 1.0 · Prepare for Submission · imported 10 Oct 2026 at 20:33" — readable, in the local time zone.
    public static func describe(_ candidate: Candidate, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let source = candidate.revision.isLocalDraft ? "local draft" : candidate.version.state.isEmpty ? "imported" : candidate.version.state
        return "\(candidate.version.title) · \(source) · \(candidate.revision.isLocalDraft ? "saved" : "imported") \(readableDate(candidate.revision.importedAt, locale: locale, timeZone: timeZone))"
    }

    public static func readableDate(_ iso: String, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        guard let date = Releases.parsedDate(iso) ?? ISO8601DateFormatter().date(from: iso) else { return iso }
        let format = DateFormatter(); format.locale = locale; format.timeZone = timeZone; format.dateStyle = .medium; format.timeStyle = .short
        return format.string(from: date)
    }
}

extension WorkspaceSession {
    /// Reuse a recent completed app material import across views, including its encrypted screenshot originals.
    /// Explicit Sync App Material still downloads fresh observations; existing plans keep their baseline.
    public func releaseStartingHistory(account: Account, appId: String, client: AppStoreConnectClient? = nil, now: Date = Date()) async throws -> [Revision] {
        try importScope(account, appId: appId, client: client)
        if try releaseStartNeedsImport(account: account, appId: appId, now: now) {
            var job = try await startImport(account: account, appId: appId, client: client)
            while job.isActive {
                try await Task.sleep(for: .milliseconds(250)); try Task.checkCancellation()
                guard let current = try importJob(account: account, appId: appId), current.id == job.id else { throw ImportFailure.status }
                job = current
            }
            guard job.state == .complete else { throw ImportFailure.download }
        }
        try Task.checkCancellation()
        return try revisions(accountId: account.id, appId: appId)
    }
    /// True when a new plan must first download the app's current material: there is no saved plan and no import completed in the last five minutes.
    public func releaseStartNeedsImport(account: Account, appId: String, now: Date = Date()) throws -> Bool {
        guard try releasePlan(accountId: account.id, appId: appId) == nil else { return false }
        guard let job = try importJob(account: account, appId: appId), job.state == .complete,
              let updated = Releases.parsedDate(job.updatedAt), (0...300).contains(now.timeIntervalSince(updated)),
              let id = job.revisionId else { return true }
        return try latestImport(accountId: account.id, appId: appId)?["id"]?.text != id
    }
}
