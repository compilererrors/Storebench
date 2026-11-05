import Foundation

/// One keyword idea for a language and optionally a market. Ideas are notes; nothing here changes the listing.
public struct KeywordIdea: Identifiable, Sendable, Equatable {
    public static let statuses: [(String, String)] = [("idea", "Idea"), ("researching", "Researching"), ("ready", "Ready to try"), ("used", "Used in listing"), ("rejected", "Rejected")]
    public static let sources: [(String, String)] = [("manual", "Own idea"), ("reviews", "Customer feedback"), ("listing", "Existing listing"), ("research", "External research")]
    public var id, term, locale, territory, status, source, reference, observedOn, notes: String
    public init(id: String = UUID().uuidString.lowercased(), term: String, locale: String, territory: String = "", status: String = "idea", source: String = "manual", reference: String = "", observedOn: String = "", notes: String = "") {
        self.id = id; self.term = term; self.locale = locale; self.territory = territory; self.status = status; self.source = source; self.reference = reference; self.observedOn = observedOn; self.notes = notes
    }
    var json: JSONText {
        .object([("id", .string(id)), ("term", .string(term)), ("locale", .string(locale)), ("territory", .string(territory)), ("status", .string(status)), ("source", .string(source)),
                 ("reference", .string(reference)), ("observedOn", .string(observedOn)), ("notes", .string(notes))])
    }
    public static func == (lhs: KeywordIdea, rhs: KeywordIdea) -> Bool { lhs.json == rhs.json }
    public var identity: String {
        JSONText.array([.string(locale), .string(territory), .string(TextSemantics.words(term).precomposedStringWithCompatibilityMapping.lowercased())]).stringify()
    }
    static func label(_ list: [(String, String)], _ key: String) -> String { list.first { $0.0 == key }?.1 ?? key }
}

public struct KeywordNotebook: Sendable, Equatable {
    public let accountId, appId: String
    public var items: [KeywordIdea]
    public init(accountId: String, appId: String, items: [KeywordIdea] = []) { self.accountId = accountId; self.appId = appId; self.items = items }
    var json: JSONText { .object([("schemaVersion", .number(1)), ("accountId", .string(accountId)), ("appId", .string(appId)), ("items", .array(items.map(\.json)))]) }
}

public enum KeywordFailure: Error, Equatable {
    case format, scope, duplicate, stale, storage, limit
    public var message: String {
        switch self {
        case .format: "A keyword idea has an invalid term, language, market, status, source, date or text. Terms cannot contain commas."
        case .scope: "This file belongs to another app."
        case .duplicate: "The same keyword is listed twice for one language and market."
        case .stale: "Keyword ideas changed in another window. Reload before saving; your entries are still here."
        case .storage: "Keyword ideas could not be read or saved."
        case .limit: "A notebook holds at most 2,000 ideas and 8 MB of normalized text. Imported files also have compressed and expanded size limits."
        }
    }
}

public enum Keywords {
    public static let limit = 2000
    static let columns = ["account_id", "app_id", "keyword_id", "term", "locale", "territory", "status", "source", "reference", "observed_on", "notes"]

    static func text(_ value: String?, _ length: Int) throws -> String {
        guard let value, value.utf16.count <= length, !value.unicodeScalars.contains(where: { ($0.value < 0x20 && ![0x09, 0x0a, 0x0d].contains($0.value)) || $0.value == 0x7f }) else { throw KeywordFailure.format }
        return value
    }

    static func normalize(_ item: KeywordIdea) throws -> KeywordIdea {
        let term = TextSemantics.words(try text(item.term, 200))
        guard item.id.range(of: "^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$", options: .regularExpression) != nil, !term.isEmpty, !term.unicodeScalars.contains(where: { $0.value == 44 }),
              StoreLocales.codes.contains(item.locale), item.territory.isEmpty || Territories.alpha3.values.contains(item.territory),
              KeywordIdea.statuses.contains(where: { $0.0 == item.status }), KeywordIdea.sources.contains(where: { $0.0 == item.source }) else { throw KeywordFailure.format }
        let observed = try text(item.observedOn, 10)
        if !observed.isEmpty && !ProductPricing.calendarDate(observed) { throw KeywordFailure.format }
        return KeywordIdea(id: item.id, term: term, locale: item.locale, territory: item.territory, status: item.status, source: item.source, reference: try text(item.reference, 500), observedOn: observed, notes: try text(item.notes, 2000))
    }

