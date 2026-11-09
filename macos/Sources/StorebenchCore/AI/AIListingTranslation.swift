import Foundation

extension WorkspaceSession {
    /// Sends only selected empty fields, then restores their positions in the complete saved source.
    /// A nil result means that this target needs no request.
    public func translatedListingSegments(accountId: String, appId: String, provider: AIProvider, source: LanguageTranslation.Request,
                                          locale: String, target: [LanguageDrafts.Section]?, replace: Bool, model: String? = nil) async throws -> [String]? {
        let indices = source.indicesToTranslate(target: target, replacing: replace)
        guard !indices.isEmpty else { return nil }
        let translated = try await translateWithAI(accountId: accountId, appId: appId, provider: provider, texts: indices.map { source.segments[$0] },
                                                    source: source.sourceLocale, target: locale, fields: indices.map { source.translationFields[$0] }, model: model)
        var texts = source.segments
        for (index, text) in zip(indices, translated) { texts[index] = text }
        return texts
    }

    public func aiTranslationTarget(accountId: String, appId: String, revisionId: String, versionId: String, locale: String) throws -> [LanguageDrafts.Section] {
        try requireHistoryScope(accountId: accountId, appId: appId)
        let key = try TextDrafts.key(accountId: accountId, appId: appId, revisionId: revisionId)
        return try storeAccess { store in
            guard let document = try store.document(namespace: "revisions", key: key) else { throw DraftFailure.sourceMissing }
            let source = try JSONText.parse(document.payload)
            let draft = try store.document(namespace: "drafts", key: key).map { try JSONText.parse($0.payload) } ?? TextDrafts.empty(revisionId)
            let revision = Self.overlay(try JSONDecoder().decode(Revision.self, from: source.data), draft: draft)
            let selections = try LanguageEditorState.selections(revision: revision, versionId: versionId, locale: locale)
            return try LanguageDrafts.sections(source: source, draft: draft, selections: selections)
        }
    }
    /// Both source and target are checked under the existing draft mutex. Translation never holds that mutex over a model request.
    public func applyAITranslation(accountId: String, appId: String, revisionId: String, versionId: String, source: LanguageTranslation.Request,
                                   translation: LanguageTranslation, target: [LanguageDrafts.Section], replace: Bool) throws {
        guard translation.sourceLocale == source.sourceLocale else { throw LanguageFailure.sourceChanged }
        _ = try translation.applying(to: .object(source.version.sorted { $0.key < $1.key }.map { ($0.key, .string($0.value)) }), scope: .version)
        if !source.appInfo.isEmpty {
            _ = try translation.applying(to: .object(source.appInfo.sorted { $0.key < $1.key }.map { ($0.key, .string($0.value)) }), scope: .appInfo)
        } else if !translation.appInfo.isEmpty { throw LanguageFailure.sourceChanged }
        let entries = target.map { section -> LanguageDrafts.Entry in
            let translated = section.selection.scope == .version ? translation.version : translation.appInfo
            var fields = section.draft.fields
            for (key, value) in translated where replace || TextSemantics.trim(fields[key] ?? "").isEmpty { fields[key] = value.text }
            return .init(id: section.selection.id, scope: section.selection.scope, fields: fields, fingerprint: section.draft.fingerprint)
        }
        try mutateDraft(accountId: accountId, appId: appId, revisionId: revisionId, check: { try self.requireHistoryScope(accountId: accountId, appId: appId) }) { draft, revision in
            guard try self.translationRequest(accountId: accountId, appId: appId, revisionId: revisionId, versionId: versionId, sourceLocale: source.sourceLocale) == source else { throw LanguageFailure.sourceChanged }
            let current = Self.overlay(try JSONDecoder().decode(Revision.self, from: revision.data), draft: draft)
            let versionTargets = target.filter { $0.selection.scope == .version }
            guard versionTargets.count == 1,
                  let locale = current.versions.first(where: { $0.id == versionId })?.localizations.first(where: { $0.id == versionTargets[0].selection.id })?.locale,
                  locale != source.sourceLocale else { throw DraftFailure.invalid }
            let selections = try LanguageEditorState.selections(revision: current, versionId: versionId, locale: locale)
            guard selections.count == target.count, selections.allSatisfy({ selection in target.contains { $0.selection.id == selection.id && $0.selection.scope == selection.scope } }) else { throw DraftFailure.invalid }
            let saved = try LanguageDrafts.saving(source: revision, draft: draft, entries: entries)
            return (saved.draft, ())
        }
    }
}
