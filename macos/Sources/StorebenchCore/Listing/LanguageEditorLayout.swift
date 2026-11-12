import Foundation
import Observation

/// App defaults with independent text section choices for each language.
public struct LanguageEditorLayout: Equatable, Sendable {
    public enum Failure: Error { case invalid }
    public enum Group: String, CaseIterable, Sendable {
        case copy, search, links, privacy
        public var title: String { switch self {
        case .copy: "Product page copy"
        case .search: "Search & ASO"
        case .links: "Support & marketing links"
        case .privacy: "Privacy"
        } }
        public var heading: String { switch self {
        case .copy: "Product Page Copy"
        case .search: "Search & ASO"
        case .links: "Support and Marketing Links"
        case .privacy: "Privacy"
        } }
        public var fields: [String] { switch self {
        case .copy: ["promotionalText", "whatsNew", "description"]
        case .search: ["name", "subtitle", "keywords"]
        case .links: ["supportUrl", "marketingUrl"]
        case .privacy: ["privacyPolicyUrl", "privacyChoicesUrl", "privacyPolicyText"]
        } }
    }
    public private(set) var expanded: [Group: Bool]
    public private(set) var languages: [String: [Group: Bool]] = [:]
    public init() { expanded = Dictionary(uniqueKeysWithValues: Group.allCases.map { ($0, true) }) }
    public init(_ value: JSONText) throws {
        guard case .number(let version)? = value["schemaVersion"], [1, 2, 3].contains(version),
              let raw = value["expanded"] else { throw Failure.invalid }
        expanded = try Self.patch(raw)
        guard Group.allCases.allSatisfy({ expanded[$0] != nil }) else { throw Failure.invalid }
        if version == 1 { expanded[.links] = true; expanded[.privacy] = true }
        if version == 3 {
            guard case .object(let entries)? = value["languages"] else { throw Failure.invalid }
            for (locale, patch) in entries {
                guard StoreLocales.codes.contains(locale), languages[locale] == nil else { throw Failure.invalid }
                languages[locale] = try Self.patch(patch)
            }
        }
    }
    public static func patch(_ value: JSONText) throws -> [Group: Bool] {
        guard case .object(let pairs) = value, !pairs.isEmpty else { throw Failure.invalid }
        var result: [Group: Bool] = [:]
        for (key, value) in pairs {
            guard let group = Group(rawValue: key), case .bool(let expanded) = value else { throw Failure.invalid }
            result[group] = expanded
        }
        return result
    }
    public func isExpanded(_ group: Group, locale: String? = nil) -> Bool {
        locale.flatMap { languages[$0]?[group] } ?? expanded[group] ?? true
    }
    public func merging(_ patch: [Group: Bool], locale: String? = nil) throws -> Self {
        guard !patch.isEmpty else { throw Failure.invalid }
        var next = self
        if let locale {
            guard StoreLocales.codes.contains(locale) else { throw Failure.invalid }
            next.languages[locale, default: [:]].merge(patch) { _, new in new }
        } else {
            next.expanded.merge(patch) { _, new in new }
            for locale in Array(next.languages.keys) {
                for group in patch.keys { next.languages[locale]?.removeValue(forKey: group) }
                if next.languages[locale]?.isEmpty == true { next.languages.removeValue(forKey: locale) }
            }
        }
        return next
    }
    public var json: JSONText {
        var fields: [(String, JSONText)] = [("schemaVersion", .number(languages.isEmpty ? 2 : 3)), ("expanded", .object(Group.allCases.map { ($0.rawValue, .bool(expanded[$0]!)) }))]
        if !languages.isEmpty {
            fields.append(("languages", .object(languages.keys.sorted().map { locale in
                (locale, .object(Group.allCases.compactMap { group in languages[locale]?[group].map { (group.rawValue, .bool($0)) } }))
            })))
        }
        return .object(fields)
    }
    static func stored(_ document: EncryptedDocumentStore.Document?) throws -> Self {
        guard let document else { return Self() }
        let raw = try JSONText.parse(document.payload)
        return raw == .null ? Self() : try Self(raw)
    }
    static func mutex(_ key: String) -> String { "language_editor_view_" + JSONText.string(key).rawSHA256.prefix(40) }
}

