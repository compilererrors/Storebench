import AppKit
import Observation
import SwiftUI
import Testing
@testable import StorebenchApp
@testable import StorebenchCore

@MainActor @Suite(.serialized) struct ReleaseCardAndSettingsTests {
    init() throws { _ = try TestIsolation.require() }
    private enum Failure: Error { case timeout(String) }
    private struct Fixture {
        let model: WorkspaceController, session: WorkspaceSession, root: URL
    }
    private func fixture() async throws -> Fixture {
        let owned = try TestIsolation.require(), root = owned.appendingPathComponent("synthetic-release-layout-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("state-v2"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.copyItem(at: owned.appendingPathComponent("native-fixtures/storebench-v2.sqlite"), to: EncryptedDocumentStore.databaseURL(root: root))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: EncryptedDocumentStore.databaseURL(root: root).path)
        let key = Data(0..<32).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let envelope = JSONText.object([("schemaVersion", .number(1)), ("phase", .string("ready")), ("envelope", .object([("version", .number(1)), ("mode", .string("device")), ("key", .string(key))]))])
        let vault = MemoryVaultStorage(JSONText.object([("version", .number(1)), ("entries", .object([(CredentialVault.databaseEntry(root: root), .string(envelope.stringify()))]))]).data)
        let model = WorkspaceController(workspace: Workspace(root: root), writer: VaultWriter(dataRoot: root, storage: vault), keychainStorage: vault,
            protectedStorage: vault, backupDelay: .seconds(3600), availabilityDelay: .seconds(3600), releaseWarmDelay: nil,
            backgroundReadInterval: .seconds(3600), preparationInterval: .seconds(3600))
        await model.start()
        return Fixture(model: model, session: try #require(model.session), root: root)
    }
    private func withFixture(_ body: @MainActor (Fixture) async throws -> Void) async throws {
        let value = try await fixture()
        do { try await body(value) }
        catch { await value.model.prepareToTerminate(); try? FileManager.default.removeItem(at: value.root); throw error }
        await value.model.prepareToTerminate(); try FileManager.default.removeItem(at: value.root)
    }
    private func release(_ id: String, version: String = "2.0") throws -> LibraryOverview.Release {
        let account = Account(id: "synthetic-layout", name: "Synthetic Account", keyId: "SYNTHKEY01", keyType: "individual", issuerId: nil,
                              appIds: [id], appNames: [id: "Synthetic App " + String(id.suffix(1))])
        let app = try #require(account.apps.first)
        let plan = try #require(ReleasePlan(.object([("accountId", .string(account.id)), ("appId", .string(id)),
            ("sourceRevisionId", .string("00000000-0000-4000-8000-000000000002")), ("baseVersionId", .string("version-1")),
            ("platform", .string("MAC_OS")), ("targetVersion", .string(version)), ("releaseType", .string("MANUAL")), ("updatedAt", .string("2026-01-01T00:00:00.000Z"))])))
        var row = try ConnectedApps.Row(account: account, app: app, savedName: "Synthetic App " + String(id.suffix(1)), revisionCount: 1)
        let steps = ["copyright", "build", "review-info"].map { ReleaseReadiness.Step(id: $0, label: "Synthetic Requirement " + $0, detail: "Synthetic requirement", href: "", action: "Open Release", state: .blocked, territories: nil, guideHref: nil) }
        let snapshot = ReleaseReadinessSnapshot(scope: try .init(accountId: account.id, appId: id), plan: plan, steps: steps,
            materialSignature: "synthetic-material", targetVersionId: "version-2", targetState: "PREPARE_FOR_SUBMISSION")
        row.release = ReleaseOverview(plan: plan, snapshot: snapshot, status: nil)
        return LibraryOverview.Release(app: row, plan: plan)
    }
    private func key(_ value: LibraryOverview.Release) -> String {
        ReleaseCardPreferences.key(accountId: value.plan.accountId, appId: value.plan.appId, platform: value.plan.platform, version: value.plan.targetVersion)
    }
    @MainActor @Observable final class Cards {
        var releases: [LibraryOverview.Release] = []
        var opens = 0
        var precedingHeight: CGFloat = 0
        var followingHeight: CGFloat = 0
    }
    private struct Portfolio: View {
        let cards: Cards, session: WorkspaceSession
        var body: some View {
            ScrollView {
                VStack(spacing: 0) {
                Color.clear.frame(height: cards.precedingHeight).accessibilityHidden(true)
                ReleaseOverviewList(releases: cards.releases, session: session, unavailable: false,
                    icon: { _ in AnyView(StorebenchIcon(name: "apps", size: 24)) }, open: { _ in cards.opens += 1 }).padding(20)
                Color.clear.frame(height: cards.followingHeight).accessibilityHidden(true)
                }
            }.modifier(StorebenchAppearance())
        }
    }
    @MainActor private final class Window {
        let window: NSWindow, host: NSHostingView<AnyView>
        init<V: View>(_ view: V, width: CGFloat = 720, height: CGFloat = 900) {
            _ = NSApplication.shared
            window = NSWindow(contentRect: .init(x: 0, y: 0, width: width, height: height), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; host = NSHostingView(rootView: AnyView(view)); window.contentView = host; window.makeKeyAndOrderFront(nil)
        }
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        func marker(_ id: String) -> StorebenchControlMarker? { views(host).compactMap { $0 as? StorebenchControlMarker }.first { $0.identifier?.rawValue == id } }
        var question: NSWindow? { window.sheets.first { $0.identifier?.rawValue == "release.cards.suggestion" } }
        func questionButton(_ id: String) -> NSButton? {
            question?.contentView.flatMap { views($0).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == id } }
        }
        func settle() async throws { host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try await Task.sleep(for: .milliseconds(50)) }
        func wait(_ detail: String, _ condition: () async throws -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(20)
            while !(try await condition()) { guard ContinuousClock.now < deadline else { throw Failure.timeout(detail) }; try await settle() }
            try await settle()
        }
        func frame(_ id: String) throws -> CGRect { let view = try #require(marker(id)); return view.convert(view.bounds, to: host) }
        func place(_ id: String, top: CGFloat) async throws {
            try await wait("Missing control " + id) { self.marker(id) != nil }
            let target = try #require(marker(id)), scroll = try #require(target.enclosingScrollView), document = try #require(scroll.documentView)
            let frame = target.convert(target.bounds, to: document), clip = scroll.contentView
            var viewport = clip.bounds; viewport.origin.y = clip.isFlipped ? frame.minY - top : frame.maxY + top - viewport.height
            clip.scroll(to: clip.constrainBoundsRect(viewport).origin); scroll.reflectScrolledClipView(clip)
            try await settle()
        }
        func press(_ id: String, reveal: Bool = true, settleAfter: Bool = true) async throws {
            if id.hasPrefix("release.cards.suggestion.") {
                try await wait("Native question button " + id) { self.questionButton(id) != nil }
                try #require(questionButton(id)).performClick(nil)
                if settleAfter { try await settle() }; return
            }
            try await wait("Missing control " + id) { self.marker(id) != nil }
            let target = try #require(marker(id)); window.makeKeyAndOrderFront(nil)
            var ancestor = reveal ? target.superview : nil
            while let view = ancestor {
                if let scroll = view as? NSScrollView, let document = scroll.documentView { document.scrollToVisible(target.convert(target.bounds, to: document)) }
                ancestor = view.superview
            }
            if reveal { try await settle() }
            let point = target.convert(CGPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
            if let native = views(host).compactMap({ $0 as? NSControl }).first(where: { $0.cell is NSButtonCell && !$0.isHiddenOrHasHiddenAncestor && $0.convert($0.bounds, to: nil).contains(point) }) {
                #expect(native.isEnabled); native.performClick(nil)
            } else {
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    window.sendEvent(try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)))
                }
            }
            if settleAfter { try await settle() }
        }
        func edit(_ field: NSTextField, value: String) throws {
            field.scrollToVisible(field.bounds); window.makeFirstResponder(field)
            let editor = try #require(window.fieldEditor(true, for: field) as? NSTextView)
            editor.selectAll(nil); editor.insertText(value, replacementRange: editor.selectedRange())
        }
        func search(_ value: String) throws {
            let marker = try #require(marker("settings.search")), frame = marker.convert(marker.bounds, to: host)
            let field = try #require(views(host).compactMap { $0 as? NSTextField }.first { $0.isEditable && !($0 is NSSecureTextField) && frame.intersects($0.convert($0.bounds, to: host)) })
            try edit(field, value: value)
        }
        func capture(_ name: String, question: Bool = false) throws {
            let root: NSView = question ? try #require(self.question?.contentView?.superview) : host
            let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds)); root.cacheDisplay(in: root.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: TestIsolation.require().appendingPathComponent(name + ".png"))
        }
        func close() {
            for sheet in window.sheets { window.endSheet(sheet, returnCode: .abort); sheet.orderOut(nil) }
            StorebenchScrollFocus.cancel(in: window); window.contentView = nil; window.orderOut(nil); window.close()
        }
    }

    @Test(arguments: [CGFloat(380), CGFloat(1100)])
    func releaseCardsMinimizeIndependentlyRememberVersionsAndOfferTheDefault(_ width: CGFloat) async throws {
        try await withFixture { fixture in
            let cards = Cards(); cards.releases = try [release("1000000001"), release("1000000002")]
            let first = cards.releases[0], second = cards.releases[1], id = "continue.release." + first.id, other = "continue.release." + second.id
            var ui = Window(Portfolio(cards: cards, session: fixture.session), width: width)
            defer { ui.close() }
            try await ui.wait("Release cards") { ui.marker(id + ".disclosure") != nil }
            let fullHeight = try ui.frame(id).height, otherHeight = try ui.frame(other).height
            if width == 1100 { try ui.capture("release-cards-expanded") }
            try await ui.press(id + ".disclosure")
            try await ui.wait("Remember first minimize") { try await fixture.session.releaseCardPreferences().expanded(key(first)) == false }
            #expect(try ui.frame(id).height < fullHeight - 70)
            #expect(try abs(ui.frame(other).height - otherHeight) < 1)
            #expect(ui.question == nil)
            #expect(try ui.frame(id).contains(ui.frame(id + ".open")))
            let ownerFrame = ui.window.frame
            try await ui.press(other + ".disclosure")
            try await ui.wait("Native question after minimizing every card") { ui.questionButton("release.cards.suggestion.yes") != nil }
            let question = try #require(ui.question), surface = try #require(question.contentView)
            try await ui.wait("Visible native question") { question.isVisible && question.alphaValue > 0.99 }
            try await Task.sleep(for: .milliseconds(250))
            question.displayIfNeeded()
            #expect(question.sheetParent === ui.window && ui.window.frame == ownerFrame)
            #expect(question.frame.width <= 500 && question.frame.height <= 450)
            for choice in ["yes", "later", "no"] {
                let button = try #require(ui.questionButton("release.cards.suggestion." + choice))
                #expect(surface.bounds.contains(button.convert(button.bounds, to: surface)))
            }
            if width == 1100 { try ui.capture("release-cards-minimized"); try ui.capture("release-cards-question", question: true) }
            try await ui.press("release.cards.suggestion.yes")
            try await ui.wait("Save minimized default") { try await fixture.session.releaseCardPreferences().defaultExpanded == false }
            #expect(ui.question == nil)
            cards.releases.append(try release("1000000003"))
            let third = try #require(cards.releases.last)
            try await ui.wait("New release follows the default") { ui.marker("continue.release." + third.id + ".disclosure") != nil }
            #expect(try ui.frame("continue.release." + third.id).height < fullHeight - 70)
            try await ui.press(id + ".disclosure")
            try await ui.wait("Remember expanded release") { try await fixture.session.releaseCardPreferences().expanded(key(first)) }
            ui.close(); ui = Window(Portfolio(cards: cards, session: fixture.session), width: width)
            try await ui.wait("Restore the same versions") { ui.marker(id + ".disclosure") != nil }
            #expect(try abs(ui.frame(id).height - fullHeight) < 1)
            #expect(try ui.frame(other).height < fullHeight - 70)
            #expect(ui.question == nil)
            try await ui.press(id + ".open")
            #expect(cards.opens == 1)
        }
    }

    @Test func settingsSearchOpensTheSettingSavesTheDefaultAndKeepsHiddenEdits() async throws {
        try await withFixture { fixture in
            let defaults = try #require(UserDefaults(suiteName: "synthetic-settings-search-" + UUID().uuidString))
            defaults.set("general", forKey: "settings.pane")
            let ui = Window(SettingsView(model: fixture.model, recovery: RecoveryCoordinator()).environment(fixture.model)
                .defaultAppStorage(defaults).modifier(StorebenchAppearance()), height: 700)
            defer { ui.close() }
            try await ui.wait("Settings search") { ui.marker("settings.search") != nil }
            try ui.search("minimize release")
            try await ui.wait("Release card search result") { ui.marker("collection.open.general-release-cards") != nil }
            try ui.capture("settings-search-release-cards")
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                ui.window.sendEvent(try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: ui.window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)))
            }
            try await ui.wait("Release card preference") { ui.marker("settings.release-cards.default") != nil && ui.marker("settings.search.results") == nil }
            let popup = try #require(ui.views(ui.host).compactMap { $0 as? NSPopUpButton }.first { $0.itemTitles == ["Expanded", "Minimized"] })
            try await ui.wait("Search reveals the setting in its viewport") {
                guard let scroll = popup.enclosingScrollView, let document = scroll.documentView else { return false }
                return scroll.contentView.bounds.contains(popup.convert(popup.bounds, to: document))
            }
            popup.selectItem(withTitle: "Minimized"); _ = popup.sendAction(popup.action, to: popup.target)
            try await ui.wait("Setting saved") { try await fixture.session.releaseCardPreferences().defaultExpanded == false }
            try ui.search("encrypted local storage")
            try await ui.press("collection.open.security-storage")
            try await ui.wait("Password input") { !ui.views(ui.host).compactMap { $0 as? NSSecureTextField }.isEmpty && ui.marker("settings.search.results") == nil }
            let field = try #require(ui.views(ui.host).compactMap { $0 as? NSSecureTextField }.first)
            try ui.edit(field, value: "synthetic-unsaved-text")
            try ui.search("keyboard")
            try await ui.wait("Search from an unsaved editor") { ui.marker("collection.open.shortcuts-keyboard") != nil }
            try ui.search("")
            try await ui.wait("Return to the same editor") { ui.marker("settings.search.results") == nil }
            #expect(field.stringValue == "synthetic-unsaved-text")
            #expect(ui.views(ui.host).contains { $0 === field })
        }
    }

    @Test(arguments: ["later", "no"])
    func decliningTheSuggestionDoesNotReopenItOnTheNextVisit(_ answer: String) async throws {
        try await withFixture { fixture in
            let cards = Cards(); cards.releases = try [release("1000000001")]
            let id = "continue.release." + cards.releases[0].id
            var ui = Window(Portfolio(cards: cards, session: fixture.session))
            defer { ui.close() }
            try await ui.press(id + ".disclosure")
            try await ui.press("release.cards.suggestion." + answer)
            try await ui.wait("Remember the suggestion answer") { try await fixture.session.releaseCardPreferences().canSuggest(at: Date()) == false }
            let saved = try await fixture.session.releaseCardPreferences()
            #expect(saved.defaultExpanded)
            #expect(answer == "no" ? !saved.asksAboutMinimizing : saved.askAfter != nil)
            ui.close(); ui = Window(Portfolio(cards: cards, session: fixture.session))
            try await ui.wait("Restore the minimized card") { ui.marker(id + ".disclosure") != nil }
            #expect(ui.question == nil)
        }
    }

    @Test(arguments: [CGFloat(420), CGFloat(1100)], [CGFloat(0), CGFloat(1100)])
    func repeatedDisclosureChangesKeepTheWorkingHeaderAtTheSamePosition(_ width: CGFloat, _ following: CGFloat) async throws {
        try await withFixture { fixture in
            _ = try await fixture.session.updateReleaseCardPreferences(.suggestions(false))
            let cards = Cards(); cards.releases = try [release("1000000001"), release("1000000002")]
            cards.precedingHeight = 900; cards.followingHeight = following
            let ui = Window(Portfolio(cards: cards, session: fixture.session), width: width, height: 700)
            defer { ui.close() }
            let id = "continue.release." + cards.releases[1].id + ".disclosure"
            try await ui.place(id, top: 280)
            let before = try ui.frame(id).origin
            for _ in 0..<4 {
                try await ui.press(id, reveal: false, settleAfter: false)
                var samples: [CGPoint] = []
                for _ in 0..<25 {
                    ui.host.layoutSubtreeIfNeeded(); ui.window.displayIfNeeded()
                    samples.append(try ui.frame(id).origin)
                    try await Task.sleep(for: .milliseconds(16))
                }
                #expect(samples.allSatisfy { abs($0.x - before.x) < 1 && abs($0.y - before.y) < 1 }, "Header moved across disclosure frames: \(samples)")
                #expect(ui.question == nil)
            }
        }
    }
    @Test(arguments: [CGFloat(420), CGFloat(1100)])
    func theNativeQuestionAndItsDismissalKeepTheScrolledCardInPlace(_ width: CGFloat) async throws {
        try await withFixture { fixture in
            let cards = Cards(); cards.releases = try [release("1000000001"), release("1000000002")]
            cards.precedingHeight = 900
            _ = try await fixture.session.updateReleaseCardPreferences(.observe(cards.releases.map(key)))
            _ = try await fixture.session.updateReleaseCardPreferences(.expanded([key(cards.releases[0])], false))
            let ui = Window(Portfolio(cards: cards, session: fixture.session), width: width, height: 700)
            defer { ui.close() }
            let id = "continue.release." + cards.releases[1].id + ".disclosure"
            try await ui.place(id, top: 240)
            let before = try ui.frame(id).origin
            try await ui.press(id, reveal: false, settleAfter: false)
            for _ in 0..<30 {
                try await ui.settle()
                let point = try ui.frame(id).origin
                #expect(abs(point.x - before.x) < 1 && abs(point.y - before.y) < 1)
            }
            try await ui.wait("Native overlay") { ui.question != nil }
            try await ui.press("release.cards.suggestion.no", settleAfter: false)
            for _ in 0..<20 {
                try await ui.settle()
                let point = try ui.frame(id).origin
                #expect(abs(point.x - before.x) < 1 && abs(point.y - before.y) < 1)
            }
            #expect(ui.question == nil)
        }
    }

}
