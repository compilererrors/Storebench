import CryptoKit
import Foundation

/// Any JSON value, for App Store Connect attributes whose shapes vary by resource.
public enum JSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
    public var string: String? { if case .string(let value) = self { value } else { nil } }
}

/// The signed request token for App Store Connect: ES256 with the key ID,
/// `iss` for team keys, `sub: "user"` for individual keys, and at most 20 minutes of validity.
public struct AppleToken: Sendable {
    public let account: Account
    private let key: P256.Signing.PrivateKey

    public init(account: Account, privateKeyPEM: String) throws {
        self.account = account
        self.key = try P256.Signing.PrivateKey(pemRepresentation: privateKeyPEM)
    }

    public func signed(issuedAt: Date = Date(), lifetime: TimeInterval = 15 * 60) throws -> String {
        let iat = Int(issuedAt.timeIntervalSince1970), exp = iat + Int(min(lifetime, 20 * 60))
        var claims: [String: Any] = ["iat": iat, "exp": exp, "aud": "appstoreconnect-v1"]
        if account.keyType == "individual" { claims["sub"] = "user" } else { claims["iss"] = account.issuerId ?? "" }
        let header = try Self.encode(["alg": "ES256", "kid": account.keyId, "typ": "JWT"]), payload = try Self.encode(claims)
        let unsigned = "\(header).\(payload)"
        let signature = try key.signature(for: Data(unsigned.utf8)).rawRepresentation
        return "\(unsigned).\(Self.base64url(signature))"
    }

    static func encode(_ object: [String: Any]) throws -> String { base64url(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) }
    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// Read-only App Store Connect client. Reads retry Apple's temporary answers; redirects and foreign pagination links are refused.
public final class AppStoreConnectClient: NSObject, URLSessionTaskDelegate, Sendable {
    public struct Resource: Codable, Identifiable, Sendable {
        public let type: String
        public let id: String
        public let attributes: [String: JSONValue]?
        public let relationships: [String: JSONValue]?
    }
    struct Page: Decodable { let data: OneOrMany; let included: [Resource]?; let links: Links?; struct Links: Decodable { let next: String? } }
    enum OneOrMany: Decodable {
        case one(Resource), many([Resource])
        init(from decoder: Decoder) throws { if try decoder.singleValueContainer().decodeNil() { self = .many([]) } else if let list = try? [Resource](from: decoder) { self = .many(list) } else { self = .one(try Resource(from: decoder)) } }
        var resources: [Resource] { switch self { case .one(let value): [value]; case .many(let values): values } }
    }
    public enum Failure: Error, Equatable { case invalidPath, invalidPagination, status(Int), agreement, unreadableResponse, paginationLimit }

