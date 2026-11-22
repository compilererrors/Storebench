import Foundation

/// One saved change of a text field in a draft on this Mac: what the field said before the save and after it.
public struct DraftTextChange: Sendable, Equatable, Identifiable {
    public let id: String, revisionId: String, savedAt: String
    public let localizationId: String, locale: String, field: String
    public let before: String, after: String
}

/// Every save of a draft keeps the text fields it changed, so earlier wording can be found and used again.
/// A text is stored once under its content hash and each change refers to it, so repeated saves of the same wording take no
/// more room. The history of one revision keeps its newest `limit` changes.
enum DraftHistory {
    static let limit = 500
    static let values = "draft_text_values", entries = "draft_text_history"

    struct Change: Equatable { let localizationId, locale, field, before, after: String }

    /// The text fields whose saved value changed. A field without a draft value shows the imported value, so that is its "before".
    static func changes(before: JSONText, after: JSONText, source: JSONText) -> [Change] {
        let old = objects(before["texts"]), new = objects(after["texts"])
        var result: [Change] = []
        for localization in Set(old.keys).union(new.keys).sorted() {
            let previous = old[localization] ?? [:], next = new[localization] ?? [:]
            let imported = importedFields(source, localizationId: localization)
            for field in Set(previous.keys).union(next.keys).sorted() {
                let was = previous[field] ?? imported.fields[field] ?? "", now = next[field] ?? imported.fields[field] ?? ""
                if !TextSemantics.same(was, now) { result.append(Change(localizationId: localization, locale: imported.locale ?? localization, field: field, before: was, after: now)) }
            }
        }
        return result
    }

    /// The writes that record `changes` in the same transaction as the draft.
    static func writes(_ changes: [Change], key: String, prefix: String, at: String, current: (String, String) throws -> EncryptedDocumentStore.Document?) throws -> [EncryptedDocumentStore.Write] {
        guard !changes.isEmpty else { return [] }
        var writes: [EncryptedDocumentStore.Write] = [], stored = Set<String>()
        func reference(_ text: String) throws -> String {
            let hash = JSONText.string(text).rawSHA256
            if !stored.contains(hash), try current(values, prefix + hash) == nil {
                writes.append(.put(namespace: values, key: prefix + hash, json: JSONText.object([("text", .string(text))]).data))
            }
            stored.insert(hash); return hash
        }
        var history: [JSONText] = []
        if let document = try current(entries, key), case .array(let saved)? = try JSONText.parse(document.payload)["changes"] { history = saved }
        for change in changes {
            history.append(.object([("id", .string(UUID().uuidString.lowercased())), ("at", .string(at)), ("localizationId", .string(change.localizationId)), ("locale", .string(change.locale)),
                                    ("field", .string(change.field)), ("before", .string(try reference(change.before))), ("after", .string(try reference(change.after)))]))
        }
        writes.append(.put(namespace: entries, key: key, json: JSONText.object([("changes", .array(Array(history.suffix(limit))))]).data))
        return writes
    }

    private static func objects(_ value: JSONText?) -> [String: [String: String]] {
        guard case .object(let localizations)? = value else { return [:] }
        var result: [String: [String: String]] = [:]
        for (id, fields) in localizations { if case .object(let pairs) = fields { result[id] = Dictionary(pairs.compactMap { key, value in value.text.map { (key, $0) } }, uniquingKeysWith: { first, _ in first }) } }
        return result
    }
    private static func importedFields(_ source: JSONText, localizationId: String) -> (locale: String?, fields: [String: String]) {
        var groups: [JSONText] = []
        if case .array(let versions)? = source["versions"] { groups += versions }
        if case .array(let infos)? = source["appInfos"] { groups += infos }
        for group in groups {
            guard case .array(let localizations)? = group["localizations"], let match = localizations.first(where: { $0["id"]?.text == localizationId }) else { continue }
            guard case .object(let fields)? = match["fields"] else { return (nil, [:]) }
            return (match["fields"]?["locale"]?.text, Dictionary(fields.compactMap { key, value in value.text.map { (key, $0) } }, uniquingKeysWith: { first, _ in first }))
        }
        return (nil, [:])
    }
}

extension WorkspaceSession {
    /// Earlier text saved in this app's drafts, newest first, across its saved versions.
    public func draftTextHistory(accountId: String, appId: String, limit: Int = 200) throws -> [DraftTextChange] {
        try requireHistoryScope(accountId: accountId, appId: appId)
        let prefix = "\(accountId):\(appId):"
        return try storeAccess { store in
            var result: [DraftTextChange] = []
            for document in try store.documents(namespace: DraftHistory.entries, prefix: prefix) {
                let revision = String(document.key.dropFirst(prefix.count))
                guard case .array(let changes)? = try JSONText.parse(document.payload)["changes"] else { continue }
                for change in changes {
                    guard let id = change["id"]?.text, let at = change["at"]?.text, let localization = change["localizationId"]?.text, let field = change["field"]?.text,
                          let before = change["before"]?.text, let after = change["after"]?.text else { continue }
                    func text(_ hash: String) throws -> String? { try store.document(namespace: DraftHistory.values, key: prefix + hash).flatMap { try JSONText.parse($0.payload)["text"]?.text } }
                    guard let was = try text(before), let now = try text(after) else { continue }
                    result.append(DraftTextChange(id: id, revisionId: revision, savedAt: at, localizationId: localization, locale: change["locale"]?.text ?? localization, field: field, before: was, after: now))
                }
            }
            return Array(result.sorted { $0.savedAt > $1.savedAt }.prefix(max(0, limit)))
        }
    }
}
