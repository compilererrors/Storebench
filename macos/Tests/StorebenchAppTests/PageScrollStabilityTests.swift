import AppKit
import StorebenchCore
import SwiftUI
import Testing
@testable import StorebenchApp

/// A SwiftUI page like Release: a scroll view with a bottom bar, a disclosure that closes, and status text that keeps updating.
/// The page must stay exactly where the user scrolled it.
@MainActor @Suite(.serialized) struct PageScrollStabilityTests {
    init() throws { _ = try TestIsolation.require() }

    @MainActor final class Model: ObservableObject {
        @Published var expanded = true
        @Published var tick = 0
    }
    struct Page: View {
        @ObservedObject var model: Model
        let focus: StorebenchScrollFocus
        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(0..<40, id: \.self) { Text("Synthetic step \($0)").frame(height: 30) }
                    Text("Synthetic disclosure").frame(height: 30).background(StorebenchScrollFocusAnchor(focus: focus))
                    if model.expanded { ForEach(0..<40, id: \.self) { Text("Synthetic detail \($0)").frame(height: 30) } }
                    // Release keeps checking App Store Connect, so its status text updates while the user scrolls.
                    Text("Synthetic status \(model.tick)").frame(height: 20)
                    ForEach(0..<6, id: \.self) { Text("Synthetic footer \($0)").frame(height: 30) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { Color.gray.frame(height: 44) }
        }
    }

