import CryptoKit
import Foundation

/// Collects one plan's steps and every Apple read it was based on.
final class Planner: @unchecked Sendable {
    let client: AppStoreConnectClient, request: PublishRequest
    var steps: [PublishStep] = [], notes: [String] = [], evidence: [JSONText] = []
    /// Screenshot and app preview files Apple already has where this review wants them, so nothing is sent for them.
    var settled: [String] = []
    func settle(_ fileName: String) { if !settled.contains(fileName) { settled.append(fileName) } }
    init(client: AppStoreConnectClient, request: PublishRequest) { self.client = client; self.request = request }

    static func resource(_ item: AppStoreConnectClient.Resource) -> JSONText {
        func convert(_ value: JSONValue) -> JSONText {
            switch value {
            case .string(let text): .string(text)
            case .number(let number): .number(number)
            case .bool(let flag): .bool(flag)
            case .null: .null
            case .array(let items): .array(items.map(convert))
            case .object(let pairs): .object(pairs.sorted { $0.key < $1.key }.map { ($0.key, convert($0.value)) })
            }
        }
        return .object([("type", .string(item.type)), ("id", .string(item.id)), ("attributes", convert(.object(item.attributes ?? [:]))), ("relationships", convert(.object(item.relationships ?? [:])))])
    }

    /// The Apple read that failed last, named when the review cannot be prepared. A later successful read clears it.
    private(set) var failedRead: String?
    private func reading<T>(_ path: String, _ read: () async throws -> T) async throws -> T {
        failedRead = nil
        do { return try await read() } catch { failedRead = path; throw error }
    }

    func get(_ path: String) async throws -> [AppStoreConnectClient.Resource] {
        let result = try await reading(path) { try await client.get(path) }
        evidence.append(.object([("path", .string(path)), ("result", .array(result.map(Self.resource)))]))
        return result
    }

    /// Lists started ahead of their turn. Each is used, and recorded as evidence, only when planning reaches it, so a review
    /// and its fingerprint are the same as when every read waits for the one before it.
    private var ahead: [String: Task<[AppStoreConnectClient.Resource], Error>] = [:]
    /// Starts lists the plan is about to read one after another, so Apple answers them side by side. The shared request queue
    /// still limits how many run at once.
    func prefetch(lists paths: [String]) {
        for path in paths where ahead[path] == nil {
            let client = client
            ahead[path] = Task { try await client.list(path) }
        }
    }
    /// Stops lists started ahead that planning never reached.
    func cancelAhead() { for task in ahead.values { task.cancel() }; ahead.removeAll() }

    func list(_ path: String) async throws -> [AppStoreConnectClient.Resource] {
        let result = try await reading(path) {
            if let started = ahead.removeValue(forKey: path) { return try await started.value }
            return try await client.list(path)
        }
        evidence.append(.object([("path", .string(path)), ("result", .array(result.map(Self.resource)))]))
        return result
    }

    /// Each country's Apple price points up to the amount it needs, read side by side, six countries at a time, and recorded as
    /// evidence in country order, so the review and its fingerprint do not depend on which answer came first. Apple's pages are
    /// read until they pass the amount while they rise in price, and to the end otherwise.
    func pricePoints(_ owner: PriceOwner, needs: [String: Decimal]) async throws -> [PricePoint] {
        let codes = needs.keys.sorted(), client = client
        let read = try await reading("price-points") {
            try await withThrowingTaskGroup(of: (String, [PricePoint]).self) { group in
                var next = 0, results: [String: [PricePoint]] = [:]
                func add(_ code: String) {
                    group.addTask { (code, try await PricePointCatalog.ladder(owner, territory: code, through: needs[code], page: { try await client.page($0, currentCursor: $1) }).points) }
                }
                for _ in 0..<min(6, codes.count) { add(codes[next]); next += 1 }
                for try await (code, points) in group {
                    results[code] = points
                    if next < codes.count { add(codes[next]); next += 1 }
                }
                return results
            }
        }
        for code in codes {
            evidence.append(.object([("pricePoints", .string(code)), ("result", .array((read[code] ?? []).map { .array([.string($0.id), .string($0.customerPrice)]) }))]))
        }
        return codes.flatMap { read[$0] ?? [] }
    }

    func listWithIncluded(_ path: String) async throws -> (data: [AppStoreConnectClient.Resource], included: [AppStoreConnectClient.Resource]) {
        let result = try await reading(path) { try await client.listWithIncluded(path) }
        evidence.append(.object([("path", .string(path)), ("result", .array(result.data.map(Self.resource))), ("included", .array(result.included.map(Self.resource)))]))
        return result
    }

    @discardableResult
    func add(_ kind: PublishStep.Kind, method: String? = nil, path: [JSONText], label: String, detail: String, before: String? = nil, after: String? = nil, body: JSONText? = nil,
             asset: JSONText? = nil, guard guardValue: JSONText? = nil, group: String? = nil) -> String {
        let key = "step-\(steps.count + 1)"
        steps.append(PublishStep(key: key, group: group, label: label, detail: detail, before: before, after: after, kind: kind, method: method, path: path, body: body, asset: asset, guardValue: guardValue, state: "pending", resultId: nil))
        return key
    }
}

