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

    func list(_ path: String) async throws -> [AppStoreConnectClient.Resource] {
        let result = try await reading(path) { try await client.list(path) }
        evidence.append(.object([("path", .string(path)), ("result", .array(result.map(Self.resource)))]))
        return result
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

/// Resources already confirmed to belong to the approved app during one write check.
final class OwnershipCache: @unchecked Sendable {
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
