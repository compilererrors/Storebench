import CryptoKit
import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct ImportJobTests {
    init() throws { _ = try TestIsolation.require() }
    let appId = "1000000001"
    let instant = Date(timeIntervalSince1970: 1_770_912_000)
    func session() throws -> (WorkspaceSession, URL) { try AppImportTests().session() }
    func reader(_ root: URL) throws -> EncryptedDocumentStore {
        try EncryptedDocumentStore(url: EncryptedDocumentStore.databaseURL(root: root), key: Data(0..<32), writable: true)
    }
    func wait(_ operation: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(try await operation()) { guard ContinuousClock.now < deadline else { throw FileMutex.Failure.timeout }; try await Task.sleep(for: .milliseconds(10)) }
    }
    func revision(_ id: String, accountId: String, origin: String? = nil) -> JSONText {
        var fields: [(String, JSONText)] = [("schemaVersion", .number(1)), ("id", .string(id)), ("importedAt", .string(CustomerReview.isoString(instant))),
            ("account", .object([("id", .string(accountId)), ("name", .string("Synthetic account"))])),
            ("app", .object([("id", .string(appId)), ("name", .string("Sample App")), ("bundleId", .string("example.synthetic.app")), ("sku", .string("SYNTHETIC")), ("primaryLocale", .string("en-US"))])),
            ("appInfos", .array([])), ("versions", .array([]))]
        if let origin { fields.append(("origin", .string(origin))) }; return .object(fields)
    }
    func seed(_ job: ImportJob, account: Account, store: EncryptedDocumentStore, assigned: JSONText? = nil) throws {
        let key = try ReportJobs.identity(.material, accountId: account.id, appId: appId)
        try store.transaction { _ in
            var writes: [EncryptedDocumentStore.Write] = [.put(namespace: "jobs", key: key, json: job.json.data)]
            if let assigned, let id = job.revisionId { writes.append(.put(namespace: "revisions", key: "\(account.id):\(appId):\(id)", json: assigned.data)) }
            return writes
        }
    }
    func transport(_ suffix: String, account: Account, gate: AnalyticsJobDelayStubProtocol.Gate? = nil,
                   mutate: @escaping @Sendable (String) -> Void = { _ in }) throws -> AppStoreConnectClient {
        let host = "import-job-\(suffix).appstoreconnect.test", images = "import-job-\(suffix).mzstatic.com"
        let png = Data([0x89, 0x50, 0x4e, 0x47]) + Data("synthetic image".utf8)
        func page(_ data: Any) -> (Int, [String: String], Data) { (200, [:], try! JSONSerialization.data(withJSONObject: ["data": data, "links": [:]])) }
        if let gate { AnalyticsJobDelayStubProtocol.register(images, gate: gate, bytes: png, headers: ["Content-Type": "image/png"]) }
        StubProtocol.handle(host) { request in
            let path = request.url!.path; mutate(path)
            switch path {
            case "/v1/apps/1000000001": return page(["type": "apps", "id": "1000000001", "attributes": ["name": "Sample App", "bundleId": "example.synthetic.app", "sku": "SYNTHETIC", "primaryLocale": "en-US"]])
            case "/v1/apps/1000000001/appInfos": return page([])
            case "/v1/apps/1000000001/assetLibrary": return (404, [:], Data())
            case "/v1/apps/1000000001/appStoreVersions": return page([["type": "appStoreVersions", "id": "version-1", "attributes": ["versionString": "1.0", "platform": "IOS"]]])
            case "/v1/appStoreVersions/version-1/appStoreVersionLocalizations": return page([["type": "appStoreVersionLocalizations", "id": "locale-1", "attributes": ["locale": "en-US", "description": "Synthetic listing"]]])
            case "/v1/appStoreVersionLocalizations/locale-1/appScreenshotSets": return page([["type": "appScreenshotSets", "id": "set-1", "attributes": ["screenshotDisplayType": "APP_IPHONE_67"]]])
            case "/v1/appScreenshotSets/set-1/appScreenshots": return page([["type": "appScreenshots", "id": "shot-1", "attributes": ["fileName": "synthetic.png", "imageAsset": ["templateUrl": "https://\(images)/synthetic/{w}x{h}.{f}", "width": 10, "height": 20]]]])
            default: Issue.record("Unexpected synthetic import route"); return (404, [:], Data())
            }
        }
        if gate == nil { StubProtocol.handle(images) { _ in (200, ["Content-Type": "image/png"], png) } }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AnalyticsJobDelayStubProtocol.self, StubProtocol.self]
        return AppStoreConnectClient(token: try AppleToken(account: account, privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation), origin: URL(string: "https://\(host)")!, configuration: config)
    }

    @Test func importContractsMatchWebAndNeverDisplayLegacyDiagnostics() throws {
        let fixture = try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/import-jobs.json")))
        guard case .array(let rows)? = fixture["jobs"], case .object(let messages)? = fixture["messages"] else { throw ImportFailure.status }
        for row in rows {
            let input = try #require(row["input"])
            if row["rejected"] == .bool(true) { #expect(throws: ImportFailure.status) { try ImportJob(json: input) } }
            else {
                let actual = try ImportJob(json: input)
                #expect(actual.json == row["expected"], "Synthetic import case: \(row["id"]?.text ?? "unknown")")
                if row["id"]?.text == "legacy-diagnostic" { #expect(actual.error == ImportFailure.status.message) }
                if row["id"]?.text == "bounded-unicode-phase" { #expect(actual.displayPhase == "App material import") }
            }
        }
        #expect(messages.count == ImportFailure.allCases.count)
        for (code, text) in messages { #expect(ReportingMessages.message(code) == text.text) }
        #expect(try ReportJobs.name(.material, accountId: "synthetic-account", appId: appId) == fixture["lockName"]?.text)
    }

    @Test func startupRecoversAssignedCommitBeforeKeychainOrNetworkAndDoesNotDuplicateIt() async throws {
        for background in [false, true] {
            let (session, root) = try session(); defer { try? FileManager.default.removeItem(at: root) }
            let account = try #require(try await session.accounts().first), store = try reader(root), id = UUID().uuidString.lowercased()
            let job = ImportJob(id: id, now: instant)
            try seed(job, account: account, store: store, assigned: revision(id, accountId: account.id))
            let before = try store.documents(namespace: "revisions")
            if background {
                let recovered = try await session.startImport(account: account, appId: appId)
                #expect(recovered.id == id && recovered.state == .complete && recovered.revisionId == id)
            } else {
                let client = try transport("recover", account: account)
                let result = try await session.importApp(account: account, appId: appId, client: client)
                #expect(result == ImportResult(revisionId: id, changed: true, screenshots: 0))
                #expect(StubProtocol.requests("import-job-recover.appstoreconnect.test").isEmpty)
            }
            #expect(try store.documents(namespace: "revisions") == before)
            #expect(try await session.importJob(account: account, appId: appId)?.state == .complete)
        }
    }

    @Test func recoveryIgnoresNewerPointersAndLocalDraftsAndPreservesCorruptReceipts() async throws {
        for kind in ["missing", "local", "foreign", "malformed"] {
            let (session, root) = try session(); defer { try? FileManager.default.removeItem(at: root) }
            let account = try #require(try await session.accounts().first), store = try reader(root), id = UUID().uuidString.lowercased()
            let job = ImportJob(id: id, now: instant), newer = UUID().uuidString.lowercased()
            try store.transaction { _ in [.put(namespace: "revisions", key: "\(account.id):\(appId):\(newer)", json: revision(newer, accountId: account.id).data),
                .put(namespace: "latest_imports", key: "\(account.id):\(appId)", json: JSONText.object([("revisionId", .string(newer))]).data)] }
            let assigned: JSONText? = switch kind {
            case "local": revision(id, accountId: account.id, origin: "local")
            case "foreign": revision(id, accountId: "synthetic-other-account")
            case "malformed": .object([("id", .string(id))])
            default: nil
            }
            try seed(job, account: account, store: store, assigned: assigned)
            let before = try store.documents(namespace: "revisions"), record = try store.document(namespace: "jobs", key: "import:\(account.id):\(appId)")
            if kind == "foreign" || kind == "malformed" {
                await #expect(throws: ImportFailure.status) { try await session.importJob(account: account, appId: appId) }
                #expect(try store.document(namespace: "jobs", key: "import:\(account.id):\(appId)") == record)
            } else {
                let recovered = try #require(try await session.importJob(account: account, appId: appId))
                #expect(recovered.state == .failed && recovered.code == "SB-IMPORT-INTERRUPTED" && recovered.revisionId == id)
            }
            #expect(try store.documents(namespace: "revisions") == before)
        }
    }

    @Test func backgroundProgressSurvivesSecondSessionAndStartsCoalesceWithoutKeychain() async throws {
        let (session, root) = try session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), gate = AnalyticsJobDelayStubProtocol.Gate(), store = try reader(root)
        let before = try store.documents(namespace: "revisions"), client = try transport("complete", account: account, gate: gate)
        let started = try await session.startImport(account: account, appId: appId, client: client)
        try await wait { gate.pending == 1 }
        let second = try WorkspaceSession(workspace: Workspace(root: root), vault: await session.vault)
        let running = try #require(try await second.importJob(account: account, appId: appId))
        #expect(running.id == started.id && running.state == .running && running.phase == "Downloading screenshots" && running.completed == 0)
        let same = try await second.startImport(account: account, appId: appId)
        #expect(same.id == started.id && same.isActive)
        #expect(try store.documents(namespace: "revisions") == before)
        gate.release()
        try await wait { try await second.importJob(account: account, appId: appId)?.state == .complete }
        let saved = try #require(try await second.importJob(account: account, appId: appId))
        #expect(saved.id == started.id && saved.revisionId == started.id && saved.completed == 1)
        let imported = try #require(try await second.revisions(accountId: account.id, appId: appId).first(where: { $0.id == started.id }))
        #expect(imported.versions.first?.localizations.first?.screenshotSets.first?.screenshots.count == 1)
        let name = try ReportJobs.name(.material, accountId: account.id, appId: appId)
        try await wait { !FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("\(name).lock").path) }
        #expect(FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("\(name).lock.mutex").path))
    }

    @Test func onlyExactCrossSessionCancellationStopsImportAndLeavesEarlierRevision() async throws {
        let (session, root) = try session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), gate = AnalyticsJobDelayStubProtocol.Gate(), store = try reader(root)
        let before = try store.documents(namespace: "revisions"), client = try transport("cancel", account: account, gate: gate)
        let started = try await session.startImport(account: account, appId: appId, client: client)
        try await wait { gate.pending == 1 }
        let second = try WorkspaceSession(workspace: Workspace(root: root), vault: await session.vault), key = "import:\(account.id):\(appId)"
        _ = try await second.cancelImport(account: account, appId: appId, id: UUID().uuidString.lowercased())
        #expect(try store.document(namespace: "job_cancels", key: key) == nil)
        let cancel = try await second.cancelImport(account: account, appId: appId, id: started.id)
        #expect(cancel?.id == started.id && cancel?.state == .cancelling)
        try await wait { try await second.importJob(account: account, appId: appId)?.state == .cancelled }
        gate.release()
        #expect(try store.documents(namespace: "revisions") == before)
        let replacement = try await second.startImport(account: account, appId: appId, client: transport("after-cancel", account: account))
        #expect(replacement.id != started.id)
        _ = try await session.cancelImport(account: account, appId: appId, id: started.id)
        #expect(try store.document(namespace: "job_cancels", key: key) == nil)
        try await wait { try await second.importJob(account: account, appId: appId)?.state == .complete }
        #expect(try await second.importJob(account: account, appId: appId)?.id == replacement.id)
    }

    @Test func changedAppScopeDuringDownloadCannotSaveARevision() async throws {
        let (session, root) = try session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), gate = AnalyticsJobDelayStubProtocol.Gate(), store = try reader(root)
        let before = try store.documents(namespace: "revisions"), client = try transport("scope", account: account, gate: gate)
        _ = try await session.startImport(account: account, appId: appId, client: client)
        try await wait { gate.pending == 1 }
        let original = try #require(try store.document(namespace: "accounts", key: "all"))
        let accounts = try JSONText.parse(original.payload)
        guard case .array(let items) = accounts else { throw ImportFailure.status }
        let updated = JSONText.array(items.map { item in
            guard case .object(let fields) = item, item["id"]?.text == account.id else { return item }
            return .object(fields.map { ($0.0, $0.0 == "appIds" ? .array([]) : $0.1) })
        })
        try store.transaction { _ in [.put(namespace: "accounts", key: "all", json: updated.data)] }
        gate.release()
        try await wait { try store.document(namespace: "jobs", key: "import:\(account.id):\(appId)").map { try ImportJob(json: JSONText.parse($0.payload)).state == .failed } ?? false }
        #expect(try store.documents(namespace: "revisions") == before)
        try store.transaction { _ in [.put(namespace: "accounts", key: "all", json: original.payload)] }
        #expect(try await session.importJob(account: account, appId: appId)?.code == "SB-IMPORT-REQUEST")
    }

    @Test func ownedImportProjectionAndTerminalWritesRequireExactIdentity() async throws {
        let (session, root) = try session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), store = try reader(root), id = UUID().uuidString.lowercased()
        let owner = try #require(try ReportJobs.acquire(.material, accountId: account.id, appId: appId, directory: store.directory, id: id)); defer { owner.release() }
        let placeholder = try #require(try await session.importJob(account: account, appId: appId))
        #expect(placeholder.id == id && placeholder.state == .running)
        #expect(try store.document(namespace: "jobs", key: owner.key) == nil)
        var job = ImportJob(id: id, now: instant); try ReportJobs.start(job, ownership: owner, store: store)
        let foreign = ImportJob(id: UUID().uuidString.lowercased(), now: instant)
        try seed(foreign, account: account, store: store)
        #expect(throws: ReportJobFailure.status) { try ReportJobs.update(job, ownership: owner, store: store) }
        #expect(try await session.importJob(account: account, appId: appId)?.id == id)
        try seed(job, account: account, store: store)
        job.complete(revision: id, phase: "Revision saved", at: CustomerReview.isoString(instant))
        try ReportJobs.update(job, ownership: owner, store: store)
        let before = try store.document(namespace: "jobs", key: owner.key)
        try ReportJobs.update(job, ownership: owner, store: store)
        #expect(try store.document(namespace: "jobs", key: owner.key) == before)
        job.phase = "Saving revision"
        #expect(throws: ReportJobFailure.status) { try ReportJobs.update(job, ownership: owner, store: store) }
        #expect(try ReportJobs.cancel(ImportJob.self, family: .material, accountId: account.id, appId: appId, id: id, store: store) == false)
    }

    @Test func previousImportMustMatchItsAccountAndDocumentIdentityBeforeReuse() async throws {
        let (session, root) = try session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), store = try reader(root), id = UUID().uuidString.lowercased()
        try store.transaction { _ in [.put(namespace: "revisions", key: "\(account.id):\(appId):\(id)", json: revision(id, accountId: "synthetic-other-account").data),
            .put(namespace: "latest_imports", key: "\(account.id):\(appId)", json: JSONText.object([("revisionId", .string(id))]).data)] }
        let before = try store.documents(namespace: "revisions")
        let client = try transport("foreign-baseline", account: account)
        await #expect(throws: ImportFailure.status) { try await session.importApp(account: account, appId: appId, client: client) }
        #expect(try store.documents(namespace: "revisions") == before)
        #expect(try await session.importJob(account: account, appId: appId)?.state == .failed)
        #expect(StubProtocol.requests("import-job-foreign-baseline.mzstatic.com").isEmpty)
    }

    @Test func liveLegacyOwnerIsNeverExpiredByAnOldTimestamp() async throws {
        let (session, root) = try session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), store = try reader(root), id = UUID().uuidString.lowercased()
        let name = try ReportJobs.name(.material, accountId: account.id, appId: appId), lock = store.directory.appendingPathComponent("\(name).lock")
        try seed(ImportJob(id: id, now: Date(timeIntervalSince1970: 1)), account: account, store: store)
        try JobLock.exclusive(lock, JSONText.object([("id", .string(id)), ("pid", .number(Double(getpid())))]).stringify())
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: lock.path)
        let before = try store.document(namespace: "jobs", key: "import:\(account.id):\(appId)")
        #expect(try await session.importJob(account: account, appId: appId)?.state == .running)
        let same = try await session.startImport(account: account, appId: appId)
        #expect(same.id == id && same.state == .running)
        #expect(try store.document(namespace: "jobs", key: "import:\(account.id):\(appId)") == before)
        // This owned synthetic legacy process releases only its own owner record.
        try FileManager.default.removeItem(at: lock)
        #expect(try await session.importJob(account: account, appId: appId)?.code == "SB-IMPORT-INTERRUPTED")
    }

    @Test func screenshotReadsBoundActualBytesAndRejectMalformedAssetDimensionsAndURLs() async throws {
        let (session, root) = try session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), client = try transport("bounded", account: account)
        StubProtocol.handle("import-job-bounded.mzstatic.com") { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            return (200, ["Content-Type": "image/png", "Content-Length": "1"], Data("synthetic".utf8))
        }
        await #expect(throws: BoundedResponse.Failure.tooLarge) { try await client.image(URL(string: "https://import-job-bounded.mzstatic.com/synthetic.png")!, maxBytes: 3) }
        let credentialURL = "https://" + ["synthetic", "synthetic"].joined(separator: ":") + String(UnicodeScalar(64)) + "images.mzstatic.com/{w}x{h}.{f}"
        for (width, url) in [(1.5, "https://images.mzstatic.com/{w}x{h}.{f}"), (0, "https://images.mzstatic.com/{w}x{h}.{f}"),
            (10, credentialURL), (10, "https://images.mzstatic.com:443/{w}x{h}.{f}"),
            (10, "https://images.mzstatic.com/{w}x{h}.{f}#synthetic"), (10, "https://example.com/{w}x{h}.{f}")] {
            let data = try JSONSerialization.data(withJSONObject: ["type": "appScreenshots", "id": "synthetic-shot", "attributes": ["imageAsset": ["templateUrl": url, "width": width, "height": 20]]])
            let resource = try JSONDecoder().decode(AppStoreConnectClient.Resource.self, from: data)
            #expect(throws: ImportFailure.download) { try WorkspaceSession.screenshotAsset(resource) }
        }
    }
}

