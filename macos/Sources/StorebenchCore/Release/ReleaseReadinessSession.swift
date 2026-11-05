import Foundation

public struct ReleaseReadinessSnapshot: Sendable {
    public let scope: RecoveryGuidance.Scope, plan: ReleasePlan, steps: [ReleaseReadiness.Step]
    public let materialSignature: String
    public let targetVersionId: String?
    /// The target version's raw App Store Connect state, read with it; nil when Apple has no such version or it could not be read.
    public let targetState: String?
    /// The parts whose Apple observations this status holds, read now or carried from an earlier read of the same target. Every other part is Unknown.
    public let parts: ReleaseReadiness.Parts
    /// Apple observations by input key, for the parts held.
    let observations: JSONText
    /// The saved local material of a live read; nil for a status only remembered, which can lend its observations but not take others.
    let local: JSONText?
    public init(scope: RecoveryGuidance.Scope, plan: ReleasePlan, steps: [ReleaseReadiness.Step], materialSignature: String, targetVersionId: String?, targetState: String?,
                parts: ReleaseReadiness.Parts = [], observations: JSONText = .object([]), local: JSONText? = nil) {
        self.scope = scope; self.plan = plan; self.steps = steps; self.materialSignature = materialSignature; self.targetVersionId = targetVersionId; self.targetState = targetState
        self.parts = parts; self.observations = observations; self.local = local
    }
    /// Builds the steps from local material and the observations held, so unread parts stay Unknown.
    init(scope: RecoveryGuidance.Scope, plan: ReleasePlan, local: JSONText, observations: JSONText, parts: ReleaseReadiness.Parts, materialSignature: String) throws {
        let input = ReleaseReadiness.input(local: local, observations: observations)
        let target = WorkspaceSession.items(input["appleVersions"]).first { TextSemantics.same($0["platform"]?.text, plan.platform) && TextSemantics.same($0["number"]?.text, plan.targetVersion) }
        self.init(scope: scope, plan: plan, steps: ReleaseReadiness.completedEarlier(try ReleaseReadiness.steps(input, scope: scope), input: input, plan: plan), materialSignature: materialSignature,
                  targetVersionId: target?["id"]?.text, targetState: target?["state"]?.text.flatMap { $0.isEmpty ? nil : $0 }, parts: parts, observations: observations, local: local)
    }
    public func count(_ state: ReleaseReadiness.State) -> Int { steps.filter { $0.state == state }.count }
    /// This read's parts over an earlier status for the same plan. App-level parts carry over; target-version parts only for the same target version,
    /// and media statuses only for the same saved material. Parts neither read holds stay Unknown. A status that cannot be merged is returned unchanged.
    public func merging(_ earlier: ReleaseReadinessSnapshot?) -> ReleaseReadinessSnapshot {
        guard let earlier, let local, earlier.scope.accountId == scope.accountId, earlier.scope.appId == scope.appId, TextSemantics.same(earlier.plan.token, plan.token) else { return self }
        var held = parts, values = observations
        func carry(_ part: ReleaseReadiness.Parts) {
            guard !parts.contains(part), earlier.parts.contains(part) else { return }
            for entry in ReleaseReadiness.Parts.keys where entry.part == part { values = values.setting(entry.key, earlier.observations[entry.key] ?? entry.unknown) }
            held.insert(part)
        }
        carry(.versions)
        let sameTarget = (try? ReleaseReadinessSnapshot(scope: scope, plan: plan, local: local, observations: values, parts: held, materialSignature: materialSignature))
            .map { TextSemantics.same($0.targetVersionId, earlier.targetVersionId) } ?? false
        if sameTarget {
            for part: ReleaseReadiness.Parts in [.versionText, .build, .review] { carry(part) }
            if TextSemantics.same(materialSignature, earlier.materialSignature) { carry(.media) }
        }
        for part: ReleaseReadiness.Parts in [.appInfoText, .appConfiguration, .ageRating, .accessibility, .availability] { carry(part) }
        return (try? ReleaseReadinessSnapshot(scope: scope, plan: plan, local: local, observations: values, parts: held, materialSignature: materialSignature)) ?? self
    }
}

