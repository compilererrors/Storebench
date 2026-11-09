import AppKit
import ImageIO
import SwiftUI
import Testing
@testable import StorebenchApp
@testable import StorebenchCore

private final class MediaAIStubProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var calls = 0
    nonisolated(unsafe) private static var quota = false
    nonisolated(unsafe) private static var sentModels: [String] = []
    static func reset(quota: Bool) { lock.withLock { calls = 0; self.quota = quota; sentModels = [] } }
    static var count: Int { lock.withLock { calls } }
    static var models: [String] { lock.withLock { sentModels } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url?.host == "api.openai.com", request.url?.path == "/v1/models", request.httpMethod == "GET" {
            let models = JSONText.array([
                .object([("id", .string("synthetic-ui-model")), ("display_name", .string("Saved Synthetic Model"))]),
                .object([("id", .string("synthetic-ui-alternate")), ("display_name", .string("Synthetic Alternative"))])])
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: JSONText.object([("data", models)]).data); client?.urlProtocolDidFinishLoading(self); return
        }
        guard request.url?.host == "api.openai.com", request.url?.path == "/v1/responses", request.httpMethod == "POST" else {
            Issue.record("Unexpected request in the owned UI journey")
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        let limited = Self.lock.withLock { Self.calls += 1; return Self.quota }
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; body.append(buffer, count: count)
            }
        }
        Self.lock.withLock { Self.sentModels.append((try? JSONText.parse(body)["model"]?.text) ?? "") }
        let card = JSONText.object([("screenshotIndex", .number(0)), ("title", .string("A Synthetic Benefit")), ("subtitle", .string("A short synthetic detail")),
            ("layout", .string("textAbove")), ("color", .string("#15243f")), ("secondColor", .string("#315fb3")), ("titleColor", .string("#ffffff"))])
        var result = JSONText.object([("cards", .array([card]))])
        if let requestBody = try? JSONText.parse(body), requestBody["text"]?["format"]?["schema"]?["properties"]?["translations"] != nil,
           case .array(let input)? = requestBody["input"], case .array(let parts)? = input.first?["content"], let text = parts.first?["text"]?.text,
           case .array(let texts)? = try? JSONText.parse(Data(text.utf8)) {
            let language = requestBody["instructions"]?.text?.contains("to de-DE.") == true ? "de" : "sv"
            result = .object([("translations", .array(texts.indices.map { .string(language + "-\($0)") }))])
        }
        let content = result.stringify()
        let response = JSONText.object([("status", .string("completed")), ("output", .array([.object([("content", .array([.object([("type", .string("output_text")), ("text", .string(content))])]))])]))]).data
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: limited ? 429 : 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: limited ? Data() : response); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private extension WorkspaceSession {
    func configureMediaUITransport() throws {
        _ = try TestIsolation.require()
        aiTestConfiguration = { let value = URLSessionConfiguration.ephemeral; value.protocolClasses = [MediaAIStubProtocol.self]; return value }
    }
}

