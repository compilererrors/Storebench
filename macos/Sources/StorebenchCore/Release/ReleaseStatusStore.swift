import Foundation

/// The last confirmed release status per app, saved in the encrypted database so a later session opens with it.
/// It is disposable private runtime data: it is shown only for the same saved plan, marked as not yet confirmed, and read again at once.
/// It never stands in for the fresh reads that preparing an Apple change requires.
extension ReleaseReadiness.Step {
    init(json: JSONText) throws {
        func text(_ key: String, required: Bool = true) throws -> String? {
            guard let value = json[key], value != .null else { if required { throw ReleaseReadiness.Failure.invalid }; return nil }
            guard let text = value.text, text.utf16.count <= 8_192 else { throw ReleaseReadiness.Failure.invalid }; return text
        }
        guard let id = try text("id"), !id.isEmpty, let label = try text("label"), let detail = try text("detail"), let href = try text("href"), let action = try text("action"),
              let state = try text("state").flatMap(ReleaseReadiness.State.init(rawValue:)) else { throw ReleaseReadiness.Failure.invalid }
        let territories = json["territories"].flatMap { $0 == .null ? nil : $0 }
        if let territories { guard case .object = territories else { throw ReleaseReadiness.Failure.invalid } }
        self.init(id: id, label: label, detail: detail, href: href, action: action, state: state, territories: territories, guideHref: try text("guideHref", required: false))
    }
}

extension ReleaseReadinessSnapshot {
    static let schemaVersion = 1
    func json(checkedAt: Date) -> JSONText {
        .object([("schemaVersion", .number(Double(Self.schemaVersion))), ("accountId", .string(scope.accountId)), ("appId", .string(scope.appId)), ("planToken", .string(plan.token)),
                 ("checkedAt", .string(Releases.iso.string(from: checkedAt))), ("materialSignature", .string(materialSignature)),
                 ("targetVersionId", targetVersionId.map(JSONText.string) ?? .null), ("targetState", targetState.map(JSONText.string) ?? .null), ("steps", .array(steps.map(\.json))),
                 ("parts", .number(Double(parts.rawValue))), ("observations", observations)])
    }
    /// A saved status for exactly this account, app and saved plan; anything else, or anything malformed, is no status.
    static func saved(_ value: JSONText, accountId: String, appId: String, planToken: String) throws -> (snapshot: ReleaseReadinessSnapshot, checkedAt: Date) {
        guard value["schemaVersion"] == .number(Double(schemaVersion)), value["accountId"]?.text == accountId, value["appId"]?.text == appId,
              let token = value["planToken"]?.text, TextSemantics.same(token, planToken), let plan = ReleasePlan(try JSONText.parse(Data(token.utf8))), plan.token == token,
              plan.accountId == accountId, plan.appId == appId, let checked = value["checkedAt"]?.text.flatMap(Releases.parsedDate),
              let signature = value["materialSignature"]?.text, signature.utf16.count <= 128, case .array(let rows)? = value["steps"], rows.count <= 4_000 else { throw ReleaseReadiness.Failure.invalid }
        func optional(_ key: String) throws -> String? {
            guard let item = value[key], item != .null else { return nil }
            guard let text = item.text, !text.isEmpty, text.utf16.count <= 256 else { throw ReleaseReadiness.Failure.invalid }; return text
        }
        let steps = try rows.map(ReleaseReadiness.Step.init(json:))
        guard Set(steps.map(\.id)).count == steps.count else { throw ReleaseReadiness.Failure.invalid }
        let scope = try RecoveryGuidance.Scope(accountId: accountId, appId: appId)
        // A status saved without its observations still shows, but lends none to a later partial read.
        var parts: ReleaseReadiness.Parts = [], observations = JSONText.object([])
        if let raw = value["parts"], raw != .null {
            guard case .number(let number) = raw, let bits = Int(exactly: number), ReleaseReadiness.Parts.all.isSuperset(of: .init(rawValue: bits)), case .object(let pairs)? = value["observations"] else { throw ReleaseReadiness.Failure.invalid }
            // A status saved before a part gained a key still reads; the new key starts as unread.
            let expected = ReleaseReadiness.Parts.keys.filter { ReleaseReadiness.Parts(rawValue: bits).contains($0.part) }, names = Set(pairs.map(\.0))
            guard pairs.count == names.count, names.isSubset(of: Set(expected.map(\.key))), Set(expected.map(\.key)).subtracting(names).isSubset(of: ["reviewMissing"]) else { throw ReleaseReadiness.Failure.invalid }
            parts = .init(rawValue: bits); observations = .object(pairs + expected.filter { !names.contains($0.key) }.map { ($0.key, $0.unknown) })
        }
        return (.init(scope: scope, plan: plan, steps: steps, materialSignature: signature, targetVersionId: try optional("targetVersionId"), targetState: try optional("targetState"),
                      parts: parts, observations: observations), checked)
    }
}