    public static func normalize(_ notebook: KeywordNotebook) throws -> KeywordNotebook {
        guard notebook.accountId.range(of: "^[A-Za-z0-9_-]{1,200}$", options: .regularExpression) != nil, notebook.appId.range(of: "^[0-9]{1,30}$", options: .regularExpression) != nil else { throw KeywordFailure.format }
        guard notebook.items.count <= limit else { throw KeywordFailure.limit }
        let items = try notebook.items.map(normalize).sorted { $0.id < $1.id }
        guard Set(items.map(\.id)).count == items.count, Set(items.map(\.identity)).count == items.count else { throw KeywordFailure.duplicate }
        return KeywordNotebook(accountId: notebook.accountId, appId: notebook.appId, items: items)
    }

    static func decode(_ value: JSONText) throws -> KeywordNotebook {
        guard value["schemaVersion"] == .number(1), let account = value["accountId"]?.text, let app = value["appId"]?.text, case .array(let rows)? = value["items"] else { throw KeywordFailure.format }
        guard rows.count <= limit else { throw KeywordFailure.limit }
        return try normalize(KeywordNotebook(accountId: account, appId: app, items: rows.map { row in
            guard case .object = row else { throw KeywordFailure.format }
            func field(_ name: String) throws -> String { guard case .string(let text)? = row[name] else { throw KeywordFailure.format }; return text }
            return KeywordIdea(id: try field("id"), term: try field("term"), locale: try field("locale"), territory: try field("territory"), status: try field("status"), source: try field("source"),
                               reference: try field("reference"), observedOn: try field("observedOn"), notes: try field("notes"))
        }))
    }

    /// The notebook revision: a digest of the saved notebook, or of `null` when there is none.
    public static func revision(_ notebook: KeywordNotebook?) -> String { Apple.sha(notebook?.json.stringify() ?? "null") }

    public static func differences(_ before: KeywordNotebook, _ after: KeywordNotebook) -> [JournalChange] {
        let previous = Dictionary(before.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }), next = Dictionary(after.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func describe(_ row: KeywordIdea?) -> String {
            guard let row else { return "Not in this notebook" }
            return "\(row.term)\n\(row.locale) · \(row.territory.isEmpty ? "Any territory" : row.territory) · \(KeywordIdea.label(KeywordIdea.statuses, row.status))\n\(KeywordIdea.label(KeywordIdea.sources, row.source)) · \(row.reference.isEmpty ? "No source reference" : row.reference)\n\(row.observedOn.isEmpty ? "No observation date" : row.observedOn)\n\(row.notes)"
        }
        var ids: [String] = []; for id in before.items.map(\.id) + after.items.map(\.id) where !ids.contains(id) { ids.append(id) }
        return ids.filter { previous[$0] != next[$0] }.map { id in
            JournalChange(label: "\(next[id] == nil ? "Removed" : previous[id] == nil ? "Added" : "Updated") keyword idea", before: describe(previous[id]), after: describe(next[id]), kind: "text")
        }
    }

    /// The keywords field text for selected ideas: duplicates removed, in order.
    public static func keywordField(_ items: [KeywordIdea]) -> String {
        var seen = Set<String>(), unique: [String] = []
        for item in items {
            let keyword = TextSemantics.trim(item.term), key = keyword.precomposedStringWithCompatibilityMapping.lowercased()
            if keyword.isEmpty || seen.contains(key) { continue }
            seen.insert(key); unique.append(keyword)
        }
        return unique.joined(separator: ",")
    }

    public static func csv(_ notebook: KeywordNotebook) -> String {
        let prefix = [notebook.accountId, notebook.appId]
        let rows = notebook.items.isEmpty ? [prefix + Array(repeating: "", count: 9)]
            : notebook.items.map { prefix + [$0.id, $0.term, $0.locale, $0.territory, $0.status, $0.source, $0.reference, $0.observedOn, $0.notes] }
        return Delimited.write(Delimited.Table(columns: columns, rows: rows.map { $0.map(Delimited.spreadsheetCell) }))
    }

    public static func json(_ notebook: KeywordNotebook) throws -> String { Transfer.pretty(try normalize(notebook).json) + "\n" }

