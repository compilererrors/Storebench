import CryptoKit
import Darwin
import Foundation

/// Issued only by `approvePublishing` for one consumed review; Apple writes require it.
struct PublishGrant { let accountId, appId, reviewId: String; fileprivate init(accountId: String, appId: String, reviewId: String) { self.accountId = accountId; self.appId = appId; self.reviewId = reviewId } }

extension AppStoreConnectClient {
    /// One Apple write. Only the publishing service can call it, with a grant for an approved review.
    func write(_ method: String, _ path: String, body: JSONText?, grant: PublishGrant) async throws -> Resource? {
        try accessCheck()
        guard ["POST", "PATCH", "DELETE"].contains(method), let url = URL(string: path, relativeTo: origin), url.host == origin.host, path.hasPrefix("/v1/") || path.hasPrefix("/v2/") && PricingSetupWrites.version2.contains(path.split(separator: "/").dropFirst().first.map(String.init) ?? "") else { throw PublishFailure.write("Unsupported Apple write.") }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = method
        request.setValue("Bearer \(try token.signed())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body?.data
        let (data, response) = try await session.data(for: request, delegate: self)
        guard let http = response as? HTTPURLResponse else { throw Failure.unreadableResponse }
        AppleRequestBudget.record(http, keyId: token.account.keyId)
        if [409, 422].contains(http.statusCode) {
            // Apple names what is wrong; keep its codes so a stopped Save says what to fix instead of only "refused".
            let problems = AppleProblem.parse(data: data, contentType: http.value(forHTTPHeaderField: "Content-Type"), resource: path.split(separator: "/").dropFirst().first.map(String.init))
            if !problems.isEmpty { throw PublishFailure.refused(AppleProblem.summary(problems, status: http.statusCode), problems: problems) }
        }
        guard (200..<300).contains(http.statusCode) else { throw Self.failure(status: http.statusCode, data: data, contentType: http.value(forHTTPHeaderField: "Content-Type")) }
        if http.statusCode == 204 || data.isEmpty { return nil }
        return (try? JSONDecoder().decode(Page.self, from: data))?.data.resources.first
    }

    /// One reserved upload part, sent to Apple's asset storage without the API token.
    func uploadPart(_ url: URL, headers: [(String, String)], body: Data) async throws {
        try accessCheck()
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "PUT"
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpShouldHandleCookies = false
        let (_, response) = try await session.upload(for: request, from: body, delegate: TransferMeter(.shared))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw PublishFailure.write("Asset upload returned an error. Prepare a new review.") }
    }
}

extension WorkspaceSession {
    // MARK: Reviews

    func publishKey(_ accountId: String, _ appId: String, _ id: String) -> String { "\(accountId):\(appId):\(id)" }

    public func publishReview(accountId: String, appId: String, id: String) throws -> PublishReview {
        try storeAccess { store in
            guard let document = try store.document(namespace: "publish_reviews", key: publishKey(accountId, appId, id)), let review = PublishReview(try JSONText.parse(document.payload)),
                  review.id == id, review.request.accountId == accountId, review.request.appId == appId else { throw PublishFailure.invalid("Publishing review was not found.") }
            return review
        }
    }

    /// Reviews for one app, newest first.
    public func publishHistory(accountId: String, appId: String) throws -> [PublishReview] {
        try storeAccess { store in
            try store.documents(namespace: "publish_reviews", prefix: "\(accountId):\(appId):").compactMap { document -> PublishReview? in
                guard let review = PublishReview(try JSONText.parse(document.payload)), review.request.accountId == accountId, review.request.appId == appId, document.key == publishKey(accountId, appId, review.id) else { return nil }; return review
            }
                .sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
        }
    }

    func savePublishReview(_ review: PublishReview, expected: Int?) throws -> Int {
        let key = publishKey(review.request.accountId, review.request.appId, review.id), data = review.json.data
        guard data.count <= 10_000_000 else { throw PublishFailure.invalid("Publishing review is too large.") }
        return try storeAccess { store in
            try store.transaction { current in
                guard try current("publish_reviews", key)?.revision == expected else { throw PublishFailure.conflict }
                return [.put(namespace: "publish_reviews", key: key, json: data)]
            }
            return try store.document(namespace: "publish_reviews", key: key)?.revision ?? 0
        }
    }

    /// Reads Apple and the local drafts and prepares a concrete review. Nothing is written to Apple here.
    public func preparePublishing(account: Account, request: PublishRequest, client: AppStoreConnectClient, now: Date = Date()) async throws -> PublishReview {
        let request = try request.validated()
        guard request.accountId == account.id, account.appIds.contains(request.appId) else { throw PublishFailure.invalid("App is not configured for this account.") }
        try requirePublishingAccount(account, appId: request.appId, client: client)
        let plan = try await publishPlan(account: account, request: request, client: client)
        let review = PublishReview(plan: plan, id: UUID().uuidString.lowercased(), now: now)
        _ = try savePublishReview(review, expected: nil)
        return review
    }

    /// Prepares a review with the account's uncached client, so the review reads Apple itself. Apple's refusals come back as `PublishFailure`.
    public func preparePublishing(account: Account, request: PublishRequest) async throws -> PublishReview {
        do { return try await preparePublishing(account: account, request: request, client: client(for: account)) }
        catch let failure as AppStoreConnectClient.Failure { throw Self.preparationFailure(failure, read: nil) }
    }

    /// A review prepared ahead is offered for this long; after that its step prepares a new one.
    static let reviewAheadLifetime: Duration = .seconds(600)

    /// Prepares a review before its step opens, such as Add for Review while the earlier Release steps are open.
    /// It is prepared exactly as the step would prepare it and saved like any review; nothing is sent to Apple.
    public func preparePublishingAhead(account: Account, request: PublishRequest) {
        let now = ContinuousClock.now
        reviewsAhead.removeAll { now - $0.started >= Self.reviewAheadLifetime }
        guard !reviewsAhead.contains(where: { $0.request == request }), let client = try? client(for: account) else { return }
        let task = Task { try await self.preparePublishing(account: account, request: request, client: client) }
        reviewsAhead.append((request, now, task))
        if reviewsAhead.count > 4 { reviewsAhead.removeFirst().task.cancel() }
    }

    /// The review prepared ahead for exactly this request, waiting for it if it is still being prepared. Nil when there is none,
    /// it failed or it is too old; the step then prepares the review itself and reports any problem.
    public func reviewPreparedAhead(_ request: PublishRequest) async -> PublishReview? {
        guard let index = reviewsAhead.firstIndex(where: { $0.request == request }) else { return nil }
        let entry = reviewsAhead.remove(at: index)
        guard ContinuousClock.now - entry.started < Self.reviewAheadLifetime, let review = try? await entry.task.value,
              let current = try? publishStatus(accountId: request.accountId, appId: request.appId, id: review.id), current.state == "prepared" else { return nil }
        return current
    }

    func requirePublishingAccount(_ account: Account, appId: String, client: AppStoreConnectClient) throws {
        func sameCredential(_ lhs: Account, _ rhs: Account) -> Bool {
            lhs.id == rhs.id && lhs.keyId == rhs.keyId && lhs.keyType == rhs.keyType && lhs.issuerId == rhs.issuerId
        }
        guard let configured = try accounts().first(where: { $0.id == account.id }), configured.appIds.contains(appId),
              account.appIds.contains(appId), client.token.account.appIds.contains(appId),
              sameCredential(configured, account), sameCredential(configured, client.token.account) else {
            throw PublishFailure.invalid("The configured Apple account or app changed. Reconnect and prepare a new review.")
        }
    }

    func publishPlan(account: Account, request: PublishRequest, client: AppStoreConnectClient) async throws -> PublishPlan {
        guard client.readCache == nil else { throw PublishFailure.invalid("Publishing requires a fresh Apple read. Prepare a new review.") }
        let planner = Planner(client: client, request: request)
        let title: String
        do {
            guard let app = try await planner.get("/v1/apps/\(request.appId)").first, app.type == "apps", app.id == request.appId else { throw PublishFailure.invalid("Apple returned a different app.") }
            switch request.scope {
            case .release, .metadata, .submit, .cancelSubmission, .releaseVersion, .versionBuild: title = try await planRelease(planner, account: account)
            case .versionCopyright: title = try await planCopyright(planner)
            case .analyticsOngoing, .analyticsSnapshot: title = try await planAnalyticsRequest(planner)
            case .pricing: title = try await planPrices(planner, account: account)
            case .productPricing: title = try await planProductPrice(planner)
            case .pricingSetup: title = try await planPricingSetup(planner)
            case .appPrivacy: title = try await planAppPrivacy(planner, account: account)
            case .taxCategory: title = try await planTaxCategory(planner, account: account)
            case .testflight: title = try await planTestFlight(planner)
            case .reviewInfo: title = try await planReviewInformation(planner)
            case .appInformation: title = try await planAppInformation(planner)
            case .availability: title = try await planAvailability(planner)
            case .ageRating: title = try await planAgeRating(planner)
            case .accessibility: title = try await planAccessibility(planner)
            case .exportCompliance: title = try await planEncryptionDeclaration(planner)
            case .exportDocument: title = try await planEncryptionDocument(planner)
            case .assetLibrary: title = try await planAssetLibrary(planner)
            }
        } catch { throw Self.preparationFailure(error, read: planner.failedRead) }
        guard planner.steps.count <= 2000 else { throw PublishFailure.invalid("This review exceeds 2,000 operations. Publish a smaller set of changes.") }
        let fingerprint = Apple.sha(Apple.canonical(.object([("request", request.json), ("account", .object([("id", .string(account.id)), ("keyId", .string(account.keyId)), ("keyType", .string(account.keyType))])),
                                                               ("evidence", .array(planner.evidence)), ("steps", .array(planner.steps.map(\.json)))])))
        return PublishPlan(title: title, request: request, fingerprint: fingerprint, steps: planner.steps, notes: planner.notes, settled: planner.settled.filter { name in !planner.steps.contains { $0.after == name || $0.guardValue?["asset"]?["fileName"]?.text == name } })
    }

