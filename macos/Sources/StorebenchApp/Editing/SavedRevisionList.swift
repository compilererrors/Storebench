import StorebenchCore
import SwiftUI

struct SavedRevisionList: View {
    let account: Account, app: Account.App, session: WorkspaceSession?, revisions: [ArchivedRevision], planSourceId: String?, available: Bool, busy: Bool
    let busyChanged: (Bool) -> Void, removed: (String) -> Void
    @State private var confirming: ArchivedRevision?
    @State private var deleting = false
    @State private var status = ""
    @Environment(\.confirmDestructive) private var confirm
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StorebenchFeedback(text: status, height: 48)
            StorebenchCollection(items: revisions, title: { ($0.local ? "Local draft · " : "Import · ") + LibraryOverview.timestamp($0.importedAt) }, subtitle: { $0.versionTitles.joined(separator: " · ") }, sorts: [.init(id: "date", label: "Saved date", less: { $0.importedAt < $1.importedAt })], empty: "No saved revisions remain.") { revision in
                VStack(alignment: .leading, spacing: StorebenchTheme.space(2)) {
                    Text(revision.local ? "A version plan's starting material, saved on this Mac. It holds \(revision.versionTitles.joined(separator: ", "))."
                         : "What App Store Connect had on \(LibraryOverview.timestamp(revision.importedAt)) for \(revision.versionTitles.joined(separator: ", ")). Read each version under Version history, or pick this import under Compare imports.")
                        .font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
                    if revision.id == planSourceId { Text("Used by the version plan, so it cannot be deleted.").font(.sbCaption).foregroundStyle(StorebenchTheme.muted) }
                    Text(revision.id).font(.sbCaption).foregroundStyle(StorebenchTheme.muted).textSelection(.enabled)
                    if available && revision.id != planSourceId {
                        StorebenchActionGroup(alignment: .leading) {
                            Button("Delete…", role: .destructive) { delete(revision) }.help("Delete this saved \(revision.local ? "draft" : "import")")
                        }.storebenchWorking(busy || deleting)
                    }
                }
                StorebenchDivider()
            }
        }.trackUnsavedChanges(confirming != nil, busy: deleting)
    }
    private func delete(_ revision: ArchivedRevision) {
        guard !busy, !deleting, confirm(.deleteRevision, title: "Delete this saved \(revision.local ? "draft" : "import")?",
                                        message: "Its draft on this Mac is deleted too. Screenshots remain available through other saved imports that use them.", action: "Delete") else { return }
        confirming = revision; status = ""
        Task { await remove(revision) }
    }
    private func remove(_ revision: ArchivedRevision) async {
        guard !busy, !deleting, available, let confirmed = confirming, confirmed.id == revision.id, let session else { return }
        deleting = true; busyChanged(true)
        do {
            let value = try await session.deleteArchivedRevision(accountId: account.id, appId: app.id, revisionId: revision.id, expectedRevision: confirmed.documentRevision)
            confirming = nil; deleting = false; busyChanged(false); removed(value ? "Revision deleted." : "Revision not found.")
        } catch {
            status = (error as? RevisionHistoryFailure)?.message ?? "The revision could not be deleted. Refresh saved material and try again."
            confirming = nil; deleting = false; busyChanged(false)
        }
    }
}
