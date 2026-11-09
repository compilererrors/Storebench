import Foundation

/// The files approved Saves are uploading now, with their combined bytes sent and speed. It lives only in memory; after a restart
/// the saved review shows each file's stage instead.
public final class PublishTransfer: @unchecked Sendable {
    public static let shared = PublishTransfer()
    public struct Snapshot: Sendable, Equatable {
        public let fileName: String
        public let sent, total: Int64
        /// Bytes per second over the last few seconds; nil until there is enough to measure.
        public let bytesPerSecond: Double?
        /// For example "07-pricing.png · 1.2 of 2.4 MB · 2.3 MB/s".
        public var text: String {
            let style = ByteCountFormatter.CountStyle.decimal
            var parts = [fileName, "\(ByteCountFormatter.string(fromByteCount: sent, countStyle: style)) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: style))"]
            if let bytesPerSecond { parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: style) + "/s") }
            return parts.joined(separator: " · ")
        }
    }
    private struct FileTransfer {
        let fileName: String, total: Int64
        var finished: Int64 = 0, current: Int64 = 0
        var samples: [(time: TimeInterval, bytes: Int64)]
        var sent: Int64 { min(total, finished + current) }
    }
    private let lock = NSLock()
    private var files: [UUID: FileTransfer] = [:]
    private var legacy: UUID?
    private let clock: @Sendable () -> TimeInterval

    init(clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) { self.clock = clock }

    @discardableResult func begin(_ fileName: String, total: Int64) -> UUID {
        lock.withLock {
            let id = UUID(); files[id] = FileTransfer(fileName: fileName, total: total, samples: [(clock(), 0)])
            legacy = id; return id
        }
    }
    /// Each upload owns its meter, so another file's progress or completion cannot overwrite it.
    func sending(_ bytes: Int64, id: UUID? = nil) {
        lock.withLock { guard let id = id ?? legacy, files[id] != nil else { return }; files[id]?.current = max(0, bytes); record(id) }
    }
    func partFinished(_ bytes: Int64, id: UUID? = nil) {
        lock.withLock { guard let id = id ?? legacy, files[id] != nil else { return }; files[id]?.finished += max(0, bytes); files[id]?.current = 0; record(id) }
    }
    func end(_ id: UUID? = nil) {
        lock.withLock { guard let id = id ?? legacy else { return }; files.removeValue(forKey: id); if legacy == id { legacy = nil } }
    }

    public func snapshot() -> Snapshot? {
        lock.withLock {
            guard !files.isEmpty else { return nil }
            var speed = 0.0, measured = false
            for file in files.values {
                if let first = file.samples.first, let last = file.samples.last, last.time - first.time >= 0.5 {
                    speed += max(0, Double(last.bytes - first.bytes) / (last.time - first.time)); measured = true
                }
            }
            let name = files.count == 1 ? files.values.first!.fileName : "\(files.count) files"
            return Snapshot(fileName: name, sent: files.values.reduce(0) { $0 + $1.sent }, total: files.values.reduce(0) { $0 + $1.total }, bytesPerSecond: measured ? speed : nil)
        }
    }
    /// Keeps about five seconds of samples for each file.
    private func record(_ id: UUID) {
        guard var file = files[id] else { return }
        let now = clock(); file.samples.append((now, file.sent))
        while file.samples.count > 2, now - file.samples[1].time > 5 { file.samples.removeFirst() }
        files[id] = file
    }
}

/// Reports an upload part's progress and, like the API client, never follows a redirect.
final class TransferMeter: NSObject, URLSessionTaskDelegate, Sendable {
    let transfer: PublishTransfer
    let transferId: UUID?
    init(_ transfer: PublishTransfer, id: UUID? = nil) { self.transfer = transfer; transferId = id }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? { nil }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        if let transferId { transfer.sending(totalBytesSent, id: transferId) }
    }
}
