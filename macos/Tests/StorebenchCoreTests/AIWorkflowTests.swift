import Foundation
import Testing
@testable import StorebenchCore

/// Exercises the production composer and listing actions with encrypted storage, real image processing
/// and provider-specific HTTP/SSE responses. Only the remote model is replaced; no quota is used.
struct AIWorkflowFixture: Sendable {
    let account = "synthetic-account", app = "1000000001", revision = "00000000-0000-4000-8000-000000000002"
    init() throws { _ = try TestIsolation.require() }
    var scope: LocalEditorDraft.Scope { .init(accountId: account, appId: app, editor: "ai-cards", resource: "composer") }
    func composer(_ session: WorkspaceSession, provider: AIProvider) async throws -> (LocalEditorDraft, [Data], [MediaCard.Screenshot]) {
        let originals = try [AssetLibraryTests().png(width: 2880, height: 1800), AssetLibraryTests().png(width: 1920, height: 1200)]
        var shots: [MediaCard.Screenshot] = []
        for (index, bytes) in originals.enumerated() {
            shots.append(try await session.stageMediaCardScreenshot(accountId: account, appId: app, bytes: bytes, name: "synthetic-screen-\(index).png"))
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let value = JSONText.object([("name", .string("Synthetic Cards")), ("brief", .string("Explain synthetic pricing and listing history with concise headlines.")),
            ("language", .string("en-US")), ("provider", .string(provider.rawValue)), ("target", .string(MediaCards.defaultTarget.id)),
            ("screenshots", try JSONText.parse(encoder.encode(shots)))])
        return (try await session.saveLocalEditorDraft(value, scope: scope, expected: 0), originals, shots)
    }
    var cards: JSONText {
        .object([("cards", .array([1, 0].map { index in
            .object([("screenshotIndex", .number(Double(index))), ("title", .string(index == 0 ? "Compare Every Market" : "See Your Listing History")),
                ("subtitle", .string("A concise synthetic benefit")), ("layout", .string("textAbove")),
                ("color", .string("#15243f")), ("secondColor", .string("#315fb3")), ("titleColor", .string("#ffffff"))])
        }))])
    }
    func response(_ result: JSONText, provider: AIProvider) -> Data {
        let text = result.stringify()
        switch provider {
        case .openai, .chatgpt:
            let value = JSONText.object([("status", .string("completed")), ("output", .array([.object([("type", .string("message")),
                ("content", .array([.object([("type", .string("output_text")), ("text", .string(text))])]))])]))])
            if provider == .chatgpt { return Data(("data: " + JSONText.object([("type", .string("response.completed")), ("response", value)]).stringify() + "\n\n").utf8) }
            return value.data
        case .anthropic: return JSONText.object([("stop_reason", .string("end_turn")), ("content", .array([.object([("type", .string("text")), ("text", .string(text))])]))]).data
        case .gemini: return JSONText.object([("candidates", .array([.object([("finishReason", .string("STOP")), ("content", .object([("parts", .array([.object([("text", .string(text))])]))]))])]))]).data
        case .apple: return Data()
        }
    }
    func imageData(_ body: JSONText, provider: AIProvider) throws -> [Data] {
        let parts: JSONText?
        switch provider {
        case .openai, .chatgpt: parts = body["input"].flatMap { if case .array(let a) = $0 { return a.first?["content"] }; return nil }
        case .anthropic: parts = body["messages"].flatMap { if case .array(let a) = $0 { return a.first?["content"] }; return nil }
        case .gemini: parts = body["contents"].flatMap { if case .array(let a) = $0 { return a.first?["parts"] }; return nil }
        case .apple: parts = nil
        }
        guard case .array(let rows)? = parts else { throw AIFailure.response }
        return try rows.compactMap { row in
            let encoded: String?
            if provider == .openai || provider == .chatgpt { encoded = row["image_url"]?.text?.components(separatedBy: ",").last }
            else if provider == .anthropic { encoded = row["source"]?["data"]?.text }
            else { encoded = row["inlineData"]?["data"]?.text }
            guard let encoded else { return nil }
            return try #require(Data(base64Encoded: encoded))
        }
    }
    func wait(_ gate: AnalyticsJobDelayStubProtocol.Gate) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while gate.pending == 0 {
            guard ContinuousClock.now < deadline else { throw AIFailure.unavailable }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    func translate(_ session: WorkspaceSession, source: LanguageTranslation.Request, locale: String, target: [LanguageDrafts.Section]?, replace: Bool = false) async throws -> [String]? {
        try await session.translatedListingSegments(accountId: account, appId: app, provider: .openai, source: source, locale: locale, target: target, replace: replace)
    }
    func apply(_ session: WorkspaceSession, source: LanguageTranslation.Request, locale: String, texts: [String], target: [LanguageDrafts.Section]?, replace: Bool = false) async throws {
        let translation = try source.translation(texts)
        if let target {
            try await session.applyAITranslation(accountId: account, appId: app, revisionId: revision, versionId: "version-1", source: source, translation: translation, target: target, replace: replace)
        } else {
            _ = try await session.addLanguage(accountId: account, appId: app, revisionId: revision, versionId: "version-1", locale: locale, copyFrom: source.sourceLocale, translation: translation)
        }
    }
    func source(_ session: WorkspaceSession) async throws -> LanguageTranslation.Request {
        try await session.translationRequest(accountId: account, appId: app, revisionId: revision, versionId: "version-1", sourceLocale: "en-US")
    }
    func target(_ session: WorkspaceSession, _ locale: String = "sv") async throws -> [LanguageDrafts.Section] {
        try await session.aiTranslationTarget(accountId: account, appId: app, revisionId: revision, versionId: "version-1", locale: locale)
    }
    func draftData(_ session: WorkspaceSession) async throws -> Data? {
        try await session.storeAccess { try $0.document(namespace: "drafts", key: account + ":" + app + ":" + revision)?.payload }
    }
}

extension AITests {
    // Also used by the signed-in ChatGPT workflow, after synthetic OAuth registration and account selection.
    func exerciseCardWorkflow(session: WorkspaceSession, root: URL, writer: VaultWriter, provider: AIProvider) async throws {
        let f = try AIWorkflowFixture()
        let (draft, originals, shots) = try await f.composer(session, provider: provider)
        #expect(try await session.mediaCardSets(accountId: f.account, appId: f.app).isEmpty)
        // Newly selected screenshots have no card set yet. The composer must read its own saved originals.
        await #expect(throws: MediaCardFailure.missing) { try await session.mediaCardScreenshot(accountId: f.account, appId: f.app, hash: shots[0].hash) }
        let response = f.response(f.cards, provider: provider), host = try #require(URL(string: provider.origin)?.host)
        StubProtocol.handle(host) { request in
            do {
                let body = try JSONText.parse(StubProtocol.body(request))
                let images = try f.imageData(body, provider: provider)
                #expect(request.httpMethod == "POST" && images.count == 2)
                for (image, original) in zip(images, originals) {
                    let info = try ScreenshotEditing.inspect(image)
                    #expect(info.width == 1400 && info.height == 875 && !info.transparent)
                    #expect(image != original && image.count <= 2_000_000)
                }
                if provider == .chatgpt { #expect(body["stream"] == .bool(true) && body["store"] == .bool(false)) }
            } catch { Issue.record("The card request must contain decodable, resized synthetic screenshots") }
            return (200, provider == .chatgpt ? ["Content-Type": "text/event-stream"] : [:], response)
        }
        let proposal = try await session.proposeAICards(accountId: f.account, appId: f.app, expected: draft.revision)
        #expect(proposal.cards.map(\.screenshot) == [shots[1], shots[0]])
        #expect(proposal.cards.map(\.title) == ["See Your Listing History", "Compare Every Market"])
        #expect(try await session.mediaCardSets(accountId: f.account, appId: f.app).isEmpty)
        let saved = try await session.saveProposedAICards(accountId: f.account, appId: f.app, set: proposal)
        #expect(saved.revision == 1 && saved.set == proposal)
        var edited = saved.set; edited.cards[0].title = "An Edited Synthetic Headline"
        #expect(try await session.saveMediaCardSet(accountId: f.account, appId: f.app, set: edited, expected: saved.revision) == 2)
        // Reopen from disk, not from the in-memory task cache. A retry must retain manual edits and use no new request.
        try await session.signOut()
        let reopened = try WorkspaceSession(workspace: Workspace(root: root), vault: writer.read())
        try await reopened.configureSyntheticAI()
        let repeated = try await reopened.proposeAICards(accountId: f.account, appId: f.app, expected: draft.revision)
        #expect(repeated.id == proposal.id)
        let retained = try await reopened.saveProposedAICards(accountId: f.account, appId: f.app, set: repeated)
        #expect(retained.revision == 2 && retained.set == edited && StubProtocol.requests(host).count == 1)
        var exports: [WorkspaceSession.CreatedLibraryImage] = []
        for (index, card) in retained.set.cards.enumerated() {
            let shot = try #require(card.screenshot)
            let bytes = try await reopened.mediaCardScreenshot(accountId: f.account, appId: f.app, hash: shot.hash)
            #expect(bytes == originals[1 - index])
            let png = try await MediaCardRenderer.exportAsync(card, width: edited.width, height: edited.height, screenshot: try ScreenshotRenderer.load(bytes))
            let info = try ScreenshotEditing.inspect(png)
            #expect(info.width == edited.width && info.height == edited.height && !info.transparent)
            exports.append(.init(sourceId: card.id, bytes: png, fileName: MediaCards.fileName(set: edited, index: index), referenceName: "Synthetic card \(index + 1)"))
        }
        let library = try await reopened.stageCreatedLibraryImages(accountId: f.account, appId: f.app, setId: edited.id, images: exports)
        #expect(library.added == 2 && library.files.allSatisfy { $0.category == .listing && !$0.hasAlpha })
        #expect(try await reopened.stageCreatedLibraryImages(accountId: f.account, appId: f.app, setId: edited.id, images: exports).added == 0)
        #expect(try await reopened.assetLibraryFiles(accountId: f.account, appId: f.app).count == library.files.count)
        #expect(try await reopened.publishHistory(accountId: f.account, appId: f.app).isEmpty)
        let jobs = try await reopened.aiJobs(accountId: f.account, appId: f.app)
        #expect(jobs.count == 1 && jobs[0].state == .complete)
        #expect(jobs.first?.request.images.allSatisfy { $0.text.isEmpty } == true)
        try await reopened.signOut()
    }

    @Test(arguments: [AIProvider.openai, .anthropic, .gemini])
    func selectedScreenshotsBecomeEditableSavedCardsAndExportedLibraryImages(_ provider: AIProvider) async throws {
        let (session, root, writer, _) = try await connected(provider); defer { try? FileManager.default.removeItem(at: root) }
        try await exerciseCardWorkflow(session: session, root: root, writer: writer, provider: provider)
    }

    @Test func aComposerChangedDuringGenerationKeepsTheResultWithoutAcceptingStaleCards() async throws {
        let (session, root, _, _) = try await connected(); defer { try? FileManager.default.removeItem(at: root) }
        let f = try AIWorkflowFixture(), (draft, _, _) = try await f.composer(session, provider: .openai)
        let gate = AnalyticsJobDelayStubProtocol.Gate(); defer { gate.release() }
        AnalyticsJobDelayStubProtocol.register("api.openai.com", gate: gate, bytes: f.response(f.cards, provider: .openai))
        try await session.configureSyntheticAI(gated: true)
        let pending = Task { try await session.proposeAICards(accountId: f.account, appId: f.app, expected: draft.revision) }
        try await f.wait(gate)
        let changed = try await session.saveLocalEditorDraft(draft.value.setting("brief", .string("A newer synthetic brief")), scope: f.scope, expected: draft.revision)
        gate.release()
        await #expect(throws: AIFailure.changed) { try await pending.value }
        #expect(try await session.localEditorDraft(f.scope) == changed)
        #expect(try await session.mediaCardSets(accountId: f.account, appId: f.app).isEmpty)
        #expect(try await session.aiJobs(accountId: f.account, appId: f.app).first?.state == .complete)
        #expect(try await session.publishHistory(accountId: f.account, appId: f.app).isEmpty)
    }

    @Test func cardQuotaAndMalformedResultsDoNotRetryOrCreatePartialCards() async throws {
        let (session, root, writer, _) = try await connected(); defer { try? FileManager.default.removeItem(at: root) }
        let f = try AIWorkflowFixture(), (draft, _, _) = try await f.composer(session, provider: .openai)
        _ = try await session.saveAIConnection(provider: .anthropic, model: "synthetic-model", apiKey: "synthetic-fallback-key", expected: 0, writer: writer)
        StubProtocol.handle("api.anthropic.com") { _ in Issue.record("A quota failure must never switch providers"); return (501, [:], Data()) }
        StubProtocol.handle("api.openai.com") { _ in (429, [:], Data()) }
        await #expect(throws: AIFailure.quota) { try await session.proposeAICards(accountId: f.account, appId: f.app, expected: draft.revision) }
        #expect(StubProtocol.requests("api.openai.com").count == 1 && StubProtocol.requests("api.anthropic.com").isEmpty)
        guard case .array(let cards)? = f.cards["cards"] else { throw AIFailure.response }
        let duplicate = f.cards.setting("cards", .array([cards[0], cards[0]]))
        let malformed = f.response(duplicate, provider: .openai)
        StubProtocol.handle("api.openai.com") { _ in (200, [:], malformed) }
        await #expect(throws: AIFailure.response) { try await session.proposeAICards(accountId: f.account, appId: f.app, expected: draft.revision) }
        #expect(StubProtocol.requests("api.openai.com").count == 1)
        #expect(try await session.aiJobs(accountId: f.account, appId: f.app).first?.result == nil)
        #expect(try await session.mediaCardSets(accountId: f.account, appId: f.app).isEmpty)
        #expect(try await session.localEditorDraft(f.scope) == draft)
        let good = f.response(f.cards, provider: .openai)
        StubProtocol.handle("api.openai.com") { _ in (200, [:], good) }
        let retried = try await session.proposeAICards(accountId: f.account, appId: f.app, expected: draft.revision)
        #expect(retried.cards.count == 2 && StubProtocol.requests("api.openai.com").count == 1)
    }

    @Test func selectedLanguagesSaveIndependentlyAndRetryOnlyMissingTranslations() async throws {
        let (session, root, writer, _) = try await connected(); defer { try? FileManager.default.removeItem(at: root) }
        let f = try AIWorkflowFixture(), source = try await f.source(session)
        let swedish = try await session.addLanguage(accountId: f.account, appId: f.app, revisionId: f.revision, versionId: "version-1", locale: "sv", copyFrom: nil)
        let loaded = try await session.textDraft(accountId: f.account, appId: f.app, revisionId: f.revision, localizationId: swedish, scope: .version)
        var fields = loaded.fields; fields["description"] = "Existing synthetic wording"
        _ = try await session.saveTextDraft(accountId: f.account, appId: f.app, revisionId: f.revision, localizationId: swedish, scope: .version, fields: fields, fingerprint: loaded.fingerprint)
        let baseline = try await f.target(session)
        StubProtocol.handle("api.openai.com") { request in
            do {
                let body = try JSONText.parse(StubProtocol.body(request))
                if body["instructions"]?.text?.contains("to de-DE.") == true { return (429, [:], Data()) }
                guard case .array(let input)? = body["input"], case .array(let parts)? = input.first?["content"], let text = parts.first?["text"]?.text,
                      case .array(let texts) = try JSONText.parse(Data(text.utf8)) else { throw AIFailure.response }
                #expect(!texts.contains(.string(source.version["description"]!)))
                let result = JSONText.object([("translations", .array(texts.indices.map { .string("sv-\($0)") }))])
                return (200, [:], f.response(result, provider: .openai))
            } catch { Issue.record("The listing request must contain only the selected source fields"); return (501, [:], Data()) }
        }
        await withTaskGroup(of: (String, [String]?, AIFailure?).self) { group in
            for locale in ["sv", "de-DE"] {
                group.addTask {
                    do { return (locale, try await f.translate(session, source: source, locale: locale, target: locale == "sv" ? baseline : nil), nil) }
                    catch { return (locale, nil, error as? AIFailure ?? .unavailable) }
                }
            }
            for await (locale, texts, error) in group {
                if locale == "de-DE" { #expect(error == .quota && texts == nil) }
                else {
                    #expect(error == nil)
                    if let texts {
                        do { try await f.apply(session, source: source, locale: locale, texts: texts, target: baseline) }
                        catch { Issue.record("A completed language must save its local draft") }
                    } else { Issue.record("The selected empty fields must be translated") }
                }
            }
        }
        #expect(StubProtocol.requests("api.openai.com").count == 2)
        let first = try await f.target(session), version = try #require(first.first { $0.selection.scope == .version })
        #expect(version.draft.fields["description"] == "Existing synthetic wording")
        #expect(version.draft.fields["keywords"] == "sv-0,sv-1")
        #expect(try await f.source(session) == source)
        let imported = try #require(try await session.revisions(accountId: f.account, appId: f.app).first { $0.id == f.revision })
        #expect(try await session.workspaceRevision(imported, accountId: f.account, appId: f.app).versions.first?.localizations.contains { $0.locale == "de-DE" } == false)
        // Reopening retains the successful language and the failed job. Only the failed language should cost a new request.
        try await session.signOut()
        let reopened = try WorkspaceSession(workspace: Workspace(root: root), vault: writer.read()); try await reopened.configureSyntheticAI()
        StubProtocol.handle("api.openai.com") { request in
            do {
                let body = try JSONText.parse(StubProtocol.body(request))
                #expect(body["instructions"]?.text?.contains("to de-DE.") == true)
                let result = JSONText.object([("translations", .array(source.segments.indices.map { .string("de-\($0)") }))])
                return (200, [:], f.response(result, provider: .openai))
            } catch { return (501, [:], Data()) }
        }
        #expect(try await f.translate(reopened, source: source, locale: "sv", target: f.target(reopened)) == nil)
        let translated = try #require(try await f.translate(reopened, source: source, locale: "de-DE", target: nil))
        try await f.apply(reopened, source: source, locale: "de-DE", texts: translated, target: nil)
        let german = try await f.target(reopened, "de-DE")
        #expect(german.first { $0.selection.scope == .version }?.draft.fields["description"] == "de-0")
        let sourceSections = try await f.target(reopened, "en-US")
        #expect(german.first { $0.selection.scope == .appInfo }?.draft.fields["name"] == sourceSections.first { $0.selection.scope == .appInfo }?.draft.fields["name"])
        #expect(StubProtocol.requests("api.openai.com").count == 1)
        #expect(try await f.translate(reopened, source: source, locale: "de-DE", target: german) == nil)
        #expect(StubProtocol.requests("api.openai.com").count == 1)
        #expect(try await reopened.publishHistory(accountId: f.account, appId: f.app).isEmpty)
        #expect(try await reopened.aiJobs(accountId: f.account, appId: f.app).count == 2)
        try await reopened.signOut()
    }

    @Test(arguments: [false, true]) func aListingEditedDuringTranslationRejectsTheOldResult(changeSource: Bool) async throws {
        let (session, root, _, _) = try await connected(); defer { try? FileManager.default.removeItem(at: root) }
        let f = try AIWorkflowFixture(), source = try await f.source(session)
        let swedish = try await session.addLanguage(accountId: f.account, appId: f.app, revisionId: f.revision, versionId: "version-1", locale: "sv", copyFrom: nil)
        let baseline = try await f.target(session)
        let gate = AnalyticsJobDelayStubProtocol.Gate(); defer { gate.release() }
        let result = JSONText.object([("translations", .array(source.segments.indices.map { .string("sv-\($0)") }))])
        AnalyticsJobDelayStubProtocol.register("api.openai.com", gate: gate, bytes: f.response(result, provider: .openai))
        try await session.configureSyntheticAI(gated: true)
        let pending = Task { try await f.translate(session, source: source, locale: "sv", target: baseline, replace: true) }
        try await f.wait(gate)
        let id = changeSource ? "version-locale-1" : swedish
        let current = try await session.textDraft(accountId: f.account, appId: f.app, revisionId: f.revision, localizationId: id, scope: .version)
        var fields = current.fields; fields["description"] = "A newer synthetic edit"
        _ = try await session.saveTextDraft(accountId: f.account, appId: f.app, revisionId: f.revision, localizationId: id, scope: .version, fields: fields, fingerprint: current.fingerprint)
        let before = try await f.draftData(session)
        gate.release()
        let translated = try #require(try await pending.value)
        if changeSource {
            await #expect(throws: LanguageFailure.sourceChanged) { try await f.apply(session, source: source, locale: "sv", texts: translated, target: baseline, replace: true) }
        } else {
            await #expect(throws: DraftFailure.stale) { try await f.apply(session, source: source, locale: "sv", texts: translated, target: baseline, replace: true) }
        }
        #expect(try await f.draftData(session) == before)
        #expect(try await session.publishHistory(accountId: f.account, appId: f.app).isEmpty)
    }

    @Test func isolatedRunsCannotInvokeAppleIntelligenceOrUnstubbedCloudServices() async throws {
        let (session, root, _, _) = try await connected(); defer { try? FileManager.default.removeItem(at: root) }
        let f = try AIWorkflowFixture(), (draft, _, _) = try await f.composer(session, provider: .apple)
        #expect(Network.testMode && !AppleLocalAI.available)
        await #expect(throws: AIFailure.localUnavailable) { try await session.proposeAICards(accountId: f.account, appId: f.app, expected: draft.revision) }
        let request = try AIRequest.translation(["Synthetic source"], source: "en-US", target: "sv")
        await #expect(throws: AIFailure.localUnavailable) { try await AppleLocalAI.generate(request) }
        // Omitting the test transport must fail closed, even with a plausible provider origin and credential.
        let client = try AIClient(provider: .openai, key: "synthetic-never-sent-key")
        await #expect(throws: (any Error).self) { try await client.generate(request, model: "synthetic-model") }
        #expect(try await session.aiJobs(accountId: f.account, appId: f.app).isEmpty)
        #expect(try await session.mediaCardSets(accountId: f.account, appId: f.app).isEmpty)
        #expect(try await session.publishHistory(accountId: f.account, appId: f.app).isEmpty)
    }

    @Test func invalidOrStaleCardDraftsCannotSpendQuota() async throws {
        let (session, root, _, _) = try await connected(); defer { try? FileManager.default.removeItem(at: root) }
        let f = try AIWorkflowFixture(), (draft, _, _) = try await f.composer(session, provider: .openai)
        StubProtocol.handle("api.openai.com") { _ in Issue.record("Invalid inputs must fail before a provider request"); return (501, [:], Data()) }
        await #expect(throws: AIFailure.changed) { try await session.proposeAICards(accountId: f.account, appId: f.app, expected: 0) }
        var current = draft
        for value in [draft.value.setting("name", .string("")), draft.value.setting("name", .string("Synthetic\nName")),
                      draft.value.setting("brief", .string(String(repeating: "x", count: 2001))), draft.value.setting("screenshots", .array([]))] {
            current = try await session.saveLocalEditorDraft(value, scope: f.scope, expected: current.revision)
            await #expect(throws: AIFailure.configuration) { try await session.proposeAICards(accountId: f.account, appId: f.app, expected: current.revision) }
        }
        #expect(StubProtocol.requests("api.openai.com").isEmpty)
        #expect(try await session.aiJobs(accountId: f.account, appId: f.app).isEmpty)
    }

    @Test func replacingExistingWordingRequiresTheExplicitReplaceChoice() async throws {
        let (session, root, _, _) = try await connected(); defer { try? FileManager.default.removeItem(at: root) }
        let f = try AIWorkflowFixture(), source = try await f.source(session)
        _ = try await session.addLanguage(accountId: f.account, appId: f.app, revisionId: f.revision, versionId: "version-1", locale: "sv", copyFrom: "en-US")
        let baseline = try await f.target(session), before = try await f.draftData(session)
        StubProtocol.handle("api.openai.com") { _ in Issue.record("Filled fields must not be translated without Replace"); return (501, [:], Data()) }
        #expect(try await f.translate(session, source: source, locale: "sv", target: baseline) == nil)
        #expect(StubProtocol.requests("api.openai.com").isEmpty)
        #expect(try await f.draftData(session) == before)
        let result = JSONText.object([("translations", .array(source.segments.indices.map { .string("sv-\($0)") }))])
        let response = f.response(result, provider: .openai)
        StubProtocol.handle("api.openai.com") { _ in (200, [:], response) }
        let texts = try #require(try await f.translate(session, source: source, locale: "sv", target: baseline, replace: true))
        try await f.apply(session, source: source, locale: "sv", texts: texts, target: baseline, replace: true)
        let after = try await f.target(session)
        #expect(after.first { $0.selection.scope == .version }?.draft.fields["description"] == "sv-0")
        for section in baseline {
            let saved = try #require(after.first { $0.selection.id == section.selection.id })
            for key in ["name", "supportUrl", "marketingUrl", "privacyPolicyUrl"] where section.draft.fields[key] != nil {
                #expect(saved.draft.fields[key] == section.draft.fields[key])
            }
        }
        #expect(try await f.source(session) == source && StubProtocol.requests("api.openai.com").count == 1)
        #expect(try await session.publishHistory(accountId: f.account, appId: f.app).isEmpty)
    }
}