    /// Apple's answer when a review cannot be prepared, naming the read that failed. Nothing was sent, since planning only reads.
    static func preparationFailure(_ error: Error, read: String?) -> Error {
        let source = read.map { " for \($0)" } ?? "", nothing = " Nothing was sent to App Store Connect."
        switch error {
        case is PublishFailure, is CancellationError: return error
        case AppStoreConnectClient.Failure.agreement: return PublishFailure.invalid(ReportingMessages.appleAgreement)
        case AppStoreConnectClient.Failure.status(let code) where code == 401 || code == 403:
            return PublishFailure.invalid("Apple did not allow this API key to read what this change needs (status \(code)\(source))." + nothing)
        case AppStoreConnectClient.Failure.status(let code): return PublishFailure.invalid("App Store Connect answered status \(code)\(source)." + nothing + " Prepare the review again.")
        case AppStoreConnectClient.Failure.unreadableResponse: return PublishFailure.invalid("App Store Connect's answer\(source) could not be read." + nothing)
        case let failure as AppStoreConnectClient.Failure: return PublishFailure.invalid("App Store Connect's answer\(source) was refused (\(failure))." + nothing)
        case let failure as URLError: return PublishFailure.invalid("App Store Connect could not be reached\(source) (\(failure.code.rawValue))." + nothing)
        default: return PublishFailure.invalid("The review could not be prepared (\(String(describing: error)))." + nothing)
        }
    }

    /// A review left running by a process that stopped is marked failed; it is never replayed.
    public func publishStatus(accountId: String, appId: String, id: String) throws -> PublishReview {
        let name = "publishing_" + JSONText.string("\(accountId)\u{0}\(appId)").rawSHA256.prefix(48)
        let directory = try storeAccess { $0.directory }
        guard let mutex = try FileMutex.tryLock(directory.appendingPathComponent("\(name).lock.mutex")) else { return try publishReview(accountId: accountId, appId: appId, id: id) }
        defer { mutex.release() }
        var review = try publishReview(accountId: accountId, appId: appId, id: id)
        guard review.state == "running" else { return review }
        if let owner = try JobLock.owner(try JobLock.privateFile(directory.appendingPathComponent("\(name).lock"))), owner.protocol != 2, JobLock.alive(owner.pid) { return review }
        let revision = try storeAccess { try $0.document(namespace: "publish_reviews", key: publishKey(accountId, appId, id))?.revision }
        review.state = "failed"; review.updatedAt = CustomerReview.isoString(Date())
        review.error = "Publishing was interrupted. Some changes may have reached Apple. Prepare a new review; this run will not be replayed."
        _ = try savePublishReview(review, expected: revision)
        return review
    }

    /// Approves a prepared review once: it must match the approved fingerprint, still be fresh and still match Apple and the drafts.
    /// The writes then run in order under the publishing lock.
    public func approvePublishing(account: Account, appId: String, id: String, fingerprint: String, client: AppStoreConnectClient, now: @Sendable () -> Date = Date.init) async throws -> PublishReview {
        try requireSessionAccess()
        let lease = try lifetime.admit(.publishing); defer { lease.finish() }
        await invalidateAppleReads()
        do {
            let result = try await SessionContext.$lease.withValue(lease) {
                try await approvePublishingAdmitted(account: account, appId: appId, id: id, fingerprint: fingerprint, client: client, now: now)
            }
            await invalidateAppleReads(); return result
        } catch {
            // A failed run can have completed earlier writes. No screen may reuse the pre-write observations.
            await invalidateAppleReads(); throw error
        }
    }
    private func approvePublishingAdmitted(account: Account, appId: String, id: String, fingerprint: String, client: AppStoreConnectClient, now: @Sendable () -> Date) async throws -> PublishReview {
        guard account.appIds.contains(appId) else { throw PublishFailure.invalid("App is not configured for this account.") }
        try requirePublishingAccount(account, appId: appId, client: client)
        let name = "publishing_" + JSONText.string("\(account.id)\u{0}\(appId)").rawSHA256.prefix(48)
        guard let release = try JobLock.acquire(directory: try storeAccess { $0.directory }, name: String(name), id: id) else { throw PublishFailure.busy }
        defer { release() }
        var revision = try storeAccess { try $0.document(namespace: "publish_reviews", key: publishKey(account.id, appId, id))?.revision }
        var review = try publishReview(accountId: account.id, appId: appId, id: id)
        _ = try review.request.validated()
        guard review.state == "prepared" else { throw PublishFailure.used }
        guard review.fingerprint == fingerprint, let expires = ISO8601DateFormatter.storebench.date(from: review.expiresAt), expires > now() else { throw PublishFailure.expired }
        guard !review.steps.isEmpty else { throw PublishFailure.noChanges }
        let fresh = try await publishPlan(account: account, request: review.request, client: client)
        guard fresh.fingerprint == review.fingerprint else {
            review.state = "conflict"; review.updatedAt = CustomerReview.isoString(now()); review.error = PublishFailure.conflict.message
            _ = try savePublishReview(review, expected: revision)
            throw PublishFailure.conflict
        }
        guard expires > now() else { throw PublishFailure.invalid("This review expired during revalidation. Prepare a new review.") }
        try requirePublishingAccount(account, appId: appId, client: client)
        review.state = "running"; review.pid = getpid(); review.approvedAt = CustomerReview.isoString(now()); review.updatedAt = review.approvedAt!
        revision = try savePublishReview(review, expected: revision)
        let grant = PublishGrant(accountId: account.id, appId: appId, reviewId: id)
        var ids: [String: String] = [:]
        // Apple returns a reservation's upload operations in its creation response; the upload step of that reservation uses them.
        var operations: [String: JSONValue] = [:]
        func persist() throws { review.updatedAt = CustomerReview.isoString(now()); revision = try savePublishReview(review, expected: revision) }
        do {
            var sentTogether = 0
            for index in review.steps.indices {
                if index < sentTogether { continue }
                let together = Self.stepsSentTogether(review.steps, from: index)
                if together.count > 1 {
                    // Independent single-country writes go several at a time; each is still checked against Apple just before it is sent.
                    try requirePublishingAccount(account, appId: appId, client: client)
                    let queued = try together.map { ($0, review.steps[$0], try Self.apiPath(review.steps[$0].path, ids: ids)) }
                    var failure: Error?
                    for wave in stride(from: 0, to: queued.count, by: Self.sendTogetherLimit) where failure == nil {
                        let sending = Array(queued[wave..<min(wave + Self.sendTogetherLimit, queued.count)])
                        try requirePublishingAccount(account, appId: appId, client: client)
                        for (item, _, _) in sending { review.steps[item].state = "running" }
                        try persist()
                        let results = await withTaskGroup(of: SentTogether.self, returning: [SentTogether].self) { group in
                            for entry in sending {
                                let item = entry.0, step = entry.1, path = entry.2
                                group.addTask { [self] in
                                    do {
                                        try await verifyWrite(method: step.method ?? "", path: path, body: step.body, guardValue: step.guardValue, appId: appId, client: client)
                                        try await requirePublishingAccount(account, appId: appId, client: client)
                                        let id = try await client.write(step.method ?? "", path, body: step.body, grant: grant)?.id
                                        return SentTogether(item: item, id: id, error: nil)
                                    } catch { return SentTogether(item: item, id: nil, error: error) }
                                }
                            }
                            var finished: [SentTogether] = []
                            for await result in group { finished.append(result) }
                            return finished
                        }
                        for result in results {
                            if let error = result.error { review.steps[result.item].state = "failed"; failure = failure ?? error; continue }
                            if let id = result.id { ids[review.steps[result.item].key] = id; review.steps[result.item].resultId = id }
                            if review.sentAt == nil { review.sentAt = CustomerReview.isoString(now()) }
                            review.steps[result.item].state = "done"
                        }
                        try persist()
                    }
                    if let failure { throw failure }
                    sentTogether = together.upperBound; continue
                }
                try requirePublishingAccount(account, appId: appId, client: client)
                review.steps[index].state = "running"; try persist()
                let step = review.steps[index]
                let path = try Self.apiPath(step.path, ids: ids)
                switch step.kind {
                case .api:
                    let body = try step.body.map { try Self.resolve($0, ids: ids) }
                    try await verifyWrite(method: step.method ?? "", path: path, body: body, guardValue: step.guardValue, appId: appId, client: client)
                    try requirePublishingAccount(account, appId: appId, client: client)
                    var result: AppStoreConnectClient.Resource?, placed: String?
                    for attempt in 1...3 {
                        do {
                            // App Privacy and Tax Category have no API key endpoint; their reviewed writes use the signed-in Apple ID.
                            if ["app-privacy", "tax-category"].contains(step.guardValue?["kind"]?.text) { result = try await appleWebClient(account: account, appId: appId).write(step.method ?? "", path, body: body, grant: grant) }
                            else { result = try await client.write(step.method ?? "", path, body: body, grant: grant) }
                            break
                        }
                        catch where attempt < 3 && step.guardValue?["kind"]?.text == "release-media-placement" && Self.transient(error) {
                            // Apple may have added the file before its answer was lost: look for it first, so it is never added twice.
                            try await Task.sleep(for: .seconds(3))
                            if let id = try await placedReleaseMedia(body: body, guardValue: step.guardValue, appId: appId, client: client) { placed = id; break }
                            try await verifyWrite(method: step.method ?? "", path: path, body: body, guardValue: step.guardValue, appId: appId, client: client)
                            try requirePublishingAccount(account, appId: appId, client: client)
                        }
                    }
                    if let id = result?.id ?? placed { ids[step.key] = id; review.steps[index].resultId = id }
                    if let reserved = result?.attributes?["uploadOperations"], case .array = reserved { operations[step.key] = reserved }
                case .upload:
                    if step.guardValue?["kind"]?.text == "release-media-upload" {
                        try await uploadReleaseMedia(path: path, step: step, reserved: Self.reservation(step.path).flatMap { operations[$0] }, accountId: account.id, appId: appId, client: client, grant: grant)
                        break
                    }
                    if step.asset?["storage"]?.text == "asset-library" {
                        let parts = path.split(separator: "/").map(String.init)
                        guard parts.count == 3, let asset = step.asset else { throw PublishFailure.conflict }
                        let reserved = try await libraryReader(appId: appId, client: client).asset(parts[2], kind: parts[1] == AssetLibrary.Kind.image.resource ? .image : .video)
                        try verifyLibraryUpload(reserved, guardValue: step.guardValue, accountId: account.id, appId: appId)
                        let resources = try await client.get(path)
                        guard let resource = resources.first, resource.id == reserved.id else { throw PublishFailure.conflict }
                        try await uploadLibraryFile(asset, operations: Self.reservation(step.path).flatMap { operations[$0] } ?? resource.attributes?["uploadOperations"], accountId: account.id, appId: appId, client: client)
                        break
                    }
                    guard let asset = step.asset, let resource = try await ownedMedia(path: path, appId: appId, client: client) else { throw PublishFailure.write("Apple upload reservation is missing.") }
                    if asset["storage"]?.text == "build-package" { try await verifyBuildPackageUpload(asset, file: resource, appId: appId, client: client) }
                    try await uploadAsset(asset, operations: resource.attributes?["uploadOperations"], accountId: account.id, appId: appId, client: client, grant: grant)
                case .verify:
                    if step.guardValue?["kind"]?.text == "asset-library-processed" {
                        try await verifyLibraryProcessing(path: path, guardValue: step.guardValue!, appId: appId, client: client)
                        break
                    }
                    var complete = false
                    let deadline = Date().addingTimeInterval(5 * 60)
                    while Date() < deadline {
                        let state = try await ownedMedia(path: path, appId: appId, client: client).map(Apple.delivery) ?? "FAILED"
                        if state == "COMPLETE" { complete = true; break }
                        if state == "FAILED" { throw PublishFailure.write("Apple could not process this media file. Prepare a new review.") }
                        try await Task.sleep(nanoseconds: 2_000_000_000)
                    }
                    guard complete else { throw PublishFailure.write("Apple is still processing this media file. Prepare a new review; do not upload a duplicate.") }
                }
                if step.kind != .verify && review.sentAt == nil { review.sentAt = CustomerReview.isoString(now()) }
                review.steps[index].state = "done"; try persist()
            }
            review.state = "complete"; review.completedAt = CustomerReview.isoString(now())
        } catch {
            if let active = review.steps.firstIndex(where: { $0.state == "running" }) { review.steps[active].state = "failed" }
            review.state = "failed"
            review.error = Self.publishingError(error)
            if case .refused(_, let problems)? = error as? PublishFailure { review.problems = problems }
        }
        review.pid = nil
        try persist()
        return review
    }

