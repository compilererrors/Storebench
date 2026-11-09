import Foundation
import Testing
@testable import StorebenchCore

private enum ModelSelectionReply {
    static func catalog(_ provider: AIProvider = .openai) -> Data {
        let model: JSONText = provider == .gemini
            ? .object([("name", .string("models/synthetic-choice")), ("displayName", .string("Synthetic Choice")), ("supportedGenerationMethods", .array([.string("generateContent")]))])
            : .object([("id", .string("synthetic-choice")), ("display_name", .string("Synthetic Choice"))])
        return JSONText.object([(provider == .gemini ? "models" : "data", .array([model]))]).data
    }
    static var translation: Data {
        let result = JSONText.object([("translations", .array([.string("Synthetic translated text")]))]).stringify()
        return JSONText.object([("status", .string("completed")), ("output", .array([.object([("content", .array([.object([("type", .string("output_text")), ("text", .string(result))])]))])]))]).data
    }
}

extension AITests {
    private func modelSelectionSession(_ provider: AIProvider = .openai) async throws -> (WorkspaceSession, URL, VaultWriter, AIConnection) {
        _ = try TestIsolation.require()
        return try await connected(provider)
    }
    private func waitForModelState(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw AIFailure.unavailable }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test(arguments: [AIProvider.openai, .anthropic, .gemini]) func savedAPIKeysReadCachedModelsWithoutInferenceOrDefaultChanges(_ provider: AIProvider) async throws {
        let (session, root, _, connection) = try await modelSelectionSession(provider); defer { try? FileManager.default.removeItem(at: root) }
        let initial = try await session.aiSetupPreferences(), host = URL(string: provider.origin)!.host!
        StubProtocol.handle(host) { request in
            #expect(request.httpMethod == "GET")
            let header = provider == .openai ? "Authorization" : provider == .anthropic ? "x-api-key" : "x-goog-api-key"
            #expect(request.value(forHTTPHeaderField: header) == (provider == .openai ? "Bearer synthetic-ai-key" : "synthetic-ai-key"))
            #expect(!request.url!.absoluteString.contains("synthetic-ai-key"))
            return (200, [:], ModelSelectionReply.catalog(provider))
        }
        #expect(try await session.availableAIModels(connection).map(\.id) == ["synthetic-choice"])
        #expect(try await session.availableAIModels(connection).map(\.id) == ["synthetic-choice"])
        #expect(StubProtocol.requests(host).count == 1)
        _ = try await session.availableAIModels(connection, refresh: true)
        #expect(StubProtocol.requests(host).count == 2)
        #expect(try await session.aiConnections() == [connection])
        #expect(try await session.aiSetupPreferences() == initial)
        #expect(try await session.aiJobs(accountId: "synthetic-account", appId: "1000000001").isEmpty)
    }

    @Test func cancellingOneModelReaderKeepsTheOtherReaderAndUsesOneRequest() async throws {
        let (session, root, _, connection) = try await modelSelectionSession(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = AnalyticsJobDelayStubProtocol.Gate(); defer { gate.release() }
        AnalyticsJobDelayStubProtocol.register("api.openai.com", gate: gate, bytes: ModelSelectionReply.catalog())
        try await session.configureSyntheticAI(gated: true)
        let first = Task { try await session.availableAIModels(connection) }
        try await waitForModelState { gate.pending == 1 }
        let second = Task { try await session.availableAIModels(connection) }
        try await waitForModelState { await session.aiModelReads[connection]?.waiters.count == 2 }
        first.cancel()
        try await waitForModelState { await session.aiModelReads[connection]?.waiters.count == 1 }
        #expect(gate.pending == 1)
        gate.release()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(try await second.value.map(\.id) == ["synthetic-choice"])
        #expect(await session.aiModelReads.isEmpty)
    }

    @Test func anEditedConnectionCannotReceiveAnOldModelCatalog() async throws {
        let (session, root, writer, connection) = try await modelSelectionSession(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = AnalyticsJobDelayStubProtocol.Gate(); defer { gate.release() }
        AnalyticsJobDelayStubProtocol.register("api.openai.com", gate: gate, bytes: ModelSelectionReply.catalog())
        try await session.configureSyntheticAI(gated: true)
        let reading = Task { try await session.availableAIModels(connection) }
        try await waitForModelState { gate.pending == 1 }
        let changed = try await session.saveAIConnection(provider: .openai, model: "synthetic-new-default", apiKey: "", expected: connection.revision, writer: writer)
        gate.release()
        await #expect(throws: AIFailure.changed) { try await reading.value }
        #expect(await session.aiModelCatalogs.isEmpty)
        await #expect(throws: AIFailure.changed) { try await session.availableAIModels(connection) }
        try await session.configureSyntheticAI()
        StubProtocol.handle("api.openai.com") { request in
            #expect(request.httpMethod == "GET"); return (200, [:], ModelSelectionReply.catalog())
        }
        #expect(try await session.availableAIModels(changed).map(\.id) == ["synthetic-choice"])
        #expect(try await session.aiConnections() == [changed])
    }

    @Test func workspaceCloseCancelsModelMetadataBeforeDrainingTheSession() async throws {
        let (session, root, _, connection) = try await modelSelectionSession(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = AnalyticsJobDelayStubProtocol.Gate(); defer { gate.release() }
        AnalyticsJobDelayStubProtocol.register("api.openai.com", gate: gate, bytes: ModelSelectionReply.catalog())
        try await session.configureSyntheticAI(gated: true)
        let reading = Task { try await session.availableAIModels(connection) }
        try await waitForModelState { gate.pending == 1 }
        try await session.signOut()
        do { _ = try await reading.value; Issue.record("Closing must cancel the metadata read") }
        catch { #expect(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        await #expect(throws: SessionFailure.closed) { try await session.availableAIModels(connection) }
        #expect(await session.aiModelReads.isEmpty)
    }

    @Test func taskModelsHaveSeparateCachesAndNeverChangeTheSavedDefault() async throws {
        let (session, root, _, connection) = try await modelSelectionSession(); defer { try? FileManager.default.removeItem(at: root) }
        let initial = try await session.aiSetupPreferences()
        StubProtocol.handle("api.openai.com") { request in
            #expect(request.httpMethod == "POST" && request.url?.path == "/v1/responses")
            let body = try? JSONText.parse(StubProtocol.body(request))
            #expect(["synthetic-one", "synthetic-two"].contains(body?["model"]?.text ?? ""))
            return (200, [:], ModelSelectionReply.translation)
        }
        for model in ["synthetic-one", "synthetic-two", "synthetic-one"] {
            let texts = try await session.translateWithAI(accountId: "synthetic-account", appId: "1000000001", provider: .openai, texts: ["Synthetic source"], source: "en-US", target: "sv", model: model)
            #expect(texts == ["Synthetic translated text"])
        }
        #expect(StubProtocol.requests("api.openai.com").count == 2)
        #expect(try await session.aiConnections() == [connection])
        #expect(try await session.aiSetupPreferences() == initial)
        #expect(Set(try await session.aiJobs(accountId: "synthetic-account", appId: "1000000001").map { $0.connection.model }) == ["synthetic-one", "synthetic-two"])
        await #expect(throws: AIFailure.configuration) {
            try await session.translateWithAI(accountId: "synthetic-account", appId: "1000000001", provider: .apple, texts: ["Synthetic source"], source: "en-US", target: "sv", model: "synthetic-one")
        }
        #expect(StubProtocol.requests("api.openai.com").count == 2)
    }
}
