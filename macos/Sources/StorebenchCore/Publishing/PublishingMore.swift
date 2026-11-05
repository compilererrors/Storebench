import Foundation

extension WorkspaceSession {
    func appVersions(_ planner: Planner) async throws -> [AppStoreConnectClient.Resource] {
        let appId = planner.request.appId
        let versions = try await planner.list("/v1/apps/\(appId)/appStoreVersions?include=app&limit=200")
        guard versions.allSatisfy({ $0.type == "appStoreVersions" && Apple.owned($0, "app", "apps", appId) }) else { throw PublishFailure.invalid("Apple returned versions outside the selected app.") }
        return versions
    }

    /// Plans the version copyright: one version's copyright, guarded by its current value.
    func planCopyright(_ planner: Planner) async throws -> String {
        let request = planner.request
        guard let version = try await appVersions(planner).first(where: { $0.id == request.versionId }) else { throw PublishFailure.invalid("Choose an Apple version belonging to this app.") }
        guard Apple.editable.contains(Apple.state(version)) else { throw PublishFailure.invalid("This Apple version is not editable. Choose a version being prepared for review.") }
        let copyright = request.copyright ?? "", current = version.attributes?["copyright"]?.string
        let name = "\(Releases.platformName(version.attributes?["platform"]?.string ?? "")) \(version.attributes?["versionString"]?.string ?? "")"
        if current != copyright {
            planner.add(.api, method: "PATCH", path: [.string("appStoreVersions"), .string(version.id)], label: "Update copyright · \(name)", detail: "Changes the rights holder shown for this App Store version.",
                        before: current ?? "No copyright at Apple", after: copyright,
                        body: .object([("data", .object([("type", .string("appStoreVersions")), ("id", .string(version.id)), ("attributes", .object([("copyright", .string(copyright))]))]))]),
                        guard: .object([("kind", .string("version-copyright")), ("digest", .string(Apple.jsonDigest(current.map { .string($0) } ?? .null)))]))
        }
        planner.notes.append("Apple's copyright field should start with the year the rights were obtained, followed by the rights holder. This review changes only the selected version's copyright.")
        return "Version copyright · \(name)"
    }

    /// Plans the Analytics request: asks Apple to generate Analytics reports for this app, once.
    func planAnalyticsRequest(_ planner: Planner) async throws -> String {
        let request = planner.request, access = request.scope == .analyticsSnapshot ? "ONE_TIME_SNAPSHOT" : "ONGOING"
        let requests = try await planner.list("/v1/apps/\(request.appId)/analyticsReportRequests?limit=200")
        guard requests.count <= 100, requests.allSatisfy({ $0.type == "analyticsReportRequests" }) else { throw PublishFailure.invalid("Apple returned unexpected Analytics report requests.") }
        let existing = requests.first { $0.attributes?["accessType"]?.string == access && (access == "ONE_TIME_SNAPSHOT" || $0.attributes?["stoppedDueToInactivity"] != .bool(true)) }
        planner.notes.append("An Admin API role is required to create Analytics report requests. Apple checks this permission when the request is sent. Initial reports can take 1–2 days to generate.")
        if existing != nil {
            planner.notes.append("This app already has this report request. Return to Analytics and download its reports. Existing requests and data are kept.")
        } else {
            planner.add(.api, method: "POST", path: [.string("analyticsReportRequests")], label: access == "ONGOING" ? "Start ongoing Analytics reports" : "Request a historical Analytics snapshot",
                        detail: "Create a report request for this app. App metadata, releases and prices are unchanged. This does not release or submit an app version.",
                        before: "No matching available report request", after: access == "ONGOING" ? "Ongoing Analytics report generation requested" : "One-time historical snapshot requested",
                        body: .object([("data", .object([("type", .string("analyticsReportRequests")), ("attributes", .object([("accessType", .string(access))])), ("relationships", .object([("app", Apple.relationship("apps", .string(request.appId)))]))]))]))
        }
        return access == "ONGOING" ? "Set up ongoing Analytics reports" : "Set up a historical Analytics snapshot"
    }

    struct PriceInterval { let territory, pointId, amount, currency: String; var start, end: String? }

