import AppKit
import StorebenchCore
import SwiftUI

/// Decorative icon inside a fixed track; missing or undecodable images retain the app's initial.
struct AppIconView: View {
    let accountId: String, appId: String, name: String, session: WorkspaceSession?
    @State private var image: NSImage?
    @Environment(\.collectionVisible) private var visible
    private struct LoadIdentity: Equatable {
        let accountId, appId, name: String
        let session: ObjectIdentifier?
        let visible: Bool
    }
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11).fill(StorebenchTheme.color("color-surface-accent"))
            Text(AppIcons.initial(name)).font(.system(size: 20)).foregroundStyle(StorebenchTheme.color("color-accent-medium"))
            if let image { Image(nsImage: image).resizable().scaledToFill().frame(width: 42, height: 42) }
        }
        .frame(width: 42, height: 42).clipShape(RoundedRectangle(cornerRadius: 11)).accessibilityHidden(true)
        .task(id: LoadIdentity(accountId: accountId, appId: appId, name: name, session: session.map { ObjectIdentifier($0) }, visible: visible)) {
            image = nil
            guard visible, let session else { return }
            do {
                guard let account = try await session.accounts().first(where: { $0.id == accountId }) else { return }
                let saved = try await session.appIcon(account: account, appId: appId)
                try Task.checkCancellation(); try session.validateAccess()
                image = saved.flatMap { NSImage(data: $0.data) }
            } catch { if !Task.isCancelled { image = nil } }
        }
    }
}