    static func publishingError(_ error: Error) -> String {
        switch error {
        case let failure as PublishFailure: return failure.message
        case AppStoreConnectClient.Failure.status(401): return "Apple did not accept the API key. Completed steps remain applied; review again to finish."
        case AppStoreConnectClient.Failure.status(403): return "Apple did not allow this change for the API key's role. Completed steps remain applied."
        case AppStoreConnectClient.Failure.agreement: return ReportingMessages.appleAgreement + " Completed steps remain applied; prepare a new review after completing Apple setup."
        case AppStoreConnectClient.Failure.status(409): return "Apple refused the change because the item changed or is in a state that does not allow it. Completed steps remain applied; prepare a new review."
        case AppStoreConnectClient.Failure.status(let code): return "Apple returned an error (\(code)). Completed steps remain applied; prepare a new review to finish."
        case let error as URLError where error.code == .cancelled: return "The Save was cancelled. Completed steps remain applied; Resume to finish."
        case is URLError: return "The connection to App Store Connect was lost. Completed steps remain applied; Resume to finish."
        case is CancellationError: return "The Save was cancelled. Completed steps remain applied; Resume to finish."
        case AppStoreConnectClient.Failure.unreadableResponse: return "Apple's answer could not be read. Completed steps remain applied; Resume checks Apple again before finishing."
        // The error's type names no account, app or file, and tells a bug report where the Save stopped.
        default: return "Publishing stopped before it finished (\(String(describing: type(of: error)))). Completed steps remain applied; prepare a new review to finish."
        }
    }
    /// One write sent together with others, and how it ended.
    struct SentTogether: Sendable { let item: Int; let id: String?; let error: Error? }
    /// How many such writes go at once; well within Apple's hourly request limit.
    static let sendTogetherLimit = 4
    /// The run of steps from `start` that may be sent together because none uses another's result: single-country price and offer writes,
    /// across subscriptions, and text updates to existing languages, each addressed by its own Apple ID.
    static func stepsSentTogether(_ steps: [PublishStep], from start: Int) -> Range<Int> {
        func batch(_ step: PublishStep) -> String? {
            guard step.kind == .api, reservation(step.path) == nil, step.body.map({ !$0.stringify().contains("\"$ref\"") }) ?? true else { return nil }
            if step.method == "PATCH", step.guardValue == nil, step.path.count == 2, let root = step.path[0].text, ["appStoreVersionLocalizations", "appInfoLocalizations"].contains(root),
               let id = step.path[1].text, step.body?["data"]?["id"]?.text == id, step.body?["data"]?["relationships"] == nil { return "text\u{0}\(root)" }
            guard step.method == "POST", step.guardValue?["kind"]?.text == "pricing-setup", let action = step.guardValue?["action"]?.text,
                  ["subscription-prices", "introductory-offer"].contains(action), step.guardValue?["territory"]?.text != nil, step.guardValue?["subscriptionId"]?.text != nil else { return nil }
            return "price\u{0}\(action)"
        }
        guard let first = batch(steps[start]) else { return start..<start + 1 }
        var end = start + 1
        while end < steps.count, batch(steps[end]) == first { end += 1 }
        return start..<end
    }

    /// A lost connection, a lost answer, a rate limit or a server error: the write may or may not have reached Apple.
    static func transient(_ error: Error) -> Bool {
        switch error {
        case let error as URLError: return error.code != .cancelled
        case AppStoreConnectClient.Failure.unreadableResponse: return true
        case AppStoreConnectClient.Failure.status(let code): return code == 429 || code >= 500
        default: return false
        }
    }

    /// The earlier step in this review whose created resource a path addresses, such as the reservation an upload sends to.
    static func reservation(_ parts: [JSONText]) -> String? {
        for part in parts { if case .object(let pairs) = part, pairs.count == 1, pairs[0].0 == "$ref", case .string(let key) = pairs[0].1 { return key } }
        return nil
    }

