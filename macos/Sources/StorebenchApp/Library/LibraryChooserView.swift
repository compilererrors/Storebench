import StorebenchCore
import SwiftUI

struct LibraryChooserView: View {
    let model: LibraryModel, section: AppNavigation.Section, navigationMessage: String
    let openApp: (LibraryOverview.Destination) -> Void
    @State private var entries: [LibraryChooser.Entry]?
    @State private var loading = false
    @State private var failed = false
    @State private var context = UUID()
    @State private var readGate = PresentationWork()
    @State private var gallery: ScreenshotGalleryRequest?
    @State private var galleryScope: Editing?
    @Environment(\.navigationPresentation) private var history
    private var unavailable: Bool { failed || entries == nil }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: StorebenchTheme.gap) {
                StorebenchPageHeader(title: section.title, description: "Choose an app to open " + section.title + ". Saved languages and images come from the latest complete import.", eyebrow: "APP WORKFLOWS", actions: AnyView(HStack {
                    Spacer(minLength: 0)
                    LibraryAppRefreshButton(model: model, identity: section.key) { await load(context, wait: true) }
                }), feedback: AnyView(StorebenchFeedback(text: failed ? "Saved apps could not be confirmed. Refresh before opening an app." : navigationMessage.isEmpty ? model.appRefreshMessage : navigationMessage, height: 34, error: failed || model.appRefreshFailed)))
                // Only Previews and Screenshots has more to show for an app; every other section opens the app directly from its row.
                StorebenchCollection(items: unavailable ? [] : entries ?? [], title: { $0.name(for: section) }, subtitle: description, icon: { entry in
                    AnyView(AppIconView(accountId: entry.row.account.id, appId: entry.row.app.id, name: entry.name(for: section), session: unavailable ? nil : model.session).id(entry.id + "/" + entry.row.accountToken))
                }, empty: failed ? "Saved apps could not be confirmed. Choose Refresh Apps." : entries == nil ? "Reading saved apps…" : "No apps configured. Connect an Apple account or choose Refresh Apps.",
                   activate: section == .media ? nil : { entry in if let action = try? entry.destination(section) { openApp(action) } }) { entry in
                    StorebenchCardList {
                        StorebenchNavigationCard(title: entry.name(for: section), description: description(entry), action: "Open", activate: { if let action = try? entry.destination(section) { openApp(action) } }) {
                            AppIconView(accountId: entry.row.account.id, appId: entry.row.app.id, name: entry.name(for: section), session: unavailable ? nil : model.session)
                        }.storebenchControlID("library.open." + entry.id)
                        if section == .media, let shots = entry.screenshots {
                            StorebenchCardListSection {
                                if shots.isEmpty { StorebenchAdaptiveText(text: "No screenshots archived yet. Import the app to see its assets.", color: StorebenchTheme.muted) }
                                else {
                                    StorebenchMetricGrid(maximumColumns: 5, minimumWidth: 160) {
                                        ForEach(Array(shots.prefix(5))) { shot in
                                            StorebenchMediaButton(title: "Enlarge " + shot.fileName, action: { showGallery(entry, initial: shot) }) { ArchivedScreenshotThumbnail(shot: shot, session: unavailable ? nil : model.session, row: entry.row) }
                                        }
                                    }
                                }
                            }
                        }
                    }.id(entry.id + "/" + entry.row.accountToken)
                }
            }.modifier(StorebenchPageContent())
        }
        .task(id: section) {
            let id = UUID(); context = id; failed = false; loading = false
            entries = history?.rememberedRead("library-chooser/" + section.key, as: [LibraryChooser.Entry].self)
            await StorebenchPolling.repeating(every: .seconds(2), stamp: { try? await model.session?.savedStateToken() },
                                              working: { failed || entries.map { $0.contains { $0.row.changing } } != false },
                                              while: { context == id }) { await load(id) }
        }
        .onDisappear { context = UUID(); readGate.end(); gallery = nil }
        .trackUnsavedChanges(false, busy: loading)
        .sheet(item: $gallery) { request in
            if let session = model.session, let scope = galleryScope { SavedScreenshotGallery(request: request, scope: scope, setId: "", session: session, close: { gallery = nil }) }
        }
    }
    private func description(_ entry: LibraryChooser.Entry) -> String {
        if section == .pricing { return entry.row.account.name + " · Apple ID " + entry.row.app.id }
        if section == .localizations {
            guard let labels = entry.languages else { return "Saved languages unavailable" }
            return "\(labels.count) archived \(labels.count == 1 ? "language" : "languages")" + (labels.isEmpty ? "" : " · " + labels.prefix(4).joined(separator: ", "))
        }
        if section == .media { return entry.screenshots.map { "\($0.count) archived \($0.count == 1 ? "image" : "images")" } ?? "Saved images unavailable" }
        return entry.row.account.name + " · Apple ID " + entry.row.app.id
    }
    private func showGallery(_ entry: LibraryChooser.Entry, initial: LibraryChooser.Shot) {
        guard !unavailable, let session = model.session, let shots = entry.screenshots, shots.contains(where: { $0.id == initial.id }) else { return }
        let starting = context
        Task {
            do {
                try await session.validateConnectedApp(entry.row); try Task.checkCancellation()
                guard model.session === session, context == starting else { return }
                galleryScope = Editing(accountId: entry.row.account.id, appId: entry.row.app.id, revisionId: initial.source.revisionId, local: false)
                gallery = ScreenshotGalleryRequest(items: shots.map(\.galleryItem), initialId: initial.id, archivedSources: shots.map(\.source))
            } catch { if context == starting, model.session === session { failed = true } }
        }
    }
    private func load(_ id: UUID, wait: Bool = false) async {
        while wait && readGate.active {
            guard context == id, !Task.isCancelled else { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard context == id, !Task.isCancelled, !readGate.active, let session = model.session else { return }
        let ticket = readGate.begin(); if entries == nil { loading = true }
        defer { if readGate.accepts(ticket) { readGate.end() }; if context == id { loading = false } }
        do {
            let next = try await session.libraryChooser(section)
            guard context == id, !Task.isCancelled, model.session === session else { return }
            if entries != next { entries = next }; failed = false
            history?.rememberRead(next, "library-chooser/" + section.key)
        } catch { if context == id, !Task.isCancelled, model.session === session { failed = true } }
    }
}