extension WorkspaceSession {
    private struct ReadinessMaterial: Sendable {
        let scope: RecoveryGuidance.Scope, plan: ReleasePlan, source: Revision, raw: JSONText, draft: JSONText, signature: String
        var version: JSONText? { WorkspaceSession.items(WorkspaceSession.overlayJSON(raw, draft: draft)["versions"]).first { TextSemantics.same($0["id"]?.text, plan.baseVersionId) } }
    }
    @inline(never) private func readinessMaterial(accountId: String, appId: String, revisionId: String, planToken: String) throws -> ReadinessMaterial {
        let scope = try RecoveryGuidance.Scope(accountId: accountId, appId: appId)
        return try withReleaseTextPlan(accountId: accountId, appId: appId, revisionId: revisionId, token: planToken) { plan, store in
            _ = try archivedRevision(accountId: accountId, appId: appId, id: revisionId, store: store)
            return try readReleaseTextDocuments(accountId: accountId, appId: appId, revisionId: revisionId, store: store) { source, draft in
                let key = try TextDrafts.key(accountId: accountId, appId: appId, revisionId: revisionId)
                guard let saved = try store.document(namespace: "revisions", key: key), source.id == plan.sourceRevisionId, source.app.id == appId,
                      source.versions.contains(where: { $0.id == plan.baseVersionId && $0.platform == plan.platform }) else { throw ReleaseTextFailure.invalid }
                let raw = try JSONText.parse(saved.payload)
                try LanguageDrafts.validateTextDocument(draft)
                let draftRevision = try store.document(namespace: "drafts", key: key)?.revision ?? 0
                let signature = JSONText.array([.string(plan.token), .number(Double(saved.revision)), .number(Double(draftRevision)), .string(raw.sha256), .string(draft.sha256)]).sha256
                return ReadinessMaterial(scope: scope, plan: plan, source: source, raw: raw, draft: draft, signature: signature)
            }
        }
    }
    /// Reads saved material and independent Apple observations outside all local write locks, then rechecks the captured material.
    /// The signature of the saved material a status read covers. Local only; no Apple request.
    public func releaseMaterialSignature(accountId: String, appId: String, revisionId: String, planToken: String) throws -> String {
        try readinessMaterial(accountId: accountId, appId: appId, revisionId: revisionId, planToken: planToken).signature
    }
    /// Reads only `parts` at Apple; a version-scoped part also reads the app's versions to find the target. Unread parts stay Unknown until merged
    /// with an earlier status. Without a client every requested part is observed as Unknown.
    public func releaseReadiness(account: Account, appId: String, revisionId: String, planToken: String, client: AppStoreConnectClient?, parts requested: ReleaseReadiness.Parts = .all) async throws -> ReleaseReadinessSnapshot {
        try Task.checkCancellation()
        let material = try readinessMaterial(accountId: account.id, appId: appId, revisionId: revisionId, planToken: planToken)
        let local = try readinessLocalInput(material)
        let parts = requested.intersection(.all).union(requested.isDisjoint(with: ReleaseReadiness.Parts.versionScoped) ? [] : .versions)
        var read: [(String, JSONText)] = []
        if let client, !parts.isEmpty {
            try requirePublishingAccount(account, appId: appId, client: client)
            async let availability: [(String, JSONText)] = parts.contains(.availability) ? [("currentAvailability", readinessAvailability(appId: appId, client: client))] : []
            async let accessibility: [(String, JSONText)] = parts.contains(.accessibility) ? [("accessibility", readinessAccessibility(appId: appId, client: client))] : []
            async let information = readinessInformation(appId: appId, parts: parts, client: client)
            async let version = readinessVersion(material: material, parts: parts, client: client)
            read = try await availability + accessibility + information + version
            try requirePublishingAccount(account, appId: appId, client: client)
        }
        try Task.checkCancellation()
        let latest = try readinessMaterial(accountId: account.id, appId: appId, revisionId: revisionId, planToken: planToken)
        guard TextSemantics.same(latest.signature, material.signature) else { throw ReleaseTextFailure.stale }
        let observations = JSONText.object(ReleaseReadiness.Parts.keys.filter { parts.contains($0.part) }.map { entry in (entry.key, read.last { $0.0 == entry.key }?.1 ?? entry.unknown) })
        return try .init(scope: material.scope, plan: material.plan, local: local, observations: observations, parts: parts, materialSignature: material.signature)
    }
    @inline(never) private func readinessLocalInput(_ material: ReadinessMaterial) throws -> JSONText {
        let saved = (try? sectionChecks(accountId: material.plan.accountId, appId: material.plan.appId)) ?? [:]
        func check(_ area: AppleProblem.Area) -> JSONText {
            saved[area].map { .object([("answered", .bool($0.answered)), ("detail", .string($0.detail)), ("checkedAt", .string($0.checkedAt))]) } ?? .string("unknown")
        }
        guard let version = material.version else { throw ReleaseTextFailure.invalid }
        let localizations = Self.items(version["localizations"]), infos = Self.items(Self.overlayJSON(material.raw, draft: material.draft)["appInfos"]).flatMap { Self.items($0["localizations"]) }
        guard Set(localizations.compactMap { $0["id"]?.text.map { Data($0.utf8) } }).count == localizations.count else { throw ReleaseTextFailure.invalid }
        // An app's first version on a platform has no What's New at Apple, so it is neither required nor compared.
        let first = try isFirstVersion(accountId: material.plan.accountId, appId: material.plan.appId, platform: material.plan.platform, number: material.plan.targetVersion)
        let languages = try ReleaseMaterial.languages(source: material.raw, draft: material.draft, versionId: material.plan.baseVersionId, requireWhatsNew: !first).map { summary -> JSONText in
            guard let locale = localizations.first(where: { TextSemantics.same($0["fields"]?["locale"]?.text, summary.locale) }), let id = locale["id"]?.text else { throw ReleaseTextFailure.invalid }
            let candidates = infos.filter { TextSemantics.same($0["fields"]?["locale"]?.text, summary.locale) }
            func fields(_ record: JSONText) -> JSONText {
                var value = record["fields"] ?? .object([])
                if case .object(let entries)? = material.draft["texts"]?[record["id"]?.text ?? ""] { for (key, text) in entries { value = value.setting(key, text) } }
                return first && value["whatsNew"] != nil ? value.setting("whatsNew", .string("")) : value
            }
            let related: [(String, TextDrafts.Scope)] = [(id, .version)] + candidates.compactMap { $0["id"]?.text.map { ($0, .appInfo) } }
            let reviews = related.flatMap { id, scope in TextDrafts.fields(scope).compactMap { CopiedText.review(source: material.source, draft: material.draft, scope: scope, versionId: material.plan.baseVersionId, targetId: id, field: $0) } }.filter(\.needsReview)
            var result = JSONText.object([("material", summary.json), ("fields", fields(locale)), ("sourceReview", .object([
                ("stale", .number(Double(reviews.filter { !$0.sourceLocale.isEmpty }.count))), ("unavailable", .number(Double(reviews.filter { $0.sourceLocale.isEmpty }.count)))]))])
            if candidates.count == 1 { result = result.setting("appInfoFields", fields(candidates[0])) }
            return result
        }
        return .object([("root", .string(material.scope.root)), ("target", .object([("platform", .string(material.plan.platform)), ("number", .string(material.plan.targetVersion))])),
            ("local", .array(languages)), ("appleVersions", .string("unknown")), ("appleLocales", .string("unknown")), ("appleAppInfoLocales", .string("unknown")),
            ("appConfiguration", .string("unknown")), ("ageRating", .string("unknown")), ("accessibility", .string("unknown")), ("reviewInformation", .string("unknown")),
            ("attachedBuild", .string("unknown")), ("exportCompliance", .object([("kind", .string("unknown"))])), ("currentAvailability", .string("unknown")),
            ("privacyCheck", check(.privacy)), ("taxCheck", check(.tax))])
    }
    private func readinessAvailability(appId: String, client: AppStoreConnectClient) async throws -> JSONText {
        do {
            let regions = try await availabilitySnapshot(appId: appId, client: client).territories
            return .object([("selected", .array(regions.filter(\.available).map { .string($0.id) }.sorted { $0.text! < $1.text! })),
                ("unselected", .array(regions.filter { !$0.available }.map { .string($0.id) }.sorted { $0.text! < $1.text! }))])
        } catch { try Task.checkCancellation(); return .string("unknown") }
    }
    private func readinessAccessibility(appId: String, client: AppStoreConnectClient) async throws -> JSONText {
        do {
            let declarations = try AccessibilityDeclarations.scoped(await client.list("/v1/apps/\(appId)/accessibilityDeclarations?limit=200"), appId: appId)
            return .object([("published", .number(Double(declarations.filter { $0.attributes?["state"]?.string == "PUBLISHED" }.count))),
                ("drafts", .number(Double(declarations.filter { $0.attributes?["state"]?.string == "DRAFT" }.count)))])
        } catch { try Task.checkCancellation(); return .string("unknown") }
    }
    private func readinessInformation(appId: String, parts: ReleaseReadiness.Parts, client: AppStoreConnectClient) async throws -> [(String, JSONText)] {
        guard !parts.isDisjoint(with: ReleaseReadiness.Parts.appInfoScoped) else { return [] }
        let infos: [AppStoreConnectClient.Resource]
        do {
            infos = try await client.list("/v1/apps/\(appId)/appInfos?include=app&limit=200")
            var seen = Set<Data>()
            guard infos.allSatisfy({ $0.type == "appInfos" && AppOverviewMaterial.identifier($0.id) && seen.insert(Data($0.id.utf8)).inserted && Apple.owned($0, "app", "apps", appId) }) else { throw ReleaseReadiness.Failure.invalid }
        } catch { try Task.checkCancellation(); return [] }
        let editable = infos.filter { Apple.editable.contains(Apple.state($0)) }, selected = editable.count == 1 ? editable[0] : infos.count == 1 ? infos[0] : nil
        async let locales: [(String, JSONText)] = parts.contains(.appInfoText) ? [("appleAppInfoLocales", readinessInfoLocales(infos, client: client))] : []
        async let configuration: [(String, JSONText)] = parts.contains(.appConfiguration) ? [("appConfiguration", readinessConfiguration(appId: appId, info: selected, empty: infos.isEmpty, client: client))] : []
        async let rating: [(String, JSONText)] = parts.contains(.ageRating) ? [("ageRating", readinessAgeRating(info: selected, empty: infos.isEmpty, client: client))] : []
        return try await locales + configuration + rating
    }
    private func readinessInfoLocales(_ infos: [AppStoreConnectClient.Resource], client: AppStoreConnectClient) async throws -> JSONText {
        do {
            var records: [[JSONText]] = []
            for info in infos {
                let items = try await client.list("/v1/appInfos/\(info.id)/appInfoLocalizations?limit=200")
                records.append(try readinessLocales(items, type: "appInfoLocalizations", owner: "appInfo", ownerType: "appInfos", ownerId: info.id))
            }
            return try ReleaseReadiness.consistentAppInfoLocales(records).map(JSONText.array) ?? .string("unknown")
        } catch { try Task.checkCancellation(); return .string("unknown") }
    }
    private func readinessConfiguration(appId: String, info: AppStoreConnectClient.Resource?, empty: Bool, client: AppStoreConnectClient) async throws -> JSONText {
        guard let info else { return .string(empty ? "missing" : "unknown") }
        do {
            async let appRead = client.get("/v1/apps/\(appId)")
            async let categoryRead = client.get("/v1/appInfos/\(info.id)?include=app,\(AppInformation.categoryFields.joined(separator: ","))")
            let (apps, categories) = try await (appRead, categoryRead)
            guard apps.count == 1, apps[0].type == "apps", apps[0].id == appId, categories.count == 1, categories[0].type == "appInfos", categories[0].id == info.id, Apple.owned(categories[0], "app", "apps", appId) else { throw ReleaseReadiness.Failure.invalid }
            for key in AppInformation.categoryFields {
                if let relation = categories[0].relationships?[key] {
                    guard case .object(let fields) = relation else { throw ReleaseReadiness.Failure.invalid }
                    if let value = fields["data"], value != .null { guard let owner = Apple.owner(categories[0], key), owner.type == "appCategories" else { throw ReleaseReadiness.Failure.invalid } }
                }
            }
            let present = !(Apple.owner(categories[0], "primaryCategory")?.id ?? "").isEmpty && ["DOES_NOT_USE_THIRD_PARTY_CONTENT", "USES_THIRD_PARTY_CONTENT"].contains(apps[0].attributes?["contentRightsDeclaration"]?.string ?? "")
            return .string(present ? "present" : "missing")
        } catch { try Task.checkCancellation(); return .string("unknown") }
    }
    private func readinessAgeRating(info: AppStoreConnectClient.Resource?, empty: Bool, client: AppStoreConnectClient) async throws -> JSONText {
        guard let info else { return .string(empty ? "missing" : "unknown") }
        do {
            let values = try await client.get("/v1/appInfos/\(info.id)/ageRatingDeclaration")
            guard values.count <= 1, values.allSatisfy({ $0.type == "ageRatingDeclarations" && AppOverviewMaterial.identifier($0.id) && ($0.relationships?["appInfo"] == nil || Apple.owned($0, "appInfo", "appInfos", info.id)) }) else { throw ReleaseReadiness.Failure.invalid }
            // Apple returns the declaration before its questions are answered; only a complete one lets a version be added for review.
            return .string(values.isEmpty ? "missing" : AgeRating.unanswered(Planner.resource(values[0])["attributes"]).isEmpty ? "present" : "incomplete")
        } catch { try Task.checkCancellation(); return .string("unknown") }
    }
    private func readinessLocales(_ resources: [AppStoreConnectClient.Resource], type: String, owner: String, ownerType: String, ownerId: String) throws -> [JSONText] {
        var ids = Set<Data>(), locales = Set<Data>()
        guard resources.count <= 2000 else { throw ReleaseReadiness.Failure.invalid }
        return try resources.map { item in
            guard item.type == type, AppOverviewMaterial.identifier(item.id), ids.insert(Data(item.id.utf8)).inserted, Apple.within(item, owner, ownerType, ownerId),
                  let locale = item.attributes?["locale"]?.string, !locale.isEmpty, locale.utf16.count <= 256, locales.insert(Data(locale.utf8)).inserted else { throw ReleaseReadiness.Failure.invalid }
            return .object([("locale", .string(locale)), ("fields", Planner.resource(item)["attributes"] ?? .object([]))])
        }
    }
    /// The app's versions, each owned by the app with a platform and number, and the one matching the plan's target.
    private static func scopedVersions(_ versions: [AppStoreConnectClient.Resource], appId: String, plan: ReleasePlan) throws -> (all: [AppStoreConnectClient.Resource], target: AppStoreConnectClient.Resource?) {
        var seen = Set<Data>()
        guard versions.count <= 2000, versions.allSatisfy({ item in
            item.type == "appStoreVersions" && AppOverviewMaterial.identifier(item.id) && seen.insert(Data(item.id.utf8)).inserted && Apple.owned(item, "app", "apps", appId) &&
            item.attributes?["platform"]?.string.map { !$0.isEmpty && $0.utf16.count <= 100 } == true &&
            item.attributes?["versionString"]?.string.map { !$0.isEmpty && $0.utf16.count <= 100 } == true
        }) else { throw ReleaseReadiness.Failure.invalid }
        let matching = versions.filter { $0.attributes?["platform"]?.string == plan.platform && $0.attributes?["versionString"]?.string == plan.targetVersion }
        guard matching.count <= 1 else { throw ReleaseReadiness.Failure.invalid }
        return (versions, matching.first)
    }
    /// One uncached read of the target version's Apple state, for frequent checks between full status reads. Nil when Apple has no such version.
    public func releaseVersionState(account: Account, plan: ReleasePlan) async throws -> String? {
        try Task.checkCancellation()
        let client = try client(for: account)
        try requirePublishingAccount(account, appId: plan.appId, client: client)
        let versions = try await client.list("/v1/apps/\(plan.appId)/appStoreVersions?include=app&limit=200")
        try requirePublishingAccount(account, appId: plan.appId, client: client)
        return try Self.scopedVersions(versions, appId: plan.appId, plan: plan).target.map(Apple.state).flatMap { $0.isEmpty ? nil : $0 }
    }
    /// The last confirmed status per saved plan, kept in memory and in the encrypted database so a revisited release opens with it while it is read again.
    public func rememberReleaseReadiness(_ snapshot: ReleaseReadinessSnapshot, checkedAt: Date) {
        guard (try? releaseStatusScope(accountId: snapshot.scope.accountId, appId: snapshot.scope.appId)) != nil else { return }
        let key = Self.releaseStatusKey(snapshot.scope.accountId, snapshot.scope.appId, snapshot.plan.token)
        if let current = releaseStatusMemory.value(for: key), current.checkedAt > checkedAt { return }
        releaseStatusMemory.insert((snapshot, checkedAt), for: key, cost: Self.releaseStatusCost(snapshot))
        saveReleaseReadiness(snapshot, checkedAt: checkedAt)
    }
    /// This session's newest status for the plan, else the one saved by an earlier session.
    public func rememberedReleaseReadiness(accountId: String, appId: String, planToken: String) -> (snapshot: ReleaseReadinessSnapshot, checkedAt: Date)? {
        guard (try? releaseStatusScope(accountId: accountId, appId: appId)) != nil else { return nil }
        let key = Self.releaseStatusKey(accountId, appId, planToken)
        if let value = releaseStatusMemory.value(for: key) { return value }
        guard let saved = savedReleaseReadiness(accountId: accountId, appId: appId, planToken: planToken) else { return nil }
        releaseStatusMemory.insert(saved, for: key, cost: Self.releaseStatusCost(saved.snapshot)); return saved
    }
    private static func releaseStatusCost(_ snapshot: ReleaseReadinessSnapshot) -> Int { 4_096 + snapshot.steps.count * 512 + snapshot.observations.data.count + (snapshot.local?.data.count ?? 0) }
    private static func releaseStatusKey(_ accountId: String, _ appId: String, _ token: String) -> String { JSONText.array([.string(accountId), .string(appId), .string(token)]).stringify() }
    private func readinessVersion(material: ReadinessMaterial, parts: ReleaseReadiness.Parts, client: AppStoreConnectClient) async throws -> [(String, JSONText)] {
        guard !parts.isDisjoint(with: ReleaseReadiness.Parts.versionScoped) else { return [] }
        do {
            let (versions, target) = try Self.scopedVersions(await client.list("/v1/apps/\(material.scope.appId)/appStoreVersions?include=app&limit=200"), appId: material.scope.appId, plan: material.plan)
            var result: [(String, JSONText)] = [("appleVersions", .array(versions.map { .object([("id", .string($0.id)), ("platform", .string($0.attributes?["platform"]?.string ?? "")),
                ("number", .string($0.attributes?["versionString"]?.string ?? "")), ("state", .string(Apple.state($0))), ("releaseType", .string($0.attributes?["releaseType"]?.string ?? "")), ("copyright", .string($0.attributes?["copyright"]?.string ?? ""))]) }))]
            guard let version = target else { return result }
            async let locales: [(String, JSONText)] = parts.isDisjoint(with: [.versionText, .media]) ? [] : readinessVersionLocales(material: material, parts: parts, version: version, client: client)
            async let review: [(String, JSONText)] = parts.contains(.review) ? readinessReview(version: version, client: client) : []
            async let build: [(String, JSONText)] = parts.contains(.build) ? readinessBuild(version: version, appId: material.scope.appId, platform: material.plan.platform, client: client) : []
            let (languages, detail, binary) = try await (locales, review, build)
            result += languages + detail + binary; return result
        } catch { try Task.checkCancellation(); return [] }
    }
    /// Media is read only for the planned languages, six at a time.
    private func readinessVersionLocales(material: ReadinessMaterial, parts: ReleaseReadiness.Parts, version: AppStoreConnectClient.Resource, client: AppStoreConnectClient) async throws -> [(String, JSONText)] {
        do {
            let resources = try await client.list("/v1/appStoreVersions/\(version.id)/appStoreVersionLocalizations?limit=200")
            let locales = try readinessLocales(resources, type: "appStoreVersionLocalizations", owner: "appStoreVersion", ownerType: "appStoreVersions", ownerId: version.id)
            var result: [(String, JSONText)] = parts.contains(.versionText) ? [("appleLocales", .array(locales))] : []
            guard parts.contains(.media) else { return result }
            let planned = Self.items(try readinessLocalInput(material)["local"]).compactMap { $0["material"]?["locale"]?.text }
            let languages = Self.items(material.version?["localizations"]).filter { language in planned.contains { TextSemantics.same($0, language["fields"]?["locale"]?.text) } }
            let platform = version.attributes?["platform"]?.string ?? ""
            var media: [(String, JSONText)] = []
            for start in stride(from: 0, to: languages.count, by: 6) {
                let statuses = try await withThrowingTaskGroup(of: (String, ReleaseMediaStatus.Status).self) { group in
                    for language in languages[start..<min(start + 6, languages.count)] {
                        let code = language["fields"]?["locale"]?.text ?? "", remote = resources.first { TextSemantics.same($0.attributes?["locale"]?.string, code) }
                        group.addTask {
                            try Task.checkCancellation()
                            guard let remote else { return (code, .init(state: .blocked, detail: "This language is missing from the target Apple version, so its media cannot be present there.")) }
                            let snapshot: ReleaseMediaStatus.Snapshot?
                            do { snapshot = try await ReleaseMediaStatus.read(localizationId: remote.id, platform: platform, client: client) }
                            catch { try Task.checkCancellation(); snapshot = nil }
                            return (code, ReleaseMediaStatus.status(locale: language, draft: material.draft, apple: snapshot))
                        }
                    }
                    var result: [(String, ReleaseMediaStatus.Status)] = []
                    for try await status in group { result.append(status) }; return result
                }
                media += statuses.map { ($0.0, $0.1.record) }
            }
            result.append(("mediaStatus", .object(media))); return result
        } catch { try Task.checkCancellation(); return [] }
    }
    /// Whether Apple has complete App Review Information, and when it does not, which of App Store Connect's fields are empty.
    private func readinessReview(version: AppStoreConnectClient.Resource, client: AppStoreConnectClient) async throws -> [(String, JSONText)] {
        func missing(_ names: [String]) -> [(String, JSONText)] { [("reviewInformation", .string("missing")), ("reviewMissing", .array(names.map(JSONText.string)))] }
        do {
            guard let detail = try await reviewDetail(versionId: version.id, client: client) else { return missing(ReviewInformation().missing) }
            do { _ = try Self.reviewInformationDigest(detail) } catch { return missing(ReviewInformation(Planner.resource(detail)["attributes"]).missing) }
            let attachments = try await client.list("/v1/appStoreReviewDetails/\(detail.id)/appStoreReviewAttachments?limit=200")
            do { _ = try Self.attachmentsDigest(attachments, detailId: detail.id) } catch { return missing(["Attachment (still processing at Apple)"]) }
            return [("reviewInformation", .string("ready")), ("reviewMissing", .array([]))]
        } catch { try Task.checkCancellation(); return [("reviewInformation", .string("unknown"))] }
    }
    private func readinessBuild(version: AppStoreConnectClient.Resource, appId: String, platform: String, client: AppStoreConnectClient) async throws -> [(String, JSONText)] {
        do {
            let attached = try await client.get("/v1/appStoreVersions/\(version.id)/build")
            if attached.isEmpty { return [("attachedBuild", .string("missing")), ("exportCompliance", .object([("kind", .string("no-build"))]))] }
            guard attached.count == 1, AppOverviewMaterial.identifier(attached[0].id) else { throw ReleaseReadiness.Failure.invalid }
            // The app filter and its included owner confirm the attached build belongs to the app; no separate owner read is needed.
            let page = try await client.listWithIncluded("/v1/builds?filter%5Bapp%5D=\(appId)&filter%5Bid%5D=\(attached[0].id)&include=app%2CpreReleaseVersion&limit=200")
            let scoped = try await scopedOwners(page.data, type: "builds", appId: appId, list: client.list)
            guard scoped.count == 1, let build = scoped.first, build.id == attached[0].id else { throw ReleaseReadiness.Failure.invalid }
            let prereleases = page.included.filter { $0.type == "preReleaseVersions" && $0.id == Apple.owner(build, "preReleaseVersion")?.id }
            guard prereleases.count <= 1 else { throw ReleaseReadiness.Failure.invalid }
            let eligible = Self.eligible(build, included: page.included, version: version)
            let export = try await readinessExport(build: build, appId: appId, platform: platform, client: client)
            return [("attachedBuild", .string(eligible ? "eligible" : "ineligible")), ("exportCompliance", export)]
        } catch { try Task.checkCancellation(); return [] }
    }
    private func readinessExport(build: AppStoreConnectClient.Resource, appId: String, platform: String, client: AppStoreConnectClient) async throws -> JSONText {
        func observation(_ kind: String) -> JSONText { .object([("kind", .string(kind)), ("buildId", .string(build.id))]) }
        switch build.attributes?["usesNonExemptEncryption"] { case .bool(false)?: return observation("no-nonexempt"); case .null?: return observation("unanswered"); case .bool(true)?: break; default: return observation("unknown") }
        do {
            let linked = try TestFlightEncryption.observedDeclaration(try await WorkspaceSession.declarationLink(build.id) { try await client.get($0) })
            if let relation = build.relationships?["appEncryptionDeclaration"] {
                guard case .object(let fields) = relation else { return observation("unknown") }
                if let data = fields["data"] {
                    if data == .null { guard linked == nil else { return observation("unknown") } }
                    else { guard let owner = Apple.owner(build, "appEncryptionDeclaration"), owner.type == "appEncryptionDeclarations", TextSemantics.same(owner.id, linked) else { return observation("unknown") } }
                }
            }
            guard let linked else { return observation("unassigned") }
            let declarations = try Self.scopedDeclarations(try await WorkspaceSession.declarationReads(appId) { try await client.list($0) }, appId: appId)
            guard let declaration = declarations.first(where: { TextSemantics.same($0.id, linked) }), let state = declaration.attributes?["appEncryptionDeclarationState"]?.string else { return observation("unknown") }
            if !TestFlightEncryption.declarationFits(declaration.attributes?["platform"]?.string, platform: platform) { return observation("invalid") }
            return observation(state == "APPROVED" ? "approved" : ["CREATED", "IN_REVIEW"].contains(state) ? "reviewing" : "invalid")
        } catch { try Task.checkCancellation(); return observation("unknown") }
    }
}

