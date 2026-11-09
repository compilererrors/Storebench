import Foundation

extension WorkspaceSession {
    private func chatGPTTokens(_ profile: ChatGPTProfile) throws -> ChatGPTTokens {
        try FileMutex.withLock(aiMutex(.chatgpt)) {
            guard try chatGPTProfile(profile.id).credentialID == profile.credentialID else { throw AIFailure.changed }
            guard let id = profile.credentialID, let secret = try credentialCapture("ai:" + id, allowMissing: true) else { throw AIFailure.signIn }
            let tokens = try ChatGPTTokens.read(secret)
            guard tokens.clientID == profile.clientID, tokens.subject == profile.subject else { throw AIFailure.identity }
            guard tokens.scopes.contains("chatgpt.tokens.use.direct") else { throw AIFailure.subscriptionPermission }
            return tokens
        }
    }
    func chatGPTAccess(_ connection: AIConnection) async throws -> String {
        if let failure = chatGPTBlocks[connection.credentialId] { throw failure }
        guard try aiConnection(.chatgpt) == connection, let profile = try chatGPTProfiles().first(where: { $0.credentialID == connection.credentialId }) else { throw AIFailure.changed }
        let bearer = try await chatGPTBearer(profile)
        guard try aiConnection(.chatgpt) == connection else { throw AIFailure.changed }; return bearer
    }
    private func chatGPTBearer(_ profile: ChatGPTProfile) async throws -> String {
        let tokens = try chatGPTTokens(profile)
        if tokens.expires.timeIntervalSinceNow > 60 { return tokens.access }
        if let task = chatGPTRenewals[profile.id] { return try await task.value }
        let lease = try lifetime.admit(.ai)
        let task = Task { [self] in
            defer { lease.finish(); chatGPTRenewals[profile.id] = nil }
            return try await SessionContext.$lease.withValue(lease) { try await refreshChatGPT(profile) }
        }
        chatGPTRenewals[profile.id] = task; return try await task.value
    }
    private func refreshChatGPT(_ requested: ChatGPTProfile) async throws -> String {
        let release = try chatGPTLease(requested.id); defer { release() }
        let writer = try chatGPTWriter()
        let (profile, capture, previous, secret) = try FileMutex.withLock(aiMutex(.chatgpt)) {
            let profile = try chatGPTProfile(requested.id)
            guard profile.credentialID == requested.credentialID, let id = profile.credentialID else { throw AIFailure.changed }
            let capture = try writer.capture("ai:" + id, root: root, cached: nil)
            guard let secret = capture.snapshot.vault.entries["ai:" + id] else { throw AIFailure.signIn }
            let tokens = try ChatGPTTokens.read(secret)
            guard tokens.clientID == profile.clientID, tokens.subject == profile.subject else { throw AIFailure.identity }
            return (profile, capture, tokens, secret)
        }
        if previous.expires.timeIntervalSinceNow > 60 { return previous.access }
        guard let refresh = previous.refresh else { throw AIFailure.signIn }
        let response: JSONText
        do { response = try await chatGPTHTTP().token(["grant_type": "refresh_token", "client_id": previous.clientID, "refresh_token": refresh, "resource": "https://api.openai.com/v1"], refresh: true) }
        catch let failure as ChatGPTRefreshFailure {
            if failure.terminal {
                try FileMutex.withLock(aiMutex(.chatgpt)) { try clearChatGPTTokens(profile, capture: capture, writer: writer) }
                throw AIFailure.signIn
            }
            throw AIFailure.subscriptionUnavailable
        }
        let updated = try ChatGPTTokens.response(response, client: previous.clientID, subject: previous.subject, identity: previous.identity, previous: previous)
        try Task.checkCancellation()
        return try FileMutex.withLock(aiMutex(.chatgpt)) {
            guard try chatGPTProfile(profile.id).credentialID == profile.credentialID, let id = profile.credentialID else { throw AIFailure.changed }
            let key = "ai:" + id
            let saved = try writer.writeCredential(key, root: root, value: updated.encoded, expected: secret, expectedVersion: capture.credentialVersion)
            acceptCredential(saved, key: key, writer: writer)
            if !updated.scopes.contains("chatgpt.tokens.use.direct") {
                var next = try chatGPTProfile(profile.id); next.planEnabled = false; next.revision += 1
                try storeAccess { store in try store.transaction { _ in
                    var writes: [EncryptedDocumentStore.Write] = [.put(namespace: "chatgpt_profiles", key: next.id, json: try JSONEncoder().encode(next))]
                    if try aiConnection(.chatgpt)?.credentialId == id { writes.append(.delete(namespace: "ai_connections", key: "chatgpt")) }
                    return writes
                } }
                throw AIFailure.subscriptionPermission
            }
            return updated.access
        }
    }
    public func chatGPTModels(_ profile: ChatGPTProfile) async throws -> [AIClient.Model] {
        guard try chatGPTProfile(profile.id) == profile else { throw DraftFailure.stale }
        let bearer = try await chatGPTBearer(profile)
        let values = try await AIClient(provider: .chatgpt, key: bearer, configuration: aiTestConfiguration?() ?? .ephemeral).models()
        guard try chatGPTProfile(profile.id).credentialID == profile.credentialID else { throw AIFailure.changed }; return values
    }
    /// Called with the account operation lock and connection mutex held. A rollback restores only the exact removed secret.
    private func clearChatGPTTokens(_ profile: ChatGPTProfile, capture: VaultWriter.Capture, writer: VaultWriter) throws {
        guard try chatGPTProfile(profile.id) == profile, let id = profile.credentialID else { throw DraftFailure.stale }
        let key = "ai:" + id, secret = capture.snapshot.vault.entries[key]
        var removed: VaultWriter.Capture?
        do {
            var next = profile; next.credentialID = nil; next.planEnabled = false; next.revision += 1
            try storeAccess { store in try store.transaction { current in
                guard try current("chatgpt_profiles", profile.id)?.revision == profile.revision else { throw DraftFailure.stale }
                removed = try writer.removeCredential(key, root: root, expected: secret, expectedVersion: capture.credentialVersion)
                var writes: [EncryptedDocumentStore.Write] = [.put(namespace: "chatgpt_profiles", key: profile.id, json: try JSONEncoder().encode(next))]
                if try aiConnection(.chatgpt)?.credentialId == id { writes.append(.delete(namespace: "ai_connections", key: "chatgpt")) }
                return writes
            } }
            if let removed { acceptCredential(removed, key: key, writer: writer) }
        } catch {
            if let removed, let secret, let restored = try? writer.writeCredential(key, root: root, value: secret, expected: nil, expectedVersion: removed.credentialVersion) { acceptCredential(restored, key: key, writer: writer) }
            throw error
        }
    }
    public func signOutChatGPT(_ profile: ChatGPTProfile) async throws -> Bool {
        if let existing = chatGPTSignOutTasks[profile.id] { return try await existing.value }
        let lease = try lifetime.admit(.ai)
        let task = Task { [self] in
            defer { lease.finish(); chatGPTSignOutTasks[profile.id] = nil }
            return try await SessionContext.$lease.withValue(lease) { try await performChatGPTSignOut(profile) }
        }
        chatGPTSignOutTasks[profile.id] = task
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
    private func performChatGPTSignOut(_ profile: ChatGPTProfile) async throws -> Bool {
        let writer = try chatGPTWriter()
        chatGPTAttempts = chatGPTAttempts.filter { $0.value.profile.id != profile.id }
        if let renewal = chatGPTRenewals[profile.id] { renewal.cancel(); _ = try? await renewal.value }
        let release = try chatGPTLease(profile.id); defer { release() }
        do {
            let capture = try FileMutex.withLock(aiMutex(.chatgpt)) {
                guard try chatGPTProfile(profile.id) == profile, let id = profile.credentialID else { throw DraftFailure.stale }
                let capture = try writer.capture("ai:" + id, root: root, cached: nil)
                if try aiConnection(.chatgpt)?.credentialId == id {
                    try storeAccess { store in try store.transaction { _ in [.delete(namespace: "ai_connections", key: "chatgpt")] } }
                }
                for (jobId, task) in aiTasks {
                    if let saved = try storeAccess({ try $0.document(namespace: "ai_jobs", key: jobId) }),
                       let job = try? JSONDecoder().decode(AIJob.self, from: saved.payload), job.connection.credentialId == id { task.cancel() }
                }
                return capture
            }
            let secret = profile.credentialID.flatMap { capture.snapshot.vault.entries["ai:" + $0] }
            let tokens = secret.flatMap { try? ChatGPTTokens.read($0) }
            let revoked: Bool
            if let tokens { revoked = await chatGPTHTTP().revoke(tokens) } else { revoked = true }
            try FileMutex.withLock(aiMutex(.chatgpt)) { try clearChatGPTTokens(profile, capture: capture, writer: writer) }
            return revoked
        }
    }
}
