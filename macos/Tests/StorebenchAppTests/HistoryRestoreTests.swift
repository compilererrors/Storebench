import AppKit
@testable import StorebenchCore
import Testing
@testable import StorebenchApp

/// Back and Forward show a page where the user left it from the first frame drawn: never its top first and then a jump,
/// even when the page's content arrives a moment later.
@MainActor @Suite(.serialized) struct HistoryRestoreTests {
    init() throws { _ = try TestIsolation.require() }

    @MainActor private final class Document: NSView { override var isFlipped: Bool { true } }
    @MainActor private final class Page {
        let window: NSWindow, scroll: NSScrollView, document: NSView
        init(height: CGFloat) {
            _ = NSApplication.shared
            window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 700, height: 500))
            scroll.hasVerticalScroller = true
            document = Document(frame: CGRect(x: 0, y: 0, width: 680, height: height))
            scroll.documentView = document; window.contentView = scroll
            window.orderBack(nil)
        }
        var offset: CGFloat { scroll.contentView.bounds.minY }
        func draw() { window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
        func close() { window.orderOut(nil); window.close() }
    }
    private func returning(to page: Page, offset: CGFloat) -> (StorebenchScrollCheckpoint.CheckpointView, NavigationPresentation, UUID) {
        let history = NavigationPresentation(), entry = UUID()
        history.save(CGPoint(x: 0, y: offset), for: entry)
        let checkpoint = StorebenchScrollCheckpoint.CheckpointView(frame: .zero)
        page.document.addSubview(checkpoint)
        checkpoint.configure(.init(store: history, entry: entry))
        return (checkpoint, history, entry)
    }

    @Test func backShowsTheSavedPositionInTheFirstFrame() async throws {
        let page = Page(height: 4_000); defer { page.close() }
        let (checkpoint, _, _) = returning(to: page, offset: 1_800); defer { checkpoint.retire() }
        page.draw()
        #expect(abs(page.offset - 1_800) < 0.5, "First frame after Back: \(page.offset)")
    }

    @Test func contentThatArrivesLateAppearsWhereTheUserLeftItWithoutShowingTheTopFirst() async throws {
        // The page first draws only its frame, as before its saved reads are shown, then its content arrives.
        let page = Page(height: 600); defer { page.close() }
        let insets = page.scroll.contentView.contentInsets
        let (checkpoint, history, entry) = returning(to: page, offset: 1_800); defer { checkpoint.retire() }
        page.draw()
        #expect(abs(page.offset - 1_800) < 0.5, "Before the content arrives: \(page.offset)")
        var seen: [CGFloat] = []
        for step in 1...5 {
            page.document.setFrameSize(CGSize(width: 680, height: 600 + CGFloat(step) * 700)); page.draw(); seen.append(page.offset)
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(seen.allSatisfy { abs($0 - 1_800) < 0.5 }, "While the content arrives: \(seen)")
        // Once the content is there, the page scrolls normally again: no room is left reserved below it.
        try await Task.sleep(for: .milliseconds(100)); page.draw()
        #expect(page.scroll.contentView.contentInsets.bottom == insets.bottom && abs(page.offset - 1_800) < 0.5)
        #expect(abs(history.offset(entry).y - 1_800) < 0.5)
    }

    @Test func scrollingWhileTheContentArrivesKeepsTheUsersPosition() async throws {
        let page = Page(height: 600); defer { page.close() }
        let insets = page.scroll.contentView.contentInsets
        let (checkpoint, history, entry) = returning(to: page, offset: 1_800); defer { checkpoint.retire() }
        page.draw()
        // The user scrolls up before the content arrives: their scroll wins and nothing pulls the page back.
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: page.scroll)
        page.scroll.contentView.scroll(to: CGPoint(x: 0, y: 200)); page.scroll.reflectScrolledClipView(page.scroll.contentView)
        page.document.setFrameSize(CGSize(width: 680, height: 4_000)); page.draw()
        try await Task.sleep(for: .milliseconds(100)); page.draw()
        #expect(abs(page.offset - 200) < 0.5, "The user's scroll is kept: \(page.offset)")
        #expect(page.scroll.contentView.contentInsets.bottom == insets.bottom)
        #expect(abs(history.offset(entry).y - 200) < 0.5)
    }

    private func session() throws -> WorkspaceSession {
        let owned = try TestIsolation.require(), root = owned.appendingPathComponent("history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("state-v2"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.copyItem(at: owned.appendingPathComponent("native-fixtures/storebench-v2.sqlite"), to: EncryptedDocumentStore.databaseURL(root: root))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: EncryptedDocumentStore.databaseURL(root: root).path)
        let key = Data(0..<32).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let record = JSONText.object([("schemaVersion", .number(1)), ("phase", .string("ready")), ("envelope", .object([("version", .number(1)), ("mode", .string("device")), ("key", .string(key))]))])
        let data = JSONText.object([("version", .number(1)), ("entries", .object([(CredentialVault.databaseEntry(root: root), .string(record.stringify()))]))]).data
        return try WorkspaceSession(workspace: Workspace(root: root), vault: CredentialVault(json: data))
    }

    /// Coming back to the Overview shows the release cards as they were, at once, rather than reading their layout again first.
    @Test func theOverviewsReleaseCardsAreKeptInMemoryBetweenVisits() async throws {
        let session = try session()
        let first = ReleaseCardsEditor.shared(for: session)
        await first.load()
        #expect(first.preferences != nil)
        let again = ReleaseCardsEditor.shared(for: session)
        #expect(again === first && again.preferences != nil, "The second visit reuses the read cards")
        #expect(ReleaseCardsEditor.shared(for: try self.session()) !== first, "Another session never sees them")
    }
}
