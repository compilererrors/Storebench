import Foundation

/// How many connected apps Storebench reads ahead in the background, so Release and Quick Release open with material and status already saved.
/// With more connected apps than the limit, the apps opened most often and most recently are prepared. Zero turns preparation off.
public struct BackgroundPreparation: Equatable, Sendable {
    public static let limits = [0, 1, 3, 5, 10, 20]
    public static let standard = 3
    public let appLimit: Int

    public init(appLimit: Int = BackgroundPreparation.standard) throws {
        guard Self.limits.contains(appLimit) else { throw BackgroundPreparationFailure.invalid }
        self.appLimit = appLimit
    }

    public init(_ value: JSONText) throws {
        guard value["schemaVersion"] == .number(1), case .number(let limit)? = value["appLimit"], limit.rounded() == limit, abs(limit) <= 1_000 else { throw BackgroundPreparationFailure.invalid }
        try self.init(appLimit: Int(limit))
    }

    public var json: JSONText { .object([("schemaVersion", .number(1)), ("appLimit", .number(Double(appLimit)))]) }

    static func stored(_ document: EncryptedDocumentStore.Document?) throws -> Self {
        let value = try document.map { try JSONText.parse($0.payload) }
        if value == nil || value == .null { return try Self() }
        return try Self(value!)
    }
}

public enum BackgroundPreparationFailure: Error, Equatable { case invalid }

