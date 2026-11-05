import StorebenchCore
import SwiftUI

struct AssetLibraryOrderView: View {
    let editor: AssetLibraryOrderEditor, account: Account, appId: String, placements: [AssetLibrary.Placement], assets: [AssetLibrary.Asset], session: WorkspaceSession?
    let editable: Bool, fresh: Bool
    let prepare: (AssetLibrary.Change) async -> Void
    @State private var latestReading = false
    @State private var reorder = MaterialReorder()
    private var enabled: Bool { editable && !editor.blocked }
    private func title(_ id: String) -> String {
        guard let placement = placements.first(where: { $0.id == id }) else { return "Placement no longer available" }
        return assets.first { $0.id == placement.assetId }?.name ?? "Library " + placement.kind.rawValue
    }
    private func names(_ ids: [String]) -> String { ids.enumerated().map { "\($0.offset + 1). \(title($0.element))" }.joined(separator: "\n") }
    var body: some View {
        VStack(alignment: .leading, spacing: StorebenchTheme.gap) {
            StorebenchHeader {
                StorebenchTextSlot(text: editor.summary, height: 56, font: .sbCallout, color: editor.dirty ? StorebenchTheme.color("color-accent-muted") : StorebenchTheme.muted, live: true)
            } actions: {
                StorebenchActionGroup(alignment: .trailing) {
                    if enabled && editor.dirty { Button("Revert Local Edits") { if !reorder.active { editor.revert() } }.storebenchWorking(reorder.active) }
                    if (enabled && editor.dirty || editor.busy) && session != nil {
                        Button(editor.busy ? "Saving…" : "Save Order") { Task { _ = await save() } }
                            .buttonStyle(StorebenchButtonStyle(.primary)).storebenchWorking(editor.busy || reorder.active)
                    }
                    if editable && fresh && editor.canReview && session != nil {
                        Button("Review Upload") {
                            guard !reorder.active else { return }
                            var change = AssetLibrary.Change(action: .reorder)
                            change.surface = editor.scope.surface; change.targetId = editor.scope.targetId; change.placementGroup = editor.scope.group
                            change.orderedIds = editor.order; change.expectedPlacements = editor.baselineDigest
                            Task { await prepare(change) }
                        }.buttonStyle(StorebenchButtonStyle(.primary)).storebenchWorking(reorder.active)
                    }
                }
            }
            Text("Drag a card by its preview, name or handle. Save Order changes only encrypted storage on this Mac. Review Upload prepares the exact before and after; approve it in App Store changes to send it to Apple.")
                .font(.sbCaption).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
            if editor.needsComparison {
                Card(title: "Compare Apple's latest placements", subtitle: "The saved draft and Apple's current placement group differ. Choosing a baseline does not save or upload.") {
                    StorebenchMetricGrid(maximumColumns: 2, minimumWidth: 240) {
                        StorebenchReadOnlyText(title: "Current Apple order", text: names(editor.baseline), height: 120)
                        StorebenchReadOnlyText(title: "Your local order", text: names(editor.order), height: 120)
                    }
                    StorebenchFormFooter {
                        Button("Keep Local Order") { editor.acceptLatest(keepEdits: true) }
                        Button("Use Apple's Order") { editor.acceptLatest(keepEdits: false) }
                    }.storebenchWorking(editor.busy)
                }
            }
            StorebenchMetricGrid(maximumColumns: 4, minimumWidth: 260) {
                ForEach(Array(editor.order.enumerated()), id: \.element) { index, id in
                    let asset = placements.first(where: { $0.id == id }).flatMap { placement in assets.first { $0.id == placement.assetId } }
                    StorebenchAssetCard(title: title(id), metadata: asset?.fileName ?? "Read the latest placements", status: editor.dirty ? "Unsaved order" : editor.pendingUpload ? "Saved locally" : "At Apple", position: index + 1,
                                        drag: enabled ? MaterialDrag(id: id, title: title(id), context: editor.context, order: editor.order, enabled: true, session: reorder) : nil) {
                        if let asset {
                            AppleLibraryThumbnail(account: account, appId: appId, asset: asset, session: session, fresh: fresh)
                                .materialDragSource(id: id, title: title(id), order: editor.order, context: editor.context, enabled: enabled && editor.order.count > 1, session: reorder)
                        } else { StorebenchIcon(name: "screenshots", size: 32).foregroundStyle(StorebenchTheme.muted) }
                    } actions: {
                        if enabled || editor.busy {
                            HStack(spacing: StorebenchTheme.space(2)) {
                                StorebenchReorderHandle(id: id, title: title(id), context: editor.context, order: editor.order, enabled: enabled, session: reorder, apply: apply)
                                Button { move(id, to: index - 1) } label: { StorebenchIcon(name: "up", size: 16) }.buttonStyle(StorebenchButtonStyle(.quiet, size: .icon))
                                    .opacity(index == 0 ? 0 : 1).allowsHitTesting(index > 0).accessibilityHidden(index == 0).storebenchWorking(reorder.active).help("Move earlier").accessibilityLabel("Move " + title(id) + " earlier")
                                Button { move(id, to: index + 1) } label: { StorebenchIcon(name: "down", size: 16) }.buttonStyle(StorebenchButtonStyle(.quiet, size: .icon))
                                    .opacity(index == editor.order.count - 1 ? 0 : 1).allowsHitTesting(index < editor.order.count - 1).accessibilityHidden(index == editor.order.count - 1).storebenchWorking(reorder.active).help("Move later").accessibilityLabel("Move " + title(id) + " later")
                            }.storebenchWorking(editor.busy)
                        }
                    }
                    .materialDropTarget(id: id, session: reorder)
                }
            }
            .materialDropArea(order: editor.order, context: editor.context, enabled: enabled, session: reorder, apply: apply)
            StorebenchReorderFeedback(session: reorder)
            StorebenchFeedback(text: editor.status, height: 40)
            LatestSaveReview(busy: editor.busy || !editable, reading: latestReading, hasEdits: editor.dirty || editor.needsComparison, available: editable, changes: editor.latestRead ? [.init(id: "order", label: "Placement order", saved: names(editor.latestLocal?.order ?? editor.baseline), edited: names(editor.order))] : nil,
                note: "Reading and choosing the local baseline does not save or upload.", onRead: { Task { guard let session else { return }; latestReading = true; defer { latestReading = false }; await editor.readLatest { try await session.assetLibraryOrder(editor.scope) } } },
                onKeep: editor.latestRead ? { editor.acceptLocalLatest(keepEdits: true) } : nil, onUse: editor.latestRead ? { editor.acceptLocalLatest(keepEdits: false) } : nil)
        }
        .onChange(of: editable) { if !editable { reorder.cancel() } }
        .onDisappear { reorder.cancel() }
        .shortcutAction(.save, enabled: enabled && editor.dirty && !reorder.active && session != nil, identity: editor.context) { _ = await save() }
    }
    private func move(_ id: String, to: Int) { if let next = MaterialReorder.moving(editor.order, source: id, to: to) { _ = apply(next, expected: editor.order, context: editor.context) } }
    private func apply(_ next: [String], expected: [String], context: String) -> Bool { guard enabled else { return false }; return editor.reorder(next, expected: expected, context: context) }
    private func save() async -> Bool {
        guard editable, !reorder.active, let session else { return false }
        let order = editor.order
        return await editor.save { saved in
            try await session.saveAssetLibraryOrder(editor.scope, baseline: editor.baseline, baselineDigest: editor.baselineDigest, order: order, expectedRevision: saved?.revision)
        }
    }
}
