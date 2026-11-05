import Foundation

public struct AsoChange: Sendable, Equatable, Codable { public let section, field, before, after: String }

struct AsoField: Sendable, Equatable { let key, section, field, value: String }

enum ASO {
    static let infoFields = ["name", "subtitle"]
    static let versionFields = ["description", "keywords", "promotionalText", "whatsNew", "marketingUrl", "supportUrl"]

    static func leadingVersions(_ revision: Revision) -> [Revision.Version] {
        var byPlatform: [String: Revision.Version] = [:], order: [String] = []
        for version in revision.versions {
            let platform = version.fields["platform"]?.text ?? "App"
            if let previous = byPlatform[platform] {
                if version.number.compare(previous.number, options: .numeric) == .orderedDescending { byPlatform[platform] = version }
            } else { byPlatform[platform] = version; order.append(platform) }
        }
        return order.map { byPlatform[$0]! }
    }

    static func entries(_ revision: Revision, versions: [Revision.Version]? = nil) -> [AsoField] {
        var result: [AsoField] = [], index: [String: Int] = [:]
        func add(_ key: String, _ section: String, _ field: String, _ value: FieldValue?) {
            guard let value else { return }
            let entry = AsoField(key: key, section: section, field: field, value: value.text ?? "")
            if let at = index[key] { result[at] = entry } else { index[key] = result.count; result.append(entry) }
        }
        for info in revision.appInfos { for locale in info.localizations {
            let language = locale.fields["locale"]?.text ?? locale.id
            // The section label is part of each entry basis, so saved journal notes stay attached; keep its original casing.
            for field in infoFields { add("info:\(language):\(field)", "App information · \(language)", field, locale.fields[field]) }
        } }
        for version in versions ?? leadingVersions(revision) {
            let platform = version.fields["platform"]?.text ?? "App", number = version.fields["versionString"]?.text ?? version.id
            let name = "\(Releases.platformName(platform)) \(number)"
            for locale in version.localizations {
                let language = locale.locale, section = "\(name) · \(language)"
                for field in versionFields { add("version:\(platform):\(language):\(field)", section, field, locale.fields[field]) }
                for set in locale.screenshotSets { add("version:\(platform):\(language):screenshots:\(set.displayType)", section, "screenshots · \(set.displayType)", .text(set.screenshots.map(\.sha256).joined(separator: ","))) }
            }
        }
        return result
    }

    struct Snapshot { let revisionId, versionId, savedAt, at, version: String; let dateCreated: Bool; let fields: [AsoField] }

    static func iso(_ text: String) -> Date? {
        ISODateParser.date(text)
    }

    /// One snapshot per version whenever its saved listing changed between imports.
    static func versionSnapshots(_ revisions: [Revision], releasedOnly: Bool = false) -> [Snapshot] {
        let ordered = revisions.filter { !releasedOnly || $0.origin == nil }.sorted { ($0.importedAt, $0.id) < ($1.importedAt, $1.id) }
        var latest: [String: Snapshot] = [:], snapshots: [Snapshot] = []
        for revision in ordered { for version in revision.versions {
            guard !releasedOnly || version.released else { continue }
            let platform = version.fields["platform"]?.text ?? "App", number = version.fields["versionString"]?.text ?? version.id, identity = "\(platform):\(number)"
            let fields = entries(revision, versions: [version]).filter { !TextSemantics.trim($0.value).isEmpty }
            let previous = latest[identity]
            if let previous, fields.count == previous.fields.count, fields.allSatisfy({ field in TextSemantics.same(previous.fields.first { $0.key == field.key }?.value, field.value) }) { continue }
            let created = version.fields["createdDate"]?.text ?? ""
            var at = revision.importedAt, dateCreated = false
            if !releasedOnly, previous == nil, created.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T"#, options: .regularExpression) != nil, let date = iso(created), let imported = iso(revision.importedAt), date <= imported { at = CustomerReview.isoString(date); dateCreated = true }
            let snapshot = Snapshot(revisionId: revision.id, versionId: version.id, savedAt: revision.importedAt, at: at, version: "\(Releases.platformName(platform)) \(number)", dateCreated: dateCreated, fields: fields)
            latest[identity] = snapshot; snapshots.append(snapshot)
        } }
        return snapshots.sorted { a, b in
            if a.at != b.at { return a.at < b.at }
            let order = a.version.compare(b.version, options: .numeric)
            return order != .orderedSame ? order == .orderedAscending : "\(a.revisionId):\(a.versionId)" < "\(b.revisionId):\(b.versionId)"
        }
    }