@MainActor private final class OwnedMediaWindow {
    enum Failure: Error { case missingControl(String), disabledControl(String), timeout(String) }
    let window: NSWindow, host: NSHostingView<AnyView>
    init<V: View>(_ view: V) {
        window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1280, height: 1000), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "Synthetic Media Journey"
        host = NSHostingView(rootView: AnyView(ScrollView { view.padding(20) }.modifier(StorebenchAppearance())
            .transaction { $0.animation = nil; $0.disablesAnimations = true }))
        window.contentView = host; window.makeKeyAndOrderFront(nil)
    }
    func close() { window.makeFirstResponder(nil); window.orderOut(nil); window.close() }
    func settle() async throws {
        host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
    }
    func wait(file: StaticString = #fileID, line: UInt = #line, _ predicate: @MainActor () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !(try await predicate()) {
            guard ContinuousClock.now < deadline else {
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    if let png = bitmap.representation(using: .png, properties: [:]) {
                        try png.write(to: TestIsolation.require().appendingPathComponent("media-ui-failure.png"))
                    }
                }
                let buttons = accessible().filter { (attribute($0, "accessibilityRole") as? String) == NSAccessibility.Role.button.rawValue }
                    .map { (attribute($0, "accessibilityLabel") as? String) ?? "unnamed" }.prefix(15)
                let fields = descendants(host).compactMap { ($0 as? NSTextField)?.stringValue }.prefix(20)
                let markers = descendants(host).compactMap { $0 as? StorebenchControlMarker }.filter { $0.identifier?.rawValue.hasPrefix("ai-languages") == true }
                    .map { "\($0.identifier!.rawValue): \($0.available), \($0.convert($0.bounds, to: nil))" }
                throw Failure.timeout("\(file):\(line); buttons: \(buttons.joined(separator: ", ")); native fields: \(fields.joined(separator: ", ")); markers: \(markers.joined(separator: "; "))")
            }
            try await settle()
        }
        try await settle()
    }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    func attribute(_ node: NSObject, _ key: String) -> Any? {
        guard node.responds(to: NSSelectorFromString(key)) || node.responds(to: NSSelectorFromString("is" + key.prefix(1).uppercased() + key.dropFirst())) else { return nil }
        return node.value(forKey: key)
    }
    func accessible() -> [NSObject] {
        var result: [NSObject] = [], seen = Set<ObjectIdentifier>()
        func walk(_ node: NSObject) {
            guard result.count < 10_000, seen.insert(ObjectIdentifier(node)).inserted else { return }
            result.append(node)
            for child in attribute(node, "accessibilityChildren") as? [NSObject] ?? [] { walk(child) }
        }
        walk(host); return result
    }
    func control(_ label: String) -> NSObject? {
        let aliases = ["AI Generate…": "media.ai", "Add Screenshots…": "ai-cards.add-screenshots", "Save All to Asset Library": "media.save-library"]
        if let marker = descendants(host).compactMap({ $0 as? StorebenchControlMarker }).first(where: { $0.identifier?.rawValue == (aliases[label] ?? label) }) { return marker }
        return accessible().first { node in
            let name = attribute(node, "accessibilityIdentifier") as? String ?? ""
            let title = attribute(node, "accessibilityLabel") as? String ?? ""
            return (name == label || title == label) && (attribute(node, "accessibilityRole") as? String) == NSAccessibility.Role.button.rawValue
                && node.responds(to: NSSelectorFromString("accessibilityPerformPress"))
        }
    }
    func press(_ label: String) async throws {
        window.makeKeyAndOrderFront(nil)
        guard let node = control(label) else { throw Failure.missingControl(label) }
        if let marker = node as? StorebenchControlMarker {
            guard marker.available else { throw Failure.disabledControl(label) }
            marker.scrollToVisible(marker.bounds.insetBy(dx: 0, dy: -80)); try await settle()
            let x = label.hasPrefix("ai-languages.target.") ? marker.bounds.minX + 8 : marker.bounds.midX
            let point = marker.convert(.init(x: x, y: marker.bounds.midY), to: nil)
            if label.hasPrefix("ai-languages.target.") {
                let local = host.convert(point, from: nil)
                print("Synthetic target click: \(label), window point: \(point), visible: \(host.bounds.contains(local)), hit: \(String(describing: host.hitTest(local).map { type(of: $0) }))")
            }
            let row = marker.convert(marker.bounds, to: nil)
            if !label.hasPrefix("ai-languages.target."), let native = descendants(host).compactMap({ $0 as? NSControl }).first(where: {
                let bounds = $0.convert($0.bounds, to: nil)
                return $0.cell is NSButtonCell && !$0.isHiddenOrHasHiddenAncestor && (bounds.contains(point) || (bounds.intersects(row) && abs(bounds.midY - row.midY) < max(2, row.height / 2)))
            }) {
                guard native.isEnabled else { throw Failure.disabledControl(label) }; native.performClick(nil); return
            }
            for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: kind == .leftMouseDown ? 1 : 0) else { throw Failure.missingControl(label) }
                window.sendEvent(event)
            }
            return
        }
        guard (attribute(node, "accessibilityEnabled") as? NSNumber)?.boolValue != false else { throw Failure.disabledControl(label) }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        let action = unsafeBitCast(node.method(for: selector), to: Press.self)
        guard action(node, selector) else { throw Failure.disabledControl(label) }
    }
    func enabled(_ label: String) -> Bool {
        guard let node = control(label) else { return false }
        if let marker = node as? StorebenchControlMarker { return marker.available && !marker.bounds.isEmpty }
        return (attribute(node, "accessibilityEnabled") as? NSNumber)?.boolValue == true
    }
    func nameField() -> NSTextField? {
        let fields = descendants(host).compactMap { $0 as? NSTextField }.filter(\.isEditable)
        return fields.first { $0.accessibilityLabel() == "Card Set Name" } ?? fields.first
    }
    func typeName(_ value: String) throws {
        guard let field = nameField(), field.isEnabled else { throw Failure.missingControl("Card Set Name") }
        window.makeFirstResponder(field)
        guard let editor = field.currentEditor() as? NSTextView else { throw Failure.missingControl("Name Editor") }
        editor.setSelectedRange(.init(location: 0, length: editor.string.utf16.count)); editor.insertText(value, replacementRange: editor.selectedRange())
        window.makeFirstResponder(nil)
    }
    func typeBrief(_ value: String) throws {
        guard let editor = descendants(host).compactMap({ $0 as? NSTextView }).first(where: { !$0.isFieldEditor && $0.isEditable }) else { throw Failure.missingControl("Brief") }
        window.makeFirstResponder(editor)
        editor.setSelectedRange(.init(location: 0, length: editor.string.utf16.count)); editor.insertText(value, replacementRange: editor.selectedRange())
        window.makeFirstResponder(nil)
    }
    func modelMenu(_ title: String) -> NSPopUpButton? {
        descendants(host).compactMap { $0 as? NSPopUpButton }.first { $0.itemTitles.contains(title) }
    }
    func chooseModel(_ title: String) throws {
        guard let menu = modelMenu(title), menu.isEnabled, let action = menu.action else { throw Failure.missingControl("AI Model") }
        menu.selectItem(withTitle: title)
        guard menu.sendAction(action, to: menu.target) else { throw Failure.disabledControl("AI Model") }
    }
}

