import Foundation

extension WorkspaceSession {
    /// Reads connection and existing Analytics metadata. No report is downloaded or generated.
    public func refreshSyncSetup(account: Account, appId: String, client: AppStoreConnectClient? = nil, now: Date = Date()) async throws -> SyncJob? {
        try reviewsScope(account, appId: appId); try Task.checkCancellation()
        let client = try client ?? self.client(for: account), days = SalesReports.days(ending: PeriodDates.text(now), count: 7)
        async let downloads = availableAnalyticsCatalog(account: account, appId: appId, kind: "downloads", processingDays: days, client: client, now: now)
        async let engagement = availableAnalyticsCatalog(account: account, appId: appId, kind: "engagement", processingDays: days, client: client, now: now)
        let catalogs = try await [downloads, engagement]
        try Task.checkCancellation(); try reviewsScope(account, appId: appId); _ = try currentAccount(account, client: client)
        let checked = CustomerReview.isoString(now)
        let connected = try FileMutex.withLock(reportingMutex(accountId: account.id)) { try salesConnection(accountId: account.id).map { $0.reporter != nil || account.keyType == "team" && !$0.vendorNumber.isEmpty } ?? false }
        let finance = try financialDownloadJob(account: account, appId: appId, now: now)
        func needs(_ key: String, _ code: String) -> SyncItem { SyncItem(key: key, state: .attention, detail: ReportingMessages.message(code), checkedAt: checked, code: code) }
        var items = [connected ? SyncItem(key: "sales", state: .ready, detail: "Reporting connection is set up. Run Sync or open Sales to download reports; this check downloaded none.", checkedAt: checked) : needs("sales", "SB-SYNC-CONNECTION")]
        for (index, key) in ["downloads", "engagement"].enumerated() {
            let catalog = catalogs[index]
            if catalog.requests.isEmpty { items.append(needs(key, "SB-ANALYTICS-SETUP")) }
            else if catalog.requests.allSatisfy(\.stopped) { items.append(needs(key, "SB-ANALYTICS-INACTIVE")) }
            else if catalog.availability.matchingInstances > 0 || catalog.availability.latestProcessingDate != nil {
                items.append(SyncItem(key: key, state: .ready, detail: "Analytics reports are available in Apple. Open Analytics or run Sync to download them; this status check downloaded no report data.", checkedAt: checked))
            } else { items.append(SyncItem(key: key, state: .waiting, detail: "Analytics report generation is enabled in Apple. Reports are still being prepared; this status check downloaded no report data.", checkedAt: checked)) }
        }
        items.append(finance == nil ? needs("finance", "SB-SYNC-FISCAL-PERIOD") : !connected ? needs("finance", "SB-SYNC-CONNECTION") : SyncItem(key: "finance", state: .ready, detail: "A fiscal selection and reporting connection are saved. Open Finance to review or download reports; this check downloaded none.", checkedAt: checked))
        // A setup check is a disposable projection, never a replacement for saved source results.
        try storeAccess { store in try store.transaction { current in
            let key = "\(account.id):\(appId)", previous = try current("sync_setup", key).map { try JSONText.parse($0.payload) }
            let id: String
            if let previous {
                guard previous["schemaVersion"] == .number(1), previous["accountId"] == .string(account.id), previous["appId"] == .string(appId), let savedId = previous["id"]?.text, ReportJobs.uuid(savedId),
                      let time = previous["checkedAt"]?.text, ReportTimestamps.shortValid(time), case .array(let rows)? = previous["items"], rows.count <= 4 else { throw SyncFailure.status }
                let prior = try rows.map { try SyncItem(json: $0) }
                guard Set(prior.map(\.key)).count == prior.count, prior.allSatisfy({ ["sales", "downloads", "engagement", "finance"].contains($0.key) && [.attention, .waiting, .ready].contains($0.state) && $0.checkedAt != nil && ($0.state == .attention ? AppSync.setupCodes.contains($0.code ?? "") : $0.code == nil) }) else { throw SyncFailure.status }
                if AppSync.newer(time, than: checked), time != checked { return [] }
                id = savedId
            } else { id = UUID().uuidString.lowercased() }
            let json = JSONText.object([("schemaVersion", .number(1)), ("id", .string(id)), ("accountId", .string(account.id)), ("appId", .string(appId)), ("checkedAt", .string(checked)), ("items", .array(items.map(\.json)))])
            return [.put(namespace: "sync_setup", key: key, json: json.data)]
        } }
        return try syncStatus(account: account, appId: appId, now: now)
    }
}
