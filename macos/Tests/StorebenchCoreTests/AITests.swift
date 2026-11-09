import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct AITests {
    init() throws { _ = try TestIsolation.require() }
    private let account = "synthetic-account", app = "1000000001", revision = "00000000-0000-4000-8000-000000000002"
    private func reply(_ translations: [String]) -> Data {
        JSONText.object([("status", .string("completed")), ("output", .array([.object([("type", .string("message")), ("content", .array([.object([("type", .string("output_text")), ("text", .string(JSONText.object([("translations", .array(translations.map(JSONText.string)))]).stringify()))])]))])]))]).data
    }
    func connected(_ provider: AIProvider = .openai) async throws -> (WorkspaceSession, URL, VaultWriter, AIConnection) {
        let (session, root) = try DraftTests().session()
        let storage = SyntheticCredentialStorage(try JSONEncoder().encode(JSONText.null))
        let vault = await session.vault
        let data = JSONText.object([("version", .number(1)), ("entries", .object(vault.entries.sorted { $0.key < $1.key }.map { ($0.key, .string($0.value)) }))]).data
        try storage.save(data)
        let writer = VaultWriter(dataRoot: root, storage: storage)
        let connection = try await session.saveAIConnection(provider: provider, model: "synthetic-model", apiKey: "synthetic-ai-key", expected: 0, writer: writer)
        try await session.configureSyntheticAI()
        return (session, root, writer, connection)
    }
    @Test func apiConnectionsKeepSecretsOutOfDocumentsAndRefuseStaleEdits() async throws {
        let (session, root, writer, connection) = try await connected(); defer { try? FileManager.default.removeItem(at: root) }
        #expect(try await session.aiConnections() == [connection])
        #expect(try writer.read().entries["ai:" + connection.credentialId] == "synthetic-ai-key")
        await #expect(throws: DraftFailure.stale) { try await session.saveAIConnection(provider: .openai, model: "other-model", apiKey: "", expected: 0, writer: writer) }
        let changed = try await session.saveAIConnection(provider: .openai, model: "other-model", apiKey: "", expected: connection.revision, writer: writer)
        #expect(changed.credentialId == connection.credentialId)
        try await session.disconnectAI(changed, writer: writer)
        #expect(try await session.aiConnections().isEmpty)
        #expect(try writer.read().entries["ai:" + connection.credentialId] == nil)
    }
    @Test func completedJobsAreReusedAndNoAppleWriteIsPrepared() async throws {
        let (session, root, _, _) = try await connected(); defer { try? FileManager.default.removeItem(at: root) }
        let response = reply(["Syntetisk översättning"])
        StubProtocol.handle("api.openai.com") { request in
            #expect(request.url?.path == "/v1/responses" && request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-ai-key")
            #expect(!(request.url?.absoluteString.contains("synthetic-ai-key") ?? true))
            #expect(!String(decoding: StubProtocol.body(request), as: UTF8.self).contains("synthetic-ai-key"))
            return (200, [:], response)
        }
        async let first = session.translateWithAI(accountId: account, appId: app, provider: .openai, texts: ["Synthetic source"], source: "en-US", target: "sv")
        async let second = session.translateWithAI(accountId: account, appId: app, provider: .openai, texts: ["Synthetic source"], source: "en-US", target: "sv")
        #expect(try await first == ["Syntetisk översättning"])
        #expect(try await second == ["Syntetisk översättning"])
        _ = try await session.translateWithAI(accountId: account, appId: app, provider: .openai, texts: ["Synthetic source"], source: "en-US", target: "sv")
        #expect(StubProtocol.requests("api.openai.com").count == 1)
        #expect(try await session.aiJobs(accountId: account, appId: app).first?.state == .complete)
        #expect(try await session.publishHistory(accountId: account, appId: app).isEmpty)
    }
    @Test func malformedResultsAndQuotaFailuresStayRetryableWithoutChangingDrafts() async throws {
        let (session, root, _, _) = try await connected(); defer { try? FileManager.default.removeItem(at: root) }
        let bad = reply([])
        StubProtocol.handle("api.openai.com") { _ in (200, [:], bad) }
        await #expect(throws: AIFailure.response) { try await session.translateWithAI(accountId: account, appId: app, provider: .openai, texts: ["Synthetic source"], source: "en-US", target: "sv") }
        #expect(try await session.aiJobs(accountId: account, appId: app).first?.state == .failed)
        StubProtocol.handle("api.openai.com") { _ in (429, [:], Data()) }
        await #expect(throws: AIFailure.quota) { try await session.translateWithAI(accountId: account, appId: app, provider: .openai, texts: ["Synthetic source"], source: "en-US", target: "sv") }
        let good = reply(["Syntetisk text"])
        StubProtocol.handle("api.openai.com") { _ in (200, [:], good) }
        #expect(try await session.translateWithAI(accountId: account, appId: app, provider: .openai, texts: ["Synthetic source"], source: "en-US", target: "sv") == ["Syntetisk text"])
    }
    private func waitForResponse(_ gate: AnalyticsJobDelayStubProtocol.Gate) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while gate.pending == 0 {
            guard ContinuousClock.now < deadline else { throw AIFailure.unavailable }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    @Test func aConnectionChangedDuringGenerationCannotCommitItsAnswer() async throws {
        let (session, root, writer, connection) = try await connected(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = AnalyticsJobDelayStubProtocol.Gate(); defer { gate.release() }
        AnalyticsJobDelayStubProtocol.register("api.openai.com", gate: gate, bytes: reply(["Synthetic translated text"]))
        try await session.configureSyntheticAI(gated: true)
        let task = Task { try await session.translateWithAI(accountId: account, appId: app, provider: .openai, texts: ["Synthetic source"], source: "en-US", target: "sv") }
        try await waitForResponse(gate)
        _ = try await session.saveAIConnection(provider: .openai, model: "new-synthetic-model", apiKey: "", expected: connection.revision, writer: writer)
        gate.release()
        await #expect(throws: AIFailure.changed) { try await task.value }
        let job = try #require(try await session.aiJobs(accountId: account, appId: app).first)
        #expect(job.state == .failed && job.result == nil)
    }
    @Test func pausingAnOwnedJobKeepsItRetryable() async throws {
        let (session, root, _, _) = try await connected(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = AnalyticsJobDelayStubProtocol.Gate(); defer { gate.release() }
        AnalyticsJobDelayStubProtocol.register("api.openai.com", gate: gate, bytes: reply(["Synthetic translated text"]))
        try await session.configureSyntheticAI(gated: true)
        let task = Task { try await session.translateWithAI(accountId: account, appId: app, provider: .openai, texts: ["Synthetic source"], source: "en-US", target: "sv") }
        try await waitForResponse(gate)
        let id = try #require(try await session.aiJobs(accountId: account, appId: app).first?.id)
        await session.pauseAIJob(id)
        do { _ = try await task.value; Issue.record("A paused job must not complete") } catch {}
        #expect(try await session.aiJobs(accountId: account, appId: app).first?.state == .paused)
        gate.release()
        #expect(try await session.translateWithAI(accountId: account, appId: app, provider: .openai, texts: ["Synthetic source"], source: "en-US", target: "sv") == ["Synthetic translated text"])
    }
    @Test func oversizedTranslatedFieldsAreNotCachedAsSuccess() async throws {
        let (session, root, _, _) = try await connected(); defer { try? FileManager.default.removeItem(at: root) }
        let oversized = reply([String(repeating: "x", count: 31)])
        StubProtocol.handle("api.openai.com") { _ in (200, [:], oversized) }
        await #expect(throws: AIFailure.response) { try await session.translateWithAI(accountId: account, appId: app, provider: .openai, texts: ["Synthetic subtitle"], source: "en-US", target: "sv", fields: ["subtitle"]) }
        #expect(try await session.aiJobs(accountId: account, appId: app).first?.result == nil)
    }
    private actor ConcurrencyProbe {
        var active = 0, peak = 0
        func work() async throws -> JSONText {
            active += 1; peak = max(peak, active); defer { active -= 1 }
            try await Task.sleep(for: .milliseconds(20)); return .string("synthetic result")
        }
    }
    @Test func backgroundConcurrencyIsBounded() async throws {
        let queue = AIWorkQueue(), probe = ConcurrencyProbe()
        try await withThrowingTaskGroup(of: JSONText.self) { group in
            for _ in 0..<6 { group.addTask { try await queue.run { try await probe.work() } } }
            var completed = 0
            for try await _ in group { completed += 1 }
            #expect(completed == 6)
        }
        #expect(await probe.peak == 2)
    }
    @Test func translationsPreserveExistingTextAndRejectAChangedSource() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let source = try await session.translationRequest(accountId: account, appId: app, revisionId: revision, versionId: "version-1", sourceLocale: "en-US")
        let targetId = try await session.addLanguage(accountId: account, appId: app, revisionId: revision, versionId: "version-1", locale: "sv", copyFrom: nil)
        let current = try await session.textDraft(accountId: account, appId: app, revisionId: revision, localizationId: targetId, scope: .version)
        var fields = current.fields; fields["description"] = "Existing synthetic description"
        _ = try await session.saveTextDraft(accountId: account, appId: app, revisionId: revision, localizationId: targetId, scope: .version, fields: fields, fingerprint: current.fingerprint)
        let target = try await session.aiTranslationTarget(accountId: account, appId: app, revisionId: revision, versionId: "version-1", locale: "sv")
        let selected = source.indicesToTranslate(target: target, replacing: false)
        #expect(!selected.contains { source.translationFields[$0] == "description" })
        #expect(source.indicesToTranslate(target: target, replacing: true).count == source.segments.count)
        #expect(source.indicesToTranslate(target: nil, replacing: false).count == source.segments.count)
        let translated = try source.translation(source.segments.map { "Translated " + $0 })
        try await session.applyAITranslation(accountId: account, appId: app, revisionId: revision, versionId: "version-1", source: source, translation: translated, target: target, replace: false)
        #expect(try await session.textDraft(accountId: account, appId: app, revisionId: revision, localizationId: targetId, scope: .version).fields["description"] == "Existing synthetic description")
        let fresh = try await session.aiTranslationTarget(accountId: account, appId: app, revisionId: revision, versionId: "version-1", locale: "sv")
        let original = try await session.textDraft(accountId: account, appId: app, revisionId: revision, localizationId: "version-locale-1", scope: .version)
        var changed = original.fields; changed["description"] = "Changed synthetic source"
        _ = try await session.saveTextDraft(accountId: account, appId: app, revisionId: revision, localizationId: "version-locale-1", scope: .version, fields: changed, fingerprint: original.fingerprint)
        await #expect(throws: LanguageFailure.sourceChanged) { try await session.applyAITranslation(accountId: account, appId: app, revisionId: revision, versionId: "version-1", source: source, translation: translated, target: fresh, replace: true) }
    }
}

extension WorkspaceSession {
    func configureSyntheticAI(gated: Bool = false) throws {
        _ = try TestIsolation.require()
        aiTestConfiguration = { let value = URLSessionConfiguration.ephemeral; value.protocolClasses = gated ? [AnalyticsJobDelayStubProtocol.self] : [StubProtocol.self]; return value }
    }
}

extension AITests {
    private func client(_ provider: AIProvider) throws -> AIClient {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubProtocol.self]
        return try AIClient(provider: provider, key: "synthetic-provider-key", configuration: configuration)
    }
    @Test(arguments: [AIProvider.openai, .anthropic, .gemini]) func transportsUseTheirOwnAuthenticationAndValidateCompletion(_ provider: AIProvider) async throws {
        let content = JSONText.object([("translations", .array([.string("Synthetic translated text")]))]).stringify()
        let response: JSONText
        switch provider {
        case .openai: response = .object([("status", .string("completed")), ("output", .array([.object([("content", .array([.object([("type", .string("output_text")), ("text", .string(content))])]))])]))])
        case .anthropic: response = .object([("stop_reason", .string("end_turn")), ("content", .array([.object([("type", .string("text")), ("text", .string(content))])]))])
        case .gemini: response = .object([("candidates", .array([.object([("finishReason", .string("STOP")), ("content", .object([("parts", .array([.object([("text", .string(content))])]))]))])]))])
        case .apple, .chatgpt: throw AIFailure.configuration
        }
        let host = try #require(URL(string: provider.origin)?.host)
        StubProtocol.handle(host) { request in
            #expect(request.httpMethod == "POST")
            #expect(!(request.url?.absoluteString.contains("synthetic-provider-key") ?? true))
            let body = StubProtocol.body(request)
            #expect(!String(decoding: body, as: UTF8.self).contains("synthetic-provider-key"))
            let json = try? JSONText.parse(body)
            switch provider {
            case .openai:
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-provider-key"); #expect(json?["store"] == .bool(false))
                #expect(String(decoding: body, as: UTF8.self).contains("data:image/jpeg;base64,AQID"))
            case .anthropic:
                #expect(request.value(forHTTPHeaderField: "x-api-key") == "synthetic-provider-key"); #expect(json?["messages"] != nil)
                #expect(String(decoding: body, as: UTF8.self).contains("\"media_type\":\"image/jpeg\""))
            case .gemini:
                #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "synthetic-provider-key"); #expect(json?["generationConfig"]?["responseJsonSchema"] != nil)
                #expect(String(decoding: body, as: UTF8.self).contains("\"inlineData\""))
            case .apple, .chatgpt: Issue.record("Unexpected local provider")
            }
            return (200, [:], response.data)
        }
        let translation = try AIRequest.translation(["Synthetic source"], source: "en-US", target: "sv")
        let input = AIRequest(purpose: translation.purpose, instructions: translation.instructions, input: translation.input, schema: translation.schema, images: [AIImage(data: Data([1, 2, 3]))])
        let result = try await client(provider).generate(input, model: "synthetic-model")
        #expect(try AIRequest.translations(result, count: 1) == ["Synthetic translated text"])
        StubProtocol.handle(host) { _ in (200, [:], JSONText.object([("status", .string("incomplete")), ("stop_reason", .string("max_tokens")), ("candidates", .array([]))]).data) }
        await #expect(throws: AIFailure.response) { try await client(provider).generate(AIRequest.translation(["Synthetic source"], source: "en-US", target: "sv"), model: "synthetic-model") }
    }
    @Test func modelPaginationTreatsTheCursorAsAQueryValue() async throws {
        let cursor = "synthetic+/=&?cursor"
        StubProtocol.handle("generativelanguage.googleapis.com") { request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(items.allSatisfy { ["pageSize", "pageToken"].contains($0.name) })
            let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
            let page = query["pageToken"]
            if page == nil {
                return (200, [:], JSONText.object([("models", .array([])), ("nextPageToken", .string(cursor))]).data)
            }
            guard page == cursor else {
                Issue.record("Synthetic pagination cursor was changed: \(request.url!.absoluteString)")
                return (400, [:], Data())
            }
            let model = JSONText.object([("name", .string("models/synthetic-vision-model")), ("supportedGenerationMethods", .array([.string("generateContent")]))])
            return (200, [:], JSONText.object([("models", .array([model]))]).data)
        }
        #expect(try await client(.gemini).models().map(\.id) == ["synthetic-vision-model"])
        #expect(StubProtocol.requests("generativelanguage.googleapis.com").count == 2)
    }
    @Test func generatedCardsKeepTheirOriginalsAndRejectDuplicateOrUnknownScreenshotIndices() throws {
        let image = AIImage(data: Data([1]))
        let request = try AICards.request(brief: "Synthetic app features", language: "en-US", target: MediaCards.defaultTarget, images: [image, image])
        #expect(request.purpose == "cards")
        func card(_ index: Int) -> JSONText { .object([("screenshotIndex", .number(Double(index))), ("title", .string("Synthetic benefit")), ("subtitle", .string("Short synthetic detail")), ("layout", .string("textAbove")), ("color", .string("#15243f")), ("secondColor", .string("#315fb3")), ("titleColor", .string("#ffffff"))]) }
        let shots = [MediaCard.Screenshot(hash: String(repeating: "a", count: 64), name: "synthetic-a.png", width: 2880, height: 1800),
                     MediaCard.Screenshot(hash: String(repeating: "b", count: 64), name: "synthetic-b.png", width: 2880, height: 1800)]
        let response = JSONText.object([("cards", .array([card(1), card(0)]))])
        let set = try AICards.cardSet(response, screenshots: shots, name: "Synthetic generated cards", language: "en-US", target: MediaCards.defaultTarget)
        #expect(set.cards.map(\.screenshot) == [shots[1], shots[0]])
        #expect(set.cards.allSatisfy { $0.style.cornerRadius > 0 && !$0.title.isEmpty })
        #expect(try AICards.cardSet(response, screenshots: shots, name: set.name, language: "en-US", target: MediaCards.defaultTarget).id == set.id)
        #expect(throws: AIFailure.response) { try AICards.cardSet(.object([("cards", .array([card(0), card(0)]))]), screenshots: shots, name: set.name, language: "en-US", target: MediaCards.defaultTarget) }
        #expect(throws: AIFailure.response) { try AICards.cardSet(.object([("cards", .array([card(0), card(9)]))]), screenshots: shots, name: set.name, language: "en-US", target: MediaCards.defaultTarget) }
    }
}
