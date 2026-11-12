import AppKit
import SwiftUI
import Testing
@testable import StorebenchApp
@testable import StorebenchCore

@MainActor @Suite(.serialized) struct LibraryNavigationTests {
    init() throws { _ = try TestIsolation.require() }

    private struct Fixture {
        let model: WorkspaceController, session: WorkspaceSession, root: URL, accounts: [Account]
        var account: Account { accounts[0] }
        var app: Account.App { account.apps.first { $0.id == "1000000001" }! }
        var appID: String { account.id + "/" + app.id }
    }
    private func fixture(plan: Bool = false) async throws -> Fixture {
        let owned = try TestIsolation.require(), root = owned.appendingPathComponent("synthetic-navigation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("state-v2"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let database = EncryptedDocumentStore.databaseURL(root: root)
        try FileManager.default.copyItem(at: owned.appendingPathComponent("native-fixtures/storebench-v2.sqlite"), to: database)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: database.path)
        let key = Data(0..<32).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let record = JSONText.object([("schemaVersion", .number(1)), ("phase", .string("ready")), ("envelope", .object([("version", .number(1)), ("mode", .string("device")), ("key", .string(key))]))])
        let data = JSONText.object([("version", .number(1)), ("entries", .object([(CredentialVault.databaseEntry(root: root), .string(record.stringify()))]))]).data
        let writer = VaultWriter(dataRoot: root, storage: MemoryVaultStorage(data))
        let model = WorkspaceController(workspace: Workspace(root: root), writer: writer, backupDelay: .seconds(3600), availabilityDelay: .seconds(3600), releaseWarmDelay: nil)
        await model.start()
        let session = try #require(model.session), accounts = try await session.accounts()
        let account = try #require(accounts.first)
        if plan {
            _ = try await session.saveReleasePlan(account: account, appId: "1000000001", start: .reuse,
                sourceRevisionId: "00000000-0000-4000-8000-000000000002", baseVersionId: "version-1", targetVersion: "2.0",
                releaseType: "MANUAL", earliestReleaseDate: nil, expected: "null")
        }
        return Fixture(model: model, session: session, root: root, accounts: accounts)
    }
    private func withFixture(plan: Bool = false, _ body: @MainActor (Fixture) async throws -> Void) async throws {
        let f = try await fixture(plan: plan)
        do { try await body(f) }
        catch { await f.model.prepareToTerminate(); try? FileManager.default.removeItem(at: f.root); throw error }
        await f.model.prepareToTerminate()
        try FileManager.default.removeItem(at: f.root)
    }

