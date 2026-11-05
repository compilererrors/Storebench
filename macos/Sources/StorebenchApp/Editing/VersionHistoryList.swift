import StorebenchCore
import SwiftUI

/// Every version's App Store listing, newest first. Opening a version shows its text and screenshots in each language,
/// with each field marked when it changed from the version before.
struct VersionHistoryList: View {
    let history: VersionHistory
    let session: WorkspaceSession?
    let available: Bool
    let showGallery: ([LibraryChooser.Shot], LibraryChooser.Shot) -> Void
    @State private var chosen: [String: String] = [:]
    var body: some View {
        StorebenchCollection(items: history.entries, title: { $0.title }, subtitle: subtitle, preferenceID: "version-history", initialOpeningLimit: 1,
                             empty: "No imported versions yet. Sync the app to read every version from App Store Connect.") { entry in
            VStack(alignment: .leading, spacing: StorebenchTheme.gap) {
                if entry.languages.count > 1 {
                    StorebenchPicker("Language", selection: Binding(get: { language(entry)?.locale ?? "" }, set: { chosen[entry.id] = $0 })) {
                        selectionOptions(entry.languages) { SelectionOption("\(StoreLocales.name($0.locale)) (\($0.locale))", value: $0.locale) }
                    }.storebenchFormColumn()
                }
                if let language = language(entry) {
                    ForEach(language.fields) { field in fieldView(field, previous: entry.previous) }
                    screenshots(language)
                } else {
                    Text("Apple returned no languages for this version.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
                }
            }
        }
    }
    private func subtitle(_ entry: VersionHistory.Entry) -> String {
        let change = entry.previous.map { entry.changedCount == 1 ? "1 change since \($0)" : "\(entry.changedCount) changes since \($0)" } ?? "First version"
        return [entry.state, change, "Saved \(LibraryOverview.timestamp(entry.savedAt))"].filter { !$0.isEmpty }.joined(separator: " · ")
    }
    private func language(_ entry: VersionHistory.Entry) -> VersionHistory.Language? {
        entry.languages.first { $0.locale == chosen[entry.id] } ?? entry.languages.first
    }
    private func fieldView(_ field: VersionHistory.Field, previous: String?) -> some View {
        VStack(alignment: .leading, spacing: StorebenchTheme.space(1)) {
            HStack(spacing: StorebenchTheme.space(2)) {
                Text(field.label).font(.sbCaption.weight(.semibold)).foregroundStyle(StorebenchTheme.muted)
                if field.changed, let previous {
                    Text("Changed since \(previous)").font(.sbCaption.weight(.semibold)).foregroundStyle(StorebenchTheme.accent)
                }
            }
            if field.value.isEmpty { Text("Empty").font(.sbCallout).foregroundStyle(StorebenchTheme.muted) }
            else { StorebenchAdaptiveText(text: field.value, maximumHeight: 160) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder private func screenshots(_ language: VersionHistory.Language) -> some View {
        VStack(alignment: .leading, spacing: StorebenchTheme.space(1)) {
            Text("Screenshots · \(language.screenshots.count)").font(.sbCaption.weight(.semibold)).foregroundStyle(StorebenchTheme.muted)
            if language.screenshots.isEmpty { Text("No screenshots saved for this language.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted) }
            else {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: StorebenchTheme.space(3)) {
                        ForEach(Array(language.screenshots.enumerated()), id: \.element.id) { index, shot in
                            let label = "Screenshot \(index + 1)"
                            Button { showGallery(language.screenshots, shot) } label: {
                                ArchivedScreenshotThumbnail(shot: shot, session: available ? session : nil, imageHeight: 140, caption: label).frame(width: 224)
                            }.buttonStyle(StorebenchPressStyle()).storebenchWorking(!available).accessibilityLabel("Enlarge " + label)
                        }
                    }
                }.frame(height: 238)
            }
        }
    }
}
