import Foundation
import SQLCipher
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct ReporterSetupTests {
    init() throws { _ = try TestIsolation.require() }
    let app = "1000000001", token = "synthetic-reporter-token-first", secondToken = "synthetic-reporter-token-second"
    func configuration() -> URLSessionConfiguration { let value = URLSessionConfiguration.ephemeral; value.protocolClasses = [StubProtocol.self]; return value }
    func body(_ request: URLRequest) -> [String: String] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
        }
        let text = String(decoding: data, as: UTF8.self), form = URLComponents(string: "?" + text)?.queryItems?.first { $0.name == "jsonRequest" }?.value
        return (try! JSONSerialization.jsonObject(with: Data(form!.utf8))) as! [String: String]
    }
    func discovery(host: String, f: AccountLifecycleTests.Fixture, accounts: [String] = ["1000"], vendors: [String] = ["200000"], checkUnlocked: Bool = true, expectedToken: String? = nil) {
        StubProtocol.handle(host) { request in
            #expect(request.httpMethod == "POST" && request.url?.query == nil && request.url?.path == "/reportservice/sales/v1")
            if checkUnlocked {
                let lock = try! FileMutex.tryLock(f.root.appendingPathComponent("state-v2/reporter_" + JSONText.string(f.account.id).rawSHA256.prefix(32) + ".mutex"))
                #expect(lock != nil); lock?.release()
            }
            let fields = body(request), query = fields["queryInput"]!
            if let expectedToken { #expect(fields["accesstoken"] == expectedToken) }
            let xml: String
            if query == "[p=Reporter.properties, Sales.getAccounts]" {
                #expect(fields["account"] == nil)
                xml = "<Accounts>" + accounts.map { "<Account><Name>Synthetic \($0)</Name><Number>\($0)</Number></Account>" }.joined() + "</Accounts>"
            } else {
                #expect(query == "[p=Reporter.properties, Sales.getVendors]" && accounts.contains(fields["account"]!))
                xml = "<Vendors>" + vendors.map { "<Vendor>\($0)</Vendor>" }.joined() + "</Vendors>"
            }
            return (200, ["Content-Type": "text/xml"], Data(xml.utf8))
        }
    }
    func connect(_ f: AccountLifecycleTests.Fixture, baseline: ReportingConnectionState, host: String, token: String? = nil, account: String = "", vendor: String = "") async throws -> ReporterSetupResult {
        try await f.session.connectReporter(account: f.account, appId: app, token: token ?? self.token, baseline: baseline, selectedAccount: account, selectedVendor: vendor, writer: f.writer, origin: URL(string: "https://\(host)")!, configuration: configuration(), now: Date(timeIntervalSince1970: 1_767_225_600))
    }
    func baseline(_ f: AccountLifecycleTests.Fixture) async throws -> ReportingConnectionState { try await f.session.reportingConnection(account: f.account, appId: app) }
    @Test func shortOpaqueTokensAreVerifiedAndSavedWithoutChangingTheirContents() async throws {
        for (index, entered) in ["test-token", " \n test+/_=:! \t"].enumerated() {
            let f = try await AccountLifecycleTests().fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
            let token = TextSemantics.trim(entered), first = try await baseline(f), host = "reporter-opaque-\(index).reporting.test"
            discovery(host: host, f: f, expectedToken: token)
            guard case .connected(let saved) = try await connect(f, baseline: first, host: host, token: entered) else { Issue.record("Expected verified connection"); return }
            #expect(StubProtocol.requests(host).count == 2)
            let id = try #require(saved.connection?.reporter?.credentialId)
            #expect(try f.writer.read().entries["reporter:\(id)"] == token)
            #expect(saved.connection?.reporter?.accountNumber == "1000" && saved.connection?.reporter?.vendorNumber == "200000")
            let document = try await f.session.storeAccess { try $0.document(namespace: "sales_connection", key: f.account.id) }
            #expect(!String(decoding: try #require(document).payload, as: UTF8.self).contains(token))
        }
    }
    @Test func appleRejectionOfAShortTokenKeepsTheSavedConnectionAndCredential() async throws {
        let f = try await AccountLifecycleTests().fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let host = "reporter-opaque-rejected.reporting.test"
        discovery(host: host, f: f)
        guard case .connected(let saved) = try await connect(f, baseline: baseline(f), host: host) else { Issue.record("Expected initial connection"); return }
        let credentials = try f.writer.read(), writes = f.storage.counts.writes
        StubProtocol.handle(host) { request in
            #expect(body(request)["accesstoken"] == "test-token")
            return (401, ["Content-Type": "text/plain"], Data("Synthetic rejected token".utf8))
        }
        await #expect(throws: ReporterClient.Failure.expiredToken) { try await connect(f, baseline: saved, host: host, token: "test-token") }
        #expect(StubProtocol.requests(host).count == 1)
        #expect(try await baseline(f) == saved && f.storage.counts.writes == writes)
        #expect(try f.writer.read().entries == credentials.entries)
    }
    @Test func malformedTokenEntriesFailBeforeDiscoveryOrCredentialWrites() async throws {
        let f = try await AccountLifecycleTests().fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let first = try await baseline(f), host = "reporter-invalid-entry.reporting.test", writes = f.storage.counts.writes
        discovery(host: host, f: f)
        for token in ["", " \n\t", "test token", "test\ntoken", "test\u{0}token", "test\u{7f}token", "test\u{200b}token", String(repeating: "x", count: 201)] {
            await #expect(throws: ReporterClient.Failure.invalidToken) { try await connect(f, baseline: first, host: host, token: token) }
        }
        #expect(StubProtocol.requests(host).isEmpty && f.storage.counts.writes == writes)
        #expect(try await baseline(f) == first)
    }
    @Test func discoveryAndConnectionContractsMatchTheWebWithBoundedSyntheticCatalogs() throws {
        let fixture = try JSONText.parse(Data(contentsOf: try TestIsolation.require().appendingPathComponent("native-fixtures/reporter-catalogs.json")))
        guard case .array(let catalogs)? = fixture["catalogs"], case .array(let connections)? = fixture["connections"] else { Issue.record("Missing guarded Reporter vectors"); return }
        for vector in catalogs {
            let xml = vector["xml"]!.text!, kind = vector["kind"]!.text!
            func parse() throws -> JSONText {
                if kind == "accounts" { return .array(try ReporterCatalog.accounts(xml).map { .object([("name", .string($0.name)), ("number", .string($0.number))]) }) }
                return .array(try ReporterCatalog.vendors(xml).map(JSONText.string))
            }
            if vector["invalid"] == .bool(true) { #expect(throws: (any Error).self) { try parse() } }
            else { #expect(try parse() == vector["expected"]) }
        }
        for vector in connections {
            if vector["invalid"] == .bool(true) { #expect(throws: ReporterSetupFailure.invalid) { try ReportingConnection(json: vector["value"]!) } }
            else { #expect(try ReportingConnection(json: vector["value"]!).json == vector["expected"]) }
        }
        #expect(throws: ReporterClient.Failure.unsupported) { try ReporterCatalog.accounts(String(repeating: "a", count: 64_001)) }
        #expect(throws: ReporterClient.Failure.access) { try ReporterCatalog.accounts("<Accounts>" + (0..<201).map { "<Account><Name>Synthetic</Name><Number>\($0)</Number></Account>" }.joined() + "</Accounts>") }
    }
    @Test func automaticConnectSavesOnlyVerifiedMetadataAndDisconnectKeepsSavedReports() async throws {
        let f = try await AccountLifecycleTests().fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let first = try await baseline(f), host = "reporter-automatic.reporting.test"
        let before = try await f.session.storeAccess { try $0.documents(namespace: "sales") + $0.documents(namespace: "revisions") }
        discovery(host: host, f: f)
        guard case .connected(let saved) = try await connect(f, baseline: first, host: host) else { Issue.record("Expected automatic connect"); return }
        #expect(saved.revision == 1 && saved.connection?.reporter?.accountNumber == "1000" && saved.connection?.reporter?.vendorNumber == "200000")
        let id = try #require(saved.connection?.reporter?.credentialId)
        #expect(try f.writer.read().entries["reporter:\(id)"] == token)
        let document = try await f.session.storeAccess { try $0.document(namespace: "sales_connection", key: f.account.id) }
        #expect(!String(decoding: document!.payload, as: UTF8.self).contains(token))
        let disconnected = try await f.session.disconnectReporter(account: f.account, appId: app, baseline: saved, writer: f.writer)
        #expect(disconnected.revision == 2 && disconnected.connection?.reporter == nil && disconnected.connection?.vendorNumber == "200000")
        #expect(try f.writer.read().entries["reporter:\(id)"] == nil)
        #expect(try await f.session.storeAccess { try $0.documents(namespace: "sales") + $0.documents(namespace: "revisions") } == before)
    }
    @Test func ambiguousChoicesNeverSaveAndEveryContinuationRechecksTheTokenCatalog() async throws {
        let f = try await AccountLifecycleTests().fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let first = try await baseline(f), host = "reporter-choices.reporting.test", writes = f.storage.counts.writes
        discovery(host: host, f: f, accounts: ["1000", "1001"], vendors: ["200000", "300000"])
        guard case .chooseAccount(let accounts) = try await connect(f, baseline: first, host: host) else { Issue.record("Expected account choice"); return }
        #expect(accounts.map(\.number) == ["1000", "1001"])
        guard case .chooseVendor(_, let selected, let vendors) = try await connect(f, baseline: first, host: host, account: "1001") else { Issue.record("Expected vendor choice"); return }
        #expect(selected == "1001" && vendors == ["200000", "300000"] && f.storage.counts.writes == writes)
        discovery(host: host, f: f, accounts: ["1000"], vendors: ["200000"])
        await #expect(throws: ReporterSetupFailure.changed) { try await connect(f, baseline: first, host: host, account: "1001", vendor: "300000") }
        await #expect(throws: ReporterSetupFailure.changed) { try await connect(f, baseline: first, host: host, account: "1000", vendor: "300000") }
        #expect(try await baseline(f) == first && f.storage.counts.writes == writes)
    }
    @Test func replacementRemovesOnlyThePriorAccountsTokenAndPreservesOtherCredentials() async throws {
        let f = try await AccountLifecycleTests().fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let host = "reporter-replace.reporting.test"; discovery(host: host, f: f)
        guard case .connected(let first) = try await connect(f, baseline: baseline(f), host: host) else { Issue.record("Expected connect"); return }
        let previous = try #require(first.connection?.reporter?.credentialId), otherId = "00000000-0000-4000-8000-000000000096"
        _ = try f.writer.writeCredential("reporter:\(otherId)", root: f.root, value: "synthetic-other-reporting-token", expected: nil, adding: true)
        guard case .connected(let replaced) = try await connect(f, baseline: first, host: host, token: secondToken) else { Issue.record("Expected replacement"); return }
        let current = try #require(replaced.connection?.reporter?.credentialId), vault = try f.writer.read()
        #expect(current != previous && replaced.revision == first.revision + 1 && vault.entries["reporter:\(previous)"] == nil)
        #expect(vault.entries["reporter:\(current)"] == secondToken && vault.entries["reporter:\(otherId)"] != nil && vault.entries["apple:\(f.account.id)"] != nil)
        await #expect(throws: ReporterSetupFailure.changed) { try await f.session.disconnectReporter(account: f.account, appId: app, baseline: first, writer: f.writer) }
    }
    @Test func lateConnectionAndAccountChangesStopTheSaveBeforeKeychainIsChanged() async throws {
        for changeAccount in [false, true] {
            let f = try await AccountLifecycleTests().fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
            let first = try await baseline(f), host = "reporter-late-\(changeAccount).reporting.test"
            let store = try EncryptedDocumentStore(url: EncryptedDocumentStore.databaseURL(root: f.root), key: Data(0..<32), writable: true)
            StubProtocol.handle(host) { request in
                let query = body(request)["queryInput"]!
                if query.contains("getAccounts") { return (200, [:], Data("<Accounts><Account><Name>Synthetic</Name><Number>1000</Number></Account></Accounts>".utf8)) }
                if changeAccount {
                    let changed = Account(id: f.account.id, name: f.account.name, keyId: "NEWKEY", keyType: f.account.keyType, issuerId: f.account.issuerId, appIds: f.account.appIds, appNames: f.account.appNames)
                    try! store.transaction { _ in [.put(namespace: "accounts", key: "all", json: JSONText.array([WorkspaceSession.json(changed)]).data)] }
                } else {
                    try! FileMutex.withLock(store.directory.appendingPathComponent("reporter_" + JSONText.string(f.account.id).rawSHA256.prefix(32) + ".mutex")) {
                        try store.transaction { _ in [.put(namespace: "sales_connection", key: f.account.id, json: try SalesSyncTests.connection(#"{"vendorNumber":"300000"}"#, accountId: f.account.id).data)] }
                    }
                }
                return (200, [:], Data("<Vendors><Vendor>200000</Vendor></Vendors>".utf8))
            }
            let writes = f.storage.counts.writes
            if changeAccount { await #expect(throws: AccountFailure.stale) { try await connect(f, baseline: first, host: host) } }
            else { await #expect(throws: ReporterSetupFailure.changed) { try await connect(f, baseline: first, host: host) } }
            #expect(f.storage.counts.writes == writes)
        }
    }
    @Test func keychainSaveFailureAndCancellationKeepThePreviousConnection() async throws {
        let f = try await AccountLifecycleTests().fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let first = try await baseline(f), host = "reporter-cancel.reporting.test"; discovery(host: host, f: f)
        f.storage.deny(true)
        await #expect(throws: ReporterSetupFailure.keychain) { try await connect(f, baseline: first, host: host) }
        f.storage.deny(false); #expect(try await baseline(f) == first)
        let task = Task { try await Task.sleep(for: .milliseconds(10)); return try await connect(f, baseline: first, host: host) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await baseline(f) == first)
    }
    @Test func failedDisconnectRestoresTheConnectionAndExplicitRetryUsesANewRevision() async throws {
        let f = try await AccountLifecycleTests().fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let host = "reporter-disconnect-failure.reporting.test"; discovery(host: host, f: f)
        guard case .connected(let connected) = try await connect(f, baseline: baseline(f), host: host) else { Issue.record("Expected connect"); return }
        f.storage.denyDeletion(true)
        await #expect(throws: ReporterSetupFailure.keychain) { try await f.session.disconnectReporter(account: f.account, appId: app, baseline: connected, writer: f.writer) }
        let restored = try await baseline(f)
        #expect(restored.connection == connected.connection && restored.revision == connected.revision + 2)
        let id = try #require(restored.connection?.reporter?.credentialId)
        #expect(try f.writer.read().entries["reporter:\(id)"] == token)
        f.storage.denyDeletion(false)
        await #expect(throws: ReporterSetupFailure.changed) { try await f.session.disconnectReporter(account: f.account, appId: app, baseline: connected, writer: f.writer) }
        try await f.session.retryKeychainAccess(accountId: f.account.id, writer: f.writer)
        let removed = try await f.session.disconnectReporter(account: f.account, appId: app, baseline: restored, writer: f.writer)
        let afterRemoval = try f.writer.read()
        #expect(removed.connection?.reporter == nil && afterRemoval.entries["reporter:\(id)"] == nil)
    }
    @Test func concurrentSessionsHaveOneWinnerAndNeverReplaceTheConnectionMutex() async throws {
        let f = try await AccountLifecycleTests().fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let second = try WorkspaceSession(workspace: Workspace(root: f.root), vault: f.writer.read(), credentialWriter: f.writer)
        let first = try await baseline(f), host = "reporter-concurrent.reporting.test"; discovery(host: host, f: f, checkUnlocked: false)
        let mutex = try await f.session.reportingMutex(accountId: f.account.id)
        let attributes = try FileManager.default.attributesOfItem(atPath: mutex.path)
        let inode = try #require(attributes[.systemFileNumber] as? NSNumber)
        let results = await withTaskGroup(of: Bool.self) { group in
            group.addTask { do { if case .connected = try await connect(f, baseline: first, host: host) { return true } } catch ReporterSetupFailure.changed {} catch { Issue.record(error) }; return false }
            group.addTask { do { if case .connected = try await second.connectReporter(account: f.account, appId: app, token: secondToken, baseline: first, writer: f.writer, origin: URL(string: "https://\(host)")!, configuration: configuration()) { return true } } catch ReporterSetupFailure.changed {} catch { Issue.record(error) }; return false }
            var result: [Bool] = []; for await value in group { result.append(value) }; return result
        }
        #expect(results.filter { $0 }.count == 1)
        #expect(try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber == inode)
        #expect(try f.writer.read().entries.keys.filter { $0.hasPrefix("reporter:") }.count == 1)
    }
    @Test func teamApiSourceUsesItsVendorWithoutDisconnectingOrReadingReporterCredentials() async throws {
        let f = try await AccountLifecycleTests().fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let host = "reporter-api-choice.reporting.test"; discovery(host: host, f: f)
        guard case .connected(let first) = try await connect(f, baseline: baseline(f), host: host) else { Issue.record("Expected connect"); return }
        let saved = try await f.session.saveApiReportingVendor(account: f.account, appId: app, vendorNumber: "300000", baseline: first)
        #expect(saved.connection?.reporter == first.connection?.reporter && saved.connection?.vendorNumber == "300000")
        let reads = f.storage.counts.reads
        let api = try await f.session.capturedSalesConnection(accountId: f.account.id, reporter: nil, source: .api)
        #expect(api?.vendorNumber == "300000" && api?.reporter == nil && f.storage.counts.reads == reads)
        let apiHost = "reporter-separate-api.appstoreconnect.test", reporterRequests = StubProtocol.requests(host).count
        StubProtocol.handle(apiHost) { request in
            if ["/v1/apps/1000000001/inAppPurchasesV2", "/v1/apps/1000000001/subscriptionGroups"].contains(request.url!.path) { return (200, [:], Data(#"{"data":[],"links":{}}"#.utf8)) }
            #expect(request.httpMethod == "GET" && request.url!.absoluteString.contains("filter%5BvendorNumber%5D=300000"))
            if request.url!.path == "/v1/financeReports" { return (200, ["Content-Type": "application/a-gzip"], FinanceSyncTests.january) }
            #expect(request.url!.path == "/v1/salesReports")
            return (200, ["Content-Type": "application/a-gzip"], SalesSyncTests.report([["APPLE", "SYNTHETIC", "1000000001", "1F", "3", "0.99", "02/10/2026", "02/10/2026", "US", ""]]))
        }
        let client = try FinanceSyncTests().client(apiHost, f.account)
        let finance = try await f.session.downloadFinancial(account: f.account, appId: app, region: "ZZ", periods: [FiscalPeriod(year: 2026, period: 4)], client: client, source: .api)
        #expect(finance.reports.count == 1)
        _ = try await f.session.downloadSales(account: f.account, appId: app, days: ["2026-02-10"], client: client, source: .api)
        #expect(StubProtocol.requests(host).count == reporterRequests && f.storage.counts.reads == reads)
        #expect(try await baseline(f) == saved)
        await #expect(throws: ReporterSetupFailure.changed) { try await f.session.saveApiReportingVendor(account: f.account, appId: app, vendorNumber: "400000", baseline: first) }
        for vendor in ["invalid", "20000", "٢٠٠٠٠٠", "123456789012345678901"] { await #expect(throws: ReporterSetupFailure.invalid) { try await f.session.saveApiReportingVendor(account: f.account, appId: app, vendorNumber: vendor, baseline: saved) } }
    }
    @Test func storedForeignScopesAndMalformedConnectionMetadataFailBeforeCredentialAccess() async throws {
        let f = try await AccountLifecycleTests().fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let reads = f.storage.counts.reads
        for json in [#"{"vendorNumber":"200000"}"#, #"{"schemaVersion":1,"accountId":"foreign","vendorNumber":"200000"}"#] {
            try await f.session.storeAccess { store in try store.transaction { _ in [.put(namespace: "sales_connection", key: f.account.id, json: Data(json.utf8))] } }
            await #expect(throws: ReporterSetupFailure.invalid) { try await f.session.reporterClient(accountId: f.account.id) }
        }
        #expect(f.storage.counts.reads == reads)
    }
    @Test func connectionWritesWaitForAnOwnedProcessEvenWithAnOldMutexTimestamp() async throws {
        let root = try TestIsolation.require().appendingPathComponent("reporter-lock-policy")
        let (session, _) = try DraftTests().session(directory: root)
        let account = try #require(try await session.accounts().first), first = try await session.readReportingState(accountId: account.id)
        let mutex = try await session.reportingMutex(accountId: account.id), ready = root.appendingPathComponent("lock-ready"), release = root.appendingPathComponent("lock-release")
        #expect(FileManager.default.fileExists(atPath: ready.path)); #expect(try FileMutex.tryLock(mutex) == nil)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: mutex.path)
        let attributes = try FileManager.default.attributesOfItem(atPath: mutex.path), inode = try #require(attributes[.systemFileNumber] as? NSNumber)
        let store = try EncryptedDocumentStore(url: EncryptedDocumentStore.databaseURL(root: root), key: Data(0..<32), writable: true)
        let pending = Task { try await session.saveApiReportingVendor(account: account, appId: app, vendorNumber: "200000", baseline: first) }
        try await Task.sleep(for: .milliseconds(75))
        #expect(try FileMutex.tryLock(mutex) == nil)
        #expect(try store.document(namespace: "sales_connection", key: account.id) == nil)
        // This owned pure fixture exits as requested; no developer process is signaled.
        try JobLock.exclusive(release, "interrupt")
        let saved = try await pending.value
        #expect(saved.revision == 1 && saved.connection?.vendorNumber == "200000")
        #expect(try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber == inode)
        #expect(try FileMutex.tryLock(mutex) != nil)
    }
    @Test func cancellationAfterTokenInstallationRollsBackOnlyTheNewCredentialAndMetadata() async throws {
        let f = try await AccountLifecycleTests().fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let first = try await baseline(f), host = "reporter-cancel-write.reporting.test"; discovery(host: host, f: f)
        final class Cancellation: @unchecked Sendable {
            let lock = NSLock(); var task: Task<ReporterSetupResult, Error>?
            func cancel() { lock.withLock { task?.cancel() } }
            func set(_ task: Task<ReporterSetupResult, Error>) { lock.withLock { self.task = task } }
        }
        let control = Cancellation()
        f.storage.onSave { control.cancel() }
        let pending = Task { try await Task.sleep(for: .milliseconds(20)); return try await connect(f, baseline: first, host: host) }
        control.set(pending)
        await #expect(throws: CancellationError.self) { try await pending.value }
        f.storage.onSave(nil)
        #expect(try await baseline(f) == first)
        #expect(try f.writer.read().entries.keys.filter { $0.hasPrefix("reporter:") }.isEmpty)
        #expect(try f.writer.read().entries["apple:\(f.account.id)"] != nil)
    }
    @Test func anEncryptedStoreFailureAfterTokenInstallationRemovesOnlyTheNewToken() async throws {
        let f = try await AccountLifecycleTests().fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let empty = try await baseline(f)
        let previous = try await f.session.saveApiReportingVendor(account: f.account, appId: app, vendorNumber: "300000", baseline: empty)
        let database = EncryptedDocumentStore.databaseURL(root: f.root); try TestIsolation.check(database)
        var handle: OpaquePointer?
        #expect(sqlite3_open_v2(database.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        let key = Data(0..<32).map { String(format: "%02x", $0) }.joined()
        #expect(sqlite3_exec(handle, "PRAGMA key = \"x'\(key)'\"", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(handle, "CREATE TRIGGER synthetic_connection_failure BEFORE UPDATE ON documents WHEN NEW.namespace = 'sales_connection' BEGIN SELECT RAISE(ABORT, 'synthetic connection storage failure'); END", nil, nil, nil) == SQLITE_OK)
        let host = "reporter-store-failure.reporting.test"; discovery(host: host, f: f)
        let writes = f.storage.counts.writes
        await #expect(throws: ReporterSetupFailure.storage) { try await connect(f, baseline: previous, host: host) }
        #expect(try await baseline(f) == previous)
        #expect(f.storage.counts.writes == writes + 2)
        let vault = try f.writer.read()
        #expect(vault.entries.keys.filter { $0.hasPrefix("reporter:") }.isEmpty && vault.entries["apple:\(f.account.id)"] != nil)
    }
}
