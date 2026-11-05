import Foundation

public enum ReleaseTextFailure: Error, Equatable {
    case invalid, source, destination, stale, replacement, copied, limit, empty
    public var message: String {
        switch self {
        case .invalid: "Choose valid release languages and text fields."
        case .source: "The saved source language was not found in this release version."
        case .destination: "Choose other destination languages in the same release version."
        case .stale: "Saved release text, its source review or the version plan changed. Your edits are kept. Compare the latest save before reviewing again."
        case .replacement: "Turn on Replace filled fields when copying, or edit the filled field yourself."
        case .copied: "Copied fields must match nonempty saved source text."
        case .limit: "Release text exceeds the App Store text limit."
        case .empty: "There are no selected text changes to save."
        }
    }
}

public enum ReleaseText {
    public static let fields = ["whatsNew", "promotionalText"]
    public static func copySource(_ source: Values, into destination: Values, replace: Bool) -> (values: Values, copied: [String]) {
        var result = destination, copied: [String] = []
        for field in fields where !TextSemantics.trim(source[field]).isEmpty && (replace || TextSemantics.trim(destination[field]).isEmpty) {
            result[field] = source[field]; copied.append(field)
        }
        return (result, copied)
    }
    /// Typing into a filled field replaces it on purpose. Only copied text over filled fields needs the Replace choice.
    public static func replacesExisting(_ targets: [Target], replace: Bool) -> Bool {
        replace || !targets.contains { row in row.copied.contains { !TextSemantics.trim(row.baseline[$0]).isEmpty } }
    }
    public struct Values: Sendable, Equatable {
        public var whatsNew, promotionalText: String
        public init(whatsNew: String = "", promotionalText: String = "") { self.whatsNew = whatsNew; self.promotionalText = promotionalText }
        public subscript(_ field: String) -> String {
            get { field == "whatsNew" ? whatsNew : promotionalText }
            set { if field == "whatsNew" { whatsNew = newValue } else if field == "promotionalText" { promotionalText = newValue } }
        }
        public static func same(_ lhs: Self, _ rhs: Self) -> Bool { fields.allSatisfy { TextSemantics.same(lhs[$0], rhs[$0]) } }
        var json: JSONText { .object(fields.map { ($0, .string(self[$0])) }) }
        var valid: Bool { fields.allSatisfy { self[$0].utf16.count <= 10_000 } }
        public init(json: JSONText?) throws {
            guard let whatsNew = json?["whatsNew"]?.text, let promotion = json?["promotionalText"]?.text else { throw ReleaseTextFailure.invalid }
            self.init(whatsNew: whatsNew, promotionalText: promotion)
            guard valid else { throw ReleaseTextFailure.invalid }
        }
    }
    public struct Target: Sendable {
        public let locale: String
        public let baseline, values: Values
        public let copied: [String]
        public init(locale: String, baseline: Values, values: Values, copied: [String] = []) { self.locale = locale; self.baseline = baseline; self.values = values; self.copied = copied }
        var json: JSONText { .object([("locale", .string(locale)), ("baseline", baseline.json), ("values", values.json), ("copied", .array(copied.map(JSONText.string)))]) }
    }
    public struct Selection: Sendable {
        public let versionId, sourceLocale: String
        public let sourceBaseline: Values
        public let targets: [Target]
        public let replaceExisting: Bool
        public init(versionId: String, sourceLocale: String, sourceBaseline: Values, targets: [Target], replaceExisting: Bool = false) {
            self.versionId = versionId; self.sourceLocale = sourceLocale; self.sourceBaseline = sourceBaseline; self.targets = targets; self.replaceExisting = replaceExisting
        }
        var json: JSONText { .object([("versionId", .string(versionId)), ("sourceLocale", .string(sourceLocale)), ("sourceBaseline", sourceBaseline.json),
                                      ("targets", .array(targets.map(\.json))), ("replaceExisting", .bool(replaceExisting))]) }
        public init(json: JSONText?) throws {
            guard let versionId = json?["versionId"]?.text, let sourceLocale = json?["sourceLocale"]?.text,
                  case .array(let rows)? = json?["targets"], case .bool(let replace)? = json?["replaceExisting"] else { throw ReleaseTextFailure.invalid }
            let targets = try rows.map { row in
                guard let locale = row["locale"]?.text, case .array(let copied)? = row["copied"], copied.allSatisfy({ $0.text != nil }) else { throw ReleaseTextFailure.invalid }
                return Target(locale: locale, baseline: try Values(json: row["baseline"]), values: try Values(json: row["values"]), copied: copied.compactMap(\.text))
            }
            self.init(versionId: versionId, sourceLocale: sourceLocale, sourceBaseline: try Values(json: json?["sourceBaseline"]), targets: targets, replaceExisting: replace)
        }
    }
    public struct Change: Sendable, Equatable, Identifiable {
        public let localizationId, locale, field, before, after: String
        public let copied: Bool
        public var id: String { "\(localizationId):\(field)" }
        var json: JSONText { .object([("localizationId", .string(localizationId)), ("locale", .string(locale)), ("field", .string(field)),
                                      ("before", .string(before)), ("after", .string(after)), ("copied", .bool(copied))]) }
    }
    public struct Preview: Sendable, Equatable { public let changes: [Change]; public let fingerprint: String }
    public struct Row: Sendable, Identifiable {
        public let id, locale: String
        public let values: Values
        public let reviews: [String: CopiedText.Review]
        public init(id: String, locale: String, values: Values, reviews: [String: CopiedText.Review]) { self.id = id; self.locale = locale; self.values = values; self.reviews = reviews }
    }
    public struct Snapshot: Sendable { public let rows: [Row]; public let primaryLocale: String }
    struct Plan { let preview: Preview; let sourceId: String }
    /// Pure comparison; session APIs protect the current release plan and coordinate persistence.
    public static func preview(source: Revision, draft: JSONText, selection: Selection, release: ReleasePlan) throws -> Preview {
        try plan(source: source, draft: draft, selection: selection, release: release).preview
    }

