import StorebenchCore
import SwiftUI

/// What a screenshot shows and the message its card should give, saved with it in Asset Library. Choosing the screenshot in
/// Create Media fills in that card's message.
struct AssetDescriptionDialog: View {
    let account: Account, appId: String, session: WorkspaceSession, file: AssetLibrary.File
    let saved: (AssetLibrary.File) -> Void
    let close: () -> Void
    @State private var description = ""
    @State private var tags = ""
    @State private var status = ""
    @State private var working = false
    var body: some View {
        StorebenchDialog(title: "Describe for AI Cards", kind: .form, subtitle: file.referenceName.isEmpty ? file.fileName : file.referenceName, busy: working, close: close) {
            Text("Describe what this screenshot shows and the message its card should give. When you choose it in Create Media, this becomes that card's message.")
                .font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
            StorebenchTextArea(title: "Description · \(description.utf16.count)/\(AssetLibrary.descriptionLimit)", text: $description, height: StorebenchTheme.textarea(rows: 4))
                .storebenchControlID("asset-description.text")
            StorebenchTextField("Tags", text: $tags, hint: "Separate tags with commas, such as dashboard, sharing.").storebenchControlID("asset-description.tags")
            StorebenchFeedback(text: status, height: 40, error: true)
        } actions: {
            StorebenchActionGroup(alignment: .trailing) {
                Button("Cancel") { if !working { close() } }.keyboardShortcut(.cancelAction)
                StorebenchBusyButton(title: "Save", loadingTitle: "Saving…", busy: working, variant: .primary) { Task { await save() } }
                    .storebenchWorking(description.utf16.count > AssetLibrary.descriptionLimit).storebenchControlID("asset-description.save")
            }
        }
        .onAppear { description = file.aiDescription; tags = file.tags.joined(separator: ", ") }
    }
    private func save() async {
        guard !working else { return }; working = true; defer { working = false }
        do {
            saved(try await session.describeAssetLibraryFile(accountId: account.id, appId: appId, id: file.id, description: description, tags: AssetLibrary.tags(from: tags)))
            close()
        } catch { status = (error as? PublishFailure)?.message ?? "The description could not be saved. The earlier one is kept." }
    }
}
