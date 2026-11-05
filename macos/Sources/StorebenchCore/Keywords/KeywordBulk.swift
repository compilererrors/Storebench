import Foundation

public struct KeywordBulkRow: Sendable, Equatable, Identifiable {
    public enum Duplicate: String, Sendable { case notebook, input }
    public let id: String, candidate: KeywordIdea, duplicate: Duplicate?
}

public struct KeywordBulkPreview: Sendable, Equatable { public let rows: [KeywordBulkRow], available: Int }

extension Keywords {
    /// Terms are paired with each explicitly selected research territory; listing languages are unchanged.
    public static func previewBulk(_ notebook: KeywordNotebook, terms: String, locale: String, territories: [String], createId: () -> String = { UUID().uuidString.lowercased() }) throws -> KeywordBulkPreview {
        let current = try normalize(notebook)
        guard terms.utf16.count <= 80_000, !territories.isEmpty, territories.count <= 250 else { throw KeywordFailure.format }
        let words = terms.components(separatedBy: CharacterSet(charactersIn: ",\r\n")).map(TextSemantics.trim).filter { !$0.isEmpty }
        guard !words.isEmpty else { throw KeywordFailure.format }
        var regions: [String] = []; for territory in territories where !regions.contains(territory) { regions.append(territory) }
        guard words.count * regions.count <= 4000 else { throw KeywordFailure.limit }
        let existing = Set(current.items.map(\.identity)); var seen = Set<String>(), rows: [KeywordBulkRow] = []
        for term in words { for territory in regions {
            let candidate = try normalize(KeywordIdea(id: createId(), term: term, locale: locale, territory: territory)), identity = candidate.identity
            let duplicate: KeywordBulkRow.Duplicate? = existing.contains(identity) ? .notebook : seen.contains(identity) ? .input : nil
            rows.append(KeywordBulkRow(id: String(rows.count), candidate: candidate, duplicate: duplicate)); seen.insert(identity)
        } }
        return KeywordBulkPreview(rows: rows, available: limit - current.items.count)
    }

    /// Adds only reviewed new combinations to the unsaved notebook. Normalization enforces its 2,000-item limit.
    public static func applyBulk(_ notebook: KeywordNotebook, preview: KeywordBulkPreview, selected: [String]) throws -> KeywordNotebook {
        let keys = Set(selected), chosen = preview.rows.filter { keys.contains($0.id) }
        guard !keys.isEmpty, chosen.count == keys.count, !chosen.contains(where: { $0.duplicate != nil }) else { throw KeywordFailure.format }
        return try normalize(KeywordNotebook(accountId: notebook.accountId, appId: notebook.appId, items: notebook.items + chosen.map(\.candidate)))
    }
}
