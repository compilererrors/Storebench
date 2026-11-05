import Foundation

/// Why an Apple ID sign-in or a request with its session stopped, in words the sign-in form shows.
public enum AppleIDFailure: Error, Equatable {
    case rejected, code, unsupported, expired, noTeam, network, unreadable, status(Int)
    /// Apple answered one sign-in step in a way Storebench does not recognise.
    case unexpected(String)
    /// Apple refused the verification code, with its status and error code.
    case codeRefused(String)
    /// Apple no longer knows this verification, so a new sign-in is needed.
    case verificationEnded(String)
    /// The code was accepted, but App Store Connect did not accept the signed-in session.
    case sessionRefused(String)
    public var message: String {
        switch self {
        case .rejected: "Apple did not accept this Apple ID or password."
        case .code: "Apple did not accept the verification code. Check it and try again, or send a new code."
        case .unsupported: "This Apple ID needs two-factor authentication or an update at appleid.apple.com before it can sign in."
        case .expired: "The Apple ID session has ended. Sign in again."
        case .noTeam: "This Apple ID has no access to this app in App Store Connect. Sign in with an Account Holder or Admin of the app's team."
        case .network: "App Store Connect could not be reached. Nothing was sent; try again."
        case .unreadable: "Apple's answer could not be read. Nothing was changed; try again."
        case .status(let code): "Apple returned an error (\(code)). Nothing was changed; try again."
        case .sessionRefused(let detail): "Apple accepted the code, but App Store Connect did not open a session for this Apple ID (\(detail)). Choose Sign In again; if it repeats, check that the Apple ID has access to App Store Connect."
        case .verificationEnded(let detail): "Apple ended this verification before the code was checked (\(detail)). Choose Sign In again; Apple then sends a new code."
        case .codeRefused(let detail): "Apple did not accept the verification code (\(detail)). Enter the newest code from your device, or choose a phone number and Text Me a Code."
        case .unexpected(let step): "Apple's answer to \(step) could not be read. Nothing was changed; try again, and report this step if it repeats."
        }
    }
}

/// Where Apple's sign-in and App Store Connect's web services live. Tests use synthetic `.test` hosts.
public struct AppleIDOrigins: Sendable, Equatable {
    public let identity, connect: URL
    public static let apple = AppleIDOrigins(identity: URL(string: "https://idmsa.apple.com")!, connect: URL(string: "https://appstoreconnect.apple.com")!)
    public init(identity: URL, connect: URL) { self.identity = identity; self.connect = connect }
    /// Only Apple's own hosts, or synthetic hosts ending in `.test`, may receive the session.
    var trusted: Bool {
        [identity, connect].allSatisfy { url in url.scheme == "https" && (url.host.map { $0 == "idmsa.apple.com" || $0 == "appstoreconnect.apple.com" || $0.hasSuffix(".test") } ?? false) }
    }
}

/// Two-factor authentication: Apple sent a code to the trusted devices, or can text one to a trusted phone number.
public struct AppleIDChallenge: Sendable, Equatable {
    public struct Phone: Sendable, Equatable, Identifiable { public let id: Int; public let number: String }
    public let phones: [Phone], codeLength: Int, deviceCode: Bool
}

/// A signed-in Apple ID session: its cookies and the App Store Connect team, kept in the chosen credential storage like the API key.
public struct AppleWebSession: Sendable, Equatable {
    public struct Cookie: Sendable, Equatable { let name, value, domain, path: String; let expires: Double?; let secure: Bool }
    public struct Team: Sendable, Equatable, Identifiable { public let id: String; public let name: String }
    public let appleId: String
    public let teams: [Team]
    let cookies: [Cookie]
    let origins: AppleIDOrigins
    public let signedInAt: String

