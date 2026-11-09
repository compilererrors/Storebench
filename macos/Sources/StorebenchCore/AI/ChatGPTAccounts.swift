import Foundation

extension WorkspaceSession {
    public func chatGPTProfiles() throws -> [ChatGPTProfile] {
        try requireOwnWorkspace()
        return try storeAccess { store in
            try store.documents(namespace: "chatgpt_profiles").map { document in
                var value = try JSONDecoder().decode(ChatGPTProfile.self, from: document.payload); value.revision = document.revision; return value
            }.sorted { $0.label < $1.label }
        }
    }
    func chatGPTProfile(_ id: String) throws -> ChatGPTProfile {
        guard let value = try chatGPTProfiles().first(where: { $0.id == id }) else { throw AIFailure.changed }; return value
    }
    func chatGPTWriter(_ supplied: VaultWriter? = nil) throws -> VaultWriter {
        try requireOwnWorkspace()
        guard !isSample, let writer = supplied ?? credentialWriter,
              LocalPaths.lexical(writer.directory) == LocalPaths.lexical(root.appendingPathComponent("credential-state")) else { throw AIFailure.configuration }
        return writer
    }
    func chatGPTHTTP() -> ChatGPTHTTP { ChatGPTHTTP(configuration: aiTestConfiguration?() ?? .ephemeral) }
    func chatGPTLease(_ id: String) throws -> () -> Void {
        guard let release = try JobLock.acquire(directory: storeAccess { $0.directory }, name: "chatgpt_" + JSONText.string(id).sha256, id: UUID().uuidString.lowercased()) else { throw AIFailure.subscriptionUnavailable }
        return release
    }
    @discardableResult func saveChatGPTProfile(_ profile: ChatGPTProfile, expected: Int) throws -> ChatGPTProfile {
        var next = profile; next.revision = expected + 1
        try storeAccess { store in try store.transaction { current in
            guard (try current("chatgpt_profiles", profile.id)?.revision ?? 0) == expected else { throw DraftFailure.stale }
            return [.put(namespace: "chatgpt_profiles", key: profile.id, json: try JSONEncoder().encode(next))]
        } }; return next
    }
    public func beginChatGPTSignIn(redirect: URL, state: String, profile: ChatGPTProfile?, writer: VaultWriter) throws -> ChatGPTSignIn {
        _ = try chatGPTWriter(writer)
        guard ChatGPTOAuth.validRedirect(redirect), state.utf8.count >= 32, state.utf8.count <= 128 else { throw AIFailure.identity }
        return try FileMutex.withLock(aiMutex(.chatgpt)) {
            let selected: ChatGPTProfile
            if let profile {
                guard try chatGPTProfile(profile.id) == profile else { throw DraftFailure.stale }; selected = profile
            } else {
                let id = UUID().uuidString.lowercased()
                selected = try saveChatGPTProfile(.init(id: id, label: "ChatGPT Account " + id.prefix(6), clientID: nil, subject: nil, credentialID: nil, model: "", planEnabled: false, revision: 0), expected: 0)
            }
            let hostKey = "ai:chatgpt-host", capture = try writer.capture(hostKey, root: root, cached: nil)
            let host: String
            if let saved = capture.snapshot.vault.entries[hostKey] {
                guard saved.hasPrefix("urn:uuid:"), UUID(uuidString: String(saved.dropFirst(9))) != nil else { throw AIFailure.identity }; host = saved
            } else {
                host = "urn:uuid:" + UUID().uuidString.lowercased()
                let installed = try writer.writeCredential(hostKey, root: root, value: host, expected: nil, adding: true)
                acceptCredential(installed, key: hostKey, writer: writer)
            }
            let hint = try selected.credentialID.flatMap { id in try writer.capture("ai:" + id, root: root, cached: nil).snapshot.vault.entries["ai:" + id] }.flatMap { try? ChatGPTTokens.read($0).identity }
            let nonce = try ChatGPTOAuth.random(), verifier = try ChatGPTOAuth.random(), id = UUID().uuidString.lowercased()
            let authorization = try ChatGPTOAuth.authorize(profile: selected, host: host, redirect: redirect, state: state, nonce: nonce, verifier: verifier, hint: hint)
            let attempt = ChatGPTSignIn(id: id, authorizationURL: authorization, profile: selected, connection: try aiConnection(.chatgpt), redirect: redirect, state: state, nonce: nonce, verifier: verifier, created: .now)
            chatGPTAttempts = chatGPTAttempts.filter { $0.value.created.duration(to: .now) < .seconds(180) }
            guard chatGPTAttempts.count < 8 else { throw AIFailure.unavailable }
            chatGPTAttempts[id] = attempt; return attempt
        }
    }
    public func cancelChatGPTSignIn(_ id: String) { chatGPTAttempts[id] = nil; chatGPTSignInTasks[id]?.cancel() }
    public func finishChatGPTSignIn(_ attempt: ChatGPTSignIn, callback: URL, writer: VaultWriter) async throws -> ChatGPTSignInResult {
        _ = try chatGPTWriter(writer)
        guard let pending = chatGPTAttempts.removeValue(forKey: attempt.id), pending.state == attempt.state,
              pending.created.duration(to: .now) < .seconds(180) else { throw AIFailure.identity }
        let result = try ChatGPTOAuth.callback(callback, attempt: pending)
        let lease = try lifetime.admit(.ai)
        let task = Task { [self] in
            defer { lease.finish(); chatGPTSignInTasks[pending.id] = nil }
            return try await SessionContext.$lease.withValue(lease) { try await completeChatGPTSignIn(pending, code: result.code, client: result.client, writer: writer) }
        }
        chatGPTSignInTasks[pending.id] = task
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
    private func completeChatGPTSignIn(_ attempt: ChatGPTSignIn, code: String, client: String, writer: VaultWriter) async throws -> ChatGPTSignInResult {
        let release = try chatGPTLease(attempt.profile.id); defer { release() }
        var profile = try FileMutex.withLock(aiMutex(.chatgpt)) {
            guard try chatGPTProfile(attempt.profile.id) == attempt.profile else { throw DraftFailure.stale }
            var value = attempt.profile; value.clientID = client
            return try saveChatGPTProfile(value, expected: value.revision)
        }
        let http = chatGPTHTTP()
        let response = try await http.token(["grant_type": "authorization_code", "client_id": client, "code": code, "code_verifier": attempt.verifier, "redirect_uri": attempt.redirect.absoluteString, "resource": "https://api.openai.com/v1"])
        guard let identity = response["id_token"]?.text else { throw AIFailure.identity }
        let jwks = try await http.read(URL(string: "https://auth.openai.com/.well-known/jwks.json")!)
        let subject = try ChatGPTOAuth.verifyIdentity(identity, jwks: jwks, client: client, nonce: attempt.nonce)
        guard profile.subject == nil || profile.subject == subject else { throw AIFailure.identity }
        let claims = identity.split(separator: ".").dropFirst().first.flatMap { ChatGPTOAuth.decode(String($0)) }.flatMap { try? JSONText.parse($0) }
        let accountName = claims?["email"]?.text ?? claims?["name"]?.text
        let tokens = try ChatGPTTokens.response(response, client: client, subject: subject, identity: identity)
        let enabled = tokens.scopes.contains("chatgpt.tokens.use.direct")
        let models = enabled ? ((try? await AIClient(provider: .chatgpt, key: tokens.access, configuration: aiTestConfiguration?() ?? .ephemeral).models()) ?? []) : []
        try Task.checkCancellation()
        return try FileMutex.withLock(aiMutex(.chatgpt)) {
            guard try chatGPTProfile(profile.id) == profile else { throw DraftFailure.stale }
            if let name = accountName, !TextSemantics.trim(name).isEmpty, name.utf16.count <= 160, TextSemantics.validControlText(name) { profile.label = name + " · " + profile.id.prefix(4) }
            let oldID = profile.credentialID, id = UUID().uuidString.lowercased(), key = "ai:" + id
            let installed = try writer.writeCredential(key, root: root, value: tokens.encoded, expected: nil, adding: true)
            do {
                let connection = try aiConnection(.chatgpt)
                let model = models.first(where: { $0.id == profile.model })?.id ?? models.first?.id ?? ""
                profile.subject = subject; profile.credentialID = id; profile.planEnabled = enabled; profile.model = model
                let activate = enabled && !model.isEmpty && connection == attempt.connection
                profile.revision += 1
                try storeAccess { store in try store.transaction { current in
                    guard try current("chatgpt_profiles", profile.id)?.revision == profile.revision - 1 else { throw DraftFailure.stale }
                    var writes: [EncryptedDocumentStore.Write] = [.put(namespace: "chatgpt_profiles", key: profile.id, json: try JSONEncoder().encode(profile))]
                    if activate {
                        let active = AIConnection(provider: .chatgpt, model: model, credentialId: id, revision: (connection?.revision ?? 0) + 1)
                        writes.append(.put(namespace: "ai_connections", key: "chatgpt", json: try JSONEncoder().encode(active)))
                    } else if let oldID, connection?.credentialId == oldID { writes.append(.delete(namespace: "ai_connections", key: "chatgpt")) }
                    return writes
                } }
                acceptCredential(installed, key: key, writer: writer)
                if let oldID { try? removeChatGPTSecret(oldID, writer: writer) }
                chatGPTBlocks[id] = nil
                return .init(profile: profile, models: models, active: activate)
            } catch { _ = try? writer.removeCredential(key, root: root, expected: try? tokens.encoded, expectedVersion: installed.credentialVersion); throw error }
        }
    }
    func removeChatGPTSecret(_ id: String, writer: VaultWriter) throws {
        let key = "ai:" + id, capture = try writer.capture(key, root: root, cached: nil)
        let removed = try writer.removeCredential(key, root: root, expected: capture.snapshot.vault.entries[key], expectedVersion: capture.credentialVersion)
        acceptCredential(removed, key: key, writer: writer)
    }
    public func activateChatGPTProfile(_ profile: ChatGPTProfile, model: String, expectedConnection: Int, defaultPreferences: AISetupPreferences? = nil) throws -> ChatGPTProfile {
        let defaults = try defaultPreferences.map { value -> Data in
            var next = value.choice == .never ? value : value.answering(.setup); next.defaultProvider = .chatgpt
            return try AISetupPreferences.encoded(next)
        }
        let writer = try chatGPTWriter(), release = try chatGPTLease(profile.id); defer { release() }
        return try FileMutex.withLock(aiMutex(.chatgpt)) {
            func save() throws -> ChatGPTProfile {
                guard try chatGPTProfile(profile.id) == profile else { throw DraftFailure.stale }
                guard let id = profile.credentialID, profile.planEnabled, AIConnection.validModel(model), let secret = try credentialCapture("ai:" + id, writer: writer),
                      try ChatGPTTokens.read(secret).scopes.contains("chatgpt.tokens.use.direct") else { throw AIFailure.signIn }
                var next = profile; next.model = model; next.revision += 1
                try storeAccess { store in try store.transaction { current in
                    guard (try current("ai_connections", "chatgpt")?.revision ?? 0) == expectedConnection, try current("chatgpt_profiles", profile.id)?.revision == profile.revision else { throw DraftFailure.stale }
                    let connection = AIConnection(provider: .chatgpt, model: model, credentialId: id, revision: expectedConnection + 1)
                    var changes: [EncryptedDocumentStore.Write] = [.put(namespace: "ai_connections", key: "chatgpt", json: try JSONEncoder().encode(connection)), .put(namespace: "chatgpt_profiles", key: profile.id, json: try JSONEncoder().encode(next))]
                    if let defaults, let defaultPreferences {
                        guard try AISetupPreferences.stored(current("ai_preferences", "current")).revision == defaultPreferences.revision else { throw DraftFailure.stale }
                        changes.append(.put(namespace: "ai_preferences", key: "current", json: defaults))
                    }
                    return changes
                } }; return next
            }
            if defaults != nil {
                return try storeAccess { store in try FileMutex.withLock(store.directory.appendingPathComponent("ai_preferences.mutex")) { try save() } }
            }
            return try save()
        }
    }
    public func retryChatGPTPlanUsage() throws { try requireOwnWorkspace(); chatGPTBlocks = chatGPTBlocks.filter { $0.value != .subscriptionLimit } }
}
