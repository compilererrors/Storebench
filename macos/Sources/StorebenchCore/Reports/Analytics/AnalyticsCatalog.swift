import Foundation

/// Existing report requests and processing-date availability for one app and selection.
public struct AnalyticsCatalog: Equatable, Sendable {
    public struct Request: Identifiable, Equatable, Sendable {
        public let id: String, accessType: String
        public let stopped: Bool
        var rank: Int { stopped ? 2 : accessType == "ONGOING" ? 0 : 1 }
        var json: JSONText { .object([("id", .string(id)), ("accessType", .string(accessType)), ("stopped", .bool(stopped))]) }
    }
    public struct Availability: Equatable, Sendable {
        public let failure: AnalyticsFailure?
        public let requestId: String?, latestProcessingDate: String?
        public let matchingInstances: Int
        public var needsSetup: Bool { failure == .setup || failure == .inactive }
        var json: JSONText {
            .object([("matchingInstances", .number(Double(matchingInstances)))]
                    + (failure.map { [("code", JSONText.string(AnalyticsCatalog.code($0)!))] } ?? [])
                    + (requestId.map { [("requestId", JSONText.string($0))] } ?? [])
                    + (latestProcessingDate.map { [("latestProcessingDate", JSONText.string($0))] } ?? []))
        }
    }
    public let requests: [Request], availability: Availability
    public var json: JSONText { .object([("requests", .array(requests.map(\.json))), ("availability", availability.json)]) }

