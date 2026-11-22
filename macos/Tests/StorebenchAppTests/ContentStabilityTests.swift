import AppKit
@testable import StorebenchCore
import SwiftUI
import Testing
@testable import StorebenchApp

/// What the user is looking at never jumps or flickers: content that changes above it, a step that is checked again, a row that is
/// resolved and every dialog keep the page, its rows and the dialog exactly where they were, in the first frame drawn after the change.
@MainActor @Suite(.serialized) struct ContentStabilityTests {
    init() throws { _ = try TestIsolation.require() }

    @MainActor final class Model: ObservableObject {
        /// Rows whose height changes, such as checklist rows while their step is checked again.
        @Published var changing: Set<Int> = []
        @Published var removed: Set<Int> = []
        @Published var grow = false
    }
    /// A page of cards and rows, like Release: every row is a shared action row, so the page knows what the user sees.
    struct Page: View {
        @ObservedObject var model: Model
        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(0..<40, id: \.self) { index in
                        if !model.removed.contains(index) {
                            StorebenchActionRow {
                                Text("Synthetic row \(index)").frame(maxWidth: .infinity, alignment: .leading)
                                    .frame(height: model.changing.contains(index) ? (model.grow ? 120 : 30) : 60, alignment: .top)
                            } actions: { EmptyView() }
                            .storebenchControlID("row.\(index)")
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { Color.gray.frame(height: 44) }
        }
    }

    private func window(_ view: some View, width: CGFloat = 700, height: CGFloat = 500) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.orderBack(nil)
        return window
    }
    private func close(_ window: NSWindow) { StorebenchScrollFocus.cancel(in: window); window.orderOut(nil); window.close() }
    private func settle(_ window: NSWindow, _ times: Int = 6) async throws {
        for _ in 0..<times { window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try await Task.sleep(for: .milliseconds(16)) }
    }
    /// One display pass, as AppKit draws the next frame: whatever it shows is what the user sees.
    private func drawNextFrame(_ window: NSWindow) { window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
    private func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews { if let found = scrollView(in: child) { return found } }
        return nil
    }
    private func marker(_ id: String, in view: NSView) -> NSView? {
        if (view as? StorebenchControlMarker)?.identifier?.rawValue == id { return view }
        for child in view.subviews { if let found = marker(id, in: child) { return found } }
        return nil
    }
    /// Where a row is on screen, measured from the top of the visible page.
    private func onScreen(_ id: String, _ window: NSWindow) throws -> CGFloat {
        let content = try #require(window.contentView), scroll = try #require(scrollView(in: content)), clip = scroll.contentView
        let row = try #require(marker(id, in: content), "\(id) is on the page"), rect = row.convert(row.bounds, to: clip)
        return clip.isFlipped ? rect.minY - clip.bounds.minY : clip.bounds.maxY - rect.maxY
    }
    private func userScroll(_ window: NSWindow, to y: CGFloat) throws {
        let content = try #require(window.contentView), scroll = try #require(scrollView(in: content)), clip = scroll.contentView
        clip.scroll(to: CGPoint(x: 0, y: y)); scroll.reflectScrolledClipView(clip)
    }

    @Test func rowsThatShrinkAboveTheViewLeaveWhatTheUserSeesInPlaceFromTheFirstFrame() async throws {
        let model = Model(), window = window(Page(model: model)); defer { close(window) }
        try await settle(window)
        try userScroll(window, to: 1_400); try await settle(window)
        let watched = "row.22", before = try onScreen(watched, window)
        #expect(before > 0 && before < 400, "The watched row is in view: \(before)")
        let root = try #require(window.contentView), page = try #require(scrollView(in: root)), anchoring = StorebenchScrollAnchoring.controller(for: page)
        #expect(anchoring.marked >= 40, "Every row joined its page: \(anchoring.marked)")
        // Rows above the view lose their commands for a moment, as checklist rows did while their step was checked.
        model.changing = Set(0..<10); drawNextFrame(window)
        let first = try onScreen(watched, window)
        #expect(abs(first - before) < 0.5, "First frame after the change: \(first) instead of \(before)")
        try await settle(window)
        #expect(abs(try onScreen(watched, window) - before) < 0.5)
        #expect(anchoring.corrections > 0, "The page was held by moving it, not left alone")
        // They come back: still no movement.
        model.changing = []; drawNextFrame(window)
        #expect(abs(try onScreen(watched, window) - before) < 0.5)
        try await settle(window)
        #expect(abs(try onScreen(watched, window) - before) < 0.5)
    }

