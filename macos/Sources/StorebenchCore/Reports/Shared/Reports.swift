import CryptoKit
import Foundation

/// Reads report histories saved in the partitioned layout: an index in `<family>_index`
/// naming one document per bucket in `<family>_part`, or the older single document in `<family>`.
public enum PartitionedReports {
    struct Index: Decodable { let schemaVersion: Int; let accountId: String; let appId: String; let buckets: [String: Entry]; struct Entry: Decodable { let fingerprint: String; let items: Int } }
    struct Bucket<Item: Decodable>: Decodable { let schemaVersion: Int; let accountId: String; let appId: String; let bucket: String; let items: [Item] }
    public enum Failure: Error, Equatable { case invalid, stale }

    public static func items<Item: Decodable>(_ type: Item.Type, family: String, legacyKey: String, accountId: String, appId: String, store: EncryptedDocumentStore) throws -> [Item] {
        let scope = "\(accountId):\(appId)", decoder = JSONDecoder()
        if let document = try store.document(namespace: "\(family)_index", key: scope) {
            let index = try decoder.decode(Index.self, from: document.payload)
            guard index.schemaVersion == 1, index.accountId == accountId, index.appId == appId else { throw Failure.invalid }
            return try index.buckets.sorted { $0.key < $1.key }.flatMap { bucket, entry -> [Item] in
                guard entry.fingerprint.count == 64, let part = try store.document(namespace: "\(family)_part", key: "\(scope):\(bucket):\(entry.fingerprint.prefix(32))") else { throw Failure.invalid }
                let saved = try decoder.decode(Bucket<Item>.self, from: part.payload)
                guard saved.schemaVersion == 1, saved.bucket == bucket, saved.accountId == accountId, saved.appId == appId, saved.items.count == entry.items else { throw Failure.invalid }
                return saved.items
            }
        }
        guard let legacy = try store.document(namespace: family, key: scope),
              let object = try JSONSerialization.jsonObject(with: legacy.payload) as? [String: Any], let list = object[legacyKey] else { return [] }
        return try decoder.decode([Item].self, from: JSONSerialization.data(withJSONObject: list))
    }
}

/// One saved Summary Sales report period. Missing days are unknown, never zero.
public struct SalesSummary: Decodable, Sendable, Identifiable {
    public let beginDate: String
    public let endDate: String
    public let importedAt: String
    public let unitsByTerritory: [String: Double]
    public let noSales: Bool?
    public var id: String { "\(beginDate):\(endDate)" }
    public var paidUnits: Double { unitsByTerritory.values.reduce(0, +) }
}

extension WorkspaceSession {
    public func sales(accountId: String, appId: String) throws -> [SalesSummary] {
        try storeAccess { try PartitionedReports.items(SalesSummary.self, family: "sales", legacyKey: "reports", accountId: accountId, appId: appId, store: $0) }
            .sorted { $0.beginDate < $1.beginDate }
    }
}

extension PartitionedReports {
    /// The stored revisions a reviewed change was prepared against.
    public struct Revision: Equatable, Sendable {
        public let index: Int?, legacy: Int?
        let indexFingerprint: String?, legacyFingerprint: String?
    }
    static func basis(index: EncryptedDocumentStore.Document?, legacy: EncryptedDocumentStore.Document?) -> Revision {
        func digest(_ document: EncryptedDocumentStore.Document?) -> String? { document.map { SHA256.hash(data: $0.payload).map { String(format: "%02x", $0) }.joined() } }
        return Revision(index: index?.revision, legacy: legacy?.revision, indexFingerprint: digest(index), legacyFingerprint: digest(legacy))
    }

