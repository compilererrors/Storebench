import Foundation

/// A theme found in customer reviews, the action decided for a release, and the reviews it is based on.
public struct ReviewTheme: Identifiable, Sendable {
    public let id, theme, action, decision, followUp, revisionId, versionId, versionLabel: String
    public let evidence: [CustomerReview]
    public let snapshotCheckedAt: String, limited: Bool, savedAt: String

    public var json: JSONText {
        .object([("id", .string(id)), ("theme", .string(theme)), ("action", .string(action)), ("decision", .string(decision)), ("followUp", .string(followUp)),
                 ("revisionId", .string(revisionId)), ("versionId", .string(versionId)), ("versionLabel", .string(versionLabel)),
                 ("evidence", .array(evidence.map { .object([("id", .string($0.id)), ("rating", .number(Double($0.rating))), ("title", .string($0.title)), ("body", .string($0.body)),
                                                             ("createdDate", .string($0.createdDate)), ("territory", .string($0.territory))]) })),
                 ("snapshotCheckedAt", .string(snapshotCheckedAt)), ("limited", .bool(limited)), ("savedAt", .string(savedAt))])
    }

    init(id: String, theme: String, action: String, decision: String, followUp: String, revisionId: String, versionId: String, versionLabel: String, evidence: [CustomerReview], snapshotCheckedAt: String, limited: Bool, savedAt: String) {
        self.id = id; self.theme = theme; self.action = action; self.decision = decision; self.followUp = followUp; self.revisionId = revisionId; self.versionId = versionId
        self.versionLabel = versionLabel; self.evidence = evidence; self.snapshotCheckedAt = snapshotCheckedAt; self.limited = limited; self.savedAt = savedAt
    }

    public init(_ value: JSONText) throws {
        guard let id = value["id"]?.text, id.range(of: "^[a-f0-9-]{36}$", options: .regularExpression) != nil, case .array(let rows)? = value["evidence"],
              let label = value["versionLabel"]?.text, label.utf16.count <= 1000, case .bool(let limited)? = value["limited"],
              let checked = value["snapshotCheckedAt"]?.text, ASO.iso(checked) != nil || ProductPricing.calendarDate(checked), let saved = value["savedAt"]?.text, ASO.iso(saved) != nil else { throw ReviewThemeFailure.invalid }
        let evidence = try rows.map { row -> CustomerReview in
            guard let id = row["id"]?.text, case .number(let rating)? = row["rating"], rating == rating.rounded(), (1...5).contains(rating), let territory = row["territory"]?.text,
                  let title = row["title"]?.text, let body = row["body"]?.text, let created = row["createdDate"]?.text else { throw ReviewThemeFailure.invalid }
            do { return try CustomerReview(id: id, rating: Int(rating), title: title, body: body, createdDate: created, territory: territory).normalized() }
            catch { throw ReviewThemeFailure.invalid }
        }
        let input = try ReviewThemeInput(id: id, reviewIds: evidence.map(\.id), revisionId: value["revisionId"]?.text ?? "", versionId: value["versionId"]?.text ?? "", theme: value["theme"]?.text ?? "",
                                         action: value["action"]?.text ?? "", decision: value["decision"]?.text ?? "", followUp: value["followUp"]?.text ?? "").validated()
        self.init(id: id, theme: input.theme, action: input.action, decision: input.decision, followUp: input.followUp, revisionId: input.revisionId, versionId: input.versionId,
                  versionLabel: label, evidence: evidence, snapshotCheckedAt: checked, limited: limited, savedAt: saved)
    }
}

