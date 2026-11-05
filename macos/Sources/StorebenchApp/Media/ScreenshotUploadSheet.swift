import StorebenchCore
import SwiftUI

/// Fixes screenshots that could not be added. Add Screenshots saves them into the draft; originals stay restorable until then.
struct ScreenshotUploadSheet: View {
    let model: PendingScreenshotSelection, close: () -> Void
    @State private var editing: ScreenshotSelection.Item?
    @State private var reorder = MaterialReorder()
    @Environment(\.draftWorkflowBusy) private var inheritedBusy
    private var busy: Bool { model.busy || editing != nil }
    var body: some View {
        StorebenchDialog(title: "Fix Screenshots", wide: true, height: 760, busy: busy, close: close) {
            Text("Edit an image to crop, rotate or resize it. Add Screenshots saves them to this version on this Mac. Close keeps them in the Screenshots section to fix later.")
                .font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
            Group {
                if let selection = model.selection {
                    VStack(alignment: .leading, spacing: 0) {
                        StorebenchCollection(items: selection.items, title: { $0.name }, maximumColumns: 3, minimumWidth: 280, cardSurface: false, initialOpeningLimit: -1, empty: "No screenshots left in this selection. Close, then discard it or add the files again.") { item in
                            let index = selection.items.firstIndex { $0.id == item.id } ?? 0
                            StorebenchAssetCard(title: item.name, metadata: "\(Double(item.data.count).formatted(.number.scale(0.000001).precision(.fractionLength(2)))) MB · Selected on this Mac", status: item.edits == nil ? "Original" : "Edited", position: index + 1,
                                                drag: !busy && !inheritedBusy ? MaterialDrag(id: item.id, title: item.name, context: selection.revision, order: selection.items.map(\.id), enabled: true, session: reorder, activate: { model.setEditing(true); editing = item }) : nil) {
                                Button { model.setEditing(true); editing = item } label: {
                                    SelectedScreenshotThumbnail(item: item)
                                        .frame(height: StorebenchTheme.measure("assetPreviewHeight") - 2 * StorebenchTheme.measure("assetPreviewPadding"))
                                        .overlay(StorebenchControlOutline(border: .clear))
                                }.buttonStyle(StorebenchPressStyle()).help("Edit " + item.name).accessibilityLabel("Edit " + item.name)
                                    .materialDragSource(id: item.id, title: item.name, order: selection.items.map(\.id), context: selection.revision, enabled: !busy && !inheritedBusy && selection.items.count > 1, session: reorder, activate: { model.setEditing(true); editing = item })
                            } actions: {
                                VStack(spacing: StorebenchTheme.space(2)) {
                                    HStack(spacing: StorebenchTheme.space(2)) {
                                        StorebenchReorderHandle(id: item.id, title: item.name, context: selection.revision, order: selection.items.map(\.id), enabled: !busy && !inheritedBusy, session: reorder, apply: { next, _, context in model.reorder(next, expectedRevision: context) })
                                        Button("Edit Image") { model.setEditing(true); editing = item }.buttonStyle(StorebenchButtonStyle(.quiet, stretch: true))
                                        Button(role: .destructive) { model.remove(item.id) } label: { StorebenchIcon(name: "close", size: 16) }
                                            .buttonStyle(StorebenchButtonStyle(.danger, size: .icon)).help("Remove from selection").accessibilityLabel("Remove " + item.name + " from selection")
                                    }
                                    HStack(spacing: StorebenchTheme.space(2)) {
                                        Button { model.move(item.id, by: -1) } label: { StorebenchIcon(name: "up", size: 16) }
                                            .buttonStyle(StorebenchButtonStyle(.quiet, size: .icon)).opacity(index == 0 ? 0 : 1).allowsHitTesting(index > 0).accessibilityHidden(index == 0).help("Move earlier").accessibilityLabel("Move " + item.name + " earlier")
                                        Button { model.move(item.id, by: 1) } label: { StorebenchIcon(name: "down", size: 16) }
                                            .buttonStyle(StorebenchButtonStyle(.quiet, size: .icon)).opacity(index == selection.items.count - 1 ? 0 : 1).allowsHitTesting(index < selection.items.count - 1).accessibilityHidden(index == selection.items.count - 1).help("Move later").accessibilityLabel("Move " + item.name + " later")
                                        Button("Restore Original") { model.restore(item.id) }.buttonStyle(StorebenchButtonStyle(.quiet, stretch: true))
                                            .opacity(item.edits == nil ? 0 : 1).allowsHitTesting(item.edits != nil).accessibilityHidden(item.edits == nil)
                                    }
                                }
                            }
                            .materialDropTarget(id: item.id, session: reorder)
                        }
                        .materialDropArea(order: selection.items.map(\.id), context: selection.revision, enabled: !busy && !inheritedBusy, session: reorder, apply: { next, _, context in model.reorder(next, expectedRevision: context) })
                    }
                    StorebenchReorderFeedback(session: reorder)
                } else if model.reading {
                    if let progress = model.readProgress {
                        ProgressView(value: progress.fraction, total: 1) {
                            Text("Reading screenshots · \(progress.completedFiles) of \(progress.totalFiles) files · \(Double(progress.bytesRead).formatted(.number.scale(0.000001).precision(.fractionLength(1)))) MB read")
                        }
                    } else { ProgressView("Reading selected files…") }
                }
            }.storebenchWorking(busy).frame(maxWidth: .infinity, alignment: .leading)
        } actions: {
            ZStack(alignment: .topLeading) {
                StorebenchFeedback(text: model.status.isEmpty ? model.problem ?? "PNG or JPEG · 20 MB each, 50 MB per saved batch · up to 10 per display size." : model.status, height: 56).opacity(model.validating ? 0 : 1)
                if model.validating { ProgressView("Checking selection…") }
            }.frame(height: 56)
            StorebenchActionGroup(alignment: .trailing) {
                Button("Discard", role: .destructive) { if !busy { discard() } }
                if model.selection == nil { Button("Retry Read") { if !busy { Task { await model.load() } } } }
                Button("Close") { if !busy { close() } }.keyboardShortcut(.cancelAction)
                if model.selection != nil && model.problem == nil {
                    Button("Add Screenshots") { if !busy && model.ready { close(); Task { _ = await model.add() } } }
                        .buttonStyle(StorebenchButtonStyle(.primary)).storebenchWorking(!model.ready)
                }
            }.storebenchWorking(busy)
        }
        .interactiveDismissDisabled(true)
        .environment(\.draftWorkflowBusy, inheritedBusy || busy)
        .sheet(item: $editing) { item in
            ScreenshotImageEditor(item: item, platform: model.platform, displayType: model.displayType, apply: { data, edits in
                try model.apply(item.id, data: data, edits: edits)
            }, close: { editing = nil; model.setEditing(false) })
        }
        .task { await model.load() }
        .onChange(of: busy) { if busy { reorder.cancel() } }
        .onDisappear { reorder.cancel() }
    }
    private func discard() {
        guard !busy, model.active else { return }
        let starting = model.selection?.revision
        guard !model.dirty || EditorProtection.confirm(.confirmDiscard), !busy, model.active, starting == model.selection?.revision else { return }
        model.clear(); close()
    }
}

private struct SelectedThumbnailRequest: Equatable { let edits: ScreenshotEdits?, visible: Bool }
private struct SelectedScreenshotThumbnail: View {
    let item: ScreenshotSelection.Item
    @Environment(\.collectionVisible) private var visible
    @State private var image: ScreenshotPreview?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(StorebenchTheme.color("color-surface-sunken"))
            if let image { Image(decorative: image.image, scale: 1).resizable().aspectRatio(contentMode: .fit) }
        }.accessibilityHidden(true)
        .task(id: SelectedThumbnailRequest(edits: item.edits, visible: visible)) {
            image = nil
            guard visible else { return }
            if let result = try? await ScreenshotRenderer.thumbnailAsync(item.data, maximumEdge: 640), !Task.isCancelled { image = result }
        }
    }
}