extension WorkspaceSession {
    static let releaseStatusNamespace = "release_status"
    static let releaseStatusBytes = 2 * 1_024 * 1_024
    /// The permanent per-app lock for saved release status; its empty file is never removed.
    func releaseStatusMutex(accountId: String, appId: String) throws -> URL {
        _ = try RecoveryGuidance.Scope(accountId: accountId, appId: appId)
        return try storeAccess { $0.directory.appendingPathComponent("release_status_\(JSONText.string("\(accountId)\u{0}\(appId)").rawSHA256.prefix(32)).mutex") }
    }
    func releaseStatusScope(accountId: String, appId: String) throws {
        guard try accounts().contains(where: { $0.id == accountId && $0.appIds.contains(appId) }) else { throw ReleaseReadiness.Failure.invalid }
    }
    /// The saved status for this plan, when its app is still connected.
    func savedReleaseReadiness(accountId: String, appId: String, planToken: String) -> (snapshot: ReleaseReadinessSnapshot, checkedAt: Date)? {
        do {
            try releaseStatusScope(accountId: accountId, appId: appId)
            guard let saved = try storeAccess({ try $0.document(namespace: Self.releaseStatusNamespace, key: "\(accountId):\(appId)") }), saved.payload.count <= Self.releaseStatusBytes else { return nil }
            return try ReleaseReadinessSnapshot.saved(JSONText.parse(saved.payload), accountId: accountId, appId: appId, planToken: planToken)
        } catch { return nil }
    }
    /// Saves a confirmed status unless a newer one for the same app is already saved. The comparison and replacement share one lock.
    /// A failed write only loses a convenience; the next read saves again.
    func saveReleaseReadiness(_ snapshot: ReleaseReadinessSnapshot, checkedAt: Date) {
        let accountId = snapshot.scope.accountId, appId = snapshot.scope.appId, key = "\(accountId):\(appId)"
        do {
            try releaseStatusScope(accountId: accountId, appId: appId)
            let payload = snapshot.json(checkedAt: checkedAt).data
            guard payload.count <= Self.releaseStatusBytes else { return }
            try FileMutex.withLock(releaseStatusMutex(accountId: accountId, appId: appId)) {
                try releaseStatusScope(accountId: accountId, appId: appId)
                try storeAccess { store in try store.transaction { current in
                    if let previous = try current(Self.releaseStatusNamespace, key), let value = try? JSONText.parse(previous.payload),
                       let saved = value["checkedAt"]?.text.flatMap(Releases.parsedDate), saved > checkedAt { return [] }
                    return [.put(namespace: Self.releaseStatusNamespace, key: key, json: payload)]
                } }
            }
        } catch { /* Saved status is a convenience; the live read stays authoritative. */ }
    }

    /// Reads release status in the background for the apps planned most recently, a few seconds apart, and saves it for the next visit.
    /// Apps checked within `maxAge` are skipped. Reads use the shared short-lived cache, so an open Release page and this warm-up share requests.
    public func warmReleaseStatus(limit: Int = 4, spacing: Duration = .seconds(3), maxAge: TimeInterval = 600, now: @escaping @Sendable () -> Date = Date.init) async {
        await AppleReadPriority.$current.withValue(.background) { await warmingReleaseStatus(limit: limit, spacing: spacing, maxAge: maxAge, now: now) }
    }
    private func warmingReleaseStatus(limit: Int, spacing: Duration, maxAge: TimeInterval, now: @escaping @Sendable () -> Date) async {
        guard let accounts = try? accounts() else { return }
        let plans = ((try? storeAccess { try plansDocument($0).plans }) ?? []).compactMap(ReleasePlan.init)
            .filter { plan in accounts.contains { $0.id == plan.accountId && $0.appIds.contains(plan.appId) } }
            .sorted { $0.updatedAt.compare($1.updatedAt, locale: Locale(identifier: "en_US")) == .orderedDescending }
        for candidate in plans.prefix(max(0, limit)) {
            guard !Task.isCancelled, let account = accounts.first(where: { $0.id == candidate.accountId }),
                  let plan = try? releasePlan(accountId: candidate.accountId, appId: candidate.appId), plan.token == candidate.token else { continue }
            if let saved = rememberedReleaseReadiness(accountId: plan.accountId, appId: plan.appId, planToken: plan.token), now().timeIntervalSince(saved.checkedAt) < maxAge { continue }
            do { try await Task.sleep(for: spacing) } catch { return }
            do {
                let client = try readClient(for: account)
                let value = try await releaseReadiness(account: account, appId: plan.appId, revisionId: plan.sourceRevisionId, planToken: plan.token, client: client)
                rememberReleaseReadiness(value, checkedAt: now())
            } catch { if Task.isCancelled { return } }
        }
    }
}
