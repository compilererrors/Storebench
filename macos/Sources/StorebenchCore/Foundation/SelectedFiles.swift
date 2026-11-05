import Darwin
import Foundation

/// Reads user-selected files without trusting their initial size or exposing partially read batches.
public enum SelectedFiles {
    public enum Purpose: Sendable {
        case transfer, screenshots, screenshotEditing, encryptionDocument, reviewAttachment
        var limits: Limits {
            switch self {
            case .transfer: Limits(fileBytes: 4_000_000, totalBytes: 4_000_000, files: 1)
            case .screenshots: Limits(fileBytes: ScreenshotSpecs.maximumBytes, totalBytes: ScreenshotSpecs.maximumBatchBytes, files: ScreenshotSpecs.maximum)
            case .screenshotEditing: Limits(fileBytes: ScreenshotEditing.maximumSourceBytes, totalBytes: ScreenshotEditing.maximumSourceBytes * ScreenshotSpecs.maximum, files: ScreenshotSpecs.maximum)
            case .encryptionDocument: Limits(fileBytes: StagedEncryptionDocument.maximumBytes, totalBytes: StagedEncryptionDocument.maximumBytes, files: 1)
            case .reviewAttachment: Limits(fileBytes: ReviewAttachment.maximumBytes, totalBytes: ReviewAttachment.maximumBytes, files: 1)
            }
        }
    }
    public enum Failure: Error, Equatable { case read, fileSize, batchSize, count, encoding }
    public struct File: Sendable { public let name: String; public let data: Data }
    public struct ReadProgress: Sendable, Equatable {
        public let completedFiles, totalFiles, bytesRead, currentFileBytes, currentFileSize: Int
        public var fraction: Double {
            guard totalFiles > 0 else { return 0 }
            let current = currentFileSize > 0 ? min(0.99, Double(currentFileBytes) / Double(currentFileSize)) : 0
            return min(1, Double(completedFiles) / Double(totalFiles) + current / Double(totalFiles))
        }
    }
    struct Limits: Sendable { let fileBytes, totalBytes, files: Int }

    public static func read(_ urls: [URL], purpose: Purpose) throws -> [File] {
        try read(urls, limits: purpose.limits, afterMetadata: { _ in })
    }

    public static func readAsync(_ urls: [URL], purpose: Purpose,
                                 progress: @escaping @MainActor @Sendable (ReadProgress) -> Void = { _ in }) async throws -> [File] {
        try Task.checkCancellation()
        let (updates, continuation) = AsyncStream<ReadProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let owned = Task.detached {
            defer { continuation.finish() }
            return try read(urls, limits: purpose.limits, afterMetadata: { _ in }, progress: { continuation.yield($0) })
        }
        return try await withTaskCancellationHandler(operation: {
            for await update in updates {
                try Task.checkCancellation(); await progress(update)
            }
            let result = try await owned.value
            try Task.checkCancellation(); return result
        }, onCancel: { owned.cancel() })
    }

    /// UTF-8 text files may have one leading BOM, which the CSV reader allows.
    public static func text(_ data: Data) throws -> String {
        do { return try ReportFiles.utf8(data, stripBom: true) }
        catch { throw Failure.encoding }
    }

    /// The guarded fixture callback can grow or replace an owned file after fstat, before its bytes are read.
    static func readFixture(_ urls: [URL], limits: Limits, afterMetadata: (URL) throws -> Void) throws -> [File] {
        _ = try TestIsolation.require()
        return try read(urls, limits: limits, afterMetadata: afterMetadata)
    }

    private static func read(_ urls: [URL], limits: Limits, afterMetadata: (URL) throws -> Void, progress: (ReadProgress) -> Void = { _ in }) throws -> [File] {
        try Task.checkCancellation()
        guard limits.files > 0, (1...limits.files).contains(urls.count) else { throw Failure.count }
        guard limits.fileBytes > 0, limits.fileBytes < Int.max, limits.totalBytes > 0, limits.totalBytes < Int.max else { throw Failure.fileSize }
        var result: [File] = [], total = 0
        progress(.init(completedFiles: 0, totalFiles: urls.count, bytesRead: 0, currentFileBytes: 0, currentFileSize: 0))
        for url in urls {
            try Task.checkCancellation()
            guard url.isFileURL, !url.path.contains("\0") else { throw Failure.read }
            try TestIsolation.check(url)
            let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw Failure.read }
            defer { close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw Failure.read }
            guard info.st_size > 0, info.st_size <= limits.fileBytes else { throw Failure.fileSize }
            guard info.st_size <= limits.totalBytes - total else { throw Failure.batchSize }
            try afterMetadata(url)
            var data = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                try Task.checkCancellation()
                let remainingFile = limits.fileBytes - data.count, remainingBatch = limits.totalBytes - total
                let wanted = min(buffer.count, min(remainingFile, remainingBatch) + 1)
                let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!, wanted) }
                if count < 0 { if errno == EINTR { continue }; throw Failure.read }
                if count == 0 { break }
                guard count <= remainingFile else { throw Failure.fileSize }
                guard count <= remainingBatch else { throw Failure.batchSize }
                data.append(contentsOf: buffer.prefix(count)); total += count
                progress(.init(completedFiles: result.count, totalFiles: urls.count, bytesRead: total, currentFileBytes: data.count, currentFileSize: Int(info.st_size)))
            }
            guard !data.isEmpty else { throw Failure.fileSize }
            result.append(File(name: url.lastPathComponent, data: data))
            progress(.init(completedFiles: result.count, totalFiles: urls.count, bytesRead: total, currentFileBytes: 0, currentFileSize: 0))
        }
        return result
    }
}
