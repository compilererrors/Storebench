import Foundation

struct ChatGPTRefreshFailure: Error { let terminal: Bool }

struct ChatGPTHTTP: Sendable {
    let pool: BoundedResponse.Pool
    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.httpShouldSetCookies = false; configuration.httpCookieStorage = nil; configuration.urlCache = nil
        pool = BoundedResponse.Pool(configuration: configuration)
    }
    func read(_ url: URL, fields: [String: String]? = nil, refresh: Bool = false, empty: Bool = false) async throws -> JSONText {
        guard url.scheme == "https", url.host == "auth.openai.com", url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { throw AIFailure.identity }
        var request = URLRequest(url: url); request.timeoutInterval = 20
        if let fields {
            request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
            request.httpBody = Data(fields.sorted { $0.key < $1.key }.map { key, value in
                key + "=" + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
            }.joined(separator: "&").utf8)
        }
        let response = try await pool.read(request, maximumBytes: 256_000)
        guard (200..<300).contains(response.response.statusCode) else {
            let code = (try? JSONText.parse(response.data))?["error"]?.text ?? ""
            if refresh {
                throw ChatGPTRefreshFailure(terminal: ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused"].contains(code))
            }
            if response.response.statusCode == 429 { throw AIFailure.subscriptionLimit }
            throw response.response.statusCode >= 500 ? AIFailure.subscriptionUnavailable : AIFailure.signIn
        }
        if empty && response.data.isEmpty { return .null }
        guard let value = try? JSONText.parse(response.data) else { throw AIFailure.response }; return value
    }
    func token(_ fields: [String: String], refresh: Bool = false) async throws -> JSONText {
        try await read(URL(string: "https://auth.openai.com/api/accounts/oauth/token")!, fields: fields, refresh: refresh)
    }
    func revoke(_ tokens: ChatGPTTokens) async -> Bool {
        for retry in 0..<2 {
            do {
                let config = try await read(URL(string: "https://auth.openai.com/.well-known/openid-configuration")!)
                guard let endpoint = config["revocation_endpoint"]?.text.flatMap(URL.init(string:)) else { return false }
                guard let refresh = tokens.refresh else { return true }
                _ = try await read(endpoint, fields: ["token": refresh, "token_type_hint": "refresh_token", "client_id": tokens.clientID], empty: true)
                return true
            } catch {
                if Task.isCancelled { return false }
                if retry == 0 { try? await Task.sleep(for: .milliseconds(300)) }
            }
        }
        return false
    }
}

enum ChatGPTEvents {
    static func failure(_ value: JSONText, status: Int? = nil) -> AIFailure {
        let code = value["response"]?["error"]?["code"]?.text ?? value["error"]?["code"]?.text ?? value["code"]?.text ?? ""
        switch code {
        case "subscription_sharing_usage_limit_exceeded": return .subscriptionLimit
        case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable": return .subscriptionUnavailable
        case "subscription_sharing_user_not_eligible", "chatpass_v2_scope_not_authorized", "chatpass_v2_invalid_authorization_context": return .subscriptionPermission
        case "subscription_sharing_invalid_user": return .signIn
        default:
            if status == 401 { return .signIn }; if status == 403 { return .subscriptionPermission }
            if status == 429 { return .subscriptionLimit }; if status.map({ $0 >= 500 }) == true { return .subscriptionUnavailable }
            return .response
        }
    }
    /// The stream is byte-bounded by the transport. Deltas alone never constitute a completed result.
    static func completed(_ bytes: Data) throws -> JSONText {
        guard bytes.count <= 2_000_000, let text = String(data: bytes, encoding: .utf8) else { throw AIFailure.response }
        var lines: [String] = [], result: JSONText?
        func event() throws {
            guard !lines.isEmpty else { return }
            let data = lines.joined(separator: "\n"); lines.removeAll(keepingCapacity: true)
            if data == "[DONE]" { return }
            guard let value = try? JSONText.parse(Data(data.utf8)) else { throw AIFailure.response }
            let kind = value["type"]?.text ?? ""
            if ["error", "response.failed", "response.incomplete"].contains(kind) || value["error"] != nil { throw failure(value) }
            if kind == "response.completed" {
                guard result == nil, let response = value["response"], response["status"] == .string("completed") else { throw AIFailure.response }
                result = response
            }
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if line.isEmpty { try event() }
            else if line.hasPrefix("data:") { lines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)) }
        }
        try event(); guard let result else { throw AIFailure.response }; return result
    }
}
