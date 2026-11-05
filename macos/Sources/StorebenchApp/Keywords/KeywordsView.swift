import AppKit
import StorebenchCore
import SwiftUI
import UniformTypeIdentifiers

/// A scoped manual notebook, saved on this Mac after every change. Local saving never grants Apple publishing approval.
struct KeywordsView: View {
    let account: Account, app: Account.App, session: WorkspaceSession?
    @Binding var locale: String
    @State private var latestReading = false
    @State private var editor: KeywordNotebookEditor?
    @State private var query = ""
    @State private var status = ""
    @State private var territory = ""
    @State private var source = ""
    @State private var bulkStatus = "ready"
    @State private var chosen: Set<String> = []
    @State private var idea: KeywordIdea?
    @State private var bulk = false
    @State private var working = false
    @State private var message = ""
    @State private var issueCode: String?
    @State private var problem = false
    @Environment(\.editorNavigation) private var navigation
    @Environment(\.confirmDestructive) private var confirm

    private struct Choices: Equatable { var query, territory, status, source: String; var chosen: Set<String> }
    private var notebook: KeywordNotebook? { editor?.values.inputs }
    private var filtered: [KeywordIdea] { Keywords.filtered(notebook?.items ?? [], .init(query: query, locale: locale, territory: territory, status: status, source: source)) }
    private var selected: [KeywordIdea] { (notebook?.items ?? []).filter { chosen.contains($0.id) } }
    private var selection: Keywords.Selection { Keywords.selection(selected) }
    private var latestChanges: [SavedValueChange]? {
        guard let editor, let latest = editor.values.comparison else { return nil }
        return Keywords.changes(latest.value, editor.values.inputs).map { .init(id: $0.id, label: $0.label, saved: $0.before, edited: $0.after) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Card(title: "1. Collect keyword ideas", subtitle: "Your shortlist of words to test in App Store keywords. Save research, mark promising words Ready to try, then use them in Localizations.", help: "keywords") {
                StorebenchMetricGrid(maximumColumns: 3) {
                    Fact(title: "Your ideas", value: "\(notebook?.items.count ?? 0)", hint: "A private shortlist for this app")
                    Fact(title: "Ready to try", value: "\(notebook?.items.filter { $0.status == "ready" }.count ?? 0)", hint: "Mark promising terms after research")
                    Fact(title: "Selected", value: "\(chosen.count)", hint: "Ideas chosen for composition below")
                }
                Text("Storebench stores your research. It does not estimate search volume, competition or ranking.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
                if let notebook, notebook.items.count < Keywords.limit {
                    StorebenchActionGroup {
                        Button("Add Multiple Ideas") { bulk = true }
                        Button("Add Keyword Idea") { idea = KeywordIdea(term: "", locale: locale.isEmpty ? "en-US" : locale) }.buttonStyle(StorebenchButtonStyle(.primary))
                    }
                } else if notebook != nil {
                    Text("Your shortlist holds the maximum of \(Keywords.limit) ideas. Remove ideas to add new ones.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
                }
            }
            Card(title: "2. Organize and select", subtitle: "Choose a listing language, inspect your ideas and select the terms you want to use. Selections are kept when you filter or change pages.") {
                StorebenchFilterBar {
                    StorebenchTextField("Find an idea", text: $query, hint: "Search a term, source note or reference.")
                    StorebenchPicker("Listing language", selection: $locale, hint: "Use one language when composing listing keywords.") { SelectionOption("All listing languages", value: ""); selectionOptions(StoreLocales.codes) { SelectionOption("\(StoreLocales.name($0)) · \($0)", value: $0) } }
                }
                DisclosureGroup("More filters") {
                    StorebenchFilterBar(columns: 3) {
                        StorebenchPicker("Territory", selection: $territory, hint: "Research context, separate from listing language.") {
                            SelectionOption("All territories", value: ""); SelectionOption("Any / unspecified", value: "unspecified")
                            selectionOptions(Array(Set((notebook?.items ?? []).map(\.territory).filter { !$0.isEmpty })).sorted()) { SelectionOption("\(WorkspaceSession.countryName($0)) · \($0)", value: $0) }
                        }
                        StorebenchPicker("Status", selection: $status, hint: "You assign each idea's status.") { SelectionOption("All statuses", value: ""); selectionOptions(KeywordIdea.statuses) { SelectionOption($0.1, value: $0.0) } }
                        StorebenchPicker("Source", selection: $source, hint: "Where you found the idea.") { SelectionOption("All sources", value: ""); selectionOptions(KeywordIdea.sources) { SelectionOption($0.1, value: $0.0) } }
                    }
                    Button("Clear Filters") { query = ""; locale = ""; territory = ""; status = ""; source = "" }
                }
                StorebenchCollection(items: filtered, title: { $0.term }, subtitle: { ideaSummary($0) },
                    sorts: [.init(id: "location", label: "Language / territory", less: { ($0.locale + $0.territory) < ($1.locale + $1.territory) }),
                            .init(id: "status", label: "Status", less: { $0.status < $1.status }),
                            .init(id: "source", label: "Source", less: { $0.source < $1.source })],
                    empty: (notebook?.items.isEmpty == true) ? "Your shortlist is empty. Add your first idea above, then mark promising terms Ready to try." : "No ideas match. Change or clear the filters.") { row in
                    keywordCard(row)
                }
                DisclosureGroup("Selected ideas · \(selected.count)") {
                    Text("Selection includes other pages. Status changes and removals are saved on this Mac right away.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
                    StorebenchPicker("New status", selection: $bulkStatus) { selectionOptions(KeywordIdea.statuses) { SelectionOption($0.1, value: $0.0) } }
                    StorebenchActionGroup {
                        if !filtered.isEmpty { Button("Select Matching Ideas") { chosen.formUnion(filtered.map(\.id)) } }
                        if !chosen.isEmpty { Button("Clear Selection") { chosen = [] } }
                        if !selected.isEmpty {
                            Button("Apply Status") { _ = change { try $0.selectedStatus(chosen, status: bulkStatus) } }
                            Button("Remove Selected", role: .destructive) {
                                guard confirm(.removeKeywordIdeas, title: chosen.count == 1 ? "Remove the selected idea?" : "Remove \(chosen.count) selected ideas?",
                                              message: "They are removed from the shortlist. Save Shortlist keeps the change; Discard Changes brings them back until then.", action: "Remove") else { return }
                                if change({ try $0.removeSelected(chosen) }) { chosen = [] }
                            }.help("Remove Selected Ideas").accessibilityLabel("Remove Selected Ideas")
                        }
                    }
                }
            }
            Card(title: "3. Compose listing keywords", subtitle: "Select terms from one language. Read the comma-separated result, then copy it or open Localizations to use saved Ready to try ideas.") {
                StorebenchReadOnlyText(title: "Selected keywords", text: selection.text, field: "keywords")
                Text("\(selection.text.utf8.count) of 100 bytes · \(selection.locale.map(StoreLocales.name) ?? "Choose ideas from one language")").font(.sbCaption).foregroundStyle(selection.text.utf8.count > 100 ? StorebenchTheme.color("color-danger") : StorebenchTheme.muted)
                Text("Avoid repeating words in your app name or subtitle. The listing editor checks the byte limit and repeated words. Publishing listing text requires a separate review in App Store changes.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
                let copyable = !selected.isEmpty && selection.locale != nil && selection.text.utf8.count <= 100
                if copyable || navigation.navigate != nil {
                    StorebenchFormFooter {
                        if copyable { Button("Copy Keywords") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(selection.text, forType: .string) }.help("Copy Selected Keywords").accessibilityLabel("Copy Selected Keywords") }
                        if navigation.navigate != nil { Button("Open Localizations") { navigation.open(.localizations, locale: selection.locale ?? (locale.isEmpty ? nil : locale)) } }
                    }
                }
            }
            Card(title: "Saved on this Mac", subtitle: "Every idea you add, edit or remove is saved on this Mac right away. Saved Ready to try ideas are available in the listing editor's keyword picker.") {
                StorebenchTextSlot(text: message.isEmpty ? (working ? "Saving the shortlist on this Mac…" : editor?.dirty == true ? "These changes are not saved yet. Save them, or discard them." : "Saving the shortlist keeps your research; it does not change App Store text.") : message,
                                   height: 56, font: .sbCallout, color: problem ? StorebenchTheme.color("color-danger") : StorebenchTheme.muted, live: true)
                RecoveryActions(code: issueCode)
                if let editor, editor.dirty { KeywordChanges(title: "Not saved", changes: editor.review?.changes ?? editor.changes) }
                LatestSaveReview(busy: working, reading: latestReading, hasEdits: editor?.dirty == true, available: editor != nil, changes: latestChanges, note: nil, onRead: { Task { await readLatest() } }, onKeep: editor?.values.comparison == nil ? nil : { editor?.acceptLatest(useSaved: false); issueCode = nil; problem = false; message = "Latest save compared. Your edits are kept; save them when ready." }, onUse: editor?.values.comparison == nil ? nil : { editor?.acceptLatest(useSaved: true); chosen = []; issueCode = nil; problem = false; message = "Latest saved ideas loaded. Nothing was saved by the comparison." })
                if editor?.dirty == true {
                    StorebenchFormFooter {
                        Button("Discard Changes", role: .destructive) {
                            guard confirm(.discardChanges, title: "Discard unsaved shortlist changes?", message: "The shortlist returns to its last save on this Mac.", action: "Discard Changes") else { return }
                            editor?.discard(); chosen = []; message = "Unsaved notebook changes discarded."; issueCode = nil; problem = false }.help("Discard Shortlist Changes").accessibilityLabel("Discard Shortlist Changes")
                        Button(problem ? "Try Again" : "Save Shortlist") { Task { await save() } }.help("Save Shortlist on This Mac").accessibilityLabel("Save Shortlist on This Mac").buttonStyle(StorebenchButtonStyle(.primary))
                    }
                }
            }
            DisclosureGroup("Import or export your shortlist") {
                Text("Import a matching CSV or JSON, optionally gzipped. Save or discard your edits first. Exports contain the saved notebook.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
                StorebenchActionGroup {
                    if notebook != nil && editor?.dirty != true { Button("Preview Import…") { Task { await importFile() } }.help("Preview Keyword Import").accessibilityLabel("Preview Keyword Import") }
                    if editor != nil {
                        Button("Export Saved CSV…") { Task { await exportFile(json: false) } }
                        Button("Export Saved JSON…") { Task { await exportFile(json: true) } }
                    }
                }
            }
        }
        .storebenchWorking(working)
        .sheet(item: $idea) { item in KeywordIdeaEditor(item: item) { value in
            change { editor in var next = editor.values.inputs; next.items.removeAll { $0.id == value.id }; next.items.append(value); try editor.change(next) }
        } }
        .sheet(isPresented: $bulk) {
            if let notebook { KeywordBulkView(notebook: notebook, initialLocale: locale.isEmpty ? "en-US" : locale) { next in change { try $0.change(next) } } }
        }
        .task { await load() }
        .historyValue("keywords", Binding(get: { Choices(query: query, territory: territory, status: status, source: source, chosen: chosen) }, set: { value in
            query = value.query; territory = value.territory; status = value.status; source = value.source; chosen = value.chosen
        }))
        .trackUnsavedChanges(editor?.dirty == true, busy: working, problem: { problem ? "Keyword shortlist: " + message : nil }, onSave: { await save(); return editor?.dirty == false })
    }

    private func ideaSummary(_ row: KeywordIdea) -> String {
        let state = KeywordIdea.statuses.first { $0.0 == row.status }?.1 ?? row.status
        return StoreLocales.name(row.locale) + " · " + state + (chosen.contains(row.id) ? " · Selected" : "")
    }
    private func keywordCard(_ row: KeywordIdea) -> some View {
        VStack(alignment: .leading, spacing: StorebenchTheme.space(3)) {
            StorebenchMetricGrid(maximumColumns: 3, minimumWidth: 180) {
                Fact(title: "Research territory", value: row.territory.isEmpty ? "Any territory" : WorkspaceSession.countryName(row.territory), info: "The App Store country you looked at when you found this keyword idea.")
                Fact(title: "Source", value: KeywordIdea.sources.first { $0.0 == row.source }?.1 ?? row.source)
                Fact(title: "Observed", value: row.observedOn.isEmpty ? "No date recorded" : row.observedOn)
            }
            StorebenchTextSlot(text: row.notes.isEmpty ? "No research notes yet. Edit the idea to explain why this term is relevant." : row.notes, height: 72, font: .sbCallout, color: StorebenchTheme.muted)
            if !row.reference.isEmpty { StorebenchTextSlot(text: row.reference, height: 40, font: .sbCaption, color: StorebenchTheme.muted) }
            StorebenchHeader {
                Toggle("Select for composition", isOn: Binding(get: { chosen.contains(row.id) }, set: { if $0 { chosen.insert(row.id) } else { chosen.remove(row.id) } })).toggleStyle(StorebenchToggleStyle())
            } actions: {
                Button("Edit Idea") { idea = row }
            }
            if !working, editor?.changes.contains(where: { $0.id == row.id }) == true { Text("Not saved. Save or discard it under Saved on this Mac.").font(.sbCaption).foregroundStyle(StorebenchTheme.color("color-danger")).fixedSize(horizontal: false, vertical: true) }
        }
    }

    /// Applies a change and saves it on this Mac right away.
    @discardableResult private func change(_ operation: (inout KeywordNotebookEditor) throws -> Void) -> Bool {
        guard mutate(operation) else { return false }
        Task { await save() }; return true
    }
    @discardableResult private func mutate(_ operation: (inout KeywordNotebookEditor) throws -> Void) -> Bool {
        guard var current = editor else { return false }
        do { try operation(&current); editor = current; chosen.formIntersection(current.values.inputs.items.map(\.id)); issueCode = nil; problem = false; message = ""; return true }
        catch let failure as KeywordFailure { issueCode = RecoveryIssue.keywords(failure); problem = true; message = failure.message }
        catch { issueCode = "SB-KEYWORDS-FORMAT"; problem = true; message = KeywordFailure.format.message }
        return false
    }
    private func load() async {
        guard !working, let session else { return }; working = true; defer { working = false }
        do { let value = try await session.keywordNotebook(accountId: account.id, appId: app.id); try Task.checkCancellation(); editor = try KeywordNotebookEditor(notebook: value.notebook, revision: value.revision); chosen.formIntersection(value.notebook.items.map(\.id)) }
        catch { issueCode = "SB-KEYWORDS-STORAGE"; message = KeywordFailure.storage.message }
    }
    private func readLatest() async {
        guard !working, let session else { return }; editor?.discardComparison(); working = true; defer { working = false }
        latestReading = true; defer { latestReading = false }
        do {
            let value = try await session.keywordNotebook(accountId: account.id, appId: app.id); try Task.checkCancellation()
            if editor == nil { editor = try KeywordNotebookEditor(notebook: value.notebook, revision: value.revision) }
            else { try editor?.compare(notebook: value.notebook, revision: value.revision) }
            issueCode = nil; message = "Latest saved ideas read. Your starting revision and unsaved inputs are unchanged."
        } catch { message = "Latest saved ideas could not be read. Your edits are kept."; issueCode = "SB-KEYWORDS-STORAGE" }
    }
    /// Saves the shortlist on this Mac. If it cannot be saved, the changes stay listed in red with Try Again or Discard Changes.
    private func save() async {
        guard !working, let session, var current = editor, current.dirty else { return }
        working = true; defer { working = false }
        do {
            let reviewed: KeywordNotebookEditor.Review
            if current.review != nil { reviewed = try current.reviewedSave() }
            else { let latest = try await session.keywordNotebook(accountId: account.id, appId: app.id); reviewed = try current.prepareSave(currentRevision: latest.revision) }
            let revision = try await session.saveReviewedKeywordNotebook(reviewed)
            try current.confirmedSave(revision); editor = current; issueCode = nil; problem = false; message = "Shortlist saved on this Mac."
        }
        catch let failure as KeywordFailure { issueCode = RecoveryIssue.keywords(failure); problem = true; message = failure == .stale ? "Not saved: the saved ideas changed elsewhere. Compare the latest save below, then save again. Your edits are kept." : "Not saved. " + failure.message }
        catch { issueCode = "SB-KEYWORDS-STORAGE"; problem = true; message = "Not saved. " + KeywordFailure.storage.message }
    }
    private func importFile() async {
        guard !working, let current = editor, !current.dirty, let session else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.commaSeparatedText, .json, .plainText, .gzip]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        working = true; defer { working = false }
        do {
            let files = try await ReportFiles.readAsync([url], purpose: .keywords)
            let latest = try await session.keywordNotebook(accountId: account.id, appId: app.id)
            guard latest.revision == current.values.baseline.revision else { throw KeywordFailure.stale }
            let next = try KeywordFiles.parse(files[0], accountId: account.id, appId: app.id, saved: latest.notebook)
            try Task.checkCancellation()
            var reviewed = current; try reviewed.change(next); if reviewed.dirty { try reviewed.prepareReview(currentRevision: latest.revision) }; editor = reviewed; chosen = []; issueCode = nil; message = reviewed.dirty ? "Import compared with the saved notebook. Read the changes under Saved on this Mac, then choose Save Shortlist or Discard Changes." : "The imported notebook matches the saved ideas."
        } catch let failure as KeywordFailure { issueCode = RecoveryIssue.keywords(failure); message = failure.message }
        catch ReportFiles.Failure.size { issueCode = "SB-KEYWORDS-LIMIT"; message = KeywordFailure.limit.message }
        catch { issueCode = "SB-KEYWORDS-FORMAT"; message = KeywordFailure.format.message }
    }
    private func exportFile(json: Bool) async {
        guard !working, editor != nil, let session else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [json ? .json : .commaSeparatedText]; panel.nameFieldStringValue = "keyword-notebook.\(json ? "json" : "csv")"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        working = true; defer { working = false }
        do { let latest = try await session.keywordNotebook(accountId: account.id, appId: app.id); try Task.checkCancellation(); try KeywordFiles.export(latest.notebook, json: json, to: url); issueCode = nil; message = "Saved notebook exported. Unsaved inputs are excluded." }
        catch { issueCode = "SB-KEYWORDS-STORAGE"; message = "The export could not be completed. The existing destination was kept." }
    }
}

struct KeywordChanges: View {
    let title: String, changes: [KeywordChange]
    var body: some View {
        DisclosureGroup("\(title) · \(changes.count)") {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(changes) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.label).font(.sbHeadline)
                            Text("Now: \(row.before)"); Text("After: \(row.after)")
                        }.font(.sbCallout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        StorebenchDivider()
                    }
                }
            }.frame(maxHeight: 260)
        }
    }
}



