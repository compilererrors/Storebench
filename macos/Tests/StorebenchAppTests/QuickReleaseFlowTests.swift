import AppKit
import Observation
import SwiftUI
import Testing
@testable import StorebenchApp
@testable import StorebenchCore

@MainActor @Suite(.serialized) struct QuickReleaseFlowTests {
    init() throws { _ = try TestIsolation.require() }
    @MainActor @Observable final class Probe {
        var section = AppNavigation.Section.quickRelease
        var requests = 0
        var changed = 0
        var saves = 0
        var saved: ReleasePlan?
        var snapshot: ReleaseReadinessSnapshot?
        var openedURL: URL?
    }
    private func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
    private func marker(_ id: String, in root: NSView) throws -> StorebenchControlMarker {
        try #require(views(root).compactMap { $0 as? StorebenchControlMarker }.first { $0.identifier?.rawValue == id })
    }
    private func presentation() throws -> WorkspaceController {
        let root = try TestIsolation.require().appendingPathComponent("quick-presentation-" + UUID().uuidString), vault = MemoryVaultStorage()
        return WorkspaceController(workspace: Workspace(root: root), writer: VaultWriter(dataRoot: root, storage: vault),
                                   keychainStorage: vault, protectedStorage: vault, releaseWarmDelay: nil)
    }
    private func click(_ id: String, window: NSWindow) async throws {
        let root = try #require(window.contentView), marker = try marker(id, in: root), rect = marker.convert(marker.bounds, to: root)
        if let button = views(root).compactMap({ $0 as? NSControl }).first(where: { $0.cell is NSButtonCell && $0.convert($0.bounds, to: root).intersects(rect) }) {
            button.performClick(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
            let target = marker.convert(marker.bounds, to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(with: type, location: CGPoint(x: target.midX, y: target.midY), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
                window.sendEvent(event)
            }
        }
        try await Task.sleep(for: .milliseconds(100)); root.layoutSubtreeIfNeeded(); window.displayIfNeeded()
    }
    /// Mouse sequences change AppKit's key window. Wait for the other concurrent window fixtures to finish first.
    private func waitForQuietAppKit() async throws {
        let deadline = ContinuousClock.now + .seconds(600)
        var quietSince: ContinuousClock.Instant?
        while ContinuousClock.now < deadline {
            if NSApplication.shared.windows.contains(where: { $0.isVisible && !($0 is NSPanel) }) { quietSince = nil }
            else if let quietSince, ContinuousClock.now - quietSince >= .seconds(3) { return }
            else if quietSince == nil { quietSince = .now }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw FileMutex.Failure.timeout
    }
    private struct Harness: View {
        let probe: Probe, owner: ReleasePlanEditor, account: Account
        let controller: WorkspaceController
        var body: some View {
            VStack {
                ReleaseVersionButton(section: probe.section, hasPlan: owner.plan != nil, continueHere: { probe.requests += 1 }, openRelease: { probe.section = .release })
                QuickReleaseView(account: account, app: account.apps[0], session: nil, changed: { probe.changed += 1 },
                                 continueRequests: probe.requests, providedModel: owner, providedSnapshot: probe.snapshot)
            }.padding(20).modifier(StorebenchAppearance()).environment(controller)
                .environment(\.openSection, { probe.section = $0 })
                .environment(\.openURL, OpenURLAction { url in probe.openedURL = url; return .handled })
        }
    }

    @Test(arguments: [CGFloat(680), CGFloat(1100)])
    func preparingSavingAndSyncingStayInTheQuickReleaseWorkspace(_ width: CGFloat) async throws {
        _ = NSApplication.shared
        try await waitForQuietAppKit()
        let probe = Probe(), account = Account(id: "synthetic-account", name: "Synthetic Account", keyId: "SYNTHKEY01", keyType: "individual", issuerId: nil,
                                              appIds: ["1000000001"], appNames: ["1000000001": "Synthetic App"])
        let input = ReleasePlanInputs(start: .reuse, sourceRevisionId: "00000000-0000-4000-8000-000000000002", baseVersionId: "version-1", targetVersion: "2.0", date: Date())
        let owner = ReleasePlanEditor(accountId: account.id, appId: account.appIds[0], initial: input, read: { probe.saved }, save: { input, expected in
            guard expected == (probe.saved?.token ?? "null") else { throw ReleaseFailure.conflict("Synthetic version changed") }
            let plan = try #require(ReleasePlan(.object([("accountId", .string(account.id)), ("appId", .string(account.appIds[0])),
                ("sourceRevisionId", .string(input.sourceRevisionId!)), ("baseVersionId", .string(input.baseVersionId!)), ("platform", .string("IOS")),
                ("targetVersion", .string(input.targetVersion)), ("releaseType", .string(input.releaseType)), ("updatedAt", .string("2026-01-01T00:00:00.000Z"))])))
            probe.saved = plan; probe.saves += 1; return plan
        }, remove: { _ in probe.saved = nil })
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 1900), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSHostingView(rootView: Harness(probe: probe, owner: owner, account: account, controller: try presentation()).frame(width: width))
        window.contentView = root; window.orderBack(nil)
        defer { window.contentView = nil; window.orderOut(nil); window.close(); owner.retire() }
        try await Task.sleep(for: .milliseconds(150)); root.layoutSubtreeIfNeeded()
        #expect(owner.loaded && owner.plan == nil)
        _ = try marker("version-plan.save", in: root)
        try await click("workspace.version", window: window)
        #expect(probe.requests == 1 && probe.section == .quickRelease)
        try await click("version-plan.save", window: window)
        #expect(probe.saves == 1 && probe.changed == 1 && owner.plan?.targetVersion == "2.0")
        owner.inputs.targetVersion = "2.1"; try await Task.sleep(for: .milliseconds(100)); root.layoutSubtreeIfNeeded()
        try await click("version-plan.save", window: window)
        #expect(probe.saves == 2 && owner.plan?.targetVersion == "2.1")
        try await click("version-plan.sync", window: window)
        #expect(probe.changed == 3 && probe.section == .quickRelease && owner.active)
        let plan = try #require(owner.plan)
        func check(_ id: String, _ state: ReleaseReadiness.State) -> ReleaseReadiness.Step {
            .init(id: id, label: id, detail: "Synthetic release status", href: "", action: "Edit", state: state, territories: nil, guideHref: nil)
        }
        var notes = check("local:sv", .blocked)
        notes.issues = [.init(field: "whatsNew", message: "Synthetic release notes are required.", section: "text")]
        probe.snapshot = .init(scope: try .init(accountId: account.id, appId: account.appIds[0]), plan: plan,
            steps: [check("version", .ready), notes, check("build", .blocked), check("copyright", .ready), check("review-info", .ready),
                    check("app-configuration", .review), check("age-rating", .review), check("accessibility", .review), check("privacy", .ready),
                    check("tax", .ready), check("territories", .ready), check("media:sv", .review)],
            materialSignature: "synthetic-ready-listing", targetVersionId: "version-2", targetState: "PREPARE_FOR_SUBMISSION", parts: .all)
        try await Task.sleep(for: .milliseconds(100)); root.layoutSubtreeIfNeeded()
        try await click("workspace.version", window: window)
        let rail = try marker("quick.rail", in: root), pane = try marker("quick.pane", in: root)
        let railFrame = rail.convert(rail.bounds, to: root), paneFrame = pane.convert(pane.bounds, to: root)
        #expect(!railFrame.intersects(paneFrame) && paneFrame.minX >= 19 && paneFrame.maxX <= width - 19)
        if width > 1000 { #expect(railFrame.maxX < paneFrame.minX) }
        let status = try marker("quick.current.status", in: root)
        #expect(paneFrame.contains(status.convert(status.bounds, to: root)))
        try await click("quick.next", window: window)
        #expect(probe.section == .quickRelease)
        try await click("quick.back", window: window)
        try await click("quick.step.version", window: window)
        _ = try marker("version-plan.save", in: root)
        try await click("quick.step.text", window: window)
        for id in QuickRelease.stepIDs { _ = try marker("quick.step." + id, in: root) }
        #expect(views(root).compactMap { $0 as? StorebenchControlMarker }.filter { $0.identifier?.rawValue.hasPrefix("quick.step.") == true }.count == 4)
        _ = try marker("quick.release", in: root)
        #expect(!views(root).compactMap { $0 as? StorebenchControlMarker }.contains { $0.identifier?.rawValue == "release-submission-review" })
        let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds)); root.cacheDisplay(in: root.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: TestIsolation.require().appendingPathComponent("quick-release-\(Int(width)).png"))
    }

    @Test(arguments: [CGFloat(680), CGFloat(1100)])
    func aStatusRefreshKeepsTheCurrentWorkStepVisible(_ width: CGFloat) async throws {
        _ = NSApplication.shared
        try await waitForQuietAppKit()
        let probe = Probe(), account = Account(id: "synthetic-account", name: "Synthetic Account", keyId: "SYNTHKEY01", keyType: "individual", issuerId: nil,
                                              appIds: ["1000000001"], appNames: ["1000000001": "Synthetic App"])
        let plan = try #require(ReleasePlan(.object([("accountId", .string(account.id)), ("appId", .string(account.appIds[0])),
            ("sourceRevisionId", .string("00000000-0000-4000-8000-000000000002")), ("baseVersionId", .string("version-1")),
            ("platform", .string("IOS")), ("targetVersion", .string("2.0")), ("releaseType", .string("MANUAL")),
            ("updatedAt", .string("2026-01-01T00:00:00.000Z"))])))
        let owner = ReleasePlanEditor(accountId: account.id, appId: account.appIds[0], initial: .init(plan, fallbackDate: Date()), read: { plan }, save: { _, _ in plan }, remove: { _ in })
        await owner.load()
        func snapshot(notesMissing: Bool) throws -> ReleaseReadinessSnapshot {
            func step(_ id: String, _ state: ReleaseReadiness.State) -> ReleaseReadiness.Step {
                .init(id: id, label: id, detail: "Synthetic status", href: "", action: "Edit", state: state, territories: nil, guideHref: nil)
            }
            var notes = step("local:sv", notesMissing ? .blocked : .review)
            if notesMissing { notes.issues = [.init(field: "whatsNew", message: "Synthetic notes are required.", section: "text")] }
            return .init(scope: try .init(accountId: account.id, appId: account.appIds[0]), plan: plan,
                steps: [step("version", .ready), notes, step("apple-text:sv", notesMissing ? .blocked : .ready), step("build", .blocked)],
                materialSignature: notesMissing ? "synthetic-empty-notes" : "synthetic-saved-notes", targetVersionId: "version-2",
                targetState: "PREPARE_FOR_SUBMISSION", parts: .all)
        }
        probe.snapshot = try snapshot(notesMissing: true)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 1900), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSHostingView(rootView: Harness(probe: probe, owner: owner, account: account, controller: try presentation()).frame(width: width))
        window.contentView = root; window.orderBack(nil)
        defer { window.contentView = nil; window.orderOut(nil); window.close(); owner.retire() }
        try await Task.sleep(for: .milliseconds(150)); root.layoutSubtreeIfNeeded()
        _ = try marker("quick.current.text", in: root)
        probe.snapshot = try snapshot(notesMissing: false)
        try await Task.sleep(for: .milliseconds(150)); root.layoutSubtreeIfNeeded()
        // The build is now the first missing requirement. Updating status must not take the user away from the text.
        _ = try marker("quick.current.text", in: root)
        #expect(QuickRelease.initialStep(QuickRelease.progress(plan: plan, snapshot: probe.snapshot)) == "build")
        #expect(probe.section == .quickRelease)
        let rail = try marker("quick.rail", in: root), pane = try marker("quick.pane", in: root)
        #expect(!rail.convert(rail.bounds, to: root).intersects(pane.convert(pane.bounds, to: root)))
        let previous = try snapshot(notesMissing: false)
        let current = JSONText.object([("id", .string("version-current")), ("platform", .string("IOS")), ("number", .string("1.5")), ("state", .string("WAITING_FOR_REVIEW"))])
        probe.snapshot = .init(scope: previous.scope, plan: plan, steps: previous.steps, materialSignature: "synthetic-blocked-version",
            targetVersionId: nil, targetState: nil, parts: .all, observations: .object([("appleVersions", .array([current]))]))
        try await Task.sleep(for: .milliseconds(150)); root.layoutSubtreeIfNeeded()
        try await click("quick.step.version", window: window)
        _ = try marker("version-plan.save", in: root)
        try await click("release.current-version.open", window: window)
        #expect(probe.openedURL == ReleaseCreation.versionURL(appId: account.appIds[0], platform: "IOS"))
        #expect(probe.section == .quickRelease)
        let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds)); root.cacheDisplay(in: root.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: TestIsolation.require().appendingPathComponent("quick-release-focus-\(Int(width)).png"))
    }
}
