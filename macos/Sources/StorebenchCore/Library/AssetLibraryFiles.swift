import CryptoKit
import Darwin
import Foundation
import ImageIO

extension AssetLibrary {
    public struct File: Sendable, Identifiable, Equatable, Codable {
        public let id: String, fileName: String, hash: String, ext: String, category: Category, kind: Kind, referenceName: String
        public let size: Int, width: Int, height: Int, hasAlpha: Bool, hasAudio: Bool
        public let duration: Double?, frameRate: Double?, timeCode: String?
        var json: JSONText {
            .object([("id", .string(id)), ("fileName", .string(fileName)), ("hash", .string(hash)), ("extension", .string(ext)), ("category", .string(category.rawValue)), ("kind", .string(kind.rawValue)),
                     ("referenceName", .string(referenceName)), ("size", .number(Double(size))), ("width", .number(Double(width))), ("height", .number(Double(height))), ("hasAlpha", .bool(hasAlpha)), ("hasAudio", .bool(hasAudio)),
                     ("duration", duration.map(JSONText.number) ?? .null), ("frameRate", frameRate.map(JSONText.number) ?? .null), ("timeCode", timeCode.map(JSONText.string) ?? .null)])
        }
        init(_ value: JSONText) throws {
            guard let id = value["id"]?.text, validID(id), let fileName = value["fileName"]?.text, !fileName.isEmpty, fileName.utf16.count <= 200,
                  !fileName.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 || $0 == "/" || $0 == "\\" }),
                  let hash = value["hash"]?.text, hash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil, let ext = value["extension"]?.text,
                  let kind = value["kind"]?.text.flatMap(Kind.init), (kind == .image ? ["png", "jpg", "jpeg"] : ["mp4", "m4v", "mov"]).contains(ext),
                  let category = value["category"]?.text.flatMap(Category.init), let name = value["referenceName"]?.text,
                  let size = integer(value["size"]), size > 0, size <= 524_288_000, let width = integer(value["width"]), let height = integer(value["height"]), width > 0, height > 0,
                  case .bool(let alpha)? = value["hasAlpha"], case .bool(let audio)? = value["hasAudio"] else { throw failure("The saved Asset Library file is invalid.") }
            self.id = id; self.fileName = fileName; self.hash = hash; self.ext = ext; self.kind = kind; self.category = category; referenceName = try AssetLibrary.referenceName(name)
            self.size = size; self.width = width; self.height = height; hasAlpha = alpha; hasAudio = audio; duration = number(value["duration"]); frameRate = number(value["frameRate"]); timeCode = value["timeCode"]?.text
            if kind == .video { guard let duration, duration > 0, let frameRate, frameRate > 0 else { throw failure("The saved video metadata is invalid.") } }
        }
        static func inspect(_ url: URL, category: Category, name: String, timeCode: String?) throws -> (JSONText, Int) {
            try TestIsolation.check(url)
            let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw failure("The selected file could not be read.") }; defer { Darwin.close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0, info.st_size <= 524_288_000 else { throw failure("Choose an image or video up to 500 MiB.") }
            let ext = url.pathExtension.lowercased(), fileName = MediaReadPolicy.exportName(url.lastPathComponent, extension: ext)
            let kind: Kind = ["png", "jpg", "jpeg"].contains(ext) ? .image : .video
            guard (kind == .image ? ["png", "jpg", "jpeg"] : ["mp4", "mov", "m4v"]).contains(ext) else { throw failure("Choose a PNG, JPEG, MP4, M4V or MOV file.") }
            var width: Int, height: Int, alpha = false, audio = false, duration: Double?, fps: Double?
            if kind == .image {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary), CGImageSourceGetCount(source) == 1,
                      let type = CGImageSourceGetType(source) as String?, ["public.png", "public.jpeg"].contains(type),
                      (type == "public.png") == (ext == "png"),
                      let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any], let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
                      w > 0, h > 0, w <= 12000, h <= 12000, w * h <= 40_000_000, (props[kCGImagePropertyOrientation] as? Int ?? 1) == 1,
                      CGImageSourceGetStatus(source) == .statusComplete,
                      CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 256] as CFDictionary) != nil else { throw failure("Choose a complete upright PNG or JPEG image.") }
                width = w; height = h; alpha = props[kCGImagePropertyHasAlpha] as? Bool ?? false
            } else {
                let movie = try PreviewSpecs.read(url)
                width = movie.width; height = movie.height; duration = movie.duration; fps = movie.frameRate; audio = movie.hasAudio
            }
            if let timeCode {
                var change = Change(action: .upload); change.fileId = "validate"; change.timeCode = timeCode; _ = try change.validated()
                if let duration, let fps {
                    let parts = timeCode.split(separator: ":").compactMap { Double($0) }
                    guard parts.count == 4, parts[3] < fps, parts[0] * 3600 + parts[1] * 60 + parts[2] + parts[3] / fps < duration else { throw failure("Choose a preview frame inside the video's duration and frame rate.") }
                }
            }
            var hash = SHA256(), offset = 0
            while offset < info.st_size {
                try Task.checkCancellation()
                var bytes = Data(count: min(1_048_576, Int(info.st_size) - offset))
                let count = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, off_t(offset)) }
                guard count == bytes.count else { throw failure("The selected file changed while it was being read.") }; hash.update(data: bytes); offset += count
            }
            var after = stat()
            guard fstat(fd, &after) == 0, info.st_size == after.st_size, info.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw failure("The selected file changed while it was being checked.") }
            return (.object([("fileName", .string(fileName)), ("extension", .string(ext)), ("kind", .string(kind.rawValue)), ("category", .string(category.rawValue)), ("referenceName", .string(try AssetLibrary.referenceName(name))),
                             ("width", .number(Double(width))), ("height", .number(Double(height))), ("hasAlpha", .bool(alpha)), ("hasAudio", .bool(audio)),
                             ("duration", duration.map(JSONText.number) ?? .null), ("frameRate", fps.map(JSONText.number) ?? .null), ("timeCode", timeCode.map(JSONText.string) ?? .null), ("sourceHash", .string(hash.finalize().map { String(format: "%02x", $0) }.joined()))]), Int(info.st_size))
        }
    }
}

