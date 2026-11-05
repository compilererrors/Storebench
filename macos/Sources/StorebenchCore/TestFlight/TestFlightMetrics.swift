import Foundation

public struct TestFlightMetricPoint: Sendable, Equatable, Identifiable {
    public let series: Int, start, end: String, values: [String: Double]
    public var id: String { "\(series):\(start):\(end)" }
}

public struct TestFlightMetrics: Sendable, Equatable {
    public let points: [TestFlightMetricPoint], seriesCount: Int
    public static let names = ["inviteCount", "installCount", "sessionCount", "crashCount", "feedbackCount"]
    public static let labels = ["Invites", "Installs", "Sessions", "Crashes", "Feedback"]

    static func date(_ text: String, plain: ISO8601DateFormatter, fractional: ISO8601DateFormatter) -> Date? {
        guard text.range(of: #"^\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2}))?$"#, options: .regularExpression) != nil else { return nil }
        let value = text.contains("T") ? text : text + "T00:00:00Z"
        return fractional.date(from: value) ?? plain.date(from: value)
    }

    /// This endpoint uses Apple's metric series shape rather than JSON:API resource IDs.
    public static func parse(_ value: JSONText, startingSeries: Int = 0) throws -> (metrics: TestFlightMetrics, next: String?) {
        guard case .object = value, case .array(let series)? = value["data"], series.count <= 200, case .object(let links)? = value["links"],
              !links.contains(where: { $0.0 == "next" && $0.1 != .null && $0.1.text == nil }) else { throw AppStoreConnectClient.Failure.unreadableResponse }
        var points: [TestFlightMetricPoint] = []
        let plain = ISO8601DateFormatter(), fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for (index, group) in series.enumerated() {
            guard case .object = group, group["type"] == nil || group["type"]?.text == "betaBuildUsages", case .array(let rows)? = group["dataPoints"], rows.count <= 200 else {
                throw AppStoreConnectClient.Failure.unreadableResponse
            }
            for row in rows {
                guard case .object = row, let start = row["start"]?.text, let end = row["end"]?.text,
                      let a = date(start, plain: plain, fractional: fractional), let b = date(end, plain: plain, fractional: fractional), a <= b else { throw AppStoreConnectClient.Failure.unreadableResponse }
                if let values = row["values"], case .object = values {} else if row["values"] != nil { throw AppStoreConnectClient.Failure.unreadableResponse }
                var values: [String: Double] = [:]
                for name in names { if let value = row["values"]?[name] {
                    guard case .number(let count) = value, count.isFinite, count == count.rounded(), count >= 0, count <= 9_007_199_254_740_991 else { throw AppStoreConnectClient.Failure.unreadableResponse }
                    values[name] = count
                } }
                points.append(TestFlightMetricPoint(series: startingSeries + index + 1, start: start, end: end, values: values))
                guard points.count <= 400 else { throw AppStoreConnectClient.Failure.paginationLimit }
            }
        }
        return (TestFlightMetrics(points: points, seriesCount: series.count), value["links"]?["next"]?.text.flatMap { $0.isEmpty ? nil : $0 })
    }
}

extension AppStoreConnectClient {
    /// Bounded raw JSON for endpoints whose response is not a JSON:API resource page.
    func metricJSON(_ path: String) async throws -> JSONText {
        guard let url = URL(string: path, relativeTo: origin), url.scheme == origin.scheme, url.host == origin.host, url.port == origin.port,
              url.user == nil, url.password == nil, url.fragment == nil, path.hasPrefix("/v1/") else { throw Failure.invalidPath }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(try token.signed())", forHTTPHeaderField: "Authorization"); request.setValue("application/json", forHTTPHeaderField: "Accept")
        for attempt in 0..<3 {
            let (data, response) = try await session.data(for: request, delegate: self)
            guard let http = response as? HTTPURLResponse else { throw Failure.unreadableResponse }
            if [429, 500, 502, 503, 504].contains(http.statusCode), attempt < 2 {
                let wait = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 0.5 * pow(3, Double(attempt))
                guard wait.isFinite, wait >= 0, wait <= 10 else { throw Failure.status(http.statusCode) }
                try await Task.sleep(for: .seconds(wait)); continue
            }
            guard (200..<300).contains(http.statusCode) else { throw Failure.status(http.statusCode) }
            guard data.count <= 4_000_000, let value = try? JSONText.parse(data) else { throw Failure.unreadableResponse }
            return value
        }
        throw Failure.unreadableResponse
    }
}

extension WorkspaceSession {
    /// Only the configured account's selected app and Apple's confirmed build owner can be read.
    public func testFlightMetrics(appId: String, buildId: String, client: AppStoreConnectClient) async throws -> TestFlightMetrics {
        guard client.token.account.appIds.contains(appId), buildId.range(of: "^[A-Za-z0-9_-]{1,256}$", options: .regularExpression) != nil else { throw PublishFailure.invalid("Choose a TestFlight build belonging to this app.") }
        let resources = try await client.get("/v1/builds/\(buildId)")
        guard resources.count == 1, let build = resources.first, build.type == "builds", build.id == buildId else { throw PublishFailure.invalid("Choose a TestFlight build belonging to this app.") }
        _ = try await scopedOwners([build], type: "builds", appId: appId) { try await client.list($0) }
        let path = "/v1/builds/\(buildId)/metrics/betaBuildUsages?limit=200"
        guard let initial = URLComponents(string: path) else { throw AppStoreConnectClient.Failure.invalidPath }
        var next: String? = path, cursor: String?, visited = Set<String>(), points: [TestFlightMetricPoint] = [], series = 0
        while let current = next {
            guard visited.insert(current).inserted, visited.count <= 10 else { throw AppStoreConnectClient.Failure.paginationLimit }
            let page = try TestFlightMetrics.parse(await client.metricJSON(current), startingSeries: series)
            points += page.metrics.points; series += page.metrics.seriesCount
            guard points.count <= 400 else { throw AppStoreConnectClient.Failure.paginationLimit }
            guard let link = page.next else { break }
            guard page.metrics.seriesCount > 0 else { throw AppStoreConnectClient.Failure.invalidPagination }
            cursor = try client.nextCursor(link, initial: initial, current: cursor)
            var components = initial; components.queryItems = initial.queryItems! + [URLQueryItem(name: "cursor", value: cursor)]; next = components.string
        }
        return TestFlightMetrics(points: points.sorted { $0.end == $1.end ? $0.series < $1.series : $0.end > $1.end }, seriesCount: series)
    }
}
