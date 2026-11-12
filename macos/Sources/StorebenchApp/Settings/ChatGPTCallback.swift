import AppKit
import Foundation
import Network
import StorebenchCore

@MainActor protocol ChatGPTSignInReceiving: AnyObject {
    func start() async throws -> URL
    func wait() async throws -> URL
    func cancel()
}

@MainActor struct ChatGPTSignInServices {
    var receiver: (String) -> any ChatGPTSignInReceiving
    var openBrowser: (URL) -> Bool
    static let live = Self(receiver: { ChatGPTCallback(state: $0) }, openBrowser: { NSWorkspace.shared.open($0) })
}

/// A short-lived browser callback bound only to the loopback interface.
@MainActor final class ChatGPTCallback: ChatGPTSignInReceiving {
    private let state: String
    private var listener: NWListener?
    private var port: UInt16 = 0
    private var ready: CheckedContinuation<Void, Error>?
    private var waiter: CheckedContinuation<URL, Error>?
    private var result: Result<URL, Error>?
    private var timeout: Task<Void, Never>?
    private var connections: [UUID: (NWConnection, Task<Void, Never>)] = [:]
    init(state: String) { self.state = state }
    func start() async throws -> URL {
        guard ProcessInfo.processInfo.environment["STOREBENCH_TEST_MODE"] != "1" else { throw AIFailure.configuration }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let server: NWListener
        do { server = try NWListener(using: parameters) }
        catch { throw AIFailure.signInCallback }
        listener = server
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            if !Task.isCancelled { self?.finish(.failure(AIFailure.signInCallback)) }
        }
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                ready = continuation
                server.stateUpdateHandler = { [weak self] status in Task { @MainActor in
                    guard let self else { return }
                    switch status {
                    case .ready: self.ready?.resume(); self.ready = nil
                    case .waiting, .failed: self.finish(.failure(AIFailure.signInCallback))
                    case .cancelled: self.finish(.failure(CancellationError()))
                    default: break
                    }
                } }
                server.newConnectionHandler = { [weak self] connection in Task { @MainActor in self?.accept(connection) } }
                server.start(queue: .main)
            }
        }, onCancel: { Task { @MainActor in self.cancel() } })
        guard let number = server.port?.rawValue, number >= 1024 else { cancel(); throw AIFailure.signInCallback }
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: ChatGPTOAuth.signInLifetime)
            if !Task.isCancelled { self?.finish(.failure(AIFailure.signInExpired)) }
        }
        port = number; return URL(string: "http://127.0.0.1:\(number)/auth/callback")!
    }
    func wait() async throws -> URL {
        if let result { return try result.get() }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { waiter = $0 }
        }, onCancel: { Task { @MainActor in self.cancel() } })
    }
    func cancel() { finish(.failure(CancellationError())) }
    private func finish(_ value: Result<URL, Error>) {
        guard result == nil else { return }; result = value; timeout?.cancel(); listener?.cancel(); listener = nil
        if case .failure(let error) = value { ready?.resume(throwing: error) }
        else { ready?.resume() }
        ready = nil
        waiter?.resume(with: value); waiter = nil
        for (connection, timeout) in connections.values { timeout.cancel(); connection.cancel() }; connections.removeAll()
    }
    private func close(_ id: UUID) { if let (connection, timeout) = connections.removeValue(forKey: id) { timeout.cancel(); connection.cancel() } }
    private func accept(_ connection: NWConnection) {
        guard result == nil, connections.count < 6 else { connection.cancel(); return }
        let id = UUID()
        let timer = Task { [weak self] in try? await Task.sleep(for: .seconds(8)); if !Task.isCancelled { self?.close(id) } }
        connections[id] = (connection, timer); connection.start(queue: .main); receive(connection, id: id, bytes: Data())
    }
    private func receive(_ connection: NWConnection, id: UUID, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384 - bytes.count) { [weak self] part, _, complete, error in Task { @MainActor in
            guard let self, self.connections[id] != nil else { connection.cancel(); return }
            let data = bytes + (part ?? Data())
            guard error == nil, data.count < 16_384 else { self.close(id); return }
            guard data.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if complete { self.close(id) } else { self.receive(connection, id: id, bytes: data) }; return
            }
            guard let request = String(data: data, encoding: .utf8) else { self.close(id); return }
            let headers = request.components(separatedBy: "\r\n"), first = (headers.first ?? "").split(separator: " ")
            let hosts = headers.dropFirst().filter { $0.lowercased().hasPrefix("host:") }
            guard first.count == 3, first[0] == "GET", first[1].hasPrefix("/auth/callback?"),
                  hosts.count == 1, hosts[0].dropFirst(5).trimmingCharacters(in: .whitespaces) == "127.0.0.1:\(self.port)",
                  let callback = URL(string: "http://127.0.0.1:\(self.port)" + first[1]),
                  let query = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems,
                  query.filter({ $0.name == "state" }).count == 1, query.first(where: { $0.name == "state" })?.value == self.state else { self.close(id); return }
            self.connections.removeValue(forKey: id)?.1.cancel()
            let body = "<!doctype html><meta charset=utf-8><title>Storebench</title><p>Sign-in returned to Storebench. You can close this tab.</p>"
            let reply = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nContent-Security-Policy: default-src 'none'\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
            connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
            self.finish(.success(callback))
        } }
    }
}
