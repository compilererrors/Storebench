import StorebenchCore
import SwiftUI

/// Adds screenshots from Asset Library to one language: originals saved on this Mac, such as cards made in Create Media, and
/// files App Store Connect's Asset Library already has. Apple's files keep their Asset Library ID, so a Save adds them to
/// App Previews and Screenshots without uploading them again. Everything is added on this Mac first, like a file from disk.
struct AssetLibraryPicker: View {
    let account: Account, appId: String, session: WorkspaceSession, model: MediaLayoutTarget, close: () -> Void
    @State private var local: [AssetLibrary.File]?
    @State private var apple: [AssetLibrary.Asset]?
    @State private var appleFailed = false
    /// Chosen files in the order they were chosen, which is the order they are added in.
    @State private var chosen: [String] = []
    @State private var working = false
    @State private var status = ""

    struct MediaLayoutTarget { let editor: MediaListingEditor; let setId: String? }

    var body: some View {
        StorebenchDialog(title: "Add from Asset Library", wide: true, height: 760, busy: working, close: close) {
            Text("Choose up to \(ScreenshotSpecs.maximum) screenshots. They are added to this language on this Mac in the order you choose them; Save to App Previews and Screenshots then sends them. Files already in App Store Connect are added without uploading them again.")
                .font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
            StorebenchCardSection(title: "On This Mac", description: "Originals saved in Asset Library on this Mac, including cards added from Create Media.") {
                if let local {
                    StorebenchCollection(items: local, title: { $0.referenceName.isEmpty ? $0.fileName : $0.referenceName }, subtitle: { "\($0.width) × \($0.height) px" }, maximumColumns: 4, cardSurface: false, initialOpeningLimit: -1,
                                         empty: "No screenshots saved in Asset Library on this Mac yet. Add files or cards in Asset Library.") { file in
                        StorebenchAssetCard(title: file.referenceName.isEmpty ? file.fileName : file.referenceName + "\n" + file.fileName, metadata: "\(file.width) × \(file.height) px · on this Mac", status: position("mac:" + file.id)) {
                            LocalLibraryThumbnail(accountId: account.id, appId: appId, file: file, session: session).accessibilityLabel(file.fileName)
                        } actions: { toggle("mac:" + file.id, name: file.fileName) }
                    }
                } else { StorebenchLoadingStatus(message: "Reading Asset Library on this Mac…", surface: false) }
            }
            StorebenchCardSection(title: "In App Store Connect", description: "Processed screenshots already in this app's Asset Library at Apple.") {
                if let apple {
                    StorebenchCollection(items: apple, title: { $0.name }, subtitle: { $0.fileName }, maximumColumns: 4, cardSurface: false, initialOpeningLimit: -1,
                                         empty: "Asset Library in App Store Connect has no processed screenshots for this app yet.") { asset in
                        StorebenchAssetCard(title: asset.name, metadata: "\(asset.size / 1024) KiB · in App Store Connect", status: position("apple:" + asset.id)) {
                            AppleLibraryThumbnail(account: account, appId: appId, asset: asset, session: session, fresh: true).accessibilityLabel(asset.fileName)
                        } actions: { toggle("apple:" + asset.id, name: asset.fileName) }
                    }
                } else if appleFailed {
                    Text("Asset Library in App Store Connect could not be read. Files on this Mac can still be added.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
                } else { StorebenchLoadingStatus(message: "Reading Asset Library in App Store Connect…", surface: false) }
            }
            StorebenchFeedback(text: status, height: 40)
        } actions: {
            StorebenchActionGroup(alignment: .trailing) {
                Button("Cancel") { if !working { close() } }.keyboardShortcut(.cancelAction)
                StorebenchBusyButton(title: chosen.isEmpty ? "Add" : "Add \(chosen.count)", loadingTitle: "Adding…", busy: working, variant: .primary) { Task { await add() } }
                    .storebenchWorking(chosen.isEmpty)
            }
        }
        .interactiveDismissDisabled(working)
        .task { await load() }
    }

    private func position(_ id: String) -> String { chosen.firstIndex(of: id).map { "Chosen · \($0 + 1)" } ?? "" }
    private func toggle(_ id: String, name: String) -> some View {
        StorebenchCheckbox("Add " + name, isOn: Binding(get: { chosen.contains(id) }, set: { on in
            if on { if chosen.count < ScreenshotSpecs.maximum { chosen.append(id) } else { status = "Choose up to \(ScreenshotSpecs.maximum) screenshots at a time." } }
            else { chosen.removeAll { $0 == id } }
        })).storebenchWorking(working)
    }

    private func load() async {
        local = ((try? await session.assetLibraryFiles(accountId: account.id, appId: appId)) ?? []).filter { $0.kind == .image && $0.category == .listing }
        do {
            let snapshot = try await session.assetLibrary(account: account, appId: appId, client: try await session.client(for: account))
            apple = snapshot.assets.filter { $0.kind == .image && $0.ready && $0.category == AssetLibrary.Category.listing.rawValue }
        } catch { appleFailed = true }
    }

    /// Reads each chosen file, then adds them all in one batch, so a file that cannot be read adds nothing.
    private func add() async {
        guard !working, !chosen.isEmpty else { return }; working = true; defer { working = false }; status = ""
        do {
            var picks: [MediaListingEditor.LibraryPick] = []
            let client = chosen.contains { $0.hasPrefix("apple:") } ? try await session.client(for: account) : nil
            for id in chosen {
                if id.hasPrefix("mac:"), let file = local?.first(where: { "mac:" + $0.id == id }) {
                    let reader = try await session.openSavedMedia(.init(accountId: account.id, appId: appId, revisionId: file.id, itemId: file.id, kind: .assetLibrary)); defer { reader.close() }
                    picks.append(.init(name: file.fileName, data: try await reader.imageBytes(), assetId: nil))
                } else if id.hasPrefix("apple:"), let client, let asset = apple?.first(where: { "apple:" + $0.id == id }) {
                    picks.append(.init(name: asset.fileName, data: try await session.assetLibraryScreenshot(account: account, appId: appId, asset: asset, client: client), assetId: asset.id))
                }
            }
            await model.editor.addFromLibrary(picks, setId: model.setId)
            status = model.editor.status
            if status.hasSuffix("added from Asset Library on this Mac.") { close() }
        } catch let failure as PublishFailure { status = failure.message }
        catch { status = "The chosen files could not be read. Nothing was added." }
    }
}