struct KeywordRows: View {
    let rows: [KeywordIdea]
    @Binding var chosen: Set<String>
    let picker: Bool
    var changed: Set<String> = []
    var edit: ((KeywordIdea) -> Void)? = nil
    var body: some View {
        if rows.isEmpty { Text(picker ? "No saved Ready to try ideas match this language and territory." : "No ideas match. Add an idea or change the filters.").foregroundStyle(StorebenchTheme.muted) }
        else {
            StorebenchTableFrame {
                StorebenchResizableTableViewport(key: picker ? "keyword-picker" : "keyword-notebook", minimum: picker ? [64, 180, 250] : [64, 180, 140, 170, 250, 116], weights: [], height: min(picker ? 230 : 600, DataTablePresentation.headerHeight + Double(rows.count) * DataTablePresentation.rowHeight), fixed: picker ? [0] : [0, 5]) { widths, resize in
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                            Section {
                                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                    StorebenchTableRow(index: index) {
                                        Toggle(isOn: Binding(get: { chosen.contains(row.id) }, set: { if $0 { chosen.insert(row.id) } else { chosen.remove(row.id) } })) { Text(picker ? "Use" : "Select") }
                                            .toggleStyle(StorebenchToggleStyle()).labelsHidden()
                                            .accessibilityLabel("\(picker ? "Use" : "Select") \(row.term) · \(row.territory.isEmpty ? "any territory" : row.territory)")
                                            .frame(height: 42).padding(.horizontal, 12).frame(width: widths[0])
                                        StorebenchTableCell(text: picker ? "\(row.term)\n\(row.territory.isEmpty ? "Any territory" : row.territory)" : row.term, width: widths[1], lines: picker ? 3 : 4)
                                        if !picker {
                                            StorebenchTableCell(text: "\(row.locale)\n\(row.territory.isEmpty ? "Any territory" : row.territory)", width: widths[2], lines: 4)
                                            StorebenchTableCell(text: "\(KeywordIdea.statuses.first { $0.0 == row.status }?.1 ?? row.status)\n\(changed.contains(row.id) ? "Unsaved change" : "Saved idea")", width: widths[3], lines: 4)
                                        }
                                        StorebenchTableCell(text: "\(KeywordIdea.sources.first { $0.0 == row.source }?.1 ?? row.source)\n\(row.observedOn)\n\(row.reference.isEmpty ? "No source reference" : row.reference)\n\(row.notes)", width: widths[picker ? 2 : 4], lines: picker ? 3 : 4)
                                        if !picker {
                                            Group { if let edit { Button("Edit Idea") { edit(row) } } }
                                                .frame(height: 42).padding(.horizontal, 12).frame(width: widths[5])
                                        }
                                    }
                                }
                            } header: {
                                StorebenchTableHeader(columns: Array(zip(picker ? ["Use", "Keyword", "Source"] : ["Select", "Keyword", "Language / territory", "Status", "Evidence", "Edit"], widths)).map { ($0.0, CGFloat($0.1)) }, resize: resize, fixed: picker ? [0] : [0, 5])
                            }
                        }.frame(width: widths.reduce(0, +), alignment: .leading)
                }
            }
        }
    }
}

