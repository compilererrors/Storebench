import Foundation

public enum DraftFailure: Error, Equatable {
    case stale, sourceMissing, invalid, tooLarge

    public var message: String {
        switch self {
        case .stale: "Saved text changed in another window or import. Your edits are still here. Reload to load the latest saved draft before editing again."
        case .sourceMissing: "The draft's source is unavailable. Reload before saving."
        case .invalid: "The draft could not be saved. Your text is still here."
        case .tooLarge: "The draft is too large."
        }
    }
}

/// Local text drafts on top of a saved revision, stored as `drafts` documents.
/// Saving locally never changes App Store Connect.
public enum TextDrafts {
    public enum Scope: String, Sendable { case appInfo, version }
    public static let appInfoFields = ["name", "subtitle", "privacyPolicyUrl", "privacyChoicesUrl", "privacyPolicyText"]
    public static let versionFields = ["description", "keywords", "promotionalText", "whatsNew", "supportUrl", "marketingUrl"]
    public static let limits = ["name": 30, "subtitle": 30, "privacyPolicyUrl": 255, "privacyChoicesUrl": 255, "privacyPolicyText": 4000,
                                "description": 4000, "keywords": 100, "promotionalText": 170, "whatsNew": 4000, "supportUrl": 255, "marketingUrl": 255]
    public static let labels = ["name": "Name", "subtitle": "Subtitle", "privacyPolicyUrl": "Privacy Policy URL", "privacyChoicesUrl": "Privacy Choices URL", "privacyPolicyText": "Privacy Policy Text",
                                "description": "Description", "keywords": "Keywords", "promotionalText": "Promotional Text", "whatsNew": "What’s New in This Version", "supportUrl": "Support URL", "marketingUrl": "Marketing URL"]

    /// The longest text a saved draft field may hold, counted in UTF-16 units.
    public static let storedLimit = 10_000

    public static func fields(_ scope: Scope) -> [String] { scope == .appInfo ? appInfoFields : versionFields }

    /// Characters as App Store Connect counts them; keywords count UTF-8 bytes.
    public static func used(_ field: String, _ value: String) -> Int { field == "keywords" ? value.utf8.count : value.unicodeScalars.count }

    /// Compares saved text changes by exact Unicode representation.
    public static func sameFields(_ lhs: [String: String], _ rhs: [String: String]) -> Bool {
        lhs.count == rhs.count && lhs.allSatisfy { TextSemantics.same($0.value, rhs[$0.key]) }
    }

    /// The text draft fingerprint: SHA-256 of the saved fields sorted by name, or of `null` when nothing is saved.
    public static func fingerprint(_ fields: [String: String]?) -> String {
        guard let fields else { return JSONText.null.sha256 }
        let english = Locale(identifier: "en")
        return JSONText.object(fields.sorted { $0.key.compare($1.key, locale: english) == .orderedAscending }.map { ($0.key, .string($0.value)) }).sha256
    }

    static func key(accountId: String, appId: String, revisionId: String) throws -> String {
        guard accountId.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil, appId.range(of: #"^\d+$"#, options: .regularExpression) != nil,
              revisionId.range(of: "^[a-f0-9-]{36}$", options: .regularExpression) != nil else { throw DraftFailure.invalid }
        return "\(accountId):\(appId):\(revisionId)"
    }

    static func empty(_ revisionId: String) -> JSONText {
        .object([("schemaVersion", .number(1)), ("revisionId", .string(revisionId)), ("texts", .object([])), ("screenshotLayouts", .object([])), ("uploads", .object([]))])
    }

    static func strings(_ value: JSONText?) -> [String: String]? {
        guard case .object(let pairs)? = value else { return nil }
        return Dictionary(pairs.compactMap { pair in pair.1.text.map { (pair.0, $0) } }, uniquingKeysWith: { _, last in last })
    }
}

extension JSONText {
    /// Replaces a key in place, or appends it when absent.
    func setting(_ key: String, _ value: JSONText) -> JSONText {
        guard case .object(var pairs) = self else { return self }
        if let index = pairs.firstIndex(where: { $0.0 == key }) { pairs[index].1 = value } else { pairs.append((key, value)) }
        return .object(pairs)
    }
}

public struct TextDraft: Sendable, Equatable {
    public let fields: [String: String]
    public let fingerprint: String
    public let edited: Bool
}

extension WorkspaceSession {
    /// The saved draft text for one localization, or Apple's imported text where nothing is drafted.
    public func textDraft(accountId: String, appId: String, revisionId: String, localizationId: String, scope: TextDrafts.Scope) throws -> TextDraft {
        let key = try TextDrafts.key(accountId: accountId, appId: appId, revisionId: revisionId)
        return try storeAccess { store in
            guard let source = try store.document(namespace: "revisions", key: key).map({ try JSONText.parse($0.payload) }) else { throw DraftFailure.sourceMissing }
            let draft = try store.document(namespace: "drafts", key: key).map { try JSONText.parse($0.payload) }
            let saved = TextDrafts.strings(draft?["texts"]?[localizationId])
            var original: [String: String] = [:]
            if let localization = Self.localization(source, id: localizationId, scope: scope), case .object(let fields)? = localization["fields"] {
                for (name, value) in fields {
                    switch value { case .string(let text): original[name] = text; case .number: original[name] = value.stringify(); default: break }
                }
            }
            let fields = Dictionary(uniqueKeysWithValues: TextDrafts.fields(scope).map { ($0, saved?[$0] ?? original[$0] ?? "") })
            return TextDraft(fields: fields, fingerprint: TextDrafts.fingerprint(saved), edited: saved != nil)
        }
    }

