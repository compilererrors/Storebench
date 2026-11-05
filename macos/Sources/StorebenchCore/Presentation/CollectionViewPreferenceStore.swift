import Foundation

/// Where shared collections remember their view options. `WorkspaceSession` keeps them in the open workspace.
public protocol CollectionViewPreferenceStore: AnyObject, Sendable {
    func collectionViewPreference(_ key: String) async throws -> CollectionViewPreferences?
    func saveCollectionViewPreference(_ key: String, value: CollectionViewPreferences) async throws
}

extension WorkspaceSession: CollectionViewPreferenceStore {}