    public static func revision(family: String, accountId: String, appId: String, store: EncryptedDocumentStore) throws -> Revision {
        let scope = "\(accountId):\(appId)", index = try store.document(namespace: "\(family)_index", key: scope)
        return basis(index: index, legacy: index == nil ? try store.document(namespace: family, key: scope) : nil)
    }
    static func fingerprints<Item: Decodable>(_ type: Item.Type, family: String, legacyKey: String, accountId: String, appId: String,
        store: EncryptedDocumentStore, bucketOf: (Item) -> String, encode: (Item) -> JSONText) throws -> [(String, String)] {
        if let document = try store.document(namespace: "\(family)_index", key: "\(accountId):\(appId)") {
            let index = try JSONDecoder().decode(Index.self, from: document.payload)
            guard index.schemaVersion == 1, index.accountId == accountId, index.appId == appId,
                  index.buckets.allSatisfy({ $0.value.items >= 0 && SyncReceipt.hash($0.value.fingerprint) && $0.key.range(of: #"\A[A-Za-z0-9._-]+(?::[A-Za-z0-9._-]+)*\z"#, options: .regularExpression) != nil }) else { throw Failure.invalid }
            return index.buckets.sorted { $0.key < $1.key }.map { ($0.key, $0.value.fingerprint) }
        }
        let values = try items(type, family: family, legacyKey: legacyKey, accountId: accountId, appId: appId, store: store)
        return Dictionary(grouping: values, by: bucketOf).sorted { $0.key < $1.key }.map { ($0.key, JSONText.array($0.value.map(encode)).sha256) }
    }

    struct ViewDocument<Item: Decodable>: Decodable { let version: Int; let fingerprint: String; let views: [Item] }
    public enum ViewFailure: Error, Equatable { case notPrepared }

    /// Prepared per-bucket data (`<family>_view`) at the expected version. A missing or older view is reported, not rebuilt here.
    public static func views<Item: Decodable>(_ type: Item.Type, family: String, version: Int, accountId: String, appId: String, store: EncryptedDocumentStore) throws -> [Item] {
        let scope = "\(accountId):\(appId)", decoder = JSONDecoder()
        guard let document = try store.document(namespace: "\(family)_index", key: scope) else {
            if try store.document(namespace: family, key: scope) != nil { throw ViewFailure.notPrepared }
            return []
        }
        let index = try decoder.decode(Index.self, from: document.payload)
        guard index.schemaVersion == 1, index.accountId == accountId, index.appId == appId else { throw Failure.invalid }
        return try index.buckets.sorted { $0.key < $1.key }.flatMap { bucket, entry -> [Item] in
            guard entry.items >= 0, entry.fingerprint.range(of: #"\A[a-f0-9]{64}\z"#, options: .regularExpression) != nil else { throw Failure.invalid }
            guard let saved = try store.document(namespace: "\(family)_view", key: "\(scope):\(bucket):\(entry.fingerprint.prefix(32))"),
                  let view = try? decoder.decode(ViewDocument<Item>.self, from: saved.payload), view.version == version, view.fingerprint == entry.fingerprint,
                  view.views.count == entry.items else { throw ViewFailure.notPrepared }
            return view.views
        }
    }
}

/// One saved Analytics report period with its facts, as prepared for views.
public struct AnalyticsPeriod: Codable, Sendable, Identifiable, Equatable {
    public struct Fact: Codable, Sendable, Equatable { public let territory: String; public let source: String; public let device: String; public let metric: String; public let count: Double }
    public let key: String
    public let kind: String
    public let level: String
    public let granularity: String
    public let processingDate: String
    public let date: String
    public let endDate: String
    public let facts: [Fact]
    public var id: String { key }
    public func total(_ metric: String) -> Double { facts.filter { $0.metric == metric }.reduce(0) { $0 + $1.count } }
}

public struct CustomerReview: Codable, Sendable, Identifiable {
    public init(id: String, rating: Int, title: String, body: String, createdDate: String, territory: String) {
        self.id = id; self.rating = rating; self.title = title; self.body = body; self.createdDate = createdDate; self.territory = territory
    }
    public let id: String
    public let rating: Int
    public let title: String
    public let body: String
    public let createdDate: String
    public let territory: String
}

extension WorkspaceSession {
    public func analytics(accountId: String, appId: String) throws -> [AnalyticsPeriod] {
        try storeAccess { store in
            do { return try PartitionedReports.views(AnalyticsPeriod.self, family: "analytics", version: 1, accountId: accountId, appId: appId, store: store) }
            catch PartitionedReports.ViewFailure.notPrepared {
                // A single-document history or an older view is summarized from the saved rows.
                var partitions: [AnalyticsPartition] = []
                try self.visitAnalyticsFiles(accountId: accountId, appId: appId, store: store) { partitions += $0 }
                return try JSONDecoder().decode([AnalyticsPeriod].self, from: AnalyticsReports.view(partitions).data)
            }
        }.sorted { $0.date < $1.date }
    }

    public func reviews(accountId: String, appId: String) throws -> [CustomerReview] {
        _ = try reviewsMeta(accountId: accountId, appId: appId)
        let records = try storeAccess { try PartitionedReports.items(CustomerReview.self, family: "reviews", legacyKey: "reviews", accountId: accountId, appId: appId, store: $0) }
        return try CustomerReview.sorted(records)
    }
}

extension PartitionedReports {
    /// Replaces an app's whole report history in the partitioned store, under the same
    /// process-shared mutex: new buckets first under content-addressed keys, then one transaction that switches
    /// the index (and retires an older single-document history), then removal of documents no longer referenced.
    public static func replaceAll<Item: Decodable>(_ type: Item.Type, family: String, legacyKey: String, accountId: String, appId: String,
                                                   store: EncryptedDocumentStore, stateDirectory: URL, onlyBuckets: Set<String>? = nil,
                                                   bucketOf: (Item) -> String, encode: (Item) -> JSONText,
                                                   view: (version: Int, build: ([Item]) throws -> JSONText)? = nil, expected: Revision? = nil, validate: (() throws -> Void)? = nil,
                                                   committed: ((Revision) -> Void)? = nil,
                                                   committedBuckets: (([(String, String)]) -> Void)? = nil,
                                                   additionalWrites: () throws -> [EncryptedDocumentStore.Write] = { [] },
                                                   change: (_ previous: [Item]?, _ previousMeta: [String: JSONValue]?) throws -> (items: [Item], meta: JSONText?)) throws {
        guard accountId.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil, appId.range(of: "^[0-9]+$", options: .regularExpression) != nil else { throw Failure.invalid }
        let scope = "\(accountId):\(appId)", decoder = JSONDecoder()
        let mutexName = "\(family)-" + JSONText.string("\(accountId)\u{0}\(appId)").rawSHA256.prefix(32)
        try FileMutex.withLock(stateDirectory.appendingPathComponent("\(mutexName).mutex")) {
            let indexDocument = try store.document(namespace: "\(family)_index", key: scope)
            let legacyDocument = indexDocument == nil ? try store.document(namespace: family, key: scope) : nil
            // A reviewed change is saved only onto the history it was reviewed against.
            let startingBasis = basis(index: indexDocument, legacy: legacyDocument)
            if let expected, expected != startingBasis { throw Failure.stale }
            var previous: [Item]?, previousMeta: [String: JSONValue]?
            var kept: [(String, JSONText)] = []
            if let indexDocument, let onlyBuckets {
                // A bucket-scoped update: read and replace only the named buckets, keep the rest of the index.
                let index = try decoder.decode(Index.self, from: indexDocument.payload)
                previous = []
                for (bucket, entry) in index.buckets.sorted(by: { $0.key < $1.key }) {
                    if onlyBuckets.contains(bucket) {
                        guard let part = try store.document(namespace: "\(family)_part", key: "\(scope):\(bucket):\(entry.fingerprint.prefix(32))") else { throw Failure.invalid }
                        previous! += try decoder.decode(Bucket<Item>.self, from: part.payload).items
                    } else { kept.append((bucket, .object([("fingerprint", .string(entry.fingerprint)), ("items", .number(Double(entry.items)))]))) }
                }
                if case .object(let meta)? = (try JSONDecoder().decode([String: JSONValue].self, from: indexDocument.payload))["meta"] { previousMeta = meta }
            } else if let indexDocument {
                previous = try items(type, family: family, legacyKey: legacyKey, accountId: accountId, appId: appId, store: store)
                if case .object(let meta)? = (try JSONDecoder().decode([String: JSONValue].self, from: indexDocument.payload))["meta"] { previousMeta = meta }
            } else if let legacyDocument {
                let object = try decoder.decode([String: JSONValue].self, from: legacyDocument.payload)
                previous = try items(type, family: family, legacyKey: legacyKey, accountId: accountId, appId: appId, store: store)
                previousMeta = object.filter { !["schemaVersion", "accountId", "appId", legacyKey].contains($0.key) }
            }
            let next = try change(previous, previousMeta)
            var grouped: [String: [Item]] = [:], order: [String] = []
            for item in next.items {
                let bucket = bucketOf(item)
                guard bucket.range(of: #"^[A-Za-z0-9._-]+(?::[A-Za-z0-9._-]+)*$"#, options: .regularExpression) != nil else { throw Failure.invalid }
                if grouped[bucket] == nil { order.append(bucket) }
                grouped[bucket, default: []].append(item)
            }
            // A write may only replace buckets it has read; anything else would drop unseen reports.
            for bucket in order where kept.contains(where: { $0.0 == bucket }) { throw Failure.invalid }
            var buckets: [(String, JSONText)] = kept.filter { entry in !order.contains(entry.0) }
            for bucket in order.sorted() {
                let values = JSONText.array(grouped[bucket]!.map(encode)), fingerprint = values.sha256
                let part = JSONText.object([("schemaVersion", .number(1)), ("accountId", .string(accountId)), ("appId", .string(appId)), ("bucket", .string(bucket)), ("items", values)])
                try store.insertIfAbsent(namespace: "\(family)_part", key: "\(scope):\(bucket):\(fingerprint.prefix(32))", json: part.data)
                if let view {
                    // Small derived data beside each bucket, so views need not read raw report rows.
                    let document = JSONText.object([("version", .number(Double(view.version))), ("fingerprint", .string(fingerprint)), ("views", try view.build(grouped[bucket]!))])
                    let key = "\(scope):\(bucket):\(fingerprint.prefix(32))", payload = document.data
                    // Compare the rebuilt bytes after validating source; identical derived data needs no extra encrypted write.
                    if try store.document(namespace: "\(family)_view", key: key)?.payload != payload {
                        try store.transaction { _ in [.put(namespace: "\(family)_view", key: key, json: payload)] }
                    }
                }
                buckets.append((bucket, .object([("fingerprint", .string(fingerprint)), ("items", .number(Double(grouped[bucket]!.count)))])))
            }
            buckets.sort { $0.0 < $1.0 }
            var indexFields: [(String, JSONText)] = [("schemaVersion", .number(1)), ("accountId", .string(accountId)), ("appId", .string(appId)), ("buckets", .object(buckets))]
            if let meta = next.meta { indexFields.append(("meta", meta)) }
            let empty = buckets.isEmpty && next.meta == nil
            try store.transaction { current in
                try validate?()
                let savedIndex = try current("\(family)_index", scope), savedLegacy = indexDocument == nil ? try current(family, scope) : nil
                guard basis(index: savedIndex, legacy: savedLegacy) == startingBasis else { throw Failure.stale }
                var writes: [EncryptedDocumentStore.Write] = empty ? (indexDocument == nil ? [] : [.delete(namespace: "\(family)_index", key: scope)]) : [.put(namespace: "\(family)_index", key: scope, json: JSONText.object(indexFields).data)]
                if legacyDocument != nil { writes.append(.delete(namespace: family, key: scope)) }
                writes += try additionalWrites()
                return writes
            }
            if let committed { committed(try revision(family: family, accountId: accountId, appId: appId, store: store)) }
            committedBuckets?(buckets.map { ($0.0, $0.1["fingerprint"]!.text!) })
            // Leftover documents from replaced buckets; a later write removes anything an interruption leaves.
            let referenced = Set(buckets.map { bucket -> String in
                guard case .object(let entry) = bucket.1, case .string(let fingerprint)? = entry.first?.1 else { return "" }
                return "\(scope):\(bucket.0):\(fingerprint.prefix(32))"
            })
            for namespace in ["\(family)_part", "\(family)_view"] {
                for stale in (try? store.documents(namespace: namespace, prefix: "\(scope):")) ?? [] where !referenced.contains(stale.key) { try? store.delete(namespace: namespace, key: stale.key) }
            }
        }
    }
}

extension JSONText {
    /// SHA-256 of the raw text content (used for mutex names, hashing the plain string).
    var rawSHA256: String {
        guard case .string(let text) = self else { return sha256 }
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

extension WorkspaceSession {
    /// Recomputes every bucket's fingerprint from its stored items, as every reader does.
    public func verifyBuckets(family: String, accountId: String, appId: String) throws {
        try storeAccess { store in
            let scope = "\(accountId):\(appId)"
            guard let index = try store.document(namespace: "\(family)_index", key: scope) else { return }
            let buckets = try JSONDecoder().decode(PartitionedReports.Index.self, from: index.payload).buckets
            for (bucket, entry) in buckets {
                guard let part = try store.document(namespace: "\(family)_part", key: "\(scope):\(bucket):\(entry.fingerprint.prefix(32))"),
                      let text = String(data: part.payload, encoding: .utf8), let start = text.range(of: #""items":"#)?.upperBound,
                      SHA256.hash(data: Data(text[start..<text.index(before: text.endIndex)].utf8)).map({ String(format: "%02x", $0) }).joined() == entry.fingerprint
                else { throw PartitionedReports.Failure.invalid }
            }
        }
    }
}