    static func resolve(_ value: JSONText, ids: [String: String]) throws -> JSONText {
        switch value {
        case .object(let pairs):
            if pairs.count == 1, pairs[0].0 == "$ref", case .string(let key) = pairs[0].1 {
                guard let id = ids[key] else { throw PublishFailure.write("An earlier publishing step has no Apple resource ID.") }
                return .string(id)
            }
            return .object(try pairs.map { ($0.0, try resolve($0.1, ids: ids)) })
        case .array(let items): return .array(try items.map { try resolve($0, ids: ids) })
        default: return value
        }
    }

    static func apiPath(_ parts: [JSONText], ids: [String: String]) throws -> String {
        // Apple accepts some product writes, such as creating an in-app purchase, only through version 2 of its API.
        if parts.first == .string("v2") {
            guard parts.count >= 2, case .string(let root) = parts[1], PricingSetupWrites.version2.contains(root) else { throw PublishFailure.write("Invalid publishing path.") }
            return "/v2" + String(try apiPath(Array(parts.dropFirst()), ids: ids).dropFirst(3))
        }
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-_.!~*'()")
        return "/v1/" + (try parts.map { part -> String in
            guard case .string(let text) = try resolve(part, ids: ids) else { throw PublishFailure.write("Invalid publishing path.") }
            return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
        }).joined(separator: "/")
    }

    // MARK: Write checks, performed just before each write with fresh Apple reads

    static let parents: [String: (relation: String, type: String)] = [
        "appStoreVersionLocalizations": ("appStoreVersion", "appStoreVersions"), "appInfoLocalizations": ("appInfo", "appInfos"),
        "appStoreReviewDetails": ("appStoreVersion", "appStoreVersions"), "appStoreReviewAttachments": ("appStoreReviewDetail", "appStoreReviewDetails"),
    ]

    /// The resource, after following its owners up to a version or app information owned by the approved app.
    func ownedResource(_ type: String, _ id: String, appId: String, client: AppStoreConnectClient, checked: OwnershipCache) async throws -> AppStoreConnectClient.Resource {
        guard !id.isEmpty, id.count <= 512 else { throw PublishFailure.write("Invalid Apple publishing resource.") }
        if let cached = checked.items["\(type)\u{0}\(id)"] { return cached }
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-_.")
        // Apple sends a version's or app information's app link only when it is included.
        let include = type == "appStoreVersions" || type == "appInfos" ? "?include=app" : ""
        guard let item = try await client.get("/v1/\(type)/\(id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id)\(include)").first, item.type == type, item.id == id else { throw PublishFailure.write("Apple publishing resource changed after review.") }
        if type == "appStoreVersions" || type == "appInfos" {
            guard Apple.owned(item, "app", "apps", appId) else { throw PublishFailure.write("Apple publishing resource no longer belongs to the approved app.") }
        } else {
            guard let link = Self.parents[type] else { throw PublishFailure.write("Apple publishing resource has no approved app owner.") }
            if let owner = Apple.owner(item, link.relation) {
                guard owner.type == link.type else { throw PublishFailure.write("Apple publishing resource has no approved app owner.") }
                _ = try await ownedResource(link.type, owner.id, appId: appId, client: client, checked: checked)
            } else {
                guard try await listedOwner(type, id, appId: appId, client: client, checked: checked) else { throw PublishFailure.write("Apple publishing resource has no approved app owner.") }
            }
        }
        checked.items["\(type)\u{0}\(id)"] = item
        return item
    }

    /// Apple can leave a language's owner link out of a read of that language alone. The language is then owned when it is listed
    /// under one of the approved app's own versions or app information, read through the app's paths.
    private func listedOwner(_ type: String, _ id: String, appId: String, client: AppStoreConnectClient, checked: OwnershipCache) async throws -> Bool {
        let parents: [AppStoreConnectClient.Resource], children: (String) -> String, relation: String
        switch type {
        case "appStoreVersionLocalizations":
            parents = try await client.list("/v1/apps/\(appId)/appStoreVersions?include=app&limit=200").filter { $0.type == "appStoreVersions" && Apple.owned($0, "app", "apps", appId) }
                .sorted { Apple.editable.contains(Apple.state($0)) && !Apple.editable.contains(Apple.state($1)) }
            children = { "/v1/appStoreVersions/\($0)/appStoreVersionLocalizations?limit=200" }; relation = "appStoreVersion"
        case "appInfoLocalizations":
            parents = try await client.list("/v1/apps/\(appId)/appInfos?include=app&limit=200").filter { $0.type == "appInfos" && Apple.owned($0, "app", "apps", appId) }
            children = { "/v1/appInfos/\($0)/appInfoLocalizations?limit=200" }; relation = "appInfo"
        default: return false
        }
        for parent in parents where try await client.list(children(parent.id)).contains(where: { $0.type == type && $0.id == id && Apple.within($0, relation, parent.type, parent.id) }) {
            checked.items["\(parent.type)\u{0}\(parent.id)"] = parent; checked.owners["\(type)\u{0}\(id)"] = (parent.type, parent.id)
            return true
        }
        return false
    }

    func ownedMedia(path: String, appId: String, client: AppStoreConnectClient) async throws -> AppStoreConnectClient.Resource? {
        let parts = path.split(separator: "/").map(String.init)
        if parts.count == 3, parts[1] == "buildUploadFiles" { return try await ownedBuildUploadFile(parts[2].removingPercentEncoding ?? parts[2], appId: appId, client: client) }
        guard parts.count == 3, ["appStoreReviewAttachments", "appEncryptionDeclarationDocuments"].contains(parts[1]) else { throw PublishFailure.write("Unsupported Apple media read.") }
        if parts[1] == "appEncryptionDeclarationDocuments" {
            let id = parts[2].removingPercentEncoding ?? parts[2]
            guard let document = try await client.get(path).first, document.type == parts[1], document.id == id, let owner = Apple.owner(document, "appEncryptionDeclaration") ?? nil,
                  try Self.scopedDeclarations(try await WorkspaceSession.declarationReads(appId) { try await client.list($0) }, appId: appId).contains(where: { $0.id == owner.id }) else { throw PublishFailure.write("The encryption document no longer belongs to this app.") }
            return document
        }
        return try await ownedResource(parts[1], parts[2].removingPercentEncoding ?? parts[2], appId: appId, client: client, checked: OwnershipCache())
    }

