import CryptoKit
import Darwin
import Foundation
import Security

/// Encrypted media files (`SBMEDIA2`): content-addressed by SHA-256, named by an HMAC of that hash,
/// encrypted in 1 MiB AES-256-GCM chunks with keys derived by HKDF from the database key.
public final class EncryptedMediaStore: @unchecked Sendable {
    public enum Failure: Error, Equatable { case notPrivate, invalid, tooLarge, empty, authentication }

    static let magic = Data("SBMEDIA2".utf8), headerLength = 88, chunkLength = 1024 * 1024, tagLength = 16
    static let context = Data("storebench-media-v1".utf8)

    let directory: URL
    private var master: SymmetricKey?
    private let masterLock = NSLock()
    let maximumBytes: Int

    public init(directory: URL, key: Data, maximumBytes: Int = 500 * 1024 * 1024) throws {
        try TestIsolation.check(directory)
        guard key.count == 32, maximumBytes >= 1, maximumBytes <= 16 * 1024 * 1024 * 1024 else { throw Failure.invalid }
        var parent = stat(); let uid = getuid()
        guard lstat(directory.deletingLastPathComponent().path, &parent) == 0, (parent.st_mode & S_IFMT) == S_IFDIR, parent.st_uid == uid, parent.st_mode & 0o077 == 0 else { throw Failure.notPrivate }
        if mkdir(directory.path, 0o700) != 0 && errno != EEXIST { throw Failure.notPrivate }
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == uid, info.st_mode & 0o077 == 0 else { throw Failure.notPrivate }
        self.directory = directory; self.master = SymmetricKey(data: key); self.maximumBytes = maximumBytes
    }

    func discardKey() { masterLock.withLock { master = nil } }
    private func masterKey() throws -> SymmetricKey {
        try masterLock.withLock { guard let master else { throw SessionFailure.closed }; return master }
    }

