import Foundation

/// The view of each release is kept separately from its plan, listing and Apple state.
public struct ReleaseCardPreferences: Sendable, Equatable {
    public enum Failure: Error { case invalid }
    public enum Answer: Sendable { case yes, later, no }
    public enum Change: Sendable {
        case observe([String])
        case expanded([String], Bool)
        case defaultExpanded(Bool)
        case suggestions(Bool)
        case answer(Answer, Date)
    }
    public private(set) var defaultExpanded = true
    public private(set) var asksAboutMinimizing = true
    public private(set) var askAfter: Date?
    public private(set) var releases: [String: Bool] = [:]

    public init() {}
    public static func key(accountId: String, appId: String, platform: String, version: String) -> String {
        CollectionViewPreferences.key([accountId, appId, platform, version])
    }
    public func expanded(_ key: String) -> Bool { releases[key] ?? defaultExpanded }
    public func canSuggest(at date: Date) -> Bool {
        defaultExpanded && asksAboutMinimizing && askAfter.map { date >= $0 } != false
    }
    public func applying(_ change: Change) throws -> Self {
        var next = self
        switch change {
        case .observe(let keys):
            for key in keys { guard Self.valid(key) else { throw Failure.invalid }; if next.releases[key] == nil { next.releases[key] = defaultExpanded } }
        case .expanded(let keys, let expanded):
            for key in keys { guard Self.valid(key) else { throw Failure.invalid }; next.releases[key] = expanded }
        case .defaultExpanded(let expanded): next.defaultExpanded = expanded
        case .suggestions(let enabled): next.asksAboutMinimizing = enabled; next.askAfter = nil
        case .answer(let answer, let date):
            guard date.timeIntervalSince1970.isFinite, (0...253_402_000_000).contains(date.timeIntervalSince1970) else { throw Failure.invalid }
            switch answer {
            case .yes: next.defaultExpanded = false; next.askAfter = nil
            case .later: next.askAfter = date.addingTimeInterval(24 * 60 * 60)
            case .no: next.asksAboutMinimizing = false; next.askAfter = nil
            }
        }
        guard next.releases.count <= 20_000 else { throw Failure.invalid }
        return next
    }
    private static func valid(_ key: String) -> Bool { key.range(of: #"\A[0-9a-f]{64}\z"#, options: .regularExpression) != nil }
    public init(json: JSONText) throws {
        guard json["schemaVersion"] == .number(1), case .bool(let expanded)? = json["defaultExpanded"],
              case .bool(let asks)? = json["asksAboutMinimizing"], case .object(let records)? = json["releases"], records.count <= 20_000 else { throw Failure.invalid }
        defaultExpanded = expanded; asksAboutMinimizing = asks
        if case .number(let seconds)? = json["askAfter"] {
            guard seconds.isFinite, (0...253_402_100_000).contains(seconds) else { throw Failure.invalid }
            askAfter = Date(timeIntervalSince1970: seconds)
        } else if json["askAfter"] != .null { throw Failure.invalid }
        for (key, value) in records {
            guard Self.valid(key), releases[key] == nil, case .bool(let expanded) = value else { throw Failure.invalid }
            releases[key] = expanded
        }
    }
    public var json: JSONText {
        .object([("schemaVersion", .number(1)), ("defaultExpanded", .bool(defaultExpanded)), ("asksAboutMinimizing", .bool(asksAboutMinimizing)),
                 ("askAfter", askAfter.map { .number($0.timeIntervalSince1970) } ?? .null),
                 ("releases", .object(releases.sorted { $0.key < $1.key }.map { ($0.key, .bool($0.value)) }))])
    }
}

extension WorkspaceSession {
    public func releaseCardPreferences() throws -> ReleaseCardPreferences {
        try storeAccess { store in
            try store.document(namespace: "release_card_preferences", key: "current").map { try ReleaseCardPreferences(json: JSONText.parse($0.payload)) } ?? ReleaseCardPreferences()
        }
    }
    /// Merge only the requested view changes while holding the shared process lock.
    public func updateReleaseCardPreferences(_ change: ReleaseCardPreferences.Change) throws -> ReleaseCardPreferences {
        try storeAccess { store in
            try FileMutex.withLock(store.directory.appendingPathComponent("release_card_preferences.mutex")) {
                var result = ReleaseCardPreferences()
                try store.transaction { read in
                    let previous = try read("release_card_preferences", "current").map { try ReleaseCardPreferences(json: JSONText.parse($0.payload)) } ?? ReleaseCardPreferences()
                    result = try previous.applying(change)
                    return result == previous ? [] : [.put(namespace: "release_card_preferences", key: "current", json: result.json.data)]
                }
                return result
            }
        }
    }
}
