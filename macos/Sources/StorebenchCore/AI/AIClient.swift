import Foundation

/// Provider transports have fixed HTTPS origins. Credentials never appear in URLs, bodies or errors.
public struct AIClient: Sendable {
    public struct Model: Sendable, Identifiable { public let id, name: String }
    let provider: AIProvider, key: String
    private let pool: BoundedResponse.Pool
    public init(provider: AIProvider, key: String, configuration: URLSessionConfiguration = .ephemeral) throws {
        guard key.utf8.count <= 10_000, !key.isEmpty, key.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }) else { throw AIFailure.credentials }
        self.provider = provider; self.key = key
        configuration.httpShouldSetCookies = false; configuration.urlCache = nil
        pool = BoundedResponse.Pool(configuration: configuration)
    }
    private func send(_ path: String, body: JSONText? = nil) async throws -> JSONText {
        guard provider != .apple, let url = URL(string: provider.origin + path), path.hasPrefix("/"), !path.contains("..") else { throw AIFailure.configuration }
        var request = URLRequest(url: url); request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        switch provider {
        case .openai, .chatgpt: request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        case .anthropic: request.setValue(key, forHTTPHeaderField: "x-api-key"); request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .gemini: request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        case .apple: throw AIFailure.configuration
        }
        if let body { request.httpMethod = "POST"; request.httpBody = body.data }
        if provider == .chatgpt, body != nil { request.setValue("text/event-stream", forHTTPHeaderField: "Accept") }
        let response = try await pool.read(request, maximumBytes: 2_000_000)
        if provider == .chatgpt {
            guard (200..<300).contains(response.response.statusCode) else { throw ChatGPTEvents.failure((try? JSONText.parse(response.data)) ?? .null, status: response.response.statusCode) }
            if body != nil { return try ChatGPTEvents.completed(response.data) }
        }
        switch response.response.statusCode {
        case 200..<300: return try JSONText.parse(response.data)
        case 401, 403: throw AIFailure.credentials
        case 402, 429: throw AIFailure.quota
        case 500...599: throw AIFailure.unavailable
        default: throw AIFailure.response
        }
    }
    public func models() async throws -> [Model] {
        var path = provider == .gemini ? "/v1beta/models?pageSize=100" : provider == .anthropic ? "/v1/models?limit=100" : "/v1/models"
        var result: [Model] = [], visited = Set<String>()
        for _ in 0..<10 {
            guard visited.insert(path).inserted else { throw AIFailure.response }
            let value = try await send(path)
            guard case .array(let rows)? = value[provider == .gemini || provider == .chatgpt ? "models" : "data"] else { throw AIFailure.response }
            result += rows.compactMap { item in
                if provider == .chatgpt && item["visibility"] != .string("list") { return nil }
                let id = provider == .chatgpt ? item["slug"]?.text : provider == .gemini ? item["name"]?.text?.replacingOccurrences(of: "models/", with: "") : item["id"]?.text
                guard let id, AIConnection.validModel(id) else { return nil }
                if provider == .gemini, case .array(let methods)? = item["supportedGenerationMethods"], !methods.contains(.string("generateContent")) { return nil }
                return Model(id: id, name: item["displayName"]?.text ?? item["display_name"]?.text ?? id)
            }
            if provider == .gemini, let next = value["nextPageToken"]?.text, !next.isEmpty, next.utf8.count <= 4096,
               let encoded = next.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))) { path = "/v1beta/models?pageSize=100&pageToken=" + encoded }
            else if provider == .anthropic, value["has_more"] == .bool(true), let next = value["last_id"]?.text, AIConnection.validModel(next) { path = "/v1/models?limit=100&after_id=" + next }
            else { return provider == .chatgpt ? result : result.sorted { $0.name < $1.name } }
        }
        throw AIFailure.response
    }
    public func generate(_ input: AIRequest, model: String) async throws -> JSONText {
        try input.validate(); guard AIConnection.validModel(model) else { throw AIFailure.configuration }
        let body: JSONText, path: String
        switch provider {
        case .openai, .chatgpt:
            let parts: [JSONText] = [.object([("type", .string("input_text")), ("text", .string(input.input))])] + input.images.map {
                .object([("type", .string("input_image")), ("image_url", .string("data:\($0.mime);base64,\($0.data.base64EncodedString())")), ("detail", .string("auto"))])
            }
            path = "/v1/responses"
            body = .object([("model", .string(model)), ("instructions", .string(input.instructions)), ("store", .bool(false)), ("stream", .bool(provider == .chatgpt)),
                ("input", .array([.object([("role", .string("user")), ("content", .array(parts))])])),
                ("text", .object([("format", .object([("type", .string("json_schema")), ("name", .string("storebench_result")), ("strict", .bool(true)), ("schema", input.schema)]))]))])
        case .anthropic:
            let parts: [JSONText] = [.object([("type", .string("text")), ("text", .string(input.input))])] + input.images.map {
                .object([("type", .string("image")), ("source", .object([("type", .string("base64")), ("media_type", .string($0.mime)), ("data", .string($0.data.base64EncodedString()))]))])
            }
            path = "/v1/messages"
            body = .object([("model", .string(model)), ("max_tokens", .number(8192)), ("system", .string(input.instructions + "\nRequired JSON schema: " + input.schema.stringify())),
                ("messages", .array([.object([("role", .string("user")), ("content", .array(parts))])]))])
        case .gemini:
            let parts: [JSONText] = [.object([("text", .string(input.input))])] + input.images.map {
                .object([("inlineData", .object([("mimeType", .string($0.mime)), ("data", .string($0.data.base64EncodedString()))]))])
            }
            // The model is one path segment, not a caller-provided endpoint.
            guard let encoded = model.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))) else { throw AIFailure.configuration }
            path = "/v1beta/models/\(encoded):generateContent"
            body = .object([("systemInstruction", .object([("parts", .array([.object([("text", .string(input.instructions))])]))])),
                ("contents", .array([.object([("role", .string("user")), ("parts", .array(parts))])])),
                ("generationConfig", .object([("responseMimeType", .string("application/json")), ("responseJsonSchema", input.schema)]))])
        case .apple: return try await AppleLocalAI.generate(input)
        }
        let response = try await send(path, body: body), text: String
        switch provider {
        case .openai, .chatgpt:
            guard response["status"] == .string("completed"), case .array(let output)? = response["output"] else { throw AIFailure.response }
            text = output.flatMap { item -> [JSONText] in if case .array(let content)? = item["content"] { return content }; return [] }
                .filter { $0["type"] == .string("output_text") }.compactMap { $0["text"]?.text }.joined()
        case .anthropic:
            guard response["stop_reason"] == .string("end_turn"), case .array(let content)? = response["content"] else { throw AIFailure.response }
            text = content.filter { $0["type"] == .string("text") }.compactMap { $0["text"]?.text }.joined()
        case .gemini:
            guard case .array(let candidates)? = response["candidates"], let first = candidates.first, first["finishReason"] == .string("STOP"), case .array(let parts)? = first["content"]?["parts"] else { throw AIFailure.response }
            text = parts.filter { $0["thought"] != .bool(true) }.compactMap { $0["text"]?.text }.joined()
        case .apple: throw AIFailure.configuration
        }
        var clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasPrefix("```"), let newline = clean.firstIndex(of: "\n"), clean.hasSuffix("```") { clean = String(clean[clean.index(after: newline)..<clean.index(clean.endIndex, offsetBy: -3)]).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard clean.utf8.count <= 1_000_000, let json = try? JSONText.parse(Data(clean.utf8)) else { throw AIFailure.response }
        return json
    }
}
