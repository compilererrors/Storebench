import Foundation

/// The file an approved Save is uploading now, with its bytes sent and speed. It lives only in memory; after a restart
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
    private let lock = NSLock()
    private var fileName: String?
    private var total: Int64 = 0, finished: Int64 = 0, current: Int64 = 0
    private var samples: [(time: TimeInterval, bytes: Int64)] = []
    private let clock: @Sendable () -> TimeInterval

    init(clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) { self.clock = clock }

    func begin(_ fileName: String, total: Int64) {
        lock.withLock { self.fileName = fileName; self.total = total; finished = 0; current = 0; samples = [(clock(), 0)] }
    }
    /// Bytes of the part being sent now, as URLSession reports them.
    func sending(_ bytes: Int64) { lock.withLock { current = bytes; record() } }
    func partFinished(_ bytes: Int64) { lock.withLock { finished += bytes; current = 0; record() } }
    func end() { lock.withLock { fileName = nil; samples = [] } }

    public func snapshot() -> Snapshot? {
        lock.withLock {
            guard let fileName else { return nil }
            let sent = min(total, finished + current)
            var speed: Double?
            if let first = samples.first, let last = samples.last, last.time - first.time >= 0.5 { speed = Double(last.bytes - first.bytes) / (last.time - first.time) }
            return Snapshot(fileName: fileName, sent: sent, total: total, bytesPerSecond: speed)
        }
    }
    /// Keeps about five seconds of samples, so the speed follows the current connection.
    private func record() {
        let now = clock()
        samples.append((now, finished + current))
        while samples.count > 2, now - samples[1].time > 5 { samples.removeFirst() }
    }
}

/// Reports an upload part's progress and, like the API client, never follows a redirect.
final class TransferMeter: NSObject, URLSessionTaskDelegate, Sendable {
    let transfer: PublishTransfer
    init(_ transfer: PublishTransfer) { self.transfer = transfer }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? { nil }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) { transfer.sending(totalBytesSent) }
}
