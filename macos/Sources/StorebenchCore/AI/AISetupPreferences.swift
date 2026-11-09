import Foundation

/// Local AI setup choices. Deferring the introduction never changes the selected service or starts a model request.
public struct AISetupPreferences: Sendable, Equatable {
    public enum Choice: String, Sendable { case setup, later, never }
    public let revision: Int
    public private(set) var choice: Choice?
    public private(set) var remindAfter: Date?
    public var defaultProvider: AIProvider
    public init() { revision = 0; choice = nil; remindAfter = nil; defaultProvider = .chatgpt }
    private init(_ value: JSONText, revision: Int) throws {
        guard value["schemaVersion"] == .number(1), let provider = value["defaultProvider"]?.text.flatMap(AIProvider.init(rawValue:)) else { throw DraftFailure.invalid }
        let choice: Choice?
        if value["choice"] == .null { choice = nil }
        else { guard let parsed = value["choice"]?.text.flatMap(Choice.init(rawValue:)) else { throw DraftFailure.invalid }; choice = parsed }
        let remindAfter: Date?
        if case .number(let time)? = value["remindAfter"], time.isFinite { remindAfter = Date(timeIntervalSince1970: time) }
        else { guard value["remindAfter"] == .null else { throw DraftFailure.invalid }; remindAfter = nil }
        guard (choice == .later) == (remindAfter != nil) else { throw DraftFailure.invalid }
        self.revision = revision; self.choice = choice; self.remindAfter = remindAfter; defaultProvider = provider
    }
    public func shouldAsk(now: Date = Date()) -> Bool { choice == nil || (choice == .later && remindAfter.map { $0 <= now } == true) }
    public func answering(_ choice: Choice, now: Date = Date()) -> Self {
        var next = self; next.choice = choice
        next.remindAfter = choice == .later ? now.addingTimeInterval(7 * 24 * 60 * 60) : nil
        return next
    }
    private var json: JSONText {
        .object([("schemaVersion", .number(1)), ("choice", choice.map { .string($0.rawValue) } ?? .null),
                 ("remindAfter", remindAfter.map { .number($0.timeIntervalSince1970) } ?? .null), ("defaultProvider", .string(defaultProvider.rawValue))])
    }
    static func stored(_ document: EncryptedDocumentStore.Document?) throws -> Self {
        guard let document else { return .init() }
        return try .init(JSONText.parse(document.payload), revision: document.revision)
    }
    static func encoded(_ value: Self) throws -> Data { _ = try Self(value.json, revision: value.revision); return value.json.data }
}

extension WorkspaceSession {
    public func aiSetupPreferences() throws -> AISetupPreferences {
        try storeAccess { try AISetupPreferences.stored($0.document(namespace: "ai_preferences", key: "current")) }
    }
    public func saveAISetupPreferences(_ preferences: AISetupPreferences) throws -> AISetupPreferences {
        let data = try AISetupPreferences.encoded(preferences)
        return try storeAccess { store in
            try FileMutex.withLock(store.directory.appendingPathComponent("ai_preferences.mutex")) {
                try store.transaction { current in
                    let saved = try AISetupPreferences.stored(current("ai_preferences", "current"))
                    guard saved.revision == preferences.revision else { throw DraftFailure.stale }
                    return [.put(namespace: "ai_preferences", key: "current", json: data)]
                }
                return try AISetupPreferences.stored(store.document(namespace: "ai_preferences", key: "current"))
            }
        }
    }
}
