import AppKit
import StorebenchCore
import SwiftUI
import Testing
@testable import StorebenchApp

/// Renders the shared building blocks the way SwiftUI measures them in menus, popovers, sheets and scroll views:
/// infinite, zero, unspecified and ordinary proposals, with and without optional content. A layout that indexes
/// a missing child or turns an infinite width into a column count traps here instead of in the app.
@MainActor @Suite struct LayoutRenderTests {
    init() throws { _ = try TestIsolation.require() }

    /// SwiftUI measures with any of these, including infinite proposals in menus, popovers and scroll views.
    private let measurements: [CGSize] = [CGSize(width: CGFloat.infinity, height: .infinity), .zero, CGSize(width: 1, height: 1),
                                          CGSize(width: 320, height: CGFloat.infinity), CGSize(width: CGFloat.infinity, height: 600), CGSize(width: 1440, height: 900)]
    /// A window places views in finite bounds or at their ideal size; these are the proposals that render.
    private let placements: [ProposedViewSize] = [.unspecified, .zero, ProposedViewSize(width: 1, height: nil), ProposedViewSize(width: 320, height: nil), ProposedViewSize(width: 1440, height: 900)]

    /// Measures through AppKit hosting under every proposal and renders an image at every placement.
    /// Measurement may report an infinite width for flexible content, but never NaN or an infinite height for a finite one.
    private func capture<V: View>(_ name: String, _ view: V, empty: Bool = false) {
        let host = NSHostingController(rootView: view)
        for size in measurements {
            let fitted = host.sizeThatFits(in: size)
            #expect(!fitted.width.isNaN && !fitted.height.isNaN, "\(name) measured \(fitted) for \(size)")
            #expect(!size.height.isFinite || fitted.height.isFinite, "\(name) measured \(fitted) for \(size)")
            #expect(!size.width.isFinite || fitted.width.isFinite || fitted.width == size.width, "\(name) measured \(fitted) for \(size)")
        }
        for proposal in placements {
            let renderer = ImageRenderer(content: view)
            renderer.proposedSize = proposal
            renderer.scale = 1
            let image = renderer.cgImage
            if !empty, proposal.width == 320 { #expect(image != nil, "\(name) did not render at \(proposal)") }
        }
    }

    @Test func actionGroupsWithNoneOneOrManyCommands() {
        capture("empty action group", StorebenchActionGroup { EmptyView() }, empty: true)
        capture("one command", StorebenchActionGroup { Button("Try Again") {} })
        capture("many commands", StorebenchActionGroup(alignment: .trailing) { ForEach(0..<7) { Button("Command \($0)") {} } })
    }

    /// Every standard command has the one shared width, whatever its label, and keeps its label on one line.
    @Test func commandsShareOneWidthWhateverTheirLabel() {
        let size = CGSize(width: CGFloat.infinity, height: .infinity)
        func width<V: View>(_ view: V) -> CGFloat { NSHostingController(rootView: view).sizeThatFits(in: size).width }
        let short = width(Button("OK") {}.buttonStyle(StorebenchButtonStyle()))
        let medium = width(Button("Read Current Connection") {}.buttonStyle(StorebenchButtonStyle()))
        #expect(abs(short - CGFloat(StorebenchTheme.actionWidth)) <= 1 && abs(medium - short) <= 1, "Short and long labels get the same shared width")
        let oneLine = NSHostingController(rootView: Button("Read Current Connection") {}.buttonStyle(StorebenchButtonStyle())).sizeThatFits(in: size).height
        #expect(abs(oneLine - CGFloat(StorebenchTheme.controlHeight)) <= 1, "Commands keep the shared control height")
        let renderer = ImageRenderer(content: StorebenchActionGroup { Button("OK") {}; Button("Read Current Connection") {} }.frame(width: 900))
        renderer.scale = 1
        #expect(renderer.cgImage != nil)
        let grid = ComponentLayout.actionGrid(width: 900, heights: [42, 42], cell: Double(medium))
        #expect(grid.frames.count == 2 && grid.frames.allSatisfy { abs(Double($0.width) - Double(medium)) <= 1 }, "Commands in a group keep the shared width")
    }

    @Test func longLabelsWrapWithinTheMaximumWidth() {
        let long = "Review Selected Assets for App Review and Check Every Placement Again"
        capture("long label", StorebenchActionGroup { Button(long) {}; Button("OK") {} })
        capture("long primary label", Button(long) {}.buttonStyle(StorebenchButtonStyle(.primary)))
        capture("long label in footer", StorebenchFormFooter { Button(long) {}; Button("Cancel") {} })
        capture("notice with languages icon", StorebenchNotice(title: "Add a second language first", description: "Synthetic", icon: "languages") { Button("Open Localizations") {} })
        let host = NSHostingController(rootView: Button(long) {}.buttonStyle(StorebenchButtonStyle()))
        #expect(host.sizeThatFits(in: CGSize(width: CGFloat.infinity, height: .infinity)).width <= CGFloat(StorebenchTheme.actionMaxWidth) + 1)
    }

    private func controls(items: Int) -> StorebenchCollectionControls {
        StorebenchCollectionControls(summary: "1–\(items) of \(items)", pageSize: .constant(10), sort: .constant("default"), descending: .constant(false), sorts: [("name", "Name")],
                                     openingLimit: .constant(0), allExpanded: false, allCollapsed: true, expand: {}, collapse: {}, pageItems: items)
    }

    /// The collection header is one row at desktop width: view options and the count lead, one page command trails.
    @Test func collectionControlsTakeOneRowWithoutReservedHeight() {
        let row = NSHostingController(rootView: controls(items: 5)).sizeThatFits(in: CGSize(width: 1200, height: CGFloat.infinity))
        #expect(row.height <= CGFloat(StorebenchTheme.controlHeight) + 2, "Measured \(row)")
        let single = NSHostingController(rootView: controls(items: 1)).sizeThatFits(in: CGSize(width: 1200, height: CGFloat.infinity))
        #expect(single.height <= CGFloat(StorebenchTheme.controlHeight) + 2, "Measured \(single)")
        let narrow = NSHostingController(rootView: controls(items: 5)).sizeThatFits(in: CGSize(width: 300, height: CGFloat.infinity))
        #expect(narrow.height > row.height && narrow.height <= 2 * CGFloat(StorebenchTheme.controlHeight) + 16, "Measured \(narrow)")
        capture("collection controls", controls(items: 5))
    }

    @Test func feedbackAndCopyReserveTheirTracksBeforeTextAppears() {
        let empty = NSHostingController(rootView: StorebenchFeedback(text: "", height: 68)).sizeThatFits(in: CGSize(width: 600, height: CGFloat.infinity))
        #expect(abs(empty.height - 68) < 1, "Measured \(empty)")
        let message = NSHostingController(rootView: StorebenchFeedback(text: "Synthetic status", height: 68)).sizeThatFits(in: CGSize(width: 600, height: CGFloat.infinity))
        #expect(abs(message.height - 68) < 1, "Measured \(message)")
        #expect(empty == message, "A feedback update must not move the commands below it")
        let long = NSHostingController(rootView: StorebenchFeedback(text: String(repeating: "Synthetic status explanation. ", count: 80), height: 68, error: true)).sizeThatFits(in: CGSize(width: 600, height: CGFloat.infinity))
        #expect(abs(long.height - empty.height) < 1, "A long error stays inside the reserved feedback track")
        let copy = NSHostingController(rootView: StorebenchTextSlot(text: "Synthetic one line", height: 96, font: .sbCallout)).sizeThatFits(in: CGSize(width: 600, height: CGFloat.infinity))
        #expect(abs(copy.height - 96) < 1, "Static copy measured \(copy)")
        let expanded = NSHostingController(rootView: StorebenchTextSlot(text: String(repeating: "Synthetic explanatory copy. ", count: 80), height: 32, font: .sbCallout)).sizeThatFits(in: CGSize(width: 300, height: CGFloat.infinity))
        #expect(expanded.height > 32 && expanded.height <= StorebenchTheme.textTrackLimit + 1, "Long copy grows to its reading limit before it scrolls: \(expanded)")
    }

    @Test func hiddenPickerLabelsKeepFullSelectionContext() throws {
        let selected = "Synthetic option with a title longer than the visible selection field"
        let detail = "Synthetic explanation of what this option changes."
        let host = NSHostingController(rootView: StorebenchPicker("Synthetic Selection", selection: .constant("selected")) {
            SelectionOption(selected, value: "selected").help(detail)
        }.labelsHidden().frame(width: 300))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        defer { window.close() }
        host.view.frame = CGRect(x: 0, y: 0, width: 320, height: 100)
        host.view.layoutSubtreeIfNeeded()
        func popup(in view: NSView) -> NSPopUpButton? {
            if let popup = view as? NSPopUpButton { return popup }
            return view.subviews.lazy.compactMap { popup(in: $0) }.first
        }
        let control = try #require(popup(in: host.view))
        #expect(control.accessibilityLabel() == "Synthetic Selection")
        #expect(control.accessibilityValue() as? String == selected, "VoiceOver retains the selected value as well as its explanation")
        #expect(control.toolTip?.contains(selected) == true, "Hover help retains the full value when the field shortens it")
        #expect(control.toolTip?.contains(detail) == true, "The option explanation remains available on hover")
    }

    @Test func headersWithAndWithoutActions() {
        capture("header without actions", StorebenchHeader { Text("Sales") } actions: { EmptyView() })
        capture("header with actions", StorebenchHeader { Text("Sales") } actions: { Button("Download") {}; Button("More") {} })
        capture("page header", StorebenchPageHeader(title: "Sales", description: "Paid purchases, proceeds and refunds by period and country.", help: "sales"))
    }

    @Test func statusRowsNoticesAndWorkflowCardsWithEmptySlots() {
        capture("status row with empty slots", StorebenchStatusRow(title: "Sales", detail: "Last downloaded today") { EmptyView() } action: { EmptyView() } details: { EmptyView() })
        capture("status row", StorebenchStatusRow(title: "Sales", detail: "Last downloaded today") { Text("Ready") } action: { Button("Open") {} } details: { Text("Synthetic detail") })
        capture("notice without action", StorebenchNotice(title: "Reports", description: "Synthetic description") { EmptyView() })
        capture("notice with action", StorebenchNotice(title: "Reports", description: String(repeating: "Synthetic description ", count: 20)) { Button("Open Reports") {} })
        capture("workflow card", StorebenchWorkflowCard(description: "Synthetic", feedback: "", progress: 2) { Text("Heading") } action: { EmptyView() })
        capture("navigation card", StorebenchNavigationCard(title: "Reports", description: "Synthetic", action: "Open Reports", activate: {}) { EmptyView() })
    }

    @Test func textTracksAndFlows() {
        capture("empty text slot", StorebenchTextSlot(text: "", height: 18), empty: true)
        capture("long text slot", StorebenchTextSlot(text: String(repeating: "Synthetic words ", count: 200), height: 18))
        capture("adaptive text", StorebenchAdaptiveText(text: String(repeating: "Synthetic ", count: 100)))
        capture("hug width", StorebenchHugWidth { Text("Synthetic") })
        capture("empty flow", StorebenchFlow { EmptyView() }, empty: true)
        capture("flow", StorebenchFlow { ForEach(0..<12) { Text("Tag \($0)") } })
        capture("feedback", StorebenchFeedback(text: "Synthetic feedback"))
    }

    @Test func cardsAndCollections() {
        capture("card", Card(title: "Reports", subtitle: "Synthetic", help: "sales") { Text("Content") })
        capture("settings service section", StorebenchFormSection("Synthetic Service", icon: "sparkles", description: "Synthetic explanation of the service and when it is used.") {
            StorebenchTextField("Synthetic Model", text: .constant("Synthetic Choice"))
            StorebenchFormFooter { Button("Save Selection") {} }
        }.environment(\.settingsPresentation, true))
        struct Item: Identifiable { let id: Int }
        capture("empty collection", StorebenchCollection(items: [Item](), title: { "Item \($0.id)" }, maximumColumns: 4, empty: "No synthetic items yet. Add one to see it here.") { _ in EmptyView() }, empty: true)
        capture("collection", StorebenchCollection(items: (0..<9).map(Item.init), title: { "Item \($0.id)" }, maximumColumns: 4, minimumWidth: 120, empty: "No synthetic items yet.") { Text("Item \($0.id)") })
        capture("asset card", StorebenchAssetCard(title: "Synthetic", metadata: "1290 × 2796", status: "Ready") { Color.gray } actions: { EmptyView() })
        capture("compact screenshot card", StorebenchAssetCard(title: "Synthetic screenshot with a long filename that needs several lines.png", metadata: "2880 × 1800 px · On This Mac", status: "", position: 10, compact: true) {
            Color.gray.aspectRatio(1.6, contentMode: .fit)
        } actions: {
            HStack {
                Button {} label: { StorebenchIcon(name: "up", size: 16) }.buttonStyle(StorebenchButtonStyle(.quiet, size: .icon))
                Spacer(minLength: 0)
                Button {} label: { StorebenchIcon(name: "close", size: 16) }.buttonStyle(StorebenchButtonStyle(.danger, size: .icon))
            }
        })
    }

    @Test func recoveryStepsForEveryReportingCode() {
        for code in ["SB-REPORTER-RESPONSE", "SB-FINANCE-RESPONSE", "SB-ANALYTICS-FORMAT", "SB-REPORT-FORMAT", "SB-REPORTER-KEYCHAIN", "SB-REPORT-UNAVAILABLE", "SB-REPORT-NETWORK", "SB-NOT-A-CODE"] {
            capture("recovery \(code)", RecoveryActions(code: code, showMessage: true))
            capture("compact recovery \(code)", RecoveryActions(code: code, compact: true))
        }
    }
}