    /// Apple's current price schedule and its digest.
    func priceScheduleSnapshot(appId: String, client: AppStoreConnectClient, planner: Planner? = nil) async throws -> (schedule: String, base: String, manual: [PriceRow], automatic: [PriceRow], pointIds: [String: String], digest: String) {
        let get = { (path: String) in planner != nil ? try await planner!.get(path) : try await client.get(path) }
        let pages = { (path: String) in planner != nil ? try await planner!.listWithIncluded(path) : try await client.listWithIncluded(path) }
        guard let schedule = try await get("/v1/apps/\(appId)/appPriceSchedule?include=app").first, schedule.type == "appPriceSchedules", Apple.owned(schedule, "app", "apps", appId) else {
            throw PublishFailure.invalid("Apple price schedule no longer belongs to the approved app.")
        }
        guard let base = try await get("/v1/appPriceSchedules/\(schedule.id)/baseTerritory").first, base.type == "territories" else { throw PublishFailure.invalid("Apple's base territory is unavailable.") }
        let query = "?limit=200&include=appPricePoint%2Cterritory"
        let manual = try await pages("/v1/appPriceSchedules/\(schedule.id)/manualPrices\(query)"), automatic = try await pages("/v1/appPriceSchedules/\(schedule.id)/automaticPrices\(query)")
        var points: [String: String] = [:]
        func rows(_ page: (data: [AppStoreConnectClient.Resource], included: [AppStoreConnectClient.Resource]), _ source: String) throws -> (JSONText, [PriceRow]) {
            guard page.data.allSatisfy({ $0.type == "appPrices" }), Set(page.data.map(\.id)).count == page.data.count else { throw PublishFailure.invalid("Apple returned an ambiguous app price schedule.") }
            var seen: [String: String] = [:]
            for item in page.included where item.type == "territories" || item.type == "appPricePoints" {
                let value = item.type == "territories" ? JSONText.array([Apple.text(item.attributes?["currency"]).map { .string($0) } ?? .null]).stringify()
                    : JSONText.array([Apple.text(item.attributes?["customerPrice"]).map { .string($0) } ?? .null, Apple.text(item.attributes?["proceeds"]).map { .string($0) } ?? .null]).stringify()
                if let previous = seen["\(item.type):\(item.id)"], previous != value { throw PublishFailure.invalid("Apple returned conflicting app price details.") }
                seen["\(item.type):\(item.id)"] = value
            }
            let parsed = Self.priceRows(page, source: source)
            var entries: [JSONText] = []
            for row in parsed.sorted(by: { $0.id < $1.id }) {
                guard let point = page.data.first(where: { $0.id == row.id }).flatMap({ Apple.owner($0, "appPricePoint") }), point.type == "appPricePoints", !row.territory.isEmpty, !row.currency.isEmpty, !row.customerPrice.isEmpty else {
                    throw PublishFailure.invalid("Apple returned incomplete app price details.")
                }
                points[row.id] = point.id
                entries.append(.object([("id", .string(row.id)), ("territory", .string(row.territory)), ("pointId", .string(point.id)), ("currency", .string(row.currency)), ("customerPrice", .string(row.customerPrice)),
                                        ("proceeds", .string(row.proceeds)), ("startDate", row.startDate.map { .string($0) } ?? .null), ("endDate", row.endDate.map { .string($0) } ?? .null)]))
            }
            return (.array(entries), parsed)
        }
        let (manualJSON, manualRows) = try rows(manual, "manual"), (automaticJSON, automaticRows) = try rows(automatic, "automatic")
        let digest = JSONText.object([("appId", .string(appId)), ("scheduleId", .string(schedule.id)), ("baseTerritory", .string(base.id)), ("manual", manualJSON), ("automatic", automaticJSON)]).sha256
        return (schedule.id, base.id, manualRows, automaticRows, points, digest)
    }

    static func nextDate(_ date: String) throws -> String {
        guard ReportTables.validDate(date), let value = ReportTables.dayFormat.date(from: date) else { throw PublishFailure.invalid("Invalid price date.") }
        return ReportTables.dayFormat.string(from: value.addingTimeInterval(86_400))
    }

    /// Apple price intervals use an inclusive start and an exclusive end.
    static func overlay(_ schedule: [PriceInterval], _ incoming: PriceInterval, today: String) throws -> [PriceInterval] {
        let start = incoming.start ?? today, end = incoming.end ?? "9999-12-31"
        guard start >= today, start < end else { throw PublishFailure.invalid("A price change needs a current or future date range.") }
        var result: [PriceInterval] = []
        for item in schedule {
            let a = item.start ?? today, b = item.end ?? "9999-12-31"
            if b <= today { continue }
            if item.territory != incoming.territory || a >= end || b <= start { result.append(item); continue }
            if a < start { var head = item; head.end = start; result.append(head) }
            if b > end { var tail = item; tail.start = incoming.end; result.append(tail) }
        }
        result.append(incoming)
        return result.sorted { ($0.territory, $0.start ?? "") < ($1.territory, $1.start ?? "") }
    }

