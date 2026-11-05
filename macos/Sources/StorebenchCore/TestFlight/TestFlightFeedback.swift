import Foundation

public enum TestFlightFeedback {
    public enum Kind: String, Sendable, CaseIterable, Codable {
        case screenshot, crash
        var resourceType: String { self == .screenshot ? "betaFeedbackScreenshotSubmissions" : "betaFeedbackCrashSubmissions" }
        public var title: String { self == .screenshot ? "Screenshot feedback" : "Crash feedback" }
    }
    public struct ImageDescriptor: Sendable, Codable {
        public let url: URL, width: Int?, height: Int?
        var json: JSONText {
            var fields: [(String, JSONText)] = [("url", .string(url.absoluteString))]
            if let width { fields.append(("width", .number(Double(width)))) }; if let height { fields.append(("height", .number(Double(height)))) }
            return .object(fields)
        }
    }
    public struct Submission: Identifiable, Sendable, Codable {
        public let id, buildId, createdDate, device, os, comment: String
        public let kind: Kind, images: [ImageDescriptor]
    }
    public struct Page: Sendable, Codable { public let submissions: [Submission], next: String? }
    public struct ImageFile: Sendable { public let bytes: Data, contentType: String }
    public enum Failure: Error, Equatable { case selection, ownership, page, unavailable, image, log }

    public static func validID(_ text: String) -> Bool { text.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil }
    static func buildId(_ resource: AppStoreConnectClient.Resource) -> String? {
        guard let link = Apple.owner(resource, "build"), link.type == "builds", validID(link.id) else { return nil }; return link.id
    }
    public static func images(_ value: JSONValue?, now: Date = Date()) -> [ImageDescriptor] {
        guard case .array(let items)? = value else { return [] }
        let plain = ISO8601DateFormatter(), fractional = ISO8601DateFormatter.storebench
        return items.prefix(10).compactMap { value in
            guard case .object(let item) = value, let raw = item["url"]?.string, var url = URLComponents(string: raw), url.scheme?.lowercased() == "https",
                  url.port == nil || url.port == 443, (url.user ?? "").isEmpty, (url.password ?? "").isEmpty, let host = url.host?.lowercased(),
                  ["apple.com", "mzstatic.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
            if let expiry = item["expirationDate"]?.string {
                let dateText = expiry.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil ? expiry + "T00:00:00Z" : expiry
                if let date = fractional.date(from: dateText) ?? plain.date(from: dateText), date <= now { return nil }
            }
            func dimension(_ name: String) -> Int? {
                guard case .number(let value)? = item[name], value.isFinite, value.rounded() == value, value > 0, value <= 20_000 else { return nil }; return Int(value)
            }
            url.scheme = "https"; url.host = host; if url.port == 443 { url.port = nil }; url.user = nil; url.password = nil
            guard let target = url.url else { return nil }
            return ImageDescriptor(url: target, width: dimension("width"), height: dimension("height"))
        }
    }
    public static func submissions(_ resources: [AppStoreConnectClient.Resource], kind: Kind, now: Date = Date()) throws -> [Submission] {
        guard resources.count <= 10, Set(resources.map(\.id)).count == resources.count else { throw Failure.page }
        return try resources.map { resource in
            guard resource.type == kind.resourceType, validID(resource.id), let buildId = buildId(resource) else { throw Failure.page }
            func text(_ key: String, fallback: String) -> String { let value = resource.attributes?[key]?.string; return value.flatMap { TextSemantics.trim($0).isEmpty ? nil : $0 } ?? fallback }
            return Submission(id: resource.id, buildId: buildId, createdDate: text("createdDate", fallback: ""), device: text("deviceModel", fallback: "Device unavailable"), os: text("osVersion", fallback: "OS unavailable"),
                              comment: text("comment", fallback: kind == .crash ? "No written crash comment." : "No written screenshot comment."), kind: kind,
                              images: kind == .screenshot ? images(resource.attributes?["screenshots"], now: now) : [])
        }
    }
    static func imageType(_ data: Data) -> String? {
        if data.count >= 8, data.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]) { return "image/png" }
        if data.count >= 3, data.prefix(3) == Data([255, 216, 255]) { return "image/jpeg" }; return nil
    }
}