private struct KeywordIdeaEditor: View {
    let item: KeywordIdea, use: (KeywordIdea) -> Bool
    @State private var draft: KeywordIdea
    @State private var message = ""
    @State private var invalidField = ""
    @State private var evidenceExpanded = false
    @Environment(\.dismiss) private var dismiss
    init(item: KeywordIdea, use: @escaping (KeywordIdea) -> Bool) { self.item = item; self.use = use; _draft = State(initialValue: item) }
    var body: some View {
        StorebenchDialog(title: item.term.isEmpty ? "Add keyword idea" : "Edit keyword idea", wide: true, height: 680, close: { dismiss() }) {
            Text("Keep a candidate word here. Mark it Ready to try to make it available when composing this language's listing keywords.")
                .font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
            StorebenchTextField("Keyword or phrase", text: $draft.term, hint: hint("Keyword or phrase", "One word or phrase, up to 200 characters. Add lists with Add multiple ideas."))
            StorebenchFormGrid() {
                StorebenchPicker("Listing language", selection: $draft.locale, hint: hint("Listing language", "The language whose keywords you want to improve.")) { selectionOptions(StoreLocales.codes) { SelectionOption(StoreLocales.name($0), value: $0) } }
                StorebenchPicker("Idea status", selection: $draft.status, hint: hint("Idea status", "Ready to try → save the shortlist → choose the idea in Localizations.")) { selectionOptions(KeywordIdea.statuses) { SelectionOption($0.1, value: $0.0) } }
            }
            DisclosureGroup("Research details (optional)", isExpanded: $evidenceExpanded) {
                StorebenchFormGrid() {
                    StorebenchPicker("Target territory", selection: $draft.territory, hint: hint("Target territory", "Where you researched this word.")) { SelectionOption("Any market", value: ""); selectionOptions(Territories.alpha3.values.sorted()) { SelectionOption(WorkspaceSession.countryName($0), value: $0) } }
                    StorebenchPicker("Idea source", selection: $draft.source, hint: hint("Idea source", "Where this word came from.")) { selectionOptions(KeywordIdea.sources) { SelectionOption($0.1, value: $0.0) } }
                    StorebenchTextField("Observation date", text: $draft.observedOn, hint: hint("Observation date", "YYYY-MM-DD or YYYYMMDD. Leave empty if unknown."), placeholder: "YYYY-MM-DD")
                    StorebenchTextField("Source reference", text: $draft.reference, hint: hint("Source reference", "Source name, link or citation, up to 500 characters."))
                }
                StorebenchTextArea(title: "Research notes", text: $draft.notes, height: 112, hint: hint("Research notes", "Why could this word help people find your app? Up to 2,000 characters."))
            }
        } actions: {
            StorebenchAdaptiveText(text: message, maximumHeight: 54, color: StorebenchTheme.color("color-danger"))
            StorebenchActionGroup(alignment: .trailing) {
                Button("Cancel") { dismiss() }
                Button(item.term.isEmpty ? "Add to Shortlist" : "Apply Idea Changes") {
                    do {
                        let value = try Keywords.validatedInput(draft)
                        if use(value) { dismiss() }
                        else { invalidField = "Keyword or phrase"; message = "This idea already exists for the same language and territory. Edit that idea instead." }
                    } catch let failure as KeywordInputFailure {
                        invalidField = failure.field; message = failure.field + ": " + failure.message
                        if !["Keyword or phrase", "Listing language", "Idea status"].contains(failure.field) { evidenceExpanded = true }
                    } catch { message = "This idea contains unsupported text. Check the word and research notes." }
                }.buttonStyle(StorebenchButtonStyle(.primary))
            }
            Text("Adds an unsaved idea. Review and Save Shortlist on the page to keep it on this Mac.").font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
        }
        .interactiveDismissDisabled(draft != item).trackUnsavedChanges(draft != item)
    }
    private func hint(_ field: String, _ fallback: String) -> String { invalidField == field ? message : fallback }
}
