import CryptoKit
import Foundation
import Security
import Testing
@testable import StorebenchCore

extension AITests {
    private struct ChatGPTFixture {
        let session: WorkspaceSession, root: URL, writer: VaultWriter
        let key = P256.Signing.PrivateKey()
        var jwks: JSONText {
            let bytes = Array(key.publicKey.x963Representation)
            let row = JSONText.object([("kid", .string("synthetic-key")), ("alg", .string("ES256")), ("kty", .string("EC")), ("crv", .string("P-256")),
                ("x", .string(AppleToken.base64url(Data(bytes[1..<33])))), ("y", .string(AppleToken.base64url(Data(bytes[33..<65]))))])
            return .object([("keys", .array([row]))])
        }
        func identity(_ attempt: ChatGPTSignIn, subject: String = "synthetic-subject", client: String = "oaiapp_synthetic", nonce: String? = nil, expiry: Double? = nil) throws -> String {
            let header = JSONText.object([("alg", .string("ES256")), ("kid", .string("synthetic-key"))])
            let payload = JSONText.object([("iss", .string("https://auth.openai.com")), ("sub", .string(subject)), ("name", .string("Synthetic Account")), ("aud", .string(client)), ("nonce", .string(nonce ?? attempt.nonce)),
                ("iat", .number(Date().timeIntervalSince1970 - 1)), ("exp", .number(expiry ?? Date().timeIntervalSince1970 + 3600))])
            let input = AppleToken.base64url(header.data) + "." + AppleToken.base64url(payload.data)
            return input + "." + AppleToken.base64url(try key.signature(for: Data(input.utf8)).rawRepresentation)
        }
        func callback(_ attempt: ChatGPTSignIn, client: String = "oaiapp_synthetic", state: String? = nil) -> URL {
            var url = URLComponents(url: attempt.redirect, resolvingAgainstBaseURL: false)!
            url.queryItems = [.init(name: "code", value: "synthetic-code"), .init(name: "client_id", value: client), .init(name: "state", value: state ?? attempt.state)]
            return url.url!
        }
        func attempt(_ profile: ChatGPTProfile? = nil) async throws -> ChatGPTSignIn {
            try await session.beginChatGPTSignIn(redirect: URL(string: "http://127.0.0.1:49152/auth/callback")!, state: ChatGPTOAuth.random(), profile: profile, writer: writer)
        }
        func authorize(_ attempt: ChatGPTSignIn, subject: String = "synthetic-subject", enabled: Bool = true, lifetime: Double = 3600, client: String = "oaiapp_synthetic") throws {
            let token = try identity(attempt, subject: subject, client: client), jwks = jwks
            StubProtocol.handle("auth.openai.com") { request in
                if request.url?.path == "/.well-known/jwks.json" { return (200, [:], jwks.data) }
                #expect(request.url?.path == "/api/accounts/oauth/token" && request.httpMethod == "POST")
                let form = URLComponents(string: "?" + String(decoding: StubProtocol.body(request), as: UTF8.self))?.queryItems ?? []
                let values = Dictionary(uniqueKeysWithValues: form.map { ($0.name, $0.value ?? "") })
                #expect(values["client_id"] == client && values["code_verifier"] == attempt.verifier)
                #expect(values["resource"] == "https://api.openai.com/v1" && values["redirect_uri"] == attempt.redirect.absoluteString)
                let response = JSONText.object([("access_token", .string("synthetic-access")), ("refresh_token", .string("synthetic-refresh")), ("token_type", .string("Bearer")),
                    ("expires_in", .number(lifetime)), ("id_token", .string(token)), ("scope", .string(enabled ? "openid offline_access resource.invoke chatgpt.tokens.use.direct" : "openid"))])
                return (200, [:], response.data)
            }
            StubProtocol.handle("api.openai.com") { request in
                #expect(request.url?.path == "/v1/models")
                let hidden = JSONText.object([("slug", .string("hidden-model")), ("visibility", .string("hidden"))])
                let visible = JSONText.object([("slug", .string("synthetic-chat-model")), ("display_name", .string("Synthetic Chat Model")), ("visibility", .string("list"))])
                return (200, [:], JSONText.object([("models", .array([hidden, visible]))]).data)
            }
        }
    }
    private func chatGPTFixture() async throws -> ChatGPTFixture {
        _ = try TestIsolation.require()
        let (session, root) = try DraftTests().session(), vault = await session.vault
        let entries = JSONText.object(vault.entries.sorted { $0.key < $1.key }.map { ($0.key, .string($0.value)) })
        let storage = SyntheticCredentialStorage(JSONText.object([("version", .number(1)), ("entries", entries)]).data)
        try await session.configureSyntheticAI()
        return .init(session: session, root: root, writer: VaultWriter(dataRoot: root, storage: storage))
    }
    private func chatGPTEvent(_ value: JSONText) -> Data { Data(("data: " + value.stringify() + "\r\n\r\n").utf8) }
    private func chatGPTCompleted(_ result: JSONText) -> Data {
        let text = JSONText.object([("type", .string("output_text")), ("text", .string(result.stringify()))])
        let message = JSONText.object([("type", .string("message")), ("role", .string("assistant")), ("content", .array([text]))])
        let response = JSONText.object([("status", .string("completed")), ("output", .array([message]))])
        return chatGPTEvent(.object([("type", .string("response.completed")), ("response", response)]))
    }
    @Test func chatGPTRegistrationBindsPKCEAndKeepsTokensOnlyInTheVault() async throws {
        let f = try await chatGPTFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let attempt = try await f.attempt()
        let query = URLComponents(url: attempt.authorizationURL, resolvingAgainstBaseURL: false)!.queryItems!
        let parameters = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
        #expect(parameters["client_id"] == "dynamic_agent_client" && parameters["agent_name_hint"] == "Storebench")
        #expect(parameters["code_challenge"] == AppleToken.base64url(Data(SHA256.hash(data: Data(attempt.verifier.utf8)))))
        try f.authorize(attempt)
        let result = try await f.session.finishChatGPTSignIn(attempt, callback: f.callback(attempt), writer: f.writer)
        #expect(result.active && result.profile.planEnabled && result.models.map(\.id) == ["synthetic-chat-model"])
        #expect(result.profile.label.hasPrefix("Synthetic Account"))
        let id = try #require(result.profile.credentialID), secret = try #require(f.writer.read().entries["ai:" + id])
        #expect(try ChatGPTTokens.read(secret).clientID == "oaiapp_synthetic")
        #expect(!String(decoding: try JSONEncoder().encode(result.profile), as: UTF8.self).contains("synthetic-access"))
        let again = try await f.attempt(result.profile), next = URLComponents(url: again.authorizationURL, resolvingAgainstBaseURL: false)!.queryItems!
        let nextParameters = Dictionary(uniqueKeysWithValues: next.map { ($0.name, $0.value ?? "") })
        #expect(nextParameters["client_id"] == "oaiapp_synthetic" && nextParameters["agent_name_hint"] == nil)
        #expect(nextParameters["ext_agent_host_id"] == parameters["ext_agent_host_id"])
        await #expect(throws: AIFailure.identity) { try await f.session.finishChatGPTSignIn(attempt, callback: f.callback(attempt), writer: f.writer) }
    }
    @Test func chatGPTRejectsWrongStateDuplicateParametersAndOtherCallbackPorts() async throws {
        let f = try await chatGPTFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        for kind in ["state", "duplicate", "port"] {
            let attempt = try await f.attempt()
            var url = URLComponents(url: f.callback(attempt), resolvingAgainstBaseURL: false)!
            if kind == "state" { url.queryItems = url.queryItems!.map { $0.name == "state" ? .init(name: "state", value: "wrong-state") : $0 } }
            if kind == "duplicate" { url.queryItems!.append(.init(name: "code", value: "another-code")) }
            if kind == "port" { url.port = 49153 }
            let callback = url.url!
            await #expect(throws: AIFailure.identity) { try await f.session.finishChatGPTSignIn(attempt, callback: callback, writer: f.writer) }
        }
        #expect(try await f.session.aiConnections().isEmpty)
    }
    @Test func chatGPTIdentityRequiresTheSignatureAudienceNonceAndExpiry() async throws {
        let f = try await chatGPTFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let attempt = try await f.attempt(), valid = try f.identity(attempt)
        #expect(try ChatGPTOAuth.verifyIdentity(valid, jwks: f.jwks, client: "oaiapp_synthetic", nonce: attempt.nonce) == "synthetic-subject")
        for token in [try f.identity(attempt, client: "oaiapp_other"), try f.identity(attempt, nonce: "wrong-nonce"), try f.identity(attempt, expiry: 1), valid + "a"] {
            #expect(throws: AIFailure.identity) { try ChatGPTOAuth.verifyIdentity(token, jwks: f.jwks, client: "oaiapp_synthetic", nonce: attempt.nonce) }
        }
    }
    @Test func chatGPTVerifiesRSASignaturesUsingOnlyEphemeralSyntheticKeys() throws {
        _ = try TestIsolation.require()
        let attributes = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048, kSecAttrIsPermanent: false] as CFDictionary
        let privateKey = try #require(SecKeyCreateRandomKey(attributes, nil)), publicKey = try #require(SecKeyCopyPublicKey(privateKey))
        let external = try #require(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data
        struct DERReader {
            var bytes: [UInt8], index = 0
            mutating func value(_ tag: UInt8) throws -> [UInt8] {
                guard index + 2 <= bytes.count, bytes[index] == tag else { throw AIFailure.identity }; index += 1
                let first = Int(bytes[index]); index += 1
                var count = first
                if first >= 128 {
                    let size = first & 127; guard (1...4).contains(size), index + size <= bytes.count else { throw AIFailure.identity }
                    count = 0; for _ in 0..<size { count = count * 256 + Int(bytes[index]); index += 1 }
                }
                guard index + count <= bytes.count else { throw AIFailure.identity }
                defer { index += count }; return Array(bytes[index..<(index + count)])
            }
        }
        var outer = DERReader(bytes: Array(external)), inner = DERReader(bytes: try outer.value(0x30))
        let modulus = Data(try inner.value(2).drop(while: { $0 == 0 })), exponent = Data(try inner.value(2).drop(while: { $0 == 0 }))
        let row = JSONText.object([("kid", .string("synthetic-rsa")), ("alg", .string("RS256")), ("kty", .string("RSA")),
            ("n", .string(AppleToken.base64url(modulus))), ("e", .string(AppleToken.base64url(exponent)))])
        let jwks = JSONText.object([("keys", .array([row]))])
        let header = JSONText.object([("kid", .string("synthetic-rsa")), ("alg", .string("RS256"))])
        let claims = JSONText.object([("iss", .string("https://auth.openai.com")), ("sub", .string("synthetic-subject")), ("aud", .string("oaiapp_synthetic")),
            ("nonce", .string("synthetic-nonce")), ("iat", .number(Date().timeIntervalSince1970 - 1)), ("exp", .number(Date().timeIntervalSince1970 + 3600))])
        let unsigned = AppleToken.base64url(header.data) + "." + AppleToken.base64url(claims.data)
        let signature = try #require(SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, Data(unsigned.utf8) as CFData, nil)) as Data
        let token = unsigned + "." + AppleToken.base64url(signature)
        #expect(try ChatGPTOAuth.verifyIdentity(token, jwks: jwks, client: "oaiapp_synthetic", nonce: "synthetic-nonce") == "synthetic-subject")
        #expect(throws: AIFailure.identity) { try ChatGPTOAuth.verifyIdentity(token + "a", jwks: jwks, client: "oaiapp_synthetic", nonce: "synthetic-nonce") }
    }
    @Test func chatGPTWithoutPlanConsentCannotBecomeAnAIConnection() async throws {
        let f = try await chatGPTFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let attempt = try await f.attempt(); try f.authorize(attempt, enabled: false)
        let result = try await f.session.finishChatGPTSignIn(attempt, callback: f.callback(attempt), writer: f.writer)
        #expect(!result.active && !result.profile.planEnabled && result.profile.credentialID != nil)
        #expect(try await f.session.aiConnections().isEmpty)
        await #expect(throws: AIFailure.signIn) { try await f.session.activateChatGPTProfile(result.profile, model: "synthetic-chat-model", expectedConnection: 0) }
    }
    @Test func chatGPTCannotReplaceAProfileWithADifferentSignedIdentity() async throws {
        let f = try await chatGPTFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let first = try await f.attempt(); try f.authorize(first)
        let saved = try await f.session.finishChatGPTSignIn(first, callback: f.callback(first), writer: f.writer)
        let before = try await f.session.aiConnections(), second = try await f.attempt(saved.profile)
        try f.authorize(second, subject: "other-synthetic-subject")
        await #expect(throws: AIFailure.identity) { try await f.session.finishChatGPTSignIn(second, callback: f.callback(second), writer: f.writer) }
        #expect(try await f.session.aiConnections() == before)
        #expect(try f.writer.read().entries["ai:" + (saved.profile.credentialID ?? "")] != nil)
    }
    @Test func chatGPTStreamsCardsAndTranslationsThroughTheExistingJobs() async throws {
        let f = try await chatGPTFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let attempt = try await f.attempt(); try f.authorize(attempt)
        _ = try await f.session.finishChatGPTSignIn(attempt, callback: f.callback(attempt), writer: f.writer)
        let translated = chatGPTCompleted(.object([("translations", .array([.string("Synthetic translated text")]))]))
        let card = JSONText.object([("screenshotIndex", .number(0)), ("title", .string("Synthetic benefit")), ("subtitle", .string("Short detail")), ("layout", .string("textAbove")),
            ("color", .string("#15243f")), ("secondColor", .string("#315fb3")), ("titleColor", .string("#ffffff"))])
        let cards = chatGPTCompleted(.object([("cards", .array([card]))]))
        StubProtocol.handle("api.openai.com") { request in
            let body = try? JSONText.parse(StubProtocol.body(request))
            #expect(body?["stream"] == .bool(true) && body?["store"] == .bool(false))
            #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
            let isCards = body?["text"]?["format"]?["schema"]?["properties"]?["cards"] != nil
            return (200, ["Content-Type": "text/event-stream"], isCards ? cards : translated)
        }
        let text = try await f.session.translateWithAI(accountId: "synthetic-account", appId: "1000000001", provider: .chatgpt, texts: ["Synthetic source"], source: "en-US", target: "sv")
        #expect(text == ["Synthetic translated text"])
        let request = try AICards.request(brief: "Synthetic app benefits", language: "en-US", target: MediaCards.defaultTarget, images: [AIImage(data: Data([1]))])
        let response = try await f.session.runAIJob(accountId: "synthetic-account", appId: "1000000001", provider: .chatgpt, request: request)
        #expect(try AICards.checked(response, count: 1).count == 1)
        #expect(try await f.session.publishHistory(accountId: "synthetic-account", appId: "1000000001").isEmpty)
    }
    @Test func chatGPTSignInGeneratesEditableCardsThatSurviveReopeningAndExport() async throws {
        let f = try await chatGPTFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let attempt = try await f.attempt(); try f.authorize(attempt)
        _ = try await f.session.finishChatGPTSignIn(attempt, callback: f.callback(attempt), writer: f.writer)
        try await exerciseCardWorkflow(session: f.session, root: f.root, writer: f.writer, provider: .chatgpt)
    }
    @Test(arguments: [false, true]) func chatGPTDefaultModelAndServiceSaveTogetherOrKeepTheNewerDefault(stale: Bool) async throws {
        let f = try await chatGPTFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let attempt = try await f.attempt(); try f.authorize(attempt)
        let signed = try await f.session.finishChatGPTSignIn(attempt, callback: f.callback(attempt), writer: f.writer)
        let before = try #require(try await f.session.aiConnections().first { $0.provider == .chatgpt })
        var selected = try await f.session.aiSetupPreferences().answering(.never)
        selected.defaultProvider = .apple
        let baseline = try await f.session.saveAISetupPreferences(selected)
        if stale {
            var changed = baseline; changed.defaultProvider = .gemini
            let newer = try await f.session.saveAISetupPreferences(changed)
            await #expect(throws: DraftFailure.stale) {
                try await f.session.activateChatGPTProfile(signed.profile, model: "synthetic-new-model", expectedConnection: before.revision, defaultPreferences: baseline)
            }
            #expect(try await f.session.aiConnections().first { $0.provider == .chatgpt } == before)
            #expect(try await f.session.chatGPTProfiles().first { $0.id == signed.profile.id } == signed.profile)
            #expect(try await f.session.aiSetupPreferences() == newer)
        } else {
            let saved = try await f.session.activateChatGPTProfile(signed.profile, model: "synthetic-new-model", expectedConnection: before.revision, defaultPreferences: baseline)
            let defaults = try await f.session.aiSetupPreferences()
            #expect(saved.model == "synthetic-new-model" && defaults.defaultProvider == .chatgpt && defaults.choice == .never)
            #expect(try await f.session.aiConnections().first { $0.provider == .chatgpt }?.model == saved.model)
        }
        #expect(StubProtocol.requests("api.openai.com").allSatisfy { $0.url?.path != "/v1/responses" })
    }
    @Test func aTaskCanChooseAnotherChatGPTModelWithoutChangingItsAccountOrDefaults() async throws {
        let f = try await chatGPTFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let attempt = try await f.attempt(); try f.authorize(attempt)
        let signed = try await f.session.finishChatGPTSignIn(attempt, callback: f.callback(attempt), writer: f.writer)
        let original = try #require(try await f.session.aiConnections().first { $0.provider == .chatgpt })
        let preferences = try await f.session.aiSetupPreferences()
        let response = chatGPTCompleted(.object([("translations", .array([.string("Synthetic translation")]))]))
        StubProtocol.handle("api.openai.com") { request in
            let body = try? JSONText.parse(StubProtocol.body(request))
            #expect(request.url?.path == "/v1/responses" && body?["model"] == .string("synthetic-plan-alternative"))
            return (200, ["Content-Type": "text/event-stream"], response)
        }
        let translated = try await f.session.translateWithAI(accountId: "synthetic-account", appId: "1000000001", provider: .chatgpt, texts: ["Synthetic source"], source: "en-US", target: "sv", model: "synthetic-plan-alternative")
        #expect(translated == ["Synthetic translation"])
        #expect(try await f.session.aiConnections().first { $0.provider == .chatgpt } == original)
        #expect(try await f.session.chatGPTProfiles().first { $0.id == signed.profile.id } == signed.profile)
        #expect(try await f.session.aiSetupPreferences() == preferences)
        #expect(try await f.session.aiJobs(accountId: "synthetic-account", appId: "1000000001").first?.connection.model == "synthetic-plan-alternative")
    }

    @Test func chatGPTLateQuotaErrorsPauseNewRequestsUntilExplicitRetry() async throws {
        let f = try await chatGPTFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let attempt = try await f.attempt(); try f.authorize(attempt)
        _ = try await f.session.finishChatGPTSignIn(attempt, callback: f.callback(attempt), writer: f.writer)
        let delta = chatGPTEvent(.object([("type", .string("response.output_text.delta")), ("delta", .string("partial output"))]))
        let failure = chatGPTEvent(.object([("type", .string("response.failed")), ("response", .object([("error", .object([("code", .string("subscription_sharing_usage_limit_exceeded"))]))]))]))
        StubProtocol.handle("api.openai.com") { _ in (200, ["Content-Type": "text/event-stream"], delta + failure) }
        for text in ["First synthetic source", "Second synthetic source"] {
            await #expect(throws: AIFailure.subscriptionLimit) { try await f.session.translateWithAI(accountId: "synthetic-account", appId: "1000000001", provider: .chatgpt, texts: [text], source: "en-US", target: "sv") }
        }
        #expect(StubProtocol.requests("api.openai.com").count == 1)
        let good = chatGPTCompleted(.object([("translations", .array([.string("Synthetic translated text")]))]))
        StubProtocol.handle("api.openai.com") { _ in (200, ["Content-Type": "text/event-stream"], good) }
        try await f.session.retryChatGPTPlanUsage()
        _ = try await f.session.translateWithAI(accountId: "synthetic-account", appId: "1000000001", provider: .chatgpt, texts: ["Second synthetic source"], source: "en-US", target: "sv")
        #expect(StubProtocol.requests("api.openai.com").count == 1)
        #expect(throws: AIFailure.response) { try ChatGPTEvents.completed(delta) }
    }
    @Test func chatGPTRefreshIsCoalescedAndUsesTheIssuedClientAndRotatingToken() async throws {
        let f = try await chatGPTFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let attempt = try await f.attempt(); try f.authorize(attempt, lifetime: 1)
        let saved = try await f.session.finishChatGPTSignIn(attempt, callback: f.callback(attempt), writer: f.writer)
        StubProtocol.handle("auth.openai.com") { request in
            let values = URLComponents(string: "?" + String(decoding: StubProtocol.body(request), as: UTF8.self))?.queryItems ?? []
            let form = Dictionary(uniqueKeysWithValues: values.map { ($0.name, $0.value ?? "") })
            #expect(form["grant_type"] == "refresh_token" && form["client_id"] == "oaiapp_synthetic" && form["refresh_token"] == "synthetic-refresh")
            return (200, [:], JSONText.object([("access_token", .string("synthetic-access-new")), ("refresh_token", .string("synthetic-refresh-new")), ("token_type", .string("Bearer")), ("expires_in", .number(3600))]).data)
        }
        let result = chatGPTCompleted(.object([("translations", .array([.string("Synthetic translated text")]))]))
        StubProtocol.handle("api.openai.com") { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-access-new")
            return (200, ["Content-Type": "text/event-stream"], result)
        }
        async let first = f.session.translateWithAI(accountId: "synthetic-account", appId: "1000000001", provider: .chatgpt, texts: ["First source"], source: "en-US", target: "sv")
        async let second = f.session.translateWithAI(accountId: "synthetic-account", appId: "1000000001", provider: .chatgpt, texts: ["Second source"], source: "en-US", target: "sv")
        _ = try await (first, second)
        #expect(StubProtocol.requests("auth.openai.com").count == 1)
        let secret = try #require(f.writer.read().entries["ai:" + (saved.profile.credentialID ?? "")])
        #expect(try ChatGPTTokens.read(secret).refresh == "synthetic-refresh-new")
    }
    @Test func chatGPTSignOutRevokesAndKeepsTheRegistrationWithoutTokens() async throws {
        let f = try await chatGPTFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let attempt = try await f.attempt(); try f.authorize(attempt)
        let saved = try await f.session.finishChatGPTSignIn(attempt, callback: f.callback(attempt), writer: f.writer)
        StubProtocol.handle("auth.openai.com") { request in
            if request.url?.path == "/.well-known/openid-configuration" {
                return (200, [:], JSONText.object([("revocation_endpoint", .string("https://auth.openai.com/api/accounts/oauth/revoke"))]).data)
            }
            #expect(request.url?.path == "/api/accounts/oauth/revoke" && request.httpMethod == "POST")
            #expect(!request.url!.absoluteString.contains("synthetic-refresh"))
            return (200, [:], Data())
        }
        #expect(try await f.session.signOutChatGPT(saved.profile))
        let profile = try #require(try await f.session.chatGPTProfiles().first)
        #expect(profile.clientID == "oaiapp_synthetic" && profile.credentialID == nil)
        #expect(try f.writer.read().entries["ai:" + (saved.profile.credentialID ?? "")] == nil)
        #expect(try await f.session.aiConnections().isEmpty)
        let next = try await f.attempt(profile)
        let parameters = URLComponents(url: next.authorizationURL, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(parameters.first(where: { $0.name == "client_id" })?.value == "oaiapp_synthetic")
        #expect(!parameters.contains { $0.name == "id_token_hint" })
    }
    @Test func chatGPTAccountSwitchesKeepRegistrationsSeparateAndRejectStaleCommands() async throws {
        let f = try await chatGPTFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let first = try await f.attempt(); try f.authorize(first)
        let old = try await f.session.finishChatGPTSignIn(first, callback: f.callback(first), writer: f.writer)
        let originalConnection = try #require(try await f.session.aiConnections().first)
        let second = try await f.attempt(); try f.authorize(second, subject: "second-synthetic-subject", client: "oaiapp_second_synthetic")
        let next = try await f.session.finishChatGPTSignIn(second, callback: f.callback(second, client: "oaiapp_second_synthetic"), writer: f.writer)
        #expect(next.active && old.profile.credentialID != next.profile.credentialID)
        #expect(try await f.session.chatGPTProfiles().count == 2)
        let activeConnection = try #require(try await f.session.aiConnections().first)
        await #expect(throws: DraftFailure.stale) { try await f.session.activateChatGPTProfile(old.profile, model: old.profile.model, expectedConnection: originalConnection.revision) }
        let chosen = try await f.session.activateChatGPTProfile(old.profile, model: old.profile.model, expectedConnection: activeConnection.revision)
        #expect(chosen.clientID == "oaiapp_synthetic")
        #expect(try await f.session.aiConnections().first?.credentialId == old.profile.credentialID)
        await #expect(throws: DraftFailure.stale) { try await f.session.signOutChatGPT(old.profile) }
        #expect(try f.writer.read().entries["ai:" + (next.profile.credentialID ?? "")] != nil)
    }
    @Test(arguments: [true, false]) func chatGPTOnlyClearsConfirmedUnusableRefreshTokens(terminal: Bool) async throws {
        let f = try await chatGPTFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let attempt = try await f.attempt(); try f.authorize(attempt, lifetime: 1)
        let saved = try await f.session.finishChatGPTSignIn(attempt, callback: f.callback(attempt), writer: f.writer)
        let response = JSONText.object([("error", .string(terminal ? "invalid_grant" : "temporarily_unavailable"))])
        StubProtocol.handle("auth.openai.com") { _ in (terminal ? 400 : 503, [:], response.data) }
        await #expect(throws: terminal ? AIFailure.signIn : AIFailure.subscriptionUnavailable) {
            try await f.session.translateWithAI(accountId: "synthetic-account", appId: "1000000001", provider: .chatgpt, texts: ["Synthetic source"], source: "en-US", target: "sv")
        }
        let key = "ai:" + (saved.profile.credentialID ?? "")
        #expect((try f.writer.read().entries[key] == nil) == terminal)
        #expect(try await f.session.aiConnections().isEmpty == terminal)
        #expect(StubProtocol.requests("api.openai.com").allSatisfy { $0.url?.path == "/v1/models" })
    }
    @Test func chatGPTReportsUnconfirmedRevocationWhileStillSigningOutLocally() async throws {
        let f = try await chatGPTFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let attempt = try await f.attempt(); try f.authorize(attempt)
        let saved = try await f.session.finishChatGPTSignIn(attempt, callback: f.callback(attempt), writer: f.writer)
        StubProtocol.handle("auth.openai.com") { _ in (503, [:], Data()) }
        #expect(try await !f.session.signOutChatGPT(saved.profile))
        #expect(try await f.session.aiConnections().isEmpty)
        #expect(try f.writer.read().entries["ai:" + (saved.profile.credentialID ?? "")] == nil)
    }
    @Test func workspaceCloseCancelsRemoteChatGPTSignOutAndFinishesLocalCleanup() async throws {
        let f = try await chatGPTFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let attempt = try await f.attempt(); try f.authorize(attempt)
        let saved = try await f.session.finishChatGPTSignIn(attempt, callback: f.callback(attempt), writer: f.writer)
        let gate = AnalyticsJobDelayStubProtocol.Gate(); defer { gate.release() }
        let metadata = JSONText.object([("revocation_endpoint", .string("https://auth.openai.com/api/accounts/oauth/revoke"))])
        AnalyticsJobDelayStubProtocol.register("auth.openai.com", gate: gate, bytes: metadata.data)
        try await f.session.configureSyntheticAI(gated: true)
        let operation = Task { try await f.session.signOutChatGPT(saved.profile) }
        let deadline = ContinuousClock.now + .seconds(15)
        while gate.pending == 0 {
            guard ContinuousClock.now < deadline else { throw AIFailure.unavailable }; try await Task.sleep(for: .milliseconds(10))
        }
        try await f.session.signOut()
        #expect(try await !operation.value)
        #expect(try f.writer.read().entries["ai:" + (saved.profile.credentialID ?? "")] == nil)
    }
}
