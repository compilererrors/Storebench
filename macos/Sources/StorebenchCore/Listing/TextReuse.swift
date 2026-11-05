import Foundation

public enum TextReuseFailure: Error, Equatable {
    case selection, source, destination, stale
    public var message: String {
        switch self {
        case .selection: "Choose source and destination languages, fields and a copy mode."
        case .source: "Source language was not found in this version."
        case .destination: "Choose other destination languages in the same version."
        case .stale: "Saved source or destination text changed. Preview again before applying."
        }
    }
}

public enum TextReuse {
    public enum Mode: String, Sendable { case empty, replace }
    public struct Selection: Sendable {
        public let versionId, sourceLocale: String
        public let targetLocales, fields: [String]
        public let mode: Mode
        public init(versionId: String, sourceLocale: String, targetLocales: [String], fields: [String], mode: Mode) {
            self.versionId = versionId; self.sourceLocale = sourceLocale; self.targetLocales = targetLocales; self.fields = fields; self.mode = mode
        }
    }
    public struct Change: Equatable, Identifiable, Sendable {
        public let localizationId, locale, field, before, after: String
        public var id: String { "\(localizationId):\(field)" }
        var json: JSONText { .object([("localizationId", .string(localizationId)), ("locale", .string(locale)), ("field", .string(field)), ("before", .string(before)), ("after", .string(after))]) }
    }
    public struct Preview: Equatable, Sendable { public let changes: [Change]; public let fingerprint: String }
    struct Plan { let preview: Preview; let sourceId: String }

    static func plan(source: Revision, draft: JSONText, selection: Selection, accountId: String, appId: String) throws -> Plan {
        guard !selection.targetLocales.isEmpty, selection.targetLocales.count <= 100,
              Set(selection.targetLocales).count == selection.targetLocales.count, !selection.fields.isEmpty,
              Set(selection.fields).count == selection.fields.count, Set(selection.fields).isSubset(of: TextDrafts.versionFields),
              source.app.id == appId else { throw TextReuseFailure.selection }
        let version = WorkspaceSession.overlay(source, draft: draft).versions.first { $0.id == selection.versionId }
        guard let version, let original = version.localizations.first(where: { $0.locale == selection.sourceLocale }) else { throw TextReuseFailure.source }
        let targets = try selection.targetLocales.map { code in
            guard let locale = version.localizations.first(where: { $0.locale == code }), locale.id != original.id else { throw TextReuseFailure.destination }
            return locale
        }
        func value(_ item: Revision.Localization, _ field: String) -> String { draft["texts"]?[item.id]?[field]?.text ?? item.fields[field]?.text ?? "" }
        var changes: [Change] = []
        for target in targets { for field in selection.fields {
            let before = value(target, field), after = value(original, field)
            if TextSemantics.trim(after).isEmpty || TextSemantics.same(before, after) || selection.mode == .empty && !TextSemantics.trim(before).isEmpty { continue }
            changes.append(Change(localizationId: target.id, locale: target.locale, field: field, before: before, after: after))
        } }
        let request = JSONText.object([("versionId", .string(selection.versionId)), ("sourceLocale", .string(selection.sourceLocale)), ("targetLocales", .array(selection.targetLocales.map(JSONText.string))),
                                       ("fields", .array(selection.fields.map(JSONText.string))), ("mode", .string(selection.mode.rawValue))])
        // Selected values and copied-text markers include skipped fields, so every relevant stale edit is rejected.
        let evidence = ( [original] + targets ).map { item in JSONText.object([("id", .string(item.id)), ("fields", .object(selection.fields.map { ($0, .string(value(item, $0))) }))]) }
        let copied = targets.map { item in JSONText.object([("id", .string(item.id)), ("sources", .object(selection.fields.map { ($0, draft["textSources"]?[item.id]?[$0] ?? .null) }))]) }
        let signature = JSONText.object([("accountId", .string(accountId)), ("appId", .string(appId)), ("revisionId", .string(source.id)), ("request", request),
                                         ("changes", .array(changes.map(\.json))), ("evidence", .array(evidence)), ("copiedEvidence", .array(copied))]).sha256
        return Plan(preview: Preview(changes: changes, fingerprint: signature), sourceId: original.id)
    }

    static func apply(_ plan: Plan, to draft: JSONText) -> JSONText {
        var result = draft
        for change in plan.preview.changes {
            let texts = result["texts"] ?? .object([])
            var fields = texts[change.localizationId] ?? .object([])
            // Save only the selected fields while retaining all other drafted fields.
            if case .object(let existing) = fields { fields = .object(existing.filter { TextDrafts.versionFields.contains($0.0) }) }
            fields = fields.setting(change.field, .string(change.after))
            result = result.setting("texts", texts.setting(change.localizationId, fields))
            let sources = result["textSources"] ?? .object([])
            let marker = JSONText.object([("revisionId", .string(draft["revisionId"]?.text ?? "")), ("localizationId", .string(plan.sourceId)), ("copiedValue", .string(change.after)), ("reviewedValue", .string(change.after))])
            result = result.setting("textSources", sources.setting(change.localizationId, (sources[change.localizationId] ?? .object([])).setting(change.field, marker)))
        }
        return result
    }
}

extension WorkspaceSession {
    /// Preview saved version text, including languages added locally. No draft or Apple data is changed.
    public func previewTextReuse(accountId: String, appId: String, revisionId: String, selection: TextReuse.Selection) throws -> TextReuse.Preview {
        let key = try TextDrafts.key(accountId: accountId, appId: appId, revisionId: revisionId)
        return try storeAccess { store in
            guard let document = try store.document(namespace: "revisions", key: key) else { throw DraftFailure.sourceMissing }
            let source = try JSONDecoder().decode(Revision.self, from: document.payload)
            let draft = try store.document(namespace: "drafts", key: key).map { try JSONText.parse($0.payload) } ?? TextDrafts.empty(revisionId)
            return try TextReuse.plan(source: source, draft: draft, selection: selection, accountId: accountId, appId: appId).preview
        }
    }

    /// Compare the concrete preview under the process-shared draft lock before saving all selected changes together.
    public func applyTextReuse(accountId: String, appId: String, revisionId: String, selection: TextReuse.Selection, fingerprint: String) throws -> TextReuse.Preview {
        try mutateDraft(accountId: accountId, appId: appId, revisionId: revisionId) { draft, json in
            let source = try JSONDecoder().decode(Revision.self, from: json.data)
            let plan = try TextReuse.plan(source: source, draft: draft, selection: selection, accountId: accountId, appId: appId)
            guard plan.preview.fingerprint == fingerprint else { throw TextReuseFailure.stale }
            return (TextReuse.apply(plan, to: draft), plan.preview)
        }
    }
}
