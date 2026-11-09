import StorebenchCore
import SwiftUI

struct PreviewsEditor: View {
    let scope: Editing, model: MediaListingEditor, others: [Revision.Localization], session: WorkspaceSession?
    let add: (String) -> Void
    @Environment(\.draftWorkflowBusy) private var workflowBusy
    private var shown: [MediaListingEditor.PreviewLayout] {
        model.previews.filter { entry in
            guard case .previews(_, _, let draft)? = entry.editor.draft else { return true }
            return !draft.items.isEmpty || entry.editor.dirty || entry.editor.needsComparison || model.previewSelections.contains { $0.pending && $0.type == entry.type }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StorebenchHeader {
                Text("App Previews").font(.sbHeadline)
            } actions: {
                StorebenchActionGroup(alignment: .trailing) {
                    if !scope.local {
                        if !others.isEmpty && model.workflow.ready {
                            StorebenchMenu("Copy From Language", icon: "copy") {
                                ForEach(others) { other in Button(StoreLocales.name(other.locale)) { Task { await model.copyPreviews(from: other.id) } } }
                            }
                        }
                        StorebenchMenu("Add Preview…", icon: "plus") {
                            ForEach(PreviewSpecs.types(platform: model.platform), id: \.self) { type in
                                Button("\(PreviewSpecs.name(type)) · \(PreviewSpecs.dimensions(type))") { add(type) }
                            }
                        }
                    }
                }
            }
            Text("15–30 seconds, up to 30 frames per second, H.264 or ProRes 422 HQ. Up to 3 per size. Added videos are saved on this Mac right away.")
                .font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
            ForEach(model.previewSelections.filter(\.pending)) { selected in
                PendingPreviewRow(selected: selected, busy: workflowBusy || model.workflow.busy)
            }
            StorebenchCollection(items: shown, title: { PreviewSpecs.name($0.type) }, subtitle: { PreviewSpecs.dimensions($0.type) },
                                 empty: "No app previews yet. Choose Add Preview to add a video.") { entry in PreviewSetEditor(scope: scope, localizationId: model.localizationId, entry: entry, model: model, workflow: model.workflow, session: session) }
        }.padding(16).background(StorebenchTheme.color("color-surface-subtle"), in: RoundedRectangle(cornerRadius: StorebenchTheme.radius))
            .overlay(RoundedRectangle(cornerRadius: StorebenchTheme.radius).strokeBorder(StorebenchTheme.border))
            .accessibilityElement(children: .contain).storebenchWorking(workflowBusy || model.busy)
    }
}