@MainActor @Suite(.serialized) struct AIMediaE2ETests {
    init() throws { _ = try TestIsolation.require() }
    @MainActor private struct Fixture {
        let session: WorkspaceSession, root: URL, account: Account, app: Account.App, screenshot: URL
        func view() -> some View {
            CreateMediaView(account: account, app: app, session: session, selectAIScreenshots: { _ in
                try await SelectedFiles.readAsync([screenshot], purpose: .screenshotEditing)
            }, availableTranslationTargets: { _, _ in ["sv"] })
        }
        var scope: LocalEditorDraft.Scope { .init(accountId: account.id, appId: app.id, editor: "ai-cards", resource: "composer") }
    }
    private func fixture() async throws -> Fixture {
        let owned = try TestIsolation.require(), root = owned.appendingPathComponent("media-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("state-v2"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.copyItem(at: owned.appendingPathComponent("native-fixtures/storebench-v2.sqlite"), to: EncryptedDocumentStore.databaseURL(root: root))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: EncryptedDocumentStore.databaseURL(root: root).path)
        let key = Data(0..<32).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let record = JSONText.object([("schemaVersion", .number(1)), ("phase", .string("ready")), ("envelope", .object([("version", .number(1)), ("mode", .string("device")), ("key", .string(key))]))])
        let data = JSONText.object([("version", .number(1)), ("entries", .object([(CredentialVault.databaseEntry(root: root), .string(record.stringify()))]))]).data
        let writer = VaultWriter(dataRoot: root, storage: MemoryVaultStorage(data)), session = try WorkspaceSession(workspace: Workspace(root: root), vault: CredentialVault(json: data))
        _ = try await session.saveAIConnection(provider: .openai, model: "synthetic-ui-model", apiKey: "synthetic-ui-key", expected: 0, writer: writer)
        var preferences = try await session.aiSetupPreferences(); preferences.defaultProvider = .openai
        _ = try await session.saveAISetupPreferences(preferences.answering(.never))
        try await session.configureMediaUITransport()
        let context = try #require(CGContext(data: nil, width: 1600, height: 1000, bitsPerComponent: 8, bytesPerRow: 6400, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)); context.fill(.init(x: 0, y: 0, width: 1600, height: 1000))
        let bytes = NSMutableData(), output = try #require(CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(output, try #require(context.makeImage()), nil); #expect(CGImageDestinationFinalize(output))
        let screenshot = root.appendingPathComponent("synthetic-screen.png"); try (bytes as Data).write(to: screenshot)
        let account = try #require(try await session.accounts().first), app = try #require(account.apps.first { $0.id == "1000000001" })
        return Fixture(session: session, root: root, account: account, app: app, screenshot: screenshot)
    }
    private func fill(_ ui: OwnedMediaWindow, _ f: Fixture) async throws {
        try await ui.wait { ui.control("AI Generate…") != nil }
        try await ui.press("AI Generate…")
        try await ui.wait { ui.nameField()?.isEnabled == true }
        try ui.typeName("Synthetic UI Cards"); try await ui.settle()
        try ui.typeBrief("Explain the synthetic app with a concise benefit."); try await ui.settle()
        try await ui.press("Add Screenshots…")
        try await ui.wait { try await f.session.localEditorDraft(f.scope)?.value["screenshots"] != nil }
        try await ui.wait { ui.enabled("ai-cards.save-draft") }
        try await ui.press("ai-cards.save-draft")
        try await ui.wait { try await f.session.localEditorDraft(f.scope)?.value["name"] == .string("Synthetic UI Cards") }
    }

    @Test func UIChoosesScreenshotsSavesGeneratesExportsAndReopensWithoutAnotherModelRequest() async throws {
        MediaAIStubProtocol.reset(quota: false)
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let ui = OwnedMediaWindow(f.view()); defer { ui.close() }
        try await fill(ui, f)
        try await ui.wait { ui.enabled("ai-cards.generate") }
        try await ui.press("ai-cards.generate")
        try await ui.wait { try await f.session.mediaCardSets(accountId: f.account.id, appId: f.app.id).count == 1 }
        try await ui.wait { ui.enabled("Save All to Asset Library") }
        try await ui.press("Save All to Asset Library")
        try await ui.wait { try await f.session.assetLibraryFiles(accountId: f.account.id, appId: f.app.id).count == 1 }
        #expect(MediaAIStubProtocol.count == 1)
        let files = try await f.session.assetLibraryFiles(accountId: f.account.id, appId: f.app.id)
        #expect(files[0].width == MediaCards.defaultTarget.width && files[0].height == MediaCards.defaultTarget.height && !files[0].hasAlpha)
        try await ui.wait { try await f.session.mediaCardSets(accountId: f.account.id, appId: f.app.id).first?.set.savedCards != nil }
        ui.close()
        let reopened = OwnedMediaWindow(f.view()); defer { reopened.close() }
        try await reopened.wait { reopened.control("AI Generate…") != nil }; try await reopened.press("AI Generate…")
        try await reopened.wait { reopened.nameField()?.stringValue == "Synthetic UI Cards" }
        try await reopened.wait { reopened.enabled("ai-cards.generate") }
        try await reopened.press("ai-cards.generate")
        try await reopened.wait { reopened.control("Save All to Asset Library") != nil }
        #expect(MediaAIStubProtocol.count == 1)
        #expect(try await f.session.mediaCardSets(accountId: f.account.id, appId: f.app.id).count == 1)
        #expect(try await f.session.publishHistory(accountId: f.account.id, appId: f.app.id).isEmpty)
    }

    @Test func UIQuotaFailureKeepsAnEditableDraftAndSendsOnlyOneAttempt() async throws {
        MediaAIStubProtocol.reset(quota: true)
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let ui = OwnedMediaWindow(f.view()); defer { ui.close() }
        try await fill(ui, f); try await ui.wait { ui.enabled("ai-cards.generate") }; try await ui.press("ai-cards.generate")
        try await ui.wait { try await f.session.aiJobs(accountId: f.account.id, appId: f.app.id).first?.state == .failed }
        #expect(MediaAIStubProtocol.count == 1)
        #expect(try await f.session.mediaCardSets(accountId: f.account.id, appId: f.app.id).isEmpty)
        try await ui.wait { ui.nameField()?.isEnabled == true }
        try ui.typeName("Synthetic Kept Draft"); try await ui.settle(); try await ui.press("ai-cards.save-draft")
        try await ui.wait { try await f.session.localEditorDraft(f.scope)?.value["name"] == .string("Synthetic Kept Draft") }
        #expect(MediaAIStubProtocol.count == 1)
        #expect(try await f.session.publishHistory(accountId: f.account.id, appId: f.app.id).isEmpty)
    }

    @Test func UISelectsTwoLanguagesAndSavesTranslationsWithoutReplacingExistingText() async throws {
        MediaAIStubProtocol.reset(quota: false)
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let revision = "00000000-0000-4000-8000-000000000002"
        let sv = try await f.session.addLanguage(accountId: f.account.id, appId: f.app.id, revisionId: revision, versionId: "version-1", locale: "sv", copyFrom: nil)
        let initial = try await f.session.textDraft(accountId: f.account.id, appId: f.app.id, revisionId: revision, localizationId: sv, scope: .version)
        var fields = initial.fields; fields["description"] = "Existing synthetic Swedish text"
        _ = try await f.session.saveTextDraft(accountId: f.account.id, appId: f.app.id, revisionId: revision, localizationId: sv, scope: .version, fields: fields, fingerprint: initial.fingerprint)
        let source = try await f.session.translationRequest(accountId: f.account.id, appId: f.app.id, revisionId: revision, versionId: "version-1", sourceLocale: "en-US")
        let imported = try #require(try await f.session.revisions(accountId: f.account.id, appId: f.app.id).first { $0.id == revision })
        let saved = try await f.session.workspaceRevision(imported, accountId: f.account.id, appId: f.app.id)
        let version = try #require(saved.versions.first { $0.id == "version-1" })
        let ui = OwnedMediaWindow(AIListingTranslationView(account: f.account, appId: f.app.id, revisionId: revision, version: version, session: f.session)); defer { ui.close() }
        try await ui.wait { ui.enabled("ai-languages.targets") }
        try await ui.press("ai-languages.targets")
        try await ui.wait { ui.enabled("ai-languages.target.sv") }
        try await ui.press("ai-languages.target.sv"); try await ui.settle()
        try await ui.press("ai-languages.target.de-DE"); try await ui.settle()
        try await ui.wait { ui.enabled("ai-languages.populate") }
        try await ui.press("ai-languages.populate")
        try await ui.wait {
            guard let german = try? await f.session.aiTranslationTarget(accountId: f.account.id, appId: f.app.id, revisionId: revision, versionId: "version-1", locale: "de-DE") else { return false }
            let swedish = try await f.session.textDraft(accountId: f.account.id, appId: f.app.id, revisionId: revision, localizationId: sv, scope: .version)
            return german.first { $0.selection.scope == .version }?.draft.fields["description"] == "de-0" && swedish.fields["keywords"] == "sv-0,sv-1"
        }
        let swedish = try await f.session.textDraft(accountId: f.account.id, appId: f.app.id, revisionId: revision, localizationId: sv, scope: .version)
        #expect(swedish.fields["description"] == "Existing synthetic Swedish text" && swedish.fields["keywords"] == "sv-0,sv-1")
        #expect(MediaAIStubProtocol.count == 2)
        #expect(try await f.session.translationRequest(accountId: f.account.id, appId: f.app.id, revisionId: revision, versionId: "version-1", sourceLocale: "en-US") == source)
        #expect(try await f.session.publishHistory(accountId: f.account.id, appId: f.app.id).isEmpty)
    }

    @Test func UITaskModelSurvivesReopeningAndRunsWithoutChangingTheSavedDefault() async throws {
        MediaAIStubProtocol.reset(quota: false)
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let original = try #require(try await f.session.aiConnections().first { $0.provider == .openai })
        let ui = OwnedMediaWindow(f.view())
        try await fill(ui, f)
        try await ui.wait { ui.modelMenu("Synthetic Alternative") != nil }
        try ui.chooseModel("Synthetic Alternative"); try await ui.settle()
        try await ui.press("ai-cards.save-draft")
        try await ui.wait { try await f.session.localEditorDraft(f.scope)?.value["model"] == .string("synthetic-ui-alternate") }
        #expect(MediaAIStubProtocol.count == 0)
        ui.close()
        let reopened = OwnedMediaWindow(f.view()); defer { reopened.close() }
        try await reopened.wait { reopened.control("AI Generate…") != nil }; try await reopened.press("AI Generate…")
        try await reopened.wait { reopened.modelMenu("Synthetic Alternative")?.selectedItem?.title == "Synthetic Alternative" && reopened.enabled("ai-cards.generate") }
        try await reopened.press("ai-cards.generate")
        try await reopened.wait { try await f.session.mediaCardSets(accountId: f.account.id, appId: f.app.id).count == 1 }
        #expect(MediaAIStubProtocol.models == ["synthetic-ui-alternate"])
        #expect(try await f.session.aiConnections().first { $0.provider == .openai } == original)
        #expect(try await f.session.aiJobs(accountId: f.account.id, appId: f.app.id).first?.connection.model == "synthetic-ui-alternate")
    }
}
