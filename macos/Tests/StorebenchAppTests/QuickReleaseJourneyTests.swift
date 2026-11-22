import AppKit
import CryptoKit
import Foundation
import Observation
import StorebenchTestSupport
import SwiftUI
import Testing
@testable import StorebenchApp
@testable import StorebenchCore

private final class QuickReleaseStubProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var handlers: [String: @Sendable (URLRequest) -> (Int, [String: String], Data)] = [:]
    static func register(_ host: String, apple: QuickReleaseApple) { lock.withLock { handlers[host] = { apple.handle($0) } } }
    static func remove(_ host: String) { _ = lock.withLock { handlers.removeValue(forKey: host) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let host = request.url?.host, host.hasSuffix(".test"), let handle = Self.lock.withLock({ Self.handlers[host] }) else {
            Issue.record("Unregistered request in the synthetic release journey")
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        let (status, headers, bytes) = handle(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// A published starting version, copied into one update. Only reviewed synthetic writes can advance it.
private final class QuickReleaseApple: @unchecked Sendable {
    let apple = SyntheticApple()
    private var attached = false
    private var submissions: [[String: Any]] = [], items: [[String: Any]] = []
    init() {
        apple.setVersionState("READY_FOR_DISTRIBUTION")
        apple.lock.withLock {
            var attributes = apple.versions[0]["attributes"] as! [String: Any]
            attributes["copyright"] = "2026 Synthetic Publisher"; apple.versions[0]["attributes"] = attributes
            attributes = apple.locales[0]["attributes"] as! [String: Any]
            attributes["supportUrl"] = "https://example.test/support"; attributes["whatsNew"] = ""
            apple.locales[0]["attributes"] = attributes
            attributes = apple.builds[0]["attributes"] as! [String: Any]
            attributes["usesNonExemptEncryption"] = false; apple.builds[0]["attributes"] = attributes
            apple.rights = "DOES_NOT_USE_THIRD_PARTY_CONTENT"
        }
    }
    var writes: [(String, String, [String: Any]?)] { apple.lock.withLock { apple.writes } }
    var state: String? { apple.lock.withLock { (apple.versions.last?["attributes"] as? [String: Any])?["appVersionState"] as? String } }
    var notes: String? { apple.lock.withLock { (apple.locales.last?["attributes"] as? [String: Any])?["whatsNew"] as? String } }
    private func owner(_ type: String, _ id: String) -> [String: Any] { ["data": ["type": type, "id": id]] }
    private func detail() -> [String: Any] {
        ["type": "appStoreReviewDetails", "id": "detail-2", "attributes": ["contactFirstName": "Synthetic", "contactLastName": "Reviewer", "contactEmail": "review@example.invalid", "contactPhone": "0000000000", "demoAccountRequired": false],
         "relationships": ["appStoreVersion": owner("appStoreVersions", "version-2")]]
    }
    func handle(_ request: URLRequest) -> (Int, [String: String], Data) {
        let path = request.url!.path, method = request.httpMethod ?? "GET"
        let body = method == "GET" ? nil : (try? JSONSerialization.jsonObject(with: apple.body(request))) as? [String: Any]
        let handled: (Int, [String: String], Data)? = apple.lock.withLock {
            let data = body?["data"] as? [String: Any]
            if method != "GET" {
                switch (method, path) {
                case ("POST", "/v1/appStoreVersions"):
                    apple.writes.append((method, path, body))
                    var version = data!, attributes = data!["attributes"] as! [String: Any]
                    attributes["appVersionState"] = "PREPARE_FOR_SUBMISSION"; attributes["copyright"] = "2026 Synthetic Publisher"
                    version["id"] = "version-2"; version["attributes"] = attributes; apple.versions.append(version)
                    var locale = apple.locales[0]; locale["id"] = "version-locale-2"
                    locale["relationships"] = ["appStoreVersion": owner("appStoreVersions", "version-2")]; apple.locales.append(locale)
                    var placement = apple.placements[0]; placement["id"] = "shot-2"
                    placement["relationships"] = ["image": owner("appAssetLibraryImages", "image-1"), "appStoreVersionLocalization": owner("appStoreVersionLocalizations", "version-locale-2")]
                    apple.placements.append(placement)
                    return apple.page(version)
                case ("PATCH", "/v1/appStoreVersionLocalizations/version-locale-2"):
                    apple.writes.append((method, path, body))
                    var attributes = apple.locales[1]["attributes"] as! [String: Any]
                    attributes.merge(data?["attributes"] as? [String: Any] ?? [:]) { _, new in new }
                    apple.locales[1]["attributes"] = attributes; return apple.page(apple.locales[1])
                case ("PATCH", "/v1/appStoreVersions/version-2"):
                    apple.writes.append((method, path, body))
                    var version = apple.versions[1], attributes = version["attributes"] as! [String: Any]
                    attributes.merge(data?["attributes"] as? [String: Any] ?? [:]) { _, new in new }; version["attributes"] = attributes
                    if let relationships = data?["relationships"] as? [String: Any], relationships["build"] != nil {
                        attached = true
                        var existing = version["relationships"] as! [String: Any]; existing["build"] = relationships["build"]; version["relationships"] = existing
                    }
                    apple.versions[1] = version; return apple.page(version)
                case ("POST", "/v1/reviewSubmissions"), ("POST", "/v1/reviewSubmissionItems"):
                    apple.writes.append((method, path, body))
                    var value = data!
                    if path.hasSuffix("reviewSubmissions") {
                        value["id"] = "submission-1"; value["attributes"] = ["platform": "IOS", "state": "READY_FOR_REVIEW"]; submissions.append(value)
                    } else { value["id"] = "submission-item-1"; items.append(value) }
                    return apple.page(value)
                case ("PATCH", "/v1/reviewSubmissions/submission-1"):
                    apple.writes.append((method, path, body))
                    // Remove from Review cancels the submission, and App Store Connect shows the version as Developer Rejected.
                    let canceled = (data?["attributes"] as? [String: Any])?["canceled"] as? Bool == true
                    submissions[0]["attributes"] = ["platform": "IOS", "state": canceled ? "COMPLETE" : "WAITING_FOR_REVIEW"]
                    var attributes = apple.versions[1]["attributes"] as! [String: Any]
                    attributes["appVersionState"] = canceled ? "DEVELOPER_REJECTED" : "WAITING_FOR_REVIEW"; apple.versions[1]["attributes"] = attributes
                    return apple.page(submissions[0])
                default: Issue.record("Unexpected synthetic release write: \(method) \(path)"); return (405, [:], Data())
                }
            }
            switch path {
            case "/v1/appStoreVersions/version-1/appStoreVersionLocalizations": return apple.page([apple.locales[0]])
            case "/v1/appStoreVersions/version-2/appStoreVersionLocalizations": return apple.page(Array(apple.locales.dropFirst()))
            case "/v1/appStoreVersions/version-2/build": return attached ? apple.page(apple.builds[0]) : (404, [:], Data())
            case "/v1/appStoreVersions/version-2/appStoreReviewDetail", "/v1/appStoreReviewDetails/detail-2": return apple.page(detail())
            case "/v1/appStoreReviewDetails/detail-2/appStoreReviewAttachments", "/v1/appStoreVersionLocalizations/version-locale-2/appPreviewSets": return apple.page([])
            case "/v1/appInfos/info-1/appInfoLocalizations", "/v1/appInfoLocalizations/info-locale-1":
                let info: [String: Any] = ["type": "appInfoLocalizations", "id": "info-locale-1", "attributes": ["locale": "en-US", "name": "Sample App Updated", "subtitle": "Sample subtitle", "privacyPolicyUrl": "https://example.test/privacy"], "relationships": ["appInfo": owner("appInfos", "info-1")]]
                return apple.page(path.hasSuffix("appInfoLocalizations") ? [info] : info)
            case "/v1/builds/build-7": return apple.page(apple.builds[0])
            case "/v1/preReleaseVersions/pre-1": return apple.page(["type": "preReleaseVersions", "id": "pre-1", "attributes": ["version": "2.0", "platform": "IOS"]])
            case "/v1/apps/1000000001/reviewSubmissions": return apple.page(submissions)
            case "/v1/reviewSubmissions/submission-1": return submissions.isEmpty ? (404, [:], Data()) : apple.page(submissions[0])
            case "/v1/reviewSubmissions/submission-1/items": return apple.page(items)
            case "/v1/reviewSubmissionItems/submission-item-1": return items.isEmpty ? (404, [:], Data()) : apple.page(items[0])
            default: return nil
            }
        }
        return handled ?? apple.handle(request)
    }
}

private extension WorkspaceSession {
    func seedQuickReleaseScreenshot(key: String, hash: String) throws {
        try storeAccess { store in
            let document = try #require(try store.document(namespace: "revisions", key: key)), source = try JSONText.parse(document.payload)
            var versions = WorkspaceSession.items(source["versions"])
            let version = try #require(versions.firstIndex { $0["id"]?.text == "version-1" })
            var languages = WorkspaceSession.items(versions[version]["localizations"])
            let language = try #require(languages.firstIndex { $0["id"]?.text == "version-locale-1" })
            var sets = WorkspaceSession.items(languages[language]["screenshotSets"])
            let set = try #require(sets.firstIndex { $0["id"]?.text == "set-1" }), shots = WorkspaceSession.items(sets[set]["screenshots"])
            #expect(shots.count == 1)
            sets[set] = sets[set].setting("screenshots", .array(shots.map { $0.setting("sha256", .string(hash)).setting("width", .number(1290)).setting("height", .number(2796)).setting("contentType", .string("image/png")) }))
            languages[language] = languages[language].setting("screenshotSets", .array(sets))
            versions[version] = versions[version].setting("localizations", .array(languages))
            let payload = source.setting("versions", .array(versions)).data
            try store.transaction { current in
                guard try current("revisions", key)?.revision == document.revision else { throw DraftFailure.stale }
                return [.put(namespace: "revisions", key: key, json: payload)]
            }
        }
    }
}

@MainActor @Suite(.serialized) struct QuickReleaseJourneyTests {
    init() throws { _ = try TestIsolation.require() }
    private enum Failure: Error { case timeout(String) }
    private func seedScreenshot(_ session: WorkspaceSession, key: String) async throws {
        let image = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1290, pixelsHigh: 2796,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let pixels = try #require(image.bitmapData)
        pixels.initialize(repeating: 128, count: image.bytesPerRow * image.pixelsHigh)
        let bytes = try #require(image.representation(using: .png, properties: [:])), hash = try await session.media.write(bytes).hash
        try await session.seedQuickReleaseScreenshot(key: key, hash: hash)
    }

    private func completed(_ scope: PublishRequest.Scope, session: WorkspaceSession, account: Account) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while true {
            let reviews = try await session.publishHistory(accountId: account.id, appId: "1000000001").filter { $0.request.scope == scope }
            if reviews.contains(where: { $0.state == "complete" }) { return }
            if let failure = reviews.first(where: { ["failed", "conflict"].contains($0.state) }) { throw Failure.timeout(failure.error ?? failure.state) }
            guard ContinuousClock.now < deadline else { throw Failure.timeout("No completed review for " + scope.rawValue) }
            try await Task.sleep(for: .milliseconds(30))
        }
    }
    @MainActor @Observable final class Probe { var changed = 0; var section = AppNavigation.Section.quickRelease }
    private struct Harness: View {
        let account: Account, session: WorkspaceSession, controller: WorkspaceController, owner: ReleasePlanEditor, history: [Revision], probe: Probe
        var body: some View {
            ScrollViewReader { scroll in
                ScrollView {
                    QuickReleaseView(account: account, app: account.apps[0], session: session, changed: { probe.changed += 1 }, providedModel: owner, providedHistory: history)
                        .padding(20)
                }.environment(\.pageScroll, { id, anchor in scroll.scrollTo(id, anchor: anchor) })
            }.environment(controller).environment(\.openSection, { probe.section = $0 }).modifier(StorebenchAppearance())
        }
    }
    @MainActor private final class Window {
        let window: NSWindow, host: NSHostingView<AnyView>
        init<V: View>(_ view: V, width: CGFloat) {
            _ = NSApplication.shared
            window = NSWindow(contentRect: .init(x: 0, y: 0, width: width, height: 1000), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; host = NSHostingView(rootView: AnyView(view)); window.contentView = host; window.makeKeyAndOrderFront(nil)
        }
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        func marker(_ id: String) -> StorebenchControlMarker? {
            ([host] + window.sheets.compactMap(\.contentView)).flatMap(views).compactMap { $0 as? StorebenchControlMarker }
                .first { $0.identifier?.rawValue == id && !$0.isHiddenOrHasHiddenAncestor }
        }
        /// Visible text on the page and its sheets, for a failure message that says what the page showed.
        func shownText(containing words: [String]) -> String {
            ([host] + window.sheets.compactMap(\.contentView)).flatMap(views).compactMap { ($0 as? NSTextField)?.stringValue }
                .filter { text in words.contains { text.localizedCaseInsensitiveContains($0) } }.prefix(12).joined(separator: " | ")
        }
        func hasText(_ text: String) -> Bool {
            ([host] + window.sheets.compactMap(\.contentView)).flatMap(views).contains {
                (($0 as? NSTextField)?.stringValue ?? ($0 as? NSTextView)?.string ?? "").contains(text)
            }
        }
        func wait(detail: String = "Release state did not settle", _ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(20)
            while !condition() {
                guard ContinuousClock.now < deadline else { throw Failure.timeout(detail) }
                host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try await Task.sleep(for: .milliseconds(30))
            }
        }
        func press(_ id: String) async throws {
            try await wait(detail: "Control is unavailable: " + id) { marker(id)?.available == true }
            let marker = try #require(marker(id)), target = marker.window ?? window
            target.makeKeyAndOrderFront(nil)
            let deadline = ContinuousClock.now + .seconds(8)
            var previous: CGRect?, stable = 0
            while ContinuousClock.now < deadline {
                var ancestor = marker.superview
                while let view = ancestor {
                    if let scroll = view as? NSScrollView, let document = scroll.documentView {
                        document.layoutSubtreeIfNeeded()
                        let rect = marker.convert(marker.bounds, to: document), clip = scroll.contentView
                        // A card taller than the page keeps its top pinned over the page's top edge, so a control there is not clickable.
                        var visible = clip.bounds.insetBy(dx: 0, dy: 20)
                        if clip.isFlipped { visible.origin.y += StorebenchStickyHeaders.height; visible.size.height -= StorebenchStickyHeaders.height }
                        if !visible.contains(rect) {
                            let y = min(max(document.bounds.minY, rect.midY - clip.bounds.height / 2), max(document.bounds.minY, document.bounds.maxY - clip.bounds.height))
                            clip.scroll(to: CGPoint(x: clip.bounds.minX, y: y)); scroll.reflectScrolledClipView(clip)
                        }
                    }
                    ancestor = view.superview
                }
                target.contentView?.layoutSubtreeIfNeeded(); target.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
                let frame = marker.convert(marker.bounds, to: nil)
                if let previous, abs(previous.minX - frame.minX) < 0.5, abs(previous.minY - frame.minY) < 0.5,
                   abs(previous.width - frame.width) < 0.5, abs(previous.height - frame.height) < 0.5 { stable += 1 } else { stable = 0 }
                previous = frame
                if stable >= 3 { break }
            }
            guard stable >= 3 else { throw Failure.timeout("Control layout did not settle: " + id) }
            let point = marker.convert(CGPoint(x: marker.bounds.midX, y: marker.bounds.midY), to: nil)
            if let root = target.contentView, let button = views(root).compactMap({ $0 as? NSControl }).first(where: { $0.cell is NSButtonCell && !$0.isHiddenOrHasHiddenAncestor && $0.convert($0.bounds, to: nil).contains(point) }) {
                try await wait(detail: "Native control is disabled: " + id) { button.isEnabled }
                button.performClick(nil)
            } else {
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    target.sendEvent(try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: target.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)))
                }
            }
            try await Task.sleep(for: .milliseconds(80))
        }
        func text(_ id: String) throws -> NSTextView {
            let marker = try #require(marker(id)), frame = marker.convert(marker.bounds, to: host)
            return try #require(views(host).compactMap { $0 as? NSTextView }.first { $0.isEditable && !$0.isHiddenOrHasHiddenAncestor && frame.intersects($0.convert($0.bounds, to: host)) })
        }
        func edit(_ id: String, value: String) throws {
            let field = try text(id); field.scrollToVisible(field.bounds); window.makeFirstResponder(field)
            field.selectAll(nil); field.insertText(value, replacementRange: field.selectedRange())
        }
        func layoutRect(_ id: String) throws -> CGRect {
            let marker = try #require(marker(id)), document = try #require(marker.enclosingScrollView?.documentView)
            return marker.convert(marker.bounds, to: document)
        }
        func capture(_ name: String) throws {
            let root = window.sheets.first?.contentView ?? host
            let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: TestIsolation.require().appendingPathComponent(name + ".png"))
        }
        func close() {
            for sheet in window.sheets { window.endSheet(sheet); sheet.orderOut(nil); sheet.close() }
            window.contentView = nil; window.orderOut(nil); window.close()
        }
    }

    @Test(arguments: [CGFloat(760), CGFloat(1100)])
    func aVersionUpdateKeepsEditsAndNeedsSeparateApprovalForTextBuildAndSubmission(_ width: CGFloat) async throws {
        let run = try TestIsolation.require(), root = run.appendingPathComponent("synthetic-quick-journey-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("state-v2"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.copyItem(at: run.appendingPathComponent("native-fixtures/storebench-v2.sqlite"), to: EncryptedDocumentStore.databaseURL(root: root))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: EncryptedDocumentStore.databaseURL(root: root).path)
        let key = Data(0..<32).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let envelope = JSONText.object([("schemaVersion", .number(1)), ("phase", .string("ready")), ("envelope", .object([("version", .number(1)), ("mode", .string("device")), ("key", .string(key))]))])
        let entries = JSONText.object([(CredentialVault.databaseEntry(root: root), .string(envelope.stringify())), ("apple:synthetic-account", .string(P256.Signing.PrivateKey().pemRepresentation))])
        let vault = MemoryVaultStorage(JSONText.object([("version", .number(1)), ("entries", entries)]).data)
        let controller = WorkspaceController(workspace: Workspace(root: root), writer: VaultWriter(dataRoot: root, storage: vault), keychainStorage: vault, protectedStorage: vault, releaseWarmDelay: nil)
        await controller.start()
        let session = try #require(controller.session), account = try #require(try await session.accounts().first)
        let appId = "1000000001", revisionId = "00000000-0000-4000-8000-000000000002", host = "quick-journey-" + UUID().uuidString.lowercased() + ".synthetic.test"
        let apple = QuickReleaseApple(); QuickReleaseStubProtocol.register(host, apple: apple)
        try await session.configureAppleReadTestRoute(origin: URL(string: "https://" + host)!) { let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [QuickReleaseStubProtocol.self]; return config }
        try await seedScreenshot(session, key: "\(account.id):\(appId):\(revisionId)")
        let history = try await session.revisions(accountId: account.id, appId: appId)
        var text = try LanguageEditorState(await session.languageTextDrafts(accountId: account.id, appId: appId, revisionId: revisionId,
            selections: [.init(id: "version-locale-1", scope: .version), .init(id: "info-locale-1", scope: .appInfo)]))
        for (key, value) in [("supportUrl", "https://example.test/support"), ("privacyPolicyUrl", "https://example.test/privacy")] {
            try text.change(try #require(text.fields.first { $0.key == key }), to: value)
        }
        _ = try await session.saveLanguageDraft(accountId: account.id, appId: appId, revisionId: revisionId, entries: text.entries())
        for area: AppleProblem.Area in [.privacy, .tax] { try await session.recordSectionCheck(area, answered: true, detail: "Synthetic checked setting", accountId: account.id, appId: appId) }
        let owner = ReleasePlanEditor(account: account, appId: appId, initial: .init(start: .copy, sourceRevisionId: revisionId, baseVersionId: "version-1", targetVersion: "2.0", date: Date()), session: session)
        let probe = Probe(), ui = Window(Harness(account: account, session: session, controller: controller, owner: owner, history: history, probe: probe), width: width)
        do {
            try await ui.press("version-plan.save")
            // Step 1 has one Sync to Apple, on the version card; the Create Version panel below shows its status and review.
            try await ui.wait(detail: "The saved plan did not show its Create Version status") { ui.marker("publish.current-status") != nil }
            #expect(ui.marker("publish.prepare") == nil, "Step 1 has no second Sync to Apple")
            #expect(ui.window.sheets.isEmpty && apple.writes.isEmpty)
            try await ui.press("version-plan.sync")
            try await ui.wait(detail: "Creation approval did not open") { ui.marker("publish.sync.approve") != nil }
            #expect(apple.writes.isEmpty)
            try await ui.press("publish.sync.approve")
            try await completed(.release, session: session, account: account)
            try await ui.wait(detail: "The version was not created, or its review stayed open: \(apple.writes.count) writes, \(ui.window.sheets.count) sheets") { apple.writes.count == 1 && ui.window.sheets.isEmpty }
            #expect(apple.writes[0].1 == "/v1/appStoreVersions")
            try await ui.press("quick.step.text")
            let field = "quick.field.en-US.whatsNew", notes = "Synthetic improvements for this update."
            try await ui.wait(detail: "What's New did not appear in the text step") { ui.marker(field) != nil }
            try ui.edit(field, value: notes)
            try await ui.press("quick.next")
            try await ui.press("quick.back")
            #expect(try ui.text(field).string == notes)
            let saveFrame = try ui.layoutRect("quick.text.save")
            try await ui.press("quick.text.save")
            try await ui.wait(detail: "The local text save did not finish") { ui.hasText("Saved on this Mac. Sync to Apple prepares a review for your approval.") }
            #expect(abs(try ui.layoutRect("quick.text.save").minY - saveFrame.minY) < 1)
            #expect(apple.writes.count == 1 && apple.notes != notes)
            try await ui.press("quick.text.sync")
            try await ui.wait(detail: "Text approval did not open") { ui.marker("publish.sync.approve") != nil }
            #expect(apple.writes.count == 1)
            try await ui.press("publish.sync.cancel")
            try await ui.wait(detail: "The cancelled review stayed open") { ui.window.sheets.isEmpty }
            #expect(apple.writes.count == 1)
            #expect(try ui.text(field).string == notes)
            // Add for Review names the text Apple doesn't have yet, and its Sync to Apple opens that text review right there:
            // the step stays open, so Add for Review is next without going back through step 2.
            try await ui.press("quick.step.submit")
            let needed = "quick.needed.sync.apple-text:en-US"
            try await ui.wait(detail: "Add for Review did not offer Sync to Apple for the text: " + ui.shownText(containing: ["needed", "waiting"])) { ui.marker(needed) != nil }
            try await ui.press(needed)
            try await ui.wait(detail: "Sync to Apple in Add for Review did not open the text review") { ui.marker("publish.sync.approve") != nil }
            #expect(ui.marker("quick.current.submit") != nil && ui.marker("quick.current.text") == nil, "Sync to Apple in Add for Review left its step")
            try await ui.press("publish.sync.cancel")
            try await ui.wait(detail: "The cancelled review stayed open") { ui.window.sheets.isEmpty }
            #expect(apple.writes.count == 1)
            try await ui.press(needed)
            try await ui.press("publish.sync.approve")
            try await completed(.metadata, session: session, account: account)
            try await ui.wait(detail: "What's New was not sent, or its review stayed open: \(ui.window.sheets.count) sheets") { apple.notes == notes && ui.window.sheets.isEmpty }
            #expect(ui.marker("quick.current.submit") != nil, "The approved text sync left Add for Review")
            try await ui.press("quick.step.build")
            try await ui.press("draft.sync.release-build")
            try await ui.wait(detail: "The build review did not open") { ui.marker("publish.sync.approve") != nil }
            #expect(!apple.writes.contains { $0.1 == "/v1/appStoreVersions/version-2" })
            try await ui.press("publish.sync.approve")
            try await completed(.versionBuild, session: session, account: account)
            try await ui.wait(detail: "The build was not added, or its review stayed open: \(ui.window.sheets.count) sheets") { apple.writes.contains { $0.1 == "/v1/appStoreVersions/version-2" } && ui.window.sheets.isEmpty }
            try await ui.press("quick.next")
            try await ui.press("publish.prepare")
            let shown = { "The Add for Review approval did not open; prepare available: \(ui.marker("publish.prepare")?.available == true), sheets: \(ui.window.sheets.count); "
                + ui.shownText(containing: ["review", "needed", "missing", "could not", "add for", "prepar", "wait", "check"]) }
            do { try await ui.wait { ui.marker("publish.sync.approve") != nil } } catch { throw Failure.timeout(shown()) }
            #expect(!apple.writes.contains { $0.1 == "/v1/reviewSubmissions" })
            try await ui.press("publish.sync.approve")
            try await completed(.submit, session: session, account: account)
            try await ui.wait(detail: "The version was not added for review: \(apple.state), \(ui.window.sheets.count) sheets") { apple.state == "WAITING_FOR_REVIEW" && ui.window.sheets.isEmpty }
            #expect(probe.section == .quickRelease)
            #expect(apple.writes.count == 6)
            #expect(!apple.writes.contains { $0.1.contains("Screenshot") || $0.1.contains("appAssetLibrary") || $0.0 == "DELETE" })
            let reviews = try await session.publishHistory(accountId: account.id, appId: appId)
            #expect(reviews.filter { $0.state == "complete" }.count == 4)
            let completed = try #require(reviews.first { $0.state == "complete" })
            let client = try await session.client(for: account)
            await #expect(throws: PublishFailure.used) { try await session.approvePublishing(account: account, appId: appId, id: completed.id, fingerprint: completed.fingerprint, client: client) }
            // A newer build for the version in review: Replace the Build removes it from review after its own approval, and Add Build
            // opens again once App Store Connect shows the version as editable.
            let replaceShown = { "Replace the Build was not offered for the version in review; prepare: \(String(describing: ui.marker("publish.prepare")?.available)); "
                + ui.shownText(containing: ["replace", "remove", "review", "submitted", "waiting", "step", "next version", "prepar", "up to date"]) }
            do { try await ui.wait { ui.hasText("To send a newer build of") && ui.marker("publish.prepare")?.available == true } } catch { throw Failure.timeout(replaceShown()) }
            try await ui.press("publish.prepare")
            try await ui.wait(detail: "The Remove from Review approval did not open") { ui.marker("publish.sync.approve") != nil }
            #expect(!apple.writes.contains { ($0.2?["data"] as? [String: Any]).flatMap { ($0["attributes"] as? [String: Any])?["canceled"] as? Bool } == true })
            try await ui.press("publish.sync.approve")
            try await self.completed(.cancelSubmission, session: session, account: account)
            let buildShown = { "Add Build did not open after removing the version from review: \(apple.state); "
                + ui.shownText(containing: ["replace", "remove", "review", "submitted", "rejected", "build", "step"]) }
            do { try await ui.wait { ui.marker("quick.current.build") != nil } } catch { throw Failure.timeout(buildShown()) }
        } catch {
            let reviews = (try? await session.publishHistory(accountId: account.id, appId: appId)) ?? []
            print("Synthetic journey reviews: " + reviews.map { $0.request.scope.rawValue + ":" + $0.state }.joined(separator: ", "))
            try? ui.capture("quick-journey-failure-\(Int(width))"); ui.close(); owner.retire(); await controller.prepareToTerminate(); QuickReleaseStubProtocol.remove(host); try? FileManager.default.removeItem(at: root); throw error
        }
        ui.close(); owner.retire(); await controller.prepareToTerminate(); QuickReleaseStubProtocol.remove(host); try FileManager.default.removeItem(at: root)
    }
}
