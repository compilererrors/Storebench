import StorebenchCore
import SwiftUI

/// A note retains its loaded revision and evidence until the user explicitly chooses another baseline.
struct JournalNoteEditor: View {
    let account: Account, app: Account.App, session: WorkspaceSession?, event: JournalEvent
    var suggestedMetric: String? = nil
    var evidence: String? = nil
    @State private var latestReading = false
    @State private var note: JournalNote?
    @State private var baseline: JournalNote?
    @State private var revision = 0
    @State private var working = false
    @State private var status = ""
    @State private var problem = false
    @State private var readId = UUID()
    @State private var latest: (revision: Int, note: JournalNote?)?
    @State private var differences: [SavedValueChange]?
    private var dirty: Bool { guard let note, let baseline else { return false }; return JournalNoteBaseline.hasChanges(note, from: baseline) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Decision and next step").font(.sbHeadline)
            Text("Save your interpretation for this exact journal change. Changing reports or filters requires an explicit evidence choice before saving.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
            if let binding = Binding($note) {
                if binding.wrappedValue.basis != event.basis {
                    Text("The recorded change set has changed. Compare its current before and after values with your note.").font(.sbCallout).foregroundStyle(StorebenchTheme.color("color-warning")).fixedSize(horizontal: false, vertical: true)
                    Button("Use Change Set") { do { note = try JournalNoteBaseline.usingCurrentChanges(binding.wrappedValue, event: event) } catch { status = JournalFailure.invalid.message } }.help("Use Current Change Set").accessibilityLabel("Use Current Change Set").storebenchWorking(working)
                }
                if let evidence, binding.wrappedValue.evidenceFingerprint != evidence {
                    Text("The selected report evidence has changed. Compare dates, revisions and other events above with the saved conclusion.").font(.sbCallout).foregroundStyle(StorebenchTheme.color("color-warning")).fixedSize(horizontal: false, vertical: true)
                    Button("Use Current Reports") { do { note = try JournalNoteBaseline.usingCurrentEvidence(binding.wrappedValue, fingerprint: evidence) } catch { status = JournalFailure.invalid.message } }.storebenchWorking(working)
                } else if evidence == nil && binding.wrappedValue.evidenceFingerprint != nil {
                    Text("This note includes a report baseline. Open ASO Diff → Outcome to compare the current reports with the saved evidence.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
                }
                StorebenchFormGrid {
                    StorebenchPicker("Where the change came from", selection: binding.attribution) { SelectionOption("Unknown", value: "unknown"); SelectionOption("Storebench decision", value: "storebench"); SelectionOption("External change", value: "external") }
                    StorebenchPicker("Primary measure", selection: binding.primaryMetric) { SelectionOption("Not selected", value: "none"); selectionOptions(AsoOutcome.metrics) { SelectionOption($0.title, value: $0.key) } }
                }
                field("Reason for the change", binding.intent)
                field("Hypothesis", binding.hypothesis)
                field("Other events in the same period", binding.simultaneousEvents)
                field("What the evidence shows", binding.conclusion)
                field("Next decision", binding.nextDecision)
                LatestSaveReview(busy: working, reading: latestReading, hasEdits: dirty, changes: differences, note: nil, onRead: { Task { await readLatest() } },
                                 onKeep: latest == nil ? nil : { chooseLatest(useSaved: false) }, onUse: latest == nil ? nil : { chooseLatest(useSaved: true) })
                Text(binding.wrappedValue.updatedAt.isEmpty ? "No note has been saved yet." : "Previous save: \(binding.wrappedValue.updatedAt)").font(.sbCaption).foregroundStyle(StorebenchTheme.muted).textSelection(.enabled)
                if working || dirty || JournalNoteBaseline.canSave(binding.wrappedValue, event: event, evidence: evidence) {
                    Button(working ? "Saving…" : "Save Journal Note") { Task { await save() } }.buttonStyle(StorebenchButtonStyle(.primary)).storebenchWorking(working)
                }
            } else if working { StorebenchLoadingStatus(message: "Reading the saved journal note…", surface: false) }
            StorebenchFeedback(text: status, height: 34, error: problem)
        }
        .storebenchWorking(working)
        .trackUnsavedChanges(dirty, busy: working, problem: { problem ? "Journal note: " + status : nil }, onSave: { await save(); return !dirty })
        .task(id: event.id) { await load() }
        .onDisappear { readId = UUID() }
    }
    private func field(_ title: String, _ value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.sbSubheadline.weight(.semibold)); StorebenchTextArea(text: value, height: max(48, StorebenchTheme.textarea(rows: 2))).accessibilityLabel(title)
            Text("\(value.wrappedValue.utf16.count) of 1,000 characters").font(.sbCaption).foregroundStyle(value.wrappedValue.utf16.count > 1000 ? StorebenchTheme.color("color-danger") : StorebenchTheme.muted)
        }
    }
    private func load() async {
        guard let session, !working else { return }
        let id = UUID(); readId = id; working = true
        defer { if readId == id { working = false } }
        do {
            let saved = try await session.journalNote(accountId: account.id, appId: app.id, eventId: event.id)
            guard readId == id, !Task.isCancelled else { return }
            let value = try JournalNoteBaseline.initial(event: event, saved: saved.note, metric: suggestedMetric, evidence: evidence)
            note = value; baseline = value; revision = saved.revision; latest = nil; differences = nil; status = ""
        } catch { guard readId == id, !Task.isCancelled else { return }; status = "The note could not be read. Existing notes are unchanged." }
    }
    private func readLatest() async {
        guard let session, let note, !working else { return }
        latestReading = true; defer { latestReading = false }
        working = true; defer { working = false }
        do {
            let saved = try await session.journalNote(accountId: account.id, appId: app.id, eventId: event.id)
            let value = try JournalNoteBaseline.initial(event: event, saved: saved.note, metric: suggestedMetric, evidence: evidence)
            latest = saved
            let fields = [("basis", "Change set", value.basis, note.basis), ("evidence", "Report evidence", value.evidenceFingerprint ?? "", note.evidenceFingerprint ?? ""),
                          ("attribution", "Attribution", value.attribution, note.attribution), ("metric", "Primary measure", value.primaryMetric, note.primaryMetric),
                          ("intent", "Reason", value.intent, note.intent), ("hypothesis", "Hypothesis", value.hypothesis, note.hypothesis), ("simultaneous", "Other events", value.simultaneousEvents, note.simultaneousEvents),
                          ("conclusion", "Conclusion", value.conclusion, note.conclusion), ("next", "Next decision", value.nextDecision, note.nextDecision)]
            differences = fields.filter { !$0.2.utf8.elementsEqual($0.3.utf8) }.map { SavedValueChange(id: $0.0, label: $0.1, saved: $0.2, edited: $0.3) }
            status = "Latest values read. Your inputs and loaded revision are unchanged."
        } catch { status = "The latest note could not be read. Your inputs and loaded revision are unchanged." }
    }
    private func chooseLatest(useSaved: Bool) {
        guard let latest, !working else { return }
        do {
            let value = try JournalNoteBaseline.initial(event: event, saved: latest.note, metric: suggestedMetric, evidence: evidence)
            if useSaved { note = value }; baseline = value; revision = latest.revision; self.latest = nil; differences = nil
            status = "Baseline chosen. Nothing has been saved."
        } catch { status = JournalFailure.invalid.message }
    }
    private func save() async {
        guard let session, let note, !working else { return }
        guard JournalNoteBaseline.canSave(note, event: event, evidence: evidence) else {
            problem = true
            status = note.basis != event.basis ? "Not saved. Choose Use Change Set above first; your inputs are kept."
                : evidence != nil && note.evidenceFingerprint != evidence ? "Not saved. Choose Use Current Reports above first; your inputs are kept."
                : "Not saved. Shorten the fields over 1,000 characters; your inputs are kept."
            return
        }
        working = true; defer { working = false }
        do {
            let saved = try await session.saveJournalNote(accountId: account.id, appId: app.id, note: note, expected: revision)
            revision = saved.revision; self.note = saved.note; baseline = saved.note; latest = nil; differences = nil; problem = false; status = "Journal note saved on this Mac."
        } catch let failure as JournalFailure { problem = true; status = "Not saved. " + failure.message } catch { problem = true; status = "Not saved. Your inputs are kept; try again." }
    }
}
