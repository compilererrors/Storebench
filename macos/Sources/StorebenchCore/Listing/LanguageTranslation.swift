import Foundation

/// Translates texts in order, returning one translation per text.
public typealias TextTranslator = @MainActor (_ texts: [String]) async throws -> [String]

/// Translated starting text for a new language. Each value keeps the exact saved source text it was made from,
/// so the draft write refuses a translation whose source changed while it was being translated.
public struct LanguageTranslation: Sendable, Equatable {
    public struct Value: Sendable, Equatable {
        public let source, text: String
        public init(source: String, text: String) { self.source = source; self.text = text }
    }
    public let sourceLocale: String
    public let version: [String: Value], appInfo: [String: Value]

    /// Fields whose wording is translated. The name and every link are copied unchanged.
    public static let versionFields = ["description", "keywords", "promotionalText", "whatsNew"]
    public static let appInfoFields = ["subtitle", "privacyPolicyText"]

    /// The saved source text of one language, split into the segments a translator receives.
    public struct Request: Sendable, Equatable {
        public let sourceLocale: String
        public let version: [String: String], appInfo: [String: String]

        public init(sourceLocale: String, version: [String: String], appInfo: [String: String]) {
            self.sourceLocale = sourceLocale; self.version = version; self.appInfo = appInfo
        }

        private var parts: [(scope: TextDrafts.Scope, field: String, segments: [String])] {
            let version = LanguageTranslation.versionFields.map { (TextDrafts.Scope.version, $0, Self.segments($0, self.version[$0] ?? "")) }
            let info = appInfo.isEmpty ? [] : LanguageTranslation.appInfoFields.map { (TextDrafts.Scope.appInfo, $0, Self.segments($0, appInfo[$0] ?? "")) }
            return version + info
        }
        /// Every text to translate, in a stable order. Keywords are translated one term at a time so commas stay separators.
        public var segments: [String] { parts.flatMap(\.segments) }

        static func segments(_ field: String, _ value: String) -> [String] {
            guard !TextSemantics.trim(value).isEmpty else { return [] }
            guard field == "keywords" else { return [value] }
            return value.split(separator: ",").map { TextSemantics.trim(String($0)) }.filter { !$0.isEmpty }
        }

        /// Pairs translated segments with their sources. Fields without text keep their source unchanged.
        public func translation(_ translated: [String]) throws -> LanguageTranslation {
            guard translated.count == segments.count else { throw LanguageFailure.translationFailed }
            var remaining = translated[...], version: [String: Value] = [:], info: [String: Value] = [:]
            for part in parts {
                let source = part.scope == .version ? self.version[part.field] ?? "" : appInfo[part.field] ?? ""
                let pieces = remaining.prefix(part.segments.count).map { TextSemantics.trim($0) }; remaining = remaining.dropFirst(part.segments.count)
                let text: String
                if part.segments.isEmpty { text = source }
                else if part.field == "keywords" { text = pieces.map { $0.replacingOccurrences(of: ",", with: " ") }.filter { !$0.isEmpty }.joined(separator: ",") }
                else { text = pieces[0] }
                guard part.segments.isEmpty || !text.isEmpty else { throw LanguageFailure.translationFailed }
                if part.scope == .version { version[part.field] = Value(source: source, text: text) } else { info[part.field] = Value(source: source, text: text) }
            }
            return LanguageTranslation(sourceLocale: sourceLocale, version: version, appInfo: info)
        }
    }

    public init(sourceLocale: String, version: [String: Value], appInfo: [String: Value]) {
        self.sourceLocale = sourceLocale; self.version = version; self.appInfo = appInfo
    }

    /// Replaces copied wording with its translation after confirming each source value is still the one that was translated
    /// and each translation fits a saved draft field.
    func applying(to copied: JSONText, scope: TextDrafts.Scope) throws -> JSONText {
        let fields = scope == .version ? Self.versionFields : Self.appInfoFields, values = scope == .version ? version : appInfo
        guard Set(values.keys) == Set(fields) else { throw LanguageFailure.sourceChanged }
        var result = copied
        for field in fields {
            guard let value = values[field], TextSemantics.same(copied[field]?.text ?? "", value.source) else { throw LanguageFailure.sourceChanged }
            // Saved drafts reject longer text on every read, so an oversized translation would make every language in the draft unreadable.
            guard value.text.utf16.count <= TextDrafts.storedLimit else { throw LanguageFailure.translationTooLong(field: field) }
            result = result.setting(field, .string(value.text))
        }
        return result
    }
}

extension WorkspaceSession {
    /// The saved text of a version's language, read outside the draft lock so translation never holds it.
    public func translationRequest(accountId: String, appId: String, revisionId: String, versionId: String, sourceLocale: String) throws -> LanguageTranslation.Request {
        let key = try TextDrafts.key(accountId: accountId, appId: appId, revisionId: revisionId)
        return try storeAccess { store in
            guard let saved = try store.document(namespace: "revisions", key: key) else { throw DraftFailure.sourceMissing }
            let source = try JSONDecoder().decode(Revision.self, from: saved.payload)
            let draft = try store.document(namespace: "drafts", key: key).map { try JSONText.parse($0.payload) } ?? TextDrafts.empty(revisionId)
            let revision = Self.overlay(source, draft: draft)
            guard let version = revision.versions.first(where: { $0.id == versionId }) else { throw LanguageFailure.versionNotFound }
            guard let original = version.localizations.first(where: { $0.locale == sourceLocale }) else { throw LanguageFailure.sourceNotFound }
            let texts = draft["texts"] ?? .object([])
            func values(_ id: String, _ fields: Fields, _ names: [String]) -> [String: String] {
                Dictionary(uniqueKeysWithValues: names.map { ($0, texts[id]?[$0]?.text ?? fields[$0].map(Self.text) ?? "") })
            }
            let info = revision.appInfos.flatMap(\.localizations).first { $0.fields["locale"]?.text == sourceLocale }
            return LanguageTranslation.Request(sourceLocale: sourceLocale, version: values(original.id, original.fields, LanguageTranslation.versionFields),
                                               appInfo: info.map { values($0.id, $0.fields, LanguageTranslation.appInfoFields) } ?? [:])
        }
    }
}
