import Foundation
import Observation

/// App-scoped section preferences shared with the primary language editor.
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
        public var fields: [String] { switch self {
        case .copy: ["promotionalText", "whatsNew", "description"]
        case .search: ["name", "subtitle", "keywords"]
        case .links: ["supportUrl", "marketingUrl"]
        case .privacy: ["privacyPolicyUrl", "privacyChoicesUrl", "privacyPolicyText"]
        } }
    }
    public private(set) var expanded: [Group: Bool]
    public init() { expanded = Dictionary(uniqueKeysWithValues: Group.allCases.map { ($0, true) }) }
    public init(_ value: JSONText) throws {
        guard case .number(let version)? = value["schemaVersion"], version == 1 || version == 2,
              let raw = value["expanded"] else { throw Failure.invalid }
        expanded = try Self.patch(raw)
        guard Group.allCases.allSatisfy({ expanded[$0] != nil }) else { throw Failure.invalid }
        if version == 1 { expanded[.links] = true; expanded[.privacy] = true }
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
    public func merging(_ patch: [Group: Bool]) throws -> Self {
        guard !patch.isEmpty else { throw Failure.invalid }
        var next = self; next.expanded.merge(patch) { _, new in new }; return next
    }
    public var json: JSONText { .object([("schemaVersion", .number(2)), ("expanded", .object(Group.allCases.map { ($0.rawValue, .bool(expanded[$0]!)) }))]) }
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
    public func saveLanguageEditorLayout(accountId: String, appId: String, patch: [LanguageEditorLayout.Group: Bool]) throws -> LanguageEditorLayout {
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
                    let value = try LanguageEditorLayout.stored(current("language_editor_views", key)).merging(patch)
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
    private var pending: [LanguageEditorLayout.Group: Bool] = [:]
    public init() {}
    public func loaded(_ value: LanguageEditorLayout) { guard !saving, pending.isEmpty else { return }; layout = value; ready = true; failed = false }
    public func readFailed() { if !ready { failed = true } }
    public func change(_ patch: [LanguageEditorLayout.Group: Bool]) {
        guard ready, !patch.isEmpty else { return }
        guard let value = try? layout.merging(patch) else { return }
        layout = value; pending.merge(patch) { _, new in new }; saved = false
    }
    public func flush(_ save: @MainActor ([LanguageEditorLayout.Group: Bool]) async throws -> LanguageEditorLayout) async {
        guard ready, !saving, !pending.isEmpty else { return }
        saving = true; failed = false; defer { saving = false }
        while !pending.isEmpty {
            let patch = pending; pending = [:]
            do {
                let receipt = try await save(patch)
                guard patch.allSatisfy({ receipt.expanded[$0.key] == $0.value }) else { throw LanguageEditorLayout.Failure.invalid }
            } catch { pending = patch.merging(pending) { _, new in new }; failed = true; return }
        }
        saved = true
    }
}
