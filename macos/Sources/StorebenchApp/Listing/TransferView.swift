import AppKit
import StorebenchCore
import SwiftUI
import UniformTypeIdentifiers

/// Export workspace data to CSV or JSON and import it back after a preview. Imports change only drafts on this Mac.
struct TransferView: View {
    let account: Account, app: Account.App, session: WorkspaceSession?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            TransferCard(account: account, app: app, session: session, kind: .languages, title: "Language text",
                         subtitle: "Every language's version and app information text. Importing adds missing languages and saves the text as drafts.")
            FastlaneMetadataCard(account: account, app: app, session: session)
            TransferCard(account: account, app: app, session: session, kind: .screenshots, title: "Screenshot order",
                         subtitle: "Position and selection of screenshots per language and display size. Images themselves are not part of the file.")
            TransferCard(account: account, app: app, session: session, kind: .prices, title: "Country prices",
                         subtitle: "Country price drafts, or Apple's current prices as a starting point. Protected countries cannot be imported.")
            TransferCard(account: account, app: app, session: session, kind: .release, title: "Version setup",
                         subtitle: "The release plan: starting version, new version number and release method.")
        }
    }
}

struct TransferCard: View {
    let account: Account, app: Account.App, session: WorkspaceSession?, kind: TransferKind, title: String, subtitle: String
    /// Runs after an import was saved, so a screen showing the same data reads it again.
    var onImported: (() async -> Void)? = nil
    @State private var model: TransferEditor?
    @State private var operation: Task<Void, Never>?
    @State private var protectionId = UUID().uuidString
    @Environment(\.editorProtection) private var protection

    var body: some View {
        Card(title: title, subtitle: subtitle) {
            if let model { content(model) }
            else { Text("Connect the workspace to import or export saved data.").foregroundStyle(StorebenchTheme.muted) }
        }
        .task {
            guard model == nil, let session, !Task.isCancelled, let owner = try? TransferEditor(account: account, appId: app.id, kind: kind, session: session) else { return }
            let id = UUID().uuidString; protectionId = id
            owner.didChange = { [weak owner, weak editingProtection = protection] in
                guard let owner, owner.active || owner.busy else { editingProtection?.policy.remove(id: id); return }
                editingProtection?.policy.update(id: id, dirty: owner.active && owner.dirty, busy: owner.busy)
            }
            model = owner
        }
        .onDisappear {
            let owner = model; operation?.cancel(); owner?.retire()
            if owner?.busy != true { protection?.policy.remove(id: protectionId) }
            model = nil
        }
    }
    private func content(_ model: TransferEditor) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 16) {
            StorebenchChoicePicker("Export format", selection: Binding(get: { model.format }, set: { model.setFormat($0) }), options: [(TransferFormat.csv, "CSV"), (TransferFormat.json, "JSON")]).storebenchFormColumn().storebenchWorking(!model.ready)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { exportButtons(model); importButton(model) }
                VStack(alignment: .trailing, spacing: 12) { exportButtons(model); StorebenchActionGroup { importButton(model) } }
            }
            StorebenchTextSlot(text: model.status, height: 64, font: .sbCallout, color: StorebenchTheme.muted, live: true)
            if let preview = model.preview {
                ImportChangesReview(title: "Unsaved import · \(preview.changes.count) changes from \(preview.totalRows) rows\(preview.added > 0 ? " · \(preview.added) new languages" : "")", preview: preview, savedAt: nil)
                if preview.changes.isEmpty { Text("The file matches the saved data. There is nothing to import.").foregroundStyle(StorebenchTheme.muted) }
                StorebenchFormFooter {
                    Button("Cancel Import Review") { model.discardPreview() }.storebenchWorking(!model.ready)
                    if model.busy || model.dirty && !model.saveBlocked {
                        Button(model.busy ? "Working…" : "Import Changes") { if model.canSave { operation = Task { if await model.apply() { await onImported?() } } } }.help(model.busy ? "Working…" : "Import Reviewed Changes").accessibilityLabel(model.busy ? "Working…" : "Import Reviewed Changes")
                            .buttonStyle(StorebenchButtonStyle(.primary)).storebenchWorking(!model.ready)
                    }
                }
                if model.saveBlocked {
                    Text("Read the latest saved values and preview this file again. Review the new comparisons before importing.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
                    Button("Preview Again") { operation = Task { _ = await model.recheck() } }.help("Preview This File Again").accessibilityLabel("Preview This File Again").storebenchWorking(!model.ready)
                }
            }
            if let receipt = model.lastSave {
                ImportChangesReview(title: "Last saved import · \(receipt.preview.changes.count) changes", preview: receipt.preview, savedAt: receipt.confirmedAt)
            }
            StorebenchActionGroup { Button("Read Saved Data") { operation = Task { _ = await model.readSavedData() } }.help("Read Current Saved Data").accessibilityLabel("Read Current Saved Data").storebenchWorking(!model.ready) }
            if let table = model.savedData { TransferSavedData(table: table) }
        })
    }
    private func exportButtons(_ model: TransferEditor) -> some View {
        StorebenchActionGroup(alignment: .trailing) {
            Button("Export…") { export(model, template: false, apple: false) }
            if kind == .prices { Button("Export Apple Prices…") { export(model, template: false, apple: true) } }
            Button("Template…") { export(model, template: true, apple: false) }
        }.storebenchWorking(!model.ready)
    }
    private func importButton(_ model: TransferEditor) -> some View {
        Button(model.busy ? "Working…" : "Import…") {
            guard model.ready else { return }
            if model.dirty {
                guard EditorProtection.confirm(.confirmDiscard), model.ready else { return }
                model.discardPreview()
            }
            operation = Task { _ = await model.choose(read: {
                let panel = NSOpenPanel(); panel.allowedContentTypes = [.commaSeparatedText, .json, .plainText]; panel.allowsMultipleSelection = false
                guard panel.runModal() == .OK, let url = panel.url, model.active, !Task.isCancelled else { return nil }
                let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let files = try await SelectedFiles.readAsync([url], purpose: .transfer)
                guard let file = files.first else { throw SelectedFiles.Failure.read }
                return .init(data: file.data, format: url.pathExtension.lowercased() == "json" ? .json : .csv)
            }) }
        }.storebenchWorking(!model.ready)
    }
    private func export(_ model: TransferEditor, template: Bool, apple: Bool) {
        operation = Task { _ = await model.export(template: template, apple: apple, write: { text, format in
            let panel = NSSavePanel(); panel.allowedContentTypes = [format == .csv ? .commaSeparatedText : .json]
            panel.nameFieldStringValue = "storebench-\(kind.rawValue)-\(app.id)\(template ? "-template" : "").\(format.rawValue)"
            guard panel.runModal() == .OK, let url = panel.url, model.active, !Task.isCancelled, let session else { return false }
            try session.validateAccess()
            let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            try text.write(to: url, atomically: true, encoding: .utf8); return true
        }) }
    }
}