    /// A stable scoped ID for imported rows without one.
    static func importedId(_ accountId: String, _ appId: String, _ identity: String) -> String {
        var hash = Array(Apple.sha(JSONText.array([.string(accountId), .string(appId), .string(identity)]).stringify()).prefix(32))
        hash[12] = "8"; hash[16] = Character(String((Int(String(hash[16]), radix: 16)! & 3) | 8, radix: 16))
        let value = String(hash)
        return [value.prefix(8), value.dropFirst(8).prefix(4), value.dropFirst(12).prefix(4), value.dropFirst(16).prefix(4), value.dropFirst(20)].map(String.init).joined(separator: "-")
    }

    /// Reads a notebook exported as CSV or JSON. Rows without an ID get a stable one.
    public static func importText(_ contents: String, accountId: String, appId: String, saved: KeywordNotebook? = nil) throws -> KeywordNotebook {
        guard saved == nil || saved?.accountId == accountId && saved?.appId == appId else { throw KeywordFailure.scope }
        let identities = Dictionary((saved?.items ?? []).map { ($0.identity, $0.id) }, uniquingKeysWith: { first, _ in first })
        let notebook: KeywordNotebook
        do {
            let trimmed = TextSemantics.trim(contents)
            if trimmed.hasPrefix("{") { notebook = try decode(try JSONText.parse(Data(trimmed.utf8))) }
            else {
                let rows = try Delimited.records(try Delimited.parse(contents), expected: columns).map { $0.mapValues(Delimited.unspreadsheetCell) }
                guard let first = rows.first else { throw KeywordFailure.format }
                guard rows.allSatisfy({ $0["account_id"] == first["account_id"] && $0["app_id"] == first["app_id"] }) else { throw KeywordFailure.scope }
                let empty = rows.count == 1 && columns.dropFirst(2).allSatisfy { first[$0] == "" }
                notebook = try normalize(KeywordNotebook(accountId: first["account_id"]!, appId: first["app_id"]!, items: empty ? [] : rows.map { row in
                    var idea = KeywordIdea(id: row["keyword_id"]!, term: row["term"]!, locale: row["locale"]!, territory: row["territory"]!, status: row["status"]!, source: row["source"]!,
                                           reference: row["reference"]!, observedOn: row["observed_on"]!, notes: row["notes"]!)
                    if idea.id.isEmpty { idea.id = identities[idea.identity] ?? importedId(first["account_id"]!, first["app_id"]!, idea.identity) }
                    return idea
                }))
            }
        } catch let failure as KeywordFailure { throw failure } catch { throw KeywordFailure.format }
        guard notebook.accountId == accountId, notebook.appId == appId else { throw KeywordFailure.scope }
        return notebook
    }
}

extension WorkspaceSession {
    /// The app's keyword notebook and the revision an editor must send back when saving.
    public func keywordNotebook(accountId: String, appId: String) throws -> (notebook: KeywordNotebook, revision: String) {
        let saved = try storeAccess { try $0.document(namespace: "keywords", key: "\(accountId):\(appId)") }
        guard let saved else { return (KeywordNotebook(accountId: accountId, appId: appId), Keywords.revision(nil)) }
        let notebook: KeywordNotebook
        do { notebook = try Keywords.decode(try JSONText.parse(saved.payload)) } catch { throw KeywordFailure.storage }
        guard notebook.accountId == accountId, notebook.appId == appId else { throw KeywordFailure.storage }
        return (notebook, Keywords.revision(notebook))
    }

    /// Saves the whole notebook only onto the revision the editor loaded.
    @discardableResult
    public func saveKeywordNotebook(_ notebook: KeywordNotebook, revision: String) throws -> String {
        guard notebook.accountId.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil, notebook.appId.range(of: "^[0-9]+$", options: .regularExpression) != nil else { throw KeywordFailure.storage }
        let value = try Keywords.normalize(notebook), key = "\(notebook.accountId):\(notebook.appId)", data = value.json.data
        guard data.count <= 8_000_000 else { throw KeywordFailure.limit }
        try storeAccess { store in
            try store.transaction { current in
                let previous = try current("keywords", key).map { document -> KeywordNotebook in
                    do { return try Keywords.decode(try JSONText.parse(document.payload)) } catch { throw KeywordFailure.storage }
                }
                guard Keywords.revision(previous) == revision else { throw KeywordFailure.stale }
                return previous?.json.stringify() == value.json.stringify() ? [] : [.put(namespace: "keywords", key: key, json: data)]
            }
        }
        return Keywords.revision(value)
    }
}
