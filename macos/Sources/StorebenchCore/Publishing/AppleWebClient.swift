import Foundation

/// App Store Connect's web services with a signed-in Apple ID, limited to one app of one team. Writes need a publishing grant.
final class AppleWebClient: @unchecked Sendable {
    let session: AppleWebSession, appId: String
    private let pool: BoundedResponse.Pool, cookies = AppleCookieJar()
    private var team: String?

    init(session: AppleWebSession, appId: String, configuration: URLSessionConfiguration = .ephemeral) throws {
        guard session.origins.trusted, appId.range(of: #"\A\d{1,30}\z"#, options: .regularExpression) != nil else { throw AppleIDFailure.unreadable }
        self.session = session; self.appId = appId
        for cookie in session.cookies {
            var properties: [HTTPCookiePropertyKey: Any] = [.name: cookie.name, .value: cookie.value, .domain: cookie.domain, .path: cookie.path]
            if let expires = cookie.expires { properties[.expires] = Date(timeIntervalSince1970: expires) }
            if cookie.secure { properties[.secure] = "TRUE" }
            if let value = HTTPCookie(properties: properties) { cookies.add([value]) }
        }
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false; configuration.urlCache = nil; configuration.timeoutIntervalForRequest = 60
        pool = BoundedResponse.Pool(configuration: configuration)
    }

    private func send(_ method: String, _ path: String, body: JSONText? = nil) async throws -> (Data, Int) {
        guard let url = URL(string: path, relativeTo: session.origins.connect)?.absoluteURL, url.host == session.origins.connect.host, path.hasPrefix("/iris/v1/") || path.hasPrefix("/olympus/v1/") else { throw AppleIDFailure.unreadable }
        var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = body?.data
        request.setValue("application/json", forHTTPHeaderField: "Accept"); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With"); request.setValue("[asc-ui]", forHTTPHeaderField: "X-Csrf-Itc")
        for (name, value) in cookies.header(for: url) { request.setValue(value, forHTTPHeaderField: name) }
        let (data, http) = try await AppleIDTransport.exchange(request, pool: pool, maximumBytes: AppleIDTransport.webBytes)
        cookies.keep(http, url: url)
        if http.statusCode == 401 { throw AppleIDFailure.expired }
        // App Store Connect's web services answer here directly; a redirect, such as to a sign-in page, is not followed.
        if AppleIDTransport.redirect(http, from: url) != nil { throw AppleIDFailure.unreadable }
        return (data, http.statusCode)
    }

    /// Switches to the team that has the app, once per client.
    func requireApp() async throws {
        if team != nil { return }
        for candidate in session.teams {
            let (_, switched) = try await send("POST", "/olympus/v1/session", body: .object([("provider", .object([("providerId", Double(candidate.id).map { .number($0) } ?? .string(candidate.id))]))]))
            guard (200..<300).contains(switched) else { continue }
            let (data, status) = try await send("GET", "/iris/v1/apps/\(appId)")
            if status == 200, let page = try? JSONDecoder().decode(AppStoreConnectClient.Page.self, from: data),
               case .one(let app) = page.data, app.type == "apps", app.id == appId { team = candidate.id; return }
        }
        throw AppleIDFailure.noTeam
    }

    func get(_ path: String) async throws -> [AppStoreConnectClient.Resource] { try await pages(path).data }
    func pages(_ path: String) async throws -> (data: [AppStoreConnectClient.Resource], included: [AppStoreConnectClient.Resource]) {
        try await requireApp()
        guard path.hasPrefix("/v1/") else { throw AppleIDFailure.unreadable }
        let (data, status) = try await send("GET", "/iris" + path)
        if status == 404 { throw AppStoreConnectClient.Failure.status(404) }
        guard (200..<300).contains(status) else { throw status == 403 ? AppleIDFailure.noTeam : AppleIDFailure.status(status) }
        guard let page = try? JSONDecoder().decode(AppStoreConnectClient.Page.self, from: data) else { throw AppleIDFailure.unreadable }
        guard page.links?.next == nil else { throw AppleIDFailure.unreadable }
        return (page.data.resources, page.included ?? [])
    }
    var reads: AppleReads { AppleReads(list: { try await self.get($0) }, get: { try await self.get($0) }, pages: { try await self.pages($0) }) }

    /// One approved write, only from the publishing service.
    func write(_ method: String, _ path: String, body: JSONText?, grant: PublishGrant) async throws -> AppStoreConnectClient.Resource? {
        guard ["POST", "PATCH", "DELETE"].contains(method), path.hasPrefix("/v1/") else { throw PublishFailure.write("Unsupported Apple write.") }
        try await requireApp()
        let (data, status) = try await send(method, "/iris" + path, body: body)
        if [409, 422].contains(status) {
            let problems = AppleProblem.parse(data: data, contentType: "application/json")
            if !problems.isEmpty { throw PublishFailure.refused(AppleProblem.summary(problems, status: status), problems: problems) }
        }
        guard (200..<300).contains(status) else { throw AppStoreConnectClient.Failure.status(status) }
        return try AppStoreConnectClient.writtenResource(data, status: status, body: body)
    }
}