    static func values(_ localization: Revision.Localization, draft: JSONText) -> Values {
        Values(whatsNew: draft["texts"]?[localization.id]?["whatsNew"]?.text ?? localization.fields["whatsNew"].map(WorkspaceSession.text) ?? "",
               promotionalText: draft["texts"]?[localization.id]?["promotionalText"]?.text ?? localization.fields["promotionalText"].map(WorkspaceSession.text) ?? "")
    }
    static func plan(source: Revision, draft: JSONText, selection: Selection, release: ReleasePlan) throws -> Plan {
        guard source.id == release.sourceRevisionId, source.app.id == release.appId, selection.versionId == release.baseVersionId else { throw ReleaseTextFailure.stale }
        guard selection.sourceBaseline.valid, !selection.targets.isEmpty, selection.targets.count <= 100,
              Set(selection.targets.map(\.locale)).count == selection.targets.count,
              selection.targets.allSatisfy({ $0.baseline.valid && $0.values.valid && Set($0.copied).count == $0.copied.count && Set($0.copied).isSubset(of: fields) }) else { throw ReleaseTextFailure.invalid }
        guard let version = WorkspaceSession.overlay(source, draft: draft).versions.first(where: { $0.id == selection.versionId }),
              Set(version.localizations.map(\.locale)).count == version.localizations.count else { throw ReleaseTextFailure.invalid }
        guard let original = version.localizations.first(where: { $0.locale == selection.sourceLocale }) else { throw ReleaseTextFailure.source }
        let sourceValues = values(original, draft: draft)
        guard Values.same(sourceValues, selection.sourceBaseline) else { throw ReleaseTextFailure.stale }
        var changes: [Change] = []
        for row in selection.targets {
            guard let target = version.localizations.first(where: { $0.locale == row.locale }), target.id != original.id else { throw ReleaseTextFailure.destination }
            let current = values(target, draft: draft)
            guard Values.same(current, row.baseline) else { throw ReleaseTextFailure.stale }
            for field in fields {
                let before = current[field], after = row.values[field], copied = row.copied.contains(field)
                if copied && (TextSemantics.trim(sourceValues[field]).isEmpty || !TextSemantics.same(after, sourceValues[field])) { throw ReleaseTextFailure.copied }
                if TextSemantics.same(before, after) { continue }
                guard TextDrafts.used(field, after) <= (TextDrafts.limits[field] ?? 0) else { throw ReleaseTextFailure.limit }
                guard selection.replaceExisting || TextSemantics.trim(before).isEmpty else { throw ReleaseTextFailure.replacement }
                changes.append(Change(localizationId: target.id, locale: row.locale, field: field, before: before, after: after, copied: copied))
            }
        }
        let evidence = changes.map { draft["textSources"]?[$0.localizationId]?[$0.field] ?? .null }
        let fingerprint = JSONText.object([("accountId", .string(release.accountId)), ("appId", .string(release.appId)), ("revisionId", .string(source.id)),
                                           ("plan", try JSONText.parse(Data(release.token.utf8))), ("request", selection.json),
                                           ("changes", .array(changes.map(\.json))), ("copiedSources", .array(evidence))]).sha256
        return Plan(preview: Preview(changes: changes, fingerprint: fingerprint), sourceId: original.id)
    }
    static func apply(_ plan: Plan, draft: JSONText) -> JSONText {
        var result = draft
        for change in plan.preview.changes {
            let texts = result["texts"] ?? .object([])
            var saved = texts[change.localizationId] ?? .object([])
            if case .object(let pairs) = saved { saved = .object(pairs.filter { TextDrafts.versionFields.contains($0.0) }) }
            result = result.setting("texts", texts.setting(change.localizationId, saved.setting(change.field, .string(change.after))))
            let sources = result["textSources"] ?? .object([])
            var markers = sources[change.localizationId] ?? .object([])
            if case .object(let pairs) = markers { markers = .object(pairs.filter { $0.0 != change.field }) }
            if change.copied {
                let marker = JSONText.object([("revisionId", .string(draft["revisionId"]?.text ?? "")), ("localizationId", .string(plan.sourceId)),
                                              ("copiedValue", .string(change.after)), ("reviewedValue", .string(change.after))])
                markers = markers.setting(change.field, marker)
            }
            if change.copied || sources[change.localizationId] != nil { result = result.setting("textSources", sources.setting(change.localizationId, markers)) }
        }
        return result
    }
}

