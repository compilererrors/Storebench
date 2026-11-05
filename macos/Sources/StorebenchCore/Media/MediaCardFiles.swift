import Foundation
import ImageIO

/// Card sets are saved per app in the encrypted store; their screenshots are encrypted media addressed by hash.
/// Every write compares the revision the editor loaded under the app's card mutex, so another window's save is never overwritten.
extension WorkspaceSession {
    public struct SavedMediaCardSet: Sendable, Equatable {
        public let revision: Int
        public let set: MediaCardSet
        public init(revision: Int, set: MediaCardSet) { self.revision = revision; self.set = set }
    }
    static let mediaCardNamespace = "media_card_sets"

    private func mediaCardPrefix(_ accountId: String, _ appId: String) throws -> String {
        try requireHistoryScope(accountId: accountId, appId: appId); return "\(accountId):\(appId):"
    }
    private func mediaCardMutex(_ store: EncryptedDocumentStore, _ prefix: String) -> URL {
        store.directory.appendingPathComponent("media_cards_" + JSONText.string(prefix).rawSHA256.prefix(40) + ".mutex")
    }
    static func decodeMediaCardSet(_ document: EncryptedDocumentStore.Document, prefix: String) throws -> MediaCardSet {
        guard let set = try? JSONDecoder().decode(MediaCardSet.self, from: document.payload), document.key == prefix + set.id else { throw MediaCardFailure.invalid }
        try MediaCards.validate(set); return set
    }
    static func encodeMediaCardSet(_ set: MediaCardSet) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(set)
    }

    /// Saved card sets of one app, by name.
    public func mediaCardSets(accountId: String, appId: String) throws -> [SavedMediaCardSet] {
        let prefix = try mediaCardPrefix(accountId, appId)
        return try storeAccess { store in
            try store.documents(namespace: Self.mediaCardNamespace, prefix: prefix).map { SavedMediaCardSet(revision: $0.revision, set: try Self.decodeMediaCardSet($0, prefix: prefix)) }
        }.sorted { $0.set.name.localizedStandardCompare($1.set.name) == .orderedAscending }
    }

    /// Saves onto the revision the editor loaded; 0 creates a new set. Returns the new revision.
    public func saveMediaCardSet(accountId: String, appId: String, set: MediaCardSet, expected: Int) throws -> Int {
        let prefix = try mediaCardPrefix(accountId, appId)
        try MediaCards.validate(set)
        guard expected >= 0 else { throw MediaCardFailure.stale }
        let key = prefix + set.id, json = try Self.encodeMediaCardSet(set)
        return try storeAccess { store in
            try FileMutex.withLock(mediaCardMutex(store, prefix)) {
                try store.transaction { current in
                    guard (try current(Self.mediaCardNamespace, key)?.revision ?? 0) == expected else { throw MediaCardFailure.stale }
                    return [.put(namespace: Self.mediaCardNamespace, key: key, json: json)]
                }
                return try store.document(namespace: Self.mediaCardNamespace, key: key)?.revision ?? 0
            }
        }
    }

    public func deleteMediaCardSet(accountId: String, appId: String, id: String, expected: Int) throws {
        let prefix = try mediaCardPrefix(accountId, appId)
        guard MediaCards.validID(id) else { throw MediaCardFailure.invalid }
        let key = prefix + id
        try storeAccess { store in
            try FileMutex.withLock(mediaCardMutex(store, prefix)) {
                try store.transaction { current in
                    guard let saved = try current(Self.mediaCardNamespace, key) else { throw MediaCardFailure.missing }
                    guard saved.revision == expected else { throw MediaCardFailure.stale }
                    return [.delete(namespace: Self.mediaCardNamespace, key: key)]
                }
            }
        }
    }

    /// Checks a PNG or JPEG and saves it in encrypted media for use on cards. The original bytes are kept unchanged.
    public func stageMediaCardScreenshot(accountId: String, appId: String, bytes: Data, name: String) throws -> MediaCard.Screenshot {
        _ = try mediaCardPrefix(accountId, appId)
        let info = try ScreenshotEditing.inspect(bytes)
        guard let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary), CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete, let type = CGImageSourceGetType(source) as String?, ["public.png", "public.jpeg"].contains(type),
              ((CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyOrientation] as? Int ?? 1) == 1 else { throw ScreenshotEditFailure.image }
        let directory = try storeAccess { $0.directory }
        let stored = try FileMutex.withLock(directory.appendingPathComponent("backup_media.mutex")) { try media.write(bytes, limit: ScreenshotEditing.maximumSourceBytes) }
        var display = String(name.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 }.map(Character.init))
        while display.utf16.count > 200 { display.removeLast() }
        return MediaCard.Screenshot(hash: stored.hash, name: display.isEmpty ? "Screenshot" : display, width: info.width, height: info.height)
    }

    /// Reads a card screenshot. Only screenshots used by this app's saved card sets can be read.
    public func mediaCardScreenshot(accountId: String, appId: String, hash: String) throws -> Data {
        let used = try mediaCardSets(accountId: accountId, appId: appId).flatMap { $0.set.cards.compactMap(\.screenshot?.hash) }
        guard hash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil, used.contains(hash) else { throw MediaCardFailure.missing }
        return try media.read(hash)
    }
}
