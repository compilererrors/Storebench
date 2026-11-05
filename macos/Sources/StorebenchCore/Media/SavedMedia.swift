import CryptoKit
import Foundation

public enum SavedMediaFailure: Error, Equatable {
    case missing, range, changed, format
    public var message: String {
        switch self {
        case .missing: "This media is no longer available in the selected saved material."
        case .range: "The requested media interval is unavailable."
        case .changed: "This media reader is closed. Open the saved media again."
        case .format: "This saved media could not be read in its original format."
        }
    }
}

/// A player request is served in authenticated bounded intervals, including requests to the end.
public enum MediaReadPolicy {
    public static let chunkBytes = 1024 * 1024
    public static func end(length: Int, offset: Int64, requested: Int, toEnd: Bool) throws -> Int {
        guard length > 0, offset >= 0, offset <= Int64(length), requested >= 0 else { throw SavedMediaFailure.range }
        let start = Int(offset)
        return toEnd ? length : start + min(requested, length - start)
    }
    public static func next(length: Int, current: Int64, end: Int) throws -> Range<Int>? {
        guard current >= 0, current <= Int64(length), end >= 0, end <= length, current <= Int64(end) else { throw SavedMediaFailure.range }
        let start = Int(current)
        return start == end ? nil : start..<start + min(chunkBytes, end - start)
    }
    public static func posterMaximum(duration: Double) -> Double { duration.isFinite ? max(0, duration - 0.01) : 0 }
    public static func poster(_ value: Double, duration: Double) -> Double { value.isFinite ? min(posterMaximum(duration: duration), max(0, value)) : min(5, posterMaximum(duration: duration)) }
    public static func exportName(_ name: String, extension ext: String) -> String {
        var safe = String(name.unicodeScalars.map { $0 == "/" || $0 == "\\" || $0.value < 32 || $0.value == 127 ? "_" : Character($0) })
        if let dot = safe.lastIndex(of: ".") { safe = String(safe[..<dot]) }
        var stem = "", count = 0
        for character in safe { let size = String(character).utf16.count; if count + size > 150 { break }; stem.append(character); count += size }
        return "\(stem.isEmpty ? "Media" : stem).\(ext)"
    }
}

public struct SavedMediaSource: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case screenshot(setId: String), archivedScreenshot(index: Int, hash: String, documentRevision: Int), preview(localizationId: String, type: String), assetLibrary }
    public let accountId: String, appId: String, revisionId: String, itemId: String, kind: Kind
    public init(accountId: String, appId: String, revisionId: String, itemId: String, kind: Kind) {
        self.accountId = accountId; self.appId = appId; self.revisionId = revisionId; self.itemId = itemId; self.kind = kind
    }
}

/// Retains an exact immutable source, but never holds a session lease while a player is idle.
public final class SavedMediaReader: @unchecked Sendable {
    public let id = UUID(), length: Int, fileName: String, contentType: String, ext: String
    public let width: Int, height: Int
    public let duration: Double?
    public var address: URL { URL(string: "storebench-media://\(id.uuidString.lowercased())/original.\(ext)")! }
    private let lock = NSLock()
    private var session: WorkspaceSession?
    let source: SavedMediaSource, hash: String
    init(session: WorkspaceSession, source: SavedMediaSource, hash: String, length: Int, fileName: String, ext: String, contentType: String, width: Int, height: Int, duration: Double?) {
        self.session = session; self.source = source; self.hash = hash; self.length = length
        self.fileName = MediaReadPolicy.exportName(fileName, extension: ext); self.ext = ext; self.contentType = contentType
        self.width = width; self.height = height; self.duration = duration
    }
    public func accepts(_ url: URL?) -> Bool { url == address }
    public func close() { lock.withLock { session = nil } }
    func currentSession() throws -> WorkspaceSession { try lock.withLock { guard let session else { throw SavedMediaFailure.changed }; return session } }
    public func read(_ range: Range<Int>) async throws -> Data {
        guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= length, range.count <= MediaReadPolicy.chunkBytes else { throw SavedMediaFailure.range }
        return try await currentSession().readSavedMedia(self, range: range)
    }
    public func imageBytes() async throws -> Data {
        guard duration == nil, length <= 50_000_000 else { throw SavedMediaFailure.format }
        var bytes = Data(), offset = 0
        while let range = try MediaReadPolicy.next(length: length, current: Int64(offset), end: length) {
            bytes.append(try await read(range)); offset = range.upperBound
        }
        guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == hash else { throw EncryptedMediaStore.Failure.authentication }
        try Task.checkCancellation(); try currentSession().validateAccess()
        return bytes
    }
    public func export(to url: URL) async throws { try await currentSession().exportSavedMedia(self, to: url) }
}

/// Queue-owned request identities prevent a cancelled or replaced request from delivering or finishing another.
public struct MediaRequestTickets<Key: Hashable & Sendable>: Sendable {
    private var active: [Key: UUID] = [:]
    public init() {}
    public mutating func begin(_ key: Key) -> UUID { let token = UUID(); active[key] = token; return token }
    public func contains(_ key: Key, token: UUID) -> Bool { active[key] == token }
    @discardableResult public mutating func finish(_ key: Key, token: UUID) -> Bool {
        guard active[key] == token else { return false }; active.removeValue(forKey: key); return true
    }
    public mutating func cancel(_ key: Key) { active.removeValue(forKey: key) }
    public mutating func cancelAll() { active.removeAll() }
}