    /// Plans price changes: the saved model and country drafts become one new manual price schedule.
    /// Protected countries and Apple's existing future prices are kept.
    func planPrices(_ planner: Planner, account: Account) async throws -> String {
        let request = planner.request, client = planner.client
        let state = try pricingProfiles()
        if let id = request.profileId, !state.profiles.contains(where: { $0.id == id }) { throw PublishFailure.invalid("Choose an existing pricing profile.") }
        guard let template = state.profiles.first(where: { $0.id == (request.profileId ?? state.defaultId) }) ?? state.profiles.first else { throw PublishFailure.invalid("Choose an existing pricing profile.") }
        let territories = try await planner.list("/v1/territories?limit=200").compactMap { item -> Territory? in
            guard item.type == "territories", item.id.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil, let currency = item.attributes?["currency"]?.string, currency.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil else { return nil }
            return Territory(code: item.id, name: Self.countryName(item.id), currency: currency)
        }.sorted { ($0.name, $0.code) < ($1.name, $1.code) }
        guard let currency = territories.first(where: { $0.code == template.guideTerritory })?.currency else { throw PublishFailure.invalid("The guide country's currency is unavailable.") }
        guard let model = try appPricingModel(accountId: request.accountId, appId: request.appId, profileId: template.id, currency: currency) else { throw PublishFailure.invalid("Choose an existing pricing profile.") }
        let drafts = try pricingDrafts(accountId: request.accountId, appId: request.appId), locks = try priceProtection(accountId: request.accountId, appId: request.appId)
        let locked = Set(locks.map(\.territory))
        planner.evidence.append(.object([("profile", model.profile.json), ("baseAmount", .string(model.base)), ("drafts", .array(drafts.map(\.json))), ("locks", .array(locks.map { .array([.string($0.territory), .string($0.customerPrice), .string($0.currency)]) }))]))
        let snapshot = try await priceScheduleSnapshot(appId: request.appId, client: client, planner: planner)
        planner.evidence.append(.object([("scheduleId", .string(snapshot.schedule))]))
        let today = ReportTables.dayFormat.string(from: Date())
        func intervals(_ rows: [PriceRow]) -> [PriceInterval] {
            rows.filter { $0.endDate.map { $0 > today } ?? true }.map { PriceInterval(territory: $0.territory, pointId: snapshot.pointIds[$0.id] ?? "", amount: $0.customerPrice, currency: $0.currency, start: $0.startDate.flatMap { $0 > today ? $0 : nil }, end: $0.endDate) }
        }
        let originalManual = intervals(snapshot.manual), originalAuto = intervals(snapshot.automatic), original = originalAuto + originalManual
        var modelRows: [ModelPrice] = []
        if !model.base.isEmpty { modelRows = try await modelPreview(appId: request.appId, profile: model.profile, base: model.base, countries: territories, guideCurrency: currency, client: client).rows }
        planner.evidence.append(.object([("model", .array(modelRows.map { .array([.string($0.territory), $0.amount.map { .string($0) } ?? .null, $0.problem.map { .string($0) } ?? .null]) }))]))
        var proposed: [PriceInterval] = []
        for country in territories where !locked.contains(country.code) {
            let override = drafts.first { $0.territory == country.code && $0.startDate == nil }, row = modelRows.first { $0.territory == country.code }
            if override == nil, let problem = row?.problem { throw PublishFailure.invalid("\(country.code): \(problem)") }
            let existing = original.last { $0.territory == country.code && $0.start == nil }
            if let amount = override?.amount ?? row?.amount, existing.flatMap({ PricingMath.decimal($0.amount) }) != PricingMath.decimal(amount) {
                if let override, override.currency != country.currency { throw PublishFailure.invalid("\(country.code): the saved currency changed. Save this override again.") }
                let next = original.filter { $0.territory == country.code }.compactMap(\.start).sorted().first
                proposed.append(PriceInterval(territory: country.code, pointId: "", amount: amount, currency: country.currency, start: nil, end: next))
            }
            for temporary in drafts where temporary.territory == country.code && temporary.startDate != nil {
                guard let start = temporary.startDate, let last = temporary.endDate, start >= today else { throw PublishFailure.invalid("\(country.code): update or remove the past temporary price before publishing.") }
                let end = try Self.nextDate(last)
                guard temporary.currency == country.currency else { throw PublishFailure.invalid("\(country.code): the saved currency changed.") }
                if original.contains(where: { $0.territory == country.code && ($0.start.map { $0 < end } ?? false) && ($0.end.map { $0 > start } ?? true) }) { throw PublishFailure.invalid("\(country.code): the temporary price overlaps Apple's future schedule. Resolve that schedule first.") }
                guard existing != nil else { throw PublishFailure.invalid("\(country.code): no current price is available to restore after the temporary period.") }
                proposed.append(PriceInterval(territory: country.code, pointId: "", amount: temporary.amount, currency: country.currency, start: start, end: end))
            }
        }
        guard !proposed.isEmpty else { planner.notes.append("Saved model and country prices already match Apple, or all selected countries are protected."); return "No price changes" }
        var points: [AppStoreConnectClient.Resource] = []
        var codes: [String] = []
        for item in proposed where !codes.contains(item.territory) { codes.append(item.territory) }
        for start in stride(from: 0, to: codes.count, by: 25) {
            points += try await planner.list("/v1/apps/\(request.appId)/appPricePoints?filter%5Bterritory%5D=\(codes[start..<min(start + 25, codes.count)].joined(separator: "%2C"))&limit=200")
        }
        let changes = try proposed.map { item -> PriceInterval in
            guard let point = points.first(where: { Self.linked($0, "territory") == item.territory && Apple.text($0.attributes?["customerPrice"]).flatMap(PricingMath.decimal) == PricingMath.decimal(item.amount) }) else {
                throw PublishFailure.invalid("\(item.territory): \(item.amount) \(item.currency) is not an available Apple price point. Choose an available amount in Pricing; Storebench will not silently change it.")
            }
            var change = item; change = PriceInterval(territory: item.territory, pointId: point.id, amount: item.amount, currency: item.currency, start: item.start, end: item.end); return change
        }
        let baseChanges = changes.contains { $0.territory == snapshot.base }
        var final = originalManual
        // Automatic territories are kept explicitly when a base change would otherwise recalculate them.
        for item in originalAuto where baseChanges || changes.contains(where: { $0.territory == item.territory }) {
            if !final.contains(where: { $0.territory == item.territory && $0.start == item.start && $0.end == item.end }) { final.append(item) }
        }
        for change in changes { final = try Self.overlay(final, change, today: today) }
        guard final.contains(where: { $0.territory == snapshot.base && $0.start == nil }) else { throw PublishFailure.invalid("The Apple base price is missing. Refresh the app's price schedule first.") }
        guard final.count <= 2000 else { throw PublishFailure.invalid("This price schedule is too large to publish together.") }
        let included = final.enumerated().map { index, item in
            JSONText.object([("type", .string("appPrices")), ("id", .string("${price-\(index)}")), ("attributes", .object([("startDate", item.start.map { .string($0) } ?? .null), ("endDate", item.end.map { .string($0) } ?? .null)])),
                             ("relationships", .object([("appPricePoint", Apple.relationship("appPricePoints", .string(item.pointId)))]))])
        }
        func describe(_ rows: [PriceInterval]) -> String { rows.map { "\($0.territory): \($0.amount) \($0.currency) · \($0.start ?? "Now") → \($0.end.map { "before \($0)" } ?? "ongoing")" }.joined(separator: "\n") }
        planner.add(.api, method: "POST", path: [.string("appPriceSchedules")], label: "Publish prices · \(codes.count) \(codes.count == 1 ? "country" : "countries")",
                    detail: "Replace the manual schedule with the reviewed prices. Existing future prices and protected countries are preserved.", before: describe(original), after: describe(final),
                    body: .object([("data", .object([("type", .string("appPriceSchedules")), ("relationships", .object([("app", Apple.relationship("apps", .string(request.appId))), ("baseTerritory", Apple.relationship("territories", .string(snapshot.base))),
                                                                                                                       ("manualPrices", .object([("data", .array(included.map { .object([("type", $0["type"]!), ("id", $0["id"]!)]) }))]))]))])), ("included", .array(included))]),
                    guard: .object([("kind", .string("app-price-schedule")), ("digest", .string(snapshot.digest))]))
        if baseChanges { planner.notes.append("Changing the base price can change Apple's automatic prices. This review converts the listed automatic prices to manual prices at their existing amounts so other countries, including protected countries, keep their prices. Apple will no longer automatically adjust those countries.") }
        planner.notes.append("Temporary prices include the last day chosen in Pricing. The review shows Apple's exclusive end date. Existing future price changes resume on their scheduled dates.")
        planner.notes.append("Publishing retains local pricing drafts. Remove a completed temporary draft before preparing a different schedule.")
        return "Publish pricing · \(model.profile.name)"
    }
}
