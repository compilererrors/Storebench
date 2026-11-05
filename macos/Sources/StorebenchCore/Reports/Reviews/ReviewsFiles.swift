import Foundation

public enum ReviewsFileFailure: Error, Equatable {
    case changedFiles, missing, size
    public var message: String {
        switch self {
        case .changedFiles: "The selected review contents changed after preview. Preview the file again before saving."
        case .missing: "No review snapshot is saved for this app. Download or import reviews before exporting."
        case .size: "The normalized review import exceeds 10 MB. Choose a smaller snapshot."
        }
    }
}

/// The scoped, normalized snapshot used for JSON and CSV transfer.
public struct ReviewsSnapshot: Sendable {
    public let accountId, appId, checkedAt: String
    public let limited: Bool
    public let fullCheckedAt: String?
    public let reviews: [CustomerReview]

    public init(accountId: String, appId: String, checkedAt: String, limited: Bool, fullCheckedAt: String? = nil, reviews: [CustomerReview]) throws {
        guard accountId.range(of: #"\A[A-Za-z0-9_-]{1,200}\z"#, options: .regularExpression) != nil,
              appId.range(of: #"\A[0-9]{1,30}\z"#, options: .regularExpression) != nil else { throw ReviewsFailure.format }
        self.accountId = accountId; self.appId = appId; self.checkedAt = try CustomerReview.isoDate(checkedAt); self.limited = limited
        self.fullCheckedAt = try fullCheckedAt.map(CustomerReview.isoDate); self.reviews = try CustomerReview.sorted(reviews)
    }
    public init(_ value: JSONText) throws {
        guard value["schemaVersion"] == .number(1), let account = value["accountId"]?.text, let app = value["appId"]?.text,
              let checked = value["checkedAt"]?.text, case .bool(let limited)? = value["limited"],
              case .array(let rows)? = value["reviews"] else { throw ReviewsFailure.format }
        if let full = value["fullCheckedAt"], full.text == nil { throw ReviewsFailure.format }
        // Read typed fields directly; serializing and decoding each row repeats the same JSON work.
        let records = try rows.map { row -> CustomerReview in
            guard let id = row["id"]?.text, case .number(let rating)? = row["rating"], rating == rating.rounded(), (1...5).contains(rating),
                  let title = row["title"]?.text, let body = row["body"]?.text, let created = row["createdDate"]?.text, let territory = row["territory"]?.text else { throw ReviewsFailure.format }
            return CustomerReview(id: id, rating: Int(rating), title: title, body: body, createdDate: created, territory: territory)
        }
        try self.init(accountId: account, appId: app, checkedAt: checked, limited: limited, fullCheckedAt: value["fullCheckedAt"]?.text, reviews: records)
    }
    /// Both inputs are immutable validated snapshots. A union by their ASCII IDs retains those guarantees.
    fileprivate init(merged records: [CustomerReview], incoming: ReviewsSnapshot, previous: ReviewsSnapshot?) {
        accountId = incoming.accountId; appId = incoming.appId; checkedAt = incoming.checkedAt
        limited = incoming.limited && (previous?.limited ?? true); fullCheckedAt = incoming.fullCheckedAt ?? previous?.fullCheckedAt
        reviews = CustomerReview.ordered(records)
    }
    public var json: JSONText {
        var fields: [(String, JSONText)] = [("schemaVersion", .number(1)), ("accountId", .string(accountId)), ("appId", .string(appId)), ("checkedAt", .string(checkedAt)), ("limited", .bool(limited))]
        if let fullCheckedAt { fields.append(("fullCheckedAt", .string(fullCheckedAt))) }
        fields.append(("reviews", .array(reviews.map(\.json)))); return .object(fields)
    }
    var metadata: JSONText {
        var fields: [(String, JSONText)] = [("checkedAt", .string(checkedAt)), ("limited", .bool(limited))]
        if let fullCheckedAt { fields.append(("fullCheckedAt", .string(fullCheckedAt))) }; return .object(fields)
    }
}

public struct ReviewDifference: Identifiable, Sendable {
    public let id, label, before, after: String
    public var json: JSONText { .object([("id", .string(id)), ("label", .string(label)), ("before", .string(before)), ("after", .string(after))]) }
}

public enum ReviewsFileFormats {
    public enum Format: Sendable { case json, csv }
    public struct Comparison: Sendable {
        public let snapshot: ReviewsSnapshot, changes: ReviewChanges, differences: [ReviewDifference]
    }
    static let columns = ["account_id", "app_id", "checked_at", "limited", "review_id", "rating", "title", "body", "created_date", "territory"]

    public static func parse(_ files: [Data], accountId: String, appId: String) throws -> ReviewsSnapshot {
        guard files.count == 1 else { throw ReviewsFailure.format }; try Task.checkCancellation()
        let text = try ReportFiles.texts(files, purpose: .reports)[0], snapshot: ReviewsSnapshot
        do {
            if TextSemantics.trim(text).hasPrefix("{") { snapshot = try ReviewsSnapshot(JSONText.parse(Data(TextSemantics.trim(text).utf8))) }
            else {
                let rows = try Delimited.records(Delimited.parse(text), expected: columns).map { $0.mapValues(Delimited.unspreadsheetCell) }
                guard let first = rows.first, ["true", "false"].contains(first["limited"]!),
                      rows.allSatisfy({ row in columns.prefix(4).allSatisfy { row[$0] == first[$0] } }) else { throw ReviewsFailure.format }
                let empty = rows.count == 1 && columns.dropFirst(4).allSatisfy { first[$0] == "" }
                let reviews = try empty ? [] : rows.map { row -> CustomerReview in
                    guard let rating = row["rating"], rating.range(of: #"\A[1-5]\z"#, options: .regularExpression) != nil else { throw ReviewsFailure.format }
                    return CustomerReview(id: row["review_id"]!, rating: Int(rating)!, title: row["title"]!, body: row["body"]!, createdDate: row["created_date"]!, territory: row["territory"]!)
                }
                snapshot = try ReviewsSnapshot(accountId: first["account_id"]!, appId: first["app_id"]!, checkedAt: first["checked_at"]!, limited: first["limited"] == "true", reviews: reviews)
            }
        } catch let error as ReviewsFailure { throw error } catch { throw ReviewsFailure.format }
        guard snapshot.accountId == accountId, snapshot.appId == appId else { throw ReviewsFailure.scope }
        guard snapshot.json.data.count <= 10_000_000 else { throw ReviewsFileFailure.size }
        try Task.checkCancellation(); return snapshot
    }

    /// Counts only incoming reviews. A missing row never removes previously saved feedback.
    public static func compare(_ previous: ReviewsSnapshot?, _ incoming: ReviewsSnapshot) throws -> Comparison {
        try Task.checkCancellation()
        if let previous, previous.accountId != incoming.accountId || previous.appId != incoming.appId { throw ReviewsFailure.scope }
        let old = Dictionary(uniqueKeysWithValues: (previous?.reviews ?? []).map { ($0.id, $0) })
        var records = old, changes = ReviewChanges(), changed = Set<String>()
        for row in incoming.reviews {
            try Task.checkCancellation()
            if let saved = old[row.id] {
                if saved.json == row.json { changes.unchanged += 1 } else { changes.updated += 1; changed.insert(row.id) }
            } else { changes.added += 1; changed.insert(row.id) }
            records[row.id] = row
        }
        changes.limited = incoming.limited && (previous?.limited ?? true)
        let snapshot = ReviewsSnapshot(merged: Array(records.values), incoming: incoming, previous: previous)
        let next = Dictionary(uniqueKeysWithValues: snapshot.reviews.map { ($0.id, $0) })
        var seen = Set<String>(), order: [String] = []
        for row in (previous?.reviews ?? []) + snapshot.reviews { if seen.insert(row.id).inserted { order.append(row.id) } }
        func description(_ row: CustomerReview?) -> String {
            guard let row else { return "Not in this snapshot" }
            return "\(row.rating) / 5 · \(row.territory) · \(row.createdDate)\n\(row.title)\n\(row.body)"
        }
        let differences = order.compactMap { id -> ReviewDifference? in
            guard changed.contains(id) else { return nil }
            return ReviewDifference(id: id, label: old[id] == nil ? "Added review" : "Updated review", before: description(old[id]), after: description(next[id]))
        }
        return Comparison(snapshot: snapshot, changes: changes, differences: differences)
    }

    static func csvRow(_ snapshot: ReviewsSnapshot, _ row: CustomerReview?) -> Data {
        let prefix = [snapshot.accountId, snapshot.appId, snapshot.checkedAt, String(snapshot.limited)]
        let values = row.map { [$0.id, String($0.rating), $0.title, $0.body, $0.createdDate, $0.territory] } ?? Array(repeating: "", count: 6)
        return Data(Delimited.write(.init(columns: (prefix + values).map(Delimited.spreadsheetCell), rows: [])).utf8)
    }
    /// Streams every saved row without applying import byte or table row limits to exports.
    public static func stream(_ snapshot: ReviewsSnapshot, format: Format, append: (Data) throws -> Void) throws {
        try Task.checkCancellation()
        if format == .json {
            var fields: [(String, JSONText)] = [("schemaVersion", .number(1)), ("accountId", .string(snapshot.accountId)), ("appId", .string(snapshot.appId)), ("checkedAt", .string(snapshot.checkedAt)), ("limited", .bool(snapshot.limited))]
            if let full = snapshot.fullCheckedAt { fields.append(("fullCheckedAt", .string(full))) }
            let header = JSONText.object(fields)
            try append(Data((String(header.stringify().dropLast()) + ",\"reviews\":[").utf8))
            for (index, row) in snapshot.reviews.enumerated() { try Task.checkCancellation(); if index > 0 { try append(Data([44])) }; try append(row.json.data) }
            try append(Data("]}".utf8))
        } else {
            try append(Data(Delimited.write(.init(columns: columns, rows: [])).utf8))
            if snapshot.reviews.isEmpty { try append(csvRow(snapshot, nil)) }
            for row in snapshot.reviews { try Task.checkCancellation(); try append(csvRow(snapshot, row)) }
        }
        try Task.checkCancellation()
    }
    public static func export(_ snapshot: ReviewsSnapshot, format: Format) throws -> Data {
        var bytes = Data(); try stream(snapshot, format: format) { bytes.append($0) }; return bytes
    }
}

public struct ReviewsFileState: Sendable {
    public let snapshot: ReviewsSnapshot?
    let revision: PartitionedReports.Revision
}
public struct ReviewsFileReview: Sendable {
    public let changes: ReviewChanges, differences: [ReviewDifference], importId: String
    let account: Account, appId: String, revision: PartitionedReports.Revision
}

extension WorkspaceSession {
    func reviewsFileSnapshot(account: Account, appId: String) throws -> ReviewsFileState {
        try reviewsScope(account, appId: appId); try Task.checkCancellation()
        return try storeAccess { store in
            let mutex = store.directory.appendingPathComponent("reviews-\(JSONText.string("\(account.id)\u{0}\(appId)").rawSHA256.prefix(32)).mutex")
            return try FileMutex.withLock(mutex) {
                try self.reviewsScope(account, appId: appId); try Task.checkCancellation()
                let revision = try PartitionedReports.revision(family: "reviews", accountId: account.id, appId: appId, store: store)
                guard let meta = try self.reviewsMeta(accountId: account.id, appId: appId) else { return ReviewsFileState(snapshot: nil, revision: revision) }
                let rows = try PartitionedReports.items(CustomerReview.self, family: "reviews", legacyKey: "reviews", accountId: account.id, appId: appId, store: store)
                let snapshot = try ReviewsSnapshot(accountId: account.id, appId: appId, checkedAt: meta["checkedAt"]!.string!, limited: meta["limited"] == .bool(true), fullCheckedAt: meta["fullCheckedAt"]?.string, reviews: rows)
                return ReviewsFileState(snapshot: snapshot, revision: revision)
            }
        }
    }
    public func savedReviewsFiles(account: Account, appId: String) throws -> ReviewsFileState { try reviewsFileSnapshot(account: account, appId: appId) }
    public func previewReviewsFile(account: Account, appId: String, files: [Data]) throws -> ReviewsFileReview {
        try reviewsScope(account, appId: appId)
        let incoming = try ReviewsFileFormats.parse(files, accountId: account.id, appId: appId)
        let saved = try reviewsFileSnapshot(account: account, appId: appId), comparison = try ReviewsFileFormats.compare(saved.snapshot, incoming)
        return ReviewsFileReview(changes: comparison.changes, differences: comparison.differences, importId: incoming.json.sha256, account: account, appId: appId, revision: saved.revision)
    }
    public func saveReviewsFile(_ review: ReviewsFileReview, files: [Data]) throws -> ReviewChanges {
        try reviewsScope(review.account, appId: review.appId)
        let incoming = try ReviewsFileFormats.parse(files, accountId: review.account.id, appId: review.appId)
        guard incoming.json.sha256 == review.importId else { throw ReviewsFileFailure.changedFiles }
        var changes = ReviewChanges()
        do {
            try storeAccess { store in
                try PartitionedReports.replaceAll(CustomerReview.self, family: "reviews", legacyKey: "reviews", accountId: review.account.id, appId: review.appId, store: store,
                                                  stateDirectory: store.directory, bucketOf: { String($0.createdDate.prefix(7)) }, encode: \.json, expected: review.revision,
                                                  validate: { try self.reviewsScope(review.account, appId: review.appId); try Task.checkCancellation() }) { previous, meta in
                    let old: ReviewsSnapshot?
                    if let meta {
                        guard let checked = meta["checkedAt"]?.string, case .bool(let limited)? = meta["limited"] else { throw ReviewsFailure.storage }
                        if let full = meta["fullCheckedAt"], full.string == nil { throw ReviewsFailure.storage }
                        old = try ReviewsSnapshot(accountId: review.account.id, appId: review.appId, checkedAt: checked, limited: limited, fullCheckedAt: meta["fullCheckedAt"]?.string, reviews: previous ?? [])
                    } else if previous == nil { old = nil } else { throw ReviewsFailure.storage }
                    let comparison = try ReviewsFileFormats.compare(old, incoming); changes = comparison.changes
                    return (comparison.snapshot.reviews, comparison.snapshot.metadata)
                }
            }
        } catch PartitionedReports.Failure.stale { throw ReviewsFailure.stale }
        return changes
    }
    public func writeReviewsFile(account: Account, appId: String, format: ReviewsFileFormats.Format, to url: URL) throws {
        try reviewsScope(account, appId: appId); try Task.checkCancellation(); try TestIsolation.check(url)
        let saved = try reviewsFileSnapshot(account: account, appId: appId)
        guard let snapshot = saved.snapshot else { throw ReviewsFileFailure.missing }
        try ReportFiles.atomicStream(to: url) { append in
            try ReviewsFileFormats.stream(snapshot, format: format, append: append)
            try self.reviewsScope(account, appId: appId); try Task.checkCancellation()
        }
    }
}
