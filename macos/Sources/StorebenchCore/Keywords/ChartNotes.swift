import Foundation

/// A note of your own on an app's charts, such as a campaign, a feature or a price change, so its date can be read beside listing
/// changes. Notes stay in the encrypted workspace on this Mac.
public struct ChartNote: Sendable, Equatable, Codable, Identifiable {
    public let id, date, text, createdAt: String
    var json: JSONText { .object([("id", .string(id)), ("date", .string(date)), ("text", .string(text)), ("createdAt", .string(createdAt))]) }
    init?(_ value: JSONText) {
        guard let id = value["id"]?.text, let date = value["date"]?.text, PeriodDates.number(date) != nil, let text = value["text"]?.text, let created = value["createdAt"]?.text else { return nil }
        self.init(id: id, date: date, text: text, createdAt: created)
    }
    public init(id: String, date: String, text: String, createdAt: String) { self.id = id; self.date = date; self.text = text; self.createdAt = createdAt }
}

public enum ChartNoteFailure: Error, Equatable {
    case invalid(String), notFound, full
    public var message: String {
        switch self {
        case .invalid(let text): text
        case .notFound: "This note was already removed."
        case .full: "An app can have at most \(ChartNotes.limit) chart notes. Remove one before adding another."
        }
    }
}

public enum ChartNotes {
    public static let limit = 500, textLimit = 200
    static let namespace = "chart_notes"
    static func key(_ accountId: String, _ appId: String) -> String { "\(accountId):\(appId)" }
    static func decode(_ document: EncryptedDocumentStore.Document?) throws -> [ChartNote] {
        guard let document else { return [] }
        let value = try JSONText.parse(document.payload)
        guard value["schemaVersion"] == .number(1) else { throw ChartNoteFailure.invalid("Saved chart notes could not be read.") }
        return WorkspaceSession.items(value["notes"]).compactMap(ChartNote.init).sorted { ($0.date, $0.createdAt, $0.id) < ($1.date, $1.createdAt, $1.id) }
    }
    static func encode(_ notes: [ChartNote]) -> Data { JSONText.object([("schemaVersion", .number(1)), ("notes", .array(notes.map(\.json)))]).data }
    /// Notes dated inside a window around a date, oldest first.
    public static func within(_ notes: [ChartNote], date: String, days: Int) -> [ChartNote] {
        guard let day = PeriodDates.number(date) else { return [] }
        return notes.filter { note in PeriodDates.number(note.date).map { abs($0 - day) <= days } ?? false }
    }
}

extension WorkspaceSession {
    /// The app's chart notes, oldest first.
    public func chartNotes(accountId: String, appId: String) throws -> [ChartNote] {
        try storeAccess { try ChartNotes.decode(try $0.document(namespace: ChartNotes.namespace, key: ChartNotes.key(accountId, appId))) }
    }

    /// Adds a note. The read, the check and the replacement run under one shared file lock, so notes added from other windows are kept.
    @discardableResult
    public func addChartNote(accountId: String, appId: String, date: String, text: String, now: Date = Date()) throws -> ChartNote {
        let trimmed = TextSemantics.trim(text)
        guard PeriodDates.number(date) != nil else { throw ChartNoteFailure.invalid("Choose a date for the note.") }
        guard !trimmed.isEmpty, trimmed.count <= ChartNotes.textLimit, !ReportTables.controlInCell(trimmed), !trimmed.contains(where: \.isNewline) else {
            throw ChartNoteFailure.invalid("Write a note of 1 to \(ChartNotes.textLimit) characters on one line.")
        }
        let note = ChartNote(id: UUID().uuidString.lowercased(), date: date, text: trimmed, createdAt: CustomerReview.isoString(now))
        try changeChartNotes(accountId: accountId, appId: appId) { notes in
            guard notes.count < ChartNotes.limit else { throw ChartNoteFailure.full }
            return notes + [note]
        }
        return note
    }

    /// Removes one note by its ID.
    public func removeChartNote(accountId: String, appId: String, id: String) throws {
        try changeChartNotes(accountId: accountId, appId: appId) { notes in
            guard notes.contains(where: { $0.id == id }) else { throw ChartNoteFailure.notFound }
            return notes.filter { $0.id != id }
        }
    }

    private func changeChartNotes(accountId: String, appId: String, _ change: ([ChartNote]) throws -> [ChartNote]) throws {
        try requireOwnWorkspace()
        let key = ChartNotes.key(accountId, appId)
        try storeAccess { store in
            try FileMutex.withLock(store.directory.appendingPathComponent("chart_notes.mutex")) {
                try store.transaction { current in
                    let notes = try change(try ChartNotes.decode(try current(ChartNotes.namespace, key)))
                    return [.put(namespace: ChartNotes.namespace, key: key, json: ChartNotes.encode(notes))]
                }
            }
        }
    }
}