public struct ReviewThemeInput: Sendable, Equatable {
    public var id: String?, reviewIds: [String], revisionId, versionId, theme, action, decision, followUp: String
    public init(id: String? = nil, reviewIds: [String], revisionId: String, versionId: String, theme: String, action: String, decision: String, followUp: String) {
        self.id = id; self.reviewIds = reviewIds; self.revisionId = revisionId; self.versionId = versionId; self.theme = theme; self.action = action; self.decision = decision; self.followUp = followUp
    }
    public var json: JSONText { .object([("id", id.map(JSONText.string) ?? .null), ("reviewIds", .array(reviewIds.sorted().map(JSONText.string))), ("revisionId", .string(revisionId)), ("versionId", .string(versionId)), ("theme", .string(theme)), ("action", .string(action)), ("decision", .string(decision)), ("followUp", .string(followUp))]) }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.json == rhs.json }
    func validated() throws -> ReviewThemeInput {
        let opaque = "^[A-Za-z0-9_-]{1,256}$"
        guard id.map({ $0.range(of: "^[a-f0-9-]{36}$", options: .regularExpression) != nil }) ?? true, revisionId.range(of: "^[a-f0-9-]{36}$", options: .regularExpression) != nil,
              versionId.range(of: opaque, options: .regularExpression) != nil, (1...50).contains(reviewIds.count), Set(reviewIds).count == reviewIds.count,
              reviewIds.allSatisfy({ $0.range(of: opaque, options: .regularExpression) != nil }) else { throw ReviewThemeFailure.selection }
        for text in [theme, action, decision, followUp] {
            guard !TextSemantics.trim(text).isEmpty, text.utf16.count <= 1000,
                  TextSemantics.validControlText(text) else { throw ReviewThemeFailure.incomplete }
        }
        var result = self; result.reviewIds.sort(); return result
    }
}

public enum ReviewThemeFailure: Error, Equatable {
    case invalid, selection, incomplete, conflict, full
    public var message: String {
        switch self {
        case .invalid: "Saved review themes are invalid."
        case .selection: "Choose reviews and an existing release version."
        case .incomplete: "Complete the theme, intended action, decision and follow-up."
        case .conflict: "The reviews, release or saved themes changed. Reload and compare before saving."
        case .full: "Choose an existing theme or remove a theme before adding more."
        }
    }
}

public struct ReviewThemeVersion: Identifiable, Sendable {
    public var id: String { "\(revisionId)|\(versionId)" }
    public let revisionId, versionId, label: String
    fileprivate let releaseBasis: String
}

/// An immutable editor baseline. Reading a newer state does not change an existing baseline.
public struct ReviewThemeState: Sendable {
    public let revision: Int, themes: [ReviewTheme], versions: [ReviewThemeVersion], snapshot: ReviewsSnapshot?
    fileprivate let accountId, appId, documentBasis, reviewsBasis: String
}

/// Exact evidence and decisions to read before the separate local save, valid for ten minutes.
public struct ReviewThemePreparation: Sendable {
    public let revision: Int, token, expiresAt: String, theme: ReviewTheme
    fileprivate let accountId, appId, documentBasis: String
    public let baseline: ReviewThemeState
    public var json: JSONText { .object([("token", .string(token)), ("expiresAt", .string(expiresAt)), ("theme", theme.json)]) }
}

