import StorebenchCore
import SwiftUI

struct SavedVersionBrowser: View {
    let revision: ArchivedRevision, account: Account, app: Account.App, session: WorkspaceSession?, available: Bool
    @State private var summaries: [AppOverviewMaterial.Summary] = []
    @State private var reading = false
    @State private var status = ""
    var body: some View {
        Card(title: "Saved app versions", subtitle: "Choose how many versions to show and expand. Each saved version contains separate language cards.") {
            StorebenchFeedback(text: status, height: 34)
            StorebenchCollection(items: summaries, title: { AppStoreNames.platform($0.platform) + " " + $0.number }, subtitle: { $0.state + " · \($0.languages) languages" }, empty: "No versions are saved in this snapshot.") { summary in
                SavedVersionDetailCard(revision: revision, summary: summary, account: account, app: app, session: session, available: available && !reading)
            }
        }.task {
            do { summaries = try AppOverviewMaterial.summaries(revision) }
            catch { status = "Saved version summaries could not be verified. Refresh saved material." }
        }.trackUnsavedChanges(false, busy: reading)
    }
}

private struct SavedVersionDetailCard: View {
    let revision: ArchivedRevision, summary: AppOverviewMaterial.Summary, account: Account, app: Account.App, session: WorkspaceSession?, available: Bool
    @State private var detail: AppOverviewMaterial.Detail?
    @State private var reading = false
    @State private var status = ""
    @State private var attempt = 0
    @State private var readId: UUID?
    @State private var gallery: ScreenshotGalleryRequest?
    var body: some View {
        Group {
                VStack(alignment: .leading, spacing: 12) {
                    StorebenchTextSlot(text: status.isEmpty ? detail == nil ? "Loading saved version material…" : "\(summary.languages) saved languages. Text and media belong to this snapshot." : status, height: 48, font: .sbCallout, color: StorebenchTheme.muted, live: true)
                    if !status.isEmpty && available && session != nil { Button("Retry Version Details") { if !reading { attempt += 1 } }.storebenchWorking(reading) }
                    if let detail {
                        StorebenchCollection(items: detail.languages.map { StorebenchCollectionEntry(id: $0.id, value: $0) }, title: { $0.value.label }, empty: "No saved languages in this version.") { entry in
                            SavedVersionLanguageView(language: entry.value, session: session, available: available && !reading, enlarge: showGallery)
                        }
                    }
                }
        }
        .task(id: "\(attempt)/\(available)") {
            guard available, detail == nil, let session else { return }
            let id = UUID(); readId = id; reading = true; status = ""
            defer { if readId == id { reading = false } }
            do {
                let next = try await session.savedVersionDetail(accountId: account.id, appId: app.id, revisionId: revision.id, documentRevision: revision.documentRevision, versionId: summary.id)
                try Task.checkCancellation(); guard readId == id else { return }; detail = next
            } catch is CancellationError { } catch { if readId == id { status = "This version could not be loaded. Retry its details, or refresh saved material." } }
        }
        .trackUnsavedChanges(false, busy: reading)
        .sheet(item: $gallery) { request in
            if let session {
                SavedScreenshotGallery(request: request, scope: Editing(accountId: account.id, appId: app.id, revisionId: revision.id, local: false), setId: "", session: session, close: { gallery = nil })
            }
        }
        .onChange(of: available) { if !available { gallery = nil } }
    }
    private func showGallery(_ shots: [LibraryChooser.Shot], _ initial: LibraryChooser.Shot) {
        guard available, !reading, detail != nil, session != nil, shots.contains(where: { $0.id == initial.id }) else { return }
        gallery = .init(items: shots.map(\.galleryItem), initialId: initial.id, archivedSources: shots.map(\.source))
    }
}

private struct SavedVersionLanguageView: View {
    let language: AppOverviewMaterial.Language, session: WorkspaceSession?, available: Bool
    let enlarge: ([LibraryChooser.Shot], LibraryChooser.Shot) -> Void
    var body: some View {
        Group {
            VStack(alignment: .leading, spacing: 12) {
                Text("Saved listing").font(.sbHeadline)
                ForEach(language.fields, id: \.key) { field in
                    StorebenchReadOnlyText(title: field.label, text: field.value, field: field.key)
                }
                ForEach(Array(language.screenshotSets.enumerated()), id: \.offset) { _, set in
                    Text(set.displayType.isEmpty ? "Screenshots" : set.displayType).font(.sbHeadline)
                    Text("\(set.screenshots.count) saved screenshots").font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(Array(set.screenshots.enumerated()), id: \.element.id) { index, shot in
                                let label = "Screenshot \(index + 1)"
                                if available {
                                    Button { enlarge(set.screenshots, shot) } label: {
                                        ArchivedScreenshotThumbnail(shot: shot, session: session, imageHeight: 160, caption: label).frame(width: 256)
                                    }.buttonStyle(StorebenchPressStyle()).accessibilityLabel("Enlarge " + label)
                                } else { ArchivedScreenshotThumbnail(shot: shot, session: nil, imageHeight: 160, caption: label).frame(width: 256) }
                            }
                        }
                    }.frame(height: 258)
                }
            }.padding(.vertical, 8)
        }
    }
}