    var json: JSONText {
        .object([("appleId", .string(appleId)), ("signedInAt", .string(signedInAt)), ("identity", .string(origins.identity.absoluteString)), ("connect", .string(origins.connect.absoluteString)),
                 ("teams", .array(teams.map { .object([("id", .string($0.id)), ("name", .string($0.name))]) })),
                 ("cookies", .array(cookies.map { .object([("name", .string($0.name)), ("value", .string($0.value)), ("domain", .string($0.domain)), ("path", .string($0.path)),
                                                           ("expires", $0.expires.map { .number($0) } ?? .null), ("secure", .bool($0.secure))]) }))])
    }
    init(appleId: String, teams: [Team], cookies: [Cookie], origins: AppleIDOrigins, signedInAt: String) {
        self.appleId = appleId; self.teams = teams; self.cookies = cookies; self.origins = origins; self.signedInAt = signedInAt
    }
    init?(_ text: String) {
        guard let value = try? JSONText.parse(Data(text.utf8)), let appleId = value["appleId"]?.text, let at = value["signedInAt"]?.text,
              let identity = value["identity"]?.text.flatMap(URL.init(string:)), let connect = value["connect"]?.text.flatMap(URL.init(string:)),
              case .array(let teams)? = value["teams"], case .array(let cookies)? = value["cookies"] else { return nil }
        let origins = AppleIDOrigins(identity: identity, connect: connect)
        guard origins.trusted else { return nil }
        self.init(appleId: appleId, teams: teams.compactMap { team in team["id"]?.text.map { Team(id: $0, name: team["name"]?.text ?? $0) } },
                  cookies: cookies.compactMap { item in
                      guard let name = item["name"]?.text, let value = item["value"]?.text, let domain = item["domain"]?.text, let path = item["path"]?.text else { return nil }
                      var expires: Double?; if case .number(let number)? = item["expires"] { expires = number }
                      return Cookie(name: name, value: value, domain: domain, path: path, expires: expires, secure: item["secure"] == .bool(true))
                  }, origins: origins, signedInAt: at)
    }
    /// Cookies for Apple's hosts only, so a session never carries anything else.
    static func cookies(_ jar: AppleCookieJar, origins: AppleIDOrigins) -> [Cookie] {
        let hosts = [origins.identity.host ?? "", origins.connect.host ?? ""]
        return jar.all.filter { cookie in
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            return hosts.contains { $0 == domain || $0.hasSuffix("." + domain) }
        }.map { Cookie(name: $0.name, value: $0.value, domain: $0.domain, path: $0.path, expires: $0.expiresDate?.timeIntervalSince1970, secure: $0.isSecure) }
            .sorted { ($0.domain, $0.name) < ($1.domain, $1.name) }
    }
}

