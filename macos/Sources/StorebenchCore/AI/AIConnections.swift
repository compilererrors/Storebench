import Foundation

extension WorkspaceSession {
    public func aiConnections() throws -> [AIConnection] {
        try storeAccess { store in
            try store.documents(namespace: "ai_connections").map { document in
                var value = try JSONDecoder().decode(AIConnection.self, from: document.payload); value.revision = document.revision; return value
            }.sorted { $0.provider.rawValue < $1.provider.rawValue }
        }
    }
    func aiConnection(_ provider: AIProvider) throws -> AIConnection? { try aiConnections().first { $0.provider == provider } }
    func aiMutex(_ provider: AIProvider) throws -> URL { try storeAccess { $0.directory.appendingPathComponent("ai_connection_\(provider.rawValue).mutex") } }
    public func saveAIConnection(provider: AIProvider, model: String, apiKey: String, expected: Int, writer: VaultWriter) throws -> AIConnection {
        try requireOwnWorkspace(); guard !isSample, provider.usesAPIKey, AIConnection.validModel(model), expected >= 0 else { throw AIFailure.configuration }
        return try FileMutex.withLock(aiMutex(provider)) {
            let previous = try aiConnection(provider)
            guard (previous?.revision ?? 0) == expected else { throw DraftFailure.stale }
            let supplied = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard previous != nil || !supplied.isEmpty else { throw AIFailure.credentials }
            let id = supplied.isEmpty ? previous!.credentialId : UUID().uuidString.lowercased(), key = "ai:" + id
            var installed: VaultWriter.Capture?
            do {
                if !supplied.isEmpty {
                    _ = try AIClient(provider: provider, key: supplied)
                    installed = try writer.writeCredential(key, root: root, value: supplied, expected: nil, adding: true)
                }
                let value = AIConnection(provider: provider, model: model, credentialId: id, revision: expected + 1)
                try storeAccess { store in
                    try store.transaction { current in
                        guard (try current("ai_connections", provider.rawValue)?.revision ?? 0) == expected else { throw DraftFailure.stale }
                        return [.put(namespace: "ai_connections", key: provider.rawValue, json: try JSONEncoder().encode(value))]
                    }
                }
                if let installed { acceptCredential(installed, key: key, writer: writer) }
                if let previous, previous.credentialId != id {
                    let old = "ai:" + previous.credentialId
                    if let capture = try? writer.capture(old, root: root, cached: nil),
                       let removed = try? writer.removeCredential(old, root: root, expected: capture.snapshot.vault.entries[old], expectedVersion: capture.credentialVersion) { acceptCredential(removed, key: old, writer: writer) }
                }
                return value
            } catch {
                if let installed { _ = try? writer.removeCredential(key, root: root, expected: supplied, expectedVersion: installed.credentialVersion) }
                throw error
            }
        }
    }
    public func disconnectAI(_ connection: AIConnection, writer: VaultWriter) throws {
        try requireOwnWorkspace()
        guard connection.provider.usesAPIKey else { throw AIFailure.configuration }
        try FileMutex.withLock(aiMutex(connection.provider)) {
            guard try aiConnection(connection.provider) == connection else { throw DraftFailure.stale }
            let key = "ai:" + connection.credentialId
            let capture = try writer.capture(key, root: root, cached: nil), secret = capture.snapshot.vault.entries[key]
            var removed: VaultWriter.Capture?
            do {
                try storeAccess { store in
                    try store.transaction { current in
                        guard try current("ai_connections", connection.id)?.revision == connection.revision else { throw DraftFailure.stale }
                        removed = try writer.removeCredential(key, root: root, expected: secret, expectedVersion: capture.credentialVersion)
                        return [.delete(namespace: "ai_connections", key: connection.id)]
                    }
                }
                if let removed { acceptCredential(removed, key: key, writer: writer) }
            } catch {
                if removed != nil, let secret, let restored = try? writer.writeCredential(key, root: root, value: secret, expected: nil) { acceptCredential(restored, key: key, writer: writer) }
                throw error
            }
        }
    }
    func aiCredential(_ connection: AIConnection) throws -> String {
        try FileMutex.withLock(aiMutex(connection.provider)) {
            guard try aiConnection(connection.provider) == connection else { throw AIFailure.changed }
            guard let key = try credentialCapture("ai:" + connection.credentialId, allowMissing: true) else { throw AIFailure.credentials }
            return key
        }
    }
}