    /// Only Apple's bounded first error code identifies an agreement failure; upstream text is never retained.
    static func failure(status: Int, data: Data, contentType: String?) -> Failure {
        guard status == 403, data.count <= 64_000, contentType?.lowercased().contains("json") == true,
              let value = try? JSONText.parse(data), case .array(let errors)? = value["errors"],
              let code = errors.first?["code"]?.text,
              code.range(of: #"\A[A-Z][A-Z0-9_.]{0,100}\z"#, options: .regularExpression) != nil,
              code.contains("REQUIRED_AGREEMENTS_MISSING_OR_EXPIRED") else { return .status(status) }
        return .agreement
    }

    public static let base = URL(string: "https://api.appstoreconnect.apple.com")!
    let token: AppleToken, origin: URL
    let session: URLSession
    /// Reads go through one connection pool, so each request reuses an open connection to Apple instead of opening its own.
    let pool: BoundedResponse.Pool
    private let ownsSession: Bool
    let accessCheck: @Sendable () throws -> Void
    let readCache: AppStoreReadCache?
    let readCacheScope: String

    /// The connections every client without its own configuration shares for the life of the app.
    private struct Shared: @unchecked Sendable { let session: URLSession, pool: BoundedResponse.Pool }
    private static let shared: Shared = {
        let configuration = configured(.ephemeral)
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        return Shared(session: URLSession(configuration: Network.guarded(configuration)), pool: BoundedResponse.Pool(configuration: configuration))
    }()
    /// A connection that goes quiet is given up sooner on the first try of a read, and the read is sent again on a new connection.
    /// Later tries wait the full time, for answers Apple takes long to prepare.
    static func readTimeout(_ attempt: Int) -> TimeInterval { attempt == 0 ? 12 : 30 }
    /// Reads change nothing at Apple, so a read whose connection stalled or dropped is sent again.
    static func retriesConnection(_ error: Error, attempt: Int) -> Bool {
        guard attempt < 2, !Task.isCancelled, let code = (error as? URLError)?.code else { return false }
        return [.timedOut, .networkConnectionLost, .cannotConnectToHost, .secureConnectionFailed, .dnsLookupFailed].contains(code)
    }
    private static func configured(_ configuration: URLSessionConfiguration) -> URLSessionConfiguration {
        configuration.timeoutIntervalForRequest = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }

    public init(token: AppleToken, origin: URL = AppStoreConnectClient.base, configuration: URLSessionConfiguration? = nil, readCache: AppStoreReadCache? = nil, readCacheScope: String = "", accessCheck: @escaping @Sendable () throws -> Void = {}) {
        self.token = token; self.origin = origin; self.accessCheck = accessCheck; self.readCache = readCache; self.readCacheScope = readCacheScope
        if let configuration {
            let own = Self.configured(configuration)
            self.session = URLSession(configuration: Network.guarded(own)); self.pool = BoundedResponse.Pool(configuration: own); ownsSession = true
        } else {
            self.session = Self.shared.session; self.pool = Self.shared.pool; ownsSession = false
        }
        super.init()
    }
    deinit { if ownsSession { session.finishTasksAndInvalidate() } }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? { nil }

    /// One page and Apple's validated cursor for the next one, for callers that may stop early.
    public func page(_ path: String, currentCursor: String?) async throws -> (resources: [Resource], next: String?) {
        guard let initial = URLComponents(string: path) else { throw Failure.invalidPath }
        let page = try await page(path)
        guard let link = page.links?.next else { return (page.data.resources, nil) }
        var fixed = initial; fixed.queryItems = initial.queryItems?.filter { $0.name != "cursor" }
        return (page.data.resources, try nextCursor(link, initial: fixed, current: currentCursor))
    }

    /// A report file (`application/a-gzip`) with the same read retries. Apple's 404 means no report exists yet.
    public func download(_ path: String, maxBytes: Int = 4_000_000) async throws -> Data {
        try accessCheck()
        guard let url = URL(string: path, relativeTo: origin), url.host == origin.host, path.hasPrefix("/v1/") else { throw Failure.invalidPath }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(try token.signed())", forHTTPHeaderField: "Authorization")
        request.setValue("application/a-gzip", forHTTPHeaderField: "Accept")
        for attempt in 0..<3 {
            try accessCheck()
            request.timeoutInterval = Self.readTimeout(attempt)
            let result: BoundedResponse.Result
            let current = request, pool = pool
            do { result = try await AppleReadAdmission.shared(for: origin.host).run(cost: AppleReadCost.current ?? .bulk) { try await pool.read(current, maximumBytes: maxBytes) } } catch where Self.retriesConnection(error, attempt: attempt) { continue }
            try accessCheck()
            let data = result.data, http = result.response
            if [429, 500, 502, 503, 504].contains(http.statusCode), attempt < 2 {
                let wait = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 0.5 * pow(3, Double(attempt))
                guard wait.isFinite, wait >= 0, wait <= 10 else { throw Failure.status(http.statusCode) }
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)); continue
            }
            guard (200..<300).contains(http.statusCode) else { throw Self.failure(status: http.statusCode, data: data, contentType: http.value(forHTTPHeaderField: "Content-Type")) }
            guard data.count <= maxBytes else { throw Failure.unreadableResponse }
            return data
        }
        throw Failure.unreadableResponse
    }

    /// One resource or page, such as `/v1/apps/123`.
    public func get(_ path: String) async throws -> [Resource] { try await page(path).data.resources }
    func iconResources(appId: String) async throws -> (data: [Resource], included: [Resource]) {
        let page = try await page("/v1/apps/" + appId + "?include=appStoreIcon")
        return (page.data.resources, page.included ?? [])
    }
    /// The newest uploaded build with its icons: an app without a version on the App Store has no App Store icon yet.
    func latestBuildIconResources(appId: String) async throws -> [Resource] {
        try await page("/v1/builds?filter[app]=" + appId + "&sort=-uploadedDate&limit=1&include=icons").included ?? []
    }