extension WorkspaceSession {
    public func stageEditedLibraryImage(accountId: String, appId: String, sourceId: String, bytes: Data) throws -> AssetLibrary.File {
        let prefix = try libraryFilePrefix(accountId, appId), directory = try storeAccess { $0.directory }
        let image = try ScreenshotSpecs.validate(bytes)
        guard image.contentType == "image/png", let source = CGImageSourceCreateWithData(bytes as CFData, nil), CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { throw AssetLibrary.failure("The edited library image could not be verified.") }
        return try FileMutex.withLock(directory.appendingPathComponent("asset_library_files.mutex")) {
            let original = try libraryFile(accountId: accountId, appId: appId, id: sourceId)
            guard original.kind == .image else { throw AssetLibrary.failure("Choose an image for editing.") }
            let stored = try FileMutex.withLock(directory.appendingPathComponent("backup_media.mutex")) { try media.write(bytes, limit: ScreenshotSpecs.maximumBytes) }
            let base = MediaReadPolicy.exportName(original.fileName, extension: "png").dropLast(4)
            let file = try AssetLibrary.File(.object([("id", .string(UUID().uuidString.lowercased())), ("fileName", .string(String(base) + "-edited.png")), ("hash", .string(stored.hash)), ("extension", .string("png")), ("category", .string(original.category.rawValue)), ("kind", .string("image")), ("referenceName", .string(original.referenceName)), ("size", .number(Double(bytes.count))), ("width", .number(Double(image.width))), ("height", .number(Double(image.height))), ("hasAlpha", .bool(false)), ("hasAudio", .bool(false)), ("duration", .null), ("frameRate", .null), ("timeCode", .null)]))
            try storeAccess { try $0.insertIfAbsent(namespace: "asset_library_files", key: prefix + file.id, json: file.json.data) }; return file
        }
    }
    /// Saves a PNG made on this Mac, such as a card from Create Media, as a new local original. Nothing is uploaded.
    public func stageCreatedLibraryImage(accountId: String, appId: String, bytes: Data, fileName: String, referenceName: String) throws -> AssetLibrary.File {
        let prefix = try libraryFilePrefix(accountId, appId), directory = try storeAccess { $0.directory }
        let image = try ScreenshotSpecs.validate(bytes)
        guard image.contentType == "image/png", (try? ScreenshotEditing.inspect(bytes))?.transparent == false,
              let source = CGImageSourceCreateWithData(bytes as CFData, nil), CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { throw AssetLibrary.failure("The created image could not be verified.") }
        return try FileMutex.withLock(directory.appendingPathComponent("asset_library_files.mutex")) {
            let stored = try FileMutex.withLock(directory.appendingPathComponent("backup_media.mutex")) { try media.write(bytes, limit: ScreenshotSpecs.maximumBytes) }
            let file = try AssetLibrary.File(.object([("id", .string(UUID().uuidString.lowercased())), ("fileName", .string(MediaReadPolicy.exportName(fileName, extension: "png"))), ("hash", .string(stored.hash)), ("extension", .string("png")), ("category", .string(AssetLibrary.Category.listing.rawValue)), ("kind", .string("image")), ("referenceName", .string(referenceName)), ("size", .number(Double(bytes.count))), ("width", .number(Double(image.width))), ("height", .number(Double(image.height))), ("hasAlpha", .bool(false)), ("hasAudio", .bool(false)), ("duration", .null), ("frameRate", .null), ("timeCode", .null)]))
            try storeAccess { try $0.insertIfAbsent(namespace: "asset_library_files", key: prefix + file.id, json: file.json.data) }; return file
        }
    }
    private func libraryFilePrefix(_ account: String, _ app: String) throws -> String {
        try requireHistoryScope(accountId: account, appId: app); return "\(account):\(app):"
    }
    public func assetLibraryFiles(accountId: String, appId: String) throws -> [AssetLibrary.File] {
        let prefix = try libraryFilePrefix(accountId, appId)
        return try storeAccess { store in try store.documents(namespace: "asset_library_files", prefix: prefix).map { document in
            let file = try AssetLibrary.File(JSONText.parse(document.payload))
            guard document.key == prefix + file.id, try media.metadata(file.hash) == file.size else { throw AssetLibrary.failure("The saved library file changed.") }; return file
        } }
    }
    func libraryFile(accountId: String, appId: String, id: String) throws -> AssetLibrary.File {
        guard AssetLibrary.validID(id) else { throw AssetLibrary.failure("Choose a saved local asset.") }
        let key = try libraryFilePrefix(accountId, appId) + id
        guard let document = try storeAccess({ try $0.document(namespace: "asset_library_files", key: key) }) else { throw AssetLibrary.failure("The reviewed local asset is no longer saved.") }
        return try AssetLibrary.File(JSONText.parse(document.payload))
    }
    public func stageAssetLibraryFile(accountId: String, appId: String, url: URL, category: AssetLibrary.Category, name: String, timeCode: String? = nil) async throws -> AssetLibrary.File {
        _ = try libraryFilePrefix(accountId, appId)
        let lease = try lifetime.admit(.transfer); defer { lease.finish() }
        return try await SessionContext.$lease.withValue(lease) {
            let media = self.media, directory = try storeAccess { $0.directory }, access = sessionRequestCheck()
            let worker = Task.detached {
                try SessionContext.$lease.withValue(lease) {
                try access()
                let (metadata, size) = try AssetLibrary.File.inspect(url, category: category, name: name, timeCode: timeCode)
                let written = try FileMutex.withLock(directory.appendingPathComponent("backup_media.mutex")) { try media.write(fileAt: url, limit: size, expectedSize: size) }
                try Task.checkCancellation(); try access()
                guard metadata["sourceHash"]?.text == written.hash else { throw AssetLibrary.failure("The selected file changed after validation. Choose it again.") }
                guard case .object(let fields) = metadata else { throw EncryptedMediaStore.Failure.invalid }
                return try AssetLibrary.File(.object(fields.filter { $0.0 != "sourceHash" } + [("id", .string(UUID().uuidString.lowercased())), ("hash", .string(written.hash)), ("size", .number(Double(size)))]))
                }
            }
            let file = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            try Task.checkCancellation()
            let prefix = try libraryFilePrefix(accountId, appId)
            try FileMutex.withLock(directory.appendingPathComponent("asset_library_files.mutex")) {
                try storeAccess { store in try store.insertIfAbsent(namespace: "asset_library_files", key: prefix + file.id, json: file.json.data) }
            }
            return file
        }
    }
    public func removeAssetLibraryFile(accountId: String, appId: String, id: String) throws {
        let prefix = try libraryFilePrefix(accountId, appId), directory = try storeAccess { $0.directory }
        let publishing = "publishing_" + JSONText.string("\(accountId)\u{0}\(appId)").rawSHA256.prefix(48)
        guard let release = try JobLock.acquire(directory: directory, name: String(publishing), id: UUID().uuidString.lowercased()) else { throw PublishFailure.busy }; defer { release() }
        try FileMutex.withLock(directory.appendingPathComponent("asset_library_files.mutex")) {
            _ = try libraryFile(accountId: accountId, appId: appId, id: id)
            try storeAccess { try $0.delete(namespace: "asset_library_files", key: prefix + id) }
        }
    }
    func describeLibraryFile(accountId: String, appId: String, id: String) throws -> JSONText {
        let file = try libraryFile(accountId: accountId, appId: appId, id: id)
        guard try media.metadata(file.hash) == file.size else { throw AssetLibrary.failure("The reviewed local asset changed size.") }
        var hash = SHA256()
        try media.stream(file.hash) { hash.update(data: $0) }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == file.hash else { throw EncryptedMediaStore.Failure.authentication }
        return .object([("storage", .string("asset-library")), ("fileId", .string(id)), ("hash", .string(file.hash)), ("fileName", .string(file.fileName)), ("size", .number(Double(file.size)))])
    }
    func uploadLibraryFile(_ asset: JSONText, operations: JSONValue?, accountId: String, appId: String, client: AppStoreConnectClient) async throws {
        guard let id = asset["fileId"]?.text, try describeLibraryFile(accountId: accountId, appId: appId, id: id) == asset else { throw AssetLibrary.failure("The reviewed local asset changed.") }
        let file = try libraryFile(accountId: accountId, appId: appId, id: id)
        let parts = try BuildUploadOperation.validate(operations, size: file.size)
        PublishTransfer.shared.begin(file.fileName, total: Int64(file.size)); defer { PublishTransfer.shared.end() }
        for operation in parts {
            try await client.uploadBuildPart(operation, media: media, hash: file.hash)
            PublishTransfer.shared.partFinished(Int64(operation.range.count))
        }
    }
}
