import StorebenchCore
import SwiftUI

struct SettingsSearchRequest: Equatable {
    let target: String
    let id = UUID()
}
private struct SettingsSearchRequestKey: EnvironmentKey { static let defaultValue: SettingsSearchRequest? = nil }
extension EnvironmentValues {
    var settingsSearchRequest: SettingsSearchRequest? {
        get { self[SettingsSearchRequestKey.self] }
        set { self[SettingsSearchRequestKey.self] = newValue }
    }
}
extension View {
    func settingsSearchAnchor(_ id: String) -> some View { modifier(SettingsSearchAnchor(id: id)) }
}
private struct SettingsSearchAnchor: ViewModifier {
    let id: String
    @Environment(\.settingsSearchRequest) private var request
    @State private var focus = StorebenchScrollFocus()
    func body(content: Content) -> some View {
        content.id(id).background(StorebenchScrollFocusAnchor(focus: focus))
            .storebenchControlID("settings.section." + id)
            .task(id: request?.id) {
                guard request?.target == id else { return }
                // The destination may have just become visible after choosing a search result.
                for _ in 0..<8 {
                    try? await Task.sleep(for: .milliseconds(30))
                    guard !Task.isCancelled else { return }
                    if focus.reveal() { return }
                }
            }
    }
}

struct SettingsSearchResults: View {
    let query: String
    let choose: (SettingsSearch.Result) -> Void
    private var results: [SettingsSearch.Result] { SettingsSearch.results(for: query) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: StorebenchTheme.gap) {
                Text(results.isEmpty ? "No Settings Found" : "\(results.count) \(results.count == 1 ? "Setting" : "Settings") Found")
                    .font(.sbHeadline).storebenchControlID("settings.search.count")
                StorebenchCollection(items: results, title: { $0.title }, subtitle: { $0.pane.title + " · " + $0.summary },
                    icon: { AnyView(StorebenchIcon(name: $0.pane.icon, size: 20).foregroundStyle(StorebenchTheme.color("color-accent-muted"))) },
                    preferenceID: "settings-search", empty: "Try a setting name, such as release cards, currency, backups or keyboard.", activate: choose) { _ in EmptyView() }
                    .id(query)
            }.padding(.horizontal, StorebenchTheme.settingsInset).padding(.vertical, StorebenchTheme.gap)
        }.storebenchControlID("settings.search.results")
    }
}