enum ReviewThemeStorage {
    static func mutex(_ key: String) -> String { "review_themes_" + JSONText.string(key).sha256.prefix(40) + ".mutex" }
    static func basis(_ document: EncryptedDocumentStore.Document?) throws -> String {
        JSONText.array([.number(Double(document?.revision ?? 0)), try document.map { try JSONText.parse($0.payload) } ?? .null]).sha256
    }
    static func reviewsBasis(index: EncryptedDocumentStore.Document?, legacy: EncryptedDocumentStore.Document?) throws -> String {
        let document = index ?? legacy
        return JSONText.array([.string(index == nil ? "document" : "index"), .number(Double(document?.revision ?? 0)), try document.map { try JSONText.parse($0.payload) } ?? .null]).sha256
    }
    static func themes(_ document: EncryptedDocumentStore.Document?) throws -> [ReviewTheme] {
        guard let document else { return [] }
        let value = try JSONText.parse(document.payload)
        guard value["schemaVersion"] == .number(1), case .array(let rows)? = value["themes"], rows.count <= 100 else { throw ReviewThemeFailure.invalid }
        let themes = try rows.map(ReviewTheme.init)
        guard Set(themes.map(\.id)).count == themes.count else { throw ReviewThemeFailure.invalid }
        return themes
    }
    static func release(_ document: EncryptedDocumentStore.Document?, accountId: String, appId: String, id: String) throws -> (JSONText, Revision) {
        guard let document else { throw ReviewThemeFailure.conflict }
        let raw = try JSONText.parse(document.payload)
        guard id.range(of: "^[a-f0-9-]{36}$", options: .regularExpression) != nil, raw["schemaVersion"] == .number(1), raw["id"] == .string(id), raw["account"]?["id"] == .string(accountId),
              raw["app"]?["id"] == .string(appId), let imported = raw["importedAt"]?.text, ASO.iso(imported) != nil || ProductPricing.calendarDate(imported) else { throw ReviewThemeFailure.invalid }
        let revision = try JSONDecoder().decode(Revision.self, from: document.payload)
        guard Set(revision.versions.map(\.id)).count == revision.versions.count else { throw ReviewThemeFailure.invalid }
        for version in revision.versions {
            guard version.id.range(of: "^[A-Za-z0-9_-]{1,256}$", options: .regularExpression) != nil else { throw ReviewThemeFailure.invalid }
            for localization in version.localizations { for set in localization.screenshotSets { for screenshot in set.screenshots {
                guard screenshot.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil, ["image/png", "image/jpeg"].contains(screenshot.contentType ?? "") else { throw ReviewThemeFailure.invalid }
            } } }
        }
        return (raw, revision)
    }
    static func versionLabel(_ version: Revision.Version) -> String {
        func text(_ key: String, fallback: String) -> String {
            guard let value = version.fields[key], value != .null, value != .text(""), value != .number(0) else { return fallback }
            return value.text ?? fallback
        }
        return text("versionString", fallback: version.id) + " · " + text("platform", fallback: "App Store")
    }
}

extension WorkspaceSession {
    /// Loads themes, all saved evidence and scoped release versions together under the shared theme mutex.
    public func reviewThemes(account: Account, appId: String) throws -> ReviewThemeState {
        try reviewsScope(account, appId: appId); try Task.checkCancellation()
        let key = "\(account.id):\(appId)"
        return try storeAccess { store in
            try FileMutex.withLock(store.directory.appendingPathComponent(ReviewThemeStorage.mutex(key))) {
                try reviewsScope(account, appId: appId); try Task.checkCancellation()
                let index = try store.document(namespace: "reviews_index", key: key), legacy = index == nil ? try store.document(namespace: "reviews", key: key) : nil
                let saved = try savedReviewsFiles(account: account, appId: appId)
                guard saved.revision == PartitionedReports.basis(index: index, legacy: legacy) else { throw ReviewThemeFailure.conflict }
                let document = try store.document(namespace: "review_themes", key: key)
                var versions: [ReviewThemeVersion] = []
                for release in try store.documents(namespace: "revisions", prefix: key + ":").sorted(by: { $0.key < $1.key }) {
                    let id = String(release.key.dropFirst(key.count + 1)), (raw, revision) = try ReviewThemeStorage.release(release, accountId: account.id, appId: appId, id: id)
                    versions += revision.versions.map { ReviewThemeVersion(revisionId: id, versionId: $0.id, label: ReviewThemeStorage.versionLabel($0) + " · imported " + String(revision.importedAt.prefix(10)), releaseBasis: raw.sha256) }
                }
                try reviewsScope(account, appId: appId); try Task.checkCancellation()
                return try ReviewThemeState(revision: document?.revision ?? 0, themes: ReviewThemeStorage.themes(document), versions: versions, snapshot: saved.snapshot, accountId: account.id, appId: appId,
                                            documentBasis: ReviewThemeStorage.basis(document), reviewsBasis: ReviewThemeStorage.reviewsBasis(index: index, legacy: legacy))
            }
        }
    }

