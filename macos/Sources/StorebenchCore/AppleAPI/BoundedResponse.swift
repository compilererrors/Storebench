import Foundation

enum BoundedResponse {
    enum Failure: Error, Equatable { case tooLarge, invalidResponse }
    struct Result: @unchecked Sendable { let data: Data, response: HTTPURLResponse }

    /// Checks incoming bytes before appending them. Content-Length is only an early rejection hint.
    static func read(_ request: URLRequest, configuration: URLSessionConfiguration, maximumBytes: Int,
                     check: @escaping @Sendable (HTTPURLResponse) throws -> Void = { _ in }) async throws -> Result {
        guard maximumBytes > 0, maximumBytes <= 500_000_000 else { throw Failure.tooLarge }
        let delegate = Reader(maximum: maximumBytes, check: check)
        let session = URLSession(configuration: Network.guarded(configuration), delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: request)
        defer { session.invalidateAndCancel() }
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in delegate.start(continuation); task.resume() }
        }, onCancel: { task.cancel() })
    }

    /// One long-lived URLSession whose connections are reused by every request sent through it, instead of a new connection per request.
    /// Each request still has its own byte limit and response check, and redirects are refused.
    final class Pool: @unchecked Sendable {
        private let router = Router()
        let session: URLSession
        init(configuration: URLSessionConfiguration) {
            session = URLSession(configuration: Network.guarded(configuration), delegate: router, delegateQueue: nil)
        }
        deinit { session.finishTasksAndInvalidate() }

        func read(_ request: URLRequest, maximumBytes: Int, check: @escaping @Sendable (HTTPURLResponse) throws -> Void = { _ in }) async throws -> Result {
            guard maximumBytes > 0, maximumBytes <= 500_000_000 else { throw Failure.tooLarge }
            let delegate = Reader(maximum: maximumBytes, check: check, owned: false)
            let task = session.dataTask(with: request)
            router.add(delegate, for: task)
            return try await withTaskCancellationHandler(operation: {
                do { try Task.checkCancellation() } catch { router.remove(task); throw error }
                return try await withCheckedThrowingContinuation { continuation in delegate.start(continuation); task.resume() }
            }, onCancel: { task.cancel() })
        }
    }

    /// Hands each task's callbacks to that task's reader.
    private final class Router: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var readers: [Int: Reader] = [:]
        func add(_ reader: Reader, for task: URLSessionTask) { lock.withLock { readers[task.taskIdentifier] = reader } }
        @discardableResult func remove(_ task: URLSessionTask) -> Reader? { lock.withLock { readers.removeValue(forKey: task.taskIdentifier) } }
        private func reader(_ task: URLSessionTask) -> Reader? { lock.withLock { readers[task.taskIdentifier] } }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            guard let reader = reader(dataTask) else { completionHandler(.cancel); return }
            reader.urlSession(session, dataTask: dataTask, didReceive: response, completionHandler: completionHandler)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) { reader(dataTask)?.urlSession(session, dataTask: dataTask, didReceive: data) }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { remove(task)?.urlSession(session, task: task, didCompleteWithError: error) }
    }

    private final class Reader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let maximum: Int, check: @Sendable (HTTPURLResponse) throws -> Void
        /// Whether the reader's session belongs to this one request and ends with it.
        let owned: Bool
        private let lock = NSLock()
        private var bytes = Data(), response: HTTPURLResponse?, failure: Error?
        private var continuation: CheckedContinuation<Result, Error>?
        init(maximum: Int, check: @escaping @Sendable (HTTPURLResponse) throws -> Void, owned: Bool = true) { self.maximum = maximum; self.check = check; self.owned = owned }
        func start(_ continuation: CheckedContinuation<Result, Error>) { lock.withLock { self.continuation = continuation } }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            do {
                guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
                guard http.expectedContentLength <= maximum else { throw Failure.tooLarge }
                try check(http)
                lock.withLock { self.response = http }; completionHandler(.allow)
            } catch { lock.withLock { failure = error }; completionHandler(.cancel) }
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            let overflow = lock.withLock {
                guard failure == nil, data.count <= maximum - bytes.count else { failure = Failure.tooLarge; return true }
                bytes.append(data); return false
            }
            if overflow { dataTask.cancel() }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let state = lock.withLock { let pending = continuation; continuation = nil; return (pending, failure ?? error, response, bytes) }
            defer { if owned { session.finishTasksAndInvalidate() } }
            if let error = state.1 { state.0?.resume(throwing: error) }
            else if let response = state.2 { state.0?.resume(returning: Result(data: state.3, response: response)) }
            else { state.0?.resume(throwing: Failure.invalidResponse) }
        }
    }
}