    static func localization(_ revision: JSONText, id: String, scope: TextDrafts.Scope) -> JSONText? {
        guard case .array(let parents)? = revision[scope == .appInfo ? "appInfos" : "versions"] else { return nil }
        for parent in parents { if case .array(let locales)? = parent["localizations"], let match = locales.first(where: { $0["id"]?.text == id }) { return match } }
        return nil
    }

    /// Changes one revision's draft under the draft mutex; the transaction checks that neither the source nor the draft moved.
    func mutateDraft<T>(accountId: String, appId: String, revisionId: String, check: () throws -> Void = {}, _ change: (_ draft: JSONText, _ source: JSONText) throws -> (JSONText, T)) throws -> T {
        let key = try TextDrafts.key(accountId: accountId, appId: appId, revisionId: revisionId)
        let mutex = "draft_" + JSONText.string(key).rawSHA256.prefix(40)
        return try storeAccess { store in
            try FileMutex.withLock(store.directory.appendingPathComponent("\(mutex).mutex")) {
                try check(); try Task.checkCancellation()
                guard let sourceDocument = try store.document(namespace: "revisions", key: key) else { throw DraftFailure.sourceMissing }
                let source = try JSONText.parse(sourceDocument.payload)
                let existing = try store.document(namespace: "drafts", key: key)
                var draft = try existing.map { try JSONText.parse($0.payload) } ?? TextDrafts.empty(revisionId)
                guard draft["schemaVersion"] == .number(1), draft["revisionId"]?.text == revisionId else { throw DraftFailure.invalid }
                if draft["uploads"] == nil { draft = draft.setting("uploads", .object([])) }
                let (updated, result) = try change(draft, source)
                let data = updated.data
                guard data.count <= 20_000_000 else { throw DraftFailure.tooLarge }
                try store.transaction { current in
                    guard let currentSource = try current("revisions", key) else { throw DraftFailure.sourceMissing }
                    guard currentSource.revision == sourceDocument.revision else { throw DraftFailure.stale }
                    guard try current("drafts", key)?.revision == existing?.revision else { throw DraftFailure.stale }
                    try check(); try Task.checkCancellation()
                    return [.put(namespace: "drafts", key: key, json: data)]
                }
                return result
            }
        }
    }

    /// Saves all text fields of one localization, only onto the draft the editor loaded (`fingerprint`).
    @discardableResult
    public func saveTextDraft(accountId: String, appId: String, revisionId: String, localizationId: String, scope: TextDrafts.Scope,
                              fields: [String: String], fingerprint: String) throws -> String {
        let allowed = TextDrafts.fields(scope)
        guard !localizationId.isEmpty, localizationId.utf16.count <= 256, Set(fields.keys).isSubset(of: allowed), fields.values.allSatisfy({ $0.utf16.count <= 10_000 }) else { throw DraftFailure.invalid }
        return try mutateDraft(accountId: accountId, appId: appId, revisionId: revisionId) { draft, _ in
            var draft = draft
            let previous = TextDrafts.strings(draft["texts"]?[localizationId])
            guard TextDrafts.fingerprint(previous) == fingerprint else { throw DraftFailure.stale }
            let saved = JSONText.object(allowed.map { ($0, .string(fields[$0] ?? "")) })
            draft = TextDrafts.saving(draft, localizationId: localizationId, fields: fields, saved: saved)
            return (draft, TextDrafts.fingerprint(TextDrafts.strings(saved)))
        }
    }
}

extension TextDrafts {
    /// Retain each copied-source marker only while its destination still holds the copied text.
    static func saving(_ draft: JSONText, localizationId: String, fields: [String: String], saved: JSONText) -> JSONText {
        var draft = draft
        let previous = strings(draft["texts"]?[localizationId])
        if case .object(let sources)? = draft["textSources"] {
            var markers: [(String, JSONText)] = []
            if case .object(let savedMarkers)? = sources.first(where: { $0.0 == localizationId })?.1 { markers = savedMarkers }
            markers = markers.filter { TextSemantics.same(fields[$0.0], previous?[$0.0]) }
            draft = draft.setting("textSources", JSONText.object(sources).setting(localizationId, .object(markers)))
        }
        return draft.setting("texts", (draft["texts"] ?? .object([])).setting(localizationId, saved))
    }
}
