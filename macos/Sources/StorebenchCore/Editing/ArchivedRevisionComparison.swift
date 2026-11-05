import Foundation

/// Each changed set retains its exact archive positions, including repeated image identities and hashes.
public struct ArchivedRevisionComparison: Sendable {
    public struct Change: Sendable {
        public let value: RevisionComparison.Change
        public let beforeScreenshots, afterScreenshots: [LibraryChooser.Shot]
    }
    public let before, after: ArchivedRevision
    public let changes: [Change]
    public init(before: ArchivedRevision, after: ArchivedRevision) throws {
        guard before.documentRevision > 0, after.documentRevision > 0 else { throw RevisionHistoryFailure.invalid }
        let values = try RevisionComparison.compare(before: before.value, after: after.value)
        let earlier = try LibraryChooser.images(before), later = try LibraryChooser.images(after)
        func images(_ indices: Range<Int>?, hashes: [String]?, in shots: [LibraryChooser.Shot]) throws -> [LibraryChooser.Shot] {
            guard let indices else {
                guard hashes == nil else { throw RevisionHistoryFailure.invalid }; return []
            }
            guard indices.lowerBound >= 0, indices.upperBound <= shots.count, hashes?.count == indices.count else { throw RevisionHistoryFailure.invalid }
            let selected = Array(shots[indices])
            guard selected.map(\.galleryItem.sha256) == hashes else { throw RevisionHistoryFailure.invalid }
            return selected
        }
        changes = try values.map { value in
            try Change(value: value, beforeScreenshots: images(value.beforeImageIndices, hashes: value.beforeImages, in: earlier),
                       afterScreenshots: images(value.afterImageIndices, hashes: value.afterImages, in: later))
        }
        self.before = before; self.after = after
    }
}

extension WorkspaceSession {
    public func archivedRevisionComparison(accountId: String, appId: String, beforeId: String, afterId: String) throws -> ArchivedRevisionComparison {
        try requireHistoryScope(accountId: accountId, appId: appId); try Task.checkCancellation()
        let comparison = try storeAccess { store in
            let before = try archivedRevision(accountId: accountId, appId: appId, id: beforeId, store: store)
            let after = try archivedRevision(accountId: accountId, appId: appId, id: afterId, store: store)
            return try ArchivedRevisionComparison(before: before, after: after)
        }
        try requireHistoryScope(accountId: accountId, appId: appId); try requireSessionAccess(); try Task.checkCancellation()
        return comparison
    }
}
