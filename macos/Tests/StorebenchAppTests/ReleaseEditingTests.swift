import AppKit
import Observation
import SwiftUI
import Testing
@testable import StorebenchApp
@testable import StorebenchCore

@MainActor @Observable final class ReleaseEditingPresentation {
    var focus: ReleaseFieldFocus?
    var finished = 0
    var requests: [PublishRequest] = []
    var failPreparation = false
    var noChanges = false
    var emptyReview = false
    var otherReads = 0
    var refreshChoices: [EditorRefresh.Choice] = []
    var delayedParentBusy = false
    var parentBusy = false
    var planBlocked = false
    var saves = 0
}

@MainActor @Suite(.serialized) struct ReleaseEditingTests {
    init() throws { _ = try TestIsolation.require() }
    @MainActor private struct MediaGuideFixture: View {
        let presentation: ReleaseEditingPresentation
        var longCopy = false
        static let title = "App Previews and Screenshots · Synthetic Language With a Deliberately Longer Name"
        static let detail = "Review this language’s saved media and add screenshots or previews below. Each change stays in the local draft until a separate Apple review is approved."
        static let hint = "Done saves the local draft and returns to the release checklist. Check the language, display size and media order before choosing Sync to Apple. This instruction must remain readable in a narrow editing pane."
        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                if longCopy {
                    StorebenchEditorGuide(title: Self.title, detail: Self.detail, hint: Self.hint, identifier: "synthetic.media-guide") {
                        Button("Done") { presentation.finished += 1 }.storebenchControlID("synthetic.media-done")
                    }
                } else {
                    ReleaseMediaEditingGuide(locale: "en-GB", busy: presentation.parentBusy) { presentation.finished += 1 }
                }
                Card(title: "App Previews", subtitle: "Saved on this Mac") {
                    Text("No app previews yet. Choose Add Preview to add a video.")
                    StorebenchActionGroup { Button("Add Preview…") {} }
                }.storebenchControlID("synthetic.previews-card")
                Card(title: "Screenshots", subtitle: "Choose the display size for this language.") {
                    Text("No screenshots yet. Add images before returning to the checklist.")
                    StorebenchActionGroup { Button("Add Screenshots…") {} }
                }
            }.modifier(StorebenchAppearance())
        }
    }
    @MainActor private struct CopyrightForm: View {
        let account: Account, app: Account.App, version: PublishingWorkspace.Version, choices: PublishingWorkspace.Snapshot
        let presentation: ReleaseEditingPresentation
        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                AppleProblemsView(problems: [AppleProblem(code: "ENTITY_ERROR.ATTRIBUTE.REQUIRED", resource: "appStoreVersions", field: "copyright")], fix: { id in
                    if id == "copyright" { presentation.finished += 1; presentation.focus = .init(anchor: "publish.copyright") }
                })
                PublishActionPanel(account: account, app: app, session: nil, actions: [.copyright],
                    initialRequest: .init(accountId: account.id, appId: app.id, scope: .versionCopyright, versionId: version.id), initialChoices: choices,
                    guided: ("Copyright", "Enter the year and rights holder, then review the change."))
            }
            .environment(\.releaseFieldFocus, presentation.focus)
            .modifier(StorebenchAppearance())
        }
    }

    @MainActor private struct Fixture: View {
        let root: URL, controller: WorkspaceController, session: WorkspaceSession, account: Account, revision: Revision, version: Revision.Version
        let owner: LanguageDraftEditor, layout: LanguageLayoutEditor, presentation: ReleaseEditingPresentation
        let targetMode, locale: String
        var body: some View { view }
        var view: some View {
            LanguageEditor(account: account, revision: revision, version: version,
                scope: .init(accountId: account.id, appId: revision.app.id, revisionId: revision.id, local: false), locale: locale, targetMode: targetMode, session: session,
                openReview: { _ in false }, providedModel: owner, contained: true,
                reviewPreparer: { _, _, request in
                    presentation.requests.append(request)
                    if presentation.delayedParentBusy {
                        presentation.parentBusy = true
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    if presentation.failPreparation { throw PublishFailure.invalid("Synthetic text preparation failed.") }
                    if presentation.noChanges { throw PublishFailure.noChanges }
                    let step = PublishStep(key: "synthetic-text", group: nil, label: "Update English (U.K.) Text", detail: "Description",
                        before: "Synthetic original", after: "Synthetic British text", kind: .api, method: "PATCH", path: [.string("appStoreVersionLocalizations"), .string("version-locale-1")],
                        body: nil, asset: nil, guardValue: nil, state: "pending", resultId: nil)
                    let review = PublishReview(plan: .init(title: "Synthetic British text review", request: request, fingerprint: JSONText.string("Synthetic review").sha256,
                        steps: presentation.emptyReview ? [] : [step], notes: []), id: UUID().uuidString.lowercased(), now: Date())
                    return .init(source: request, review: review)
                })
                .environment(controller).environment(\.languageLayout, layout).environment(\.releaseFieldFocus, presentation.focus)
                .environment(\.draftWorkflowBusy, presentation.parentBusy || owner.workflow.busy)
                .environment(\.releaseChecklistReturn, { presentation.finished += 1; presentation.focus = nil })
                .modifier(StorebenchAppearance())
        }
        func close() async {
            owner.retire(); await controller.prepareToTerminate(); try? FileManager.default.removeItem(at: root)
        }
    }
    private func fixture(targetMode: String = "apple-version", locale: String = "en-GB", sharedLayout: LanguageLayoutEditor? = nil) async throws -> Fixture {
        let run = try TestIsolation.require(), root = run.appendingPathComponent("synthetic-release-editing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("state-v2"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.copyItem(at: run.appendingPathComponent("native-fixtures/storebench-v2.sqlite"), to: EncryptedDocumentStore.databaseURL(root: root))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: EncryptedDocumentStore.databaseURL(root: root).path)
        let key = Data(0..<32).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let record = JSONText.object([("schemaVersion", .number(1)), ("phase", .string("ready")), ("envelope", .object([("version", .number(1)), ("mode", .string("device")), ("key", .string(key))]))])
        let vault = JSONText.object([("version", .number(1)), ("entries", .object([(CredentialVault.databaseEntry(root: root), .string(record.stringify()))]))])
        let controller = WorkspaceController(workspace: Workspace(root: root), writer: VaultWriter(dataRoot: root, storage: MemoryVaultStorage(vault.data)), releaseWarmDelay: nil)
        await controller.start()
        let session = try #require(controller.session), account = try #require(try await session.accounts().first)
        let revision = try #require(try await session.revisions(accountId: account.id, appId: "1000000001").first { $0.id == "00000000-0000-4000-8000-000000000002" })
        let version = try #require(revision.versions.first { $0.id == "version-1" })
        func section(_ scope: TextDrafts.Scope, id: String) -> LanguageDrafts.Section {
            let names = scope == .version ? TextDrafts.versionFields : TextDrafts.appInfoFields
            let values = ["name": "Synthetic App", "subtitle": "Synthetic subtitle", "description": String(repeating: "Synthetic description. ", count: 60),
                "promotionalText": "Synthetic promotion", "keywords": "synthetic,notes", "supportUrl": "https://example.test/support", "marketingUrl": "https://example.test/product",
                "privacyPolicyUrl": "https://example.test/privacy", "privacyChoicesUrl": "https://example.test/choices", "privacyPolicyText": "Synthetic privacy information."]
            let fields = Dictionary(uniqueKeysWithValues: names.map { ($0, values[$0] ?? "") })
            return .init(selection: .init(id: id, scope: scope), imported: fields, draft: .init(fields: fields, fingerprint: TextDrafts.fingerprint(fields), edited: false))
        }
        let sections = [section(.version, id: "version-locale-1"), section(.appInfo, id: "info-locale-1")]
        var stored = sections
        let workflow = ListingSaveWorkflow(identity: "Synthetic partial text UI"), presentation = ReleaseEditingPresentation()
        workflow.register(priority: .text, required: true, state: { .init(dirty: false, blocked: presentation.planBlocked, signature: "Synthetic saved version plan") }, save: { true })
        workflow.register(priority: .file, state: { .init(dirty: true, blocked: true, signature: "Synthetic unfinished screenshot selection") }, save: { Issue.record("Text must not save unrelated media"); return false })
        let owner = LanguageDraftEditor(scope: .init(accountId: account.id, appId: revision.app.id, revisionId: revision.id), versionId: version.id, locale: locale, selections: sections.map(\.selection), workflow: workflow,
            read: { stored }, save: { entries in
                try await Task.sleep(for: .milliseconds(60))
                presentation.saves += 1
                stored = stored.map { section in
                    guard let entry = entries.first(where: { $0.selection.id == section.selection.id && $0.selection.scope == section.selection.scope }) else { return section }
                    return .init(selection: section.selection, imported: section.imported,
                                 draft: .init(fields: entry.fields, fingerprint: TextDrafts.fingerprint(entry.fields), edited: true))
                }
                return Dictionary(uniqueKeysWithValues: entries.map { ($0.selection.id, TextDrafts.fingerprint($0.fields)) })
            })
        await owner.load()
        let layout = sharedLayout ?? LanguageLayoutEditor(); if !layout.ready { layout.loaded(LanguageEditorLayout()) }
        return .init(root: root, controller: controller, session: session, account: account, revision: revision, version: version, owner: owner, layout: layout, presentation: presentation, targetMode: targetMode, locale: locale)
    }
    @MainActor @Observable final class LanguageScrollProbe {
        var target = ""
        var ticket = UUID()
        func showAtBottom(_ target: String) { self.target = target; ticket = UUID() }
    }
    @MainActor private struct LanguageScrollFixture: View {
        let english, swedish: Fixture
        let probe: LanguageScrollProbe
        var body: some View {
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        StorebenchCollection(items: [StorebenchCollectionEntry(id: "en-GB", value: "en-GB"), StorebenchCollectionEntry(id: "sv", value: "sv")],
                            title: { StoreLocales.name($0.value) }, subtitle: { $0.value + " · Synthetic saved language" },
                            headerActions: { language in AnyView(LanguageLayoutControls(editor: english.layout, accountId: english.account.id, appId: english.revision.app.id, session: english.session, locale: language.value)) },
                            initialOpeningLimit: -1, empty: "") { language in
                            if language.value == "en-GB" {
                                english.view
                                RoundedRectangle(cornerRadius: 12).fill(StorebenchTheme.color("color-surface-subtle"))
                                    .frame(height: 1200).overlay { Text("Synthetic saved media") }
                            } else { swedish.view }
                        }
                        Color.clear.frame(height: 900)
                    }.padding(20)
                }
                .onChange(of: probe.ticket) { scroll.scrollTo(probe.target, anchor: .bottom) }
            }.modifier(StorebenchAppearance())
        }
    }
    @MainActor private struct RefreshFixture: View {
        let fixture: Fixture, refresh: EditorRefresh
        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                Button("Refresh Status") {
                    if refresh.begin(scope: "synthetic-release"), refresh.confirmation == nil { Task { await refresh.perform(.refresh) } }
                }.storebenchControlID("synthetic.page-refresh").storebenchWorking(refresh.busy)
                fixture.view.storebenchWorking(refresh.busy)
                Card(title: "Another Card", subtitle: "Synthetic current status") { Text("Synthetic saved card data") }
                    .pageRefreshParticipant("synthetic-other-card", state: { .init() }, refresh: { fixture.presentation.otherReads += 1; return true })
            }.environment(\.pageRefresh, PageRefreshContext(owner: refresh, scope: "synthetic-release"))
                .modifier(StorebenchAppearance())
                .sheet(isPresented: Binding(get: { refresh.confirmation != nil }, set: { if !$0 && refresh.confirmation != nil { refresh.cancel() } })) {
                    if let confirmation = refresh.confirmation {
                        PageRefreshConfirmation(confirmation: confirmation, choose: chooseRefresh)
                    }
                }
        }
        func chooseRefresh(_ choice: EditorRefresh.Choice) {
            fixture.presentation.refreshChoices.append(choice)
            if choice == .cancel { refresh.cancel() }
            else { Task { await refresh.perform(choice) } }
        }
    }
    @MainActor @Observable final class SharedScrollProbe {
        var expanded = false
        var precedingHeight: CGFloat = 1100
        var text = "Synthetic retained input"
        var focusTicket: UUID?
    }
    @MainActor private struct SharedScrollFixture: View {
        let probe: SharedScrollProbe
        let nested: Bool
        private var form: some View {
            StorebenchForm {
                Color.clear.frame(height: probe.precedingHeight)
                DisclosureGroup(isExpanded: Binding(get: { probe.expanded }, set: { probe.expanded = $0 })) {
                    StorebenchTextField("Synthetic Input", text: Binding(get: { probe.text }, set: { probe.text = $0 }))
                        .requestFocus(probe.focusTicket).storebenchControlID("synthetic.scroll-input")
                    Color.clear.frame(height: 800)
                } label: { Text("Synthetic Section").storebenchControlID("synthetic.scroll-disclosure") }
                Color.clear.frame(height: 1000)
            }
        }
        var body: some View {
            Group {
                if nested {
                    ScrollView {
                        VStack(spacing: 16) {
                            Color.clear.frame(height: 1000)
                            form.frame(height: 350)
                            Color.clear.frame(height: 1000)
                        }
                    }
                } else { form }
            }.environment(\.settingsPresentation, !nested).modifier(StorebenchAppearance())
        }
    }
    @MainActor private final class Window {
        enum Failure: Error { case timeout(String), missingControl }
        let window: NSWindow, host: NSHostingView<AnyView>
        init<V: View>(_ view: V, width: CGFloat = 1280, scroll: Bool = true) {
            _ = NSApplication.shared
            window = NSWindow(contentRect: .init(x: 0, y: 0, width: width, height: 900), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            if scroll { host = NSHostingView(rootView: AnyView(ScrollView { view.padding(20) })) }
            else { host = NSHostingView(rootView: AnyView(view.frame(width: width, height: 900))) }
            window.contentView = host; window.makeKeyAndOrderFront(nil)
        }
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        func marker(_ id: String) -> StorebenchControlMarker? {
            ([host] + window.sheets.compactMap(\.contentView)).flatMap(views).compactMap { $0 as? StorebenchControlMarker }.first { $0.identifier?.rawValue == id }
        }
        func settle() async throws { host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
        func wait(file: StaticString = #fileID, line: UInt = #line, _ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(8)
            while true {
                if condition() { try await settle(); if condition() { return } }
                guard ContinuousClock.now < deadline else {
                    try? capture("release-editing-timeout")
                    if !window.sheets.isEmpty { try? capture("release-editing-sheet-timeout", sheet: true) }
                    throw Failure.timeout("\(file):\(line)")
                }
                try await settle()
            }
        }
        func press(_ id: String, revealFirst: Bool = true) async throws {
            try await wait { marker(id) != nil }
            let marker = try #require(marker(id))
            let targetWindow = marker.window ?? window
            if revealFirst { try await reveal(marker) }
            targetWindow.makeKeyAndOrderFront(nil)
            if !marker.available { return }
            let inset = StorebenchTheme.space(2) + StorebenchTheme.measure("disclosureIcon") / 2
            let localPoint = id.hasPrefix("collection.disclosure.")
                ? CGPoint(x: marker.bounds.minX + inset, y: marker.isFlipped ? marker.bounds.minY + inset + 6 : marker.bounds.maxY - inset - 6)
                : CGPoint(x: marker.bounds.midX, y: marker.bounds.midY)
            let point = marker.convert(localPoint, to: nil)
            if let root = targetWindow.contentView, let native = views(root).compactMap({ $0 as? NSControl }).first(where: {
                $0.cell is NSButtonCell && !$0.isHiddenOrHasHiddenAncestor && $0.convert($0.bounds, to: nil).contains(point)
            }) {
                native.performClick(nil); return
            }
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: targetWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
                targetWindow.sendEvent(event)
            }
        }
        private func reveal(_ marker: NSView) async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            var previous: CGRect?, stable = 0
            while ContinuousClock.now < deadline {
                var ancestor = marker.superview
                while let view = ancestor {
                    if let scroll = view as? NSScrollView, let document = scroll.documentView {
                        document.layoutSubtreeIfNeeded()
                        let target = marker.convert(marker.bounds, to: document), clip = scroll.contentView
                        if !clip.bounds.insetBy(dx: 0, dy: 20).contains(target) {
                            let y = min(max(document.bounds.minY, target.midY - clip.bounds.height / 2), max(document.bounds.minY, document.bounds.maxY - clip.bounds.height))
                            clip.scroll(to: CGPoint(x: clip.bounds.minX, y: y)); scroll.reflectScrolledClipView(clip)
                        }
                    }
                    ancestor = view.superview
                }
                try await settle()
                let frame = marker.convert(marker.bounds, to: nil)
                if let previous, abs(previous.minX - frame.minX) < 0.5, abs(previous.minY - frame.minY) < 0.5,
                   abs(previous.width - frame.width) < 0.5, abs(previous.height - frame.height) < 0.5 { stable += 1 }
                else { stable = 0 }
                if stable >= 3 { return }
                previous = frame
            }
            throw Failure.timeout("Control layout did not settle: " + (marker.identifier?.rawValue ?? "unnamed"))
        }
        func textView(_ id: String) -> NSTextView? {
            guard let marker = marker(id) else { return nil }
            let frame = marker.convert(marker.bounds, to: host)
            return views(host).compactMap { $0 as? NSTextView }.first { $0.isEditable && frame.intersects($0.convert($0.bounds, to: host)) }
        }
        func hasText(_ text: String) -> Bool {
            ([host] + window.sheets.compactMap(\.contentView)).flatMap(views).contains { (($0 as? NSTextField)?.stringValue ?? ($0 as? NSTextView)?.string ?? "").contains(text) }
        }
        func capture(_ name: String, sheet: Bool = false) throws {
            let root: NSView = sheet ? try #require(window.sheets.first?.contentView) : host
            let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: TestIsolation.require().appendingPathComponent(name + ".png"))
        }
        func close() {
            for sheet in window.sheets { window.endSheet(sheet); sheet.orderOut(nil); sheet.close() }
            window.contentView = nil; window.orderOut(nil); window.close()
        }
    }

    @Test func britishSyncOpensItsApprovalEvenWhenUnrelatedScreenshotsAreBlocked() async throws {
        let fixture = try await fixture(), ui = Window(fixture)
        do {
            try await ui.wait { ui.marker("language.sync.en-GB") != nil }
            try await ui.press("language.sync.en-GB")
            try await ui.wait { !ui.window.sheets.isEmpty }
            #expect(fixture.presentation.requests.count == 1)
            #expect(fixture.presentation.requests.first?.listingLocale == "en-GB" && fixture.presentation.requests.first?.mediaStage == PublishRequest.textStage)
            #expect(ui.hasText("Synthetic British text"))
            #expect(!fixture.owner.workflow.ready && fixture.owner.publishingReady)
            #expect(try await fixture.session.publishHistory(accountId: fixture.account.id, appId: fixture.revision.app.id).isEmpty)
        } catch { ui.close(); await fixture.close(); throw error }
        ui.close(); await fixture.close()
    }
    @Test(arguments: [true, false])
    func matchingTextShowsAVisibleCheckInsteadOfAnEmptySyncDialog(_ noChanges: Bool) async throws {
        let fixture = try await fixture(); fixture.presentation.noChanges = noChanges; fixture.presentation.emptyReview = !noChanges
        let ui = Window(fixture)
        do {
            try await ui.wait { !fixture.owner.busy && !fixture.owner.workflow.busy && ui.marker("language.sync.en-GB")?.available == true }
            try await ui.press("language.sync.en-GB")
            try await ui.wait { fixture.presentation.requests.count == 1 && ui.hasText("Up to Date with Apple") }
            #expect(ui.window.sheets.isEmpty && ui.marker("language.sync-status.en-GB") != nil)
            #expect(fixture.presentation.saves == 0 && !fixture.owner.dirty)
            #expect(try await fixture.session.publishHistory(accountId: fixture.account.id, appId: fixture.revision.app.id).isEmpty)
            try ui.capture("language-sync-up-to-date")
            let field = try #require(fixture.owner.editor?.fields.first { $0.key == "description" })
            try fixture.owner.change(field, to: "Synthetic newer text after the Apple check.")
            try await ui.wait { !ui.hasText("Up to Date with Apple") }
        } catch { ui.close(); await fixture.close(); throw error }
        ui.close(); await fixture.close()
    }
    @Test(arguments: [EditorRefresh.Choice.save, .discard, .cancel])
    func refreshingThePageSettlesEachDialogChoiceAndRefreshesTheOtherCard(_ choice: EditorRefresh.Choice) async throws {
        let fixture = try await fixture(); fixture.presentation.noChanges = true
        let refresh = EditorRefresh(), page = RefreshFixture(fixture: fixture, refresh: refresh), ui = Window(page)
        do {
            try await ui.wait { !fixture.owner.busy && !fixture.owner.workflow.busy && ui.marker("language.sync.en-GB")?.available == true }
            let field = try #require(fixture.owner.editor?.fields.first { $0.key == "description" }), original = fixture.owner.editor?.value(field)
            try fixture.owner.change(field, to: "Synthetic unsaved text before refresh."); try await ui.settle()
            // A refresh's local Save must not require an unrelated version gate to be ready for publishing.
            fixture.presentation.planBlocked = choice == .save
            try await ui.press("synthetic.page-refresh")
            try await ui.wait { ui.marker("page.refresh.save")?.available == true && ui.marker("page.refresh.discard")?.available == true && ui.marker("page.refresh.cancel")?.available == true }
            #expect(fixture.presentation.otherReads == 0 && fixture.presentation.requests.isEmpty)
            // The native unit host cannot become a foreground app; dispatch the same presenter callback used by the dialog.
            page.chooseRefresh(choice)
            #expect(fixture.presentation.refreshChoices == [choice])
            try await ui.wait { ui.window.sheets.isEmpty && !refresh.busy }
            if choice == .cancel {
                #expect(fixture.owner.dirty && fixture.presentation.otherReads == 0 && fixture.presentation.requests.isEmpty)
            } else {
                try await ui.wait { fixture.presentation.otherReads == 1 && ui.hasText("Up to Date with Apple") }
                #expect(!fixture.owner.dirty && !refresh.failed)
                #expect(fixture.owner.editor?.value(field) == (choice == .save ? "Synthetic unsaved text before refresh." : original))
            }
            #expect(fixture.presentation.saves == (choice == .save ? 1 : 0))
            #expect(try await fixture.session.publishHistory(accountId: fixture.account.id, appId: fixture.revision.app.id).isEmpty)
        } catch { ui.close(); await fixture.close(); throw error }
        ui.close(); await fixture.close()
    }
    @Test func aDelayedParentBusyFrameDoesNotHideTheFinishedRefreshComparison() async throws {
        let fixture = try await fixture(); fixture.presentation.noChanges = true
        let refresh = EditorRefresh(), ui = Window(RefreshFixture(fixture: fixture, refresh: refresh))
        do {
            try await ui.wait { !fixture.owner.busy && !fixture.owner.workflow.busy && ui.marker("language.sync.en-GB")?.available == true }
            // The owned workflow has finished even while a parent's environment still displays its previous busy frame.
            fixture.presentation.parentBusy = true; try await ui.settle()
            try await ui.press("synthetic.page-refresh")
            try await ui.wait { fixture.presentation.otherReads == 1 && ui.hasText("Up to Date with Apple") }
            #expect(!refresh.failed && fixture.presentation.requests.count == 1 && ui.window.sheets.isEmpty)
        } catch { ui.close(); await fixture.close(); throw error }
        ui.close(); await fixture.close()
    }

    @Test func expandingAndCollapsingSwedishKeepsItsHeaderInPlaceWithoutResizingEnglish() async throws {
        let english = try await fixture(), swedish = try await fixture(locale: "sv", sharedLayout: english.layout)
        english.layout.change(Dictionary(uniqueKeysWithValues: LanguageEditorLayout.Group.allCases.map { ($0, false) }))
        await english.layout.flushScoped { patch, locale in
            try await english.session.saveLanguageEditorLayout(accountId: english.account.id, appId: english.revision.app.id, patch: patch, locale: locale)
        }
        let field = try #require(swedish.owner.editor?.fields.first { $0.key == "description" })
        try swedish.owner.change(field, to: "Synthetic unsaved Swedish description.")
        let probe = LanguageScrollProbe(), ui = Window(LanguageScrollFixture(english: english, swedish: swedish, probe: probe), scroll: false)
        do {
            let target = "language.section-toggle.sv.copy"
            try await ui.wait { ui.marker(target)?.available == true && ui.marker("language.section.en-GB.copy") != nil }
            let earlier = try #require(ui.marker("language.section.en-GB.copy")), initialHeight = earlier.bounds.height
            probe.showAtBottom(LanguageSectionNavigation.anchor("sv", .copy))
            try await ui.settle(); try await ui.settle()
            let outer = try #require(ui.views(ui.host).compactMap { $0 as? NSScrollView }.max { $0.contentView.bounds.height < $1.contentView.bounds.height })
            func visible(_ id: String) -> Bool {
                guard let view = ui.marker(id) else { return false }
                let frame = view.convert(view.bounds, to: ui.host), viewport = outer.contentView.convert(outer.contentView.bounds, to: ui.host)
                return frame.minY >= viewport.minY - 1 && frame.maxY <= viewport.maxY + 1
            }
            func point(_ id: String) throws -> CGPoint {
                let view = try #require(ui.marker(id)); return view.convert(view.bounds, to: ui.host).origin
            }
            let before = try point(target)
            for expanded in [true, false, true] {
                try await ui.press(target, revealFirst: false)
                try await ui.wait { english.layout.layout.isExpanded(.copy, locale: "sv") == expanded }
                for _ in 0..<20 {
                    try await ui.settle()
                    let current = try point(target)
                    #expect(visible(target) && abs(current.x - before.x) < 1 && abs(current.y - before.y) < 1)
                }
                #expect(!english.layout.layout.isExpanded(.copy, locale: "en-GB") && abs(earlier.bounds.height - initialHeight) < 1)
                #expect(swedish.owner.editor?.value(field) == "Synthetic unsaved Swedish description." && swedish.owner.dirty)
                try ui.capture(expanded ? "language-section-sweden-expanded" : "language-section-sweden-collapsed")
            }
            try await ui.press("collection.disclosure.sv")
            try await ui.wait { visible("collection.disclosure.sv") && ui.marker(target)?.available == false }
            let collectionBefore = try point("collection.disclosure.sv")
            try await ui.press("collection.disclosure.sv", revealFirst: false)
            try await ui.wait { ui.marker("language.field.sv.description")?.available == true }
            for _ in 0..<20 {
                try await ui.settle()
                let current = try point("collection.disclosure.sv")
                #expect(visible("collection.disclosure.sv") && abs(current.x - collectionBefore.x) < 1 && abs(current.y - collectionBefore.y) < 1)
            }
            #expect(abs(earlier.bounds.height - initialHeight) < 1)
            #expect(swedish.owner.editor?.value(field) == "Synthetic unsaved Swedish description." && swedish.owner.dirty)
        } catch { ui.close(); await english.close(); await swedish.close(); throw error }
        ui.close(); await english.close(); await swedish.close()
    }

    @Test func theLatestDisclosureRevealCancelsEarlierScrollCorrections() async throws {
        let reveal = StorebenchScrollReveal()
        var positions: [String] = []
        reveal.reveal("synthetic-old", anchor: .top) { id, _ in positions.append(id) }
        reveal.reveal("synthetic-current", anchor: .top) { id, _ in positions.append(id) }
        try await Task.sleep(for: .milliseconds(160))
        #expect(!positions.isEmpty && positions.allSatisfy { $0 == "synthetic-current" })
        reveal.reveal("synthetic-cancelled", anchor: .top) { id, _ in positions.append(id) }
        reveal.cancel()
        try await Task.sleep(for: .milliseconds(120))
        #expect(!positions.contains("synthetic-cancelled"))
    }

    @Test(arguments: [false, true])
    func sharedDisclosuresAndInputsStayVisibleInSettingsAndNestedInspectors(_ nested: Bool) async throws {
        let probe = SharedScrollProbe(), ui = Window(SharedScrollFixture(probe: probe, nested: nested), width: 720, scroll: false)
        defer { ui.close() }
        func visible(_ id: String) -> Bool {
            guard let marker = ui.marker(id) else { return false }
            let rect = marker.convert(marker.bounds, to: ui.host)
            var ancestor = marker.superview
            while let view = ancestor {
                if let scroll = view as? NSScrollView {
                    let viewport = scroll.contentView.convert(scroll.contentView.bounds, to: ui.host)
                    if !viewport.insetBy(dx: -1, dy: -1).contains(rect) { return false }
                }
                ancestor = view.superview
            }
            return true
        }
        try await ui.wait { ui.marker("synthetic.scroll-disclosure") != nil }
        let header = try #require(ui.marker("synthetic.scroll-disclosure"))
        var ancestor = header.superview
        while let view = ancestor {
            if let scroll = view as? NSScrollView, let document = scroll.documentView {
                let rect = header.convert(header.bounds, to: document), clip = scroll.contentView
                var viewport = clip.bounds; viewport.origin.y = rect.minY - 80
                clip.scroll(to: clip.constrainBoundsRect(viewport).origin); scroll.reflectScrolledClipView(clip)
            }
            ancestor = view.superview
        }
        try await ui.settle()
        let before = header.convert(header.bounds, to: ui.host).origin
        func stable() -> Bool {
            let current = header.convert(header.bounds, to: ui.host).origin
            return abs(current.x - before.x) < 1 && abs(current.y - before.y) < 1
        }
        try await ui.press("synthetic.scroll-disclosure", revealFirst: false)
        try await ui.wait { probe.expanded && visible("synthetic.scroll-disclosure") && stable() }
        // A later preceding measurement must preserve this header in both enclosing viewports.
        try await Task.sleep(for: .milliseconds(400))
        probe.precedingHeight += 500
        try await ui.wait { visible("synthetic.scroll-disclosure") && stable() }
        try ui.capture("shared-disclosure-before-" + String(nested))
        try await ui.press("synthetic.scroll-disclosure", revealFirst: false)
        try ui.capture("shared-disclosure-after-" + String(nested))
        for _ in 0..<25 {
            try await ui.settle()
            #expect(!probe.expanded && visible("synthetic.scroll-disclosure") && stable(), "Expanded: \(probe.expanded); visible: \(visible("synthetic.scroll-disclosure")); current: \(header.convert(header.bounds, to: ui.host)); expected origin: \(before)")
        }
        // An Edit-style action can open a section and focus its input without a page-specific scroll callback.
        probe.precedingHeight += 500; probe.expanded = true; probe.focusTicket = UUID()
        try await ui.wait { visible("synthetic.scroll-input") && ui.window.firstResponder is NSTextView }
        #expect(probe.text == "Synthetic retained input")
    }

    @Test(arguments: [CGFloat(420), CGFloat(1100)])
    func focusedMediaInstructionsAndDoneStayInsideTheirOwnPanel(_ width: CGFloat) async throws {
        let presentation = ReleaseEditingPresentation(), ui = Window(MediaGuideFixture(presentation: presentation), width: width)
        defer { ui.close() }
        let id = "release.media-guide.en-GB"
        try await ui.wait { ui.marker(id) != nil && ui.marker("release.media-done.en-GB") != nil }
        let panel = try #require(ui.marker(id)), frame = panel.convert(panel.bounds, to: ui.host)
        for suffix in [".title", ".detail", ".hint"] {
            let copy = try #require(ui.marker(id + suffix)), copyFrame = copy.convert(copy.bounds, to: ui.host)
            #expect(frame.insetBy(dx: 15, dy: 15).contains(copyFrame), "Instruction text needs padding on every side")
        }
        let done = try #require(ui.marker("release.media-done.en-GB")), doneFrame = done.convert(done.bounds, to: ui.host)
        #expect(frame.insetBy(dx: 15, dy: 15).contains(doneFrame))
        #expect(abs(doneFrame.width - StorebenchTheme.actionWidth) < 1 && abs(doneFrame.height - StorebenchTheme.controlHeight) < 1)
        let previews = try #require(ui.marker("synthetic.previews-card")), previewsFrame = previews.convert(previews.bounds, to: ui.host)
        #expect(!frame.intersects(previewsFrame) && previewsFrame.minY >= frame.maxY + 11, "The guide cannot overlap the following media card")
        #expect(frame.minX >= 19 && frame.maxX <= width - 19)
        try ui.capture("release-media-guide-\(Int(width))")
        presentation.parentBusy = true
        try await ui.wait { ui.marker("release.media-done.en-GB")?.available == false }
        #expect(panel.convert(panel.bounds, to: ui.host) == frame && done.convert(done.bounds, to: ui.host) == doneFrame)
        try await ui.press("release.media-done.en-GB"); try await ui.settle(); #expect(presentation.finished == 0)
        presentation.parentBusy = false
        try await ui.wait { ui.marker("release.media-done.en-GB")?.available == true }
        try await ui.press("release.media-done.en-GB")
        try await ui.wait { presentation.finished == 1 }
    }

    @Test(arguments: [CGFloat(420), CGFloat(1100)])
    func editingGuideShowsCompleteLongCopyWithoutWideningTheColumn(_ width: CGFloat) async throws {
        let ui = Window(MediaGuideFixture(presentation: ReleaseEditingPresentation(), longCopy: true), width: width)
        defer { ui.close() }
        try await ui.wait { ui.marker("synthetic.media-guide.hint") != nil }
        let panel = try #require(ui.marker("synthetic.media-guide")), frame = panel.convert(panel.bounds, to: ui.host)
        let bodySize = StorebenchTheme.design.number("font-size-body"), captionSize = StorebenchTheme.design.number("font-size-caption")
        for (suffix, text, font) in [("title", MediaGuideFixture.title, NSFont.systemFont(ofSize: bodySize, weight: .semibold)),
                                     ("detail", MediaGuideFixture.detail, NSFont.systemFont(ofSize: bodySize)),
                                     ("hint", MediaGuideFixture.hint, NSFont.systemFont(ofSize: captionSize))] {
            let copy = try #require(ui.marker("synthetic.media-guide." + suffix)), copyFrame = copy.convert(copy.bounds, to: ui.host)
            let needed = (text as NSString).boundingRect(with: CGSize(width: copyFrame.width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).height
            #expect(copyFrame.height >= ceil(needed) - 2, "Every line of \(suffix) must remain readable")
            #expect(frame.insetBy(dx: 15, dy: 15).contains(copyFrame))
        }
        #expect(frame.minX >= 19 && frame.maxX <= width - 19)
        try ui.capture("release-media-long-copy-\(Int(width))")
    }

    @Test func aFailedTextPreparationShowsItsReasonInsteadOfDoingNothing() async throws {
        let fixture = try await fixture(); fixture.presentation.failPreparation = true
        let ui = Window(fixture)
        do {
            try await ui.wait { ui.marker("language.sync.en-GB") != nil }; try await ui.press("language.sync.en-GB")
            try await ui.wait { ui.hasText("Synthetic text preparation failed.") }
            #expect(fixture.presentation.requests.count == 1 && ui.window.sheets.isEmpty)
        } catch { ui.close(); await fixture.close(); throw error }
        ui.close(); await fixture.close()
    }

    @Test(arguments: ["apple-version", "release-plan"])
    func savedTextOpensItsReviewWhileTheParentStillPresentsTheCompletedBusyFrame(_ targetMode: String) async throws {
        let fixture = try await fixture(targetMode: targetMode); fixture.presentation.delayedParentBusy = true
        let ui = Window(fixture)
        do {
            let field = try #require(fixture.owner.editor?.fields.first { $0.key == "description" })
            try fixture.owner.change(field, to: "Synthetic unsaved British text")
            try await ui.wait { ui.marker("language.sync.en-GB")?.available == true }
            try await ui.press("language.sync.en-GB")
            try await ui.wait { !ui.window.sheets.isEmpty }
            #expect(fixture.presentation.parentBusy && !fixture.owner.workflow.busy)
            #expect(fixture.presentation.saves == 1 && !fixture.owner.dirty && fixture.owner.publishingReady)
            #expect(fixture.presentation.requests.first?.targetMode == targetMode && fixture.presentation.requests.first?.mediaStage == PublishRequest.textStage)
            #expect(try await fixture.session.publishHistory(accountId: fixture.account.id, appId: fixture.revision.app.id).isEmpty)
            fixture.presentation.parentBusy = false
        } catch { ui.close(); await fixture.close(); throw error }
        ui.close(); await fixture.close()
    }

    @Test func aDraftCanSaveIncompleteOrLongTextWithAnUnfinishedPlanAndSaveAgainWithoutAWrite() async throws {
        let fixture = try await fixture(targetMode: "release-plan"), ui = Window(fixture)
        do {
            fixture.presentation.planBlocked = true
            let field = try #require(fixture.owner.editor?.fields.first { $0.key == "description" }), long = String(repeating: "Synthetic text. ", count: 300)
            try fixture.owner.change(field, to: long)
            let url = try #require(fixture.owner.editor?.fields.first { $0.key == "supportUrl" })
            try fixture.owner.change(url, to: "")
            try await ui.wait { ui.marker("language.save.en-GB")?.available == true }
            try await ui.press("language.save.en-GB")
            try await ui.wait { !fixture.owner.dirty && ui.hasText("Language draft saved on this Mac.") }
            #expect(fixture.presentation.saves == 1 && fixture.owner.editor?.saved(field) == long && fixture.owner.editor?.saved(url) == "")
            #expect(fixture.presentation.requests.isEmpty && !fixture.owner.publishingReady)
            // With everything saved, Save Draft rests until the next edit, so it never looks like there is more to save.
            try await ui.wait { ui.marker("language.save.en-GB")?.available == false }
            #expect(fixture.presentation.saves == 1)
            try fixture.owner.change(field, to: long + " Again")
            try await ui.wait { ui.marker("language.save.en-GB")?.available == true }
        } catch { ui.close(); await fixture.close(); throw error }
        ui.close(); await fixture.close()
    }

    @Test func aFailedSyncKeepsTheDraftAndTheNextClickPreparesAgainWithoutResaving() async throws {
        let fixture = try await fixture(targetMode: "release-plan"); fixture.presentation.failPreparation = true
        let ui = Window(fixture)
        do {
            let field = try #require(fixture.owner.editor?.fields.first { $0.key == "description" })
            try fixture.owner.change(field, to: "Synthetic saved text for retry")
            try await ui.wait { ui.marker("language.sync.en-GB")?.available == true }; try await ui.press("language.sync.en-GB")
            try await ui.wait { ui.hasText("Synthetic text preparation failed.") }
            #expect(!fixture.owner.dirty && fixture.presentation.saves == 1 && fixture.presentation.requests.count == 1)
            fixture.presentation.failPreparation = false
            try await ui.wait { ui.marker("language.sync.en-GB")?.available == true }; try await ui.press("language.sync.en-GB")
            try await ui.wait { !ui.window.sheets.isEmpty }
            #expect(fixture.presentation.saves == 1 && fixture.presentation.requests.count == 2)
        } catch { ui.close(); await fixture.close(); throw error }
        ui.close(); await fixture.close()
    }

    @Test(arguments: [CGFloat(760), CGFloat(1280)])
    func editFocusesShortAndLongInputsAndDoneRetainsTheirNativeViewsWithoutClipping(_ width: CGFloat) async throws {
        let fixture = try await fixture(), ui = Window(fixture, width: width)
        do {
            try await ui.wait { ui.marker("language.field.en-GB.privacyPolicyUrl") != nil }
            fixture.presentation.focus = .init(anchor: ReleaseReadiness.fieldAnchor("en-GB", "privacyPolicyUrl"))
            try await ui.wait {
                let marker = ui.marker("language.field.en-GB.privacyPolicyUrl")
                return ui.views(ui.host).compactMap { $0 as? NSTextField }.contains { field in
                    guard field.isEditable, let marker else { return false }
                    return marker.convert(marker.bounds, to: ui.host).intersects(field.convert(field.bounds, to: ui.host)) && field.currentEditor() === ui.window.firstResponder
                }
            }
            fixture.presentation.focus = .init(anchor: ReleaseReadiness.fieldAnchor("en-GB", "description"))
            try await ui.wait { ui.textView("language.field.en-GB.description") === ui.window.firstResponder }
            let focus = try #require(ui.marker("language.focus.en-GB.description")), focusFrame = focus.convert(focus.bounds, to: ui.host)
            let input = try #require(ui.marker("language.field.en-GB.description")), inputFrame = input.convert(input.bounds, to: ui.host)
            #expect(inputFrame.minX >= focusFrame.minX + 7 && inputFrame.maxX <= focusFrame.maxX - 7, "Focus outlines need room around the complete input")
            #expect(focusFrame.minX >= 0 && focusFrame.maxX <= ui.host.bounds.width)
            let text = try #require(ui.textView("language.field.en-GB.description"))
            text.insertText("Synthetic edited description.", replacementRange: NSRange(location: 0, length: text.string.utf16.count))
            try await ui.wait { fixture.owner.dirty }
            let fields = ["description", "name", "subtitle", "keywords", "supportUrl", "marketingUrl", "privacyPolicyUrl", "privacyChoicesUrl", "privacyPolicyText"]
            let before = try fields.map { field in
                let marker = try #require(ui.marker("language.field.en-GB." + field)); return marker.convert(marker.bounds, to: ui.host)
            }
            #expect(before.allSatisfy { $0.minX >= -1 && $0.maxX <= ui.host.bounds.width + 1 && $0.height >= 28 }, "Every field stays inside its column")
            try await ui.press("language.done.en-GB.description")
            try await ui.wait { fixture.presentation.finished == 1 && !fixture.owner.dirty }
            #expect(ui.textView("language.field.en-GB.description") === text, "Done retains the native text editor")
            for (field, frame) in zip(fields, before) {
                let marker = try #require(ui.marker("language.field.en-GB." + field)), after = marker.convert(marker.bounds, to: ui.host)
                #expect(abs(after.height - frame.height) < 1 && after.width <= ui.host.bounds.width + 1)
            }
            let field = try #require(fixture.owner.editor?.fields.first { $0.key == "description" })
            #expect(fixture.owner.editor?.value(field) == "Synthetic edited description.")
        } catch { ui.close(); await fixture.close(); throw error }
        ui.close(); await fixture.close()
    }

    @Test(arguments: [CGFloat(580), CGFloat(1100)])
    func contextualDraftActionsKeepTheFullFormWidthAndStableNativeButtons(_ width: CGFloat) async throws {
        let fixture = try await fixture()
        let draft = LocalEditorDraftEditor(scope: .init(accountId: fixture.account.id, appId: fixture.revision.app.id,
            editor: "synthetic-footer", resource: "synthetic-category"), session: fixture.session)
        _ = await draft.load(initial: .string("Synthetic original category"))
        let value = JSONText.string("Synthetic changed category")
        let ui = Window(Card(title: "Category", subtitle: "Synthetic category editor") {
            StorebenchFormFooter {
                LocalDraftActions(editor: draft, value: value, restore: { _ in }, sync: {}, title: "Category Changes")
                    .storebenchControlID("synthetic.draft.footer")
            }
        }.modifier(StorebenchAppearance()), width: width)
        do {
            try await ui.wait { ui.marker("draft.save.synthetic-footer")?.available == true }
            let marker = try #require(ui.marker("synthetic.draft.footer")), frame = marker.convert(marker.bounds, to: ui.host)
            #expect(frame.width >= width - 110, "A contextual footer must not become a single 192-point button cell")
            #expect(frame.height < 270, "Copy and commands use the form width instead of becoming a tall narrow panel")
            let save = try #require(ui.marker("draft.save.synthetic-footer")), sync = try #require(ui.marker("draft.sync.synthetic-footer"))
            let saveFrame = save.convert(save.bounds, to: ui.host), syncFrame = sync.convert(sync.bounds, to: ui.host)
            #expect(abs(saveFrame.width - StorebenchTheme.actionWidth) <= 1 && abs(saveFrame.height - StorebenchTheme.controlHeight) <= 1)
            #expect(abs(syncFrame.width - saveFrame.width) <= 1 && abs(syncFrame.height - saveFrame.height) <= 1)
            #expect(!saveFrame.intersects(syncFrame) && frame.contains(saveFrame) && frame.contains(syncFrame))
            if width == 1100 { try ui.capture("release-contextual-footer") }
            try await ui.press("draft.save.synthetic-footer")
            try await ui.wait { !draft.dirty(value) }
            let after = marker.convert(marker.bounds, to: ui.host)
            #expect(abs(after.height - frame.height) <= 1, "Saving must not move the footer or its buttons")
        } catch { ui.close(); await fixture.close(); throw error }
        ui.close(); await fixture.close()
    }

    @Test func aMissingReviewPasswordCanFocusTheSharedSecureInput() async throws {
        let field = StorebenchSecureField("Synthetic Demo Password", text: .constant(""))
            .requestFocus(UUID()).storebenchControlID("synthetic.review-password").modifier(StorebenchAppearance())
        let ui = Window(field, width: 640)
        do {
            try await ui.wait {
                ui.views(ui.host).compactMap { $0 as? NSSecureTextField }.contains { $0.currentEditor() != nil && $0.currentEditor() === ui.window.firstResponder }
            }
            #expect(ui.marker("synthetic.review-password") != nil)
        } catch { ui.close(); throw error }
        ui.close()
    }

    @Test func aSubmittedVersionShowsItsAppleStateInsteadOfAnOldResumeOrSubmissionError() async throws {
        let fixture = try await fixture(), app = try #require(fixture.account.apps.first { $0.id == fixture.revision.app.id })
        let version = PublishingWorkspace.Version(id: "synthetic-submitted", platform: "MAC_OS", number: "2.0", state: "WAITING_FOR_REVIEW")
        let choices = PublishingWorkspace.Snapshot(accountId: fixture.account.id, appId: app.id, versions: [version], sources: [], builds: nil, profiles: [], defaultProfile: nil, plan: nil)
        for width in [CGFloat(560), 1100] {
            let view = VStack(alignment: .leading, spacing: 16) {
                ReleaseSubmittedStatus(version: "macOS 2.0", state: version.state)
                PublishActionPanel(account: fixture.account, app: app, session: nil, actions: [.submit],
                    initialRequest: .init(accountId: fixture.account.id, appId: app.id, scope: .submit, versionId: version.id), initialChoices: choices)
            }.modifier(StorebenchAppearance())
            let ui = Window(view, width: width)
            do {
                try await ui.wait { ui.marker("release.submitted-status") != nil && ui.hasText("already been submitted") }
                #expect(ui.hasText("Waiting for Review"))
                #expect(!ui.hasText("Ready to Resume") && !ui.hasText("This version is not ready to prepare for review"))
                let marker = try #require(ui.marker("release.submitted-status")), frame = marker.convert(marker.bounds, to: ui.host)
                #expect(frame.width > 300 && frame.minX >= -1 && frame.maxX <= ui.host.bounds.width + 1)
                #expect(try await fixture.session.publishHistory(accountId: fixture.account.id, appId: app.id).isEmpty)
            } catch { ui.close(); await fixture.close(); throw error }
            ui.close()
        }
        await fixture.close()
    }

    @Test func aGuidedCopyrightFixShowsAndFocusesTheNativeInputInTheApp() async throws {
        let fixture = try await fixture(), app = try #require(fixture.account.apps.first { $0.id == fixture.revision.app.id })
        let version = PublishingWorkspace.Version(id: "synthetic-version", platform: "MAC_OS", number: "1.0", state: "PREPARE_FOR_SUBMISSION")
        let choices = PublishingWorkspace.Snapshot(accountId: fixture.account.id, appId: app.id, versions: [version], sources: [], builds: [], profiles: [], defaultProfile: nil, plan: nil)
        let ui = Window(CopyrightForm(account: fixture.account, app: app, version: version, choices: choices, presentation: fixture.presentation), width: 900)
        do {
            try await ui.wait { ui.marker("publish.copyright") != nil }
            let marker = try #require(ui.marker("publish.copyright")), bounds = marker.convert(marker.bounds, to: ui.host)
            let input = try #require(ui.views(ui.host).compactMap { $0 as? NSTextField }.first {
                $0.isEditable && bounds.intersects($0.convert($0.bounds, to: ui.host))
            })
            try await ui.wait { input.currentEditor() != nil && input.currentEditor() === ui.window.firstResponder }
            #expect(bounds.width > 200 && bounds.maxX <= ui.host.bounds.width)
            try await ui.press("apple.fix.copyright")
            try await ui.wait { fixture.presentation.finished == 1 && input.currentEditor() != nil && input.currentEditor() === ui.window.firstResponder }
            #expect(try await fixture.session.publishHistory(accountId: fixture.account.id, appId: app.id).isEmpty, "Editing Copyright cannot approve an Apple write")
        } catch { ui.close(); await fixture.close(); throw error }
        ui.close(); await fixture.close()
    }
}
