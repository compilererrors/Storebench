import StorebenchCore
import SwiftUI

struct ScreenshotsEditor: View {
    let scope: Editing, model: MediaListingEditor, others: [Revision.Localization], session: WorkspaceSession?
    let add: (String?, String?) -> Void
    let drop: ([URL], String?, String?) -> Bool
    let fix: (PendingScreenshotSelection) -> Void
    /// Opens Add from Asset Library: files saved on this Mac, including Create Media cards, and files already at Apple.
    var library: (() -> Void)? = nil
    @Environment(\.draftWorkflowBusy) private var workflowBusy
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StorebenchHeader {
                Text("Screenshots").font(.sbHeadline)
            } actions: {
                StorebenchActionGroup(alignment: .trailing) {
                    if !scope.local {
                        if model.screenshots.count > 1 {
                            Button("Remove All") { model.removeAllScreenshots() }
                                .buttonStyle(StorebenchButtonStyle(.danger))
                                .help("Remove all screenshots from every display size in this language. Originals are kept.")
                                .accessibilityLabel("Remove All Screenshots in This Language")
                                .storebenchWorking(!model.canRemoveScreenshots || !model.screenshots.contains { $0.editor.included > 0 })
                        }
                        if !others.isEmpty && model.workflow.ready {
                            StorebenchMenu("Copy From Language", icon: "copy") {
                                ForEach(others) { other in Button(StoreLocales.name(other.locale)) { Task { await model.copyScreenshots(from: other.id) } } }
                            }
                        }
                        if let library {
                            StorebenchMenu("Add…", icon: "plus") {
                                Button("From This Mac…") { add(nil, nil) }
                                Button("From Asset Library…") { library() }
                            }.help("Add Screenshots from This Mac or Asset Library").accessibilityLabel("Add Screenshots")
                        } else { Button { add(nil, nil) } label: { StorebenchLabel("Add Screenshots…", icon: "plus", size: 16) } }
                    }
                }
            }
            Text("Add PNG or JPEG files from this Mac or Asset Library, or drag them here. Up to 10 per display size. Removed screenshots can be restored.")
                .font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
            ForEach(model.screenshotSelections.filter(\.dirty)) { selected in
                PendingScreenshotRow(selected: selected, busy: workflowBusy || model.workflow.busy) { fix(selected) }
            }
            StorebenchCollection(items: model.screenshots, title: { StoreLocales.displayTypeName($0.displayType) }, subtitle: { "\($0.editor.included) included screenshots" },
                                 empty: "No screenshots yet. Choose Add Screenshots or drop PNG or JPEG files here.") { entry in
                ScreenshotSetEditor(scope: scope, entry: entry, model: model, workflow: model.workflow, session: session, add: { add(entry.id, entry.displayType) }, drop: { drop($0, entry.id, entry.displayType) })
            }
        }.padding(16).background(StorebenchTheme.color("color-surface-subtle"), in: RoundedRectangle(cornerRadius: StorebenchTheme.radius))
            .overlay(RoundedRectangle(cornerRadius: StorebenchTheme.radius).strokeBorder(StorebenchTheme.border))
            .accessibilityElement(children: .contain).storebenchWorking(workflowBusy || model.busy)
    }
}

/// Files being added, or files that could not be saved, stay in the Screenshots section with their next step.
private struct PendingScreenshotRow: View {
    let selected: PendingScreenshotSelection, busy: Bool
    let fix: () -> Void
    private var files: String {
        guard let count = selected.selection?.items.count else { return "The chosen screenshots" }
        return count == 1 ? "1 screenshot" : "\(count) screenshots"
    }
    var body: some View {
        Group {
            if selected.busy {
                StorebenchAddingRow {
                    if selected.reading, let progress = selected.readProgress {
                        ProgressView(value: progress.fraction, total: 1) { Text("Adding screenshots · reading \(progress.completedFiles) of \(progress.totalFiles)…") }
                    } else { ProgressView(selected.saving ? "Saving \(files) on this Mac…" : "Adding screenshots…") }
                }
            } else {
                StorebenchNotSavedRow(title: "\(files) not added", reason: selected.problem ?? (selected.status.isEmpty ? "These files are not saved yet. Try again, or discard them." : selected.status),
                                      next: selected.problem != nil ? "Fix Images…" : "Try Again", retry: { if selected.problem != nil { fix() } else { Task { _ = await selected.add() } } }, discard: { selected.clear() })
            }
        }.storebenchWorking(busy)
    }
}

