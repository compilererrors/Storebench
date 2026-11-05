import Foundation

/// Editable text, its immutable import and the explicitly chosen saved baseline for one language.
public struct LanguageEditorState: Sendable {
    public struct Field: Identifiable, Sendable {
        public let selection: LanguageDrafts.Selection, key: String
        public var id: String { selection.id + ":" + key }
        public var label: String { TextDrafts.labels[key] ?? key }
    }
    public let selections: [LanguageDrafts.Selection], fields: [Field]
    public let imported: [String: [String: String]]
    public private(set) var values: [String: [String: String]], baseline: [String: [String: String]], fingerprints: [String: String]
    public private(set) var latest: [LanguageDrafts.Section]?
    public private(set) var edited: Bool

    public init(_ sections: [LanguageDrafts.Section]) throws {
        try Self.validate(sections)
        selections = sections.map(\.selection)
        fields = sections.flatMap { section in TextDrafts.fields(section.selection.scope).map { Field(selection: section.selection, key: $0) } }
        imported = Dictionary(uniqueKeysWithValues: sections.map { ($0.selection.id, $0.imported) })
        values = Dictionary(uniqueKeysWithValues: sections.map { ($0.selection.id, $0.draft.fields) }); baseline = values
        fingerprints = Dictionary(uniqueKeysWithValues: sections.map { ($0.selection.id, $0.draft.fingerprint) })
        edited = sections.contains { $0.draft.edited }
    }
    private static func validate(_ sections: [LanguageDrafts.Section]) throws {
        try LanguageDrafts.selections(sections.map(\.selection))
        for section in sections {
            let allowed = Set(TextDrafts.fields(section.selection.scope))
            guard Set(section.imported.keys) == allowed, Set(section.draft.fields.keys) == allowed,
                  section.draft.fingerprint.utf8.count == 64, section.draft.fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw DraftFailure.invalid }
        }
    }
    public static func selections(revision: Revision, versionId: String, locale: String) throws -> [LanguageDrafts.Selection] {
        let info = revision.appInfos.flatMap(\.localizations).filter { TextSemantics.same($0.fields["locale"]?.text.flatMap { $0.isEmpty ? nil : $0 } ?? $0.id, locale) }
        guard let version = revision.versions.first(where: { TextSemantics.same($0.id, versionId) }) else { throw DraftFailure.invalid }
        let listing = version.localizations.filter { TextSemantics.same($0.fields["locale"]?.text.flatMap { $0.isEmpty ? nil : $0 } ?? $0.id, locale) }
        let result = listing.map { LanguageDrafts.Selection(id: $0.id, scope: .version) } + info.map { LanguageDrafts.Selection(id: $0.id, scope: .appInfo) }
        try LanguageDrafts.selections(result); return result
    }
    public var dirty: Bool { selections.contains { !TextDrafts.sameFields(values[$0.id] ?? [:], baseline[$0.id] ?? [:]) } }
    public var signature: String { JSONText.object(selections.map { selection in
        (selection.id, .object(TextDrafts.fields(selection.scope).map { ($0, .string(values[selection.id]?[$0] ?? "")) }))
    }).rawSHA256 }
    public func value(_ field: Field) -> String { values[field.selection.id]?[field.key] ?? "" }
    public func saved(_ field: Field) -> String { baseline[field.selection.id]?[field.key] ?? "" }
    public func original(_ field: Field) -> String { imported[field.selection.id]?[field.key] ?? "" }
    public func differsFromImport(_ field: Field) -> Bool { !TextSemantics.same(value(field), original(field)) }
    public func unsaved(_ field: Field) -> Bool { !TextSemantics.same(value(field), saved(field)) }
    public func sourceVisible(_ review: CopiedText.Review) -> Bool {
        selections.contains { TextSemantics.same($0.id, review.targetId) && $0.scope == review.scope }
        && TextSemantics.same(values[review.targetId]?[review.field], review.marker.copiedValue)
    }
    public func canAcknowledge(_ review: CopiedText.Review) -> Bool {
        review.canAcknowledge && sourceVisible(review) && TextSemantics.same(values[review.targetId]?[review.field], baseline[review.targetId]?[review.field])
    }
    public var searchTitle: (name: String, subtitle: String) {
        guard let info = selections.first(where: { $0.scope == .appInfo }) else { return ("", "") }
        return (values[info.id]?["name"] ?? "", values[info.id]?["subtitle"] ?? "")
    }
    public mutating func change(_ field: Field, to value: String) throws {
        guard fields.contains(where: { $0.id == field.id && $0.selection.scope == field.selection.scope }), value.utf16.count <= 10_000 else { throw DraftFailure.invalid }
        values[field.selection.id]?[field.key] = value; latest = nil
    }
    public mutating func restoreImport(_ field: Field) throws { try change(field, to: original(field)) }
    public func entries() throws -> [LanguageDrafts.Entry] {
        let entries = selections.filter { !TextDrafts.sameFields(values[$0.id] ?? [:], baseline[$0.id] ?? [:]) }.map {
            LanguageDrafts.Entry(id: $0.id, scope: $0.scope, fields: values[$0.id] ?? [:], fingerprint: fingerprints[$0.id] ?? "")
        }
        if !entries.isEmpty { try LanguageDrafts.validate(entries) }; return entries
    }
    /// Only the exact confirmed snapshot becomes the baseline; later typing remains unsaved.
    public mutating func confirmed(_ entries: [LanguageDrafts.Entry], fingerprints receipt: [String: String]) throws {
        try LanguageDrafts.validate(entries)
        guard Set(receipt.keys) == Set(entries.map { $0.selection.id }), entries.allSatisfy({ entry in
            selections.contains { $0.id == entry.selection.id && $0.scope == entry.selection.scope }
            && fingerprints[entry.selection.id] == entry.fingerprint && receipt[entry.selection.id] == TextDrafts.fingerprint(entry.fields)
        }) else { throw DraftFailure.stale }
        for entry in entries { baseline[entry.selection.id] = entry.fields; fingerprints[entry.selection.id] = receipt[entry.selection.id] }
        edited = true; latest = nil
    }
    public mutating func compare(_ sections: [LanguageDrafts.Section]) throws {
        try Self.validate(sections)
        guard sections.count == selections.count, sections.allSatisfy({ section in selections.contains { $0.id == section.selection.id && $0.scope == section.selection.scope } }) else { throw DraftFailure.invalid }
        latest = sections
    }
    public mutating func acceptLatest(keepEdits: Bool) {
        guard let latest else { return }
        baseline = Dictionary(uniqueKeysWithValues: latest.map { ($0.selection.id, $0.draft.fields) })
        fingerprints = Dictionary(uniqueKeysWithValues: latest.map { ($0.selection.id, $0.draft.fingerprint) })
        edited = latest.contains { $0.draft.edited }
        if !keepEdits { values = baseline }; self.latest = nil
    }
    public mutating func discard() { values = baseline; latest = nil }
    public func publishingRequest(accountId: String, appId: String, revisionId: String, versionId: String, targetMode: String) throws -> PublishRequest {
        guard !dirty else { throw PublishFailure.invalid("Save all language text before preparing its App Store review.") }
        _ = try TextDrafts.key(accountId: accountId, appId: appId, revisionId: revisionId)
        return try PublishRequest(accountId: accountId, appId: appId, scope: .metadata, targetMode: targetMode, revisionId: revisionId, versionId: versionId).validated()
    }
}
