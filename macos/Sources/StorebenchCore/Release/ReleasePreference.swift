import Foundation

/// The App Store Version Release option last saved for an app on this Mac. A new version starts with it; the date of a scheduled release belongs to each version.
public enum ReleasePreference {
    static let namespace = "release_preferences"
    static func mutex(_ key: String) -> String { "release_preference_" + JSONText.string(key).rawSHA256.prefix(40) }
    static func stored(_ document: EncryptedDocumentStore.Document?) throws -> String? {
        guard let document else { return nil }
        let value = try JSONText.parse(document.payload)
        guard case .number(let version)? = value["schemaVersion"], version == 1, let type = value["releaseType"]?.text, valid(type) else { throw ReleaseFailure.invalid("The saved release option could not be read.") }
        return type
    }
    static func valid(_ type: String) -> Bool { Releases.releaseTypes.contains { $0.0 == type } }

    /// A new version takes the app's saved option instead of the one copied from Apple's earlier version.
    public static func applying(_ type: String?, to inputs: ReleasePlanInputs) -> ReleasePlanInputs {
        guard let type, valid(type) else { return inputs }
        var next = inputs; next.releaseType = type; return next
    }
}

extension WorkspaceSession {
    public func releasePreference(accountId: String, appId: String) throws -> String? {
        try requireHistoryScope(accountId: accountId, appId: appId); try Task.checkCancellation()
        return try storeAccess { try ReleasePreference.stored($0.document(namespace: ReleasePreference.namespace, key: "\(accountId):\(appId)")) }
    }
    public func saveReleasePreference(accountId: String, appId: String, releaseType: String) throws {
        guard ReleasePreference.valid(releaseType) else { throw ReleaseFailure.invalid("Choose a valid release method.") }
        try requireHistoryScope(accountId: accountId, appId: appId)
        let key = "\(accountId):\(appId)"
        try storeAccess { store in
            try FileMutex.withLock(store.directory.appendingPathComponent(ReleasePreference.mutex(key) + ".mutex")) {
                try store.transaction { _ in
                    try requireHistoryScope(accountId: accountId, appId: appId); try requireSessionAccess(); try Task.checkCancellation()
                    return [.put(namespace: ReleasePreference.namespace, key: key, json: JSONText.object([("schemaVersion", .number(1)), ("releaseType", .string(releaseType))]).data)]
                }
            }
        }
    }
}
