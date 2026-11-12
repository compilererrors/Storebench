import AppKit
import Observation
import SwiftUI
import Testing
@testable import StorebenchApp
@testable import StorebenchCore

@MainActor @Suite(.serialized) struct ReleaseOverviewCardTests {
    init() throws { _ = try TestIsolation.require() }
    @MainActor @Observable final class Model {
        var overview: ReleaseOverview?
        var opens = 0
    }
    private func overview(_ state: String = "PREPARE_FOR_SUBMISSION") throws -> ReleaseOverview {
        let plan = try #require(ReleasePlan(.object([("accountId", .string("synthetic-account")), ("appId", .string("1000000001")),
            ("sourceRevisionId", .string("00000000-0000-4000-8000-000000000002")), ("baseVersionId", .string("version-1")), ("platform", .string("MAC_OS")),
            ("targetVersion", .string("2.0")), ("releaseType", .string("MANUAL")), ("updatedAt", .string("2026-01-01T00:00:00.000Z"))])))
        let steps: [ReleaseReadiness.Step] = ["copyright", "build", "review-info", "app-configuration", "age-rating"].map {
            .init(id: $0, label: "Synthetic Requirement " + $0, detail: "Synthetic requirement details", href: "", action: "Open Release", state: .blocked, territories: nil, guideHref: nil)
        }
        let snapshot = ReleaseReadinessSnapshot(scope: try .init(accountId: plan.accountId, appId: plan.appId), plan: plan, steps: steps,
                                                materialSignature: "synthetic-material", targetVersionId: "version-2", targetState: state)
        return ReleaseOverview(plan: plan, snapshot: snapshot, status: nil, readinessCheckedAt: Date(timeIntervalSince1970: 1_900_000_000))
    }
    private struct Cards: View {
        let model: Model
        let compact: Bool
        var body: some View {
            StorebenchMetricGrid(maximumColumns: 4, minimumWidth: 300, spacing: 12) {
                ForEach(0..<3) { index in
                    StorebenchWorkflowCard(description: "Synthetic app workflow", feedback: "Synthetic saved status", heading: {
                        StorebenchWorkflowHeading(title: "Synthetic Card \(index)")
                    }, action: { Button("Open App") {}.storebenchControlID("summary.peer.\(index)") })
                        .storebenchControlID("summary.card.\(index)")
                }
                ReleaseOverviewCard(title: "Release", overview: model.overview, compact: compact, identifier: "summary.release", open: { model.opens += 1 })
            }.padding(20).modifier(StorebenchAppearance())
        }
    }
    private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    private func marker(_ id: String, _ root: NSView) throws -> StorebenchControlMarker {
        try #require(views(root).compactMap { $0 as? StorebenchControlMarker }.first { $0.identifier?.rawValue == id })
    }
    private func frame(_ id: String, _ root: NSView) throws -> CGRect {
        let view = try marker(id, root); return view.convert(view.bounds, to: root)
    }
    private func settle(_ window: NSWindow) async throws {
        window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try await Task.sleep(for: .milliseconds(80))
    }

    @Test(arguments: [CGFloat(320), CGFloat(600), CGFloat(1380)], [false, true])
    func theReleaseCardFitsItsGridAndKeepsItsActionVisible(_ width: CGFloat, _ compact: Bool) async throws {
        _ = NSApplication.shared
        let model = Model(); model.overview = try overview()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 2000), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSHostingView(rootView: Cards(model: model, compact: compact).frame(width: width, alignment: .topLeading))
        window.contentView = root; window.orderBack(nil)
        defer { window.contentView = nil; window.orderOut(nil); window.close() }
        try await settle(window)
        let card = try frame("summary.release", root), action = try frame("summary.release.open", root)
        #expect(card.contains(action) && abs(action.width - StorebenchTheme.actionWidth) < 1)
        #expect(card.minX >= 19 && card.maxX <= width - 19)
        if !compact { for index in 0..<3 { #expect(try card.contains(frame("summary.release.item.\(index)", root))) } }
        if width == 1380 {
            for index in 0..<3 { #expect(try abs(frame("summary.peer.\(index)", root).maxY - action.maxY) < 1) }
        }
        let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds)); root.cacheDisplay(in: root.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: TestIsolation.require().appendingPathComponent("release-summary-\(Int(width))-\(compact ? "compact" : "full").png"))
        let command = try marker("summary.release.open", root), commandFrame = command.convert(command.bounds, to: nil)
        if let native = views(root).compactMap({ $0 as? NSControl }).first(where: { $0.cell is NSButtonCell && $0.convert($0.bounds, to: nil).intersects(commandFrame) }) {
            native.performClick(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(with: type, location: CGPoint(x: commandFrame.midX, y: commandFrame.midY), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
                window.sendEvent(event)
            }
        }
        try await settle(window)
        #expect(model.opens == 1)
        model.overview = try overview("WAITING_FOR_REVIEW"); try await settle(window)
        #expect(try frame("summary.release.open", root) == action)
        #expect(model.overview?.items.isEmpty == true)
    }
}