    func fileURL(_ hash: String) throws -> URL {
        guard hash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw Failure.invalid }
        let name = HMAC<SHA256>.authenticationCode(for: Data("storebench-media-file-v2\0\(hash)".utf8), using: try masterKey()).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(name).sbmedia")
    }

    func keys(_ salt: Data) throws -> (encryption: SymmetricKey, authentication: SymmetricKey) {
        let derived = HKDF<SHA256>.deriveKey(inputKeyMaterial: try masterKey(), salt: salt, info: Self.context, outputByteCount: 64).withUnsafeBytes { Data($0) }
        return (SymmetricKey(data: derived.prefix(32)), SymmetricKey(data: derived.suffix(32)))
    }

    static func nonce(_ prefix: Data, _ index: UInt32) throws -> AES.GCM.Nonce {
        var value = prefix
        withUnsafeBytes(of: index.bigEndian) { value.append(contentsOf: $0) }
        return try AES.GCM.Nonce(data: value)
    }

    static func associated(_ index: UInt32, _ length: Int) -> Data {
        var value = Data()
        withUnsafeBytes(of: index.bigEndian) { value.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(length).bigEndian) { value.append(contentsOf: $0) }
        return value
    }

    /// Encrypts bytes into the store and returns their content hash. Existing identical content is verified and kept.
    @discardableResult public func write(_ bytes: Data, limit: Int? = nil) throws -> (hash: String, length: Int) {
        guard !bytes.isEmpty else { throw Failure.empty }
        guard bytes.count <= min(limit ?? maximumBytes, maximumBytes) else { throw Failure.tooLarge }
        var salt = Data(count: 16), prefix = Data(count: 8)
        guard salt.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }) == errSecSuccess,
              prefix.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 8, $0.baseAddress!) }) == errSecSuccess else { throw Failure.invalid }
        let secret = try keys(salt), hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        var body = Data(), index: UInt32 = 0, offset = bytes.startIndex
        while offset < bytes.endIndex {
            let end = min(offset + Self.chunkLength, bytes.endIndex), plain = bytes[offset..<end]
            let sealed = try AES.GCM.seal(plain, using: secret.encryption, nonce: Self.nonce(prefix, index), authenticating: Self.associated(index, plain.count))
            body += sealed.ciphertext; body += sealed.tag
            index += 1; offset = end
        }
        var header = Self.magic + salt + prefix
        var metadata = Data()
        withUnsafeBytes(of: UInt64(bytes.count).bigEndian) { metadata.append(contentsOf: $0) }
        metadata += Data(SHA256.hash(data: bytes))
        let sealedHeader = try AES.GCM.seal(metadata, using: secret.authentication, nonce: Self.nonce(prefix, 0xffff_ffff), authenticating: header)
        header += sealedHeader.ciphertext; header += sealedHeader.tag

        let temporary = directory.appendingPathComponent(".media-\(UUID().uuidString.lowercased()).tmp")
        defer { unlink(temporary.path) }
        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Failure.invalid }
        let file = header + body
        let written = file.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        let synced = fsync(descriptor); close(descriptor)
        guard written == file.count, synced == 0 else { throw Failure.invalid }
        let destination = try fileURL(hash)
        if link(temporary.path, destination.path) != 0 {
            guard errno == EEXIST else { throw Failure.invalid }
            // A content-addressed target must already decrypt to the same bytes.
            guard try read(hash) == bytes else { throw Failure.invalid }
        }
        return (hash, bytes.count)
    }

    struct Header { let length: Int; let hash: String; let prefix: Data; let encryption: SymmetricKey }

    private func header(_ file: Data, expected: String?, fileLength: Int? = nil) throws -> Header {
        guard file.count >= Self.headerLength, file.prefix(8) == Self.magic else { throw Failure.invalid }
        let salt = file.subdata(in: 8..<24), prefix = file.subdata(in: 24..<32), secret = try keys(salt)
        let metadata: Data
        do {
            let box = try AES.GCM.SealedBox(nonce: Self.nonce(prefix, 0xffff_ffff), ciphertext: file.subdata(in: 32..<72), tag: file.subdata(in: 72..<88))
            metadata = try AES.GCM.open(box, using: secret.authentication, authenticating: file.prefix(32))
        } catch { throw Failure.authentication }
        let rawLength = metadata.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }, hash = metadata.suffix(32).map { String(format: "%02x", $0) }.joined()
        guard rawLength >= 1, rawLength <= UInt64(maximumBytes), expected == nil || hash == expected else { throw Failure.invalid }
        let length = Int(rawLength)
        guard (fileLength ?? file.count) == Self.headerLength + length + (length + Self.chunkLength - 1) / Self.chunkLength * Self.tagLength else { throw Failure.invalid }
        return Header(length: length, hash: hash, prefix: prefix, encryption: secret.encryption)
    }

    private func opened(_ hash: String) throws -> (Int32, Header) {
        let descriptor = open(try fileURL(hash).path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.invalid }
        do {
            var info = stat()
            guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw Failure.notPrivate }
            var bytes = Data(count: Self.headerLength)
            guard bytes.withUnsafeMutableBytes({ pread(descriptor, $0.baseAddress, Self.headerLength, 0) }) == Self.headerLength else { throw Failure.invalid }
            return (descriptor, try header(bytes, expected: hash, fileLength: Int(info.st_size)))
        } catch { close(descriptor); throw error }
    }

    private func load(_ url: URL) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.invalid }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw Failure.notPrivate }
        guard Int(info.st_size) <= Self.headerLength + maximumBytes + (maximumBytes / Self.chunkLength + 1) * Self.tagLength else { throw Failure.tooLarge }
        return try Data(contentsOf: url, options: .uncached)
    }

    /// Authenticates every chunk of a file found by name, and checks that its name belongs to its content.
    func verifyFile(named name: String) throws {
        guard name.range(of: "^[a-f0-9]{64}\\.sbmedia$", options: .regularExpression) != nil else { throw Failure.invalid }
        let url = directory.appendingPathComponent(name)
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.invalid }
        var head = Data(count: Self.headerLength)
        let got = head.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, Self.headerLength, 0) }
        close(descriptor)
        guard got == Self.headerLength else { throw Failure.invalid }
        let salt = head.subdata(in: 8..<24), prefix = head.subdata(in: 24..<32)
        guard head.prefix(8) == Self.magic else { throw Failure.invalid }
        let metadata: Data
        do {
            let box = try AES.GCM.SealedBox(nonce: Self.nonce(prefix, 0xffff_ffff), ciphertext: head.subdata(in: 32..<72), tag: head.subdata(in: 72..<88))
            metadata = try AES.GCM.open(box, using: keys(salt).authentication, authenticating: head.prefix(32))
        } catch { throw Failure.authentication }
        let hash = metadata.suffix(32).map { String(format: "%02x", $0) }.joined()
        guard try fileURL(hash).lastPathComponent == name else { throw Failure.invalid }
        try stream(hash) { _ in }
    }

    /// The length of saved content, after authenticating its header.
    public func metadata(_ hash: String) throws -> Int {
        let (descriptor, header) = try opened(hash); defer { close(descriptor) }; return header.length
    }

    /// Decrypts and authenticates every chunk and the complete content hash.
    public func read(_ hash: String) throws -> Data {
        let file = try load(try fileURL(hash)), header = try header(file, expected: hash)
        var plain = Data(capacity: header.length), index: UInt32 = 0, offset = Self.headerLength
        while plain.count < header.length {
            let length = min(Self.chunkLength, header.length - plain.count)
            do {
                let box = try AES.GCM.SealedBox(nonce: Self.nonce(header.prefix, index), ciphertext: file.subdata(in: offset..<offset + length), tag: file.subdata(in: offset + length..<offset + length + Self.tagLength))
                plain += try AES.GCM.open(box, using: header.encryption, authenticating: Self.associated(index, length))
            } catch { throw Failure.authentication }
            offset += length + Self.tagLength; index += 1
        }
        guard SHA256.hash(data: plain).map({ String(format: "%02x", $0) }).joined() == header.hash else { throw Failure.authentication }
        return plain
    }
}