    @Test func rowsThatGrowOrAreRemovedAboveTheViewDoNotPushThePage() async throws {
        let model = Model(), window = window(Page(model: model)); defer { close(window) }
        try await settle(window)
        try userScroll(window, to: 1_400); try await settle(window)
        let watched = "row.22", before = try onScreen(watched, window)
        model.grow = true; model.changing = [2, 4, 6]; drawNextFrame(window)
        #expect(abs(try onScreen(watched, window) - before) < 0.5)
        // A resolved row above the view is removed.
        model.removed = [3, 5]; drawNextFrame(window)
        #expect(abs(try onScreen(watched, window) - before) < 0.5)
        try await settle(window)
        #expect(abs(try onScreen(watched, window) - before) < 0.5)
    }

    @Test func theRowTheUserSeesCanChangeWithoutMovingThePage() async throws {
        let model = Model(), window = window(Page(model: model)); defer { close(window) }
        try await settle(window)
        try userScroll(window, to: 1_400); try await settle(window)
        let content = try #require(window.contentView), clip = try #require(scrollView(in: content)).contentView
        let origin = clip.bounds.minY, first = try onScreen("row.20", window), next = try onScreen("row.26", window)
        // Rows in view open downward, like a disclosure: the page stays, the rows under them move down.
        model.grow = true; model.changing = [22]; try await settle(window)
        let firstNow = try onScreen("row.20", window)
        #expect(abs(clip.bounds.minY - origin) < 0.5 && abs(firstNow - first) < 0.5)
        #expect(try onScreen("row.26", window) > next + 50)
    }

    @Test func aPageAtItsTopStaysAtItsTop() async throws {
        let model = Model(), window = window(Page(model: model)); defer { close(window) }
        try await settle(window)
        let content = try #require(window.contentView), clip = try #require(scrollView(in: content)).contentView
        let top = clip.bounds.minY
        model.changing = [0, 1]; drawNextFrame(window); try await settle(window)
        #expect(abs(clip.bounds.minY - top) < 0.5, "The page left its top: \(clip.bounds.minY)")
        model.grow = true; try await settle(window)
        #expect(abs(clip.bounds.minY - top) < 0.5)
    }

    @Test func aNewScrollByTheUserSetsWhatIsKeptInPlace() async throws {
        let model = Model(), window = window(Page(model: model)); defer { close(window) }
        try await settle(window)
        try userScroll(window, to: 1_400); try await settle(window)
        model.changing = Set(0..<5); try await settle(window)
        try userScroll(window, to: 900); try await settle(window)
        let watched = "row.17", before = try onScreen(watched, window)
        model.changing = Set(0..<10); drawNextFrame(window)
        #expect(abs(try onScreen(watched, window) - before) < 0.5)
        try await settle(window)
        #expect(abs(try onScreen(watched, window) - before) < 0.5)
    }

