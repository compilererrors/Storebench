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

    /// The largest font file a card can use.
    public static let maximumFontBytes = 20 * 1024 * 1024

    /// Checks a TrueType or OpenType font file and saves it in encrypted media for use on cards. The original bytes are kept unchanged.
    public func stageMediaCardFont(accountId: String, appId: String, bytes: Data, name: String) throws -> MediaCardStyle.FontFile {
        _ = try mediaCardPrefix(accountId, appId)
        guard !bytes.isEmpty, bytes.count <= Self.maximumFontBytes, let family = MediaCardRenderer.fontFamily(bytes), !TextSemantics.trim(family).isEmpty else { throw MediaCardFailure.font }
        let directory = try storeAccess { $0.directory }
        let stored = try FileMutex.withLock(directory.appendingPathComponent("backup_media.mutex")) { try media.write(bytes, limit: Self.maximumFontBytes) }
        func shown(_ text: String, _ fallback: String) -> String {
            var value = String(text.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 }.map(Character.init))
            while value.utf16.count > 200 { value.removeLast() }
            return value.isEmpty ? fallback : value
        }
        return MediaCardStyle.FontFile(hash: stored.hash, name: shown(name, "Font"), family: shown(family, "Font"))
    }

    /// Reads a card font file. Only fonts used by this app's saved card sets can be read.
    public func mediaCardFont(accountId: String, appId: String, hash: String) throws -> Data {
        let used = try mediaCardSets(accountId: accountId, appId: appId).flatMap { $0.set.cards.compactMap(\.style.fontFile?.hash) }
        guard hash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil, used.contains(hash) else { throw MediaCardFailure.missing }
        return try media.read(hash)
    }

    /// Reads a card screenshot. Only screenshots used by this app's saved card sets can be read.
    public func mediaCardScreenshot(accountId: String, appId: String, hash: String) throws -> Data {
        let used = try mediaCardSets(accountId: accountId, appId: appId).flatMap { $0.set.cards.compactMap(\.screenshot?.hash) }
        guard hash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil, used.contains(hash) else { throw MediaCardFailure.missing }
        return try media.read(hash)
    }
}

/// A file chosen for one card. When it finishes loading it applies only to that card in that set, and only if no newer
/// choice of the same kind for the card replaced it, so switching cards while a file loads never changes another card.
public struct MediaCardLoad: Sendable, Equatable {
    public enum Kind: String, Sendable { case screenshot, font }
    public let setId: String, cardId: String, kind: Kind, ticket: UUID
    public init(setId: String, cardId: String, kind: Kind, ticket: UUID = UUID()) { self.setId = setId; self.cardId = cardId; self.kind = kind; self.ticket = ticket }
    /// The key that newer choices for the same card and kind share.
    public var key: String { kind.rawValue + ":" + cardId }
    /// The card's position in the open set, or nil when the set changed, the card was removed or a newer choice replaced this one.
    public func position(in set: MediaCardSet?, newest: [String: UUID]) -> Int? {
        guard newest[key] == ticket, let set, set.id == setId else { return nil }
        return set.cards.firstIndex { $0.id == cardId }
    }
}

/// The decoded screenshots of an open card set. Thumbnails use small decodes kept for every card; full-size decodes, which the
/// selected card's preview and exports need, are kept least recently used first within a byte budget, so a set with many
/// screenshots never holds all of them at full size.
public struct MediaCardImages: @unchecked Sendable {
    /// Longest side of a thumbnail decode: enough for cards drawn at search-result size on a Retina screen.
    public static let thumbnailEdge = 720
    public static let fullBudget = CachePolicy.Limit(count: 6, bytes: 96 * 1_048_576)
    private var full = BoundedMemoryCache<String, DecodedScreenshot>(MediaCardImages.fullBudget)
    private var small: [String: DecodedScreenshot] = [:]
    public init() {}
    /// The full-size decode, if kept. Reading it does not count as use.
    public func full(_ hash: String) -> DecodedScreenshot? { full.peek(hash) }
    /// A screenshot good enough for a thumbnail: the small decode, or the full one while no small one exists.
    public func thumbnail(_ hash: String) -> DecodedScreenshot? { small[hash] ?? full.peek(hash) }
    /// Bytes of every full-size decode retained by the cache.
    public var fullBytes: Int { full.cost }
    public var fullCount: Int { full.count }
    /// A decode larger than the budget stays with its caller for rendering and is not retained here.
    public mutating func keepFull(_ image: DecodedScreenshot, _ hash: String) { full.insert(image, for: hash, cost: image.width * image.height * 4) }
    /// Marks a full-size decode as used, so the selected card's screenshot is the last one let go.
    public mutating func touch(_ hash: String) { _ = full.value(for: hash) }
    public mutating func keepThumbnail(_ image: DecodedScreenshot, _ hash: String) {
        if small.count >= MediaCards.maximumCards * 4, small[hash] == nil { small.removeAll() }
        small[hash] = image
    }
    /// Lets go of every decode, as when another card set opens.
    public mutating func removeAll() { full.removeAll(); small.removeAll() }
}