extension EncryptedMediaStore {
    /// Encrypts a file chunk by chunk without holding it in memory, for videos up to the store's limit.
    @discardableResult public func write(fileAt source: URL, limit: Int, expectedSize: Int? = nil, signature: Data? = nil) throws -> (hash: String, length: Int) {
        try TestIsolation.check(source)
        let sourceDescriptor = open(source.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard sourceDescriptor >= 0 else { throw Failure.invalid }
        let input = FileHandle(fileDescriptor: sourceDescriptor, closeOnDealloc: true)
        defer { try? input.close() }
        var sourceInfo = stat()
        guard fstat(sourceDescriptor, &sourceInfo) == 0, sourceInfo.st_mode & S_IFMT == S_IFREG else { throw Failure.invalid }
        if let expectedSize { guard expectedSize >= 1, expectedSize <= min(limit, maximumBytes), Int(sourceInfo.st_size) == expectedSize else { throw Failure.invalid } }
        var salt = Data(count: 16), prefix = Data(count: 8)
        guard salt.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }) == errSecSuccess,
              prefix.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 8, $0.baseAddress!) }) == errSecSuccess else { throw Failure.invalid }
        let secret = try keys(salt)
        let temporary = directory.appendingPathComponent(".media-\(UUID().uuidString.lowercased()).tmp")
        defer { unlink(temporary.path) }
        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Failure.invalid }
        var closed = false
        defer { if !closed { close(descriptor) } }
        func put(_ data: Data, at offset: Int) throws {
            let written = data.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, off_t(offset)) }
            guard written == data.count else { throw Failure.invalid }
        }
        var digest = SHA256(), total = 0, index: UInt32 = 0, position = Self.headerLength
        try put(Data(count: Self.headerLength), at: 0)
        while let chunk = try input.read(upToCount: Self.chunkLength), !chunk.isEmpty {
            try Task.checkCancellation()
            if total == 0, let signature { guard chunk.prefix(signature.count) == signature else { throw Failure.invalid } }
            total += chunk.count
            guard total <= min(limit, maximumBytes), expectedSize.map({ total <= $0 }) ?? true else { throw Failure.tooLarge }
            digest.update(data: chunk)
            let sealed = try AES.GCM.seal(chunk, using: secret.encryption, nonce: Self.nonce(prefix, index), authenticating: Self.associated(index, chunk.count))
            let encrypted = sealed.ciphertext + sealed.tag
            try put(encrypted, at: position)
            position += encrypted.count; index += 1
        }
        guard total > 0 else { throw Failure.empty }
        if let expectedSize { guard total == expectedSize else { throw Failure.invalid } }
        let hashBytes = Data(digest.finalize()), hash = hashBytes.map { String(format: "%02x", $0) }.joined()
        var header = Self.magic + salt + prefix, metadata = Data()
        withUnsafeBytes(of: UInt64(total).bigEndian) { metadata.append(contentsOf: $0) }
        metadata += hashBytes
        let sealedHeader = try AES.GCM.seal(metadata, using: secret.authentication, nonce: Self.nonce(prefix, 0xffff_ffff), authenticating: header)
        header += sealedHeader.ciphertext; header += sealedHeader.tag
        try put(header, at: 0)
        guard fsync(descriptor) == 0 else { throw Failure.invalid }
        close(descriptor); closed = true
        let destination = try fileURL(hash)
        if link(temporary.path, destination.path) != 0 {
            guard errno == EEXIST, try self.metadata(hash) == total else { throw Failure.invalid }
            try stream(hash) { _ in }
        }
        return (hash, total)
    }
}