extension WorkspaceSession {
    struct ResolvedMedia { let hash: String, name: String, ext: String, width: Int, height: Int, duration: Double? }
    func resolveSavedMedia(_ source: SavedMediaSource) throws -> ResolvedMedia {
        try requireHistoryScope(accountId: source.accountId, appId: source.appId)
        switch source.kind {
        case .assetLibrary:
            guard source.revisionId == source.itemId else { throw SavedMediaFailure.missing }
            let file = try libraryFile(accountId: source.accountId, appId: source.appId, id: source.itemId)
            return ResolvedMedia(hash: file.hash, name: file.fileName, ext: file.ext, width: file.width, height: file.height, duration: file.duration)
        case .archivedScreenshot(let index, let hash, let documentRevision):
            let revision = try storeAccess { try archivedRevision(accountId: source.accountId, appId: source.appId, id: source.revisionId, store: $0) }
            guard revision.documentRevision == documentRevision else { throw SavedMediaFailure.changed }
            let images = try LibraryChooser.images(revision)
            guard images.indices.contains(index), let storedHash = images[index].value["sha256"]?.text,
                  TextSemantics.same(storedHash, hash), TextSemantics.same(images[index].source.itemId, source.itemId) else { throw SavedMediaFailure.missing }
            let image = images[index]
            func dimension(_ field: String) throws -> Int {
                guard let raw = image.value[field] else { return 0 }
                guard case .number(let number) = raw, number > 0, number <= 9_007_199_254_740_991, let value = Int(exactly: number) else { throw SavedMediaFailure.format }
                return value
            }
            return ResolvedMedia(hash: hash, name: image.fileName, ext: "", width: try dimension("width"), height: try dimension("height"), duration: nil)
        case .screenshot(let setId):
            let set = try screenshotSet(accountId: source.accountId, appId: source.appId, revisionId: source.revisionId, setId: setId)
            guard let item = set.items.first(where: { $0.id == source.itemId }) else { throw SavedMediaFailure.missing }
            return ResolvedMedia(hash: item.sha256, name: item.fileName, ext: "", width: item.width ?? 0, height: item.height ?? 0, duration: nil)
        case .preview(let localizationId, let type):
            let key = try TextDrafts.key(accountId: source.accountId, appId: source.appId, revisionId: source.revisionId)
            guard try storeAccess({ try $0.document(namespace: "revisions", key: key) }) != nil else { throw SavedMediaFailure.missing }
            let set = try previewSet(accountId: source.accountId, appId: source.appId, revisionId: source.revisionId, localizationId: localizationId, type: type)
            guard let item = set.items.first(where: { $0.id == source.itemId }), ["mp4", "m4v", "mov"].contains(item.ext), item.duration.isFinite, item.duration > 0 else { throw SavedMediaFailure.missing }
            return ResolvedMedia(hash: item.sha256, name: item.fileName, ext: item.ext, width: item.width, height: item.height, duration: item.duration)
        }
    }
    public func openSavedMedia(_ source: SavedMediaSource) throws -> SavedMediaReader {
        let item = try resolveSavedMedia(source), length = try media.metadata(item.hash)
        let dimensionsOptional = item.duration == nil
        guard length > 0, length <= (source.kind == .assetLibrary ? 524_288_000 : item.duration == nil ? 50_000_000 : PreviewSpecs.maximumBytes),
              dimensionsOptional ? item.width >= 0 && item.height >= 0 : item.width > 0 && item.height > 0 else { throw SavedMediaFailure.format }
        let ext: String, contentType: String
        if item.duration != nil { ext = item.ext; contentType = ext == "mov" ? "com.apple.quicktime-movie" : ext == "m4v" ? "com.apple.m4v-video" : "public.mpeg-4" }
        else {
            let signature = try media.read(item.hash, range: 0..<min(8, length))
            if signature.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) { ext = "png"; contentType = "public.png" }
            else if signature.starts(with: [255, 216, 255]) { ext = "jpg"; contentType = "public.jpeg" }
            else { throw SavedMediaFailure.format }
        }
        return SavedMediaReader(session: self, source: source, hash: item.hash, length: length, fileName: item.name, ext: ext, contentType: contentType, width: item.width, height: item.height, duration: item.duration)
    }
    func readSavedMedia(_ reader: SavedMediaReader, range: Range<Int>) async throws -> Data {
        let item = try resolveSavedMedia(reader.source)
        guard item.hash == reader.hash, try reader.currentSession() === self else { throw SavedMediaFailure.changed }
        let lease = try lifetime.admit(.transfer); defer { lease.finish() }
        let media = self.media, access = sessionRequestCheck()
        let worker = Task.detached {
            try SessionContext.$lease.withValue(lease) {
                try access(); try Task.checkCancellation(); _ = try reader.currentSession()
                let bytes = try media.read(reader.hash, range: range)
                try access(); try Task.checkCancellation(); _ = try reader.currentSession(); return bytes
            }
        }
        let bytes = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        try Task.checkCancellation()
        guard try resolveSavedMedia(reader.source).hash == reader.hash else { throw SavedMediaFailure.changed }
        return bytes
    }
    func exportSavedMedia(_ reader: SavedMediaReader, to url: URL) async throws {
        guard try resolveSavedMedia(reader.source).hash == reader.hash, try reader.currentSession() === self else { throw SavedMediaFailure.changed }
        let lease = try lifetime.admit(.transfer); defer { lease.finish() }
        let media = self.media, access = sessionRequestCheck()
        let worker = Task.detached {
            try SessionContext.$lease.withValue(lease) {
                try ReportFiles.atomicStream(to: url) { write in
                    try media.stream(reader.hash) { bytes in
                        try access(); try Task.checkCancellation(); _ = try reader.currentSession(); try write(bytes)
                    }
                    try access(); _ = try reader.currentSession()
                }
            }
        }
        try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
}