    static func diff(_ before: [AsoField], _ after: [AsoField]) -> [AsoChange] {
        let old = Dictionary(before.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last }), next = Dictionary(after.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
        var keys: [String] = []
        for key in before.map(\.key) + after.map(\.key) where !keys.contains(key) { keys.append(key) }
        return keys.compactMap { key -> AsoChange? in
            let a = old[key], b = next[key]
            if TextSemantics.same(a?.value, b?.value) { return nil }
            return AsoChange(section: b?.section ?? a!.section, field: b?.field ?? a!.field, before: a?.value ?? "", after: b?.value ?? "")
        }.sorted { a, b in
            let section = a.section.localizedCompare(b.section)
            return section != .orderedSame ? section == .orderedAscending : a.field.localizedCompare(b.field) == .orderedAscending
        }
    }

    /// A journal basis retains entry order from the imports, independently of the sorted comparison presentation.
    static func journalChanges(_ before: [AsoField], _ after: [AsoField]) -> [JournalChange] {
        let old = Dictionary(before.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last }), next = Dictionary(after.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
        var keys: [String] = []; for field in before + after where !keys.contains(field.key) { keys.append(field.key) }
        return keys.compactMap { key in
            let a = old[key], b = next[key]
            guard !TextSemantics.same(a?.value, b?.value) else { return nil }
            let field = b ?? a!
            return JournalChange(label: "\(field.section) · \(field.field)", before: a?.value ?? "", after: b?.value ?? "", kind: field.field.hasPrefix("screenshots") ? "media" : "text")
        }
    }

    /// The listing as the local draft would publish it, compared with the saved revision.
    static func draftChanges(_ source: Revision, draft: JSONText) -> [AsoChange] {
        let current = WorkspaceSession.overlay(source, draft: draft), texts = draft["texts"]
        func edited(_ id: String, _ fields: Fields, _ names: [String]) -> Fields {
            var result = fields
            for name in names { if let value = texts?[id]?[name]?.text { result[name] = .text(value) } }
            return result
        }
        var uploads: [(String, Revision.Screenshot)] = []
        if case .object(let pairs)? = draft["uploads"] {
            for (id, upload) in pairs {
                guard let set = upload["setId"]?.text, let sha = upload["sha256"]?.text else { continue }
                uploads.append((set, Revision.Screenshot(id: upload["id"]?.text ?? id, fileName: upload["fileName"]?.text ?? "", sha256: sha, width: nil, height: nil)))
            }
        }
        let next = Revision(schemaVersion: current.schemaVersion, origin: current.origin, id: current.id, importedAt: current.importedAt, app: current.app,
            appInfos: current.appInfos.map { info in Revision.AppInfo(id: info.id, fields: info.fields, localizations: info.localizations.map { Revision.AppInfoLocalization(id: $0.id, fields: edited($0.id, $0.fields, infoFields)) }) },
            versions: current.versions.map { version in Revision.Version(id: version.id, fields: version.fields, localizations: version.localizations.map { locale in
                Revision.Localization(id: locale.id, fields: edited(locale.id, locale.fields, versionFields), screenshotSets: locale.screenshotSets.map { set in
                    let original = set.screenshots + uploads.filter { $0.0 == set.id }.map(\.1)
                    guard let layout = draft["screenshotLayouts"]?[set.id] else { return set }
                    let order = WorkspaceSession.items(layout["order"]).compactMap(\.text), hidden = Set(WorkspaceSession.items(layout["hidden"]).compactMap(\.text))
                    let rank = { (id: String) in order.firstIndex(of: id) ?? Int.max }
                    let sorted = original.enumerated().sorted { (rank($0.element.id), $0.offset) < (rank($1.element.id), $1.offset) }.map(\.element)
                    return Revision.ScreenshotSet(id: set.id, displayType: set.displayType, screenshots: sorted.filter { !hidden.contains($0.id) })
                })
            }) })
        return diff(entries(current), entries(next))
    }
}

