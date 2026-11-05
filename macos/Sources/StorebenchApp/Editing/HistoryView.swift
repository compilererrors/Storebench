import StorebenchCore
import SwiftUI

struct HistoryView: View {
    let account: Account, app: Account.App, session: WorkspaceSession?
    var changed: () -> Void = {}
    @State private var revisions: [ArchivedRevision] = []
    @State private var plan: ReleasePlan?
    @State private var publications: [PublishReview] = []
    @State private var publicationsLoaded = false
    @State private var publicationStatus = ""
    @State private var review: PublishReview?
    @State private var working = false
    @State private var publishing = false
    @State private var loaded = false
    @State private var status = ""
    @State private var beforeId = ""
    @State private var afterId = ""
    @State private var comparedBefore = ""
    @State private var comparedAfter = ""
    @State private var comparison: ArchivedRevisionComparison?
    @State private var gallery: ScreenshotGalleryRequest?
    /// Built once per read, not per redraw.
    @State private var versions = VersionHistory([])
    private var changes: [ArchivedRevisionComparison.Change] { comparison?.changes ?? [] }
    @State private var deleting = false
    @Environment(\.navigationPresentation) private var history
    private var busy: Bool { working || publishing || deleting }
    private struct Choices: Equatable { var beforeId, afterId, comparedBefore, comparedAfter: String }
    private struct Read { let revisions: [ArchivedRevision], plan: ReleasePlan?, publications: [PublishReview]? }
    private var readKey: String { "history/\(account.id)/\(app.id)" }
    private func comparisonKey(_ before: String, _ after: String) -> String { "history-comparison/\(account.id)/\(app.id)/\(before)/\(after)" }
    /// Back returns to the compared pair and its result, which the next read clears if either saved revision changed.
    private var choices: Binding<Choices> {
        Binding(get: { Choices(beforeId: beforeId, afterId: afterId, comparedBefore: comparedBefore, comparedAfter: comparedAfter) }, set: { value in
            beforeId = value.beforeId; afterId = value.afterId; comparedBefore = value.comparedBefore; comparedAfter = value.comparedAfter
            if comparison == nil, !value.comparedBefore.isEmpty, value.comparedBefore == value.beforeId, value.comparedAfter == value.afterId {
                comparison = history?.rememberedRead(comparisonKey(value.beforeId, value.afterId), as: ArchivedRevisionComparison.self)
            }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Card(title: "Version history", subtitle: "What each version said on the App Store, from the imports saved on this Mac. Open a version to read its text and screenshots in each language; fields that changed from the version before are marked.", help: "versions", actions: AnyView(
                Button(working ? "Reading…" : "Refresh History") { Task { await load() } }.storebenchWorking(busy)
            )) {
                StorebenchAdaptiveText(text: status, maximumHeight: 40, color: StorebenchTheme.muted)
                VersionHistoryList(history: versions, session: session, available: loaded, showGallery: { openGallery($0, initial: $1) })
            }
            if !versions.names.isEmpty {
                Card(title: "App name and subtitle", subtitle: "Each change of the name and subtitle in the primary language, newest first, as the imports saw it.") {
                    ForEach(Array(versions.names.enumerated()), id: \.element.id) { index, change in
                        if index > 0 { StorebenchDivider() }
                        VStack(alignment: .leading, spacing: StorebenchTheme.space(1)) {
                            Text(change.name.isEmpty ? "No name" : change.name).font(.sbHeadline).textSelection(.enabled)
                            Text(change.subtitle.isEmpty ? "No subtitle" : change.subtitle).font(.sbCallout).foregroundStyle(StorebenchTheme.muted).textSelection(.enabled)
                            Text("Saved \(timestamp(change.savedAt))").font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            if revisions.count >= 2 {
                Card(title: "Compare imports", subtitle: "Pick two saved imports to see every field and screenshot set that changed between them. Unsaved drafts are not included.") {
                    StorebenchFormGrid {
                        StorebenchPicker("Earlier import", selection: $beforeId) { selectionOptions(revisions) { SelectionOption(timestamp($0.importedAt) + " · " + $0.versionTitles.joined(separator: " · "), value: $0.id) } }
                        StorebenchPicker("Later import", selection: $afterId) { selectionOptions(revisions) { SelectionOption(timestamp($0.importedAt) + " · " + $0.versionTitles.joined(separator: " · "), value: $0.id) } }
                    }
                    if !beforeId.isEmpty && !afterId.isEmpty {
                        StorebenchFormFooter {
                            Button("Compare") { Task { await compare() } }
                        }
                    }
                }.storebenchWorking(busy || !loaded)
            }
            if comparison != nil {
                Card(title: "Changes", subtitle: changes.isEmpty ? "No differences between these revisions." : "\(changes.count) changed fields or screenshot sets.") {
                    StorebenchCollection(items: changes.enumerated().map { StorebenchCollectionEntry(id: String($0.offset), value: $0.element) }, title: { $0.value.value.label }, empty: "No differences between these revisions.") { item in
                        let entry = item.value
                        let change = entry.value
                        VStack(alignment: .leading, spacing: 8) {
                            Text(change.section).font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
                            HStack { Text(change.label).font(.sbHeadline); Spacer(); Text(change.kind.capitalized).font(.sbCaption).foregroundStyle(StorebenchTheme.muted) }
                            if change.type == "text" {
                                textComparison("Before", value: change.before)
                                textComparison("After", value: change.after)
                            } else {
                                images("Before", shots: entry.beforeScreenshots)
                                images("After", shots: entry.afterScreenshots)
                            }
                        }
                        StorebenchDivider()
                    }
                }
            }
            Card(title: "Saved imports", subtitle: "Each import keeps every version's text and screenshots as App Store Connect had them. Deleting one also removes its draft; screenshots used by another saved import stay available.") {
                SavedRevisionList(account: account, app: app, session: session, revisions: revisions, planSourceId: plan?.sourceRevisionId,
                    available: loaded, busy: working || publishing, busyChanged: { deleting = $0 }, removed: { message in
                        status = message; changed(); Task { await load(preserveStatus: true) }
                    })
            }
            Card(title: "Publishing history", subtitle: "Reopen a prepared review to see its exact changes and completed steps.") {
                Text(publicationStatus).font(.sbCallout).foregroundStyle(StorebenchTheme.muted).frame(maxWidth: .infinity, minHeight: 24, alignment: .topLeading)
                StorebenchCollection(items: publications, title: { $0.title }, subtitle: { publicationState($0) }, sorts: [.init(id: "date", label: "Created", less: { $0.createdAt < $1.createdAt })], empty: publicationsLoaded ? "No publishing reviews yet. Reviews you prepare appear here." : "Reading publishing history…") { item in
                    StorebenchStatusRow(title: item.title, detail: "\(timestamp(item.createdAt)) · \(item.steps.filter { $0.state == "done" }.count) of \(item.steps.count) steps completed", separator: false, actionWidth: StorebenchTheme.actionWidth) {
                        StorebenchTextSlot(text: publicationState(item), height: StorebenchTheme.controlHeight, font: .sbCaption, color: StorebenchTheme.muted, centered: true)
                    } action: {
                        if publicationsLoaded { Button("Open Review") { Task { await open(item) } }.storebenchWorking(busy) }
                    } details: { EmptyView() }
                }

            }
            ReviewPanel(account: account, app: app, session: session, review: $review, done: { Task { await load() } }, busyChanged: { publishing = $0 })
        }
        .task { showRemembered(); await load() }
        .historyValue("history", choices)
        .onChange(of: beforeId) { if beforeId != comparedBefore { comparison = nil; gallery = nil } }
        .onChange(of: afterId) { if afterId != comparedAfter { comparison = nil; gallery = nil } }
        .trackUnsavedChanges(false, busy: busy)
        .sheet(item: $gallery) { request in
            if let session, let source = request.archivedSources?.first {
                SavedScreenshotGallery(request: request, scope: Editing(accountId: source.accountId, appId: source.appId, revisionId: source.revisionId, local: false), setId: "", session: session, close: { gallery = nil })
            }
        }
        .task(id: publications.contains { $0.state == "running" }) {
            await StorebenchPolling.repeating(every: .milliseconds(2500), readFirst: false, while: { publications.contains { $0.state == "running" } }) {
                if !busy { await load() }
            }
        }
    }

    private func publicationState(_ review: PublishReview) -> String {
        if review.state == "prepared" {
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let expires = formatter.date(from: review.expiresAt) else { return "Approval expiry unknown" }
            return expires <= Date() ? "Approval expired" : "Awaiting approval"
        }
        return review.state.capitalized
    }
    private func timestamp(_ value: String) -> String { LibraryOverview.timestamp(value) }
    private func textComparison(_ title: String, value: String?) -> some View {
        StorebenchReadOnlyText(title: title, text: value ?? "", height: 140)
    }
    private func images(_ title: String, shots: [LibraryChooser.Shot]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(title) · \(shots.count) images").font(.sbCaption.bold())
            if shots.isEmpty { Text("No screenshots").font(.sbCallout).foregroundStyle(StorebenchTheme.muted) }
            else {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(Array(shots.enumerated()), id: \.element.id) { index, shot in
                            let label = "\(title) screenshot \(index + 1)"
                            Button { showGallery(shots, initial: shot) } label: {
                                ArchivedScreenshotThumbnail(shot: shot, session: loaded ? session : nil, imageHeight: 140, caption: label).frame(width: 224)
                            }.buttonStyle(StorebenchPressStyle()).storebenchWorking(busy || !loaded).accessibilityLabel("Enlarge " + label)
                        }
                    }
                }.frame(height: 238)
            }
        }
    }
    private func showGallery(_ shots: [LibraryChooser.Shot], initial: LibraryChooser.Shot) {
        guard !busy, loaded, comparison != nil, session != nil, shots.contains(where: { $0.id == initial.id }) else { return }
        gallery = ScreenshotGalleryRequest(items: shots.map(\.galleryItem), initialId: initial.id, archivedSources: shots.map(\.source))
    }
    /// Version history screenshots open in the same gallery as compared ones.
    private func openGallery(_ shots: [LibraryChooser.Shot], initial: LibraryChooser.Shot) {
        guard !busy, loaded, session != nil, shots.contains(where: { $0.id == initial.id }) else { return }
        gallery = ScreenshotGalleryRequest(items: shots.map(\.galleryItem), initialId: initial.id, archivedSources: shots.map(\.source))
    }
    private func load(preserveStatus: Bool = false) async {
        guard !busy, let session else { return }
        working = true; defer { working = false }
        do {
            let latest = try await session.archivedHistory(accountId: account.id, appId: app.id)
            let currentPlan = try await session.releasePlan(accountId: account.id, appId: app.id)
            try Task.checkCancellation()
            let comparedSourcesChanged = comparison.map { value in
                [value.before, value.after].contains { saved in latest.first(where: { $0.id == saved.id })?.documentRevision != saved.documentRevision }
            } ?? false
            if comparedSourcesChanged { comparison = nil; gallery = nil }
            revisions = latest; plan = currentPlan; loaded = true; versions = VersionHistory(latest)
            if !preserveStatus { status = "" }
            if !revisions.contains(where: { $0.id == afterId }) { afterId = revisions.first?.id ?? "" }
            if !revisions.contains(where: { $0.id == beforeId }) { beforeId = revisions.dropFirst().first?.id ?? revisions.first?.id ?? "" }
            if !revisions.contains(where: { $0.id == comparedBefore }) || !revisions.contains(where: { $0.id == comparedAfter }) { comparison = nil; gallery = nil }
        } catch { loaded = false; comparison = nil; gallery = nil; status = "Saved history could not be read. Refresh before comparing or deleting." }
        do {
            var history = try await session.publishHistory(accountId: account.id, appId: app.id)
            for index in history.indices where history[index].state == "running" {
                try Task.checkCancellation()
                history[index] = try await session.publishStatus(accountId: account.id, appId: app.id, id: history[index].id)
            }
            try Task.checkCancellation()
            publications = history; publicationsLoaded = true; publicationStatus = ""
        } catch { publicationsLoaded = false; publicationStatus = "Publishing history could not be read. Refresh history." }
        if loaded { self.history?.rememberRead(Read(revisions: revisions, plan: plan, publications: publicationsLoaded ? publications : nil), readKey) }
    }
    /// The last read shows at once; the read that follows replaces it. Actions stay disabled until that read confirms it.
    private func showRemembered() {
        guard !loaded, revisions.isEmpty, let read = history?.rememberedRead(readKey, as: Read.self) else { return }
        revisions = read.revisions; plan = read.plan; versions = VersionHistory(read.revisions)
        if let publications = read.publications { self.publications = publications }
    }
    private func compare() async {
        guard !busy, loaded, let session else { return }
        working = true; defer { working = false }
        do {
            let value = try await session.archivedRevisionComparison(accountId: account.id, appId: app.id, beforeId: beforeId, afterId: afterId)
            try Task.checkCancellation(); comparison = value; comparedBefore = beforeId; comparedAfter = afterId; status = ""
            history?.rememberRead(value, comparisonKey(beforeId, afterId))
        } catch { comparison = nil; gallery = nil; status = (error as? RevisionHistoryFailure)?.message ?? "Saved revisions could not be compared." }
    }
    private func open(_ item: PublishReview) async {
        guard !busy, publicationsLoaded, let session else { return }
        working = true; defer { working = false }
        do {
            let latest = try await session.publishStatus(accountId: account.id, appId: app.id, id: item.id)
            try Task.checkCancellation(); review = latest
        }
        catch { status = "Publishing review could not be read. Refresh history." }
    }
}
