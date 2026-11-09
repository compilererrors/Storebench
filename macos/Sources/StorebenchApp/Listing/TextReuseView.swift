import StorebenchCore
import SwiftUI

struct TextReuseView: View {
    let version: Revision.Version, scope: Editing, currentLocale: String, session: WorkspaceSession?
    let hasUnsaved: Bool, changed: () -> Void, onBusy: (Bool) -> Void
    var readiness: (() -> Bool)? = nil
    @State private var source = ""
    @State private var targets = Set<String>()
    @State private var fields: Set<String> = ["whatsNew"]
    @State private var mode: TextReuse.Mode = .empty
    @State private var preview: TextReuse.Preview?
    @State private var receipt: TextReuse.Preview?
    @State private var working = false
    @State private var message = ""
    @State private var active = false
    @State private var operation: Task<Void, Never>?
    @State private var ticket: UUID?

    private var selection: TextReuse.Selection {
        TextReuse.Selection(versionId: version.id, sourceLocale: source, targetLocales: version.localizations.map(\.locale).filter { targets.contains($0) && $0 != source },
                            fields: TextDrafts.versionFields.filter { fields.contains($0) }, mode: mode)
    }

    var body: some View {
        DisclosureGroup("Reuse saved text between languages") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Copy saved version fields into other languages. Text is copied as written; translate it afterward. Empty source fields are skipped.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
                Text(hasUnsaved ? "Save your open text edits before reusing saved text." : "Previewing does not change any drafts.")
                    .font(.sbCallout).foregroundStyle(StorebenchTheme.muted).frame(minHeight: 36, alignment: .topLeading)
                if version.localizations.count < 2 { Text("Add another language to this version to reuse its text.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted) }
                if !hasUnsaved && version.localizations.count >= 2 {
                VStack(alignment: .leading, spacing: 12) {
                    StorebenchFormGrid {
                        StorebenchPicker("Copy saved text from", selection: $source) { selectionOptions(version.localizations) { SelectionOption(StoreLocales.name($0.locale), value: $0.locale) } }
                        StorebenchPicker("Copy mode", selection: $mode) { SelectionOption("Fill empty fields only", value: TextReuse.Mode.empty); SelectionOption("Replace selected fields", value: TextReuse.Mode.replace) }
                    }
                    Text("Destination languages").font(.sbHeadline)
                    StorebenchActionGroup {
                        Button("Select All") { targets = Set(version.localizations.map(\.locale).filter { $0 != source }) }
                        if !targets.isEmpty { Button("Clear") { targets = [] } }
                    }
                    ScrollView { VStack(alignment: .leading) {
                        StorebenchCollection(items: version.localizations.filter { $0.locale != source }, title: { StoreLocales.name($0.locale) }, subtitle: { $0.locale }, empty: "No other languages in this version. Add a language in Localizations first.") { locale in
                            StorebenchToggle(StoreLocales.name(locale.locale), isOn: choice(locale.locale, in: $targets))
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading) }.frame(height: min(160, CGFloat(max(1, version.localizations.count - 1)) * 28))
                    Text("Text fields").font(.sbHeadline)
                    ForEach(TextDrafts.versionFields, id: \.self) { field in StorebenchToggle(TextDrafts.labels[field] ?? field, isOn: choice(field, in: $fields)) }
                    if !targets.isEmpty && !fields.isEmpty { Button(working ? "Checking…" : "Preview Text Reuse") { operation = Task { await run(apply: false) } } }
                }.storebenchWorking(working)
                }
                if let preview {
                    Text("\(preview.changes.count) field changes").font(.sbHeadline)
                    review(preview)
                    Button("Apply Reviewed Text") { operation = Task { await run(apply: true) } }.buttonStyle(StorebenchButtonStyle(.primary)).storebenchWorking(working).storebenchWorking(!(!hasUnsaved && !preview.changes.isEmpty))
                }
                if let receipt { Text("Last text save").font(.sbHeadline); review(receipt) }
                StorebenchFeedback(text: message, height: 36)
            }
        }
        .onAppear {
            active = true
            source = version.localizations.first { $0.locale != currentLocale }?.locale ?? currentLocale
            if currentLocale != source { targets = [currentLocale] }
        }
        .onDisappear { active = false; operation?.cancel() }
        .onChange(of: source) { _, value in targets.remove(value); reset() }
        .onChange(of: targets) { reset() }
        .onChange(of: fields) { reset() }
        .onChange(of: mode) { reset() }
    }

    private func choice(_ value: String, in values: Binding<Set<String>>) -> Binding<Bool> {
        Binding(get: { values.wrappedValue.contains(value) }, set: { if $0 { values.wrappedValue.insert(value) } else { values.wrappedValue.remove(value) } })
    }
    private func reset() { preview = nil; message = "" }
    private func review(_ result: TextReuse.Preview) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                StorebenchCollection(items: result.changes, title: { StoreLocales.name($0.locale) + " · " + (TextDrafts.labels[$0.field] ?? $0.field) }, empty: "No text changes to copy.") { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(StoreLocales.name(item.locale)) · \(TextDrafts.labels[item.field] ?? item.field)").font(.sbHeadline)
                        Text("Saved text").font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
                        Text(item.before.isEmpty ? "Empty" : item.before).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Text("Copied text").font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
                        Text(item.after).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    StorebenchDivider()
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.frame(height: result.changes.isEmpty ? 0 : 240)
    }
    private func run(apply: Bool) async {
        guard active, !Task.isCancelled, let session, !working, !hasUnsaved, readiness?() != false else { return }
        let job = UUID(); ticket = job; working = true; onBusy(true)
        defer { if ticket == job { ticket = nil; working = false; onBusy(false) } }
        do {
            if apply, let preview {
                let saved = try await session.applyTextReuse(accountId: scope.accountId, appId: scope.appId, revisionId: scope.revisionId, selection: selection, fingerprint: preview.fingerprint)
                try Task.checkCancellation(); guard active, ticket == job else { return }; receipt = saved
                self.preview = nil; message = "\(receipt?.changes.count ?? 0) text fields saved on this Mac. Review the wording in each destination language."; changed()
            } else {
                let checked = try await session.previewTextReuse(accountId: scope.accountId, appId: scope.appId, revisionId: scope.revisionId, selection: selection)
                try Task.checkCancellation(); guard active, ticket == job else { return }; preview = checked
                message = preview?.changes.isEmpty == true ? "No fields need copying with these settings." : ""
            }
        } catch {
            guard active, ticket == job, !Task.isCancelled else { return }
            if let failure = error as? TextReuseFailure { message = failure.message; if failure == .stale { preview = nil } }
            else if let failure = error as? DraftFailure { message = failure.message }
            else { message = "Text could not be reused. Try again." }
        }
    }
}
