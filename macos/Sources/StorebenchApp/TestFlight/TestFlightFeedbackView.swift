import ImageIO
import StorebenchCore
import SwiftUI
import UniformTypeIdentifiers

/// Separate feedback pages retain independent cursors and errors. The builds name each submission's build; they are read here when not given.
struct TestFlightFeedbackView: View {
    let account: Account, app: Account.App, session: WorkspaceSession?
    var builds: [TestFlightBuild]? = nil
    @State private var read: [TestFlightBuild] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(TestFlightFeedback.Kind.allCases, id: \.self) { kind in
                FeedbackSection(account: account, app: app, session: session, kind: kind, builds: builds ?? read).id("\(account.id):\(app.id):\(kind.rawValue)")
            }
        }
        .task {
            guard builds == nil, let session else { return }
            read = (try? await session.testFlightBuilds(account: account, appId: app.id)) ?? []
        }
    }
}

private struct FeedbackSection: View {
    let account: Account, app: Account.App, session: WorkspaceSession?, kind: TestFlightFeedback.Kind
    let builds: [TestFlightBuild]
    @State private var page: TestFlightFeedback.Page?
    @State private var cursor: String?
    @State private var loading = false
    @State private var error = ""
    @Environment(\.navigationPresentation) private var history
    private var readKey: String { "testflight-feedback/\(account.id)/\(app.id)/\(kind.rawValue)/\(cursor ?? "")" }

    var body: some View {
        Card(title: kind.title, subtitle: kind == .screenshot ? "Written feedback submitted with tester screenshots." : "Tester comments submitted with crash reports.") {
            if loading && page == nil { ProgressView("Reading feedback…") }
            else if !error.isEmpty { Text(error).foregroundStyle(StorebenchTheme.muted) }
            else if let page {
                StorebenchCollection(items: page.submissions, title: { $0.device }, subtitle: { $0.createdDate }, empty: cursor == nil ? "Apple has no recent \(kind.rawValue) feedback for this app." : "No \(kind.rawValue) feedback on this page. Return to the first page to check newer submissions.") { submission in
                    FeedbackSubmissionView(account: account, app: app, session: session, submission: submission, build: builds.first { $0.id == submission.buildId }).id("\(submission.id):\(cursor ?? "first")")
                    StorebenchDivider()
                }
            }
            ViewThatFits {
                HStack(spacing: 12) { pageActions }
                VStack(alignment: .leading, spacing: 12) { pageActions }
            }
        }
        .task(id: cursor) {
            // Back returns to the same feedback page; the page last read shows while it is read again.
            page = history?.rememberedRead(readKey, as: TestFlightFeedback.Page.self)
            await load()
        }
        .historyValue("feedback-page", $cursor)
    }
    @ViewBuilder private var pageActions: some View {
        Button("Refresh First Page") { if cursor == nil { Task { await load() } } else { cursor = nil } }.storebenchWorking(loading)
        if cursor != nil { Button("First Page") { cursor = nil }.storebenchWorking(loading) }
        if let next = page?.next { Button("Older Feedback") { cursor = next }.storebenchWorking(loading) }
    }
    private func load() async {
        guard let session, !loading else { return }
        let requestedCursor = cursor
        loading = true; defer { loading = false }
        do {
            let loaded = try await session.testFlightFeedback(appId: app.id, kind: kind, cursor: requestedCursor, client: try await session.client(for: account))
            try Task.checkCancellation()
            guard cursor == requestedCursor else { return }
            page = loaded; error = ""; history?.rememberRead(loaded, readKey)
        } catch is CancellationError { return }
        catch { page = nil; self.error = "Feedback could not be read from Apple. Refresh to try again." }
    }
}

private struct FeedbackDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
private struct FeedbackImage: Identifiable {
    let id: Int, bytes: Data, type: String
    var thumbnail: CGImage? {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2048, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
    }
}