extension EncryptedMediaStore {
    /// Authenticated chunks and whole-file hashing, with bounded memory even for build packages.
    public func stream(_ hash: String, _ body: (Data) throws -> Void) throws {
        let (descriptor, header) = try opened(hash); defer { close(descriptor) }
        try stream(descriptor, header: header, range: 0..<header.length, body)
    }

    /// Authenticates covered chunks without allocating the complete requested range.
    public func stream(_ hash: String, range: Range<Int>, _ body: (Data) throws -> Void) throws {
        let (descriptor, header) = try opened(hash); defer { close(descriptor) }
        try stream(descriptor, header: header, range: range, body)
    }

    private func stream(_ descriptor: Int32, header: Header, range: Range<Int>, _ body: (Data) throws -> Void) throws {
        guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= header.length else { throw Failure.invalid }
        var digest = SHA256()
        let whole = range.lowerBound == 0 && range.upperBound == header.length
        for index in (range.lowerBound / Self.chunkLength)...((range.upperBound - 1) / Self.chunkLength) {
            try Task.checkCancellation()
            let size = min(Self.chunkLength, header.length - index * Self.chunkLength)
            var sealed = Data(count: size + Self.tagLength)
            let offset = Self.headerLength + index * (Self.chunkLength + Self.tagLength)
            guard sealed.withUnsafeMutableBytes({ pread(descriptor, $0.baseAddress, $0.count, off_t(offset)) }) == sealed.count else { throw Failure.invalid }
            let plain: Data
            do {
                let box = try AES.GCM.SealedBox(nonce: Self.nonce(header.prefix, UInt32(index)), ciphertext: sealed.prefix(size), tag: sealed.suffix(Self.tagLength))
                plain = try AES.GCM.open(box, using: header.encryption, authenticating: Self.associated(UInt32(index), size))
            } catch { throw Failure.authentication }
            if whole { digest.update(data: plain) }
            let chunkStart = index * Self.chunkLength, from = max(range.lowerBound, chunkStart) - chunkStart, to = min(range.upperBound, chunkStart + size) - chunkStart
            try body(plain.subdata(in: from..<to))
        }
        if whole { guard Data(digest.finalize()).map({ String(format: "%02x", $0) }).joined() == header.hash else { throw Failure.authentication } }
    }

    /// Convenience for small consumers; large uploads use the callback stream instead.
    public func read(_ hash: String, range: Range<Int>) throws -> Data {
        var result = Data()
        try stream(hash, range: range) { result.append($0) }
        return result
    }
}