    /// The first page of a list with its `included` resources, and whether Apple has more after it. Its bytes are shared with the
    /// first page `listWithIncluded` reads for the same path.
    public func firstPageWithIncluded(_ path: String) async throws -> (data: [Resource], included: [Resource], more: Bool) {
        guard path.hasPrefix("/v1/") || path.hasPrefix("/v2/"), let initial = URLComponents(string: path) else { throw Failure.invalidPath }
        let page = try await page(path)
        guard let link = page.links?.next else { return (page.data.resources, page.included ?? [], false) }
        _ = try nextCursor(link, initial: initial, current: nil)
        return (page.data.resources, page.included ?? [], true)
    }

    /// Every page of a list with its `included` resources, following only Apple's cursor on the same path and query.
    public func listWithIncluded(_ path: String) async throws -> (data: [Resource], included: [Resource]) {
        guard path.hasPrefix("/v1/") || path.hasPrefix("/v2/"), let initial = URLComponents(string: path) else { throw Failure.invalidPath }
        var results: [Resource] = [], included: [Resource] = [], next: String? = path, visited = Set<String>(), cursor: String?
        while let current = next {
            guard visited.insert(current).inserted, visited.count <= 1000 else { throw Failure.paginationLimit }
            let page = try await page(current)
            results += page.data.resources; included += page.included ?? []
            guard let link = page.links?.next else { break }
            let following = try nextCursor(link, initial: initial, current: cursor)
            cursor = following
            var components = initial
            components.queryItems = (initial.queryItems ?? []).filter { $0.name != "cursor" } + [URLQueryItem(name: "cursor", value: following)]
            next = components.string
        }
        return (results, included)
    }

    /// Every page of a list, following only Apple's cursor on the same path and query, at most 1,000 pages.
    public func list(_ path: String) async throws -> [Resource] {
        guard path.hasPrefix("/v1/") || path.hasPrefix("/v2/"), let initial = URLComponents(string: path) else { throw Failure.invalidPath }
        var results: [Resource] = [], next: String? = path, visited = Set<String>(), cursor: String?
        while let current = next {
            guard visited.insert(current).inserted, visited.count <= 1000 else { throw Failure.paginationLimit }
            let page = try await page(current)
            results += page.data.resources
            guard let link = page.links?.next else { break }
            let following = try nextCursor(link, initial: initial, current: cursor)
            cursor = following
            var components = initial
            components.queryItems = (initial.queryItems ?? []).filter { $0.name != "cursor" } + [URLQueryItem(name: "cursor", value: following)]
            next = components.string
        }
        return results
    }

    func nextCursor(_ raw: String, initial: URLComponents, current: String?) throws -> String {
        guard raw.utf16.count <= 8000, let base = URL(string: initial.path, relativeTo: origin), let absolute = URL(string: raw, relativeTo: base)?.absoluteURL,
              absolute.absoluteString.utf16.count <= 8000, let url = URLComponents(url: absolute, resolvingAgainstBaseURL: true),
              url.scheme?.lowercased() == origin.scheme?.lowercased(), url.host?.lowercased() == origin.host?.lowercased(), url.port == origin.port,
              url.path == initial.path, url.user == nil, url.password == nil, url.fragment == nil else { throw Failure.invalidPagination }
        let fixed = (initial.queryItems ?? []).filter { $0.name != "cursor" }, items = url.queryItems ?? []
        guard Set(items.filter { $0.name != "cursor" }.map(\.name)).allSatisfy({ name in
                  let expected = fixed.filter { $0.name == name }.map(\.value)
                  return !expected.isEmpty && items.filter { $0.name == name }.map(\.value) == expected
              }), items.filter({ $0.name == "cursor" }).count == 1,
              let next = items.first(where: { $0.name == "cursor" })?.value, !next.isEmpty, next != current, next.utf16.count <= 2048,
              !next.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { throw Failure.invalidPagination }
        return next
    }