private struct FeedbackSubmissionView: View {
    let account: Account, app: Account.App, session: WorkspaceSession?, submission: TestFlightFeedback.Submission
    let build: TestFlightBuild?
    @State private var image: FeedbackImage?
    @State private var export: FeedbackDocument?
    @State private var exporting = false
    @State private var working = false
    @State private var status = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(build.map { "Build \($0.version)" } ?? "Build details unavailable").font(.sbHeadline).lineLimit(2).textSelection(.enabled)
            Text([createdDate, submission.device, submission.os].joined(separator: " · ")).font(.sbCaption).foregroundStyle(StorebenchTheme.muted).lineLimit(3)
            ScrollView { Text(submission.comment).font(.sbCallout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 120)
            if submission.kind == .screenshot {
                if submission.images.isEmpty { Text("No screenshot image is available for this submission.").font(.sbCaption).foregroundStyle(StorebenchTheme.muted) }
                else {
                    ScrollView(.horizontal) {
                        HStack { ForEach(submission.images.indices, id: \.self) { index in
                            Button("View screenshot \(index + 1)") { Task { await loadImage(index) } }.storebenchWorking(working)
                        } }
                    }.frame(height: 36)
                }
            } else { Button("Download Crash Log") { Task { await loadLog() } }.storebenchWorking(working) }
            VStack(alignment: .leading) {
                if working { ProgressView("Reading attachment…") }
                StorebenchFeedback(text: status, height: 34)
            }.frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
        }
        .trackUnsavedChanges(false, busy: working)
        .sheet(item: $image) { selected in imageViewer(selected) }
        .fileExporter(isPresented: $exporting, document: export, contentType: .plainText, defaultFilename: "testflight-crash-log.txt") { result in
            status = (try? result.get()) == nil ? "" : "Crash log exported."
            export = nil
        }
    }
    private var createdDate: String {
        guard !submission.createdDate.isEmpty, let date = try? TestFlightFeedbackDate.utc(submission.createdDate) else { return "Date unavailable" }; return date
    }
    private func loadImage(_ index: Int) async {
        guard let session, !working else { return }
        working = true; status = ""; defer { working = false }
        do {
            let file = try await session.testFlightFeedbackImage(appId: app.id, submissionId: submission.id, index: index, client: try await session.client(for: account))
            image = FeedbackImage(id: index, bytes: file.bytes, type: file.contentType)
        } catch { status = "The screenshot is unavailable, expired or could not be verified. Refresh feedback to check it again." }
    }
    private func loadLog() async {
        guard let session, !working else { return }
        working = true; status = ""; defer { working = false }
        do { export = FeedbackDocument(data: try await session.testFlightCrashLog(appId: app.id, submissionId: submission.id, client: try await session.client(for: account))); exporting = true }
        catch { status = "The crash log could not be read for this app." }
    }
    private func imageViewer(_ selected: FeedbackImage) -> some View {
        FeedbackImageViewer(file: selected)
    }
}

private enum TestFlightFeedbackDate {
    static func utc(_ value: String) throws -> String {
        let fractional = ISO8601DateFormatter(), plain = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fractional.date(from: value) ?? plain.date(from: value) else { throw TestFlightFeedback.Failure.page }
        plain.timeZone = TimeZone(secondsFromGMT: 0)
        return plain.string(from: date).replacingOccurrences(of: "T", with: " ").replacingOccurrences(of: "Z", with: " UTC")
    }
}

private struct FeedbackImageViewer: View {
    let file: FeedbackImage
    @Environment(\.dismiss) private var dismiss
    @State private var exporting = false
    var body: some View {
        StorebenchDialog(title: "Tester screenshot \(file.id + 1)", wide: true, height: 760, scrollBody: false, media: true, close: { dismiss() }) {
            if let image = file.thumbnail { Image(decorative: image, scale: 1).resizable().scaledToFit().accessibilityLabel("Tester screenshot \(file.id + 1)") }
            else { Text("The screenshot could not be decoded.").foregroundStyle(StorebenchTheme.muted) }
        } actions: {
            StorebenchActionGroup(alignment: .trailing) { Button("Save Screenshot") { exporting = true }; Button("Close") { dismiss() } }
        }
            .fileExporter(isPresented: $exporting, document: FeedbackDocument(data: file.bytes), contentType: file.type == "image/png" ? .png : .jpeg, defaultFilename: file.type == "image/png" ? "testflight-feedback.png" : "testflight-feedback.jpg") { _ in }
    }
}