    static let failures: [(String, AnalyticsFailure)] = [("SB-ANALYTICS-SETUP", .setup), ("SB-ANALYTICS-INACTIVE", .inactive),
        ("SB-ANALYTICS-REPORT-MISSING", .reportMissing), ("SB-ANALYTICS-PERIOD", .period), ("SB-ANALYTICS-NO-INSTANCES", .noInstances)]
    static func code(_ failure: AnalyticsFailure) -> String? { failures.first { $0.1 == failure }?.0 }
    static func id(_ value: String) -> Bool { value.range(of: #"\A[a-zA-Z0-9_-]{1,256}\z"#, options: .regularExpression) != nil }

    /// The bounded catalog contract; scope is checked by the caller.
    public init(json: JSONText) throws {
        guard case .array(let rows)? = json["requests"], rows.count <= 100, let info = json["availability"],
              case .number(let raw)? = info["matchingInstances"], let count = Int(exactly: raw), (0...365).contains(count) else { throw AnalyticsFailure.integrity }
        let requests = try rows.map { row in
            guard let identifier = row["id"]?.text, Self.id(identifier), let access = row["accessType"]?.text,
                  ["ONGOING", "ONE_TIME_SNAPSHOT"].contains(access), case .bool(let stopped)? = row["stopped"] else { throw AnalyticsFailure.integrity }
            return Request(id: identifier, accessType: access, stopped: stopped)
        }
        guard Set(requests.map(\.id)).count == requests.count else { throw AnalyticsFailure.integrity }
        let failure: AnalyticsFailure?
        if let value = info["code"] {
            guard let text = value.text, let found = Self.failures.first(where: { $0.0 == text }) else { throw AnalyticsFailure.integrity }
            failure = found.1
        } else { failure = nil }
        let requestId: String?, latest: String?
        if let value = info["requestId"] {
            guard let text = value.text, requests.contains(where: { $0.id == text }) else { throw AnalyticsFailure.integrity }
            requestId = text
        } else { requestId = nil }
        if let value = info["latestProcessingDate"] {
            guard let text = value.text, PeriodDates.number(text) != nil, requestId != nil else { throw AnalyticsFailure.integrity }
            latest = text
        } else { latest = nil }
        guard failure == nil ? count > 0 && latest != nil : count == 0 else { throw AnalyticsFailure.integrity }
        self.requests = requests
        availability = Availability(failure: failure, requestId: requestId, latestProcessingDate: latest, matchingInstances: count)
    }

    static func requests(_ resources: [AppStoreConnectClient.Resource]) throws -> [Request] {
        guard resources.count <= 100 else { throw AnalyticsFailure.limit }
        guard resources.allSatisfy({ id($0.id) }), Set(resources.map(\.id)).count == resources.count else { throw AnalyticsFailure.integrity }
        return try resources.map { item in
            guard item.type == "analyticsReportRequests", let access = item.attributes?["accessType"]?.string,
                  ["ONGOING", "ONE_TIME_SNAPSHOT"].contains(access) else { throw AnalyticsFailure.download }
            var stopped = false
            if let value = item.attributes?["stoppedDueToInactivity"] {
                guard case .bool(let flag) = value else { throw AnalyticsFailure.download }; stopped = flag
            }
            return Request(id: item.id, accessType: access, stopped: stopped)
        }
    }

    public struct Instance: Equatable, Sendable { public let id: String, processingDate: String }
    /// Validate all returned metadata before selecting a granularity or processing window.
    public static func instances(_ resources: [AppStoreConnectClient.Resource], granularity: String) throws -> [Instance] {
        guard resources.count <= 200_000 else { throw AnalyticsFailure.limit }
        guard ["DAILY", "WEEKLY", "MONTHLY"].contains(granularity) else { throw AnalyticsFailure.format }
        var identifiers = Set<String>(), dates = Set<String>(), result: [Instance] = []
        for item in resources {
            guard id(item.id), identifiers.insert(item.id).inserted else { throw AnalyticsFailure.integrity }
            guard item.type == "analyticsReportInstances", let date = item.attributes?["processingDate"]?.string, PeriodDates.number(date) != nil,
                  let unit = item.attributes?["granularity"]?.string, ["DAILY", "WEEKLY", "MONTHLY"].contains(unit) else { throw AnalyticsFailure.download }
            if unit == granularity {
                guard dates.insert(date).inserted else { throw AnalyticsFailure.integrity }
                result.append(Instance(id: item.id, processingDate: date))
            }
        }
        return result.sorted { ($0.processingDate, $0.id) < ($1.processingDate, $1.id) }
    }
}

extension WorkspaceSession {
    func analyticsCheckedList(account: Account, appId: String, client: AppStoreConnectClient, path: String, limit: Int) async throws -> [AppStoreConnectClient.Resource] {
        try Task.checkCancellation(); try analyticsFileScope(account, appId: appId); _ = try currentAccount(account, client: client)
        let rows = try await Self.analyticsList(client, path, limit: limit)
        try Task.checkCancellation(); try analyticsFileScope(account, appId: appId); _ = try currentAccount(account, client: client)
        return rows
    }

    func analyticsDiscovery(account: Account, appId: String, kind: String, processingDays: [String], client: AppStoreConnectClient,
                            level: String, granularity: String, requestId: String?, now: Date) async throws -> (AnalyticsCatalog, [AnalyticsCatalog.Instance]) {
        try Task.checkCancellation(); try analyticsFileScope(account, appId: appId); _ = try currentAccount(account, client: client)
        guard now.timeIntervalSince1970.isFinite else { throw AnalyticsFailure.access }
        let today = PeriodDates.text(now)
        guard !processingDays.isEmpty, processingDays.count <= 365, Set(processingDays).count == processingDays.count,
              processingDays.allSatisfy({ PeriodDates.number($0) != nil && $0 <= today }) else { throw AnalyticsFailure.access }
        _ = try AnalyticsMetadata(kind: kind, level: level, granularity: granularity, processingDate: processingDays[0])
        if let requestId { guard AnalyticsCatalog.id(requestId) else { throw AnalyticsFailure.access } }
        let requests = try AnalyticsCatalog.requests(await analyticsCheckedList(account: account, appId: appId, client: client,
            path: "/v1/apps/\(appId)/analyticsReportRequests?limit=200", limit: 100))
        let candidates = requests.enumerated().sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }.map(\.element)
            .filter { requestId == nil || $0.id == requestId }
        if requestId != nil, candidates.isEmpty { throw AnalyticsFailure.access }
        let wanted = Set(processingDays), names = AnalyticsReports.reportNames(kind: kind, level: level)
        var reportFound = false, latest: (id: String, date: String)?
        func catalog(_ instances: [AnalyticsCatalog.Instance], failure: AnalyticsFailure? = nil, selected: String? = nil, date: String? = nil) throws -> AnalyticsCatalog {
            let info = AnalyticsCatalog.Availability(failure: failure, requestId: selected, latestProcessingDate: date, matchingInstances: instances.count)
            return try AnalyticsCatalog(json: .object([("requests", .array(requests.map(\.json))), ("availability", info.json)]))
        }
        for request in candidates {
            let reports = try await analyticsCheckedList(account: account, appId: appId, client: client,
                path: "/v1/analyticsReportRequests/\(request.id)/reports?limit=200", limit: 200)
            let matches = reports.filter { $0.type == "analyticsReports" && names.contains($0.attributes?["name"]?.string ?? "") }
            guard matches.count <= 1 else { throw AnalyticsFailure.integrity }
            guard let report = matches.first else { continue }; reportFound = true
            let available = try AnalyticsCatalog.instances(await analyticsCheckedList(account: account, appId: appId, client: client,
                path: "/v1/analyticsReports/\(report.id)/instances?filter%5Bgranularity%5D=\(granularity)&limit=200", limit: 200_000), granularity: granularity)
            let date = available.last?.processingDate
            if let date, latest.map({ date > $0.date }) ?? true { latest = (request.id, date) }
            let matching = available.filter { wanted.contains($0.processingDate) }
            if !matching.isEmpty { return (try catalog(matching, selected: request.id, date: date), matching) }
        }
        let failure: AnalyticsFailure = candidates.isEmpty ? .setup : latest != nil ? .period : candidates.allSatisfy(\.stopped) ? .inactive : !reportFound ? .reportMissing : .noInstances
        return (try catalog([], failure: failure, selected: latest?.id, date: latest?.date), [])
    }

    /// Reads existing requests and instance metadata; no report file or Apple write is requested.
    public func availableAnalyticsCatalog(account: Account, appId: String, kind: String, processingDays: [String], client: AppStoreConnectClient,
                                          now: Date = Date(), level: String = "standard", granularity: String = "DAILY", requestId: String? = nil) async throws -> AnalyticsCatalog {
        try await analyticsDiscovery(account: account, appId: appId, kind: kind, processingDays: processingDays, client: client,
                                     level: level, granularity: granularity, requestId: requestId, now: now).0
    }
}