/// How often each connected app was opened on this Mac. Each opening adds one, and older openings count for half every two weeks,
/// so the apps worked on lately rank first. Opening Release or Quick Release is remembered separately.
public struct AppUsage: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let accountId: String, appId: String
        public let score: Double, lastOpened: Date
        /// The last time Release or Quick Release was opened for the app.
        public let releaseOpened: Date?
    }
    static let halfLife: TimeInterval = 14 * 86_400
    static let capacity = 200
    /// An app whose release was opened within this time has its material imported ahead when it is opened again.
    static let releaseMemory: TimeInterval = 30 * 86_400
    public private(set) var entries: [Entry]

    public init(entries: [Entry] = []) { self.entries = entries }

    init(_ value: JSONText) throws {
        guard value["schemaVersion"] == .number(1), case .array(let rows)? = value["apps"], rows.count <= Self.capacity else { throw BackgroundPreparationFailure.invalid }
        var seen = Set<String>()
        entries = try rows.map { row in
            guard let accountId = row["accountId"]?.text, let appId = row["appId"]?.text, !accountId.isEmpty, !appId.isEmpty,
                  case .number(let score)? = row["score"], score.isFinite, score >= 0, case .number(let opened)? = row["lastOpened"], opened.isFinite,
                  seen.insert(Self.key(accountId, appId)).inserted else { throw BackgroundPreparationFailure.invalid }
            var release: Date?
            if let value = row["releaseOpened"], value != .null {
                guard case .number(let seconds) = value, seconds.isFinite else { throw BackgroundPreparationFailure.invalid }
                release = Date(timeIntervalSince1970: seconds)
            }
            return Entry(accountId: accountId, appId: appId, score: score, lastOpened: Date(timeIntervalSince1970: opened), releaseOpened: release)
        }
    }

    var json: JSONText {
        .object([("schemaVersion", .number(1)), ("apps", .array(entries.map { entry in
            .object([("accountId", .string(entry.accountId)), ("appId", .string(entry.appId)), ("score", .number(entry.score)),
                     ("lastOpened", .number(entry.lastOpened.timeIntervalSince1970)), ("releaseOpened", entry.releaseOpened.map { .number($0.timeIntervalSince1970) } ?? .null)])
        }))])
    }

    static func stored(_ document: EncryptedDocumentStore.Document?) throws -> Self {
        let value = try document.map { try JSONText.parse($0.payload) }
        if value == nil || value == .null { return Self() }
        return try Self(value!)
    }

    private static func key(_ accountId: String, _ appId: String) -> String { JSONText.array([.string(accountId), .string(appId)]).stringify() }

    /// The entry's score as of `now`.
    public static func score(_ entry: Entry, now: Date) -> Double {
        entry.score * pow(0.5, max(0, now.timeIntervalSince(entry.lastOpened)) / halfLife)
    }

    /// One more opening of the app; `release` marks an opening of Release or Quick Release. A release opened inside an app already counted
    /// passes `counts: false`. Only the highest-scoring apps are kept.
    public func recording(accountId: String, appId: String, release: Bool = false, counts: Bool = true, now: Date = Date()) -> AppUsage {
        let current = entries.first { $0.accountId == accountId && $0.appId == appId }
        // A mark that does not count leaves the score and its decay where they were.
        let score = counts ? (current.map { Self.score($0, now: now) } ?? 0) + 1 : current?.score ?? 0
        let entry = Entry(accountId: accountId, appId: appId, score: score, lastOpened: counts ? now : current?.lastOpened ?? now,
                          releaseOpened: release ? now : current?.releaseOpened)
        let others = entries.filter { !($0.accountId == accountId && $0.appId == appId) }
            .sorted { Self.score($0, now: now) > Self.score($1, now: now) }
        return AppUsage(entries: [entry] + others.prefix(Self.capacity - 1))
    }

    /// True when Release or Quick Release was opened for the app lately.
    public func preparesRelease(accountId: String, appId: String, now: Date = Date()) -> Bool {
        guard let opened = entries.first(where: { $0.accountId == accountId && $0.appId == appId })?.releaseOpened else { return false }
        return now.timeIntervalSince(opened) < Self.releaseMemory
    }

    /// The apps to prepare, at most `limit`: the open app first, then the others by score, then by their last opening and their connected order.
    /// With no more connected apps than the limit, every app is prepared.
    public func ranked(_ apps: [(accountId: String, appId: String)], current: (accountId: String, appId: String)?, limit: Int, now: Date = Date()) -> [(accountId: String, appId: String)] {
        guard limit > 0 else { return [] }
        let byKey = Dictionary(entries.map { (Self.key($0.accountId, $0.appId), $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        let connected = apps.enumerated().filter { seen.insert(Self.key($0.element.accountId, $0.element.appId)).inserted }
        let ordered = connected.sorted { lhs, rhs in
            func isCurrent(_ app: (accountId: String, appId: String)) -> Bool { current.map { $0.accountId == app.accountId && $0.appId == app.appId } ?? false }
            if isCurrent(lhs.element) != isCurrent(rhs.element) { return isCurrent(lhs.element) }
            let left = byKey[Self.key(lhs.element.accountId, lhs.element.appId)], right = byKey[Self.key(rhs.element.accountId, rhs.element.appId)]
            let leftScore = left.map { Self.score($0, now: now) } ?? 0, rightScore = right.map { Self.score($0, now: now) } ?? 0
            if leftScore != rightScore { return leftScore > rightScore }
            let leftOpened = left?.lastOpened ?? .distantPast, rightOpened = right?.lastOpened ?? .distantPast
            if leftOpened != rightOpened { return leftOpened > rightOpened }
            return lhs.offset < rhs.offset
        }
        return ordered.prefix(limit).map(\.element)
    }
}

extension WorkspaceSession {
    /// A remembered status of another app younger than this is kept; Release reads it again when it opens.
    static let preparedStatusAge: TimeInterval = 30 * 60
    /// The opened page reads first; preparation follows after this pause and between apps.
    static let preparationPause: Duration = .milliseconds(800)

    public func backgroundPreparation() throws -> BackgroundPreparation {
        try storeAccess { store in try BackgroundPreparation.stored(store.document(namespace: "background_preparation", key: "current")) }
    }

    public func setBackgroundPreparation(_ value: BackgroundPreparation) throws {
        try storeAccess { store in
            try FileMutex.withLock(store.directory.appendingPathComponent("background_preparation.mutex")) {
                try store.transaction { current in
                    _ = try BackgroundPreparation.stored(current("background_preparation", "current"))
                    return [.put(namespace: "background_preparation", key: "current", json: value.json.data)]
                }
            }
        }
    }

    public func appUsage() throws -> AppUsage {
        try storeAccess { store in try AppUsage.stored(store.document(namespace: "app_usage", key: "current")) }
    }

    /// Counts one opening of a connected app; `release` marks Release or Quick Release as opened, and `counts: false` only marks it.
    public func recordAppOpened(accountId: String, appId: String, release: Bool = false, counts: Bool = true, now: Date = Date()) throws {
        guard try accounts().contains(where: { $0.id == accountId && $0.apps.contains { $0.id == appId } }) else { throw AccountFailure.notFound }
        try storeAccess { store in
            try FileMutex.withLock(store.directory.appendingPathComponent("app_usage.mutex")) {
                try store.transaction { current in
                    let usage = try AppUsage.stored(current("app_usage", "current"))
                    return [.put(namespace: "app_usage", key: "current", json: usage.recording(accountId: accountId, appId: appId, release: release, counts: counts, now: now).json.data)]
                }
            }
        }
    }

    /// Hands over the selected apps' saved starting versions before any delay, credential access or Apple request. Remote preparation
    /// then follows one app at a time, the open app first. Each remote part is handed over as soon as it is ready. The open app's material
    /// import starts when its release was opened lately and it has no saved plan; each saved plan's release status is read and remembered
    /// as a full status check would. Stops when cancelled.
    public func prepareApps(current: (accountId: String, appId: String)?, now: @Sendable () -> Date = Date.init,
                            prepared: @escaping @MainActor @Sendable (PreparedApp) -> Void = { _ in }) async {
        guard let limit = try? backgroundPreparation().appLimit, limit > 0, let accounts = try? accounts() else { return }
        let connected = accounts.flatMap { account in account.apps.map { (accountId: account.id, appId: $0.id) } }
        let usage = (try? appUsage()) ?? AppUsage()
        let targets = usage.ranked(connected, current: current, limit: limit, now: now())
        for target in targets.prefix(PreparedApp.presentedLimit) {
            guard !Task.isCancelled else { return }
            guard let history = try? revisions(accountId: target.accountId, appId: target.appId) else { continue }
            guard !Task.isCancelled else { return }
            await prepared(PreparedApp(accountId: target.accountId, appId: target.appId, history: history, builds: nil, pricing: nil))
        }
        for (index, target) in targets.enumerated() {
            do { try await Task.sleep(for: Self.preparationPause) } catch { return }
            guard let account = accounts.first(where: { $0.id == target.accountId }) else { continue }
            let open = current.map { $0.accountId == target.accountId && $0.appId == target.appId } ?? false
            do {
                let importing = open && usage.preparesRelease(accountId: target.accountId, appId: target.appId, now: now())
                // The open app's reads are likely next; other apps fill in behind every screen's own reads.
                try await AppleReadPriority.$current.withValue(open ? .next : .background) {
                    try await prepare(account: account, appId: target.appId, open: open, importing: importing, presented: index < PreparedApp.presentedLimit, now: now, prepared: prepared)
                }
            } catch { if Task.isCancelled { return } }
        }
    }

    private func prepare(account: Account, appId: String, open: Bool, importing: Bool, presented: Bool, now: @Sendable () -> Date,
                         prepared: @MainActor @Sendable (PreparedApp) -> Void) async throws {
        try Task.checkCancellation()
        guard AppleRequestBudget.allowsReadingAhead(keyId: account.keyId) else { return }
        let client = try readClient(for: account)
        // Deliver the build list before pricing and the fuller TestFlight check, which also reads group memberships.
        // The later check reuses these build responses instead of downloading them again.
        if presented {
            if let builds = try? await AppStoreReadCache.rereadingAfterInvalidation({ try await testFlightBuilds(appId: appId, client: client) }) {
                try Task.checkCancellation()
                await prepared(PreparedApp(accountId: account.id, appId: appId, history: nil, builds: builds, pricing: nil))
            }
        }
        if open, let pricing = try? await AppStoreReadCache.rereadingAfterInvalidation({ try await pricingSetupState(account: account, appId: appId, client: client) }) {
            try Task.checkCancellation()
            await prepared(PreparedApp(accountId: account.id, appId: appId, history: nil, builds: nil, pricing: pricing))
        }
        // Start Testing's check reads the builds, groups and test information the TestFlight pages show, so they open from the shared reads too.
        if open, let facts = try? await testFlightFacts(account: account, appId: appId, fresh: false) {
            try Task.checkCancellation()
            await prepared(PreparedApp(accountId: account.id, appId: appId, history: nil, builds: facts.builds, pricing: nil, testFlight: facts))
        }
        try Task.checkCancellation()
        if let plan = try releasePlan(accountId: account.id, appId: appId) {
            let freshness = open ? ReleaseStatusSync.rememberedFreshness : Self.preparedStatusAge
            let remembered = rememberedReleaseReadiness(accountId: account.id, appId: appId, planToken: plan.token)
            if remembered.map({ now().timeIntervalSince($0.checkedAt) >= freshness }) ?? true,
               let snapshot = try? await releaseReadiness(account: account, appId: appId, revisionId: plan.sourceRevisionId, planToken: plan.token, client: client) {
                try Task.checkCancellation()
                rememberReleaseReadiness(snapshot, checkedAt: now())
            }
        } else if importing, try releaseStartNeedsImport(account: account, appId: appId, now: now()) {
            // A new plan starts from an import of the last few minutes; the job runs on its own and Release follows the same job.
            _ = try await startImport(account: account, appId: appId)
        }
    }
}

/// One part background preparation read for an app: its saved starting versions, Apple's builds, or the open app's pricing or TestFlight check.
public struct PreparedApp: Sendable {
    /// Only the first prepared apps are handed to the window, which keeps a bounded number of reads.
    static let presentedLimit = 5
    public let accountId: String, appId: String
    public let history: [Revision]?
    public let builds: [TestFlightBuild]?
    /// The open app's pricing as Pricing shows it.
    public let pricing: PricingSetupState?
    /// The open app's TestFlight check as Start Testing shows it.
    public var testFlight: TestFlightFlow.Facts? = nil
}
