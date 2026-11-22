import AppKit
import StorebenchCore
import SwiftUI
import Testing
@testable import StorebenchApp

/// A guide's Back and Next sit in a bar fixed to the bottom of the page, so a long step never needs scrolling to reach them.
@MainActor @Suite(.serialized) struct StepBarTests {
    init() throws { _ = try TestIsolation.require() }

    @MainActor final class Presses { var back = 0, next = 0 }

    @Test func theBarRunsTheLatestCommandsAndOnlyWhenTheyCanRun() {
        let model = StorebenchStepBarModel(), presses = Presses()
        var state = StorebenchStepBarState(id: "guide/one", title: "Step 1 of 3: Synthetic", detail: "Synthetic detail",
                                           back: .init(title: "Back", unavailable: "This is the first step.", primary: false) { presses.back += 1 },
                                           next: [.init(title: "Next") { presses.next += 1 }])
        model.show(state)
        model.runBack(); model.runNext()
        #expect(presses.back == 0 && presses.next == 1, "An unavailable Back never runs")
        // A new closure with the same look does not redraw the bar, but a press runs the new closure.
        state.next = [.init(title: "Next") { presses.next += 10 }]
        model.show(state)
        model.runNext()
        #expect(presses.next == 11)
        // A guide that closes removes only its own bar.
        model.clear("guide/other"); #expect(model.state != nil)
        model.clear("guide/one"); #expect(model.state == nil)
        model.runNext(); #expect(presses.next == 11)
    }

