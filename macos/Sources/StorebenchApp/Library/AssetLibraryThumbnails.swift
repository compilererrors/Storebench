import StorebenchCore
import SwiftUI

struct LocalLibraryThumbnail: View {
    let accountId, appId: String
    let file: AssetLibrary.File
    let session: WorkspaceSession?
    @Environment(\.collectionVisible) private var visible
    @State private var image: ScreenshotPreview?
    @State private var failed = false
    var body: some View {
        AssetThumbnailSurface(image: image, message: failed ? "Local preview unavailable" : "Reading image…", loading: !failed && image == nil)
            .task(id: accountId + "/" + appId + "/" + file.id + "/" + file.hash + "/" + String(visible)) {
                image = nil; failed = false
                guard visible else { return }
                guard let session else { failed = true; return }
                var reader: SavedMediaReader?
                defer { reader?.close() }
                do {
                    let opened = try await session.openSavedMedia(.init(accountId: accountId, appId: appId, revisionId: file.id, itemId: file.id, kind: .assetLibrary)); reader = opened
                    let bytes = try await opened.imageBytes(), thumbnail = try await ScreenshotRenderer.thumbnailAsync(bytes, maximumEdge: 640)
                    try Task.checkCancellation(); try session.validateAccess(); image = thumbnail
                } catch is CancellationError { } catch { failed = true }
            }
    }
}

struct AppleLibraryThumbnail: View {
    let account: Account, appId: String
    let asset: AssetLibrary.Asset
    let session: WorkspaceSession?
    let fresh: Bool
    /// A table row's compact thumbnail; nil keeps the card preview height.
    var height: CGFloat? = nil
    @Environment(\.collectionVisible) private var visible
    @State private var image: ScreenshotPreview?
    @State private var failed = false
    var body: some View {
        AssetThumbnailSurface(image: image, message: fresh ? "Preview unavailable" : "Refresh Asset Library for previews", loading: fresh && !failed && image == nil, height: height)
            .task(id: fresh && visible ? asset.value : nil) {
                image = nil; failed = false
                guard fresh, visible else { return }
                guard let session else { failed = true; return }
                do {
                    let client = try await session.client(for: account)
                    let bytes = try await session.assetLibraryThumbnail(account: account, appId: appId, asset: asset, client: client)
                    let thumbnail = try await ScreenshotRenderer.thumbnailAsync(bytes, maximumEdge: 640)
                    try Task.checkCancellation(); try session.validateAccess(); image = thumbnail
                } catch is CancellationError { } catch { failed = true }
            }
    }
}

private struct AssetThumbnailSurface: View {
    let image: ScreenshotPreview?
    let message: String
    let loading: Bool
    var height: CGFloat? = nil
    var body: some View {
        ZStack {
            if let image { Image(decorative: image.image, scale: 1).resizable().aspectRatio(contentMode: .fit) }
            else if height != nil {
                Group { if loading { StorebenchSpinner() } else { StorebenchIcon(name: "screenshots", size: 20).foregroundStyle(StorebenchTheme.muted) } }
                    .help(message).accessibilityLabel(message)
            } else {
                VStack(spacing: StorebenchTheme.space(2)) {
                    if loading { StorebenchSpinner() }
                    else { StorebenchIcon(name: "screenshots", size: 28).foregroundStyle(StorebenchTheme.muted) }
                    Text(message).font(.sbCaption).foregroundStyle(StorebenchTheme.muted).multilineTextAlignment(.center)
                }
            }
        }.frame(maxWidth: .infinity).frame(height: height ?? StorebenchTheme.measure("assetPreviewHeight") - 2 * StorebenchTheme.measure("assetPreviewPadding"))
    }
}
