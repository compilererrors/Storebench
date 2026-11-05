import Foundation

public enum CopiedTextFailure: Error, Equatable {
    case invalid, stale
    public var message: String {
        switch self {
        case .invalid: "Choose a copied language field to review."
        case .stale: "The source or destination text changed. Your wording is kept. Read the latest source and compare again."
        }
    }
}

/// A saved source comparison. Acknowledgement updates provenance without replacing destination text.
public enum CopiedText {
    public struct Marker: Sendable, Equatable {
        public let revisionId, localizationId, copiedValue, reviewedValue: String
        init?(_ json: JSONText) {
            guard let revision = json["revisionId"]?.text, let localization = json["localizationId"]?.text,
                  let copied = json["copiedValue"]?.text, let reviewed = json["reviewedValue"]?.text else { return nil }
            revisionId = revision; localizationId = localization; copiedValue = copied; reviewedValue = reviewed
        }
    }
    public struct Review: Sendable, Equatable {
        public let scope: TextDrafts.Scope
        public let versionId, targetId, field: String
        public let marker: Marker
        public let sourceLocale, sourceValue, targetValue: String
        public let needsReview: Bool
        /// A marker from another revision or an unavailable source cannot be acknowledged.
        public let canAcknowledge: Bool
    }

    public static func review(source: Revision, draft: JSONText, scope: TextDrafts.Scope, versionId: String, targetId: String, field: String) -> Review? {
        guard TextDrafts.fields(scope).contains(field), let markerJSON = draft["textSources"]?[targetId]?[field],
              let marker = Marker(markerJSON) else { return nil }
        let working = WorkspaceSession.overlay(source, draft: draft)
        guard let version = working.versions.first(where: { $0.id == versionId }) else { return nil }
        let records: [(id: String, fields: Fields)] = scope == .version
            ? version.localizations.map { ($0.id, $0.fields) }
            : working.appInfos.flatMap { $0.localizations.map { ($0.id, $0.fields) } }
        guard Set(records.map(\.id)).count == records.count, let target = records.first(where: { $0.id == targetId }) else { return nil }
        let original = records.first { $0.id == marker.localizationId }
        func value(_ record: (id: String, fields: Fields)) -> String { draft["texts"]?[record.id]?[field]?.text ?? record.fields[field].map(WorkspaceSession.text) ?? "" }
        let current = original.map(value) ?? ""
        // Keep canonically equivalent Unicode spellings distinct when comparing exact text.
        let needs = marker.revisionId != source.id || original == nil || !TextSemantics.same(current, marker.reviewedValue)
        return Review(scope: scope, versionId: versionId, targetId: targetId, field: field, marker: marker,
                      sourceLocale: original?.fields["locale"]?.text ?? "", sourceValue: current, targetValue: value(target), needsReview: needs,
                      canAcknowledge: needs && marker.revisionId == source.id && !(original?.fields["locale"]?.text ?? "").isEmpty)
    }

    /// Pure draft transformation; persistence is coordinated by WorkspaceSession.
    public static func acknowledge(source: Revision, draft: JSONText, expected: Review) throws -> JSONText {
        guard expected.versionId.utf16.count <= 256, expected.targetId.utf16.count <= 256,
              expected.marker.localizationId.utf16.count <= 256,
              [expected.targetValue, expected.sourceValue, expected.marker.copiedValue, expected.marker.reviewedValue].allSatisfy({ $0.utf16.count <= 10_000 }),
              TextDrafts.fields(expected.scope).contains(expected.field) else { throw CopiedTextFailure.invalid }
        guard let current = review(source: source, draft: draft, scope: expected.scope, versionId: expected.versionId, targetId: expected.targetId, field: expected.field),
              current.canAcknowledge, current.marker.revisionId == source.id, expected.marker.revisionId == source.id,
              TextSemantics.same(current.targetValue, expected.targetValue), TextSemantics.same(current.sourceValue, expected.sourceValue),
              TextSemantics.same(current.marker.reviewedValue, expected.marker.reviewedValue), TextSemantics.same(current.marker.copiedValue, expected.marker.copiedValue),
              current.marker.localizationId == expected.marker.localizationId else { throw CopiedTextFailure.stale }
        let sources = draft["textSources"] ?? .object([]), fields = sources[expected.targetId] ?? .object([])
        let marker = (fields[expected.field] ?? .object([])).setting("reviewedValue", .string(current.sourceValue))
        return draft.setting("textSources", sources.setting(expected.targetId, fields.setting(expected.field, marker)))
    }
}

extension WorkspaceSession {
    public func copiedTextReviews(accountId: String, appId: String, revisionId: String, localizationId: String, scope: TextDrafts.Scope, versionId: String? = nil) throws -> [String: CopiedText.Review] {
        try requireHistoryScope(accountId: accountId, appId: appId)
        let key = try TextDrafts.key(accountId: accountId, appId: appId, revisionId: revisionId)
        return try storeAccess { store in
            guard let saved = try store.document(namespace: "revisions", key: key) else { throw DraftFailure.sourceMissing }
            let source = try JSONDecoder().decode(Revision.self, from: saved.payload)
            let draft = try store.document(namespace: "drafts", key: key).map { try JSONText.parse($0.payload) } ?? TextDrafts.empty(revisionId)
            let working = Self.overlay(source, draft: draft)
            let version = versionId.map { id in working.versions.first { $0.id == id } } ?? (scope == .version ? working.versions.first { $0.localizations.contains { $0.id == localizationId } } : working.versions.first)
            guard let version else { return [:] }
            return Dictionary(uniqueKeysWithValues: TextDrafts.fields(scope).compactMap { field in
                CopiedText.review(source: source, draft: draft, scope: scope, versionId: version.id, targetId: localizationId, field: field).map { (field, $0) }
            })
        }
    }

    public func acknowledgeCopiedText(accountId: String, appId: String, revisionId: String, review: CopiedText.Review) throws {
        try requireHistoryScope(accountId: accountId, appId: appId)
        try mutateDraft(accountId: accountId, appId: appId, revisionId: revisionId) { draft, json in
            let source = try JSONDecoder().decode(Revision.self, from: json.data)
            return (try CopiedText.acknowledge(source: source, draft: draft, expected: review), ())
        }
    }
}