struct ScreenshotSetEditor: View {
    let scope: Editing, entry: MediaListingEditor.ScreenshotLayout, model: MediaListingEditor, workflow: ListingSaveWorkflow, session: WorkspaceSession?
    let add: () -> Void
    let drop: ([URL]) -> Bool
    @State private var gallery: ScreenshotGalleryRequest?
    @State private var reorder = MaterialReorder()
    @State private var showRemoved = false
    @Environment(\.editingPreferences) private var preferences
    @Environment(\.draftWorkflowBusy) private var workflowBusy
    private var editor: MediaLayoutEditor { entry.editor }
    private var draft: ScreenshotSetDraft? { if case .screenshots(let value)? = editor.draft { value } else { nil } }
    private var inputs: MediaDraftInputs { editor.inputs }
    private var canReorder: Bool { !scope.local && !editor.state.blocked && !workflowBusy && !workflow.busy }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            StorebenchHeader {
                VStack(alignment: .leading, spacing: StorebenchTheme.space(1)) {
                    StorebenchTextSlot(text: "Screenshot order", height: StorebenchTheme.measure("sectionTitle"), font: .sbHeadline)
                    StorebenchTextSlot(text: "\(editor.included) of \(ScreenshotSpecs.maximum) included", height: StorebenchTheme.measure("fieldLabel"), font: .sbCaption, color: editor.included > ScreenshotSpecs.maximum ? StorebenchTheme.color("color-danger") : StorebenchTheme.muted)
                }
            } actions: {
                VStack(alignment: .trailing, spacing: StorebenchTheme.space(2)) {
                StorebenchActionGroup(alignment: .trailing) {
                    if !scope.local {
                        Button("Remove All") { if !reorder.active { editor.removeAllScreenshots() } }
                            .buttonStyle(StorebenchButtonStyle(.danger))
                            .help("Remove all screenshots from this display size. Originals are kept.")
                            .accessibilityLabel("Remove All " + StoreLocales.displayTypeName(entry.displayType) + " Screenshots")
                            .storebenchWorking(!editor.canEditScreenshots || editor.included == 0 || reorder.active)
                        if editor.dirty && !editor.saving { Button("Revert") { editor.revert() } }
                    }
                }
                }
            }
            StorebenchTextSlot(text: editor.dirty ? "Unsaved changes · Save Draft keeps additions, removals and order on this Mac. Sync to Apple prepares a separate review."
                             : "Saved on this Mac · Drag to change the order. Sync to Apple reviews the saved changes before sending them.", height: 40, font: .sbCaption, color: editor.dirty ? StorebenchTheme.color("color-accent-muted") : StorebenchTheme.muted, live: true)
            if let draft, !editor.includedOrder.isEmpty {
                StorebenchMetricGrid(maximumColumns: 4, minimumWidth: 260, spacing: StorebenchTheme.measure("assetGridGap")) {
                    ForEach(Array(editor.includedOrder.enumerated()), id: \.element) { index, id in
                        if let item = draft.items.first(where: { $0.id == id }) {
                            StorebenchAssetCard(title: item.fileName, metadata: metadata(item), status: "", position: index + 1, compact: true,
                                                drag: canReorder ? MaterialDrag(id: id, title: item.fileName, context: editor.reorderContext, order: inputs.order, enabled: true, session: reorder, activate: { enlarge(id) }) : nil) {
                                Button { if session != nil { enlarge(id) } } label: {
                                    ScreenshotThumbnail(screenshot: item, session: session, canvasHeight: StorebenchTheme.measure("assetPreviewHeight") - 2 * StorebenchTheme.measure("assetPreviewPadding"), canvasColor: .clear)
                                        .overlay(StorebenchControlOutline(border: .clear))
                                }.buttonStyle(StorebenchPressStyle())
                                    .help("Enlarge " + item.fileName).accessibilityLabel("Enlarge " + item.fileName)
                                    .materialDragSource(id: id, title: item.fileName, order: inputs.order, context: editor.reorderContext, enabled: canReorder && inputs.order.count > 1, session: reorder, activate: { enlarge(id) })
                            } actions: {
                                if scope.local {
                                    if session != nil { Button { enlarge(id) } label: { StorebenchLabel("View Screenshot", icon: "screenshots", size: 16) }
                                        .buttonStyle(StorebenchButtonStyle(.quiet, stretch: true)) }
                                } else {
                                    HStack(spacing: StorebenchTheme.space(2)) {
                                        StorebenchReorderHandle(id: id, title: item.fileName, context: editor.reorderContext, order: inputs.order, enabled: canReorder, session: reorder, apply: changeOrder)
                                        Button { move(id, by: -1) } label: { StorebenchIcon(name: "up", size: 16) }
                                            .buttonStyle(StorebenchButtonStyle(.quiet, size: .icon)).opacity(index == 0 ? 0 : 1).allowsHitTesting(index > 0).accessibilityHidden(index == 0).storebenchWorking(reorder.active)
                                            .help("Move earlier").accessibilityLabel("Move " + item.fileName + " earlier")
                                        Button { move(id, by: 1) } label: { StorebenchIcon(name: "down", size: 16) }
                                            .buttonStyle(StorebenchButtonStyle(.quiet, size: .icon)).opacity(index == editor.includedOrder.count - 1 ? 0 : 1).allowsHitTesting(index < editor.includedOrder.count - 1).accessibilityHidden(index == editor.includedOrder.count - 1).storebenchWorking(reorder.active)
                                            .help("Move later").accessibilityLabel("Move " + item.fileName + " later")
                                        Spacer(minLength: StorebenchTheme.space(2))
                                        Button { if !reorder.active { editor.removeScreenshot(id) } } label: { StorebenchIcon(name: "close", size: 16) }
                                            .buttonStyle(StorebenchButtonStyle(.danger, size: .icon)).storebenchWorking(reorder.active || !editor.canEditScreenshots)
                                            .help("Remove from this version. The original is kept and can be restored.")
                                            .accessibilityLabel("Remove " + item.fileName + " from this version")
                                    }
                                }
                            }
                            .materialDropTarget(id: id, session: reorder)
                        }
                    }
                }
                .materialDropArea(order: inputs.order, context: editor.reorderContext, enabled: canReorder, session: reorder, apply: changeOrder)
            } else if draft != nil { Text("No screenshots for this size yet.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted) }
            if !scope.local && !editor.removedOrder.isEmpty {
                StorebenchDisclosureButton(isExpanded: $showRemoved) {
                    Text("Removed Screenshots (\(editor.removedOrder.count))").font(.sbCallout)
                }
                if showRemoved, let draft {
                    Text("Removed from this version. Originals are kept; Restore adds one back to this display size.")
                        .font(.sbCaption).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
                    ForEach(editor.removedOrder, id: \.self) { id in
                        if let item = draft.items.first(where: { $0.id == id }) {
                            StorebenchStatusRow(title: item.fileName, detail: metadata(item)) {
                                Text("Removed").font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
                            } action: {
                                Button("Restore") { if !reorder.active { editor.restoreScreenshot(id) } }
                                    .help("Restore " + item.fileName + " to this version")
                                    .accessibilityLabel("Restore " + item.fileName)
                                    .storebenchWorking(!editor.canEditScreenshots || editor.included >= ScreenshotSpecs.maximum || reorder.active)
                            } details: {}
                        }
                    }
                }
            }
            StorebenchReorderFeedback(session: reorder)
            if !scope.local { MediaLayoutReview(editor: editor, workflow: workflow) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .storebenchWorking(editor.busy || workflowBusy)
        .dropDestination(for: URL.self) { urls, _ in !scope.local && !editor.busy && !workflowBusy && drop(urls) }
        .autosaveDraft(editor.autosave, identity: editor.identity, signature: inputs.signature, enabled: preferences?.autosaveDrafts == true,
                       dirty: editor.dirty, blocked: editor.state.blocked || scope.local || reorder.active) { if workflow.busy { return false }; return await editor.save(automatic: true) }
        .onChange(of: workflowBusy) { if workflowBusy { reorder.cancel() } }
        .onChange(of: workflow.busy) { if workflow.busy { reorder.cancel() } }
        .onDisappear { reorder.cancel() }
        .sheet(item: $gallery) { request in
            if let session { SavedScreenshotGallery(request: request, scope: scope, setId: entry.id, session: session, close: { gallery = nil }) }
        }
    }
    private func metadata(_ item: ScreenshotSetDraft.Item) -> String {
        let dimensions = item.width.flatMap { width in item.height.map { "\(width) × \($0) px" } } ?? "Dimensions unavailable"
        return dimensions + " · " + (item.local ? "On This Mac" : "Saved Original")
    }
    private func enlarge(_ id: String) {
        guard let draft, session != nil else { return }
        gallery = ScreenshotGalleryRequest(items: inputs.order.compactMap { selected in draft.items.first { $0.id == selected } }, initialId: id)
    }
    private func move(_ id: String, by amount: Int) {
        let visible = editor.includedOrder
        guard canReorder, let index = visible.firstIndex(of: id), visible.indices.contains(index + amount),
              let target = inputs.order.firstIndex(of: visible[index + amount]),
              let next = MaterialReorder.moving(inputs.order, source: id, to: target) else { return }
        _ = changeOrder(next, expected: inputs.order, context: editor.reorderContext)
    }
    private func changeOrder(_ next: [String], expected: [String], context: String) -> Bool { guard canReorder else { return false }; return editor.reorder(next, expected: expected, context: context) }

}