public struct JournalChange: Sendable, Equatable, Codable {
    public let label, before, after, kind: String
    var json: JSONText { .object([("label", .string(label)), ("before", .string(before)), ("after", .string(after)), ("kind", .string(kind))]) }
}

/// One entry in the change journal. Every timestamp keeps its own provenance; none claims an App Store publication date.
public struct JournalEvent: Identifiable, Sendable, Equatable, Codable {
    public let id, source, stage, title: String
    public let platform, version: String?
    public let locales, territories: [String]
    public let sourceRevisionId: String?
    public let changes: [JournalChange]
    public let basis: String
    public let preparedAt, approvedAt, sentAt, completedAt, observedAt, occurrenceAfter: String?
    public let reviewId, reviewScope, olderRevisionId, newerRevisionId: String?
    public var publicVerifiedAt: String? = nil
    public var time: String { observedAt ?? sentAt ?? approvedAt ?? preparedAt ?? "" }
}

public struct JournalNote: Sendable, Equatable {
    public static let attributions = ["unknown", "storebench", "external"]
    public static let metrics = ["none", "impressions", "views", "get", "first", "paid"]
    public var eventId, basis, attribution, intent, hypothesis, primaryMetric, simultaneousEvents, conclusion, nextDecision: String
    public var evidenceFingerprint: String?
    public var updatedAt: String
    public init(eventId: String, basis: String, attribution: String = "unknown", intent: String = "", hypothesis: String = "", primaryMetric: String = "none", simultaneousEvents: String = "",
                conclusion: String = "", nextDecision: String = "", evidenceFingerprint: String? = nil, updatedAt: String = "") {
        self.eventId = eventId; self.basis = basis; self.attribution = attribution; self.intent = intent; self.hypothesis = hypothesis; self.primaryMetric = primaryMetric
        self.simultaneousEvents = simultaneousEvents; self.conclusion = conclusion; self.nextDecision = nextDecision; self.evidenceFingerprint = evidenceFingerprint; self.updatedAt = updatedAt
    }
    var texts: [(String, String)] { [("intent", intent), ("hypothesis", hypothesis), ("simultaneousEvents", simultaneousEvents), ("conclusion", conclusion), ("nextDecision", nextDecision)] }
    var json: JSONText {
        var fields: [(String, JSONText)] = [("eventId", .string(eventId)), ("basis", .string(basis)), ("attribution", .string(attribution))]
        fields += texts.prefix(2).map { ($0.0, .string($0.1)) }
        fields.append(("primaryMetric", .string(primaryMetric)))
        fields += texts.dropFirst(2).map { ($0.0, .string($0.1)) }
        if let evidenceFingerprint { fields.append(("evidenceFingerprint", .string(evidenceFingerprint))) }
        return .object(fields + [("schemaVersion", .number(1)), ("updatedAt", .string(updatedAt))])
    }
    init(_ value: JSONText, eventId: String) throws {
        let allowed: Set<String> = ["schemaVersion", "eventId", "basis", "attribution", "intent", "hypothesis", "primaryMetric", "simultaneousEvents", "conclusion", "nextDecision", "evidenceFingerprint", "updatedAt"]
        guard case .object(let pairs) = value, pairs.allSatisfy({ allowed.contains($0.0) }), value["schemaVersion"] == .number(1), value["eventId"]?.text == eventId,
              let basis = value["basis"]?.text, let attribution = value["attribution"]?.text, let metric = value["primaryMetric"]?.text, let updated = value["updatedAt"]?.text else { throw JournalFailure.invalid }
        self.init(eventId: eventId, basis: basis, attribution: attribution, intent: value["intent"]?.text ?? "", hypothesis: value["hypothesis"]?.text ?? "", primaryMetric: metric,
                  simultaneousEvents: value["simultaneousEvents"]?.text ?? "", conclusion: value["conclusion"]?.text ?? "", nextDecision: value["nextDecision"]?.text ?? "",
                  evidenceFingerprint: value["evidenceFingerprint"]?.text, updatedAt: updated)
        try validate()
    }
    func validate() throws {
        let hex = "^[a-f0-9]{64}$"
        guard basis.range(of: hex, options: .regularExpression) != nil, Self.attributions.contains(attribution), Self.metrics.contains(primaryMetric),
              evidenceFingerprint.map({ $0.range(of: hex, options: .regularExpression) != nil }) ?? true,
              texts.allSatisfy({ $0.1.utf16.count <= 1000 && !$0.1.unicodeScalars.contains { ($0.value < 0x20 && ![0x09, 0x0a, 0x0d].contains($0.value)) || $0.value == 0x7f } }) else { throw JournalFailure.invalid }
    }
}

