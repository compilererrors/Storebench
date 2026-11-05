import AppKit
import StorebenchCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor struct ReviewsFilesView: View {
    let account: Account, app: Account.App, session: WorkspaceSession?
    let blocked: Bool
    let refreshToken: String
    let onChanged: () async -> Void
    @State private var chosen: URL?
    @State private var review: ReviewsFileReview?
    @State private var saved: ReviewsFileState?
    @State private var stale = false
    @State private var readFailed = false
    @State private var issueCode: String?
    @State private var status = ""
    @State private var page = 1
    @State private var working = false
    @State private var operation: Task<Void, Never>?
    @State private var operationId: UUID?
    private var unavailable: Bool { blocked || working || session == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Card(title: "Import and export reviews", subtitle: "Choose one Storebench CSV or JSON export, optionally gzipped. Preview additions and updates before saving. Previously saved reviews are kept.", help: "imports") {
                Text("Exports include all saved review text and this app's identity. Keep them private.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
                StorebenchActionGroup { fileActions }
                StorebenchTextSlot(text: chosen?.lastPathComponent ?? "No file selected", height: 36, font: .sbCallout, color: nil)
                StorebenchActionGroup { importActions }
                StorebenchTextSlot(text: status, height: 64, font: .sbCallout, color: StorebenchTheme.muted, live: true).accessibilityLabel("Review file operation status")
                RecoveryActions(code: issueCode)
                if let snapshot = saved?.snapshot {
                    Text("Checked \(snapshot.checkedAt.prefix(19).replacingOccurrences(of: "T", with: " ")) UTC. " + (snapshot.limited ? "Older reviews may be missing." : "This snapshot is not marked as limited.")).font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
                    if let full = snapshot.fullCheckedAt { Text("Last complete download: \(full.prefix(19).replacingOccurrences(of: "T", with: " ")) UTC.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted) }
                }
            }
            if let review {
                Card(title: "Review import changes", subtitle: "\(review.changes.added) added · \(review.changes.updated) updated · \(review.changes.unchanged) unchanged. No previously saved reviews are removed.") {
                    if stale { Text("Saved history or selected contents changed. Preview again to explicitly review the new baseline before saving.").foregroundStyle(StorebenchTheme.muted) }
                    StorebenchCollection(items: review.differences, title: { $0.label }, empty: "No review text changes.") { item in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(item.label).font(.sbHeadline)
                            comparison("Saved", item.before); comparison("After import", item.after)
                        }
                        StorebenchDivider()
                    }

                }
            }
        }
        .trackUnsavedChanges(chosen != nil || review != nil, busy: working)
        .task(id: "\(account.id):\(app.id)") { stop(); chosen = nil; review = nil; saved = nil; issueCode = nil; status = ""; stale = false; await load() }
        .task(id: refreshToken) { await load() }
        .onDisappear { operationId = nil; operation?.cancel(); operation = nil }
    }
    private var fileActions: some View {
        Group {
            Button("Choose Review File") { choose() }
            if !readFailed && saved?.snapshot != nil {
                Button("Export Reviews CSV") { export(.csv) }
                Button("Export Reviews JSON") { export(.json) }
            }
            Button("Read Saved Reviews") { run { _ in await load() } }
        }.storebenchWorking(unavailable)
    }
    private var importActions: some View {
        Group {
            Button("Preview Import") { run { id in await preview(id) } }.help("Preview Review Import").accessibilityLabel("Preview Review Import").storebenchWorking(unavailable).storebenchWorking(!(chosen != nil))
            Button("Save Reviewed Import") { if let review { run { id in await save(review, id) } } }.buttonStyle(StorebenchButtonStyle(.primary)).storebenchWorking(unavailable).storebenchWorking(!(review != nil && !stale))
            Button("Discard Import", role: .destructive) { guard !unavailable, EditorProtection.confirm(.confirmDiscard) else { return }; chosen = nil; review = nil; stale = false; issueCode = nil; status = "Import discarded. Saved reviews are kept." }.storebenchWorking(unavailable).storebenchWorking(!(chosen != nil))
            if working { Button("Stop File Operation") { stop() } }
        }
    }
    private func comparison(_ label: String, _ value: String) -> some View {
        StorebenchReadOnlyText(title: label, text: value, height: 120)
    }
    private func run(_ action: @escaping @MainActor (UUID) async -> Void) {
        guard !unavailable else { return }; let id = UUID(); operationId = id; working = true
        operation = Task { await action(id); if operationId == id { working = false; operationId = nil; operation = nil } }
    }
    private func stop() {
        guard working else { return }; operation?.cancel(); operation = nil; operationId = nil; working = false
        issueCode = nil; status = "Stopped waiting. Completed local saves are kept; read saved reviews before retrying."
    }
    private func choose() {
        guard !unavailable else { return }
        if chosen != nil || review != nil { guard EditorProtection.confirm(.confirmDiscard) else { return } }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.commaSeparatedText, .json, .gzip]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }; chosen = url; review = nil; stale = false; issueCode = nil; status = "Preview the chosen file before saving."
    }
    private func files() async throws -> [Data] { guard let chosen else { throw ReviewsFailure.format }; return try await ReportFiles.readAsync([chosen], purpose: .reports) }
    private func load() async {
        guard let session else { return }
        do { let value = try await session.savedReviewsFiles(account: account, appId: app.id); guard !Task.isCancelled else { return }; saved = value; readFailed = false }
        catch { if !Task.isCancelled { saved = nil; readFailed = true; issueCode = nil; status = "Saved reviews could not be verified. Existing history is kept." } }
    }
    private func preview(_ id: UUID) async {
        guard let session else { return }
        do {
            let input = try await files(); try Task.checkCancellation(); guard operationId == id else { return }
            let value = try await session.previewReviewsFile(account: account, appId: app.id, files: input)
            guard operationId == id, !Task.isCancelled else { return }; review = value; page = 1; stale = false; issueCode = nil; status = "Preview ready. Compare the saved and incoming text before saving locally."
        } catch { if operationId == id { review = nil; issueCode = RecoveryIssue.reviews(error); status = reviewsFileMessage(error) } }
    }
    private func save(_ value: ReviewsFileReview, _ id: UUID) async {
        guard let session else { return }
        do {
            let input = try await files(); try Task.checkCancellation(); guard operationId == id else { return }
            _ = try await session.saveReviewsFile(value, files: input)
            guard operationId == id else { return }; review = nil; chosen = nil; stale = false; issueCode = nil; status = "Reviewed changes saved locally. Previously saved reviews are kept."
            await load(); if operationId == id { await onChanged() }
        } catch { if operationId == id { stale = true; issueCode = RecoveryIssue.reviews(error); status = reviewsFileMessage(error) } }
    }
    private func export(_ format: ReviewsFileFormats.Format) {
        guard !unavailable else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [format == .json ? .json : .commaSeparatedText]; panel.nameFieldStringValue = "reviews-\(app.id).\(format == .json ? "json" : "csv")"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run { id in
            do { try await session?.writeReviewsFile(account: account, appId: app.id, format: format, to: url); if operationId == id { issueCode = nil; status = "Complete saved review snapshot exported. Keep this file private." } }
            catch { if operationId == id { issueCode = RecoveryIssue.reviews(error); status = reviewsFileMessage(error) } }
        }
    }
}

private func reviewsFileMessage(_ error: Error) -> String {
    if let value = error as? ReviewsFileFailure { return value.message }
    if let value = error as? ReportFiles.Failure { return value.message }
    if let value = error as? ReviewsFailure {
        switch value {
        case .format: return ReportingMessages.message("SB-REVIEWS-FORMAT")
        case .integrity: return ReportingMessages.message("SB-REVIEWS-INTEGRITY")
        case .scope: return ReportingMessages.message("SB-REVIEWS-SCOPE")
        case .stale: return ReportingMessages.message("SB-REVIEWS-STALE")
        default: return ReportingMessages.message("SB-REVIEWS-STORAGE")
        }
    }
    return "Review files could not be read or saved. Read the existing history and preview again before retrying."
}