extension WorkspaceSession {
    func requireFeedbackScope(appId: String, client: AppStoreConnectClient) throws {
        guard TestFlightFeedback.validID(appId), client.token.account.appIds.contains(appId) else { throw TestFlightFeedback.Failure.selection }
        try requirePublishingAccount(client.token.account, appId: appId, client: client)
    }
    nonisolated func feedbackOwner(_ buildId: String, appId: String, client: AppStoreConnectClient) async throws {
        let owners = try await client.get("/v1/builds/\(buildId)/app")
        guard owners.count == 1, owners[0].type == "apps", owners[0].id == appId else { throw TestFlightFeedback.Failure.ownership }
    }
    func ownedFeedback(appId: String, submissionId: String, kind: TestFlightFeedback.Kind, client: AppStoreConnectClient) async throws -> AppStoreConnectClient.Resource {
        try requireFeedbackScope(appId: appId, client: client)
        guard TestFlightFeedback.validID(submissionId) else { throw TestFlightFeedback.Failure.selection }
        let items = try await client.get("/v1/\(kind.resourceType)/\(submissionId)")
        guard items.count == 1, let resource = items.first, resource.type == kind.resourceType, resource.id == submissionId, let build = TestFlightFeedback.buildId(resource) else { throw TestFlightFeedback.Failure.ownership }
        try await feedbackOwner(build, appId: appId, client: client)
        try requireFeedbackScope(appId: appId, client: client)
        return resource
    }
    public func testFlightFeedback(appId: String, kind: TestFlightFeedback.Kind, cursor: String? = nil, client: AppStoreConnectClient, now: Date = Date()) async throws -> TestFlightFeedback.Page {
        try requireFeedbackScope(appId: appId, client: client)
        if let cursor { guard !cursor.isEmpty, cursor.utf16.count <= 2048, !cursor.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { throw AppStoreConnectClient.Failure.invalidPagination } }
        var path = URLComponents(string: "/v1/apps/\(appId)/\(kind.resourceType)")!
        path.queryItems = [URLQueryItem(name: "limit", value: "10"), URLQueryItem(name: "sort", value: "-createdDate")]
        if let cursor { path.queryItems!.append(URLQueryItem(name: "cursor", value: cursor)) }
        let page = try await client.page(path.string!, currentCursor: cursor)
        let submissions = try TestFlightFeedback.submissions(page.resources, kind: kind, now: now)
        guard page.next == nil || !submissions.isEmpty else { throw AppStoreConnectClient.Failure.invalidPagination }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for build in Set(submissions.map(\.buildId)).sorted() { group.addTask { try await self.feedbackOwner(build, appId: appId, client: client) } }
            for try await _ in group { }
        }
        try requireFeedbackScope(appId: appId, client: client)
        return TestFlightFeedback.Page(submissions: submissions, next: page.next)
    }
    public func testFlightFeedbackImage(appId: String, submissionId: String, index: Int, client: AppStoreConnectClient, now: Date = Date()) async throws -> TestFlightFeedback.ImageFile {
        guard (0..<10).contains(index) else { throw TestFlightFeedback.Failure.selection }
        let submission = try await ownedFeedback(appId: appId, submissionId: submissionId, kind: .screenshot, client: client)
        let images = TestFlightFeedback.images(submission.attributes?["screenshots"], now: now)
        guard index < images.count else { throw TestFlightFeedback.Failure.unavailable }
        try requireFeedbackScope(appId: appId, client: client)
        try client.accessCheck()
        let configuration = client.session.configuration
        configuration.httpAdditionalHeaders = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 15
        var request = URLRequest(url: images[index].url); request.httpShouldHandleCookies = false; request.cachePolicy = .reloadIgnoringLocalCacheData; request.timeoutInterval = 15
        let response = try await BoundedResponse.read(request, configuration: configuration, maximumBytes: 10_000_000) { http in
            guard (200..<300).contains(http.statusCode) else { throw AppStoreConnectClient.Failure.status(http.statusCode) }
            let type = http.value(forHTTPHeaderField: "Content-Type")?.components(separatedBy: ";").first.map(TextSemantics.trim)?.lowercased()
            guard type == "image/png" || type == "image/jpeg" else { throw TestFlightFeedback.Failure.image }
        }
        try client.accessCheck()
        guard let type = TestFlightFeedback.imageType(response.data), type == response.response.value(forHTTPHeaderField: "Content-Type")?.components(separatedBy: ";").first.map(TextSemantics.trim)?.lowercased() else { throw TestFlightFeedback.Failure.image }
        try requireFeedbackScope(appId: appId, client: client)
        return TestFlightFeedback.ImageFile(bytes: response.data, contentType: type)
    }
    public func testFlightCrashLog(appId: String, submissionId: String, client: AppStoreConnectClient) async throws -> Data {
        _ = try await ownedFeedback(appId: appId, submissionId: submissionId, kind: .crash, client: client)
        let items = try await client.get("/v1/betaFeedbackCrashSubmissions/\(submissionId)/crashLog")
        guard items.count == 1, let log = items.first, log.type == "betaCrashLogs", let text = log.attributes?["logText"]?.string,
              !TextSemantics.trim(text).isEmpty, text.utf8.count <= 4_000_000 else { throw TestFlightFeedback.Failure.log }
        try requireFeedbackScope(appId: appId, client: client)
        return Data(text.utf8)
    }
}