extension ReleaseReadiness {
    /// States only a version that passed App Review reaches.
    static let approvedStates: Set<String> = ["PENDING_DEVELOPER_RELEASE", "PROCESSING_FOR_DISTRIBUTION", "PROCESSING_FOR_APP_STORE", "READY_FOR_DISTRIBUTION", "READY_FOR_SALE",
                                              "REPLACED_WITH_NEW_VERSION", "REMOVED_FROM_SALE", "DEVELOPER_REMOVED_FROM_SALE"]
    /// A new version of an app Apple already approved starts with the app-level answers it kept: categories, age rating, published
    /// accessibility declarations, and the App Privacy and Tax Category answers that approval required. Those show as done; anything
    /// missing or unread keeps its own state.
    static func completedEarlier(_ steps: [Step], input: JSONText, plan: ReleasePlan) -> [Step] {
        let approvedEarlier = WorkspaceSession.items(input["appleVersions"]).contains { version in
            !(TextSemantics.same(version["platform"]?.text, plan.platform) && TextSemantics.same(version["number"]?.text, plan.targetVersion))
                && approvedStates.contains(version["state"]?.text ?? "")
        }
        // App Privacy is done only when the last read of App Store Connect showed the answers published, Tax Category when it showed a category.
        let privacyPublished = input["privacyCheck"]?["answered"] == .bool(true), taxRead = input["taxCheck"]?["answered"] == .bool(true)
        let accessibility = input["accessibility"]
        let declared = accessibility?["drafts"] == .number(0) && { if case .number(let count)? = accessibility?["published"] { return count > 0 }; return false }()
        return steps.map { step in
            func done(_ detail: String? = nil) -> Step {
                var next = Step(id: step.id, label: step.label, detail: detail ?? step.detail, href: step.href, action: step.action, state: .ready, territories: step.territories, guideHref: step.guideHref)
                next.issues = step.issues; return next
            }
            switch (step.id, step.state) {
            case ("app-configuration", .review), ("age-rating", .review): return done()
            case ("accessibility", .review) where declared: return done()
            case ("privacy", .manual) where privacyPublished:
                return done("\(input["privacyCheck"]?["detail"]?.text ?? "Published") in App Store Connect · checked \(LibraryOverview.timestamp(input["privacyCheck"]?["checkedAt"]?.text ?? "")). Storebench read this with your Apple ID; change it under App Privacy only if the data the app collects changes.")
            case ("privacy", .manual) where approvedEarlier:
                return done("Answered for an earlier version Apple approved. Update them in App Store Connect, under App Privacy, only if this version changes what data the app collects.")
            case ("tax", .manual) where taxRead:
                return done("\(input["taxCheck"]?["detail"]?.text ?? "A category") in App Store Connect · checked \(LibraryOverview.timestamp(input["taxCheck"]?["checkedAt"]?.text ?? "")). Storebench read this with your Apple ID; change it under Tax Category only if the app's category changes.")
            case ("tax", .manual) where approvedEarlier:
                return done("Set for an earlier version Apple approved. Change it in App Store Connect, under Pricing and Availability, only if the app's category changed.")
            default: return step
            }
        }
    }
}

extension WorkspaceSession {
    /// True when no import holds another version of this platform: App Store Connect then shows no What's New for it.
    public func isFirstVersion(accountId: String, appId: String, platform: String, number: String) throws -> Bool {
        !(try revisions(accountId: accountId, appId: appId)).contains { revision in
            !revision.isLocalDraft && revision.versions.contains { $0.platform == platform && $0.number != number }
        }
    }
}