    @MainActor final class ChecklistModel: ObservableObject { @Published var rows = Array(0..<8) }
    /// Release's step card: a heading, its checklist rows, then the cards below it.
    struct ChecklistPage: View {
        @ObservedObject var model: ChecklistModel
        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Synthetic page heading").frame(maxWidth: .infinity, alignment: .leading).frame(height: 300)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Synthetic step heading").frame(height: 200)
                        ForEach(model.rows, id: \.self) { row in
                            StorebenchActionRow { Text("Synthetic choice \(row)").frame(height: 60) } actions: { EmptyView() }.storebenchControlID("choice.\(row)")
                        }
                    }.storebenchScrollAnchor()
                    Text("Synthetic sync card").frame(maxWidth: .infinity, alignment: .leading).frame(height: 300).storebenchScrollAnchor().storebenchControlID("below")
                    ForEach(0..<6, id: \.self) { Text("Synthetic card \($0)").frame(height: 100).storebenchScrollAnchor() }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
        }
    }

    /// Removing what is in view, such as a resolved row or a removed language, never scrolls the page: what is above stays,
    /// what is below moves up into the gap, as in Mail or Finder.
    @Test func removingWhatIsInViewMovesTheContentBelowUpWithoutScrollingThePage() async throws {
        let model = ChecklistModel(), window = window(ChecklistPage(model: model)); defer { close(window) }
        try await settle(window)
        try userScroll(window, to: 900); try await settle(window)
        let root = try #require(window.contentView), clip = try #require(scrollView(in: root)).contentView
        let origin = clip.bounds.minY, removed = try onScreen("choice.5", window), above = try onScreen("choice.4", window)
        #expect(removed >= -1 && removed < 100, "The first choice in view: \(removed)")
        // The first choice in view is resolved: the one above stays, the next one takes its place.
        model.rows.removeAll { $0 == 5 }; drawNextFrame(window)
        let next = try onScreen("choice.6", window), aboveNow = try onScreen("choice.4", window)
        #expect(abs(clip.bounds.minY - origin) < 0.5 && abs(aboveNow - above) < 0.5 && abs(next - removed) < 0.5,
                "Page \(clip.bounds.minY) from \(origin); above \(aboveNow) from \(above); next \(next) in place of \(removed)")
        // Every remaining choice is resolved at once; the page still does not move.
        let below = try onScreen("below", window)
        model.rows = []; drawNextFrame(window); try await settle(window)
        #expect(abs(clip.bounds.minY - origin) < 0.5, "The page stayed: \(clip.bounds.minY) from \(origin)")
        #expect(try onScreen("below", window) < below - 100, "The card below moved up into the gap")
    }

    // MARK: Release checklist

    private func step(issues: [ReleaseMaterial.Issue]) -> ReleaseReadiness.Step {
        ReleaseReadiness.Step(id: "localization:en-GB", label: "English (U.K.) (en-GB) · Version text", detail: "Synthetic detail", href: "", action: "Open",
                              state: .blocked, territories: nil, guideHref: nil, issues: issues)
    }
    private func appleChange(_ field: String) -> ReleaseMaterial.Issue {
        var issue = ReleaseMaterial.Issue(field: field, message: "\(field) was changed in App Store Connect after your draft took its text.", section: ReleaseMaterial.changedAtApple)
        issue.localizationId = "synthetic-locale"; issue.scope = .version; issue.apple = "Synthetic newer text at Apple"; issue.base = "Synthetic text"; issue.mine = "Synthetic text"
        return issue
    }

    @Test func checklistRowsKeepTheirHeightAndCommandsWhileTheStepIsCheckedAgain() async throws {
        let steps = [step(issues: [appleChange("description"), appleChange("promotionalText")])]
        func list(_ ready: Bool) -> some View {
            ReleaseCheckList(steps: steps, ready: ready, open: { _ in }, fix: { _, _ in }, resolve: { _, _, _ in })
                .frame(width: 1_100).environment(\.workspaceWidth, 1_400).environment(\.workspaceHeight, 900)
        }
        let ready = NSHostingView(rootView: list(true)), checking = NSHostingView(rootView: list(false))
        for view in [ready, checking] { view.frame.size = view.fittingSize; view.layoutSubtreeIfNeeded() }
        #expect(abs(ready.fittingSize.height - checking.fittingSize.height) < 0.5, "Ready \(ready.fittingSize.height), checking \(checking.fittingSize.height)")
        for id in ["release.issue.use-apple.description", "release.issue.keep-mine.description", "release.issue.view-changes.description"] {
            let shown = try #require(marker(id, in: ready)), waiting = try #require(marker(id, in: checking), "\(id) stays while checking")
            #expect(shown.convert(shown.bounds, to: ready) == waiting.convert(waiting.bounds, to: checking), "\(id) stays in place")
        }
        // While checking, View Changes stays available; the choices wait in place.
        #expect((try #require(marker("release.issue.view-changes.description", in: checking)) as? StorebenchControlMarker)?.available == true)
    }

    // MARK: Dialogs

    @Test func theComparisonShowsBothTextsSideBySide() async throws {
        let issue = appleChange("description")
        let window = window(ReleaseTextComparisonView(language: "English (U.K.) (en-GB)", issue: issue, choose: { _ in }, close: {})
            .environment(\.workspaceWidth, 1_400).environment(\.workspaceHeight, 900), width: 1_400, height: 900)
        defer { close(window) }
        try await settle(window)
        let content = try #require(window.contentView)
        let mine = try #require(marker("release.compare.mine", in: content)), apple = try #require(marker("release.compare.apple", in: content))
        let left = mine.convert(mine.bounds, to: content), right = apple.convert(apple.bounds, to: content)
        #expect(abs(left.minY - right.minY) < 0.5 && abs(left.height - right.height) < 0.5, "Both panels share one row: \(left) \(right)")
        #expect(left.maxX <= right.minX && left.width > 300 && abs(left.width - right.width) < 1)
        #expect(marker("release.compare.keep", in: content) != nil && marker("release.compare.use", in: content) != nil)
    }

    @MainActor final class DialogModel: ObservableObject {
        @Published var lines = 1
        @Published var busy = false
        @Published var status = ""
    }
    struct Dialog: View {
        @ObservedObject var model: DialogModel
        var body: some View {
            StorebenchDialog(title: "Synthetic Dialog", kind: .form, subtitle: "Synthetic subtitle", busy: model.busy, close: {}) {
                ForEach(0..<model.lines, id: \.self) { Text("Synthetic line \($0)").frame(height: 28) }
                StorebenchFeedback(text: model.status, height: 40)
            } actions: {
                StorebenchActionGroup(alignment: .trailing) {
                    StorebenchCommand(title: "Synthetic Save", busy: model.busy, unavailable: nil) {}.storebenchControlID("dialog.synthetic.save")
                }
            }
            .environment(\.workspaceWidth, 1_200).environment(\.workspaceHeight, 800)
        }
    }

    @Test func aDialogKeepsItsSizeAndCommandsWhateverItsContentDoes() async throws {
        let model = DialogModel(), window = window(Dialog(model: model), width: 1_200, height: 800); defer { close(window) }
        try await settle(window)
        let content = try #require(window.contentView)
        let size = content.fittingSize, save = try #require(marker("dialog.synthetic.save", in: content))
        let place = save.convert(save.bounds, to: content)
        for change in [{ model.lines = 40 }, { model.busy = true }, { model.status = "Synthetic status that is long enough to need two lines of the reserved feedback track." }, { model.busy = false; model.lines = 0 }] {
            change(); drawNextFrame(window)
            #expect(content.fittingSize == size, "The dialog changed size: \(content.fittingSize) from \(size)")
            #expect(save.convert(save.bounds, to: content) == place, "Its command moved")
        }
    }

    /// Every sheet in the app is the shared dialog, whose size is fixed by the window and whose body scrolls inside it, so no
    /// dialog changes size or moves its commands when its content changes, and its scrolled body keeps its content in place.
    @Test func everySheetInTheAppIsTheSharedFixedSizeDialog() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/StorebenchApp")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)).compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(files.count > 50, "The app's sources are readable: \(sources.path)")
        let texts = try Dictionary(uniqueKeysWithValues: files.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) })
        /// The source of a type, property or function by name, up to the next declaration at the same level.
        func declaration(_ name: String, in text: String? = nil) -> String? {
            let patterns = ["struct \(name)\\b", "var \(name)\\b", "func \(name)\\b"]
            for source in text.map({ [$0] }) ?? Array(texts.values) {
                for pattern in patterns {
                    guard let range = source.range(of: pattern, options: .regularExpression) else { continue }
                    let rest = source[range.lowerBound...]
                    let end = rest.dropFirst().range(of: "\n(private |fileprivate )?(struct|final class|enum|extension) ", options: .regularExpression)?.lowerBound ?? rest.endIndex
                    return String(rest[..<end])
                }
            }
            return nil
        }
        func isDialog(_ source: String, depth: Int = 0, in file: String) -> Bool {
            if source.contains("StorebenchDialog(") { return true }
            guard depth < 2 else { return false }
            let calls = try! Regex("([A-Za-z][A-Za-z0-9]*)\\("), properties = try! Regex("\\{\\s*([a-z][A-Za-z0-9]*)\\s*\\}")
            let names = (source.matches(of: calls) + source.matches(of: properties)).compactMap { $0.output[1].substring.map(String.init) }
            for name in Set(names) where !["if", "Binding", "Task", "await", "try"].contains(name) {
                let found = name.first!.isUppercase ? declaration(name) : declaration(name, in: file)
                if let found, isDialog(found, depth: depth + 1, in: file) { return true }
            }
            return false
        }
        var sheets = 0, failures: [String] = []
        for (name, text) in texts {
            var rest = Substring(text)
            while let range = rest.range(of: ".sheet(") {
                sheets += 1
                // The presented content: the sheet's closure, from its opening brace to the matching closing one.
                var presented = "", parentheses = 1, depth = 0
                for character in rest[range.upperBound...] {
                    // The sheet's own arguments, such as a Binding with closures, come first and are skipped.
                    if parentheses > 0 { if character == "(" { parentheses += 1 } else if character == ")" { parentheses -= 1 }; continue }
                    if character == "{" { depth += 1 } else if character == "}" { depth -= 1 }
                    if depth > 0 || character == "}" { presented.append(character) }
                    if depth == 0 && character == "}" { break }
                }
                if !isDialog(presented, in: text) { failures.append(name + ": " + presented.prefix(80)) }
                rest = rest[range.upperBound...]
            }
        }
        #expect(sheets >= 20, "Found \(sheets) sheets")
        #expect(failures.isEmpty, "Sheets not built on StorebenchDialog: \(failures)")
    }
}
