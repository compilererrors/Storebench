import Foundation

public enum RevisionHistoryFailure: Error, Equatable {
    case invalid, missing, planned, busy, stale
    public var message: String {
        switch self {
        case .invalid: "Saved revision identity or content could not be verified. Reload history before continuing."
        case .missing: "Revision not found. Refresh history."
        case .planned: "This revision is used by the active release plan. Remove that plan before deleting the revision."
        case .busy: "Finish or cancel the active import before deleting a revision."
        case .stale: "The saved revision changed after confirmation was opened. Refresh history and review it again."
        }
    }
}

public struct ArchivedRevision: Identifiable, Sendable, Codable {
    public let id, importedAt, appName: String
    public let local: Bool
    public let versionTitles: [String]
    public let documentRevision: Int
    let value: JSONText
    init(_ value: JSONText, accountId: String, appId: String, id: String, documentRevision: Int) throws {
        try RevisionComparison.validate(value)
        guard id.range(of: "^[a-f0-9-]{36}$", options: .regularExpression) != nil, TextSemantics.same(value["account"]?["id"]?.text, accountId), TextSemantics.same(value["app"]?["id"]?.text, appId), TextSemantics.same(value["id"]?.text, id), let at = value["importedAt"]?.text else { throw RevisionHistoryFailure.invalid }
        self.value = value; self.id = id; importedAt = at; local = value["origin"]?.text == "local"; self.documentRevision = documentRevision
        appName = value["app"]?["name"]?.text ?? appId
        versionTitles = WorkspaceSession.items(value["versions"]).map { item in
            let fields = item["fields"] ?? .object([])
            return Releases.platformName(RevisionComparison.fallback(fields["platform"], "App")) + " " + RevisionComparison.fallback(fields["versionString"], item["id"]?.text ?? "")
        }
    }
}

