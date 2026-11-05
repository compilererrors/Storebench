import Foundation

/// Reading newer changes or reports never silently replaces an interpretation's saved baseline.
public enum JournalNoteBaseline {
    public static func initial(event: JournalEvent, saved: JournalNote?, metric: String? = nil, evidence: String? = nil) throws -> JournalNote {
        if let saved { guard saved.eventId == event.id else { throw JournalFailure.invalid }; return saved }
        return JournalNote(eventId: event.id, basis: event.basis, attribution: event.source == "import" ? "unknown" : "storebench", primaryMetric: metric ?? "none", evidenceFingerprint: evidence)
    }
    public static func canSave(_ note: JournalNote, event: JournalEvent, evidence: String?) -> Bool {
        guard note.eventId == event.id && note.basis == event.basis && (evidence == nil || note.evidenceFingerprint == evidence) else { return false }
        return (try? note.validate()) != nil
    }
    public static func hasChanges(_ note: JournalNote, from baseline: JournalNote) -> Bool { note.json.data != baseline.json.data }
    public static func usingCurrentChanges(_ note: JournalNote, event: JournalEvent) throws -> JournalNote {
        guard note.eventId == event.id else { throw JournalFailure.invalid }
        var result = note; result.basis = event.basis; return result
    }
    public static func usingCurrentEvidence(_ note: JournalNote, fingerprint: String) throws -> JournalNote {
        guard fingerprint.range(of: #"\A[a-f0-9]{64}\z"#, options: .regularExpression) != nil else { throw JournalFailure.invalid }
        var result = note; result.evidenceFingerprint = fingerprint; return result
    }
}
