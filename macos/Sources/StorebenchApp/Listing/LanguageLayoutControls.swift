import StorebenchCore
import SwiftUI

private struct LanguageLayoutKey: EnvironmentKey { static let defaultValue: LanguageLayoutEditor? = nil }
extension EnvironmentValues {
    var languageLayout: LanguageLayoutEditor? {
        get { self[LanguageLayoutKey.self] }
        set { self[LanguageLayoutKey.self] = newValue }
    }
}

enum LanguageSectionNavigation {
    static func anchor(_ locale: String, _ group: LanguageEditorLayout.Group) -> String { "language-section-" + locale + "-" + group.rawValue }
}

struct LanguageLayoutControls: View {
    let editor: LanguageLayoutEditor
    let accountId: String, appId: String, session: WorkspaceSession?
    var locale = ""
    @Environment(\.pageFocusInteraction) private var interaction
    @State private var scrollFocus = StorebenchScrollFocus()
    @Environment(\.openCollectionRecord) private var openRecord
    private var selectedLocale: String? { locale.isEmpty ? nil : locale }
    var body: some View {
        StorebenchIconMenu(title: locale.isEmpty ? "Text Section Options" : "Text Section Options · " + StoreLocales.name(locale)) {
            Text("Text Sections · " + (locale.isEmpty ? "All Languages" : StoreLocales.name(locale))).font(.sbCaption)
            ForEach(LanguageEditorLayout.Group.allCases, id: \.self) { group in
                StorebenchMenuToggle(title: group.heading, isOn: Binding(get: { editor.layout.isExpanded(group, locale: selectedLocale) }, set: { change([group: $0], locale: selectedLocale, group: group) }))
                    .storebenchWorking(!editor.ready)
            }
            StorebenchMenuSeparator()
            Button("Expand All Text Sections") { change(all(true), locale: selectedLocale) }.storebenchWorking(!editor.ready || allMatch(true))
            Button("Collapse All Text Sections") { change(all(false), locale: selectedLocale) }.storebenchWorking(!editor.ready || allMatch(false))
            if !locale.isEmpty {
                StorebenchMenuSeparator()
                StorebenchSubmenu("All Languages") {
                    Button("Apply This Layout to All Languages") {
                        change(Dictionary(uniqueKeysWithValues: LanguageEditorLayout.Group.allCases.map { ($0, editor.layout.isExpanded($0, locale: locale)) }), locale: nil)
                    }
                    Button("Expand All Text Sections") { change(all(true), locale: nil) }
                    Button("Collapse All Text Sections") { change(all(false), locale: nil) }
                }.storebenchWorking(!editor.ready)
            }
            StorebenchMenuSeparator()
            Text(status)
            if editor.failed {
                Button(editor.ready ? "Retry Layout Save" : "Read Layout Again") {
                    guard !editor.saving else { return }
                    Task { if editor.ready { await flush() } else { await load() } }
                }.storebenchWorking(editor.saving)
            }
        }.help(editor.failed ? status : "Show or hide text sections for " + (locale.isEmpty ? "all languages" : StoreLocales.name(locale)) + ". Choices are remembered across versions; listing text is unchanged.")
            .accessibilityHint(editor.failed ? status : "Changes apply to " + (locale.isEmpty ? "all languages" : StoreLocales.name(locale)) + ". The All Languages submenu applies a layout everywhere.")
            .overlay(alignment: .topLeading) {
                StorebenchIcon(name: "warning", size: 10).foregroundStyle(StorebenchTheme.color("color-danger"))
                    .opacity(editor.failed ? 1 : 0).allowsHitTesting(false).accessibilityHidden(true)
            }
            .storebenchControlID("language.sections." + locale)
            .background(StorebenchScrollFocusAnchor(focus: scrollFocus))
            .task { if !editor.ready { await load() } }
            .trackUnsavedChanges(false, busy: editor.saving)
    }
    private var status: String {
        if editor.failed { return editor.ready ? "Layout Not Saved · Retry Layout Save" : "Layout Unavailable · Read Layout Again" }
        if !editor.ready { return "Reading Text Section Layout…" }
        return editor.saving ? "Saving Text Section Layout…" : locale.isEmpty ? "Layout Remembered for All Languages" : "Layout Remembered for This Language"
    }
    private func all(_ value: Bool) -> [LanguageEditorLayout.Group: Bool] {
        Dictionary(uniqueKeysWithValues: LanguageEditorLayout.Group.allCases.map { ($0, value) })
    }
    private func allMatch(_ value: Bool) -> Bool { LanguageEditorLayout.Group.allCases.allSatisfy { editor.layout.isExpanded($0, locale: selectedLocale) == value } }
    private func change(_ patch: [LanguageEditorLayout.Group: Bool], locale: String?, group: LanguageEditorLayout.Group? = nil) {
        guard session != nil, editor.ready else { return }
        interaction?()
        scrollFocus.reveal(.preserve)
        openRecord?()
        editor.change(patch, locale: locale)
        Task { await flush() }
    }
    private func load() async {
        guard let session else { return }
        do { let value = try await session.languageEditorLayout(accountId: accountId, appId: appId); try Task.checkCancellation(); if !editor.ready { editor.loaded(value) } }
        catch { if !Task.isCancelled { editor.readFailed() } }
    }
    private func flush() async {
        guard let session else { return }
        await editor.flushScoped { patch, locale in try await session.saveLanguageEditorLayout(accountId: accountId, appId: appId, patch: patch, locale: locale) }
    }
}