public enum JournalFailure: Error, Equatable {
    case invalid, stale, unavailable, foreign
    public var message: String {
        switch self {
        case .invalid: "The note has an invalid value. Notes are limited to 1,000 characters per field."
        case .stale: "The journal entry or note changed. Reload and compare before saving."
        case .unavailable: "Journal entry is unavailable. Reload before saving."
        case .foreign: "Journal material belongs to another app."
        }
    }
}

extension WorkspaceSession {
    static func fingerprint(_ value: JSONText) -> String { Apple.sha(value.stringify()) }
    static let journalScopes: Set<String> = ["release", "metadata", "version-copyright", "app-information", "availability", "age-rating", "pricing", "submit", "cancel-submission", "release-version"]

    static func journalEvents(accountId: String, appId: String, revisions: [Revision], drafts: [(String, [AsoChange])], plan: ReleasePlan?, reviews: [PublishReview]) throws -> [JournalEvent] {
        guard reviews.allSatisfy({ $0.request.accountId == accountId && $0.request.appId == appId }), plan.map({ $0.accountId == accountId && $0.appId == appId }) ?? true else { throw JournalFailure.foreign }
        let localePattern = "^[a-z]{2,3}(?:-[A-Z]{2,4})?$"
        func isLocale(_ text: String) -> Bool { text.range(of: localePattern, options: .regularExpression) != nil }
        func trailingLocale(_ text: String) -> String? {
            guard let range = text.range(of: #" · ([a-z]{2,3}(?:-[A-Z]{2,4})?)$"#, options: .regularExpression) else { return nil }
            return String(text[range].dropFirst(3))
        }
        func uniq(_ items: [String]) -> [String] { var seen: [String] = []; for item in items where !seen.contains(item) { seen.append(item) }; return seen }
        var entries: [JournalEvent] = []
        let lookup = Dictionary(revisions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let versionLookup = Dictionary(revisions.flatMap(\.versions).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let imported = revisions.filter { !$0.isLocalDraft }.sorted { $0.importedAt < $1.importedAt }
        var prior: [String: Revision] = [:], latestImport: [String: Revision] = [:]
        for revision in imported { for version in revision.versions {
            let identity = "\(version.fields["platform"]?.text ?? "App"):\(version.fields["versionString"]?.text ?? version.id)"
            if let previous = latestImport[identity] { prior["\(revision.id):\(version.id)"] = previous }
            latestImport[identity] = revision
        } }
        var latest: [String: [AsoField]] = [:]
        for snapshot in ASO.versionSnapshots(imported) {
            let version = lookup[snapshot.revisionId]!.versions.first { $0.id == snapshot.versionId }!
            let platform = version.fields["platform"]?.text.flatMap { $0.isEmpty ? nil : $0 }, number = version.fields["versionString"]?.text.flatMap { $0.isEmpty ? nil : $0 }
            let identity = "\(platform ?? "null"):\(number ?? "null")", previous = latest[identity]
            let changes = ASO.journalChanges(previous ?? [], snapshot.fields)
            let recent = prior["\(snapshot.revisionId):\(snapshot.versionId)"]
            let locales = uniq(snapshot.fields.compactMap { field -> String? in
                let parts = field.key.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
                let value = parts[0] == "info" ? parts[1] : parts[0] == "version" ? parts[2] : ""
                return isLocale(value) ? value : nil
            })
            entries.append(JournalEvent(id: "import:\(snapshot.revisionId):\(fingerprint(.string(snapshot.versionId)).prefix(32))", source: "import", stage: "observed",
                                        title: previous != nil ? "Observed listing change · \(snapshot.version)" : "First saved listing · \(snapshot.version)", platform: platform, version: number,
                                        locales: locales, territories: [], sourceRevisionId: snapshot.revisionId, changes: changes,
                                        basis: fingerprint(.array([.string(snapshot.revisionId), .string(snapshot.versionId), recent.map { .string($0.id) } ?? .null, .array(changes.map(\.json))])),
                                        preparedAt: nil, approvedAt: nil, sentAt: nil, completedAt: nil, observedAt: snapshot.savedAt, occurrenceAfter: recent?.importedAt,
                                        reviewId: nil, reviewScope: nil, olderRevisionId: recent?.id, newerRevisionId: snapshot.revisionId))
            latest[identity] = snapshot.fields
        }
        for (revisionId, aso) in drafts where !aso.isEmpty {
            guard let revision = lookup[revisionId] else { throw JournalFailure.unavailable }
            let changes = aso.map { JournalChange(label: "\($0.section) · \($0.field)", before: $0.before, after: $0.after, kind: $0.field.hasPrefix("screenshots") ? "media" : "text") }
            let single = revision.versions.count == 1 ? revision.versions[0] : nil
            entries.append(JournalEvent(id: "draft:\(revisionId)", source: "draft", stage: "draft", title: "Saved listing draft",
                                        platform: single?.fields["platform"]?.text.flatMap { $0.isEmpty ? nil : $0 }, version: single?.fields["versionString"]?.text.flatMap { $0.isEmpty ? nil : $0 },
                                        locales: uniq(aso.compactMap { trailingLocale($0.section) }), territories: [], sourceRevisionId: revisionId, changes: changes,
                                        basis: fingerprint(.array([.string(revisionId), .array(changes.map(\.json))])), preparedAt: nil, approvedAt: nil, sentAt: nil, completedAt: nil,
                                        observedAt: nil, occurrenceAfter: nil, reviewId: nil, reviewScope: nil, olderRevisionId: nil, newerRevisionId: nil))
        }
        if let plan {
            entries.append(JournalEvent(id: "plan:\(plan.sourceRevisionId):\(fingerprint(.string(plan.baseVersionId)).prefix(32))", source: "release-plan", stage: "draft", title: "Planned release · \(plan.label)",
                                        platform: plan.platform, version: plan.targetVersion, locales: [], territories: [], sourceRevisionId: plan.sourceRevisionId,
                                        changes: [JournalChange(label: "Version target", before: "", after: plan.label, kind: "step")], basis: Apple.sha(plan.token),
                                        preparedAt: plan.updatedAt, approvedAt: nil, sentAt: nil, completedAt: nil, observedAt: nil, occurrenceAfter: nil, reviewId: nil, reviewScope: nil, olderRevisionId: nil, newerRevisionId: nil))
        }
        for review in reviews where journalScopes.contains(review.request.scope.rawValue) {
            var platform: String?, version: String?
            let source = review.request.revisionId.flatMap { lookup[$0] }
            let target = source?.versions.first { $0.id == review.request.versionId } ?? review.request.versionId.flatMap { versionLookup[$0] }
            if review.request.scope == .release, let posted = review.steps.first(where: { $0.method == "POST" && $0.path.first?.text == "appStoreVersions" })?.body?["data"]?["attributes"],
               let p = posted["platform"]?.text, let v = posted["versionString"]?.text { platform = p; version = v }
            else if review.request.scope == .metadata, review.request.targetMode == "release-plan", let range = review.title.range(of: #" · ([A-Z_]+) (\d+(?:\.\d+){0,2})$"#, options: .regularExpression) {
                let parts = review.title[range].dropFirst(3).split(separator: " "); platform = String(parts[0]); version = String(parts[1])
            } else { platform = target?.fields["platform"]?.text.flatMap { $0.isEmpty ? nil : $0 }; version = target?.fields["versionString"]?.text.flatMap { $0.isEmpty ? nil : $0 } }
            let changes = review.steps.filter { $0.kind == .api && ($0.before != nil || $0.after != nil || $0.method != nil) }.map { step in
                JournalChange(label: step.label, before: step.before ?? "", after: step.after ?? "",
                              kind: review.request.scope == .pricing ? "price" : step.label.range(of: "screenshot|preview", options: [.regularExpression, .caseInsensitive]) != nil ? "media" : "step")
            }
            let territories = review.request.scope == .pricing ? uniq(review.steps.flatMap { ($0.after ?? "").split(separator: "\n").compactMap { line in
                line.range(of: "^[A-Z]{3}:", options: .regularExpression) != nil ? String(line.prefix(3)) : nil } }) : []
            let sent = review.sentAt != nil || review.steps.contains { $0.kind != .verify && $0.state == "done" }
            entries.append(JournalEvent(id: "publish:\(review.id)", source: "publish", stage: sent ? "sent" : review.approvedAt != nil || review.state == "running" ? "approved" : "prepared",
                                        title: review.title, platform: platform, version: version, locales: uniq(review.steps.compactMap { trailingLocale($0.label) }), territories: territories,
                                        sourceRevisionId: review.request.revisionId, changes: changes, basis: review.fingerprint, preparedAt: review.createdAt, approvedAt: review.approvedAt,
                                        sentAt: review.sentAt, completedAt: review.completedAt, observedAt: nil, occurrenceAfter: nil, reviewId: review.id, reviewScope: review.request.scope.rawValue,
                                        olderRevisionId: nil, newerRevisionId: nil))
        }
        return entries.sorted { $0.time != $1.time ? $0.time > $1.time : $0.id < $1.id }
    }

    /// Saved listings, drafts, the release plan and publishing reviews of one app, newest first.
    public func changeJournal(accountId: String, appId: String) throws -> [JournalEvent] {
        let revisions = try self.revisions(accountId: accountId, appId: appId), plan = try releasePlan(accountId: accountId, appId: appId), reviews = try publishHistory(accountId: accountId, appId: appId)
        let prefix = "\(accountId):\(appId):"
        let documents = try storeAccess { try $0.documents(namespace: "drafts", prefix: prefix) }
        guard documents.count < 5000 else { throw JournalFailure.invalid }
        let lookup = Dictionary(revisions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var drafts: [(String, [AsoChange])] = []
        for document in documents.sorted(by: { $0.key < $1.key }) {
            guard let revision = lookup[String(document.key.dropFirst(prefix.count))] else { continue }
            drafts.append((revision.id, ASO.draftChanges(revision, draft: try JSONText.parse(document.payload))))
        }
        return try Self.journalEvents(accountId: accountId, appId: appId, revisions: revisions, drafts: drafts, plan: plan, reviews: reviews)
    }

    static func journalKey(_ accountId: String, _ appId: String, _ eventId: String) throws -> String {
        let pattern = #"^(?:publish:[a-f0-9-]{36}|import:[a-f0-9-]{36}:[A-Za-z0-9_-]{1,256}|draft:[a-f0-9-]{36}|plan:[a-f0-9-]{36}:[A-Za-z0-9_-]{1,256})$"#
        guard accountId.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil, appId.range(of: #"^\d+$"#, options: .regularExpression) != nil,
              eventId.range(of: pattern, options: .regularExpression) != nil else { throw JournalFailure.invalid }
        return "\(accountId):\(appId):\(eventId)"
    }

    public func journalNote(accountId: String, appId: String, eventId: String) throws -> (revision: Int, note: JournalNote?) {
        let key = try Self.journalKey(accountId, appId, eventId)
        guard let saved = try storeAccess({ try $0.document(namespace: "change_journal_notes", key: key) }) else { return (0, nil) }
        return (saved.revision, try JournalNote(try JSONText.parse(saved.payload), eventId: eventId))
    }

    /// Saves a note only onto the journal entry and note revision the editor loaded.
    public func saveJournalNote(accountId: String, appId: String, note input: JournalNote, expected: Int) throws -> (revision: Int, note: JournalNote) {
        guard let event = try changeJournal(accountId: accountId, appId: appId).first(where: { $0.id == input.eventId }) else { throw JournalFailure.unavailable }
        let key = try Self.journalKey(accountId, appId, event.id)
        guard input.basis == event.basis, expected >= 0 else { throw JournalFailure.stale }
        var note = input; note.updatedAt = CustomerReview.isoString(Date())
        try note.validate()
        let mutex = "journal_" + JSONText.string(key).rawSHA256.prefix(40)
        return try storeAccess { store in
            try FileMutex.withLock(store.directory.appendingPathComponent("\(mutex).mutex")) {
                guard (try store.document(namespace: "change_journal_notes", key: key)?.revision ?? 0) == expected else { throw JournalFailure.stale }
                try store.transaction { current in
                    guard (try current("change_journal_notes", key)?.revision ?? 0) == expected else { throw JournalFailure.stale }
                    return [.put(namespace: "change_journal_notes", key: key, json: note.json.data)]
                }
                return ((try store.document(namespace: "change_journal_notes", key: key)?.revision) ?? 0, note)
            }
        }
    }
}

/// One saved state of a version's listing, for side-by-side comparison.
public struct AsoSnapshot: Identifiable, Sendable, Equatable, Codable {
    public struct Field: Sendable, Equatable, Codable {
        public let key, section, field, value: String
        public static func == (a: Self, b: Self) -> Bool { TextSemantics.same(a.key, b.key) && TextSemantics.same(a.section, b.section) && TextSemantics.same(a.field, b.field) && TextSemantics.same(a.value, b.value) }
    }
    public let id, version, at, savedAt, revisionId: String, dateCreated: Bool, fields: [Field]
    init(_ snapshot: ASO.Snapshot) {
        id = "\(snapshot.revisionId):\(snapshot.versionId)"; version = snapshot.version; at = snapshot.at; savedAt = snapshot.savedAt; revisionId = snapshot.revisionId
        dateCreated = snapshot.dateCreated; fields = snapshot.fields.map { Field(key: $0.key, section: $0.section, field: $0.field, value: $0.value) }
    }
    var json: JSONText { .object([("id", .string(id)), ("version", .string(version)), ("at", .string(at)), ("savedAt", .string(savedAt)), ("revisionId", .string(revisionId)), ("dateCreated", .bool(dateCreated)), ("fields", .array(fields.map { .object([("key", .string($0.key)), ("section", .string($0.section)), ("field", .string($0.field)), ("value", .string($0.value))]) }))]) }
}

extension WorkspaceSession {
    /// Every distinct saved listing state, oldest first, and the app's unsaved draft changes.
    public func asoSnapshots(accountId: String, appId: String) throws -> (snapshots: [AsoSnapshot], drafts: [AsoChange], primaryLocale: String) {
        let revisions = try self.revisions(accountId: accountId, appId: appId)
        let snapshots = AsoComparison.snapshots(revisions)
        let prefix = "\(accountId):\(appId):"
        let documents = try storeAccess { try $0.documents(namespace: "drafts", prefix: prefix) }
        var drafts: [AsoChange] = []
        for revision in revisions {
            guard let document = documents.first(where: { $0.key == prefix + revision.id }) else { continue }
            drafts += ASO.draftChanges(revision, draft: try JSONText.parse(document.payload)).map { AsoChange(section: "Saved import \(revision.importedAt.prefix(16).replacingOccurrences(of: "T", with: " ")) UTC · \($0.section)", field: $0.field, before: $0.before, after: $0.after) }
        }
        return (snapshots, drafts, revisions.first?.app.primaryLocale ?? "")
    }
}