    /// Reads an existing concrete review after restart, preserving its stored format.
    public func pendingReviewTheme(account: Account, appId: String, now: Date = Date()) throws -> ReviewThemePreparation? {
        let baseline = try reviewThemes(account: account, appId: appId), key = "\(account.id):\(appId)"
        return try storeAccess { store in
            try FileMutex.withLock(store.directory.appendingPathComponent(ReviewThemeStorage.mutex(key))) {
                try reviewsScope(account, appId: appId); try Task.checkCancellation()
                let document = try store.document(namespace: "review_themes", key: key)
                guard try ReviewThemeStorage.basis(document) == baseline.documentBasis,
                      try ReviewThemeStorage.reviewsBasis(index: store.document(namespace: "reviews_index", key: key), legacy: store.document(namespace: "reviews", key: key)) == baseline.reviewsBasis else { throw ReviewThemeFailure.conflict }
                guard let data = document?.payload, let prepared = try JSONText.parse(data)["prepared"] else { return nil }
                guard let token = prepared["token"]?.text, token.range(of: "^[a-f0-9-]{36}$", options: .regularExpression) != nil,
                      let expiry = prepared["expiresAt"]?.text, let date = ASO.iso(expiry), date > now, let raw = prepared["theme"],
                      prepared["basis"] == .string(baseline.reviewsBasis) else { throw ReviewThemeFailure.conflict }
                let theme = try ReviewTheme(raw)
                let (release, _) = try ReviewThemeStorage.release(store.document(namespace: "revisions", key: key + ":" + theme.revisionId), accountId: account.id, appId: appId, id: theme.revisionId)
                guard theme.json == raw, prepared["releaseBasis"] == .string(release.sha256) else { throw ReviewThemeFailure.conflict }
                return ReviewThemePreparation(revision: baseline.revision, token: token, expiresAt: expiry, theme: theme, accountId: account.id, appId: appId, documentBasis: baseline.documentBasis, baseline: baseline)
            }
        }
    }

    /// Preparing stores a review, leaving the saved themes unchanged. A changed baseline requires explicit comparison.
    public func prepareReviewTheme(account: Account, appId: String, input raw: ReviewThemeInput, baseline: ReviewThemeState, now: Date = Date()) throws -> ReviewThemePreparation {
        let input = try raw.validated(), key = "\(account.id):\(appId)"
        guard baseline.accountId == account.id, baseline.appId == appId, let snapshot = baseline.snapshot,
              let offered = baseline.versions.first(where: { $0.revisionId == input.revisionId && $0.versionId == input.versionId }) else { throw ReviewThemeFailure.conflict }
        try reviewsScope(account, appId: appId); try Task.checkCancellation()
        return try storeAccess { store in
            try FileMutex.withLock(store.directory.appendingPathComponent(ReviewThemeStorage.mutex(key))) {
                var result: ReviewThemePreparation?
                try store.transaction { read in
                    try reviewsScope(account, appId: appId); try Task.checkCancellation()
                    let document = try read("review_themes", key)
                    guard try ReviewThemeStorage.basis(document) == baseline.documentBasis,
                          try ReviewThemeStorage.reviewsBasis(index: read("reviews_index", key), legacy: read("reviews", key)) == baseline.reviewsBasis else { throw ReviewThemeFailure.conflict }
                    let themes = try ReviewThemeStorage.themes(document)
                    if let id = input.id { guard themes.contains(where: { $0.id == id }) else { throw ReviewThemeFailure.conflict } }
                    else if themes.count >= 100 { throw ReviewThemeFailure.full }
                    let (release, revision) = try ReviewThemeStorage.release(read("revisions", key + ":" + input.revisionId), accountId: account.id, appId: appId, id: input.revisionId)
                    guard release.sha256 == offered.releaseBasis, let version = revision.versions.first(where: { $0.id == input.versionId }) else { throw ReviewThemeFailure.conflict }
                    let byId = Dictionary(uniqueKeysWithValues: snapshot.reviews.map { ($0.id, $0) }), evidence = input.reviewIds.compactMap { byId[$0] }
                    guard evidence.count == input.reviewIds.count else { throw ReviewThemeFailure.conflict }
                    let theme = ReviewTheme(id: input.id ?? UUID().uuidString.lowercased(), theme: input.theme, action: input.action, decision: input.decision, followUp: input.followUp,
                                            revisionId: input.revisionId, versionId: input.versionId, versionLabel: ReviewThemeStorage.versionLabel(version), evidence: evidence,
                                            snapshotCheckedAt: snapshot.checkedAt, limited: snapshot.limited, savedAt: CustomerReview.isoString(now))
                    let token = UUID().uuidString.lowercased(), expiry = CustomerReview.isoString(now.addingTimeInterval(600))
                    let prepared = JSONText.object([("token", .string(token)), ("expiresAt", .string(expiry)), ("theme", theme.json), ("basis", .string(baseline.reviewsBasis)), ("releaseBasis", .string(release.sha256))])
                    let next = JSONText.object([("schemaVersion", .number(1)), ("themes", .array(themes.map(\.json))), ("prepared", prepared)])
                    let number = (document?.revision ?? 0) + 1
                    result = ReviewThemePreparation(revision: number, token: token, expiresAt: expiry, theme: theme, accountId: account.id, appId: appId,
                                                    documentBasis: JSONText.array([.number(Double(number)), next]).sha256,
                                                    baseline: ReviewThemeState(revision: number, themes: baseline.themes, versions: baseline.versions, snapshot: baseline.snapshot, accountId: account.id, appId: appId,
                                                                              documentBasis: JSONText.array([.number(Double(number)), next]).sha256, reviewsBasis: baseline.reviewsBasis))
                    try reviewsScope(account, appId: appId); try Task.checkCancellation()
                    return [.put(namespace: "review_themes", key: key, json: next.data)]
                }
                guard let result else { throw ReviewThemeFailure.invalid }; return result
            }
        }
    }

