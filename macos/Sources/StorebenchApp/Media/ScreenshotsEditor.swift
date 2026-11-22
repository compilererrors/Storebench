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
            StorebenchHeader(stackAt: 420) {
                Text("Screenshots").font(.sbHeadline)
            } actions: {
                HStack(spacing: StorebenchTheme.space(2)) {
                    if !scope.local {
                        if let library {
                            StorebenchMenu("Add…", icon: "plus") {
                                Button("From This Mac…") { add(nil, nil) }
                                Button("From Asset Library…") { library() }
                            }.help("Add Screenshots from This Mac or Asset Library").accessibilityLabel("Add Screenshots")
                        } else { Button { add(nil, nil) } label: { StorebenchLabel("Add Screenshots…", icon: "plus", size: 16) } }
                        StorebenchIconMenu(title: "Screenshot Options for This Language") {
                            if !others.isEmpty && model.workflow.shown.ready {
                                StorebenchSubmenu("Copy From Language") {
                                    ForEach(others) { other in Button(StoreLocales.name(other.locale)) { Task { await model.copyScreenshots(from: other.id) } } }
                                }
                                StorebenchMenuSeparator()
                            }
                            Button("Remove All Screenshots", role: .destructive) { model.removeAllScreenshots() }
                                .storebenchWorking(!model.canRemoveScreenshots || !model.screenshots.contains { $0.editor.included > 0 })
                        }
                    }
                }
            }
            Text("PNG or JPEG, up to 10 per display size. Drag files here to add them.")
                .font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
            ForEach(model.screenshotSelections.filter(\.dirty)) { selected in
                PendingScreenshotRow(selected: selected, busy: workflowBusy || model.workflow.busy) { fix(selected) }
            }
            StorebenchCollection(items: model.screenshots, title: { StoreLocales.displayTypeName($0.displayType) }, subtitle: { "\($0.editor.included) of \(ScreenshotSpecs.maximum) screenshots" },
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
            // One line beside the size's options: what is saved and how to reorder, or why the size cannot be saved yet.
            StorebenchHeader(stackAt: 0) {
                StorebenchTextSlot(text: editor.included > ScreenshotSpecs.maximum ? "\(editor.included) of \(ScreenshotSpecs.maximum) included. Remove some before saving."
                                   : editor.dirty ? "Unsaved changes. Save Draft keeps them on this Mac." : "Saved on this Mac. Drag to change the order.",
                                   height: StorebenchTheme.controlHeight, font: .sbCaption,
                                   color: editor.included > ScreenshotSpecs.maximum ? StorebenchTheme.color("color-danger") : editor.dirty ? StorebenchTheme.color("color-accent-strong") : StorebenchTheme.muted, live: true)
                    .storebenchControlID("screenshots.order-status")
            } actions: {
                    if !scope.local {
                        StorebenchIconMenu(title: "Screenshot Order Options · " + StoreLocales.displayTypeName(entry.displayType)) {
                            Button("Revert Order and Selection") { if !reorder.active { editor.revert() } }.storebenchWorking(!editor.dirty || editor.saving || reorder.active)
                            StorebenchMenuSeparator()
                            Button("Remove All in This Display Size", role: .destructive) { if !reorder.active { editor.removeAllScreenshots() } }
                                .storebenchWorking(!editor.canEditScreenshots || editor.included == 0 || reorder.active)
                        }.storebenchControlID("screenshots.order-options." + entry.displayType)
                    }
            }
            if let draft, !editor.includedOrder.isEmpty {
                StorebenchMetricGrid(maximumColumns: 4, minimumWidth: 260, spacing: StorebenchTheme.measure("assetGridGap")) {
                    ForEach(Array(editor.includedOrder.enumerated()), id: \.element) { index, id in
                        if let item = draft.items.first(where: { $0.id == id }) {
                            StorebenchAssetCard(title: item.fileName, metadata: metadata(item), status: "", position: index + 1, compact: true,
                                                drag: canReorder ? MaterialDrag(id: id, title: item.fileName, context: editor.reorderContext, order: inputs.order, enabled: true, session: reorder, activate: { enlarge(id) }) : nil) {
                                StorebenchMediaButton(title: "Enlarge " + item.fileName, help: "Click to Select; Double-Click to Open " + item.fileName, action: { if session != nil { enlarge(id) } }) {
                                    ScreenshotThumbnail(screenshot: item, session: session, canvasHeight: StorebenchTheme.measure("assetPreviewHeight") - 2 * StorebenchTheme.measure("assetPreviewPadding"), canvasColor: .clear)
                                }
                                    .materialDragSource(id: id, title: item.fileName, order: inputs.order, context: editor.reorderContext, enabled: canReorder, session: reorder, activate: { enlarge(id) })
                            } actions: {
                                if scope.local {
                                    if session != nil { Button { enlarge(id) } label: { StorebenchLabel("View Screenshot", icon: "screenshots", size: 16) }
                                        .buttonStyle(StorebenchButtonStyle(.quiet, stretch: true)) }
                                } else {
                                    StorebenchMaterialToolbar()
                                }
                            }
                            .materialReorderCard(id: id, title: item.fileName, order: inputs.order, visibleOrder: editor.includedOrder,
                                context: editor.reorderContext, enabled: canReorder, session: reorder, apply: changeOrder,
                                open: session == nil ? nil : { enlarge(id) }, remove: editor.canEditScreenshots ? { editor.removeScreenshot(id) } : nil)
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
    private func changeOrder(_ next: [String], expected: [String], context: String) -> Bool { guard canReorder else { return false }; return editor.reorder(next, expected: expected, context: context) }

}