    struct Guide: View {
        @Binding var step: Int
        let presses: Presses
        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<60, id: \.self) { Text("Synthetic field \($0) of step \(step)").frame(height: 30) }
                Text("Synthetic last field").frame(height: 30).storebenchControlID("synthetic.last")
                StorebenchStepCommands(state: .init(id: "synthetic/\(step)", title: "Step \(step) of 3: Synthetic", detail: "Synthetic detail",
                    back: .init(title: "Back", unavailable: step == 1 ? "This is the first step." : nil, primary: false) { step -= 1; presses.back += 1 },
                    next: [.init(title: "Next", unavailable: step == 3 ? "This is the last step." : nil) { step += 1; presses.next += 1 }]))
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
    }
    struct Page: View {
        let model: StorebenchStepBarModel
        let presses: Presses
        @State var step = 1
        @State var open = true
        var body: some View {
            ScrollView { if open { Guide(step: $step, presses: presses) } }
                .environment(\.stepBar, model)
                .safeAreaInset(edge: .bottom, spacing: 0) { StorebenchStepBar(model: model) }
        }
    }

    private func settle(_ window: NSWindow, _ times: Int = 6) async throws {
        for _ in 0..<times { window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try await Task.sleep(for: .milliseconds(16)) }
    }
    private func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews { if let found = scrollView(in: child) { return found } }
        return nil
    }

    @Test func aLongStepKeepsBackAndNextAtTheBottomWithoutHidingItsLastField() async throws {
        _ = NSApplication.shared
        let model = StorebenchStepBarModel(), presses = Presses()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.close() }
        window.contentView = NSHostingView(rootView: Page(model: model, presses: presses))
        window.orderBack(nil)
        try await settle(window)
        let state = try #require(model.state)
        #expect(state.title == "Step 1 of 3: Synthetic" && state.back?.runnable == false && state.next.last?.runnable == true)

        // Scrolled to the very end, the last field ends above the bar instead of under it.
        let content = try #require(window.contentView), scroll = try #require(scrollView(in: content)), clip = scroll.contentView
        let document = try #require(scroll.documentView)
        clip.scroll(to: CGPoint(x: 0, y: max(0, document.frame.height - clip.bounds.height + clip.contentInsets.bottom))); scroll.reflectScrolledClipView(clip)
        try await settle(window)
        #expect(clip.contentInsets.bottom >= StorebenchStepBar.height - 1, "The page leaves room for the bar: \(clip.contentInsets.bottom)")

        // Next in the bar moves the guide on, and the bar follows the open step.
        model.runNext(); try await settle(window)
        #expect(presses.next == 1 && model.state?.title == "Step 2 of 3: Synthetic" && model.state?.back?.runnable == true)
        model.runBack(); try await settle(window)
        #expect(presses.back == 1 && model.state?.title == "Step 1 of 3: Synthetic")
    }

    @Test func withoutAPageBarTheCommandsStayInPlace() async throws {
        _ = NSApplication.shared
        let presses = Presses()
        struct Inline: View {
            let presses: Presses
            @State var step = 2
            var body: some View { Guide(step: $step, presses: presses) }
        }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.close() }
        window.contentView = NSHostingView(rootView: ScrollView { Inline(presses: presses) })
        window.orderBack(nil)
        try await settle(window)
        func markers(_ view: NSView) -> [String] { (((view as? StorebenchControlMarker)?.identifier?.rawValue).map { [$0] } ?? []) + view.subviews.flatMap(markers) }
        let found = Set(markers(try #require(window.contentView)))
        #expect(found.isSuperset(of: ["step-bar.back", "step-bar.next"]), "Commands in place: \(found)")
    }

    struct GuidePage<Guide: View>: View {
        let model: StorebenchStepBarModel
        let controller: WorkspaceController
        @ViewBuilder let guide: () -> Guide
        var body: some View {
            ScrollView { guide().padding(16) }
                .environment(controller)
                .environment(\.stepBar, model)
                .safeAreaInset(edge: .bottom, spacing: 0) { StorebenchStepBar(model: model) }
        }
    }

    private func barState<Guide: View>(_ guide: @escaping () -> Guide, steps: (StorebenchStepBarModel, NSWindow) async throws -> Void) async throws {
        _ = NSApplication.shared
        let model = StorebenchStepBarModel(), root = try TestIsolation.require().appendingPathComponent("step-bar-guides-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        // A workspace that is never started: the guides read nothing and show their steps without App Store Connect.
        let controller = WorkspaceController(workspace: Workspace(root: root), writer: VaultWriter(dataRoot: root, storage: MemoryVaultStorage()), releaseWarmDelay: nil)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.close() }
        window.contentView = NSHostingView(rootView: GuidePage(model: model, controller: controller, guide: guide))
        window.orderBack(nil)
        try await settle(window, 10)
        try await steps(model, window)
    }

    @Test func startTestingSetUpReportsAndCreateMediaShowTheBarOnEveryStep() async throws {
        let account = Account(id: "synthetic-guides", name: "Synthetic Account", keyId: "SYNTHKEY01", keyType: "individual", issuerId: nil,
                              appIds: ["1000000009"], appNames: ["1000000009": "Synthetic Guide App"])
        let app = try #require(account.apps.first)

        // Before TestFlight is read, Start Testing already has its bar, with Next waiting for the read.
        try await barState({ TestFlightGuideView(account: account, app: app, session: nil) }) { model, _ in
            let state = try #require(model.state)
            #expect(state.title == "Start Testing" && state.back?.runnable == false && state.next.last?.runnable == false)
            #expect(state.next.last?.unavailable?.isEmpty == false, "A dimmed command says why")
        }

        // Set Up Reports walks every step with Back and Next in the bar, and the last one continues to App Overview.
        try await barState({ ReportsGuideView(account: account, app: app, session: nil) }) { model, window in
            var seen: [String] = []
            for _ in 0..<5 {
                let state = try #require(model.state); seen.append(state.title)
                guard state.next.last?.title == "Next" else { break }
                model.runNext(); try await settle(window)
            }
            #expect(seen.count == 5 && seen.first?.hasPrefix("Step 1 of 5") == true && seen.last?.hasPrefix("Step 5 of 5") == true, "Steps: \(seen)")
            #expect(model.state?.back?.runnable == true && model.state?.next.last?.title.hasPrefix("To ") == true)
        }

        // Create Media is split into numbered steps; step 4 offers Save All to Asset Library, dimmed until a card set exists.
        try await barState({ CreateMediaView(account: account, app: app, session: nil, availableTranslationTargets: { _, _ in [] }) }) { model, window in
            var seen: [StorebenchStepBarState] = []
            for _ in 0..<5 {
                let state = try #require(model.state); seen.append(state)
                guard state.next.last?.title == "Next" else { break }
                model.runNext(); try await settle(window)
            }
            #expect(seen.map(\.title) == ["Step 1 of 5: Display Size and Cards", "Step 2 of 5: Screenshots", "Step 3 of 5: Text and Background",
                                          "Step 4 of 5: Save to Asset Library", "Step 5 of 5: Add in Text and Screenshots"])
            #expect(seen[0].back?.runnable == false && seen[0].back?.unavailable == "This is the first step.")
            let save = try #require(seen[3].next.first { $0.title == "Save All to Asset Library" })
            #expect(save.unavailable == "Create a card set in step 1 first." && seen[3].next.last?.title == "Next")
            #expect(seen[4].next.last?.runnable == false, "Without an open app the last step's exit is dimmed with its reason")
            model.runBack(); try await settle(window)
            #expect(model.state?.title == "Step 4 of 5: Save to Asset Library")
        }
    }
}
