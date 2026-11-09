import StorebenchCore
import SwiftUI

struct Editing: Equatable { let accountId: String, appId: String, revisionId: String, local: Bool }

struct VersionCard: View {
    enum Mode { case text, media }
    let account: Account, version: Revision.Version, scope: Editing, mode: Mode, locale: String, targetMode: String, session: WorkspaceSession?, openReview: (LanguageListingReview) -> Bool, selectLanguage: (String) -> Void, changed: () -> Void
    @State private var adding = false
    @State private var newLocale = ""
    @State private var copyFrom = ""
    @State private var status = ""
    @State private var languageWorking = false
    @Environment(\.editorProtection) private var protection

    private var available: [String] { StoreLocales.codes.filter { code in !version.localizations.contains { $0.locale == code } } }

    /// Adds a language as a local draft; App Store Connect is unchanged until the version is published.
    private var addLanguage: some View {
        VStack(alignment: .leading, spacing: 8) {
            StorebenchFormGrid {
                StorebenchPicker("Language", selection: $newLocale) { selectionOptions(available) { SelectionOption(StoreLocales.name($0), value: $0) } }
                StorebenchPicker("Copy text from", selection: $copyFrom) {
                    SelectionOption("Start empty", value: "")
                    selectionOptions(version.localizations) { SelectionOption(StoreLocales.name($0.locale), value: $0.locale) }
                }
            }
            HStack(spacing: 12) {
                Button("Add Language") {
                    guard !languageWorking, !newLocale.isEmpty, protection?.allowLeaving() != false, let session else { return }
                    let target = newLocale, source = copyFrom.isEmpty ? nil : copyFrom
                    languageWorking = true
                    Task {
                        defer { languageWorking = false }
                        do {
                            _ = try await session.addLanguage(accountId: scope.accountId, appId: scope.appId, revisionId: scope.revisionId, versionId: version.id, locale: target, copyFrom: source)
                            selectLanguage(target); adding = false; status = "\(StoreLocales.name(target)) added on this Mac."; changed()
                        } catch let failure as LanguageFailure { status = failure.message } catch let failure as DraftFailure { status = failure.message } catch { status = DraftFailure.invalid.message }
                    }
                }.buttonStyle(StorebenchButtonStyle(.primary)).opacity(newLocale.isEmpty ? 0 : 1).allowsHitTesting(!newLocale.isEmpty).accessibilityHidden(newLocale.isEmpty)
                Button("Cancel") { adding = false }
            }
        }
        .onAppear { if newLocale.isEmpty { newLocale = available.first ?? "" }; if copyFrom.isEmpty { copyFrom = version.localizations.first?.locale ?? "" } }
    }

    private var selected: Revision.Localization? { version.localizations.first { $0.locale == locale } }

    var body: some View {
        Card(title: version.title, subtitle: version.state) {
            if !scope.local && !adding && !available.isEmpty { Button("Add Language…") { if protection?.allowLeaving() != false { adding = true; status = "" } } }
            if adding { addLanguage }
            StorebenchFeedback(text: status, height: 34)
            if mode == .media {
                StorebenchCollection(items: version.localizations, title: { StoreLocales.name($0.locale) }, subtitle: { $0.locale + " · Screenshots and preview videos" },
                    focusedID: selected?.id, empty: "No languages in this version yet. Add a language to add its screenshots and app previews.", onOpen: { selectLanguage($0.locale) }) { selected in
                    MediaListingView(account: account, version: version, scope: scope, localization: selected, others: version.localizations.filter { $0.id != selected.id }, targetMode: targetMode, session: session, openReview: openReview)
                        .id("\(scope.accountId)/\(scope.appId)/\(scope.revisionId)/media/\(selected.id)/\(targetMode)")
                }
            } else if selected == nil { Text("No listing localization saved for this language.").foregroundStyle(StorebenchTheme.muted) }
        }
        .storebenchWorking(languageWorking)
        .trackUnsavedChanges(false, busy: languageWorking)
    }
}

/// A saved screenshot, decrypted from local media. A missing file is shown as a placeholder, never fetched.
struct ScreenshotThumbnail: View {
    let screenshot: ScreenshotSetDraft.Item, session: WorkspaceSession?
    var canvasHeight: CGFloat? = nil
    var canvasColor = StorebenchTheme.color("color-surface-sunken")
    @Environment(\.collectionVisible) private var visible
    @State private var image: ScreenshotPreview?
    @State private var missing = false

    var body: some View {
        let ratio: CGFloat = {
            if let width = screenshot.width, let height = screenshot.height { return CGFloat(width) / CGFloat(height) }
            if let image { return CGFloat(image.image.width) / CGFloat(image.image.height) }
            return 1
        }()
        ZStack {
            RoundedRectangle(cornerRadius: StorebenchTheme.controlRadius).fill(canvasColor)
            if let image { Image(decorative: image.image, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: StorebenchTheme.controlRadius)) }
            else if missing { Text("Not saved").font(.sbCaption).foregroundStyle(StorebenchTheme.muted) }
            else { ProgressView().controlSize(.small).accessibilityLabel("Reading Saved Media") }
        }
        .frame(width: canvasHeight == nil ? 140 * min(ratio, 2) : nil, height: canvasHeight ?? 140 * min(1 / ratio, 2.2))
        .frame(maxWidth: canvasHeight == nil ? nil : .infinity)
        .clipShape(RoundedRectangle(cornerRadius: StorebenchTheme.controlRadius))
        .accessibilityLabel(screenshot.fileName)
        .task(id: screenshot.sha256 + "/" + String(visible)) {
            image = nil; missing = false
            guard visible else { return }
            guard let session else { missing = true; return }
            do {
                let bytes = try await session.mediaBytes(screenshot.sha256), decoded = try await ScreenshotRenderer.thumbnailAsync(bytes, maximumEdge: 640)
                try Task.checkCancellation(); try session.validateAccess(); image = decoded
            } catch is CancellationError { } catch { missing = true }
        }
    }
}
