import Darwin
import Foundation
import zlib

/// File limits shared by report imports. No filename or extension establishes a report's format.
public enum ReportFiles {
    public enum Purpose: Sendable {
        case sales, reports, keywords
        var files: Int { self == .reports ? 20 : 1 }
        var fileBytes: Int { self == .sales ? 4_000_000 : self == .keywords ? 8_100_000 : 10_000_000 }
        var packedBytes: Int { self == .sales ? 4_000_000 : self == .keywords ? 8_100_000 : 10_100_000 }
        var expandedBytes: Int { self == .sales ? 8_000_000 : 10_000_000 }
    }
    public enum Failure: Error, Equatable {
        case format, size, read, write
        public var message: String {
            switch self {
            case .format: "Choose a UTF-8 report file with valid compression."
            case .size: "The selected reports exceed the supported file or expanded size."
            case .read: "The selected report could not be read. Choose a regular report file and retry."
            case .write: "The report export could not be completed. The existing destination file has not been replaced."
            }
        }
    }

    /// Bounds actual bytes while reading, including a file that grows after its size was checked.
    public static func read(_ urls: [URL], purpose: Purpose) throws -> [Data] {
        guard (1...purpose.files).contains(urls.count) else { throw Failure.format }
        var files: [Data] = [], total = 0
        for url in urls {
            try Task.checkCancellation(); try TestIsolation.check(url)
            let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw Failure.read }
            defer { close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw Failure.read }
            guard info.st_size > 0, info.st_size <= purpose.fileBytes else { throw Failure.size }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                try Task.checkCancellation()
                let remaining = min(purpose.fileBytes - data.count, purpose.packedBytes - total)
                let wanted = min(buffer.count, remaining + 1)
                let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!, wanted) }
                if count < 0 { if errno == EINTR { continue }; throw Failure.read }
                if count == 0 { break }
                guard count <= remaining else { throw Failure.size }
                data.append(contentsOf: buffer.prefix(count)); total += count
            }
            guard !data.isEmpty else { throw Failure.format }
            files.append(data)
        }
        return files
    }

    public static func readAsync(_ urls: [URL], purpose: Purpose) async throws -> [Data] {
        try Task.checkCancellation()
        let owned = Task.detached { try read(urls, purpose: purpose) }
        return try await withTaskCancellationHandler(operation: { try await owned.value }, onCancel: { owned.cancel() })
    }

    /// Detects gzip by its bytes, validates its trailer and all concatenated members, then validates UTF-8.
    public static func texts(_ files: [Data], purpose: Purpose) throws -> [String] {
        guard (1...purpose.files).contains(files.count) else { throw Failure.format }
        var packed = 0, expanded = 0, result: [String] = []
        for file in files {
            try Task.checkCancellation()
            guard !file.isEmpty else { throw Failure.format }
            packed += file.count
            guard file.count <= purpose.fileBytes, packed <= purpose.packedBytes else { throw Failure.size }
            guard expanded < purpose.expandedBytes else { throw Failure.size }
            let bytes = try unpack(file, limit: purpose.expandedBytes - expanded)
            expanded += bytes.count
            result.append(try utf8(bytes, stripBom: purpose != .sales))
        }
        return result
    }

    static func utf8(_ bytes: Data, stripBom: Bool) throws -> String {
        let text = String(decoding: bytes, as: UTF8.self)
        // Reject repaired UTF-8 on every supported macOS version and strip only the requested leading BOM.
        guard text.utf8.elementsEqual(bytes) else { throw Failure.format }
        return stripBom && text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    }

    /// Writes an owned temporary file beside the destination, then atomically replaces it only after every chunk succeeds.
    static func atomicStream(to url: URL, _ operation: ((Data) throws -> Void) throws -> Void) throws {
        try TestIsolation.check(url); try Task.checkCancellation()
        var info = stat()
        if lstat(url.path, &info) == 0 { guard info.st_mode & S_IFMT == S_IFREG else { throw Failure.write } }
        else { guard errno == ENOENT else { throw Failure.write } }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".storebench-export-\(UUID().uuidString).tmp")
        try TestIsolation.check(temporary)
        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Failure.write }
        var committed = false
        defer { close(descriptor); if !committed { unlink(temporary.path) } }
        try operation { data in
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    try Task.checkCancellation()
                    let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), min(64 * 1024, bytes.count - offset))
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw Failure.write }
                    offset += count
                }
            }
        }
        try Task.checkCancellation()
        guard fsync(descriptor) == 0, rename(temporary.path, url.path) == 0 else { throw Failure.write }
        committed = true
    }

    static func unpack(_ data: Data, limit: Int) throws -> Data {
        guard limit >= 0 else { throw Failure.size }
        guard data.count >= 2, data[data.startIndex] == 0x1f, data[data.startIndex + 1] == 0x8b else {
            guard data.count <= limit else { throw Failure.size }; return data
        }
        var input = Array(data), output = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
        return try input.withUnsafeMutableBufferPointer { source in
            var cursor = 0
            while cursor < source.count {
                try Task.checkCancellation()
                // zlib permits zero padding after the gzip stream.
                if source[cursor] == 0 { break }
                var stream = z_stream()
                guard inflateInit2_(&stream, MAX_WBITS + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw Failure.format }
                defer { inflateEnd(&stream) }
                stream.next_in = source.baseAddress!.advanced(by: cursor); stream.avail_in = uInt(source.count - cursor)
                var status = Z_OK
                while status == Z_OK {
                    try Task.checkCancellation()
                    let before = stream.avail_in
                    let produced = buffer.withUnsafeMutableBufferPointer { target in
                        stream.next_out = target.baseAddress; stream.avail_out = uInt(target.count)
                        status = inflate(&stream, Z_NO_FLUSH)
                        return target.count - Int(stream.avail_out)
                    }
                    guard produced <= limit - output.count else { throw Failure.size }
                    output.append(contentsOf: buffer.prefix(produced))
                    if status == Z_OK, produced == 0, stream.avail_in == before { throw Failure.format }
                }
                guard status == Z_STREAM_END else { throw Failure.format }
                let next = source.count - Int(stream.avail_in)
                guard next > cursor else { throw Failure.format }
                cursor = next
            }
            return output
        }
    }

    public static func gzip(_ data: Data) throws -> Data {
        guard data.count <= Int(uInt.max) else { throw Failure.size }
        var stream = z_stream(), input = Array(data), output = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, MAX_WBITS + 16, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw Failure.format }
        defer { deflateEnd(&stream) }
        return try input.withUnsafeMutableBufferPointer { source in
            stream.next_in = source.baseAddress; stream.avail_in = uInt(source.count)
            var status = Z_OK
            while status == Z_OK {
                try Task.checkCancellation()
                let produced = buffer.withUnsafeMutableBufferPointer { target in
                    stream.next_out = target.baseAddress; stream.avail_out = uInt(target.count)
                    status = deflate(&stream, Z_FINISH)
                    return target.count - Int(stream.avail_out)
                }
                output.append(contentsOf: buffer.prefix(produced))
            }
            guard status == Z_STREAM_END else { throw Failure.format }
            return output
        }
    }
}