/// Versions and App Information records confirmed to belong to the approved app while one approved review is sent.
/// A record's app never changes, so a later step's check of the same parent needs no second read. Each step still reads the
/// record it writes, and every state and digest check reads Apple again.
final class OwnershipProofs: @unchecked Sendable {
    private let lock = NSLock()
    private var owned: Set<String> = []
    func contains(_ type: String, _ id: String, appId: String) -> Bool { lock.withLock { owned.contains("\(appId)\u{0}\(type)\u{0}\(id)") } }
    func add(_ type: String, _ id: String, appId: String) { lock.withLock { _ = owned.insert("\(appId)\u{0}\(type)\u{0}\(id)") } }
}

/// Resources already confirmed to belong to the approved app during one write check.
final class OwnershipCache: @unchecked Sendable {
    /// What earlier steps of the same approved review confirmed, when this check is part of one.
    let proofs: OwnershipProofs?
    init(proofs: OwnershipProofs? = nil) { self.proofs = proofs }
    var items: [String: AppStoreConnectClient.Resource] = [:]
    /// Owners found by listing the app's own resources, for reads where Apple left the owner link out.
    var owners: [String: (type: String, id: String)] = [:]
    func owner(_ item: AppStoreConnectClient.Resource, _ relation: String) -> (type: String, id: String)? { Apple.owner(item, relation) ?? owners["\(item.type)\u{0}\(item.id)"] }
}

enum Apple {
    static func relationship(_ type: String, _ id: JSONText) -> JSONText { .object([("data", .object([("type", .string(type)), ("id", id)]))]) }
    static func ref(_ key: String) -> JSONText { .object([("$ref", .string(key))]) }
    static func owner(_ item: AppStoreConnectClient.Resource, _ name: String) -> (type: String, id: String)? {
        guard case .object(let relation)? = item.relationships?[name], case .object(let data)? = relation["data"], case .string(let type)? = data["type"], case .string(let id)? = data["id"] else { return nil }
        return (type, id)
    }
    static func owned(_ item: AppStoreConnectClient.Resource, _ name: String, _ type: String, _ id: String) -> Bool { owner(item, name).map { $0 == (type, id) } ?? false }
    /// For a list read through its parent's own path or filtered by its parent, such as a version's languages: Apple sends only links
    /// there, so a missing owner is accepted and only an owner naming another parent is rejected. Reads that use `include=` stay strict.
    static func within(_ item: AppStoreConnectClient.Resource, _ name: String, _ type: String, _ id: String) -> Bool { owner(item, name).map { $0 == (type, id) } ?? true }
    static func state(_ item: AppStoreConnectClient.Resource) -> String {
        let keys: [String]
        switch item.type {
        case "appStoreVersions": keys = ["appVersionState", "appStoreState"]
        case "appInfos": keys = ["state", "appStoreState"]
        default: return item.attributes?["appVersionState"]?.string ?? item.attributes?["state"]?.string ?? item.attributes?["appStoreState"]?.string ?? ""
        }
        for key in keys {
            switch item.attributes?[key] {
            case .string(let value)?: if !value.isEmpty { return value }
            case nil, .null?, .bool(false)?: continue
            case .number(let value)? where value == 0: continue
            default: return "" // A malformed truthy state cannot authorize its fallback.
            }
        }
        return ""
    }
    static let editable: Set<String> = ["PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED", "INVALID_BINARY", "READY_FOR_REVIEW"]
    static func sha(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func text(_ value: JSONValue?) -> String? { switch value { case .string(let text)?: text; case .number(let number)?: JSONText.number(number); default: nil } }
    static func delivery(_ item: AppStoreConnectClient.Resource) -> String {
        for key in ["videoDeliveryState", "assetDeliveryState"] { if case .object(let state)? = item.attributes?[key], case .string(let value)? = state["state"] { return value } }
        return ""
    }
    /// Canonical JSON: object keys sorted (English collation), undefined values dropped.
    static func canonical(_ value: JSONText) -> String { PricingModels.canonical(value).stringify() }

    static func releaseDigest(_ attributes: [String: JSONValue]?) throws -> String {
        let type = attributes?["releaseType"]?.string ?? ""
        guard ["MANUAL", "AFTER_APPROVAL", "SCHEDULED"].contains(type) else { throw PublishFailure.invalid("Apple did not confirm this version's release method. Refresh before changing it.") }
        var date: String?
        if case .string(let text)? = attributes?["earliestReleaseDate"] {
            guard let parsed = ISO8601DateFormatter.storebench.date(from: text) ?? ISO8601DateFormatter().date(from: text) else { throw PublishFailure.invalid("Apple did not confirm this version's release date. Refresh before changing it.") }
            date = ISO8601DateFormatter.storebench.string(from: parsed)
        }
        guard (type == "SCHEDULED") == (date != nil) else { throw PublishFailure.invalid("Apple did not confirm this version's release date. Refresh before changing it.") }
        return sha("\(type)\u{0}\(date ?? "")")
    }

    static func jsonDigest(_ value: JSONText) -> String { value.sha256 }
}
