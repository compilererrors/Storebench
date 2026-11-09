import StorebenchCore
import SwiftUI

/// One command row belongs to the enclosing media card.
struct MediaDraftCommands: View {
    let model: MediaListingEditor
    var blocked = false
    var syncing = false
    let sync: () -> Void
    var body: some View {
        StorebenchActionGroup(alignment: .trailing) {
            StorebenchBusyButton(title: "Save Draft", loadingTitle: "Saving…", busy: model.workflow.phase == .saving) {
                Task {
                    guard !blocked, !model.workflow.busy else { return }
                    _ = await model.run()
                }
            }
            .storebenchWorking(blocked || model.workflow.busy || (!model.dirty || model.workflow.blocked))
            .help("Save additions, removals and order on this Mac")
            StorebenchBusyButton(title: "Sync to Apple", loadingTitle: syncing ? "Syncing…" : "Preparing…", busy: syncing || model.workflow.phase == .preparing, variant: model.needsSync ? .primary : .secondary, action: sync)
                .storebenchWorking(blocked || model.busy || model.workflow.blocked)
                .help("Save the media draft and review the changes before sending them to App Store Connect")
        }
    }
}