    @MainActor private final class Window {
        enum Failure: Error { case timeout(String), missing(String), disabled(String) }
        let window: NSWindow, host: NSHostingView<AnyView>, shortcuts: ShortcutActions
        init(_ fixture: Fixture, initial: LibraryLocation = LibraryLocation()) {
            _ = NSApplication.shared
            let shortcuts = ShortcutActions(); self.shortcuts = shortcuts
            window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1280, height: 900), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            host = NSHostingView(rootView: AnyView(LibraryView(accounts: fixture.accounts, model: fixture.model, initialLocation: initial)
                .environment(fixture.model)
                .environment(\.shortcutActions, shortcuts)
                .modifier(StorebenchAppearance()).transaction { $0.animation = nil; $0.disablesAnimations = true }))
            window.contentView = host; window.makeKeyAndOrderFront(nil)
        }
        func close() { window.contentView = nil; window.orderOut(nil); window.close() }
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        func marker(_ id: String) -> StorebenchControlMarker? {
            views(host).compactMap { $0 as? StorebenchControlMarker }.first { $0.identifier?.rawValue == id }
        }
        func settle() async throws {
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
        func wait(_ description: String, _ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(15)
            while !condition() {
                guard ContinuousClock.now < deadline else {
                    let controls = views(host).compactMap { ($0 as? StorebenchControlMarker)?.identifier?.rawValue }.prefix(40)
                    throw Failure.timeout(description + "; controls: " + controls.joined(separator: ", "))
                }
                try await settle()
            }
            try await settle()
        }
        func press(_ id: String, disclosure: Bool = false) async throws {
            window.makeKeyAndOrderFront(nil)
            try await wait(id) { marker(id) != nil }
            let target = try #require(marker(id))
            guard target.available else { throw Failure.disabled(id) }
            var ancestor = target.superview
            while let view = ancestor {
                if let scroll = view as? NSScrollView, let document = scroll.documentView {
                    let rect = target.convert(target.bounds, to: document)
                    document.scrollToVisible(rect)
                }
                ancestor = view.superview
            }
            try await settle()
            let inset = StorebenchTheme.space(2) + StorebenchTheme.measure("disclosureIcon") / 2
            let localPoint = disclosure
                ? CGPoint(x: target.bounds.minX + inset, y: target.isFlipped ? target.bounds.minY + inset + 6 : target.bounds.maxY - inset - 6)
                : CGPoint(x: target.bounds.midX, y: target.bounds.midY)
            let point = target.convert(localPoint, to: nil)
            if let native = views(host).compactMap({ $0 as? NSControl }).first(where: {
                $0.cell is NSButtonCell && !$0.isHiddenOrHasHiddenAncestor && $0.convert($0.bounds, to: nil).contains(point)
            }) {
                guard native.isEnabled else { throw Failure.disabled(id) }
                native.performClick(nil)
            }
            else {
                for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = try #require(NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: kind == .leftMouseDown ? 1 : 0))
                    window.sendEvent(event)
                }
            }
            try await settle()
        }
        func expectApp(_ fixture: Fixture, section: AppNavigation.Section) async throws {
            try await wait("App " + section.key) { marker("library.app." + fixture.appID + "." + section.key) != nil }
        }
    }

    @Test func localizationsAppReturnsToItsChooserAndForwardReopensTheApp() async throws {
        try await withFixture(plan: true) { f in
            let ui = Window(f); defer { ui.close() }
            try await ui.press("sidebar.Localizations")
            try await ui.wait("Localizations chooser") { ui.marker("library.chooser.localizations") != nil }
            try await ui.press("collection.open." + f.appID)
            try await ui.expectApp(f, section: .localizations)
            try await ui.wait("Loaded version draft") { ui.marker("workspace.version-source.draft") != nil }
            try await ui.press("navigation.back")
            try await ui.wait("Back to Localizations chooser") { ui.marker("library.chooser.localizations") != nil }
            try await ui.press("navigation.forward")
            try await ui.expectApp(f, section: .localizations)
            try await ui.wait("Back shortcut") { ui.shortcuts.enabled(.back) }
            #expect(ui.shortcuts.perform(.back))
            try await ui.wait("Back to the same chooser again") { ui.marker("library.chooser.localizations") != nil }
            try await ui.wait("Forward shortcut") { ui.shortcuts.enabled(.forward) }
            #expect(ui.shortcuts.perform(.forward))
            try await ui.expectApp(f, section: .localizations)
            try await ui.wait("Draft restored") { ui.marker("workspace.version-source.draft") != nil }
            try await ui.press("workspace.version-source.draft")
            try await ui.wait("Imported version selected") { ui.marker("workspace.version-source.imported") != nil }
            try await ui.press("navigation.back")
            try await ui.wait("Back to draft") { ui.marker("workspace.version-source.draft") != nil }
            try await ui.press("navigation.back")
            try await ui.wait("Back to chooser after explicit version choice") { ui.marker("library.chooser.localizations") != nil }
            try await ui.press("navigation.forward")
            try await ui.expectApp(f, section: .localizations)
            try await ui.press("navigation.forward")
            try await ui.wait("Forward restores the imported version after reopening the app") { ui.marker("workspace.version-source.imported") != nil }
        }
    }

    @Test func leavingAnEditorDoesNotAddAnInvisibleContextCleanupStep() async throws {
        try await withFixture { f in
            let scope = try RecoveryGuidance.Scope(accountId: f.account.id, appId: f.app.id)
            let context = try AppNavigation.Context(scope: scope, locale: "en-US", version: "version-1")
            let ui = Window(f, initial: LibraryLocation(selection: f.appID, section: .localizations, context: context))
            defer { ui.close() }
            try await ui.expectApp(f, section: .localizations)
            try await ui.press("sidebar.App Information")
            try await ui.expectApp(f, section: .information)
            for _ in 0..<3 { try await ui.settle() }
            try await ui.press("navigation.back")
            try await ui.expectApp(f, section: .localizations)
            try await ui.press("navigation.forward")
            try await ui.expectApp(f, section: .information)
        }
    }

    @Test func everyAppChooserCanGoBackAndForwardAndANewVisitClearsForward() async throws {
        try await withFixture { f in
            let ui = Window(f); defer { ui.close() }
            for section in LibraryChooser.sections {
                try await ui.press("sidebar.Overview")
                try await ui.press("sidebar." + section.title)
                try await ui.wait("Chooser " + section.key) { ui.marker("library.chooser." + section.key) != nil }
                if section == .media {
                    for _ in 0..<3 { try await ui.settle() }
                    if ui.marker("library.open." + f.appID) == nil { try await ui.press("collection.disclosure." + f.appID, disclosure: true) }
                }
                try await ui.press((section == .media ? "library.open." : "collection.open.") + f.appID)
                try await ui.expectApp(f, section: section)
                try await ui.press("navigation.back")
                try await ui.wait("Back to " + section.key) { ui.marker("library.chooser." + section.key) != nil }
                try await ui.press("navigation.forward")
                try await ui.expectApp(f, section: section)
            }
            try await ui.press("navigation.back")
            try await ui.wait("Last chooser") { ui.marker("library.chooser.test-information") != nil }
            try await ui.press("sidebar.Apps")
            try await ui.wait("A new visit clears Forward") { ui.marker("navigation.forward")?.available == false }
        }
    }

    @Test func everySidebarDestinationHasOneHistoryEntryDespiteDepartingEditorCleanup() throws {
        let scope = try RecoveryGuidance.Scope(accountId: "synthetic-account", appId: "1000000001")
        let context = try AppNavigation.Context(scope: scope, locale: "en-US", version: "synthetic-version", draft: true)
        let editor = LibraryLocation(selection: "synthetic-account/1000000001", section: .localizations, context: context)
        for section in AppNavigation.Section.allCases where !section.usesLanguage {
            var history = NavigationHistory(editor.normalized)
            var next = editor; next.section = section
            history.visit(next.normalized)
            next.context = nil
            history.visit(next.normalized)
            #expect(history.count == 2, "Context cleanup must not add a step for \(section.key)")
            #expect(history.commit(try #require(history.request(.back))))
            #expect(history.current == editor && history.current.context == context)
            #expect(history.commit(try #require(history.request(.forward))))
            #expect(history.current.section == section && history.current.context == nil)
        }
        for section in LibraryChooser.sections {
            var history = NavigationHistory(editor.normalized)
            let chooser = LibraryLocation(selection: LibraryChooser.selection(section), section: editor.section, context: context)
            history.visit(chooser.normalized)
            history.visit(LibraryLocation(selection: chooser.selection).normalized)
            #expect(history.count == 2)
            #expect(history.commit(try #require(history.request(.back))) && history.current == editor)
            #expect(history.commit(try #require(history.request(.forward))) && history.current.selection == chooser.selection)
        }
    }

    @Test func switchingAppsKeepsEachAppsOwnEditorContextAndNewNavigationBranches() throws {
        let first = try RecoveryGuidance.Scope(accountId: "synthetic-account", appId: "1000000001")
        let second = try RecoveryGuidance.Scope(accountId: "synthetic-account", appId: "1000000002")
        let firstContext = try AppNavigation.Context(scope: first, locale: "en-US", version: "synthetic-first", draft: true)
        let secondContext = try AppNavigation.Context(scope: second, locale: "sv", version: "synthetic-second")
        let firstApp = LibraryLocation(selection: "synthetic-account/1000000001", section: .localizations, context: firstContext)
        let secondApp = LibraryLocation(selection: "synthetic-account/1000000002", section: .media, context: secondContext)
        var history = NavigationHistory(firstApp.normalized)
        history.visit(secondApp.normalized)
        #expect(history.commit(try #require(history.request(.back))) && history.current == firstApp)
        #expect(history.commit(try #require(history.request(.forward))) && history.current == secondApp)
        #expect(history.commit(try #require(history.request(.back))))
        history.visit(LibraryLocation(selection: "library:apps").normalized)
        #expect(!history.canGoForward && history.current.selection == "library:apps")
        var foreign = secondApp; foreign.context = firstContext
        #expect(foreign.normalized.context == nil)
        let keywords = LibraryLocation(selection: firstApp.selection, section: .keywords, context: firstContext).normalized
        #expect(keywords.context?.locale == "en-US" && keywords.context?.version == nil && keywords.context?.draft == false)
    }
}