/// Archived fields and screenshot order, with fixed revision-diff keys and ordering.
public enum RevisionComparison {
    public struct Change: Sendable, Equatable {
        public let section, label, kind, type: String
        public let before, after: String?
        public let beforeImages, afterImages: [String]?
        let beforeImageIndices, afterImageIndices: Range<Int>?
        public var json: JSONText {
            var fields: [(String, JSONText)] = [("section", .string(section)), ("label", .string(label)), ("kind", .string(kind)), ("type", .string(type))]
            if let before { fields.append(("before", .string(before))) }; if let after { fields.append(("after", .string(after))) }
            if let beforeImages { fields.append(("beforeImages", .array(beforeImages.map(JSONText.string)))) }; if let afterImages { fields.append(("afterImages", .array(afterImages.map(JSONText.string)))) }
            return .object(fields)
        }
    }
    struct Entry { let section, label, type, value: String; let images: [String]?; var imageIndices: Range<Int>? = nil }
    static func validate(_ value: JSONText) throws {
        guard value["schemaVersion"] == .number(1), let account = value["account"]?["id"]?.text, !account.isEmpty, let app = value["app"]?["id"]?.text, !app.isEmpty,
              case .array? = value["appInfos"], case .array? = value["versions"] else { throw RevisionHistoryFailure.invalid }
    }
    static func text(_ value: JSONText) throws -> String {
        switch value {
        case .string(let text): return text
        case .null: return ""
        case .number(let number):
            guard let text = TextSemantics.number(number) else { throw RevisionHistoryFailure.invalid }; return text
        default: throw RevisionHistoryFailure.invalid
        }
    }
    static func fallback(_ value: JSONText?, _ defaultValue: String) -> String {
        guard let value, value != .null, value != .string(""), value != .number(0) else { return defaultValue }; return (try? text(value)) ?? defaultValue
    }
    static let labels: [String: String] = Dictionary(uniqueKeysWithValues: ["name", "bundleId", "sku", "primaryLocale", "subtitle", "privacyPolicyUrl", "privacyChoicesUrl", "privacyPolicyText", "appStoreState", "appVersionState", "copyright", "description", "keywords", "marketingUrl", "promotionalText", "supportUrl", "whatsNew"].map { name in
        let spaced = name.replacingOccurrences(of: "([A-Z])", with: " $1", options: .regularExpression)
        return (name, spaced.prefix(1).uppercased() + spaced.dropFirst())
    })
    static func label(_ name: String) -> String { labels[name] ?? name }
    static func entries(_ revision: JSONText) throws -> (keys: [Data], values: [Data: Entry]) {
        var keys: [Data] = [], values: [Data: Entry] = [:], imageIndex = 0
        func insert(_ key: String, _ entry: Entry) { let bytes = Data(key.utf8); if values[bytes] == nil { keys.append(bytes) }; values[bytes] = entry }
        func fields(_ fields: JSONText, prefix: String, section: String, names: [String]) throws {
            guard case .object = fields else { throw RevisionHistoryFailure.invalid }
            for name in names { if let value = fields[name] { insert(prefix + ":" + name, Entry(section: section, label: label(name), type: "text", value: try text(value), images: nil)) } }
        }
        func array(_ value: JSONText?) throws -> [JSONText] { guard case .array(let values)? = value else { throw RevisionHistoryFailure.invalid }; return values }
        func id(_ value: JSONText) throws -> String { guard let id = value["id"]?.text else { throw RevisionHistoryFailure.invalid }; return id }
        try fields(revision["app"] ?? .null, prefix: "app", section: "App", names: ["name", "bundleId", "sku", "primaryLocale"])
        for info in try array(revision["appInfos"]) {
            for locale in try array(info["localizations"]) {
                let language = fallback(locale["fields"]?["locale"], try id(locale))
                try fields(locale["fields"] ?? .null, prefix: "info:\(try id(info)):\(language)", section: "App information · \(language)", names: ["name", "subtitle", "privacyPolicyUrl", "privacyChoicesUrl", "privacyPolicyText"])
            }
        }
        for version in try array(revision["versions"]) {
            let versionID = try id(version), fieldsValue = version["fields"] ?? .null
            let name = fallback(fieldsValue["platform"], "App") + " " + fallback(fieldsValue["versionString"], versionID)
            try fields(fieldsValue, prefix: "version:\(versionID)", section: "Version · \(name)", names: ["appStoreState", "appVersionState", "copyright"])
            for locale in try array(version["localizations"]) {
                let language = fallback(locale["fields"]?["locale"], try id(locale)), section = name + " · " + language, prefix = "version:\(versionID):locale:\(language)"
                try fields(locale["fields"] ?? .null, prefix: prefix, section: section, names: ["description", "keywords", "marketingUrl", "promotionalText", "supportUrl", "whatsNew"])
                for set in try array(locale["screenshotSets"]) {
                    guard let display = set["displayType"]?.text else { throw RevisionHistoryFailure.invalid }
                    let hashes = try array(set["screenshots"]).map { shot -> String in guard let hash = shot["sha256"]?.text else { throw RevisionHistoryFailure.invalid }; return hash }
                    let indices = imageIndex..<(imageIndex + hashes.count); imageIndex += hashes.count
                    insert(prefix + ":screenshots:" + display, Entry(section: section, label: "Screenshots · " + (display.isEmpty ? "Unknown display" : display), type: "screenshots", value: hashes.joined(separator: ","), images: hashes, imageIndices: indices))
                }
            }
        }
        return (keys, values)
    }
    public static func compare(before: JSONText, after: JSONText) throws -> [Change] {
        try validate(before); try validate(after)
        guard TextSemantics.same(before["account"]?["id"]?.text, after["account"]?["id"]?.text), TextSemantics.same(before["app"]?["id"]?.text, after["app"]?["id"]?.text) else { throw RevisionHistoryFailure.invalid }
        let old = try entries(before), new = try entries(after)
        var seen = Set<Data>()
        let keys = (old.keys + new.keys).filter { seen.insert($0).inserted }
        let changes = keys.compactMap { key -> Change? in
            let a = old.values[key], b = new.values[key]
            if TextSemantics.same(a?.value, b?.value) { return nil }
            let entry = b ?? a!
            return Change(section: entry.section, label: entry.label, kind: a == nil ? "added" : b == nil ? "removed" : "changed", type: entry.type,
                          before: a?.type == "text" ? a?.value : nil, after: b?.type == "text" ? b?.value : nil, beforeImages: a?.images, afterImages: b?.images,
                          beforeImageIndices: a?.imageIndices, afterImageIndices: b?.imageIndices)
        }
        return changes.enumerated().sorted { a, b in
            let section = a.element.section.compare(b.element.section, locale: Locale(identifier: "en"))
            let label = a.element.label.compare(b.element.label, locale: Locale(identifier: "en"))
            return section == .orderedSame ? label == .orderedSame ? a.offset < b.offset : label == .orderedAscending : section == .orderedAscending
        }.map(\.element)
    }
}

