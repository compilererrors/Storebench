import Foundation

/// One language save validates all starting text sections before replacing the shared draft.
public enum LanguageDrafts {
    public struct Selection: Sendable {
        public let id: String, scope: TextDrafts.Scope
        public init(id: String, scope: TextDrafts.Scope) { self.id = id; self.scope = scope }
    }
    public struct Entry: Sendable {
        public let selection: Selection, fields: [String: String], fingerprint: String
        public init(id: String, scope: TextDrafts.Scope, fields: [String: String], fingerprint: String) {
            selection = .init(id: id, scope: scope); self.fields = fields; self.fingerprint = fingerprint
        }
        public var json: JSONText { .object([("id", .string(selection.id)), ("scope", .string(selection.scope.rawValue)),
            ("fields", .object(TextDrafts.fields(selection.scope).map { ($0, .string(fields[$0] ?? "")) })), ("fingerprint", .string(fingerprint))]) }
    }
    public struct Section: Sendable {
        public let selection: Selection, imported: [String: String], draft: TextDraft
        public var json: JSONText { .object([("id", .string(selection.id)), ("scope", .string(selection.scope.rawValue)),
            ("imported", .object(TextDrafts.fields(selection.scope).map { ($0, .string(imported[$0] ?? "")) })),
            ("fields", .object(TextDrafts.fields(selection.scope).map { ($0, .string(draft.fields[$0] ?? "")) })),
            ("fingerprint", .string(draft.fingerprint)), ("edited", .bool(draft.edited))]) }
    }

    static func selections(_ values: [Selection]) throws {
        guard (1...20).contains(values.count), Set(values.map(\.id)).count == values.count,
              values.allSatisfy({ AppOverviewMaterial.identifier($0.id) }) else { throw DraftFailure.invalid }
    }
    static func validate(_ entries: [Entry]) throws {
        try selections(entries.map(\.selection))
        for entry in entries {
            guard Set(entry.fields.keys) == Set(TextDrafts.fields(entry.selection.scope)), entry.fields.values.allSatisfy({ $0.utf16.count <= 10_000 }),
                  entry.fingerprint.utf8.count == 64, entry.fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw DraftFailure.invalid }
        }
    }
    static func localization(_ selection: Selection, source: JSONText, draft: JSONText) throws -> JSONText {
        guard source["id"]?.text == draft["revisionId"]?.text else { throw DraftFailure.invalid }
        let parents = WorkspaceSession.items(source[selection.scope == .appInfo ? "appInfos" : "versions"])
        for parent in parents {
            if let locale = WorkspaceSession.items(parent["localizations"]).first(where: { TextSemantics.same($0["id"]?.text, selection.id) }) { return locale }
        }
        let additions = WorkspaceSession.items(draft["addedLocalizations"])
        if selection.scope == .version {
            if let locale = additions.first(where: { TextSemantics.same($0["id"]?.text, selection.id) }),
               parents.contains(where: { TextSemantics.same($0["id"]?.text, locale["versionId"]?.text) }), let code = locale["locale"]?.text {
                return .object([("id", .string(selection.id)), ("fields", .object([("locale", .string(code))]))])
            }
        } else {
            for locale in additions {
                guard let code = locale["locale"]?.text, TextSemantics.same("local-app-info-" + code, selection.id),
                      !parents.contains(where: { WorkspaceSession.items($0["localizations"]).contains(where: { TextSemantics.same($0["fields"]?["locale"]?.text, code) }) }) else { continue }
                return .object([("id", .string(selection.id)), ("fields", .object([("locale", .string(code))]))])
            }
        }
        throw DraftFailure.invalid
    }
    static func originalText(_ value: JSONText?) throws -> String {
        guard let value else { return "" }
        switch value {
        case .bool(let flag): return flag ? "true" : "false"
        case .array(let values): return try values.map { try originalText($0) }.joined(separator: ",")
        case .object: return "[object Object]"
        default: return try RevisionComparison.text(value)
        }
    }
    static func validateTextDocument(_ draft: JSONText) throws {
        guard case .number(1)? = draft["schemaVersion"], case .object(let texts)? = draft["texts"], texts.count <= 2000 else { throw DraftFailure.invalid }
        let allowed = Set(TextDrafts.appInfoFields + TextDrafts.versionFields)
        for (_, value) in texts {
            guard case .object(let fields) = value else { throw DraftFailure.invalid }
            for (key, value) in fields { guard allowed.contains(key), let text = value.text, text.utf16.count <= 10_000 else { throw DraftFailure.invalid } }
        }
    }
    public static func sections(source: JSONText, draft: JSONText, selections: [Selection]) throws -> [Section] {
        try Self.selections(selections)
        try validateTextDocument(draft)
        return try selections.map { selection in
            let locale = try localization(selection, source: source, draft: draft)
            let imported = try Dictionary(uniqueKeysWithValues: TextDrafts.fields(selection.scope).map { ($0, try originalText(locale["fields"]?[$0])) })
            let saved = TextDrafts.strings(draft["texts"]?[selection.id])
            let fields = Dictionary(uniqueKeysWithValues: TextDrafts.fields(selection.scope).map { ($0, saved?[$0] ?? imported[$0] ?? "") })
            return .init(selection: selection, imported: imported, draft: .init(fields: fields, fingerprint: TextDrafts.fingerprint(saved), edited: saved != nil))
        }
    }
    public static func saving(source: JSONText, draft: JSONText, entries: [Entry]) throws -> (draft: JSONText, fingerprints: [String: String]) {
        try validate(entries)
        try validateTextDocument(draft)
        for entry in entries {
            _ = try localization(entry.selection, source: source, draft: draft)
            guard TextDrafts.fingerprint(TextDrafts.strings(draft["texts"]?[entry.selection.id])) == entry.fingerprint else { throw DraftFailure.stale }
        }
        var next = draft, fingerprints: [String: String] = [:]
        for entry in entries {
            let saved = JSONText.object(TextDrafts.fields(entry.selection.scope).map { ($0, .string(entry.fields[$0] ?? "")) })
            next = TextDrafts.saving(next, localizationId: entry.selection.id, fields: entry.fields, saved: saved)
            fingerprints[entry.selection.id] = TextDrafts.fingerprint(entry.fields)
        }
        return (next, fingerprints)
    }
}