    /// Consumes the exact local review once, rechecking the source, entire release, scope and expiry in the write transaction.
    @discardableResult
    public func saveReviewTheme(account: Account, appId: String, preparation: ReviewThemePreparation, now: Date = Date()) throws -> Int {
        guard preparation.accountId == account.id, preparation.appId == appId else { throw ReviewThemeFailure.conflict }
        try reviewsScope(account, appId: appId); try Task.checkCancellation()
        let key = "\(account.id):\(appId)"
        return try storeAccess { store in
            try FileMutex.withLock(store.directory.appendingPathComponent(ReviewThemeStorage.mutex(key))) {
                try store.transaction { read in
                    try reviewsScope(account, appId: appId); try Task.checkCancellation()
                    let document = try read("review_themes", key)
                    guard (document?.revision ?? 0) == preparation.revision, try ReviewThemeStorage.basis(document) == preparation.documentBasis,
                          let data = document?.payload, let prepared = try JSONText.parse(data)["prepared"], prepared["token"] == .string(preparation.token), prepared["expiresAt"] == .string(preparation.expiresAt),
                          prepared["theme"] == preparation.theme.json, let expiry = ASO.iso(preparation.expiresAt), expiry > now,
                          prepared["basis"] == .string(try ReviewThemeStorage.reviewsBasis(index: read("reviews_index", key), legacy: read("reviews", key))),
                          let release = try read("revisions", key + ":" + preparation.theme.revisionId), prepared["releaseBasis"] == .string(try JSONText.parse(release.payload).sha256) else { throw ReviewThemeFailure.conflict }
                    _ = try ReviewThemeStorage.release(release, accountId: account.id, appId: appId, id: preparation.theme.revisionId)
                    let saved = try ReviewTheme(prepared["theme"]!), themes = try ReviewThemeStorage.themes(document)
                    let theme = ReviewTheme(id: saved.id, theme: saved.theme, action: saved.action, decision: saved.decision, followUp: saved.followUp, revisionId: saved.revisionId, versionId: saved.versionId,
                                            versionLabel: saved.versionLabel, evidence: saved.evidence, snapshotCheckedAt: saved.snapshotCheckedAt, limited: saved.limited, savedAt: CustomerReview.isoString(now))
                    let next = themes.filter { $0.id != theme.id } + [theme]
                    guard next.count <= 100, JSONText.array(next.map(\.json)).data.count <= 8_000_000 else { throw ReviewThemeFailure.full }
                    try reviewsScope(account, appId: appId); try Task.checkCancellation()
                    return [.put(namespace: "review_themes", key: key, json: JSONText.object([("schemaVersion", .number(1)), ("themes", .array(next.map(\.json)))]).data)]
                }
                return preparation.revision + 1
            }
        }
    }
}
