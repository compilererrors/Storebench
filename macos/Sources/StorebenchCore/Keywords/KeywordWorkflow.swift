import Foundation

public struct KeywordChange: Identifiable, Sendable, Equatable {
    public let id, label, before, after: String
    public var json: JSONText { .object([("id", .string(id)), ("label", .string(label)), ("before", .string(before)), ("after", .string(after))]) }
}

extension Keywords {
    public struct Filters: Sendable, Equatable {
        public var query, locale, territory, status, source: String
        public init(query: String = "", locale: String = "", territory: String = "", status: String = "", source: String = "") {
            self.query = query; self.locale = locale; self.territory = territory; self.status = status; self.source = source
        }
    }
    public struct Selection: Sendable, Equatable {
        public let locale: String?, text: String
        public var json: JSONText { .object([("locale", locale.map(JSONText.string) ?? .null), ("text", .string(text))]) }
    }
    public struct TextReview: Sendable, Equatable {
        public let duplicates: [String], cleaned: String
        public var json: JSONText { .object([("duplicates", .array(duplicates.map(JSONText.string))), ("cleaned", .string(cleaned))]) }
    }
    public static func reviewText(_ text: String) -> TextReview {
        var seen: Set<String> = [], unique: [String] = [], duplicates: [String] = []
        for raw in text.unicodeScalars.split(separator: ",", omittingEmptySubsequences: false) {
            let term = TextSemantics.trim(String(raw)), key = term.precomposedStringWithCompatibilityMapping.lowercased()
            guard !term.isEmpty else { continue }
            if !seen.insert(key).inserted { duplicates.append(term) } else { unique.append(term) }
        }
        return TextReview(duplicates: duplicates, cleaned: unique.joined(separator: ","))
    }
    public static func selection(_ items: [KeywordIdea]) -> Selection {
        Selection(locale: Set(items.map(\.locale)).count == 1 ? items.first?.locale : nil, text: reviewText(items.map(\.term).joined(separator: ",")).cleaned)
    }
    public static func filtered(_ items: [KeywordIdea], _ filters: Filters) -> [KeywordIdea] {
        let query = TextSemantics.trim(filters.query).lowercased()
        let rows = items.filter {
            (query.isEmpty || "\($0.term)\n\($0.reference)\n\($0.notes)".lowercased().range(of: query, options: .literal) != nil) && (filters.locale.isEmpty || $0.locale == filters.locale)
                && (filters.territory.isEmpty || (filters.territory == "unspecified" ? $0.territory.isEmpty : $0.territory == filters.territory))
                && (filters.status.isEmpty || $0.status == filters.status) && (filters.source.isEmpty || $0.source == filters.source)
        }
        return rows.enumerated().sorted { lhs, rhs in
            for (a, b) in [(lhs.element.term, rhs.element.term), (lhs.element.locale, rhs.element.locale), (lhs.element.territory, rhs.element.territory)] {
                let result = a.compare(b, locale: Locale(identifier: "en"))
                if result != .orderedSame { return result == .orderedAscending }
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
    /// Stable column sorting uses the English base/numeric comparison shared by every table.
    public static func ordered(_ rows: [KeywordIdea], key: String, descending: Bool = false, picker: Bool = false) -> [KeywordIdea] {
        guard (picker ? ["keyword", "source"] : ["keyword", "location", "status", "evidence"]).contains(key) else { return rows }
        func value(_ row: KeywordIdea) -> String {
            switch key {
            case "keyword": picker ? "\(row.term) \(row.territory)" : row.term
            case "location": "\(row.locale) \(row.territory)"
            case "status": KeywordIdea.label(KeywordIdea.statuses, row.status)
            case "source": "\(KeywordIdea.label(KeywordIdea.sources, row.source)) \(row.reference)"
            default: "\(KeywordIdea.label(KeywordIdea.sources, row.source)) \(row.observedOn) \(row.reference) \(row.notes)"
            }
        }
        return rows.enumerated().sorted { lhs, rhs in
            let result = value(lhs.element).compare(value(rhs.element), options: [.numeric, .caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en"))
            return result == .orderedSame ? lhs.offset < rhs.offset : result == (descending ? .orderedDescending : .orderedAscending)
        }.map(\.element)
    }
    public struct Page: Sendable {
        public let number, count: Int
        public let rows: [KeywordIdea]
        public init(_ rows: [KeywordIdea], requested: Int, size: Int) {
            let size = max(1, min(limit, size)), count = max(1, (rows.count + size - 1) / size), number = max(1, min(count, requested))
            self.number = number; self.count = count; self.rows = Array(rows.dropFirst((number - 1) * size).prefix(size))
        }
    }
    public static func changes(_ before: KeywordNotebook, _ after: KeywordNotebook) -> [KeywordChange] {
        let previous = Dictionary(before.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }), next = Dictionary(after.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func describe(_ row: KeywordIdea?) -> String {
            guard let row else { return "Not in this notebook" }
            return "\(row.term)\n\(row.locale) · \(row.territory.isEmpty ? "Any territory" : row.territory) · \(KeywordIdea.label(KeywordIdea.statuses, row.status))\n\(KeywordIdea.label(KeywordIdea.sources, row.source)) · \(row.reference.isEmpty ? "No source reference" : row.reference)\n\(row.observedOn.isEmpty ? "No observation date" : row.observedOn)\n\(row.notes)"
        }
        var seen: Set<String> = []
        return (before.items.map(\.id) + after.items.map(\.id)).filter { seen.insert($0).inserted && previous[$0] != next[$0] }.map { id in
            KeywordChange(id: id, label: "\(next[id] == nil ? "Removed" : previous[id] == nil ? "Added" : "Updated") keyword idea", before: describe(previous[id]), after: describe(next[id]))
        }
    }
    public static func fromJSON(_ value: JSONText) throws -> KeywordNotebook { try decode(value) }
    public static func normalizedIdea(_ value: KeywordIdea) throws -> KeywordIdea { try normalize(value) }

    /// Form input accepts compact dates; persisted and imported notebook data stays canonical.
    public static func validatedInput(_ value: KeywordIdea) throws -> KeywordIdea {
        var item = value
        item.observedOn = TextSemantics.trim(item.observedOn)
        if item.observedOn.range(of: "^[0-9]{8}$", options: .regularExpression) != nil {
            let date = Array(item.observedOn)
            item.observedOn = String(date[0..<4]) + "-" + String(date[4..<6]) + "-" + String(date[6..<8])
        }
        guard !TextSemantics.words(item.term).isEmpty else { throw KeywordInputFailure(field: "Keyword or phrase", message: "Enter a keyword or phrase.") }
        guard item.term.utf16.count <= 200, !item.term.contains(",") else { throw KeywordInputFailure(field: "Keyword or phrase", message: "Use one idea without commas, up to 200 characters. Use Add multiple ideas for a list.") }
        guard StoreLocales.codes.contains(item.locale) else { throw KeywordInputFailure(field: "Listing language", message: "Choose a listing language.") }
        guard item.territory.isEmpty || Territories.alpha3.values.contains(item.territory) else { throw KeywordInputFailure(field: "Target territory", message: "Choose a territory or Any market.") }
        guard KeywordIdea.statuses.contains(where: { $0.0 == item.status }) else { throw KeywordInputFailure(field: "Idea status", message: "Choose a status for this idea.") }
        guard KeywordIdea.sources.contains(where: { $0.0 == item.source }) else { throw KeywordInputFailure(field: "Idea source", message: "Choose where this idea came from.") }
        guard item.observedOn.isEmpty || ProductPricing.calendarDate(item.observedOn) else { throw KeywordInputFailure(field: "Observation date", message: "Enter a valid date as YYYY-MM-DD or YYYYMMDD, or leave it empty.") }
        guard item.reference.utf16.count <= 500 else { throw KeywordInputFailure(field: "Source reference", message: "Keep the source reference within 500 characters.") }
        guard item.notes.utf16.count <= 2000 else { throw KeywordInputFailure(field: "Research notes", message: "Keep research notes within 2,000 characters.") }
        return try normalize(item)
    }
}

/// A concrete local review stays tied to the editor's loaded revision and exact normalized inputs.
public struct KeywordNotebookEditor: Sendable {
    public struct Review: Sendable {
        public let notebook: KeywordNotebook, revision, fingerprint: String, changes: [KeywordChange]
        fileprivate init(notebook: KeywordNotebook, revision: String, changes: [KeywordChange]) {
            self.notebook = notebook; self.revision = revision; fingerprint = Keywords.revision(notebook); self.changes = changes
        }
    }
    public private(set) var values: SavedValueReview<KeywordNotebook>
    public private(set) var review: Review?
    public var dirty: Bool { values.dirty }
    public var changes: [KeywordChange] { Keywords.changes(values.baseline.value, values.inputs) }
    public init(notebook: KeywordNotebook, revision: String) throws {
        guard Self.validRevision(revision) else { throw KeywordFailure.storage }
        values = SavedValueReview(value: try Keywords.normalize(notebook), revision: revision)
    }
    private static func validRevision(_ text: String) -> Bool { text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    private func scoped(_ notebook: KeywordNotebook) throws -> KeywordNotebook {
        guard notebook.accountId == values.baseline.value.accountId, notebook.appId == values.baseline.value.appId else { throw KeywordFailure.scope }
        return try Keywords.normalize(notebook)
    }
    public mutating func change(_ notebook: KeywordNotebook) throws {
        let normalized = try scoped(notebook)
        guard normalized.json.data.count <= 8_000_000 else { throw KeywordFailure.limit }
        let baseline = values.baseline
        values = SavedValueReview(value: baseline.value, revision: baseline.revision); values.inputs = normalized; review = nil
    }
    public mutating func discard() { values = SavedValueReview(value: values.baseline.value, revision: values.baseline.revision); review = nil }
    public mutating func compare(notebook: KeywordNotebook, revision: String) throws {
        guard Self.validRevision(revision) else { throw KeywordFailure.storage }
        values.compare(value: try scoped(notebook), revision: revision); review = nil
    }
    public mutating func discardComparison() {
        let inputs = values.inputs, baseline = values.baseline
        values = SavedValueReview(value: baseline.value, revision: baseline.revision); values.inputs = inputs; review = nil
    }
    public mutating func acceptLatest(useSaved: Bool) { values.acceptLatest(useSaved: useSaved); review = nil }
    public mutating func discardReview() { review = nil }
    public mutating func prepareReview(currentRevision: String? = nil) throws {
        review = nil
        guard currentRevision == nil || currentRevision == values.baseline.revision else { throw KeywordFailure.stale }
        let notebook = values.inputs
        guard dirty, notebook.json.data.count <= 8_000_000 else { throw KeywordFailure.limit }
        review = Review(notebook: notebook, revision: values.baseline.revision, changes: Keywords.changes(values.baseline.value, notebook))
    }
    /// Checks the inputs against the current saved revision and returns them ready to save, so a change is kept on this Mac in one step.
    public mutating func prepareSave(currentRevision: String) throws -> Review {
        try prepareReview(currentRevision: currentRevision)
        return try reviewedSave()
    }
    public func reviewedSave() throws -> Review {
        guard let review, review.revision == values.baseline.revision, review.notebook == values.inputs, review.fingerprint == Keywords.revision(values.inputs), !review.changes.isEmpty else { throw KeywordFailure.stale }
        return review
    }
    public mutating func confirmedSave(_ revision: String) throws {
        let current = try reviewedSave()
        guard revision == current.fingerprint else { throw KeywordFailure.storage }
        values = SavedValueReview(value: current.notebook, revision: revision); review = nil
    }
    public mutating func selectedStatus(_ ids: Set<String>, status: String) throws {
        guard KeywordIdea.statuses.contains(where: { $0.0 == status }) else { throw KeywordFailure.format }
        var next = values.inputs
        next.items = next.items.map { item in var item = item; if ids.contains(item.id) { item.status = status }; return item }
        try change(next)
    }
    public mutating func removeSelected(_ ids: Set<String>) throws {
        var next = values.inputs; next.items.removeAll { ids.contains($0.id) }; try change(next)
    }
}

/// Only saved Ready to try ideas in the requested listing language can enter an unsaved text editor.
public struct KeywordListingSelection: Sendable {
    public enum Mode: String, CaseIterable, Sendable { case append, replace }
    public let current, proposed: String
    public let selectedCount, bytes: Int
    public var exceeded: Bool { bytes > 100 }
    public var canUse: Bool { selectedCount > 0 && !exceeded && !proposed.utf8.elementsEqual(current.utf8) }
    public var json: JSONText { .object([("current", .string(current)), ("proposed", .string(proposed)), ("selectedCount", .number(Double(selectedCount))), ("bytes", .number(Double(bytes))), ("exceeded", .bool(exceeded)), ("canUse", .bool(canUse))]) }
    public init(items: [KeywordIdea], locale: String, current: String, selected: Set<String>, mode: Mode) throws {
        guard StoreLocales.codes.contains(locale), current.utf8.count <= 16_000 else { throw KeywordFailure.format }
        let chosen = items.filter { $0.locale == locale && $0.status == "ready" && selected.contains($0.id) }
        self.current = current; selectedCount = chosen.count
        let text = Keywords.selection(chosen).text
        proposed = Keywords.reviewText(mode == .append ? current + "," + text : text).cleaned; bytes = proposed.utf8.count
    }
}

public struct KeywordPickerSnapshot: Sendable {
    public let scope: RecoveryGuidance.Scope, locale: String, rows: [KeywordIdea]
    public init(notebook: KeywordNotebook, scope: RecoveryGuidance.Scope, locale: String) throws {
        guard notebook.accountId == scope.accountId, notebook.appId == scope.appId, StoreLocales.codes.contains(locale) else { throw KeywordFailure.scope }
        let saved = try Keywords.normalize(notebook)
        self.scope = scope; self.locale = locale
        rows = saved.items.filter { $0.locale == locale && $0.status == "ready" }.sorted { $0.term.compare($1.term, locale: Locale(identifier: "en")) == .orderedAscending }
    }
    public func selection(current: String, selected: Set<String>, mode: KeywordListingSelection.Mode) throws -> KeywordListingSelection {
        try KeywordListingSelection(items: rows, locale: locale, current: current, selected: selected, mode: mode)
    }
}

public enum KeywordFiles {
    public static func export(_ notebook: KeywordNotebook, json: Bool, to url: URL) throws {
        let saved = try Keywords.normalize(notebook)
        let bytes = Data((json ? try Keywords.json(saved) : Keywords.csv(saved)).utf8)
        try ReportFiles.atomicStream(to: url) { write in
            var position = 0
            while position < bytes.count {
                try Task.checkCancellation()
                let end = min(bytes.count, position + 64 * 1024)
                try write(bytes.subdata(in: position..<end)); position = end
            }
        }
    }
    public static func parse(_ data: Data, accountId: String, appId: String, saved: KeywordNotebook) throws -> KeywordNotebook {
        guard saved.accountId == accountId, saved.appId == appId else { throw KeywordFailure.scope }
        let text: String
        do { text = try ReportFiles.texts([data], purpose: .keywords)[0] }
        catch ReportFiles.Failure.size { throw KeywordFailure.limit }
        catch { throw KeywordFailure.format }
        let imported = try Keywords.importText(text, accountId: accountId, appId: appId, saved: saved)
        guard imported.json.data.count <= 8_000_000 else { throw KeywordFailure.limit }
        return imported
    }
}

extension WorkspaceSession {
    @discardableResult public func saveReviewedKeywordNotebook(_ review: KeywordNotebookEditor.Review) throws -> String {
        guard Keywords.revision(review.notebook) == review.fingerprint, !review.changes.isEmpty else { throw KeywordFailure.stale }
        return try saveKeywordNotebook(review.notebook, revision: review.revision)
    }
}