struct PreviewSetEditor: View {
    let scope: Editing, localizationId: String, entry: MediaListingEditor.PreviewLayout, model: MediaListingEditor, workflow: ListingSaveWorkflow, session: WorkspaceSession?
    @Environment(\.editingPreferences) private var preferences
    @Environment(\.draftWorkflowBusy) private var workflowBusy
    @State private var reorder = MaterialReorder()
    private var editor: MediaLayoutEditor { entry.editor }
    private var draft: PreviewSetDraft? { if case .previews(_, _, let value)? = editor.draft { value } else { nil } }
    private var inputs: MediaDraftInputs { editor.inputs }
    private var canReorder: Bool { !scope.local && !editor.state.blocked && !workflowBusy && !workflow.busy }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            StorebenchHeader {
                VStack(alignment: .leading, spacing: StorebenchTheme.space(1)) {
                    StorebenchTextSlot(text: "Preview order", height: StorebenchTheme.measure("sectionTitle"), font: .sbHeadline)
                    StorebenchTextSlot(text: "\(editor.included) of \(PreviewSpecs.maximum) included", height: StorebenchTheme.measure("fieldLabel"), font: .sbCaption, color: StorebenchTheme.muted)
                }
            } actions: {
                if !scope.local {
                    StorebenchActionGroup(alignment: .trailing) {
                        if editor.dirty && !editor.saving { Button("Revert") { editor.revert() } }
                    }
                }
            }
            StorebenchTextSlot(text: editor.dirty ? "Unsaved preview changes · Save Draft keeps them on this Mac. Sync to Apple opens a review." : "Saved layout · Drag a video by its name or handle to change its position. Playback and poster controls remain available.", height: 40, font: .sbCaption, color: editor.dirty ? StorebenchTheme.color("color-accent-muted") : StorebenchTheme.muted, live: true)
            StorebenchMetricGrid(maximumColumns: 3, minimumWidth: 360, spacing: StorebenchTheme.measure("assetGridGap")) {
                ForEach(Array(inputs.order.enumerated()), id: \.element) { index, id in
                    if let item = draft?.items.first(where: { $0.id == id }) {
                        let excluded = inputs.hidden.contains(id)
                        StorebenchAssetCard(title: item.fileName, metadata: "\(item.width) × \(item.height) px · \(item.duration.formatted(.number.precision(.fractionLength(1)))) s", status: scope.local ? "Saved video" : excluded ? "Excluded" : "Included", position: index + 1, excluded: excluded, previewHeight: StorebenchTheme.measure("assetPreviewHeight") + StorebenchTheme.controlHeight + 34 + 16,
                                            drag: canReorder ? MaterialDrag(id: id, title: item.fileName, context: editor.reorderContext, order: inputs.order, enabled: true, session: reorder) : nil) {
                            SavedPreviewPlayer(scope: scope, localizationId: localizationId, type: entry.type, item: item, posterTime: inputs.posterTimes[id, default: 5], session: session, canvasHeight: StorebenchTheme.measure("assetPreviewHeight") - 2 * StorebenchTheme.measure("assetPreviewPadding"))
                        } actions: {
                            VStack(alignment: .leading, spacing: StorebenchTheme.space(3)) {
                                if !scope.local {
                                    HStack(spacing: StorebenchTheme.space(2)) {
                                        StorebenchToggle("Include", isOn: Binding(get: { !editor.inputs.hidden.contains(id) }, set: { if $0 { editor.inputs.hidden.remove(id) } else { editor.inputs.hidden.insert(id) } }))
                                            .accessibilityLabel("Include " + item.fileName)
                                            .storebenchWorking(reorder.active)
                                        StorebenchReorderHandle(id: id, title: item.fileName, context: editor.reorderContext, order: inputs.order, enabled: canReorder, session: reorder, apply: changeOrder)
                                        Button { move(id, by: -1) } label: { StorebenchIcon(name: "up", size: 16) }.buttonStyle(StorebenchButtonStyle(.quiet, size: .icon))
                                            .opacity(index == 0 ? 0 : 1).allowsHitTesting(index > 0).accessibilityHidden(index == 0).storebenchWorking(reorder.active).help("Move earlier").accessibilityLabel("Move " + item.fileName + " earlier")
                                        Button { move(id, by: 1) } label: { StorebenchIcon(name: "down", size: 16) }.buttonStyle(StorebenchButtonStyle(.quiet, size: .icon))
                                            .opacity(index == inputs.order.count - 1 ? 0 : 1).allowsHitTesting(index < inputs.order.count - 1).accessibilityHidden(index == inputs.order.count - 1).storebenchWorking(reorder.active).help("Move later").accessibilityLabel("Move " + item.fileName + " later")
                                    }
                                    StorebenchTextField("Poster frame (seconds)", value: Binding(get: { editor.inputs.posterTimes[id, default: 5] }, set: { editor.inputs.posterTimes[id] = MediaReadPolicy.poster($0, duration: item.duration) }), format: .number.precision(.fractionLength(2)))
                                        .environment(\.fieldHintHeight, 0).accessibilityLabel("Poster frame for " + item.fileName + " in seconds")
                                    StorebenchStepper("Adjust by 0.01 s", value: Binding(get: { editor.inputs.posterTimes[id, default: 5] }, set: { editor.inputs.posterTimes[id] = $0 }), in: 0...MediaReadPolicy.posterMaximum(duration: item.duration), step: 0.01)
                                        .accessibilityLabel("Adjust poster frame for " + item.fileName)
                                } else { Text("Saved preview · original available above").font(.sbCaption).foregroundStyle(StorebenchTheme.muted) }
                            }
                        }
                        .materialDropTarget(id: id, session: reorder)
                    }
                }
            }
            .materialDropArea(order: inputs.order, context: editor.reorderContext, enabled: canReorder, session: reorder, apply: changeOrder)
            StorebenchReorderFeedback(session: reorder)
            if !scope.local { MediaLayoutReview(editor: editor, workflow: workflow) }
        }
        .padding(16).background(StorebenchTheme.color("color-surface-subtle"), in: RoundedRectangle(cornerRadius: StorebenchTheme.radius))
        .storebenchWorking(editor.busy || workflowBusy)
        .autosaveDraft(editor.autosave, identity: editor.identity, signature: inputs.signature, enabled: preferences?.autosaveDrafts == true,
                       dirty: editor.dirty, blocked: editor.state.blocked || scope.local || reorder.active) { if workflow.busy { return false }; return await editor.save(automatic: true) }
        .onChange(of: workflowBusy) { if workflowBusy { reorder.cancel() } }
        .onChange(of: workflow.busy) { if workflow.busy { reorder.cancel() } }
        .onDisappear { reorder.cancel() }
    }
    private func move(_ id: String, by amount: Int) {
        guard canReorder, let index = inputs.order.firstIndex(of: id), let next = MaterialReorder.moving(inputs.order, source: id, to: index + amount) else { return }
        _ = changeOrder(next, expected: inputs.order, context: editor.reorderContext)
    }
    private func changeOrder(_ next: [String], expected: [String], context: String) -> Bool { guard canReorder else { return false }; return editor.reorder(next, expected: expected, context: context) }

}

/// A video being added, or one that could not be saved, stays in the App Previews section with its next step.
private struct PendingPreviewRow: View {
    let selected: PendingPreviewSelection, busy: Bool
    var body: some View {
        Group {
            if selected.saving { StorebenchAddingRow { ProgressView("Saving \(selected.name) on this Mac…") } }
            else {
                StorebenchNotSavedRow(title: "\(selected.name) not added", reason: selected.status.isEmpty ? "This video is not saved yet. Try again, or discard it." : selected.status,
                                      next: "Try Again", retry: { Task { _ = await selected.save() } }, discard: { selected.remove() })
            }
        }.storebenchWorking(busy)
    }
}
