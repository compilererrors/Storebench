import Darwin
import Foundation

struct BuildUploadOperation: Sendable {
    let url: URL, range: Range<Int>, headers: [(String, String)]
    static func validate(_ value: JSONValue?, size: Int) throws -> [Self] {
        guard size > 0, size <= StagedBuildPackage.maximumBytes, case .array(let items)? = value, !items.isEmpty, items.count <= 1000 else { throw PublishFailure.write("Apple returned no valid upload operations.") }
        var parts: [Self] = []
        // Says which part of Apple's operation is not accepted, without its signed address.
        func unsupported(_ reason: String) -> PublishFailure { .write("Apple returned an unsupported upload operation: \(reason). Nothing was uploaded for this file; prepare a new review.") }
        for item in items {
            guard case .object(let operation) = item else { throw unsupported("an entry that is not an operation") }
            let method = operation["method"]?.string ?? ""
            guard method == "PUT" else { throw unsupported(method.isEmpty ? "no upload method" : "method \(String(method.prefix(12)))") }
            guard let text = operation["url"]?.string, let url = URLComponents(string: text), url.scheme == "https", url.user == nil, url.password == nil,
                  url.port == nil || url.port == 443, url.fragment == nil, let host = url.host?.lowercased(), let target = url.url else { throw unsupported("an upload address that is not a plain HTTPS address") }
            // Apple's upload operations point at Apple-owned storage; the exact host varies by service.
            guard host.hasSuffix(".apple.com"), host.range(of: "^[a-z0-9.-]{1,253}$", options: .regularExpression) != nil else {
                throw unsupported("an upload host outside apple.com (\(String(host.filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }.prefix(80))))")
            }
            guard case .number(let offset)? = operation["offset"], case .number(let length)? = operation["length"],
                  offset.isFinite, length.isFinite, offset.rounded() == offset, length.rounded() == length, offset >= 0, offset < Double(size), length >= 1, length <= Double(size) - offset else {
                throw unsupported("a byte range outside the \(size)-byte file")
            }
            // Apple documents request headers as a list; an operation without any needs none.
            let values: [JSONValue]
            switch operation["requestHeaders"] {
            case nil, .null?: values = []
            case .array(let list)?: values = list
            default: throw unsupported("request headers that are not a list")
            }
            var headers: [(String, String)] = [], names = Set<String>()
            for header in values {
                guard case .object(let pair) = header, let name = pair["name"]?.string, let value = pair["value"]?.string,
                      name.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil, names.insert(name.lowercased()).inserted,
                      !value.contains("\r"), !value.contains("\n"), !["authorization", "cookie", "host", "origin", "proxy-authorization", "transfer-encoding"].contains(name.lowercased()),
                      name.lowercased() != "content-length" || value == String(Int(length)) else { throw PublishFailure.write("Apple returned unsafe upload headers.") }
                headers.append((name, value))
            }
            parts.append(Self(url: target, range: Int(offset)..<Int(offset + length), headers: headers))
        }
        parts.sort { $0.range.lowerBound < $1.range.lowerBound }
        var covered = 0
        for part in parts { guard part.range.lowerBound == covered else { throw PublishFailure.write("Apple upload operations do not cover the complete file.") }; covered = part.range.upperBound }
        guard covered == size else { throw PublishFailure.write("Apple upload operations do not cover the complete file.") }
        return parts
    }
}

/// Foundation consumes a bounded memory stream. The producer decrypts one media chunk at a time;
/// neither a plaintext temporary file nor a complete Apple upload part is allocated.
private final class EncryptedUploadPump: @unchecked Sendable {
    let input: InputStream, output: OutputStream
    private let condition = NSCondition()
    private var cancelled = false, finished = false
    private var failure: Error?
    init(media: EncryptedMediaStore, hash: String, range: Range<Int>) throws {
        var reader: InputStream?, writer: OutputStream?
        Stream.getBoundStreams(withBufferSize: 64 * 1024, inputStream: &reader, outputStream: &writer)
        guard let reader, let writer else { throw PublishFailure.write("The encrypted upload stream could not be opened.") }
        input = reader; output = writer
        Thread.detachNewThread { [self] in
            output.open(); defer { output.close() }
            let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(600))
            do {
                var sent = 0
                try media.stream(hash, range: range) { chunk in
                    try chunk.withUnsafeBytes { bytes in
                        var offset = 0
                        while offset < bytes.count {
                            guard !condition.withLock({ cancelled }), clock.now < deadline else { throw CancellationError() }
                            guard output.streamStatus != .error, output.streamStatus != .closed else { throw PublishFailure.write("Apple stopped reading the build upload.") }
                            guard output.hasSpaceAvailable else { usleep(2_000); continue }
                            let count = output.write(bytes.baseAddress!.assumingMemoryBound(to: UInt8.self).advanced(by: offset), maxLength: min(16 * 1024, bytes.count - offset))
                            guard count >= 0 else { throw PublishFailure.write("The build upload stream failed.") }
                            if count == 0 { usleep(2_000); continue }
                            offset += count; sent += count
                        }
                    }
                }
                guard sent == range.count else { throw PublishFailure.write("The staged build changed while uploading.") }
                condition.withLock { finished = true; condition.broadcast() }
            } catch { condition.withLock { failure = error; finished = true; condition.broadcast() } }
        }
    }
    func cancel() { condition.withLock { cancelled = true } }
    func result() throws {
        condition.lock(); defer { condition.unlock() }
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(2))
        while !finished, clock.now < deadline { _ = condition.wait(until: Date().addingTimeInterval(0.02)) }
        guard finished else { throw PublishFailure.write("Apple did not consume the complete build upload.") }
        if let failure { throw failure }
    }
}

