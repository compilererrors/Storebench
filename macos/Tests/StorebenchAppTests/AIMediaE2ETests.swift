import AppKit
import ImageIO
import SwiftUI
import Testing
@testable import StorebenchApp
@testable import StorebenchCore

private final class MediaAIStubProtocol: URLProtocol, @unchecked Sendable {
    enum Outcome: Sendable, Equatable { case success, quota, malformed, unavailable }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var calls = 0
    nonisolated(unsafe) private static var outcome = Outcome.success
    nonisolated(unsafe) private static var limit = 2
    nonisolated(unsafe) private static var holding = false
    nonisolated(unsafe) private static var pending: [@Sendable () -> Void] = []
    nonisolated(unsafe) private static var sentModels: [String] = []
    nonisolated(unsafe) private static var bodies: [JSONText] = []
    private let deliveryLock = NSLock()
    private var stopped = false, delivered = false
    static func reset(quota: Bool = false, outcome: Outcome = .success, maximumRequests: Int = 2, hold: Bool = false) {
        lock.withLock {
            #expect(pending.isEmpty, "Every owned response gate must be released before the next journey")
            calls = 0; self.outcome = quota ? .quota : outcome; limit = maximumRequests; holding = hold; sentModels = []; bodies = []
        }
    }
    static var count: Int { lock.withLock { calls } }
    static var models: [String] { lock.withLock { sentModels } }
    static var requests: [JSONText] { lock.withLock { bodies } }
    static func respond(with outcome: Outcome) { lock.withLock { self.outcome = outcome } }
    static func release() {
        let work = lock.withLock { holding = false; let work = pending; pending = []; return work }
        for send in work { send() }
    }
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
        let (outcome, allowed) = Self.lock.withLock { Self.calls += 1; return (Self.outcome, Self.calls <= Self.limit) }
        guard allowed else {
            Issue.record("AI generation exceeded this journey's explicit request budget")
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled)); return
        }
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; body.append(buffer, count: count)
            }
        }
        let requestBody = (try? JSONText.parse(body)) ?? .null
        Self.lock.withLock { Self.sentModels.append(requestBody["model"]?.text ?? ""); Self.bodies.append(requestBody) }
        let input: JSONText = {
            guard case .array(let input)? = requestBody["input"], case .array(let parts)? = input.first?["content"], let text = parts.first?["text"]?.text else { return .null }
            return (try? JSONText.parse(Data(text.utf8))) ?? .null
        }()
        let count: Int = if case .number(let value)? = input["screenshotCount"], let count = Int(exactly: value), (1...10).contains(count) { count } else { 1 }
        let cards = (0..<count).reversed().map { index in
            JSONText.object([("screenshotIndex", .number(Double(index))), ("title", .string(index == 0 ? "A Synthetic Benefit" : "Synthetic Feature \(index + 1)")), ("subtitle", .string("A short synthetic detail")),
                ("layout", .string("textAbove")), ("color", .string("#15243f")), ("secondColor", .string("#315fb3")), ("titleColor", .string("#ffffff"))])
        }
        var result = JSONText.object([("cards", .array(cards))])
        if let requestBody = try? JSONText.parse(body), requestBody["text"]?["format"]?["schema"]?["properties"]?["translations"] != nil,
           case .array(let input)? = requestBody["input"], case .array(let parts)? = input.first?["content"], let text = parts.first?["text"]?.text,
           case .array(let texts)? = try? JSONText.parse(Data(text.utf8)) {
            let language = requestBody["instructions"]?.text?.contains("to de-DE.") == true ? "de" : "sv"
            result = .object([("translations", .array(texts.indices.map { .string(language + "-\($0)") }))])
        }
        if outcome == .malformed { result = .object([("cards", .array([]))]) }
        let content = result.stringify()
        let response = JSONText.object([("status", .string("completed")), ("output", .array([.object([("content", .array([.object([("type", .string("output_text")), ("text", .string(content))])]))])]))]).data
        let status = outcome == .quota ? 429 : outcome == .unavailable ? 503 : 200
        let send: @Sendable () -> Void = { [self] in deliver(status: status, bytes: status == 200 ? response : Data()) }
        let deferred = Self.lock.withLock { if Self.holding { Self.pending.append(send); return true }; return false }
        if !deferred { send() }
    }
    private func deliver(status: Int, bytes: Data) {
        guard deliveryLock.withLock({ if stopped || delivered { return false }; delivered = true; return true }) else { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { deliveryLock.withLock { stopped = true } }
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
                let fields = views.compactMap { ($0 as? NSTextField)?.stringValue ?? ($0 as? NSTextView)?.string }.prefix(35)
                let markers = descendants(host).compactMap { $0 as? StorebenchControlMarker }.filter { $0.identifier?.rawValue.hasPrefix("ai-languages") == true }
                    .map { "\($0.identifier!.rawValue): \($0.available), \($0.convert($0.bounds, to: nil))" }
                throw Failure.timeout("\(file):\(line); buttons: \(buttons.joined(separator: ", ")); native fields: \(fields.joined(separator: ", ")); markers: \(markers.joined(separator: "; "))")
            }
            try await settle()
        }
        try await settle()
    }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private var roots: [NSView] { [host] + window.sheets.compactMap(\.contentView) }
    private var views: [NSView] { roots.flatMap(descendants) }
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
        for root in roots { walk(root) }; return result
    }
    func control(_ label: String) -> NSObject? {
        let aliases = ["AI Generate…": "media.ai", "Add Screenshots…": "ai-cards.add-screenshots", "Save All to Asset Library": "media.save-library"]
        if let marker = views.compactMap({ $0 as? StorebenchControlMarker }).first(where: { $0.identifier?.rawValue == (aliases[label] ?? label) }) { return marker }
        return accessible().first { node in
            let name = attribute(node, "accessibilityIdentifier") as? String ?? ""
            let title = attribute(node, "accessibilityLabel") as? String ?? ""
            let role = attribute(node, "accessibilityRole") as? String
            return (name == label || title == label) && [NSAccessibility.Role.button.rawValue, NSAccessibility.Role.radioButton.rawValue, NSAccessibility.Role.checkBox.rawValue].contains(role ?? "")
                && node.responds(to: NSSelectorFromString("accessibilityPerformPress"))
        }
    }
    func press(_ label: String) async throws {
        window.makeKeyAndOrderFront(nil)
        guard let node = control(label) else { throw Failure.missingControl(label) }
        if let marker = node as? StorebenchControlMarker {
            guard marker.available else { throw Failure.disabledControl(label) }
            let targetWindow = marker.window ?? window
            targetWindow.makeKeyAndOrderFront(nil)
            try await reveal(marker)
            let x = label.hasPrefix("ai-languages.target.") ? marker.bounds.minX + 8 : marker.bounds.midX
            let point = marker.convert(.init(x: x, y: marker.bounds.midY), to: nil)
            if label == "ai-history.response" {
                print("Synthetic history response target: \(point); visible: \(marker.visibleRect); sheet: \(targetWindow.contentLayoutRect)")
            }
            if label.hasPrefix("ai-languages.target.") {
                let local = host.convert(point, from: nil)
                print("Synthetic target click: \(label), window point: \(point), visible: \(host.bounds.contains(local)), hit: \(String(describing: host.hitTest(local).map { type(of: $0) }))")
            }
            let row = marker.convert(marker.bounds, to: nil)
            if !label.hasPrefix("ai-languages.target."), let native = descendants(targetWindow.contentView ?? host).compactMap({ $0 as? NSControl }).first(where: {
                let bounds = $0.convert($0.bounds, to: nil)
                return $0.window === targetWindow && $0.cell is NSButtonCell && !$0.isHiddenOrHasHiddenAncestor && (bounds.contains(point) || (bounds.intersects(row) && abs(bounds.midY - row.midY) < max(2, row.height / 2)))
            }) {
                guard native.isEnabled else { throw Failure.disabledControl(label) }; native.performClick(nil); return
            }
            for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: targetWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: kind == .leftMouseDown ? 1 : 0) else { throw Failure.missingControl(label) }
                targetWindow.sendEvent(event)
            }
            return
        }
        guard (attribute(node, "accessibilityEnabled") as? NSNumber)?.boolValue != false else { throw Failure.disabledControl(label) }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        let action = unsafeBitCast(node.method(for: selector), to: Press.self)
        guard action(node, selector) else { throw Failure.disabledControl(label) }
    }
    private func reveal(_ marker: NSView) async throws {
        for _ in 0..<2 {
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
        }
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
    func promptEditor(_ id: String = "ai-cards.prompt-text") -> NSTextView? {
        guard let marker = descendants(host).compactMap({ $0 as? StorebenchControlMarker }).first(where: { $0.identifier?.rawValue == id }) else { return nil }
        let frame = host.convert(marker.bounds, from: marker)
        return descendants(host).compactMap { $0 as? NSTextView }.first { editor in
            guard !editor.isFieldEditor, editor.isEditable else { return false }
            let viewport: NSView = editor.enclosingScrollView ?? editor
            return frame.intersects(host.convert(viewport.bounds, from: viewport))
        }
    }
    func typePrompt(_ value: String, id: String = "ai-cards.prompt-text") throws {
        guard let editor = promptEditor(id) else { throw Failure.missingControl(id) }
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
    func chooseColor(_ id: String, color: NSColor) throws {
        guard let marker = control(id) as? StorebenchControlMarker, marker.available else { throw Failure.missingControl(id) }
        let frame = marker.convert(marker.bounds, to: nil)
        guard let well = views.compactMap({ $0 as? NSColorWell }).first(where: {
            let bounds = $0.convert($0.bounds, to: nil); return frame.contains(CGPoint(x: bounds.midX, y: bounds.midY))
        }),
              well.isEnabled, let action = well.action else { throw Failure.missingControl(id) }
        well.color = color
        guard well.sendAction(action, to: well.target) else { throw Failure.disabledControl(id) }
    }
    func burst(_ id: String, count: Int) async throws {
        guard let marker = control(id) as? StorebenchControlMarker, marker.available else { throw Failure.missingControl(id) }
        marker.scrollToVisible(marker.bounds.insetBy(dx: 0, dy: -80)); try await settle()
        let point = marker.convert(.init(x: marker.bounds.midX, y: marker.bounds.midY), to: nil)
        for _ in 0..<count {
            for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: kind == .leftMouseDown ? 1 : 0))
                window.sendEvent(event)
            }
        }
    }
    func containsText(_ value: String) -> Bool {
        if views.compactMap({ ($0 as? NSTextField)?.stringValue ?? ($0 as? NSTextView)?.string }).contains(where: { $0.contains(value) }) { return true }
        return accessible().contains { node in
            ["accessibilityLabel", "accessibilityValue"].contains { key in (attribute(node, key) as? String)?.contains(value) == true }
        }
    }
    func captureSheet(_ name: String) throws {
        guard let view = window.sheets.last?.contentView else { throw Failure.missingControl("Owned Sheet") }
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: TestIsolation.require().appendingPathComponent(name + ".png"))
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

    @Test func UIColorsPerCardMessagesAndHistoryRoundTripWithoutExtraModelRequests() async throws {
        MediaAIStubProtocol.reset(maximumRequests: 1)
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let ui = OwnedMediaWindow(f.view()); defer { ui.close() }
        try await fill(ui, f)
        try ui.typePrompt("Explain synthetic country pricing.", id: "ai-cards.card-brief-0"); try await ui.settle()
        try await ui.press("ai-cards.add-screenshots")
        try await ui.wait { ui.promptEditor("ai-cards.card-brief-1") != nil }
        try ui.typePrompt("Explain synthetic daily reports.", id: "ai-cards.card-brief-1"); try await ui.settle()
        try await ui.press("choice.Color Direction.1")
        try await ui.wait { ui.control("ai-cards.color-start") != nil }
        try ui.chooseModel("Solid Color"); try await ui.settle()
        try ui.chooseColor("ai-cards.color-start", color: NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        try ui.chooseColor("ai-cards.color-text", color: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)); try await ui.settle()
        try await ui.press("ai-cards.save-draft")
        try await ui.wait { try await f.session.localEditorDraft(f.scope)?.value["cardPalette"]?["color"] == .string("#336699") }
        #expect(MediaAIStubProtocol.count == 0, "Editing and saving must not spend a model request")
        ui.close()
        let reopened = OwnedMediaWindow(f.view()); defer { reopened.close() }
        try await reopened.wait { reopened.control("media.ai") != nil }; try await reopened.press("media.ai")
        try await reopened.wait { reopened.promptEditor("ai-cards.card-brief-1")?.string == "Explain synthetic daily reports." }
        #expect(reopened.promptEditor("ai-cards.card-brief-0")?.string == "Explain synthetic country pricing.")
        #expect(reopened.modelMenu("Solid Color")?.titleOfSelectedItem == "Solid Color")
        try await reopened.press("ai-cards.generate")
        try await reopened.wait { try await f.session.mediaCardSets(accountId: f.account.id, appId: f.app.id).first?.set.cards.count == 2 }
        let saved = try #require(try await f.session.mediaCardSets(accountId: f.account.id, appId: f.app.id).first)
        #expect(saved.set.cards.map(\.title) == ["Synthetic Feature 2", "A Synthetic Benefit"])
        #expect(saved.set.cards.allSatisfy { $0.style.fill == .solid && $0.style.color == "#336699" && $0.style.titleColor == "#FFFFFF" })
        let wire = try #require(MediaAIStubProtocol.requests.first)
        guard case .array(let input)? = wire["input"], case .array(let parts)? = input.first?["content"], let text = parts.first?["text"]?.text else { throw AIFailure.response }
        let submitted = try JSONText.parse(Data(text.utf8))
        guard case .array(let instructions)? = submitted["cardInstructions"] else { throw AIFailure.response }
        #expect(instructions.map { $0["instructions"]?.text } == ["Explain synthetic country pricing.", "Explain synthetic daily reports."])
        #expect(submitted["palette"]?["color"] == .string("#336699"))
        try await reopened.wait { reopened.enabled("media.save-library") }; try await reopened.press("media.save-library")
        try await reopened.wait { try await f.session.assetLibraryFiles(accountId: f.account.id, appId: f.app.id).count == 2 }
        try await reopened.wait { try await f.session.mediaCardSets(accountId: f.account.id, appId: f.app.id).first?.set.savedCards != nil }
        try await reopened.wait { reopened.enabled("media.recreate-card") }
        try await reopened.press("media.recreate-card")
        try await reopened.wait { reopened.promptEditor("ai-cards.card-brief-0")?.string == "Explain synthetic daily reports." }
        #expect(MediaAIStubProtocol.count == 1, "Export and Re-create only reopen saved material")

        let history = OwnedMediaWindow(AIHistorySection(session: f.session)); defer { history.close() }
        for _ in 0..<3 {
            try await history.wait { history.enabled("ai-history.refresh") }; try await history.press("ai-history.refresh")
            try await history.settle()
        }
        let entry = try #require(try await f.session.aiHistory(accountId: f.account.id, appId: f.app.id).first)
        let openID = "collection.open." + entry.id
        try await history.wait { history.enabled(openID) }; try await history.press(openID)
        try await history.wait { !history.window.sheets.isEmpty && history.control("ai-history.instructions") != nil }
        try await history.press("ai-history.instructions")
        try await history.wait { history.containsText("Explain synthetic daily reports.") }
        try await history.press("ai-history.instructions"); try await history.settle()
        try await history.press("ai-history.response")
        try await history.settle(); try history.captureSheet("history-response")
        try await history.wait { history.containsText("Synthetic Feature 2") }
        try await history.press("dialog.close")
        try await history.wait { history.window.sheets.isEmpty }
        #expect(MediaAIStubProtocol.count == 1 && MediaAIStubProtocol.requests.count == 1)
        #expect(try await f.session.publishHistory(accountId: f.account.id, appId: f.app.id).isEmpty)
    }

    @Test func UIBurstGenerationSendsOneRequestAndKeepsTheWindowResponsive() async throws {
        MediaAIStubProtocol.reset(maximumRequests: 1, hold: true); defer { MediaAIStubProtocol.release() }
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let ui = OwnedMediaWindow(f.view()); defer { ui.close() }
        try await fill(ui, f)
        try await ui.burst("ai-cards.generate", count: 12)
        try await ui.wait { MediaAIStubProtocol.count == 1 && !ui.enabled("ai-cards.generate") }
        #expect(!ui.enabled("ai-cards.save-draft"))
        var worst = Duration.zero
        for index in 0..<8 {
            let start = ContinuousClock.now
            ui.window.setContentSize(.init(width: index.isMultiple(of: 2) ? 960 : 1280, height: 1000))
            ui.host.layoutSubtreeIfNeeded(); ui.window.displayIfNeeded()
            worst = max(worst, ContinuousClock.now - start)
            try await ui.settle()
            #expect(!ui.enabled("ai-cards.generate") && MediaAIStubProtocol.count == 1)
        }
        #expect(worst < .seconds(1), "A waiting AI service must not block native layout and event handling")
        print("Synthetic AI-wait UI response maximum: \(worst)")
        MediaAIStubProtocol.release()
        try await ui.wait { try await f.session.mediaCardSets(accountId: f.account.id, appId: f.app.id).count == 1 }
        #expect(try await f.session.aiHistory(accountId: f.account.id, appId: f.app.id).count == 1)
        #expect(MediaAIStubProtocol.count == 1)
    }

    @Test(arguments: [MediaAIStubProtocol.Outcome.quota, .malformed, .unavailable])
    private func UIFailuresRequireAnExplicitRetryAndKeepEverySavedDraft(_ outcome: MediaAIStubProtocol.Outcome) async throws {
        MediaAIStubProtocol.reset(outcome: outcome, maximumRequests: 2)
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let ui = OwnedMediaWindow(f.view()); defer { ui.close() }
        try await fill(ui, f)
        try ui.typePrompt("Keep the synthetic report message.", id: "ai-cards.card-brief-0"); try await ui.settle()
        try await ui.press("ai-cards.generate")
        try await ui.wait { try await f.session.aiHistory(accountId: f.account.id, appId: f.app.id).first?.state == .failed }
        try await ui.wait { ui.enabled("ai-cards.save-draft") }
        try await ui.press("ai-cards.save-draft")
        for _ in 0..<3 { ui.window.orderOut(nil); ui.window.makeKeyAndOrderFront(nil); try await ui.settle() }
        #expect(MediaAIStubProtocol.count == 1, "Showing and saving a failed draft must not retry it")
        #expect(try await f.session.mediaCardSets(accountId: f.account.id, appId: f.app.id).isEmpty)
        #expect(try await f.session.localEditorDraft(f.scope)?.value["cardBriefs"] == .array([.string("Keep the synthetic report message.")]))
        MediaAIStubProtocol.respond(with: .success)
        try await ui.press("ai-cards.generate")
        try await ui.wait { try await f.session.mediaCardSets(accountId: f.account.id, appId: f.app.id).count == 1 }
        let history = try await f.session.aiHistory(accountId: f.account.id, appId: f.app.id)
        #expect(history.count == 2 && history.filter { $0.state == .failed }.count == 1 && history.filter { $0.state == .complete }.count == 1)
        #expect(MediaAIStubProtocol.count == 2)
        #expect(try await f.session.publishHistory(accountId: f.account.id, appId: f.app.id).isEmpty)
    }

    @Test func UIInvalidPromptAndCardInstructionsCannotDispatchAModelRequest() async throws {
        MediaAIStubProtocol.reset(maximumRequests: 1)
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let ui = OwnedMediaWindow(f.view()); defer { ui.close() }
        try await fill(ui, f)
        try await ui.press("ai-cards.prompt-instructions")
        try await ui.wait { ui.enabled("ai-cards.edit-prompt") }; try await ui.press("ai-cards.edit-prompt")
        try await ui.wait { ui.promptEditor() != nil }
        for invalid in ["", String(repeating: "x", count: AICards.customInstructionsLimit + 1)] {
            try ui.typePrompt(invalid); try await ui.settle()
            #expect(!ui.enabled("ai-cards.generate") && MediaAIStubProtocol.count == 0)
        }
        try await ui.press("ai-cards.reset-prompt"); try await ui.settle()
        try ui.typePrompt(String(repeating: "x", count: AICards.cardBriefLimit + 1), id: "ai-cards.card-brief-0"); try await ui.settle()
        #expect(!ui.enabled("ai-cards.generate") && MediaAIStubProtocol.count == 0)
        try ui.typePrompt("", id: "ai-cards.card-brief-0"); try await ui.settle()
        try await ui.wait { ui.enabled("ai-cards.generate") }; try await ui.press("ai-cards.generate")
        try await ui.wait { try await f.session.mediaCardSets(accountId: f.account.id, appId: f.app.id).count == 1 }
        #expect(MediaAIStubProtocol.count == 1, "Optional empty card instructions must stay valid")
    }

    @Test func UIChoosesScreenshotsSavesExportsAndRecreatesWithoutReplacingEarlierCards() async throws {
        MediaAIStubProtocol.reset(quota: false)
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let ui = OwnedMediaWindow(f.view()); defer { ui.close() }
        try await fill(ui, f)
        try ui.typePrompt("Synthetic country pricing", id: "ai-cards.card-brief-0"); try await ui.settle()
        try await ui.press("ai-cards.add-screenshots")
        try await ui.wait { ui.promptEditor("ai-cards.card-brief-1") != nil }
        try ui.typePrompt("Synthetic daily reports", id: "ai-cards.card-brief-1"); try await ui.settle()
        try await ui.press("ai-cards.remove-screenshot-0")
        try await ui.wait { ui.promptEditor("ai-cards.card-brief-0")?.string == "Synthetic daily reports" }
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
        let first = try #require(try await f.session.mediaCardSets(accountId: f.account.id, appId: f.app.id).first)
        try await ui.wait { ui.enabled("media.recreate-card") }
        try await ui.press("media.recreate-card")
        try await ui.wait { ui.nameField()?.stringValue == "Synthetic UI Cards" && ui.enabled("ai-cards.generate") }
        try await ui.press("ai-cards.generate")
        try await ui.wait { try await f.session.mediaCardSets(accountId: f.account.id, appId: f.app.id).count == 2 }
        #expect(MediaAIStubProtocol.count == 2)
        #expect(try await f.session.mediaCardSets(accountId: f.account.id, appId: f.app.id).first { $0.set.id == first.set.id } == first)
        #expect(try await f.session.aiHistory(accountId: f.account.id, appId: f.app.id).count == 2)
        try await ui.wait { ui.enabled("media.return-ai") }
        try await ui.press("media.return-ai")
        try await ui.wait { ui.nameField()?.stringValue == "Synthetic UI Cards" }
        #expect(MediaAIStubProtocol.count == 2)
        try await ui.press("ai-cards.save-draft")
        ui.close()
        let reopened = OwnedMediaWindow(f.view()); defer { reopened.close() }
        try await reopened.wait { reopened.control("AI Generate…") != nil }; try await reopened.press("AI Generate…")
        try await reopened.wait { reopened.nameField()?.stringValue == "Synthetic UI Cards" }
        #expect(reopened.promptEditor("ai-cards.card-brief-0")?.string == "Synthetic daily reports")
        #expect(MediaAIStubProtocol.count == 2)
        #expect(try await f.session.publishHistory(accountId: f.account.id, appId: f.app.id).isEmpty)
    }

    @Test func UICustomPromptEditsResetPersistAndReachGeneration() async throws {
        MediaAIStubProtocol.reset(quota: false)
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let custom = "Use a synthetic editorial direction and describe the visible feature precisely."
        let ui = OwnedMediaWindow(f.view()); defer { ui.close() }
        try await fill(ui, f)
        try ui.typePrompt("Synthetic daily reports", id: "ai-cards.card-brief-0"); try await ui.settle()
        try await ui.press("ai-cards.prompt-instructions")
        try await ui.wait { ui.enabled("ai-cards.edit-prompt") }; try await ui.press("ai-cards.edit-prompt")
        try await ui.wait { ui.promptEditor() != nil }; try ui.typePrompt(custom); try await ui.settle()
        try await ui.press("ai-cards.edit-prompt"); try await ui.press("ai-cards.save-draft")
        try await ui.wait { try await f.session.localEditorDraft(f.scope)?.value["customInstructions"] == .string(custom) }
        #expect(MediaAIStubProtocol.count == 0)
        ui.close()
        let reopened = OwnedMediaWindow(f.view()); defer { reopened.close() }
        try await reopened.wait { reopened.control("media.ai") != nil }; try await reopened.press("media.ai")
        try await reopened.wait { reopened.nameField()?.stringValue == "Synthetic UI Cards" }
        #expect(reopened.promptEditor("ai-cards.card-brief-0")?.string == "Synthetic daily reports")
        try await reopened.press("ai-cards.prompt-instructions")
        try await reopened.wait { reopened.enabled("ai-cards.edit-prompt") }; try await reopened.press("ai-cards.edit-prompt")
        try await reopened.wait { reopened.promptEditor()?.string == custom }
        try await reopened.press("ai-cards.reset-prompt")
        try await reopened.wait { reopened.promptEditor()?.string == AICards.defaultInstructions }
        try reopened.typePrompt(custom); try await reopened.settle()
        try await reopened.press("ai-cards.generate")
        try await reopened.wait { try await f.session.mediaCardSets(accountId: f.account.id, appId: f.app.id).count == 1 }
        let job = try #require(try await f.session.aiJobs(accountId: f.account.id, appId: f.app.id).first)
        #expect(job.request.instructions.hasPrefix(custom) && job.request.cardDraft?["customInstructions"] == .string(custom))
        #expect(try AICards.cardBriefs(in: job.request.cardDraft ?? .null, count: 1) == ["Synthetic daily reports"])
        #expect(MediaAIStubProtocol.count == 1)
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
