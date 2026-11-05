import Foundation

public enum ReviewsFailure: Error, Equatable { case format, integrity, noKey, scope, stale, storage, timeout }

extension CustomerReview {
    private static let timestampPattern = try! NSRegularExpression(pattern: #"\A[0-9]{4}-[0-9]{2}-[0-9]{2}T(?:[01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](?:\.[0-9]{1,3})?(?:Z|[+-][0-9]{2}:[0-9]{2})\z"#)
    /// The stored form, in its fixed field order, so bucket fingerprints match.
    public var json: JSONText {
        .object([("id", .string(id)), ("rating", .number(Double(rating))), ("title", .string(title)), ("body", .string(body)), ("createdDate", .string(createdDate)), ("territory", .string(territory))])
    }

    /// Normalizes accepted timestamps to UTC with millisecond precision.
    static func isoDate(_ value: String) throws -> String {
        guard timestampPattern.firstMatch(in: value, range: NSRange(value.startIndex..<value.endIndex, in: value)) != nil,
              PeriodDates.number(String(value.prefix(10))) != nil else { throw ReviewsFailure.format }
        if value.hasSuffix("Z") {
            let base = String(value.prefix(19)), suffix = value.dropFirst(19).dropLast()
            let fraction = suffix.isEmpty ? "000" : String(suffix.dropFirst()).padding(toLength: 3, withPad: "0", startingAt: 0)
            return base + "." + fraction + "Z"
        }
        guard let date = ISODateParser.date(value) else { throw ReviewsFailure.format }
        return isoString(date)
    }

    static func isoString(_ date: Date) -> String {
        ISODateParser.text(date)
    }

    /// A review from App Store Connect, without the reviewer's nickname, validated before it is stored.
    init(apple resource: AppStoreConnectClient.Resource) throws {
        guard resource.type == "customerReviews", resource.id.range(of: "^[A-Za-z0-9_-]{1,256}$", options: .regularExpression) != nil else { throw ReviewsFailure.integrity }
        let attributes = resource.attributes ?? [:]
        guard case .number(let rating)? = attributes["rating"], rating == rating.rounded(), (1...5).contains(rating),
              let created = attributes["createdDate"]?.string else { throw ReviewsFailure.format }
        func text(_ value: JSONValue?) throws -> String {
            if value == nil || value == .null { return "" }
            guard case .string(let text)? = value else { throw ReviewsFailure.format }; return text
        }
        func truthy(_ value: JSONValue?) -> Bool {
            switch value { case nil, .null: false; case .bool(let value): value; case .number(let value): value != 0; case .string(let value): !value.isEmpty; default: true }
        }
        var related: JSONValue?
        if case .object(let relationship)? = resource.relationships?["reviewTerritory"], truthy(relationship["data"]) {
            guard case .object(let data)? = relationship["data"], data["type"]?.string == "territories" else { throw ReviewsFailure.integrity }; related = data["id"]
        }
        let stated = attributes["territory"]
        if truthy(related), truthy(stated), related != stated { throw ReviewsFailure.integrity }
        let selected = truthy(stated) ? stated : truthy(related) ? related : .string("UNKNOWN")
        guard let territory = selected?.string else { throw ReviewsFailure.format }
        self = try CustomerReview(id: resource.id, rating: Int(rating), title: text(attributes["title"]), body: text(attributes["body"]), createdDate: created, territory: territory).normalized()
    }
    public func normalized() throws -> CustomerReview {
        let identifier = id.utf8, country = territory.utf8
        guard (1...256).contains(identifier.count), identifier.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 || $0 == 45 }), (1...5).contains(rating),
              title.utf16.count <= 1000, body.utf16.count <= 16000,
              TextSemantics.validControlText(title), TextSemantics.validControlText(body),
              country.count == 3 && country.allSatisfy({ (65...90).contains($0) }) || country.elementsEqual("UNKNOWN".utf8) else { throw ReviewsFailure.format }
        return .init(id: id, rating: rating, title: title, body: body, createdDate: try Self.isoDate(createdDate), territory: territory)
    }
    public static func sorted(_ records: [CustomerReview]) throws -> [CustomerReview] {
        let normalized = try records.map { try $0.normalized() }
        guard Set(normalized.map(\.id)).count == normalized.count else { throw ReviewsFailure.integrity }
        return ordered(normalized)
    }
    /// Only immutable snapshots and `sorted` call this with rows already validated and normalized.
    static func ordered(_ records: [CustomerReview]) -> [CustomerReview] {
        records.sorted { $0.createdDate == $1.createdDate ? $0.id.compare($1.id, locale: Locale(identifier: "en")) == .orderedAscending : $0.createdDate > $1.createdDate }
    }
}

public struct ReviewChanges: Equatable, Sendable {
    public var added = 0, updated = 0, unchanged = 0, removed = 0
    public var limited = false
    var json: JSONText { .object([("added", .number(Double(added))), ("updated", .number(Double(updated))), ("unchanged", .number(Double(unchanged))), ("removed", .number(Double(removed))), ("limited", .bool(limited))]) }
}