private struct ImportChangesReview: View {
    let title: String, preview: TransferPreview, savedAt: String?
    @State private var page = 1
    @State private var expanded: [String: Bool] = [:]
    private var selection: TransferReviewPage { .init(changes: preview.changes, page: page) }
    var body: some View {
        DisclosureGroup(title) {
            VStack(alignment: .leading, spacing: 12) {
                Text(preview.saved ? "Confirmed\(savedAt.map { " · \(LibraryOverview.timestamp($0))" } ?? ""). This comparison records that save; later edits may differ." : "Compare the saved and imported values. These changes have not been saved.")
                    .font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        StorebenchCollection(items: selection.changes, title: { $0.label }, empty: "No changes in this selection.") { change in
                            DisclosureGroup(change.label, isExpanded: Binding(get: { expanded[change.id] ?? (preview.changes.count <= 3) }, set: { expanded[change.id] = $0 })) {
                                ImportComparisonText(label: preview.saved ? "Before saving" : "Saved value", value: change.before)
                                ImportComparisonText(label: preview.saved ? "Saved value" : "Unsaved value", value: change.after)
                            }.font(.sbCallout)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 420)
                HStack(spacing: 12) {
                    if selection.current > 1 { Button("Previous") { page = max(1, selection.current - 1) } }
                    Text("Page \(selection.current) of \(selection.pages)").font(.sbCaption).frame(minWidth: 110)
                    if selection.current < selection.pages { Button("Next") { page = min(selection.pages, selection.current + 1) } }
                }
            }
        }
    }
}
private struct ImportComparisonText: View {
    let label: String, value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.sbCaption.weight(.semibold)).foregroundStyle(StorebenchTheme.muted)
            StorebenchTextSlot(text: value.isEmpty ? "Empty" : value, height: 160, font: .sbCallout, color: nil)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
private struct TransferSavedData: View {
    let table: Delimited.Table
    var body: some View {
        DisclosureGroup("Current saved data · \(table.rows.count) rows") {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    StorebenchCollection(items: table.rows.enumerated().map { StorebenchCollectionEntry(id: String($0.offset), value: ($0.offset, $0.element)) }, title: { "Row \($0.value.0 + 1)" }, empty: "No saved rows.") { entry in
                        let (index, row) = entry.value
                        DisclosureGroup("Row \(index + 1)") {
                            ForEach(Array(table.columns.enumerated()), id: \.offset) { column, label in
                                ImportComparisonText(label: label, value: row.indices.contains(column) ? row[column] : "Unknown")
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 420)
        }
    }
}