    private func page(_ path: String) async throws -> Page {
        try accessCheck(); try Task.checkCancellation()
        let data: Data
        if let readCache {
            let account = token.account
            let key = JSONText.array([.string(origin.absoluteString), .string(account.id), .string(account.keyId),
                .string(account.issuerId ?? ""), .string(account.keyType), .string(readCacheScope), .string(path)]).sha256
            data = try await readCache.read(key, host: origin.host) { try await self.pageBytes(path) }
        } else { data = try await pageBytes(path) }
        try accessCheck(); try Task.checkCancellation()
        guard let page = try? JSONDecoder().decode(Page.self, from: data) else { throw Failure.unreadableResponse }
        return page
    }

    /// Request shape only: continuation pages are bulk work; a single resource or a bounded small page is metadata.
    /// The server's actual latency is unknown, so unclassified requests keep the ordinary queue position.
    static func readCost(_ path: String) -> AppleReadCost {
        guard let components = URLComponents(string: path) else { return .standard }
        let items = components.queryItems ?? []
        if items.contains(where: { $0.name == "cursor" }) { return .bulk }
        let limits = items.filter { $0.name == "limit" }
        if limits.count == 1, let text = limits[0].value, let limit = Int(text), (1...50).contains(limit) { return .small }
        let parts = components.path.split(separator: "/")
        if parts.count == 3, parts[0] == "v1" || parts[0] == "v2" { return .small }
        return .standard
    }

    private func pageBytes(_ path: String) async throws -> Data {
        try accessCheck()
        guard let url = URL(string: path, relativeTo: origin), url.host == origin.host, path.hasPrefix("/v1/") || path.hasPrefix("/v2/") else { throw Failure.invalidPath }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(try token.signed())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for attempt in 0..<3 {
            try accessCheck()
            request.timeoutInterval = Self.readTimeout(attempt)
            let result: BoundedResponse.Result
            let current = request, pool = pool
            do { result = try await AppleReadAdmission.shared(for: origin.host).run(cost: AppleReadCost.current ?? Self.readCost(path)) { try await pool.read(current, maximumBytes: 4_000_000) } } catch where Self.retriesConnection(error, attempt: attempt) { continue }
            try accessCheck()
            let data = result.data, http = result.response
            AppleRequestBudget.record(http, keyId: token.account.keyId)
            if [429, 500, 502, 503, 504].contains(http.statusCode), attempt < 2 {
                let wait = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 0.5 * pow(3, Double(attempt))
                guard wait.isFinite, wait >= 0, wait <= 10 else { throw Failure.status(http.statusCode) }
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                continue
            }
            guard (200..<300).contains(http.statusCode) else { throw Self.failure(status: http.statusCode, data: data, contentType: http.value(forHTTPHeaderField: "Content-Type")) }
            guard (try? JSONDecoder().decode(Page.self, from: data)) != nil else { throw Failure.unreadableResponse }
            return data
        }
        throw Failure.unreadableResponse
    }
}

/// What is left of Apple's hourly request limit for each API key, from the `X-Rate-Limit` header Apple sends with each answer.
/// Reads made ahead of time stop while little is left, so the screens and reviews the user opens still get answers.
public enum AppleRequestBudget {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var remaining: [String: (count: Int, at: ContinuousClock.Instant)] = [:]
    /// Below this many requests left in the hour, nothing is read ahead.
    public static let reserve = 400

    static func record(_ response: HTTPURLResponse, keyId: String) {
        if response.statusCode == 429 { lock.withLock { remaining[keyId] = (0, .now) }; return }
        guard let header = response.value(forHTTPHeaderField: "X-Rate-Limit"), let left = parse(header) else { return }
        lock.withLock { remaining[keyId] = (left, .now) }
    }
    /// `user-hour-lim:3600;user-hour-rem:3412;` gives 3412.
    static func parse(_ header: String) -> Int? {
        for part in header.split(separator: ";") {
            let pair = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2, pair[0] == "user-hour-rem", let value = Int(pair[1]), value >= 0 { return value }
        }
        return nil
    }
    /// Whether requests made ahead of time may still be sent with this key. An answer older than an hour no longer counts.
    public static func allowsReadingAhead(keyId: String) -> Bool {
        lock.withLock {
            guard let entry = remaining[keyId], ContinuousClock.now - entry.at < .seconds(3_600) else { return true }
            return entry.count >= reserve
        }
    }
}
