import Foundation

/// The open session's view of stored credentials: captures, pauses and explicit retries for this workspace.
extension WorkspaceSession {
    func credentialCapture(_ key: String, writer: VaultWriter? = nil, allowMissing: Bool = false) throws -> String? {
        try requireSessionAccess(); try requireOwnWorkspace()
        if let writer { credentialWriter = writer }
        guard !credentialFailures.contains(key) else { throw CredentialAccessFailure.paused }
        guard let writer = credentialWriter else { return vault.entries[key] }
        do {
            let result = try writer.capture(key, root: root, cached: credentialSnapshot)
            credentialSnapshot = result.snapshot; vault = result.snapshot.vault
            credentialVersions[key] = result.credentialVersion
            if vault.entries[key] == nil, !allowMissing { throw ReviewsFailure.noKey }
            return vault.entries[key]
        } catch { credentialFailures.insert(key); credentialSnapshot = nil; throw error }
    }
    func acceptCredential(_ value: VaultWriter.Capture, key: String, writer: VaultWriter) {
        credentialWriter = writer; credentialSnapshot = value.snapshot; vault = value.snapshot.vault; credentialVersions[key] = value.credentialVersion; credentialFailures.remove(key)
    }
    /// An explicit retry clears paused access for this account and its current Reporter token.
    public func retryKeychainAccess(accountId: String, writer: VaultWriter) throws {
        try requireOwnWorkspace()
        guard try accounts().contains(where: { $0.id == accountId }) else { throw AccountFailure.notFound }
        let directory = try storeAccess { $0.directory }, name = "reporter_" + JSONText.string(accountId).rawSHA256.prefix(32)
        try FileMutex.withLock(directory.appendingPathComponent("\(name).mutex")) {
            let reporter = try salesConnection(accountId: accountId)?.reporter
            writer.retryKeychainAccess()
            credentialWriter = writer; credentialSnapshot = nil
            credentialFailures.remove("apple:\(accountId)"); credentialVersions["apple:\(accountId)"] = nil
            if let reporter { credentialFailures.remove("reporter:\(reporter.credentialId)"); credentialVersions["reporter:\(reporter.credentialId)"] = nil }
        }
    }
}
