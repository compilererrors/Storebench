import AppKit
import StorebenchCore
import SwiftUI
import Testing
@testable import StorebenchApp

/// A guide's step list stays in view beside a long step, as in Release: it reaches the page's top edge and stays there,
/// stops at the end of the step, and keeps working while the page scrolls.
@MainActor @Suite(.serialized) struct StickyStepRailTests {
    init() throws { _ = try TestIsolation.require() }

    final class Clicks: ObservableObject { @Published var opened: [String] = [] }
    struct Page: View {
        @ObservedObject var clicks: Clicks
        let stepHeight: CGFloat
        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Card(title: "Synthetic Heading", subtitle: "Above the guide") { Text("Synthetic content above the steps") }
                    StorebenchStepLayout {
                        StorebenchStepRail(title: "Synthetic steps", items: (1...7).map {
                            .init(id: "s\($0)", number: $0, title: "Synthetic Step \($0)", label: $0 < 3 ? "Done" : $0 == 3 ? "Next step" : "Later", complete: $0 < 3, current: $0 == 3)
                        }, selected: "s3", select: { clicks.opened.append($0) }, identifierPrefix: "synthetic.step.")
                        Color.gray.opacity(0.2).frame(height: stepHeight)
                    }
                    Text("Synthetic content below the guide").frame(height: 400)
                }.padding(16)
            }
        }
    }

    private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    private func settle(_ window: NSWindow, _ times: Int = 4) async throws {
        for _ in 0..<times { window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try await Task.sleep(for: .milliseconds(16)) }
    }
    private func open(width: CGFloat = 1100, height: CGFloat = 900, stepHeight: CGFloat = 3_000) async throws -> (NSWindow, NSScrollView, StorebenchStickyColumnView, Clicks) {
        _ = NSApplication.shared
        let clicks = Clicks()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Page(clicks: clicks, stepHeight: stepHeight))
        window.orderBack(nil)
        try await settle(window, 8)
        let all = views(try #require(window.contentView))
        let scroll = try #require(all.compactMap { $0 as? NSScrollView }.first)
        let column = try #require(all.compactMap { $0 as? StorebenchStickyColumnView }.first)
        return (window, scroll, column, clicks)
    }
    /// The list in the page's visible coordinates: 0 is the page's top edge.
    private func shown(_ column: StorebenchStickyColumnView, _ scroll: NSScrollView) -> CGRect {
        let clip = scroll.contentView, rect = column.convert(column.columnFrame, to: clip)
        return rect.offsetBy(dx: 0, dy: -(clip.bounds.minY + clip.contentInsets.top))
    }
    private func area(_ column: StorebenchStickyColumnView, _ scroll: NSScrollView) -> CGRect {
        let clip = scroll.contentView
        return column.convert(column.bounds, to: clip).offsetBy(dx: 0, dy: -(clip.bounds.minY + clip.contentInsets.top))
    }
    private func scroll(_ scroll: NSScrollView, to y: CGFloat) { scroll.contentView.scroll(to: CGPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView) }

    @Test func theStepListStaysAtThePagesTopWhileTheStepScrolls() async throws {
        let (window, page, column, _) = try await open()
        defer { window.orderOut(nil); window.close() }
        let start = shown(column, page)
        #expect(start.minY > 0 && abs(column.columnFrame.minY) < 0.5, "At the top the list sits at the start of its step: \(start)")
        for y in [CGFloat(600), 1_200, 2_000] {
            scroll(page, to: y)
            // The list moves in the same frame as the page, before anything is laid out again.
            let rect = shown(column, page)
            #expect(abs(rect.minY - StorebenchStickyColumnView.margin) < 1, "Scrolled to \(y): list at \(rect)")
        }
        // At the end of the step the list stops with it instead of covering what comes after.
        scroll(page, to: 10_000); try await settle(window, 2)
        let end = shown(column, page), whole = area(column, page)
        #expect(abs(end.maxY - whole.maxY) < 1 && end.minY < StorebenchStickyColumnView.margin, "At the end: list \(end), step \(whole)")
        scroll(page, to: 0); try await settle(window, 2)
        #expect(abs(column.columnFrame.minY) < 0.5)
    }

    @Test func aListTallerThanThePageKeepsItsEndInView() async throws {
        let (window, page, column, _) = try await open(height: 360)
        defer { window.orderOut(nil); window.close() }
        let visible = page.contentView.bounds.height - page.contentView.contentInsets.top - page.contentView.contentInsets.bottom
        #expect(column.columnFrame.height > visible, "The synthetic list is taller than the page: \(column.columnFrame.height) vs \(visible)")
        scroll(page, to: 1_500)
        let rect = shown(column, page)
        #expect(abs(rect.maxY - (visible - StorebenchStickyColumnView.margin)) < 1, "The list's end stays in view: \(rect), page \(visible)")
    }

    @Test func theStepsCanBeChosenWhileTheyAreHeldInView() async throws {
        let (window, page, column, clicks) = try await open()
        defer { window.orderOut(nil); window.close() }
        scroll(page, to: 1_500); try await settle(window, 2)
        let target = try #require(views(column).first { ($0 as? StorebenchControlMarker)?.identifier?.rawValue == "synthetic.step.s5" })
        let center = target.convert(CGPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
        let root = try #require(window.contentView), frame = try #require(root.superview)
        let hit = try #require(root.hitTest(frame.convert(center, from: nil)))
        #expect(hit.isDescendant(of: column), "A click on a held step reaches the list")
        // The empty area below the list passes clicks on.
        let below = column.convert(CGPoint(x: column.bounds.midX, y: column.columnFrame.maxY + 40), to: nil)
        #expect(column.hitTest(column.superview!.convert(below, from: nil)) == nil)
        #expect(clicks.opened.isEmpty)
    }

    @Test func aNarrowWindowShowsTheListAboveTheStepWithoutHoldingIt() async throws {
        let (window, page, column, _) = try await open(width: 700)
        defer { window.orderOut(nil); window.close() }
        #expect(abs(column.bounds.height - column.columnFrame.height) < 1, "Above the step the list has only its own height")
        scroll(page, to: 1_500); try await settle(window, 2)
        #expect(abs(column.columnFrame.minY) < 0.5)
    }

    /// Every guide's step list sits in the shared step layout, which gives it the step's whole height to stay in view in.
    @Test func everyStepListInTheAppSitsInTheSharedStepLayout() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/StorebenchApp")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)).compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(files.count > 50, "The app's sources are readable: \(sources.path)")
        var lists = 0
        for file in files where file.lastPathComponent != "StorebenchStepFlow.swift" && file.lastPathComponent != "ReleaseStepRail.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            guard text.contains("StorebenchStepRail(") || text.contains("ReleaseStepRail(") else { continue }
            lists += 1
            #expect(text.contains("StorebenchStepLayout {"), "\(file.lastPathComponent) shows a step list outside the shared step layout")
        }
        #expect(lists >= 4, "Release, Quick Release, pricing setup and Lower Prices show a step list: \(lists)")
        let layouts = try files.filter { try String(contentsOf: $0, encoding: .utf8).contains("railWidth") }.map(\.lastPathComponent)
        #expect(layouts == ["StorebenchStepFlow.swift"], "Only the shared layout places a step list: \(layouts)")
    }

    @MainActor private final class Document: NSView { override var isFlipped: Bool { true } }
    /// SwiftUI can put the list in its window before it is inside the page's scroll view; it still follows that page.
    @Test func aListPlacedBeforeItsPageExistsStillFollowsThePage() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.close() }
        let holder = NSView(frame: CGRect(x: 0, y: 0, width: 700, height: 500)); window.contentView = holder; window.orderBack(nil)
        let column = StorebenchStickyColumnView(frame: CGRect(x: 0, y: 0, width: 248, height: 3_000))
        column.show(AnyView(Color.gray.frame(width: 248, height: 200)))
        holder.addSubview(column); holder.layoutSubtreeIfNeeded()
        let page = NSScrollView(frame: holder.bounds), document = Document(frame: CGRect(x: 0, y: 0, width: 680, height: 4_000)), group = Document(frame: CGRect(x: 0, y: 100, width: 680, height: 3_000))
        page.documentView = document; document.addSubview(group); holder.addSubview(page)
        column.removeFromSuperview(); group.addSubview(column)
        window.contentView?.layoutSubtreeIfNeeded()
        scroll(page, to: 1_500)
        let rect = shown(column, page)
        #expect(abs(rect.minY - StorebenchStickyColumnView.margin) < 1, "The list follows the page it was moved into: \(rect)")
        // SwiftUI moves the view that holds the list rather than the list itself; the list follows that too.
        group.setFrameOrigin(CGPoint(x: 0, y: 300))
        #expect(abs(shown(column, page).minY - StorebenchStickyColumnView.margin) < 1)
    }
}
