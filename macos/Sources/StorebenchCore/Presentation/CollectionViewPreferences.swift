import Foundation

public struct CollectionViewPreferences: Sendable, Equatable {
    public enum Failure: Error { case invalid }
    public let page, pageSize, openingLimit: Int
    public let sort: String, descending: Bool, overrides: [String: Bool]
    public init(page: Int = 1, pageSize: Int = 10, openingLimit: Int = 0, sort: String = "default", descending: Bool = false, overrides: [String: Bool] = [:]) throws {
        guard (1...1_000_000).contains(page), CollectionPresentation<Int>.pageSizes.contains(pageSize), CollectionPresentation<Int>.openingLimits.contains(openingLimit),
              sort.range(of: #"\A[A-Za-z0-9._:-]{1,128}\z"#, options: .regularExpression) != nil,
              overrides.count <= 1024, overrides.keys.allSatisfy(Self.validKey) else { throw Failure.invalid }
        self.page = page; self.pageSize = pageSize; self.openingLimit = openingLimit; self.sort = sort; self.descending = descending; self.overrides = overrides
    }
    public static func key(_ components: [String]) -> String { JSONText.array(components.map(JSONText.string)).rawSHA256 }
    static func validKey(_ key: String) -> Bool { key.range(of: #"\A[0-9a-f]{64}\z"#, options: .regularExpression) != nil }
    public init(json: JSONText) throws {
        func number(_ key: String) throws -> Int { guard case .number(let value)? = json[key], let result = Int(exactly: value) else { throw Failure.invalid }; return result }
        guard json["schemaVersion"] == .number(1), let sort = json["sort"]?.text, case .bool(let descending)? = json["descending"], case .object(let values)? = json["overrides"], values.count <= 1024 else { throw Failure.invalid }
        var overrides: [String: Bool] = [:]
        for (key, value) in values { guard overrides[key] == nil, case .bool(let expanded) = value else { throw Failure.invalid }; overrides[key] = expanded }
        try self.init(page: number("page"), pageSize: number("pageSize"), openingLimit: number("openingLimit"), sort: sort, descending: descending, overrides: overrides)
    }
    public var json: JSONText { .object([("schemaVersion", .number(1)), ("page", .number(Double(page))), ("pageSize", .number(Double(pageSize))), ("openingLimit", .number(Double(openingLimit))), ("sort", .string(sort)), ("descending", .bool(descending)), ("overrides", .object(overrides.sorted { $0.key < $1.key }.map { ($0.key, .bool($0.value)) }))]) }
}

extension CollectionPresentation {
    public init(preferences: CollectionViewPreferences, ids: [ID]) {
        self.init(pageSize: preferences.pageSize, openingLimit: preferences.openingLimit)
        choosePage(preferences.page)
        for id in ids { if let expanded = preferences.overrides[CollectionViewPreferences.key([String(describing: id)])] { setExpanded(id, expanded) } }
        reconcile(ids)
    }
    public func preferences(ids: [ID], sort: String, descending: Bool) throws -> CollectionViewPreferences {
        let current = page(ids), prioritized = current.ids + ids.filter { !current.ids.contains($0) }
        let values = prioritized.compactMap { id -> (String, Bool)? in overrides[id].map { (CollectionViewPreferences.key([String(describing: id)]), $0) } }.prefix(1024)
        return try CollectionViewPreferences(page: current.number, pageSize: pageSize, openingLimit: openingLimit, sort: sort, descending: descending, overrides: Dictionary(values, uniquingKeysWith: { _, last in last }))
    }
}

extension WorkspaceSession {
    public func collectionViewPreference(_ key: String) throws -> CollectionViewPreferences? {
        guard CollectionViewPreferences.validKey(key) else { throw CollectionViewPreferences.Failure.invalid }
        return try storeAccess { try $0.document(namespace: "collection_views", key: key).map { try CollectionViewPreferences(json: JSONText.parse($0.payload)) } }
    }
    public func saveCollectionViewPreference(_ key: String, value: CollectionViewPreferences) throws {
        guard CollectionViewPreferences.validKey(key) else { throw CollectionViewPreferences.Failure.invalid }
        _ = try CollectionViewPreferences(json: value.json)
        try storeAccess { store in
            try FileMutex.withLock(store.directory.appendingPathComponent("collection_views.mutex")) {
                try store.transaction { read in
                    if let previous = try read("collection_views", key) { _ = try CollectionViewPreferences(json: JSONText.parse(previous.payload)) }
                    return [.put(namespace: "collection_views", key: key, json: value.json.data)]
                }
            }
        }
    }
}