    /// The write allowlist and ownership checks for the scopes this app publishes. Anything else is refused.
    func verifyWrite(method: String, path: String, body: JSONText?, guardValue: JSONText?, appId: String, client: AppStoreConnectClient) async throws {
        let parts = path.split(separator: "/").dropFirst().map { $0.removingPercentEncoding ?? String($0) }
        guard let root = parts.first else { throw PublishFailure.write("Unsupported Apple write.") }
        let data = body?["data"]
        let checked = OwnershipCache()
        func owned(_ type: String, _ id: String) async throws -> AppStoreConnectClient.Resource { try await ownedResource(type, id, appId: appId, client: client, checked: checked) }
        func versions() async throws -> [AppStoreConnectClient.Resource] {
            let items = try await client.list("/v1/apps/\(appId)/appStoreVersions?include=app&limit=200")
            guard items.allSatisfy({ $0.type == "appStoreVersions" && Apple.owned($0, "app", "apps", appId) }) else { throw PublishFailure.write("Apple returned resources outside the approved app.") }
            return items
        }
        func submissions() async throws -> [AppStoreConnectClient.Resource] {
            let items = try await client.list("/v1/apps/\(appId)/reviewSubmissions?limit=200")
            guard items.allSatisfy({ $0.type == "reviewSubmissions" && Apple.within($0, "app", "apps", appId) }) else { throw PublishFailure.write("Apple returned resources outside the approved app.") }
            return items
        }
        func relation(_ value: JSONText?, _ name: String) -> (type: String, id: String)? {
            guard let item = value?["relationships"]?[name]?["data"], let type = item["type"]?.text, let id = item["id"]?.text else { return nil }
            return (type, id)
        }
        switch root {
        case "appDataUsages", "appDataUsagesPublishState" where guardValue?["kind"]?.text == "app-privacy":
            try await verifyAppPrivacyWrite(method: method, parts: parts, body: body, guardValue: guardValue, account: client.token.account, appId: appId)
        case "appTaxCategories" where guardValue?["kind"]?.text == "tax-category":
            try await verifyTaxCategoryWrite(method: method, parts: parts, body: body, guardValue: guardValue, account: client.token.account, appId: appId)
        case let name where guardValue?["kind"]?.text == "pricing-setup" && PricingSetupWrites.roots.contains(name):
            try await verifyPricingSetupWrite(root: root, method: method, path: path, parts: parts, body: body, guardValue: guardValue, appId: appId, client: client)
        case "appAssetLibraryImages", "appAssetLibraryVideos", "appAssetLibraryPlacements", "appAssetLibraryPlacementOrderingRequests":
            try await verifyLibraryWrite(method: method, parts: parts, body: body, guardValue: guardValue, appId: appId, client: client)
        case let name where ["reviewSubmissions", "reviewSubmissionItems"].contains(name) && guardValue?["kind"]?.text?.hasPrefix("asset-library-review") == true:
            try await verifyLibraryWrite(method: method, parts: parts, body: body, guardValue: guardValue, appId: appId, client: client)
        case "buildUploads", "buildUploadFiles":
            try await verifyBuildUploadWrite(method: method, parts: parts, body: body, guardValue: guardValue, appId: appId, client: client)
        case "appStoreVersionLocalizations", "appInfoLocalizations":
            let parent = root == "appInfoLocalizations" ? ("appInfo", "appInfos") : ("appStoreVersion", "appStoreVersions")
            guard data?["type"]?.text == root, ["POST", "PATCH"].contains(method), parts.count <= 2 else { throw PublishFailure.write("Unsupported App Store localization change.") }
            if method == "POST" {
                guard parts.count == 1, data?["id"] == nil, let owner = relation(data, parent.0), owner.type == parent.1 else { throw PublishFailure.write("Unsupported App Store localization creation.") }
                _ = try await owned(owner.type, owner.id)
            } else {
                guard parts.count == 2, data?["id"]?.text == parts[1], data?["relationships"] == nil else { throw PublishFailure.write("Unsupported App Store localization update.") }
                _ = try await owned(root, parts[1])
            }
        case "appStoreVersions":
            guard data?["type"]?.text == "appStoreVersions", method != "DELETE" else { throw PublishFailure.write("Unsupported App Store version change.") }
            if method == "POST" {
                guard parts.count == 1, data?["id"] == nil, relation(data, "app").map({ $0 == ("apps", appId) }) == true, case .object(let relationships)? = data?["relationships"], relationships.count == 1,
                      case .object(let attributes)? = data?["attributes"], attributes.allSatisfy({ ["platform", "versionString", "releaseType", "earliestReleaseDate"].contains($0.0) }),
                      let platform = data?["attributes"]?["platform"]?.text, ["IOS", "MAC_OS", "TV_OS", "VISION_OS"].contains(platform),
                      let number = data?["attributes"]?["versionString"]?.text, number.range(of: #"^\d+(?:\.\d+){0,2}$"#, options: .regularExpression) != nil, data?["attributes"]?["releaseType"] != nil else { throw PublishFailure.write("Unsupported App Store version creation.") }
                if try await versions().contains(where: { $0.attributes?["platform"]?.string == platform && $0.attributes?["versionString"]?.string == number }) { throw PublishFailure.write("This Apple version was created after review. Prepare a new review.") }
            } else {
                guard parts.count == 2, data?["id"]?.text == parts[1], let current = try await versions().first(where: { $0.id == parts[1] }) else { throw PublishFailure.write("App Store version no longer belongs to this app.") }
                guard Apple.editable.contains(Apple.state(current)) else { throw PublishFailure.write("The App Store version is no longer editable.") }
                switch guardValue?["kind"]?.text {
                case "version-copyright":
                    guard data?["relationships"] == nil, case .object(let attributes)? = data?["attributes"], attributes.count == 1, case .string(let copyright)? = data?["attributes"]?["copyright"],
                          !copyright.trimmingCharacters(in: .whitespaces).isEmpty, copyright.utf16.count <= 200 else { throw PublishFailure.write("Unsupported version copyright change.") }
                    let current = current.attributes?["copyright"]?.string.map { JSONText.string($0) } ?? .null
                    guard Apple.jsonDigest(current) == guardValue?["digest"]?.text else { throw PublishFailure.write("The version copyright changed after review.") }
                case "release-settings":
                    guard data?["relationships"] == nil, case .object(let attributes)? = data?["attributes"], Set(attributes.map(\.0)) == ["releaseType", "earliestReleaseDate"],
                          try Apple.releaseDigest(current.attributes) == guardValue?["digest"]?.text else { throw PublishFailure.write("The version release settings changed after review.") }
                case "submission-build":
                    guard data?["attributes"] == nil, case .object(let relationships)? = data?["relationships"], relationships.count == 1, let build = relation(data, "build"), build.type == "builds" else { throw PublishFailure.write("Unsupported App Store build selection.") }
                    let attached = try await attachedBuild(versionId: current.id, appId: appId, client: client)
                    guard Apple.jsonDigest(attached.map { .string($0.id) } ?? .null) == guardValue?["digest"]?.text else { throw PublishFailure.write("The selected version's build changed after review.") }
                    guard try await eligibleBuild(build.id, version: current, appId: appId, client: client) else { throw PublishFailure.write("Selected build no longer belongs to this app or is ineligible.") }
                default: throw PublishFailure.write("Unsupported App Store version update.")
                }
            }
        case "reviewSubmissions":
            guard data?["type"]?.text == "reviewSubmissions", method != "DELETE" else { throw PublishFailure.write("Unsupported review submission change.") }
            if method == "POST" {
                guard parts.count == 1, data?["id"] == nil, relation(data, "app").map({ $0 == ("apps", appId) }) == true else { throw PublishFailure.write("Unsupported review submission creation.") }
            } else if guardValue?["kind"]?.text == "submission-cancel" {
                guard parts.count == 2, data?["id"]?.text == parts[1], data?["relationships"] == nil, case .object(let attributes)? = data?["attributes"], attributes.count == 1, data?["attributes"]?["canceled"] == .bool(true),
                      let versionId = guardValue?["versionId"]?.text, try await versions().contains(where: { $0.id == versionId }),
                      let submission = try await submissions().first(where: { $0.id == parts[1] }) else { throw PublishFailure.write("Unsupported App Review cancellation.") }
                let items = try await client.list("/v1/reviewSubmissions/\(submission.id)/items?include=appStoreVersion&limit=200")
                guard try Self.cancellationDigest(submission, items: items, appId: appId, versionId: versionId) == guardValue?["digest"]?.text else { throw PublishFailure.write("The App Review submission changed after approval. Prepare a new review.") }
            } else {
                guard parts.count == 2, data?["id"]?.text == parts[1], data?["relationships"] == nil, case .object(let attributes)? = data?["attributes"], attributes.count == 1, data?["attributes"]?["submitted"] == .bool(true),
                      guardValue?["kind"]?.text == "submission-final", let versionId = guardValue?["versionId"]?.text else { throw PublishFailure.write("Unsupported review submission update.") }
                guard try await submissions().contains(where: { $0.id == parts[1] && $0.attributes?["state"]?.string == "READY_FOR_REVIEW" }) else { throw PublishFailure.write("Review submission no longer belongs to this app or is not ready.") }
                guard let version = try await versions().first(where: { $0.id == versionId }), Apple.editable.contains(Apple.state(version)) else { throw PublishFailure.write("The reviewed version is no longer editable for App Review submission. Prepare a new review.") }
                guard case .string(let copyright)? = version.attributes?["copyright"], !copyright.trimmingCharacters(in: .whitespaces).isEmpty, Apple.jsonDigest(.string(copyright)) == guardValue?["copyrightDigest"]?.text else { throw PublishFailure.write("The version copyright changed after review.") }
                guard let detail = try await reviewDetail(versionId: version.id, client: client), try Self.reviewInformationDigest(detail) == guardValue?["reviewInformationDigest"]?.text else { throw PublishFailure.write("App Review Information changed after approval. Prepare a new review.") }
                guard try Self.attachmentsDigest(try await client.list("/v1/appStoreReviewDetails/\(detail.id)/appStoreReviewAttachments?limit=200"), detailId: detail.id) == guardValue?["reviewAttachmentsDigest"]?.text else { throw PublishFailure.write("App Review attachments changed after approval. Prepare a new review.") }
                guard try await versionLibraryReview(reader: libraryReader(appId: appId, client: client), version: version).digest == guardValue?["assetLibraryDigest"]?.text else { throw PublishFailure.write("Assigned Asset Library material changed after review. Prepare a new review.") }
                let items = try await client.list("/v1/reviewSubmissions/\(parts[1])/items?include=appStoreVersion&limit=200")
                guard items.count == 1, items[0].type == "reviewSubmissionItems", Apple.within(items[0], "reviewSubmission", "reviewSubmissions", parts[1]), Apple.owned(items[0], "appStoreVersion", "appStoreVersions", version.id) else { throw PublishFailure.write("The Apple review submission contains different material after review.") }
                guard let attached = try await attachedBuild(versionId: version.id, appId: appId, client: client), Apple.jsonDigest(.string(attached.id)) == guardValue?["digest"]?.text,
                      try await eligibleBuild(attached.id, version: version, appId: appId, client: client) else { throw PublishFailure.write("The reviewed build is no longer eligible for App Review.") }
            }
        case "reviewSubmissionItems":
            guard method == "POST", parts.count == 1, data?["type"]?.text == "reviewSubmissionItems", data?["id"] == nil, let submission = relation(data, "reviewSubmission"), submission.type == "reviewSubmissions",
                  let version = relation(data, "appStoreVersion"), version.type == "appStoreVersions" else { throw PublishFailure.write("Unsupported review submission item.") }
            guard try await submissions().contains(where: { $0.id == submission.id && $0.attributes?["state"]?.string == "READY_FOR_REVIEW" }), try await versions().contains(where: { $0.id == version.id }) else { throw PublishFailure.write("Review submission item no longer belongs to this app.") }
        case "appStoreVersionReleaseRequests":
            guard method == "POST", parts.count == 1, data?["type"]?.text == "appStoreVersionReleaseRequests", data?["id"] == nil, let version = relation(data, "appStoreVersion"), version.type == "appStoreVersions",
                  try await versions().contains(where: { $0.id == version.id && Apple.state($0) == "PENDING_DEVELOPER_RELEASE" && $0.attributes?["releaseType"]?.string == "MANUAL" }) else {
                throw PublishFailure.write("App Store version no longer belongs to this app or is not approved for manual release.")
            }
        case "betaAppReviewDetails":
            try await verifyBetaReviewInformation(method: method, parts: parts, data: data, guardValue: guardValue, appId: appId, client: client)
        case "buildBetaNotifications":
            try await verifyBuildAudience(method: method, parts: parts, body: body, guardValue: guardValue, appId: appId, client: client)
        case "builds" where guardValue?["kind"]?.text == "build-expiry-audience":
            try await verifyBuildAudience(method: method, parts: parts, body: body, guardValue: guardValue, appId: appId, client: client)
        case "builds" where ["build-encryption-declaration", "build-new-encryption-declaration"].contains(guardValue?["kind"]?.text ?? ""):
            try await verifyBuildDeclaration(method: method, parts: parts, data: data, guardValue: guardValue, appId: appId, client: client)
        case "builds" where guardValue?["kind"]?.text == "individual-access", "buildBetaDetails":
            try await verifyBuildAccess(method: method, parts: parts, data: data, guardValue: guardValue, appId: appId, client: client)
        case "betaTesters" where guardValue?["kind"]?.text == "tester-build-target":
            try await verifyBuildAccess(method: method, parts: parts, data: data, guardValue: guardValue, appId: appId, client: client)
        case "builds":
            guard method == "PATCH", parts.count == 2, data?["type"]?.text == "builds", data?["id"]?.text == parts[1], data?["relationships"] == nil, case .object(let attributes)? = data?["attributes"], attributes.count == 1 else { throw PublishFailure.write("Unsupported TestFlight build update.") }
            guard let build = try await appBuild(appId: appId, buildId: parts[1], client: client) else { throw PublishFailure.write("TestFlight build does not belong to this app.") }
            if case .bool = data?["attributes"]?["usesNonExemptEncryption"] {
                guard guardValue?["kind"]?.text == "build-encryption-use", Self.processedUnexpired(build) else { throw PublishFailure.write("Build is no longer eligible for export compliance changes.") }
                guard try Self.encryptionUseDigest(build.attributes?["usesNonExemptEncryption"]) == guardValue?["digest"]?.text else { throw PublishFailure.write("The build encryption answer changed after review.") }
            } else { throw PublishFailure.write("Unsupported TestFlight build update.") }
        case "betaBuildLocalizations", "betaAppLocalizations", "betaLicenseAgreements":
            try await verifyTestFlightContent(root: root, method: method, parts: parts, data: data, guardValue: guardValue, appId: appId, client: client)
        case "betaGroups":
            try await verifyTestFlightGroup(method: method, parts: parts, body: body, guardValue: guardValue, appId: appId, client: client)
        case "betaTesters" where guardValue?["kind"]?.text == "tester-group-target":
            try await verifyTestFlightGroup(method: method, parts: parts, body: body, guardValue: guardValue, appId: appId, client: client)
        case "betaTesterInvitations":
            try await verifyAppTesterChange(method: method, parts: parts, body: body, guardValue: guardValue, appId: appId, client: client)
        case "betaAppReviewSubmissions":
            try await verifyBetaSubmission(method: method, parts: parts, body: body, guardValue: guardValue, appId: appId, client: client)
        case "betaTesters":
            throw PublishFailure.write("Unsupported TestFlight tester change.")
        case "appStoreReviewDetails":
            guard data?["type"]?.text == "appStoreReviewDetails", ["POST", "PATCH"].contains(method) else { throw PublishFailure.write("Unsupported App Review publishing request.") }
            if method == "POST" {
                guard parts.count == 1, data?["id"] == nil, let version = relation(data, "appStoreVersion"), version.type == "appStoreVersions", let owner = try await versions().first(where: { $0.id == version.id }),
                      Apple.editable.contains(Apple.state(owner)) else { throw PublishFailure.write("App Review Information belongs to another app or version.") }
            } else {
                guard parts.count == 2, data?["id"]?.text == parts[1], data?["relationships"] == nil else { throw PublishFailure.write("Unsupported App Review publishing request.") }
                _ = try await owned("appStoreReviewDetails", parts[1])
            }
        case "appStoreReviewAttachments":
            if method == "DELETE" {
                guard parts.count == 2, body == nil, guardValue?["kind"]?.text == "review-attachment-delete", let versionId = guardValue?["versionId"]?.text,
                      let detailId = guardValue?["detailId"]?.text, let version = try await versions().first(where: { $0.id == versionId }), Apple.editable.contains(Apple.state(version)),
                      let detail = try await reviewDetail(versionId: versionId, client: client), detail.id == detailId else { throw PublishFailure.write("Unsupported App Review attachment removal.") }
                let attachments = try ReviewInformation.scopedAttachments(await client.list("/v1/appStoreReviewDetails/\(detailId)/appStoreReviewAttachments?limit=200"), detailId: detailId)
                guard let attachment = attachments.first(where: { $0.id == parts[1] }), try ReviewInformation.attachmentDigest(attachment, detailId: detailId) == guardValue?["digest"]?.text else { throw PublishFailure.write("The App Review attachment changed after approval. Prepare a new review.") }
                break
            }
            guard data?["type"]?.text == "appStoreReviewAttachments", ["POST", "PATCH"].contains(method) else { throw PublishFailure.write("Unsupported App Review publishing request.") }
            if method == "POST" {
                guard parts.count == 1, data?["id"] == nil, let detail = relation(data, "appStoreReviewDetail"), detail.type == "appStoreReviewDetails" else { throw PublishFailure.write("Unsupported App Review attachment reservation.") }
                _ = try await owned("appStoreReviewDetails", detail.id)
            } else {
                guard parts.count == 2, data?["id"]?.text == parts[1], data?["relationships"] == nil, case .object(let attributes)? = data?["attributes"],
                      attributes.allSatisfy({ ["uploaded", "sourceFileChecksum"].contains($0.0) }) else { throw PublishFailure.write("Unsupported App Review attachment change.") }
                _ = try await owned("appStoreReviewAttachments", parts[1])
            }
        case "subscriptionPrices", "inAppPurchasePriceSchedules":
            try await verifyProductPriceWrite(root: root, method: method, parts: parts, body: body, guardValue: guardValue, appId: appId, client: client)
        case "apps" where parts.count == 4 && parts[2] == "relationships" && parts[3] == "betaTesters":
            try await verifyAppTesterChange(method: method, parts: parts, body: body, guardValue: guardValue, appId: appId, client: client)
        case "apps":
            guard method == "PATCH", parts.count == 2, parts[1] == appId, data?["type"]?.text == "apps", data?["id"]?.text == appId, data?["relationships"] == nil, case .object(let attributes)? = data?["attributes"], attributes.count == 1,
                  let rights = data?["attributes"]?["contentRightsDeclaration"]?.text, ["DOES_NOT_USE_THIRD_PARTY_CONTENT", "USES_THIRD_PARTY_CONTENT"].contains(rights), guardValue?["kind"]?.text == "app-content-rights" else { throw PublishFailure.write("Unsupported app information change.") }
            guard let app = try await client.get("/v1/apps/\(appId)").first, app.type == "apps", app.id == appId,
                  Apple.jsonDigest(app.attributes?["contentRightsDeclaration"]?.string.map { .string($0) } ?? .null) == guardValue?["digest"]?.text else { throw PublishFailure.write("The content rights declaration changed after review.") }
        case "appInfos":
            guard method == "PATCH", parts.count == 2, data?["type"]?.text == "appInfos", data?["id"]?.text == parts[1], data?["attributes"] == nil, case .object(let relationships)? = data?["relationships"],
                  relationships.allSatisfy({ AppInformation.categoryFields.contains($0.0) }), guardValue?["kind"]?.text == "app-categories" else { throw PublishFailure.write("Unsupported App Store category change.") }
            guard let info = try await client.get("/v1/appInfos/\(parts[1])?include=app,\(AppInformation.categoryFields.joined(separator: ","))").first, info.type == "appInfos", Apple.owned(info, "app", "apps", appId),
                  Apple.editable.contains(Apple.state(info)), Apple.jsonDigest(AppInformation.snapshotJSON(info)) == guardValue?["digest"]?.text else { throw PublishFailure.write("App Store categories changed after review. Prepare a new review.") }
        case "territoryAvailabilities":
            guard method == "PATCH", parts.count == 2, data?["type"]?.text == "territoryAvailabilities", data?["id"]?.text == parts[1], data?["relationships"] == nil, case .object(let attributes)? = data?["attributes"], attributes.count == 1,
                  case .bool? = data?["attributes"]?["available"], guardValue?["kind"]?.text == "app-territory-availability", let territory = guardValue?["territoryId"]?.text else { throw PublishFailure.write("Unsupported territory availability change.") }
            let snapshot = try await availabilitySnapshot(appId: appId, client: client)
            guard snapshot.digest == guardValue?["digest"]?.text, snapshot.territories.contains(where: { $0.resourceId == parts[1] && $0.id == territory }) else { throw PublishFailure.write("This app's region availability changed after review. Prepare a new review.") }
        case "appEncryptionDeclarationDocuments":
            guard let declarationId = guardValue?["declarationId"]?.text, ["encryption-document-reservation", "encryption-document-commit"].contains(guardValue?["kind"]?.text ?? "") else { throw PublishFailure.write("Unsupported encryption document change.") }
            let declarations = try Self.scopedDeclarations(try await WorkspaceSession.declarationReads(appId) { try await client.list($0) }, appId: appId)
            guard let declaration = declarations.first(where: { $0.id == declarationId }), Self.documentOwnerDigest(declaration) == guardValue?["digest"]?.text else { throw PublishFailure.write("The encryption declaration changed after review. Prepare a new review.") }
            if method == "POST" {
                guard guardValue?["kind"]?.text == "encryption-document-reservation", parts.count == 1, relation(data, "appEncryptionDeclaration").map({ $0 == ("appEncryptionDeclarations", declarationId) }) == true,
                      data?["attributes"]?["fileName"] == guardValue?["fileName"], data?["attributes"]?["fileSize"] == guardValue?["size"], declaration.attributes?["appEncryptionDeclarationState"]?.string == "CREATED",
                      try await declarationDocument(declarationId, client: client) == nil else { throw PublishFailure.write("Unsupported encryption document reservation.") }
            } else {
                guard method == "PATCH", guardValue?["kind"]?.text == "encryption-document-commit", parts.count == 2, data?["id"]?.text == parts[1], data?["attributes"]?["sourceFileChecksum"] == guardValue?["checksum"],
                      let linked = try await declarationDocument(declarationId, client: client), linked.id == parts[1] else { throw PublishFailure.write("The reserved encryption document no longer belongs to this declaration.") }
            }
        case "appEncryptionDeclarations":
            guard method == "POST", parts.count == 1, data?["type"]?.text == "appEncryptionDeclarations", data?["id"] == nil, relation(data, "app").map({ $0 == ("apps", appId) }) == true,
                  guardValue?["kind"]?.text == "app-encryption-creation" else { throw PublishFailure.write("Unsupported encryption declaration creation.") }
            let current = try Self.scopedDeclarations(try await WorkspaceSession.declarationReads(appId) { try await client.list($0) }, appId: appId)
            guard Self.declarationsDigest(current, appId: appId) == guardValue?["digest"]?.text else { throw PublishFailure.write("This app's encryption declarations changed after review. Prepare a new review.") }
        case "accessibilityDeclarations":
            guard guardValue?["kind"]?.text == "accessibility-declaration", let family = guardValue?["family"]?.text else { throw PublishFailure.write("Unsupported accessibility declaration change.") }
            let declarations = try AccessibilityDeclarations.scoped(try await client.list("/v1/apps/\(appId)/accessibilityDeclarations?limit=200"), appId: appId)
            guard AccessibilityDeclarations.digest(declarations, appId: appId, family: family) == guardValue?["digest"]?.text else { throw PublishFailure.write("Apple's accessibility declaration changed after review. Prepare a new review.") }
            let draft = declarations.first { $0.attributes?["deviceFamily"]?.string == family && $0.attributes?["state"]?.string == "DRAFT" }
            switch method {
            case "POST": guard parts.count == 1, draft == nil, data?["type"]?.text == "accessibilityDeclarations", data?["attributes"]?["deviceFamily"]?.text == family, relation(data, "app").map({ $0 == ("apps", appId) }) == true else { throw PublishFailure.write("Unsupported accessibility declaration change.") }
            case "PATCH", "DELETE": guard parts.count == 2, let draft, draft.id == parts[1], method == "DELETE" ? body == nil : data?["id"]?.text == draft.id else { throw PublishFailure.write("Unsupported accessibility declaration change.") }
            default: throw PublishFailure.write("Unsupported accessibility declaration change.")
            }
        case "ageRatingDeclarations":
            guard method == "PATCH", parts.count == 2, data?["type"]?.text == "ageRatingDeclarations", data?["id"]?.text == parts[1], data?["relationships"] == nil, case .object(let attributes)? = data?["attributes"],
                  guardValue?["kind"]?.text == "age-rating" else { throw PublishFailure.write("Unsupported age rating change.") }
            try AgeRating.validate(attributes)
            let declaration = try await ageRatingDeclaration(appId: appId, client: client)
            guard declaration.id == parts[1], AgeRating.digest(Planner.resource(declaration)["attributes"] ?? .object([])) == guardValue?["digest"]?.text else { throw PublishFailure.write("Apple's age rating answers changed after review. Prepare a new review.") }
        case "analyticsReportRequests":
            guard method == "POST", parts.count == 1, data?["type"]?.text == "analyticsReportRequests", ["ONGOING", "ONE_TIME_SNAPSHOT"].contains(data?["attributes"]?["accessType"]?.text ?? ""),
                  relation(data, "app").map({ $0 == ("apps", appId) }) == true else { throw PublishFailure.write("Unsupported Analytics publishing request.") }
        case "appPriceSchedules":
            guard method == "POST", parts.count == 1, data?["type"]?.text == "appPriceSchedules", data?["id"] == nil, relation(data, "app").map({ $0 == ("apps", appId) }) == true,
                  let base = relation(data, "baseTerritory"), base.type == "territories", guardValue?["kind"]?.text == "app-price-schedule" else { throw PublishFailure.write("Unsupported app price schedule change.") }
            let current = try await priceScheduleSnapshot(appId: appId, client: client)
            guard current.digest == guardValue?["digest"]?.text, current.base == base.id else { throw PublishFailure.write("Apple price schedule changed after review. Prepare a new review.") }
        default: throw PublishFailure.write("Unsupported Apple write.")
        }
    }

    // MARK: Uploads

    /// Resolves a reviewed asset back to its revision or draft, then decrypts it to confirm its SHA-256 and compute Apple's MD5 checksum.
    func describeAsset(revisionId: String, hash: String, storage: String, ext: String, fileName: String, accountId: String, appId: String) throws -> JSONText {
        let key = ["review-attachment", "export-document"].contains(storage) ? "\(accountId):\(appId):\(revisionId)" : try TextDrafts.key(accountId: accountId, appId: appId, revisionId: revisionId)
        let (revision, draft) = try storeAccess { store in
            (try store.document(namespace: "revisions", key: key).map { try JSONText.parse($0.payload) }, try store.document(namespace: "drafts", key: key).map { try JSONText.parse($0.payload) })
        }
        guard let revision = revision ?? (["review-attachment", "export-document"].contains(storage) ? JSONText.object([]) : nil) else { throw PublishFailure.invalid("The publishing source is unavailable.") }
        var declared: Int?
        switch storage {
        case "archive":
            let images = Self.items(revision["versions"]).flatMap { Self.items($0["localizations"]).flatMap { Self.items($0["screenshotSets"]).flatMap { Self.items($0["screenshots"]) } } }
            guard let image = images.first(where: { $0["sha256"]?.text == hash }), ext == (image["contentType"]?.text == "image/jpeg" ? "jpg" : "png") else { throw PublishFailure.invalid("The reviewed screenshot is no longer in this version.") }
        case "image":
            guard Self.uploads(draft).contains(where: { $0.1["sha256"]?.text == hash && $0.1["archiveSource"] != .bool(true) && ext == ($0.1["contentType"]?.text == "image/jpeg" ? "jpg" : "png") }) else { throw PublishFailure.invalid("The reviewed screenshot is no longer in this draft.") }
        case "export-document":
            guard let staged = try stagedEncryptionDocument(accountId: accountId, appId: appId, declarationId: revisionId), staged.hash == hash, staged.fileName == fileName, ext == "pdf" else { throw PublishFailure.invalid("The reviewed encryption PDF is no longer staged for this declaration.") }
            declared = staged.size
        case "review-attachment":
            let saved = try reviewInformationDraft(accountId: accountId, appId: appId, versionId: revisionId)
            guard saved.revision > 0, let attachment = saved.attachment, attachment.hash == hash, attachment.fileName == fileName, attachment.ext == ext else { throw PublishFailure.invalid("The reviewed App Review attachment is no longer in this draft.") }
            declared = attachment.size
        case "preview":
            guard case .object(let videos)? = draft?["previewUploads"], let video = videos.first(where: { $0.1["sha256"]?.text == hash && $0.1["extension"]?.text == ext })?.1, case .number(let bytes)? = video["bytes"] else { throw PublishFailure.invalid("The reviewed preview is no longer in this draft.") }
            declared = Int(bytes)
        default: throw PublishFailure.invalid("Invalid publishing asset.")
        }
        let size = try media.metadata(hash), limit = storage == "preview" ? 500_000_000 : 50_000_000
        guard size >= 1, size <= limit, declared.map({ $0 == size }) ?? true else { throw PublishFailure.invalid("A publishing asset is missing or has changed size.") }
        var md5 = Insecure.MD5(), read = 0
        try media.stream(hash) { chunk in md5.update(data: chunk); read += chunk.count }
        guard read == size else { throw PublishFailure.invalid("A publishing asset changed. Restore or re-upload it before publishing.") }
        return .object([("hash", .string(hash)), ("storage", .string(storage)), ("extension", .string(ext)), ("fileName", .string(fileName)), ("revisionId", .string(revisionId)),
                        ("size", .number(Double(size))), ("checksum", .string(md5.finalize().map { String(format: "%02x", $0) }.joined()))])
    }

    /// Streams the reviewed asset's byte ranges to the upload URLs Apple reserved, after checking every operation.
    func uploadAsset(_ asset: JSONText, operations: JSONValue?, accountId: String, appId: String, client: AppStoreConnectClient, grant: PublishGrant) async throws {
        if asset["storage"]?.text == "build-package" { try await uploadBuildPackage(asset, operations: operations, accountId: accountId, appId: appId, client: client, grant: grant); return }
        guard let hash = asset["hash"]?.text, let storage = asset["storage"]?.text, let ext = asset["extension"]?.text, let fileName = asset["fileName"]?.text, let revisionId = asset["revisionId"]?.text,
              case .number(let declared)? = asset["size"], let checksum = asset["checksum"]?.text else { throw PublishFailure.write("Invalid publishing asset.") }
        let checked = try describeAsset(revisionId: revisionId, hash: hash, storage: storage, ext: ext, fileName: fileName, accountId: accountId, appId: appId)
        guard checked["size"] == .number(declared), checked["checksum"]?.text == checksum else { throw PublishFailure.write("The reviewed asset changed.") }
        guard declared.isFinite, declared >= 1, declared <= Double(StagedBuildPackage.maximumBytes), declared.rounded() == declared else { throw PublishFailure.write("Invalid publishing asset size.") }
        let parts = try BuildUploadOperation.validate(operations, size: Int(declared))
        PublishTransfer.shared.begin(fileName, total: Int64(declared)); defer { PublishTransfer.shared.end() }
        for part in parts {
            try await client.uploadPart(part.url, headers: part.headers, body: try media.read(hash, range: part.range))
            PublishTransfer.shared.partFinished(Int64(part.range.count))
        }
    }

    // MARK: Submission helpers

    /// The build App Store Connect shows in the version's Build section, if any.
    public func versionBuildId(versionId: String, appId: String, client: AppStoreConnectClient) async throws -> String? {
        try requireFeedbackScope(appId: appId, client: client)
        guard versionId.range(of: "^[A-Za-z0-9_-]{1,256}$", options: .regularExpression) != nil else { throw PublishFailure.invalid("Choose an Apple version.") }
        return try await AppStoreReadCache.rereadingAfterInvalidation { try await attachedBuild(versionId: versionId, appId: appId, client: client)?.id }
    }
    func attachedBuild(versionId: String, appId: String, client: AppStoreConnectClient) async throws -> AppStoreConnectClient.Resource? {
        let builds: [AppStoreConnectClient.Resource]
        do { builds = try await client.get("/v1/appStoreVersions/\(versionId)/build") } catch AppStoreConnectClient.Failure.status(404) { return nil }
        guard let build = builds.first else { return nil }
        guard build.type == "builds" else { throw PublishFailure.invalid("Apple returned unexpected TestFlight resources.") }
        if Apple.owner(build, "app") != nil { guard Apple.owned(build, "app", "apps", appId) else { throw PublishFailure.invalid("Apple returned TestFlight resources outside the selected app.") }; return build }
        let owners = try await client.list("/v1/builds/\(build.id)/relationships/app")
        guard owners.count == 1, owners[0].type == "apps", owners[0].id == appId else { throw PublishFailure.invalid("Apple did not confirm this TestFlight resource belongs to the selected app.") }
        return build
    }

    func eligibleBuild(_ id: String, version: AppStoreConnectClient.Resource, appId: String, client: AppStoreConnectClient) async throws -> Bool {
        let page = try await client.listWithIncluded("/v1/builds?filter%5Bapp%5D=\(appId)&filter%5Bid%5D=\(id)&include=preReleaseVersion&limit=200")
        return Self.eligible(page.data.first { $0.id == id }, included: page.included, version: version)
    }

    static func eligible(_ build: AppStoreConnectClient.Resource?, included: [AppStoreConnectClient.Resource], version: AppStoreConnectClient.Resource) -> Bool {
        guard let build, build.type == "builds", let related = Apple.owner(build, "preReleaseVersion"), related.type == "preReleaseVersions",
              let prerelease = included.first(where: { $0.type == "preReleaseVersions" && $0.id == related.id }) else { return false }
        return build.attributes?["processingState"]?.string == "VALID" && build.attributes?["buildAudienceType"]?.string == "APP_STORE_ELIGIBLE"
            && prerelease.attributes?["version"]?.string == version.attributes?["versionString"]?.string && prerelease.attributes?["platform"]?.string == version.attributes?["platform"]?.string
    }

    func reviewDetail(versionId: String, client: AppStoreConnectClient) async throws -> AppStoreConnectClient.Resource? {
        let details: [AppStoreConnectClient.Resource]
        do { details = try await client.get("/v1/appStoreVersions/\(versionId)/appStoreReviewDetail") } catch AppStoreConnectClient.Failure.status(404) { return nil }
        guard details.count <= 1, details.allSatisfy({ $0.type == "appStoreReviewDetails" && $0.id.range(of: "^[a-zA-Z0-9_-]{1,256}$", options: .regularExpression) != nil && Apple.within($0, "appStoreVersion", "appStoreVersions", versionId) }) else { throw PublishFailure.invalid("Apple returned App Review Information outside the selected version.") }
        return details.first
    }

    /// The App Review information digest: the detail ID and its validated contact and demo fields.
    static func reviewInformationDigest(_ detail: AppStoreConnectClient.Resource) throws -> String {
        guard detail.type == "appStoreReviewDetails", !detail.id.isEmpty else { throw PublishFailure.invalid("Apple returned invalid App Review Information.") }
        let fields = try ReviewInformation(Planner.resource(detail)["attributes"]).validated()
        return JSONText.array([.string(detail.id), fields.json]).sha256
    }

    static func attachmentsDigest(_ attachments: [AppStoreConnectClient.Resource], detailId: String) throws -> String {
        _ = try ReviewInformation.scopedAttachments(attachments, detailId: detailId)
        let snapshot = try attachments.map { attachment -> (String, JSONText) in
            let value = try ReviewInformation.attachmentSnapshot(attachment, detailId: detailId)
            guard Apple.delivery(attachment) == "COMPLETE" else { throw PublishFailure.invalid("Wait for App Review attachments to finish processing before submission.") }
            return (attachment.id, value)
        }.sorted { $0.0.compare($1.0, locale: Locale(identifier: "en")) == .orderedAscending }
        return JSONText.array(snapshot.map(\.1)).sha256
    }

    static func cancellationDigest(_ submission: AppStoreConnectClient.Resource, items: [AppStoreConnectClient.Resource], appId: String, versionId: String) throws -> String {
        guard submission.type == "reviewSubmissions", Apple.within(submission, "app", "apps", appId), let state = submission.attributes?["state"]?.string,
              ["WAITING_FOR_REVIEW", "IN_REVIEW", "UNRESOLVED_ISSUES"].contains(state) else { throw PublishFailure.invalid("Choose an active App Review submission for this app.") }
        guard items.count == 1, items[0].type == "reviewSubmissionItems", Apple.within(items[0], "reviewSubmission", "reviewSubmissions", submission.id), Apple.owned(items[0], "appStoreVersion", "appStoreVersions", versionId) else {
            throw PublishFailure.invalid("This App Review submission contains other material. Manage it under App Review in the app's sidebar in App Store Connect.")
        }
        func value(_ item: JSONValue?) -> JSONText { item?.string.map { .string($0) } ?? .null }
        return JSONText.array([.string(submission.id), .string(state), value(submission.attributes?["platform"]), .string(items[0].id), value(items[0].attributes?["state"]), .string(versionId)]).sha256
    }
}