extension WorkspaceSession {
    func requireHistoryScope(accountId: String, appId: String) throws {
        guard accountId.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil, appId.range(of: "^[0-9]+$", options: .regularExpression) != nil,
              try accounts().contains(where: { $0.id == accountId && $0.appIds.contains(appId) }) else { throw RevisionHistoryFailure.invalid }
    }
    func archivedRevision(accountId: String, appId: String, id: String, store: EncryptedDocumentStore) throws -> ArchivedRevision {
        guard id.range(of: "^[a-f0-9-]{36}$", options: .regularExpression) != nil, let saved = try store.document(namespace: "revisions", key: "\(accountId):\(appId):\(id)") else { throw RevisionHistoryFailure.missing }
        let key = JSONText.array([.string("archived"), .string(saved.key), .number(Double(saved.revision))]).stringify()
        if let cached = archivedRevisions.value(for: key), cached.payload == saved.payload { return cached.value }
        let value = try ArchivedRevision(JSONText.parse(saved.payload), accountId: accountId, appId: appId, id: id, documentRevision: saved.revision)
        archivedRevisions.insert((saved.payload, value), for: key, cost: saved.payload.count * 3)
        return value
    }
    public func archivedHistory(accountId: String, appId: String) throws -> [ArchivedRevision] {
        try requireHistoryScope(accountId: accountId, appId: appId)
        let prefix = "\(accountId):\(appId):"
        return try storeAccess { store in try store.documents(namespace: "revisions", prefix: prefix).compactMap { document in
            let id = String(document.key.dropFirst(prefix.count))
            return try? ArchivedRevision(JSONText.parse(document.payload), accountId: accountId, appId: appId, id: id, documentRevision: document.revision)
        }.sorted { $0.importedAt > $1.importedAt } }
    }
    public func compareArchivedRevisions(accountId: String, appId: String, beforeId: String, afterId: String) throws -> [RevisionComparison.Change] {
        try requireHistoryScope(accountId: accountId, appId: appId)
        return try storeAccess { store in
            let before = try archivedRevision(accountId: accountId, appId: appId, id: beforeId, store: store), after = try archivedRevision(accountId: accountId, appId: appId, id: afterId, store: store)
            return try RevisionComparison.compare(before: before.value, after: after.value)
        }
    }
    public func archivedScreenshot(accountId: String, appId: String, revisionId: String, hash: String) throws -> Data {
        try requireHistoryScope(accountId: accountId, appId: appId)
        guard hash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw RevisionHistoryFailure.invalid }
        let source = try storeAccess { try archivedRevision(accountId: accountId, appId: appId, id: revisionId, store: $0) }
        guard try RevisionComparison.entries(source.value).values.values.contains(where: { $0.images?.contains(hash) == true }) else { throw RevisionHistoryFailure.missing }
        return try media.read(hash)
    }
    /// Same permanent import gate, release-plan lock, draft lock and atomic deletion as every other revision write.
    @discardableResult public func deleteArchivedRevision(accountId: String, appId: String, revisionId: String, expectedRevision: Int) throws -> Bool {
        try requireHistoryScope(accountId: accountId, appId: appId)
        let key = try TextDrafts.key(accountId: accountId, appId: appId, revisionId: revisionId)
        guard expectedRevision > 0 else { throw RevisionHistoryFailure.invalid }
        return try storeAccess { store in
            let name = "import_" + JSONText.string("\(accountId)\u{0}\(appId)").rawSHA256.prefix(48)
            guard let gate = try FileMutex.tryLock(store.directory.appendingPathComponent("\(name).lock.mutex")) else { throw RevisionHistoryFailure.busy }
            defer { gate.release() }
            if let owner = try JobLock.owner(JobLock.privateFile(store.directory.appendingPathComponent("\(name).lock"))), owner.protocol != 2 && JobLock.alive(owner.pid) { throw RevisionHistoryFailure.busy }
            return try FileMutex.withLock(store.directory.appendingPathComponent("release_plans.mutex")) {
                let draft = "draft_" + JSONText.string(key).rawSHA256.prefix(40)
                return try FileMutex.withLock(store.directory.appendingPathComponent("\(draft).mutex")) {
                    var deleted = false
                    try store.transaction { current in
                        try requireHistoryScope(accountId: accountId, appId: appId)
                        if let planDocument = try current("release_plans", "all") {
                            let value = try JSONText.parse(planDocument.payload)
                            guard value["schemaVersion"] == .number(1), case .array(let plans)? = value["plans"] else { throw RevisionHistoryFailure.invalid }
                            if plans.contains(where: { $0["accountId"]?.text == accountId && $0["appId"]?.text == appId && $0["sourceRevisionId"]?.text == revisionId }) { throw RevisionHistoryFailure.planned }
                        }
                        guard let source = try current("revisions", key) else { return [] }
                        guard source.revision == expectedRevision else { throw RevisionHistoryFailure.stale }
                        _ = try ArchivedRevision(JSONText.parse(source.payload), accountId: accountId, appId: appId, id: revisionId, documentRevision: source.revision)
                        deleted = true
                        return [.delete(namespace: "drafts", key: key), .delete(namespace: "revisions", key: key)]
                    }
                    return deleted
                }
            }
        }
    }
}