/// Apple ID sign-in for App Store Connect's web services: password proof, two-factor code and trust, then the account's teams.
/// The password is used only for the proof and is never stored.
public actor AppleIDSignIn {
    let origins: AppleIDOrigins, appleId: String
    private let pool: BoundedResponse.Pool, cookies = AppleCookieJar()
    private var widgetKey = "", sessionId = "", scnt = ""

    public init(appleId: String, origins: AppleIDOrigins = .apple, configuration: URLSessionConfiguration = .ephemeral) throws {
        let trimmed = appleId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard origins.trusted, !trimmed.isEmpty, trimmed.count <= 200, !trimmed.contains(where: { $0.isWhitespace }) else { throw AppleIDFailure.rejected }
        self.appleId = trimmed; self.origins = origins
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCache = nil; configuration.timeoutIntervalForRequest = 30
        pool = BoundedResponse.Pool(configuration: configuration)
    }

    /// Sign-in requests send Apple's widget key; two-factor requests also send the session id and `scnt` from the sign-in answer,
    /// with only the headers Apple's own sign-in page sends. A GET that Apple redirects is followed only to Apple's sign-in or
    /// App Store Connect hosts, a few times at most; any other redirect is refused.
    private func send(_ method: String, _ url: URL, body: JSONText? = nil, headers: [String: String] = [:], twoFactor: Bool = false, keepSession: Bool = false) async throws -> (Data, HTTPURLResponse) {
        var target = url
        for hop in 0...AppleIDTransport.redirects {
            guard AppleIDTransport.allowed(target, origins: [origins.identity, origins.connect]) else { throw AppleIDFailure.unreadable }
            var request = URLRequest(url: target); request.httpMethod = method; request.httpBody = body?.data
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !widgetKey.isEmpty { request.setValue(widgetKey, forHTTPHeaderField: "X-Apple-Widget-Key") }
            if twoFactor {
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue(sessionId, forHTTPHeaderField: "X-Apple-ID-Session-Id"); request.setValue(scnt, forHTTPHeaderField: "scnt")
            } else {
                request.setValue("application/json, text/javascript", forHTTPHeaderField: "Accept")
                request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
            }
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            for (name, value) in cookies.header(for: target) { request.setValue(value, forHTTPHeaderField: name) }
            let (data, http) = try await AppleIDTransport.exchange(request, pool: pool, maximumBytes: AppleIDTransport.signInBytes)
            cookies.keep(http, url: target)
            if let next = AppleIDTransport.redirect(http, from: target) {
                guard method == "GET", hop < AppleIDTransport.redirects, AppleIDTransport.allowed(next, origins: [origins.identity, origins.connect]) else { throw AppleIDFailure.unreadable }
                target = next; continue
            }
            // The sign-in answer starts the verification session; Apple then sends a newer `scnt`, and sometimes a newer session id, with each step.
            if keepSession { sessionId = http.value(forHTTPHeaderField: "X-Apple-ID-Session-Id") ?? ""; scnt = http.value(forHTTPHeaderField: "scnt") ?? "" }
            else if twoFactor {
                if let value = http.value(forHTTPHeaderField: "X-Apple-ID-Session-Id"), !value.isEmpty { sessionId = value }
                if let value = http.value(forHTTPHeaderField: "scnt"), !value.isEmpty { scnt = value }
            }
            return (data, http)
        }
        throw AppleIDFailure.unreadable
    }
    private func url(_ origin: URL, _ path: String) -> URL { URL(string: path, relativeTo: origin)!.absoluteURL }

    /// Apple's sign-in widget key, read from the redirect of App Store Connect's logout page without following it, or from its older configuration endpoint.
    private func serviceKey() async throws -> String {
        func valid(_ key: String?) -> String? { key.flatMap { $0.range(of: #"\A[A-Za-z0-9]{1,200}\z"#, options: .regularExpression) != nil ? $0 : nil } }
        var request = URLRequest(url: url(origins.connect, "/logout")); request.httpMethod = "HEAD"
        // Redirects are never followed by the transport, so the logout answer's own Location is read without visiting it.
        if case let (_, http)? = try? await AppleIDTransport.exchange(request, pool: pool, maximumBytes: AppleIDTransport.signInBytes),
           let location = http.value(forHTTPHeaderField: "Location"), let key = valid(URLComponents(string: location)?.queryItems?.first(where: { $0.name == "widgetKey" })?.value) {
            return key
        }
        let (config, response) = try await send("GET", url(origins.connect, "/olympus/v1/app/config?hostname=itunesconnect.apple.com"))
        guard response.statusCode == 200, let key = valid((try? JSONText.parse(config))?["authServiceKey"]?.text) else { throw AppleIDFailure.unexpected("the sign-in key request") }
        return key
    }

    /// Proves the password. Returns nil when Apple signs in without a code, otherwise the two-factor choices.
    public func signIn(password: String) async throws -> AppleIDChallenge? {
        guard !password.isEmpty, password.count <= 512 else { throw AppleIDFailure.rejected }
        widgetKey = try await serviceKey()
        let (_, challenge) = try await send("GET", url(origins.identity, "/appleauth/auth/signin?widgetKey=\(widgetKey)"))
        let stamp = Int(challenge.value(forHTTPHeaderField: "X-Apple-HC-Bits") ?? "").flatMap { bits in challenge.value(forHTTPHeaderField: "X-Apple-HC-Challenge").flatMap { AppleIDProof.hashcash(bits: bits, challenge: $0) } }
        let proof = AppleIDProof(account: appleId)
        let (start, startResponse) = try await send("POST", url(origins.identity, "/appleauth/auth/signin/init"),
                                                    body: .object([("a", .string(Data(proof.publicValue.bytes).base64EncodedString())), ("accountName", .string(appleId)), ("protocols", .array([.string("s2k"), .string("s2k_fo")]))]))
        guard startResponse.statusCode == 200 else { throw startResponse.statusCode == 400 || startResponse.statusCode == 401 ? AppleIDFailure.rejected : AppleIDFailure.status(startResponse.statusCode) }
        guard let value = try? JSONText.parse(start) else { throw AppleIDFailure.unexpected("the password check") }
        guard case .number(let iterations)? = value["iteration"], let salt = value["salt"]?.text.flatMap({ Data(base64Encoded: $0) }), let server = value["b"]?.text.flatMap({ Data(base64Encoded: $0) }),
              let c = value["c"]?.text, let name = value["protocol"]?.text else { throw AppleIDFailure.unexpected("the password check") }
        let answer: (m1: [UInt8], m2: [UInt8])
        do { answer = try proof.respond(password: password, salt: Array(salt), iterations: Int(iterations), protocol: name, serverValue: Array(server)) } catch { throw AppleIDFailure.unsupported }
        let (_, done) = try await send("POST", url(origins.identity, "/appleauth/auth/signin/complete?isRememberMeEnabled=false"),
                                       body: .object([("accountName", .string(appleId)), ("c", .string(c)), ("m1", .string(Data(answer.m1).base64EncodedString())), ("m2", .string(Data(answer.m2).base64EncodedString())), ("rememberMe", .bool(false))]),
                                       headers: stamp.map { ["X-Apple-HC": $0] } ?? [:], keepSession: true)
        switch done.statusCode {
        case 200: return nil
        case 409: break
        case 412: throw AppleIDFailure.unsupported
        case 401, 403: throw AppleIDFailure.rejected
        default: throw AppleIDFailure.status(done.statusCode)
        }
        guard !sessionId.isEmpty, !scnt.isEmpty else { throw AppleIDFailure.unexpected("the two-factor request") }
        let (options, optionsResponse) = try await send("GET", url(origins.identity, "/appleauth/auth"), twoFactor: true)
        guard optionsResponse.statusCode == 200 || optionsResponse.statusCode == 201 else { throw AppleIDFailure.status(optionsResponse.statusCode) }
        guard let details = try? JSONText.parse(options) else { throw AppleIDFailure.unexpected("the two-factor choices") }
        var phones: [AppleIDChallenge.Phone] = []
        if case .array(let items)? = details["trustedPhoneNumbers"] { for item in items { if case .number(let id)? = item["id"] { phones.append(.init(id: Int(id), number: item["numberWithDialCode"]?.text ?? "Trusted phone number")) } } }
        var length = 6; if case .number(let value)? = details["securityCode"]?["length"] { length = Int(value) }
        return AppleIDChallenge(phones: phones, codeLength: length, deviceCode: details["noTrustedDevices"] != .bool(true))
    }

    /// Asks Apple to text a code to one trusted phone number.
    public func requestText(phone: Int) async throws {
        let (data, response) = try await send("PUT", url(origins.identity, "/appleauth/auth/verify/phone"), body: .object([("phoneNumber", .object([("id", .number(Double(phone)))])), ("mode", .string("sms"))]), twoFactor: true)
        guard (200..<300).contains(response.statusCode) else { throw response.statusCode == 401 ? AppleIDFailure.verificationEnded(Self.detail(response, data)) : AppleIDFailure.unexpected("the text message request (\(Self.detail(response, data)))") }
    }

    /// Checks the code from a trusted device, or from a text to `phone`, then trusts this sign-in and reads the account's teams.
    public func verify(code: String, phone: Int? = nil) async throws -> AppleWebSession {
        guard code.range(of: #"\A[0-9]{4,8}\z"#, options: .regularExpression) != nil else { throw AppleIDFailure.code }
        let body: JSONText = phone.map { .object([("securityCode", .object([("code", .string(code))])), ("phoneNumber", .object([("id", .number(Double($0)))])), ("mode", .string("sms"))]) }
            ?? .object([("securityCode", .object([("code", .string(code))]))])
        let (data, response) = try await send("POST", url(origins.identity, phone == nil ? "/appleauth/auth/verify/trusteddevice/securitycode" : "/appleauth/auth/verify/phone/securitycode"), body: body, twoFactor: true)
        guard (200..<300).contains(response.statusCode) else { throw response.statusCode == 401 ? AppleIDFailure.verificationEnded(Self.detail(response, data)) : AppleIDFailure.codeRefused(Self.detail(response, data)) }
        let (trustData, trust) = try await send("GET", url(origins.identity, "/appleauth/auth/2sv/trust"), twoFactor: true)
        guard (200..<300).contains(trust.statusCode) else { throw AppleIDFailure.unexpected("trusting this Mac (\(Self.detail(trust, trustData)))") }
        return try await finish()
    }

    /// Reads the teams the signed-in Apple ID can use in App Store Connect and keeps the session's cookies.
    public func finish() async throws -> AppleWebSession {
        let (data, response) = try await send("GET", url(origins.connect, "/olympus/v1/session"))
        guard response.statusCode == 200 else { throw AppleIDFailure.sessionRefused(Self.detail(response, data)) }
        guard let value = try? JSONText.parse(data) else { throw AppleIDFailure.unexpected("the App Store Connect session") }
        var teams: [AppleWebSession.Team] = []
        func add(_ item: JSONText?) {
            guard let item, let id = Self.identifier(item["providerId"]) ?? item["publicProviderId"]?.text, !teams.contains(where: { $0.id == id }) else { return }
            teams.append(.init(id: id, name: item["name"]?.text ?? id))
        }
        add(value["provider"]); if case .array(let items)? = value["availableProviders"] { items.forEach { add($0) } }
        guard !teams.isEmpty else { throw AppleIDFailure.noTeam }
        let cookies = AppleWebSession.cookies(self.cookies, origins: origins)
        guard !cookies.isEmpty else { throw AppleIDFailure.unexpected("the session cookies") }
        return AppleWebSession(appleId: appleId, teams: teams, cookies: cookies, origins: origins, signedInAt: ISODateParser.text(Date()))
    }
    /// Apple's status and its own error code, such as "400 · -21669"; Apple's free text is not shown.
    static func detail(_ response: HTTPURLResponse, _ data: Data) -> String {
        let value = try? JSONText.parse(data)
        var code: String?
        for key in ["service_errors", "serviceErrors", "validationErrors"] {
            if case .array(let items)? = value?[key], let first = items.first, let text = first["code"]?.text, text.range(of: #"\A[A-Za-z0-9._-]{1,40}\z"#, options: .regularExpression) != nil { code = text; break }
        }
        return code.map { "\(response.statusCode) · \($0)" } ?? "\(response.statusCode)"
    }
    /// A team id Apple sends as text or as a number.
    static func identifier(_ value: JSONText?) -> String? {
        switch value { case .string(let text)?: text; case .number(let number)?: JSONText.number(number); default: nil }
    }
    static func value(_ text: JSONText) -> JSONValue? {
        switch text { case .string(let value): .string(value); case .number(let value): .number(value); default: nil }
    }
}

/// The Apple ID transport: requests go through the guarded, bounded reader, which counts bytes as they arrive and never follows a
/// redirect on its own.
enum AppleIDTransport {
    static let signInBytes = 2_000_000, webBytes = 4_000_000, redirects = 3

    static func exchange(_ request: URLRequest, pool: BoundedResponse.Pool, maximumBytes: Int) async throws -> (Data, HTTPURLResponse) {
        do {
            let result = try await pool.read(request, maximumBytes: maximumBytes)
            return (result.data, result.response)
        } catch is BoundedResponse.Failure { throw AppleIDFailure.unreadable }
        catch let error as AppleIDFailure { throw error }
        catch { if error is CancellationError || Task.isCancelled { throw CancellationError() }; throw AppleIDFailure.network }
    }
    /// Where a redirect answer points, resolved against the request; nil for any other answer.
    static func redirect(_ response: HTTPURLResponse, from url: URL) -> URL? {
        guard [301, 302, 303, 307, 308].contains(response.statusCode) else { return nil }
        return response.value(forHTTPHeaderField: "Location").flatMap { URL(string: $0, relativeTo: url)?.absoluteURL } ?? url
    }
    /// Only HTTPS on one of Apple's configured hosts.
    static func allowed(_ url: URL, origins: [URL]) -> Bool {
        url.scheme == "https" && origins.contains { $0.host == url.host && $0.port == url.port }
    }
}

/// Cookies for Apple's hosts, kept by Storebench itself: one per name, domain and path, sent only to a matching host and path,
/// and dropped when Apple expires them. Nothing reaches the shared cookie store.
final class AppleCookieJar: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [HTTPCookie] = []
    var all: [HTTPCookie] { lock.withLock { items.filter { $0.expiresDate.map { $0 > Date() } ?? true } } }

    func keep(_ response: HTTPURLResponse, url: URL) {
        let fields = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in if let key = pair.key as? String, let value = pair.value as? String { result[key] = value } }
        add(HTTPCookie.cookies(withResponseHeaderFields: fields, for: url))
    }
    func add(_ cookies: [HTTPCookie]) {
        lock.withLock {
            for cookie in cookies {
                items.removeAll { $0.name == cookie.name && $0.domain.lowercased() == cookie.domain.lowercased() && $0.path == cookie.path }
                if cookie.expiresDate.map({ $0 > Date() }) ?? true { items.append(cookie) }
            }
        }
    }
    func header(for url: URL) -> [String: String] {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return [:] }
        let path = url.path.isEmpty ? "/" : url.path
        let matching = all.filter { cookie in
            let domain = cookie.domain.lowercased(), bare = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
            return (host == bare || host.hasSuffix("." + bare)) && path.hasPrefix(cookie.path.isEmpty ? "/" : cookie.path)
        }
        return matching.isEmpty ? [:] : HTTPCookie.requestHeaderFields(with: matching)
    }
}
