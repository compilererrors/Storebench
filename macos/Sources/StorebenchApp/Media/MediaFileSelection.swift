import AppKit
import StorebenchCore

enum MediaFileSelection {
    @MainActor static func screenshots(remaining: Int) async throws -> [SelectedFiles.File] {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg]; panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return [] }
        guard remaining > 0, panel.urls.count <= remaining else { throw SelectedFiles.Failure.count }
        let urls = panel.urls, scopes = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { scopes.forEach { $0.stopAccessingSecurityScopedResource() } }
        return try await SelectedFiles.readAsync(urls, purpose: .screenshotEditing)
    }
}