/// Complete text snapshots captured inside the same atomic release-field write.
public struct ReleaseTextSaveReceipt: Sendable {
    public let scope: MediaDraftScope
    public let preview: ReleaseText.Preview
    public let before: [LanguageDrafts.Section]
    public let after: [LanguageDrafts.Section]
    public init(scope: MediaDraftScope, preview: ReleaseText.Preview, before: [LanguageDrafts.Section], after: [LanguageDrafts.Section]) {
        self.scope = scope; self.preview = preview; self.before = before; self.after = after
    }
}

extension WorkspaceSession {
    /// Release-plan protection always precedes draft protection, matching release edits and revision deletion.
    func withReleaseTextPlan<T>(accountId: String, appId: String, revisionId: String, token: String, _ action: (ReleasePlan, EncryptedDocumentStore) throws -> T) throws -> T {
        try requireHistoryScope(accountId: accountId, appId: appId)
        _ = try TextDrafts.key(accountId: accountId, appId: appId, revisionId: revisionId)
        return try storeAccess { store in
            try FileMutex.withLock(store.directory.appendingPathComponent("release_plans.mutex")) {
                guard let release = try plansDocument(store).plans.first(where: { $0["accountId"]?.text == accountId && $0["appId"]?.text == appId }).flatMap(ReleasePlan.init),
                      release.token == token, release.sourceRevisionId == revisionId else { throw ReleaseTextFailure.stale }
                return try action(release, store)
            }
        }
    }
    func readReleaseTextDocuments<T>(accountId: String, appId: String, revisionId: String, store: EncryptedDocumentStore,
                                              _ action: (Revision, JSONText) throws -> T) throws -> T {
        let key = try TextDrafts.key(accountId: accountId, appId: appId, revisionId: revisionId)
        let mutex = "draft_" + JSONText.string(key).rawSHA256.prefix(40)
        return try FileMutex.withLock(store.directory.appendingPathComponent("\(mutex).mutex")) {
            guard let saved = try store.document(namespace: "revisions", key: key) else { throw DraftFailure.sourceMissing }
            let source = try decodedRevision(saved, cacheKey: "direct/" + saved.key) { try JSONDecoder().decode(Revision.self, from: saved.payload) }
            let draft = try store.document(namespace: "drafts", key: key).map { try JSONText.parse($0.payload) } ?? TextDrafts.empty(revisionId)
            return try action(source, draft)
        }
    }
    public func releaseText(accountId: String, appId: String, revisionId: String, planToken: String) throws -> ReleaseText.Snapshot {
        try withReleaseTextPlan(accountId: accountId, appId: appId, revisionId: revisionId, token: planToken) { release, store in
            try readReleaseTextDocuments(accountId: accountId, appId: appId, revisionId: revisionId, store: store) { source, draft in
                guard source.id == revisionId, source.app.id == appId,
                      let version = Self.overlay(source, draft: draft).versions.first(where: { $0.id == release.baseVersionId }),
                      Set(version.localizations.map(\.locale)).count == version.localizations.count,
                      Set(version.localizations.map(\.id)).count == version.localizations.count else { throw ReleaseTextFailure.invalid }
                let rows = version.localizations.map { item in
                    ReleaseText.Row(id: item.id, locale: item.locale, values: ReleaseText.values(item, draft: draft),
                                    reviews: Dictionary(uniqueKeysWithValues: ReleaseText.fields.compactMap { field in
                                        CopiedText.review(source: source, draft: draft, scope: .version, versionId: version.id, targetId: item.id, field: field).map { (field, $0) }
                                    }))
                }
                return ReleaseText.Snapshot(rows: rows, primaryLocale: source.app.primaryLocale)
            }
        }
    }
    public func previewReleaseText(accountId: String, appId: String, revisionId: String, planToken: String, selection: ReleaseText.Selection) throws -> ReleaseText.Preview {
        try withReleaseTextPlan(accountId: accountId, appId: appId, revisionId: revisionId, token: planToken) { release, store in
            try readReleaseTextDocuments(accountId: accountId, appId: appId, revisionId: revisionId, store: store) { source, draft in
                try ReleaseText.plan(source: source, draft: draft, selection: selection, release: release).preview
            }
        }
    }
    public func applyReleaseText(accountId: String, appId: String, revisionId: String, planToken: String, selection: ReleaseText.Selection, fingerprint: String) throws -> ReleaseText.Preview {
        try applyReleaseTextWithReceipt(accountId: accountId, appId: appId, revisionId: revisionId, planToken: planToken, selection: selection, fingerprint: fingerprint).preview
    }
    public func applyReleaseTextWithReceipt(accountId: String, appId: String, revisionId: String, planToken: String, selection: ReleaseText.Selection, fingerprint: String) throws -> ReleaseTextSaveReceipt {
        try withReleaseTextPlan(accountId: accountId, appId: appId, revisionId: revisionId, token: planToken) { release, _ in
            try mutateDraft(accountId: accountId, appId: appId, revisionId: revisionId) { draft, json in
                let source = try JSONDecoder().decode(Revision.self, from: json.data)
                let plan = try ReleaseText.plan(source: source, draft: draft, selection: selection, release: release)
                guard plan.preview.fingerprint == fingerprint else { throw ReleaseTextFailure.stale }
                guard !plan.preview.changes.isEmpty else { throw ReleaseTextFailure.empty }
                let next = ReleaseText.apply(plan, draft: draft)
                var ids: [String] = []
                for change in plan.preview.changes where !ids.contains(change.localizationId) { ids.append(change.localizationId) }
                let before = try ids.flatMap { try LanguageDrafts.sections(source: json, draft: draft, selections: [.init(id: $0, scope: .version)]) }
                let after = try ids.flatMap { try LanguageDrafts.sections(source: json, draft: next, selections: [.init(id: $0, scope: .version)]) }
                return (next, ReleaseTextSaveReceipt(scope: .init(accountId: accountId, appId: appId, revisionId: revisionId), preview: plan.preview, before: before, after: after))
            }
        }
    }
    public func acknowledgeReleaseTextSource(accountId: String, appId: String, revisionId: String, planToken: String, review: CopiedText.Review) throws {
        try withReleaseTextPlan(accountId: accountId, appId: appId, revisionId: revisionId, token: planToken) { release, _ in
            guard review.scope == .version, review.versionId == release.baseVersionId, ReleaseText.fields.contains(review.field) else { throw CopiedTextFailure.invalid }
            try acknowledgeCopiedText(accountId: accountId, appId: appId, revisionId: revisionId, review: review)
        }
    }
}