extension WorkspaceSession {
    /// Downloads reviews newest first and merges them into the saved history: new and changed reviews are saved,
    /// reviews Apple no longer returns are kept. Every page is read when nothing complete is saved yet and at least weekly.
    func downloadReviewsBody(account: Account, appId: String, client: AppStoreConnectClient, now: Date,
                             check: @escaping () throws -> Void, progress: (ReviewsDownloadJob.Phase, Int, Int) throws -> Void,
                             completion: (ReviewChanges, EncryptedDocumentStore) throws -> [EncryptedDocumentStore.Write]) async throws -> ReviewChanges {
        try reviewsScope(account, appId: appId); _ = try currentAccount(account, client: client); try check()
        let revision = try storeAccess { try PartitionedReports.revision(family: "reviews", accountId: account.id, appId: appId, store: $0) }
        let saved = try reviews(accountId: account.id, appId: appId), meta = try reviewsMeta(accountId: account.id, appId: appId)
        let lastFull = meta?["fullCheckedAt"]?.string.flatMap { try? CustomerReview.isoDate($0) }.flatMap { ISO8601DateFormatter.fractional.date(from: $0) }
        let full = meta?["limited"] != .bool(false) || lastFull.map { now.timeIntervalSince($0) > 7 * 86_400 } ?? true
        let known = full ? [:] : Dictionary(uniqueKeysWithValues: saved.map { ($0.id, $0.json.data) })

        let path = "/v1/apps/\(appId)/customerReviews?limit=200&sort=-createdDate&fields%5BcustomerReviews%5D=rating,title,body,createdDate,territory,reviewTerritory"
        var incoming: [CustomerReview] = [], ids = Set<String>(), visited = Set<String>(), cursor: String?, limited = false, pages = 0
        while true {
            try check()
            let current = cursor.map { path + "&cursor=" + ($0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0) } ?? path
            guard visited.insert(current).inserted else { throw ReviewsFailure.integrity }
            let page = try await client.page(current, currentCursor: cursor)
            try check()
            pages += 1
            guard page.resources.count <= 200, page.next == nil || !page.resources.isEmpty else { throw ReviewsFailure.integrity }
            var unchanged = !page.resources.isEmpty
            for resource in page.resources {
                let review = try CustomerReview(apple: resource)
                guard ids.insert(review.id).inserted, incoming.last.map({ review.createdDate <= $0.createdDate }) ?? true else { throw ReviewsFailure.integrity }
                if known[review.id] != review.json.data { unchanged = false }
                incoming.append(review)
            }
            try progress(.downloading, pages, incoming.count)
            guard let next = page.next else { break }
            if !full && unchanged { limited = true; break }
            cursor = next
        }

        let checkedAt = CustomerReview.isoString(now)
        var changes = ReviewChanges()
        let previous = Dictionary(uniqueKeysWithValues: saved.map { ($0.id, $0) })
        for review in incoming {
            if let old = previous[review.id] { if old.json == review.json { changes.unchanged += 1 } else { changes.updated += 1 } } else { changes.added += 1 }
        }
        changes.limited = limited && (meta?["limited"].map { $0 == .bool(true) } ?? true)
        let fullCheckedAt = limited ? meta?["fullCheckedAt"]?.string : checkedAt
        try check(); try progress(.saving, pages, incoming.count)
        try storeAccess { store in
            try PartitionedReports.replaceAll(CustomerReview.self, family: "reviews", legacyKey: "reviews", accountId: account.id, appId: appId, store: store,
                                              stateDirectory: store.directory, bucketOf: { String($0.createdDate.prefix(7)) }, encode: { $0.json }, expected: revision,
                                              validate: { try self.reviewsScope(account, appId: appId); try check() }, additionalWrites: { try completion(changes, store) }) { stored, _ in
                try self.reviewsScope(account, appId: appId); try check()
                var merged = Dictionary(uniqueKeysWithValues: (stored ?? []).map { ($0.id, $0) })
                for review in incoming { merged[review.id] = review }
                let sorted = try CustomerReview.sorted(Array(merged.values))
                var metaFields: [(String, JSONText)] = [("checkedAt", .string(checkedAt)), ("limited", .bool(changes.limited))]
                if let fullCheckedAt { metaFields.append(("fullCheckedAt", .string(fullCheckedAt))) }
                return (sorted, .object(metaFields))
            }
        }
        return changes
    }

    func reviewsMeta(accountId: String, appId: String) throws -> [String: JSONValue]? {
        try storeAccess { store in
            let key = "\(accountId):\(appId)"
            guard let document = try store.document(namespace: "reviews_index", key: key) ?? store.document(namespace: "reviews", key: key) else { return nil }
            let json = try JSONText.parse(document.payload)
            guard json["schemaVersion"] == .number(1), json["accountId"]?.text == accountId, json["appId"]?.text == appId else { throw ReviewsFailure.storage }
            let meta = json["buckets"] == nil ? json : json["meta"]
            guard let meta, let checkedAt = meta["checkedAt"]?.text, case .bool? = meta["limited"] else { throw ReviewsFailure.storage }
            _ = try CustomerReview.isoDate(checkedAt)
            if let full = meta["fullCheckedAt"] { guard let text = full.text else { throw ReviewsFailure.storage }; _ = try CustomerReview.isoDate(text) }
            return try JSONDecoder().decode([String: JSONValue].self, from: meta.data)
        }
    }
    func reviewsScope(_ account: Account, appId: String) throws {
        guard try currentAccount(account).appIds.contains(appId) else { throw ReviewsFailure.scope }
        _ = try ReportJobs.identity(.reviews, accountId: account.id, appId: appId)
    }
}

extension ISO8601DateFormatter {
    static var fractional: ISO8601DateFormatter { let format = ISO8601DateFormatter(); format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return format }
}