    private func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews { if let found = scrollView(in: child) { return found } }
        return nil
    }
    private func settle(_ window: NSWindow, _ times: Int = 6) async throws {
        for _ in 0..<times { window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try await Task.sleep(for: .milliseconds(16)) }
    }

    @Test func thePageStaysWhereTheUserScrollsAfterADisclosureClosesWhileStatusKeepsUpdating() async throws {
        _ = NSApplication.shared
        let model = Model(), focus = StorebenchScrollFocus()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { StorebenchScrollFocus.cancel(in: window); window.orderOut(nil); window.close() }
        window.contentView = NSHostingView(rootView: Page(model: model, focus: focus))
        window.orderBack(nil)
        try await settle(window)
        let content = try #require(window.contentView)
        let scroll = try #require(scrollView(in: content))
        let clip = scroll.contentView, original = clip.contentInsets, automatic = clip.automaticallyAdjustsContentInsets
        func userScroll(to y: CGFloat) { clip.scroll(to: CGPoint(x: 0, y: y)); scroll.reflectScrolledClipView(clip) }

        // Near the bottom of the open disclosure, the user closes it; the page keeps the header where it was.
        userScroll(to: 2_300); try await settle(window)
        focus.preserving { model.expanded = false }
        try await Task.sleep(for: .milliseconds(1_800)); try await settle(window)
        // The user's next input ends the placement, as the app's input monitor does.
        StorebenchScrollFocus.cancel(in: window)

        // Then the user scrolls; every position must hold while the status text keeps updating.
        var drift: [String] = []
        for target in [1_400, 900, 400, 120, 0, 300] as [CGFloat] {
            userScroll(to: target); try await settle(window, 2)
            let reached = clip.bounds.minY
            for _ in 0..<8 { model.tick += 1; try await settle(window, 1) }
            if abs(clip.bounds.minY - reached) > 0.5 { drift.append("asked \(target), reached \(reached), moved to \(clip.bounds.minY)") }
        }
        #expect(drift.isEmpty, "The page moved on its own: \(drift)")
        // Once the user is back in ordinary range, the page's own insets are restored.
        #expect(clip.contentInsets.top == original.top && clip.contentInsets.bottom == original.bottom && clip.automaticallyAdjustsContentInsets == automatic,
                "Insets \(clip.contentInsets) instead of \(original); automatic \(clip.automaticallyAdjustsContentInsets) instead of \(automatic)")
    }

    @Test func statusUpdatesAloneNeverMoveAPageTheUserScrolled() async throws {
        _ = NSApplication.shared
        let model = Model(), focus = StorebenchScrollFocus()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.close() }
        window.contentView = NSHostingView(rootView: Page(model: model, focus: focus))
        window.orderBack(nil)
        try await settle(window)
        let content = try #require(window.contentView)
        let scroll = try #require(scrollView(in: content)), clip = scroll.contentView
        clip.scroll(to: CGPoint(x: 0, y: 1_000)); scroll.reflectScrolledClipView(clip); try await settle(window)
        let reached = clip.bounds.minY
        for _ in 0..<20 { model.tick += 1; try await settle(window, 1) }
        #expect(abs(clip.bounds.minY - reached) < 0.5, "Moved from \(reached) to \(clip.bounds.minY)")
    }

    @MainActor final class FocusModel: ObservableObject {
        @Published var busy = false
        @Published var ticket: UUID?
        @Published var text = "Synthetic description"
        @Published var shown = true
    }
    /// A Release-like page: a field that was asked to take focus, such as after Edit on a language problem, among many others,
    /// while saves and status checks make the page busy for a moment now and then.
    struct FocusPage: View {
        @ObservedObject var model: FocusModel
        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(0..<30, id: \.self) { Text("Synthetic step \($0)").frame(height: 30) }
                    if model.shown { StorebenchTextField("Synthetic Description", text: $model.text).requestFocus(model.ticket) }
                    else { Text("Reading saved language text…").frame(height: 52) }
                    ForEach(0..<60, id: \.self) { Text("Synthetic field \($0)").frame(height: 30) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                .disabled(model.busy)
            }
        }
    }

    @Test func aFieldThatAskedForFocusDoesNotPullThePageBackEachTimeThePageStopsBeingBusy() async throws {
        _ = NSApplication.shared
        let model = FocusModel()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { StorebenchScrollFocus.cancel(in: window); window.orderOut(nil); window.close() }
        window.contentView = NSHostingView(rootView: FocusPage(model: model))
        window.orderBack(nil)
        try await settle(window)
        let content = try #require(window.contentView)
        let scroll = try #require(scrollView(in: content)), clip = scroll.contentView
        // The request brings the field into view once.
        model.ticket = UUID()
        try await Task.sleep(for: .milliseconds(600)); try await settle(window)
        let revealed = clip.bounds.minY
        #expect(revealed > 400, "The requested field was not brought into view: \(revealed)")
        // The user scrolls away, which ends the placement as the app's input monitor does.
        StorebenchScrollFocus.cancel(in: window)
        clip.scroll(to: CGPoint(x: 0, y: 2_000)); scroll.reflectScrolledClipView(clip); try await settle(window)
        let scrolled = clip.bounds.minY
        // Saving and checking make the page busy and then ready again, several times.
        var positions: [CGFloat] = []
        for _ in 0..<4 {
            model.busy = true; try await settle(window, 3)
            model.busy = false; try await Task.sleep(for: .milliseconds(300)); try await settle(window, 3)
            positions.append(clip.bounds.minY)
        }
        #expect(positions.allSatisfy { abs($0 - scrolled) < 0.5 }, "The page went back to the field: scrolled to \(scrolled), then \(positions)")
    }

    @Test func aFieldShownAgainAfterItsEditorReloadsDoesNotPullThePageBack() async throws {
        _ = NSApplication.shared
        let model = FocusModel()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { StorebenchScrollFocus.cancel(in: window); window.orderOut(nil); window.close() }
        window.contentView = NSHostingView(rootView: FocusPage(model: model))
        window.orderBack(nil)
        try await settle(window)
        let content = try #require(window.contentView)
        let scroll = try #require(scrollView(in: content)), clip = scroll.contentView
        model.ticket = UUID()
        try await Task.sleep(for: .milliseconds(600)); try await settle(window)
        StorebenchScrollFocus.cancel(in: window)
        clip.scroll(to: CGPoint(x: 0, y: 2_000)); scroll.reflectScrolledClipView(clip); try await settle(window)
        let scrolled = clip.bounds.minY
        // The editor reloads: its field is replaced by a loading line and then shown again, with the same request.
        var positions: [CGFloat] = []
        for _ in 0..<3 {
            model.shown = false; try await settle(window, 3)
            model.shown = true; try await Task.sleep(for: .milliseconds(300)); try await settle(window, 3)
            positions.append(clip.bounds.minY)
        }
        #expect(positions.allSatisfy { abs($0 - scrolled) < 0.5 }, "The page went back to the field: scrolled to \(scrolled), then \(positions)")
        // A new request, as from a second Edit, still brings the field into view.
        model.ticket = UUID()
        try await Task.sleep(for: .milliseconds(600)); try await settle(window)
        #expect(clip.bounds.minY < scrolled - 200, "A new request did not bring the field into view: \(clip.bounds.minY)")
    }

    @MainActor final class Draws { var count = 0; var report: (() -> Void)? }
    /// A page shaped like the app workspace: it records each scroll step for its own placements and hands the recorder down.
    struct InteractionPage: View {
        let draws: Draws
        @State private var interactions = StorebenchPageInteractions()
        var body: some View {
            draws.count += 1
            return InteractionChild(draws: draws).environment(\.pageFocusInteraction, { interactions.record() })
        }
    }
    /// Stands in for the page's scroll observer, which calls the recorder on every wheel step.
    struct InteractionChild: View {
        let draws: Draws
        @Environment(\.pageFocusInteraction) var interaction
        var body: some View { Text("Synthetic page").onAppear { draws.report = interaction } }
    }

    @Test func scrollStepsAreCountedWithoutDrawingThePageAgain() async throws {
        _ = NSApplication.shared
        let draws = Draws()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.close() }
        window.contentView = NSHostingView(rootView: InteractionPage(draws: draws)); window.orderBack(nil)
        try await settle(window)
        let report = try #require(draws.report), before = draws.count
        // A quick scroll is dozens of wheel steps.
        for _ in 0..<60 { report(); try await settle(window, 1) }
        #expect(draws.count == before, "The page drew again \(draws.count - before) times while scrolling")
    }
}