private final class BuildStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let media: EncryptedMediaStore, mediaHash: String, range: Range<Int>
    private let transferId: UUID?
    private var pump: EncryptedUploadPump?, initial = true
    private var continuation: CheckedContinuation<Void, Error>?
    private var responseSize = 0
    init(media: EncryptedMediaStore, hash: String, range: Range<Int>, transferId: UUID?) throws {
        self.media = media; self.mediaHash = hash; self.range = range; self.transferId = transferId
        pump = try EncryptedUploadPump(media: media, hash: hash, range: range)
    }
    var input: InputStream? { lock.withLock { pump?.input } }
    func start(_ continuation: CheckedContinuation<Void, Error>) { lock.withLock { self.continuation = continuation } }
    func cancel() { lock.withLock { pump?.cancel() } }
    func urlSession(_ session: URLSession, task: URLSessionTask, needNewBodyStream completionHandler: @escaping @Sendable (InputStream?) -> Void) {
        let stream: InputStream? = lock.withLock {
            if initial { initial = false; return pump?.input }
            pump?.cancel(); pump = try? EncryptedUploadPump(media: media, hash: mediaHash, range: range)
            return pump?.input
        }
        completionHandler(stream)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        if let transferId { PublishTransfer.shared.sending(totalBytesSent, id: transferId) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if lock.withLock({ responseSize += data.count; return responseSize > 1_000_000 }) { dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let state = lock.withLock { let value = continuation; continuation = nil; return (value, pump, responseSize) }
        defer { state.1?.cancel(); session.finishTasksAndInvalidate() }
        do {
            if let error { throw error }
            guard state.2 <= 1_000_000, let response = task.response as? HTTPURLResponse else { throw AppStoreConnectClient.Failure.unreadableResponse }
            guard (200..<300).contains(response.statusCode) else { throw AppStoreConnectClient.Failure.status(response.statusCode) }
            try state.1?.result()
            state.0?.resume()
        } catch { state.0?.resume(throwing: error) }
    }
}

extension AppStoreConnectClient {
    func uploadBuildPart(_ part: BuildUploadOperation, media: EncryptedMediaStore, hash: String, transferId: UUID? = nil) async throws {
        try accessCheck()
        let delegate = try BuildStreamDelegate(media: media, hash: hash, range: part.range, transferId: transferId)
        let configuration = session.configuration
        configuration.timeoutIntervalForRequest = 600; configuration.timeoutIntervalForResource = 600
        configuration.httpAdditionalHeaders = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false; configuration.urlCache = nil
        let uploadSession = URLSession(configuration: Network.guarded(configuration), delegate: delegate, delegateQueue: nil)
        defer { delegate.cancel(); uploadSession.invalidateAndCancel() }
        var request = URLRequest(url: part.url); request.httpMethod = "PUT"; request.timeoutInterval = 600
        request.httpShouldHandleCookies = false
        for (name, value) in part.headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue(String(part.range.count), forHTTPHeaderField: "Content-Length")
        request.httpBodyStream = delegate.input
        let task = uploadSession.uploadTask(withStreamedRequest: request)
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in delegate.start(continuation); task.resume() }
        }, onCancel: { delegate.cancel(); task.cancel() })
    }
}

extension WorkspaceSession {
    func uploadBuildPackage(_ asset: JSONText, operations: JSONValue?, accountId: String, appId: String, client: AppStoreConnectClient, grant: PublishGrant) async throws {
        guard grant.accountId == accountId, grant.appId == appId, let id = asset["packageId"]?.text,
              let package = try stagedBuildPackage(accountId: accountId, appId: appId, id: id), asset["hash"]?.text == package.sha256,
              asset["checksum"]?.text == package.sha256, asset["size"] == .number(Double(package.size)), asset["fileName"]?.text == package.fileName,
              asset["extension"]?.text == (package.uti == "com.apple.ipa" ? "ipa" : "pkg") else { throw PublishFailure.write("The reviewed build package changed.") }
        let parts = try BuildUploadOperation.validate(operations, size: package.size), media = try packageMedia(package.id)
        let validation = Task.detached { try media.stream(package.sha256) { _ in } }
        try await withTaskCancellationHandler(operation: { try await validation.value }, onCancel: { validation.cancel() })
        let transferId = PublishTransfer.shared.begin(package.fileName, total: Int64(package.size)); defer { PublishTransfer.shared.end(transferId) }
        for part in parts { try Task.checkCancellation(); try await client.uploadBuildPart(part, media: media, hash: package.sha256, transferId: transferId); PublishTransfer.shared.partFinished(Int64(part.range.count), id: transferId) }
    }
}