extension WorkspaceSession {
    public func languageTextDrafts(accountId: String, appId: String, revisionId: String, selections: [LanguageDrafts.Selection]) throws -> [LanguageDrafts.Section] {
        try requireHistoryScope(accountId: accountId, appId: appId); try Task.checkCancellation()
        let key = try TextDrafts.key(accountId: accountId, appId: appId, revisionId: revisionId)
        return try storeAccess { store in
            try FileMutex.withLock(store.directory.appendingPathComponent("draft_" + JSONText.string(key).rawSHA256.prefix(40) + ".mutex")) {
                try requireHistoryScope(accountId: accountId, appId: appId); try Task.checkCancellation()
                let source = try archivedRevision(accountId: accountId, appId: appId, id: revisionId, store: store)
                let draft = try store.document(namespace: "drafts", key: key).map { try JSONText.parse($0.payload) } ?? TextDrafts.empty(revisionId)
                let result = try LanguageDrafts.sections(source: source.value, draft: draft, selections: selections)
                try requireHistoryScope(accountId: accountId, appId: appId); try Task.checkCancellation(); return result
            }
        }
    }
    public func saveLanguageDraft(accountId: String, appId: String, revisionId: String, entries: [LanguageDrafts.Entry]) throws -> [String: String] {
        try LanguageDrafts.validate(entries)
        let request = JSONText.object([("accountId", .string(accountId)), ("appId", .string(appId)), ("revisionId", .string(revisionId)), ("entries", .array(entries.map(\.json)))])
        guard request.data.count <= 1_000_000 else { throw DraftFailure.tooLarge }
        return try mutateDraft(accountId: accountId, appId: appId, revisionId: revisionId, check: { try self.requireHistoryScope(accountId: accountId, appId: appId) }) { draft, source in
            guard source["account"]?["id"]?.text == accountId, source["app"]?["id"]?.text == appId, source["id"]?.text == revisionId else { throw DraftFailure.invalid }
            let result = try LanguageDrafts.saving(source: source, draft: draft, entries: entries)
            return (result.draft, result.fingerprints)
        }
    }
}