@Suite(.serialized) struct ImportJobProcessTests {
    init() throws { _ = try TestIsolation.require() }
    @Test(arguments: [true, false]) func interruptionRecoversOnlyItsAssignedCommitWithoutReplacingMutex(committed: Bool) async throws {
        let fixture = try ImportJobTests(), root = try TestIsolation.require().appendingPathComponent(committed ? "import-job-recovery-policy" : "import-job-interrupted-policy")
        let (session, _) = try SalesSyncTests().session(directory: root), account = try #require(try await session.accounts().first), store = try fixture.reader(root)
        let id = committed ? "00000000-0000-4000-8000-000000000071" : "00000000-0000-4000-8000-000000000072"
        let name = try ReportJobs.name(.material, accountId: account.id, appId: fixture.appId), mutex = store.directory.appendingPathComponent("\(name).lock.mutex")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("lock-ready").path))
        #expect(try FileMutex.tryLock(mutex) == nil)
        let inode = try #require(try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber)
        let placeholder = try #require(try await session.importJob(account: account, appId: fixture.appId))
        #expect(placeholder.id == id && placeholder.state == .running)
        var job = ImportJob(id: id, now: Date(timeIntervalSince1970: 1)); job.phase = "Saving revision"
        try fixture.seed(job, account: account, store: store, assigned: committed ? fixture.revision(id, accountId: account.id) : nil)
        let before = try store.documents(namespace: "revisions")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: mutex.path)
        #expect(try await session.importJob(account: account, appId: fixture.appId)?.state == .running)
        let runningCard = try #require(try await session.connectedApps().first { $0.account.id == account.id && $0.app.id == fixture.appId })
        #expect(runningCard.material?.id == id && runningCard.material?.state == .running && !runningCard.materialUnavailable)
        #expect(try ReportJobs.acquire(.material, accountId: account.id, appId: fixture.appId, directory: store.directory, id: UUID().uuidString.lowercased()) == nil)
        try JobLock.exclusive(root.appendingPathComponent("lock-release"), "interrupt")
        try await fixture.wait { if let proof = try FileMutex.tryLock(mutex) { proof.release(); return true }; return false }
        let recoveredCard = try #require(try await session.connectedApps().first { $0.account.id == account.id && $0.app.id == fixture.appId })
        let recovered = try #require(recoveredCard.material)
        #expect(!recoveredCard.materialUnavailable)
        #expect(recovered.id == id && recovered.revisionId == id && recovered.state == (committed ? .complete : .failed))
        #expect(recovered.code == (committed ? nil : "SB-IMPORT-INTERRUPTED"))
        #expect(try store.documents(namespace: "revisions") == before)
        #expect(try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber == inode)
    }
}