extension WorkspaceSession {
    public func languageEditorLayout(accountId: String, appId: String) throws -> LanguageEditorLayout {
        try requireHistoryScope(accountId: accountId, appId: appId); try Task.checkCancellation()
        let value = try storeAccess { try LanguageEditorLayout.stored($0.document(namespace: "language_editor_views", key: "\(accountId):\(appId)")) }
        try requireHistoryScope(accountId: accountId, appId: appId); try Task.checkCancellation(); return value
    }
    public func saveLanguageEditorLayout(accountId: String, appId: String, patch: [LanguageEditorLayout.Group: Bool], locale: String? = nil) throws -> LanguageEditorLayout {
        guard !patch.isEmpty else { throw LanguageEditorLayout.Failure.invalid }
        try requireHistoryScope(accountId: accountId, appId: appId)
        let key = "\(accountId):\(appId)"
        return try storeAccess { store in
            try FileMutex.withLock(store.directory.appendingPathComponent(LanguageEditorLayout.mutex(key) + ".mutex")) {
                try requireHistoryScope(accountId: accountId, appId: appId); try Task.checkCancellation()
                var result: LanguageEditorLayout?
                try store.transaction { current in
                    try requireHistoryScope(accountId: accountId, appId: appId)
                    // The transaction also coordinates primary clients using this same document.
                    let value = try LanguageEditorLayout.stored(current("language_editor_views", key)).merging(patch, locale: locale)
                    try requireSessionAccess(); try Task.checkCancellation(); result = value
                    return [.put(namespace: "language_editor_views", key: key, json: value.json.data)]
                }
                guard let result else { throw LanguageEditorLayout.Failure.invalid }; return result
            }
        }
    }
}

/// Optimistic section changes keep their newest values while a prior save finishes.
/// Retrying a failed layout write never saves or changes listing text.
@MainActor @Observable public final class LanguageLayoutEditor {
    public private(set) var layout = LanguageEditorLayout()
    public private(set) var ready = false
    public private(set) var saving = false
    public private(set) var failed = false
    public private(set) var saved = false
    private var pending: [String: [LanguageEditorLayout.Group: Bool]] = [:]
    private var allLanguageEdits: [LanguageEditorLayout.Group: Int] = [:]
    public init() {}
    public func loaded(_ value: LanguageEditorLayout) { guard !saving, pending.isEmpty else { return }; layout = value; ready = true; failed = false }
    public func readFailed() { if !ready { failed = true } }
    public func change(_ patch: [LanguageEditorLayout.Group: Bool], locale: String? = nil) {
        guard ready, !patch.isEmpty else { return }
        guard let value = try? layout.merging(patch, locale: locale) else { return }
        if locale == nil {
            for group in patch.keys { allLanguageEdits[group, default: 0] += 1 }
            for key in Array(pending.keys) where !key.isEmpty {
                for group in patch.keys { pending[key]?.removeValue(forKey: group) }
                if pending[key]?.isEmpty == true { pending.removeValue(forKey: key) }
            }
        }
        layout = value; pending[locale ?? "", default: [:]].merge(patch) { _, new in new }; saved = false
    }
    public func flush(_ save: @MainActor ([LanguageEditorLayout.Group: Bool]) async throws -> LanguageEditorLayout) async {
        await flushScoped { patch, locale in
            guard locale == nil else { throw LanguageEditorLayout.Failure.invalid }
            return try await save(patch)
        }
    }
    public func flushScoped(_ save: @MainActor ([LanguageEditorLayout.Group: Bool], String?) async throws -> LanguageEditorLayout) async {
        guard ready, !saving, !pending.isEmpty else { return }
        saving = true; failed = false; defer { saving = false }
        while !pending.isEmpty {
            guard let key = pending.keys.sorted().first, let patch = pending.removeValue(forKey: key) else { break }
            let locale: String? = key.isEmpty ? nil : key
            let startingAllLanguageEdits = allLanguageEdits
            do {
                let receipt = try await save(patch, locale)
                guard patch.allSatisfy({ entry in
                    if let locale { return receipt.languages[locale]?[entry.key] == entry.value }
                    return receipt.expanded[entry.key] == entry.value
                }) else { throw LanguageEditorLayout.Failure.invalid }
            } catch {
                // A newer app-wide choice also supersedes a language save whose answer failed.
                let retry = patch.filter { locale == nil || allLanguageEdits[$0.key] == startingAllLanguageEdits[$0.key] }
                if retry.isEmpty { continue }
                pending[key] = retry.merging(pending[key] ?? [:]) { _, new in new }; failed = true; return
            }
        }
        saved = true
    }
}
