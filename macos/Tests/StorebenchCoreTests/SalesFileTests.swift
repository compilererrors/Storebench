import CryptoKit
import Darwin
import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct SalesFileTests {
    init() throws { _ = try TestIsolation.require() }
    let appId = "1000000001"
    func golden() throws -> JSONText { try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/sales-file-formats.json"))) }
    func input(_ row: String = "1000000001,2026-02-10,2026-02-10,USA,3") -> Data { Data(("app_id,begin_date,end_date,territory,paid_units\r\n" + row + "\r\n").utf8) }
    func account(_ session: WorkspaceSession) async throws -> Account { try #require(try await session.accounts().first) }
    func records(_ session: WorkspaceSession, _ account: Account) async throws -> [SalesRecord] { try await session.salesFileRecords(account: account, appId: appId) }

    @Test func allFileFormatsAndSummaryFailuresMatchWebGeneratedVectors() throws {
        let value = try golden(), accountId = value["accountId"]!.text!, appId = value["appId"]!.text!, date = value["importedAt"]!.text!
        guard case .array(let vectors)? = value["vectors"] else { Issue.record("Missing synthetic sales file vectors"); return }
        for vector in vectors {
            let text = vector["text"]!.text!, scope = try vector["productScope"].map { try JSONDecoder().decode(ProductScope.self, from: $0.data) }
            if vector["invalid"] == .bool(true) {
                #expect(throws: (any Error).self) { try SalesFileFormats.parse(text, accountId: accountId, appId: appId, importedAt: date, appSku: vector["appSku"]?.text, productScope: scope) }
            } else {
                let actual = try SalesFileFormats.parse(text, accountId: accountId, appId: appId, importedAt: date, appSku: vector["appSku"]?.text, productScope: scope)
                let expected = try JSONDecoder().decode([SalesRecord].self, from: vector["expected"]!.data)
                #expect(actual.map(\.json) == expected.map(\.json))
                #expect(SalesFileFormats.summary(actual) == vector["summary"]?.text)
                if let original = vector["original"]?.text {
                    #expect(String(decoding: try SalesFileFormats.original(actual[0], format: .originalCsv), as: UTF8.self) == original)
                }
            }
        }
    }

    @Test func gzipMembersTrailersAndUtf8MatchNode() throws {
        guard case .array(let cases)? = try golden()["codecs"] else { Issue.record("Missing synthetic gzip vectors"); return }
        for item in cases {
            let bytes = try #require(Data(base64Encoded: item["base64"]!.text!))
            if item["invalid"] == .bool(true) {
                #expect(throws: ReportFiles.Failure.format) { try ReportFiles.texts([bytes], purpose: .sales) }
            } else {
                let texts = try ReportFiles.texts([bytes], purpose: .sales)
                #expect(texts == [item["expected"]!.text!], "Synthetic gzip vector: \(item["id"]!.text!)")
            }
        }
        let text = "Synthetic Unicode 😀 and quotes \"\r\n"
        #expect(try ReportFiles.texts([ReportFiles.gzip(Data(text.utf8))], purpose: .sales) == [text])
    }

    @Test func sourceComparisonKeepsDuplicateTransactionsAndDetectsUnicodeAndCellChanges() throws {
        guard case .array(let pairs)? = try golden()["pairs"] else { Issue.record("Missing synthetic comparison vectors"); return }
        for pair in pairs {
            let before = try JSONDecoder().decode(SalesRecord.self, from: pair["before"]!.data), after = try JSONDecoder().decode(SalesRecord.self, from: pair["after"]!.data)
            #expect(JSONText.bool(SalesReports.same(before, after)) == pair["same"])
        }
        let text = String(decoding: try SalesReports.gunzip(SalesSyncTests.report([["APPLE", "SYNTHETIC", appId, "1F", "1", ".99", "02/10/2026", "02/10/2026", "US", ""], ["APPLE", "SYNTHETIC", appId, "1F", "1", ".99", "02/10/2026", "02/10/2026", "US", ""]])), as: UTF8.self)
        let records = try SalesFileFormats.parse(text, accountId: "synthetic-account", appId: appId, importedAt: "2026-03-01T12:00:00.000Z")
        #expect(records[0].source?.rows.count == 2 && records[0].unitsByTerritory == ["USA": 2])
    }

    @Test func compressedAndExpandedLimitsApplyToActualBytesAndTheWholeBatch() throws {
        #expect(throws: ReportFiles.Failure.size) { try ReportFiles.texts([Data(repeating: 65, count: 4_000_001)], purpose: .sales) }
        let bomb = try ReportFiles.gzip(Data(repeating: 65, count: 8_000_001))
        #expect(throws: ReportFiles.Failure.size) { try ReportFiles.texts([bomb], purpose: .sales) }
        let part = try ReportFiles.gzip(Data(repeating: 65, count: 5_000_001))
        #expect(throws: ReportFiles.Failure.size) { try ReportFiles.texts([part, part], purpose: .reports) }
        #expect(throws: ReportFiles.Failure.format) { try ReportFiles.texts([], purpose: .sales) }
        #expect(throws: ReportFiles.Failure.format) { try ReportFiles.texts([Data("x".utf8), Data("y".utf8)], purpose: .sales) }
        #expect(throws: ReportFiles.Failure.format) { try ReportFiles.texts(Array(repeating: Data("x".utf8), count: 21), purpose: .reports) }
    }

    @Test func fileReadsRejectLinksDevicesAndOversizedInputsInsideTheGuardedRun() async throws {
        let root = try TestIsolation.require().appendingPathComponent("synthetic-file-reader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("synthetic.txt"), link = root.appendingPathComponent("synthetic-link.txt"), fifo = root.appendingPathComponent("synthetic-pipe")
        try input().write(to: file); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file); #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(try await ReportFiles.readAsync([file], purpose: .sales).first == input())
        #expect(throws: ReportFiles.Failure.read) { try ReportFiles.read([link], purpose: .sales) }
        #expect(throws: ReportFiles.Failure.read) { try ReportFiles.read([fifo], purpose: .sales) }
        #expect(throws: ReportFiles.Failure.read) { try ReportFiles.read([root], purpose: .sales) }
        #expect(throws: TestIsolation.Failure.self) { try ReportFiles.read([root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("synthetic-outside.txt")], purpose: .sales) }
        try Data(repeating: 65, count: 4_000_001).write(to: file)
        #expect(throws: ReportFiles.Failure.size) { try ReportFiles.read([file], purpose: .sales) }
        let pending = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await ReportFiles.readAsync([file], purpose: .sales) }
        await #expect(throws: CancellationError.self) { try await pending.value }
    }

    @Test func summaryImportNeedsNoKeyAndPreservesSavedMonthsAndOtherAppHistories() async throws {
        let (session, root) = try SalesSyncTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try await account(session)
        let beforeOther = try await session.sales(accountId: account.id, appId: "1000000002")
        let changes = try await session.importSalesFile(account: account, appId: appId, data: input())
        #expect(changes.added == 1 && changes.updated == 0)
        let saved = try await records(session, account)
        #expect(saved.count == 4 && saved.last?.unitsByTerritory == ["USA": 3])
        #expect(try await session.sales(accountId: account.id, appId: "1000000002").map(\.id) == beforeOther.map(\.id))
        try await session.verifyBuckets(family: "sales", accountId: account.id, appId: appId)
        let repeated = try await session.importSalesFile(account: account, appId: appId, data: input())
        #expect(repeated.unchanged == 1 && repeated.added == 0 && repeated.updated == 0)
    }

    @Test func appleTxtGzipAndFullCsvRoundTripRetainOnlyOwnedRowsAndOriginalText() async throws {
        let (session, root) = try SalesSyncTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try await account(session), host = "sales-file-roundtrip.appstoreconnect.test"
        StubProtocol.handle(host) { request in
            #expect(request.httpMethod == "GET")
            if request.url!.path.hasSuffix("inAppPurchasesV2") { return (200, [:], Data(#"{"data":[{"type":"inAppPurchases","id":"2000000001"}],"links":{}}"#.utf8)) }
            return (200, [:], Data(#"{"data":[],"links":{}}"#.utf8))
        }
        let client = try SalesSyncTests().client(host, account: account)
        guard case .array(let vectors)? = try golden()["vectors"] else { return }
        let text = try #require(vectors.first { $0["id"] == .string("apple-txt") }?["text"]?.text)
        let original = Data(text.utf8)
        let first = try await session.importSalesFile(account: account, appId: appId, data: original, client: client)
        #expect(first.added == 1)
        let saved = try #require(try await records(session, account).last)
        #expect(saved.source?.rows.count == 3 && saved.unitsByTerritory == ["GBR": 2, "USA": 3])
        #expect(saved.productScope?.ids == ["2000000001"] && saved.productScope?.complete == true)
        for format in [SalesFileFormats.Format.originalCsv, .originalTxt, .originalGzip] {
            let bytes = try await session.exportSalesFile(account: account, appId: appId, beginDate: saved.beginDate, endDate: saved.endDate, format: format)
            let again = try await session.importSalesFile(account: account, appId: appId, data: bytes, client: client)
            #expect(again.unchanged == 1 && again.updated == 0)
        }
        let summary = try await session.exportSalesFile(account: account, appId: appId, beginDate: saved.beginDate, endDate: saved.endDate, format: .summary)
        let repeatSummary = try await session.importSalesFile(account: account, appId: appId, data: summary)
        #expect(repeatSummary.unchanged == 1)
        let after = try #require(try await records(session, account).last)
        #expect(after.source == saved.source && after.productScope == saved.productScope)
    }

    @Test func missingCatalogCannotReplacePreviouslyVerifiedChildProducts() async throws {
        let (session, root) = try SalesSyncTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try await account(session), host = "sales-file-catalog.appstoreconnect.test"
        StubProtocol.handle(host) { request in
            if request.url!.path.hasSuffix("inAppPurchasesV2") { return (200, [:], Data(#"{"data":[{"type":"inAppPurchases","id":"2000000001"}],"links":{}}"#.utf8)) }
            return (200, [:], Data(#"{"data":[],"links":{}}"#.utf8))
        }
        guard case .array(let vectors)? = try golden()["vectors"] else { return }
        let text = try #require(vectors.first { $0["id"] == .string("apple-txt") }?["text"]?.text)
        _ = try await session.importSalesFile(account: account, appId: appId, data: Data(text.utf8), client: SalesSyncTests().client(host, account: account))
        let before = try await records(session, account).map(\.json)
        await #expect(throws: SalesFailure.self) { try await session.importSalesFile(account: account, appId: appId, data: input("1000000001,2026-02-10,2026-02-10,USA,9")) }
        #expect(try await records(session, account).map(\.json) == before)
    }

    @Test func overlappingCrossMonthImportsAndForeignFilesLeaveAllReportsUntouched() async throws {
        let (session, root) = try SalesSyncTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try await account(session), before = try await records(session, account).map(\.json)
        await #expect(throws: SalesFailure.conflict) { try await session.importSalesFile(account: account, appId: appId, data: input("1000000001,2026-01-31,2026-02-02,USA,3")) }
        await #expect(throws: SalesFileFailure.scope) { try await session.importSalesFile(account: account, appId: appId, data: input("1000000099,2026-02-10,2026-02-10,USA,3")) }
        #expect(try await records(session, account).map(\.json) == before)
    }

    @Test func summaryZeroDoesNotInventAppleNoSalesOrOriginalRows() throws {
        let reports = try SalesFileFormats.parse(String(decoding: input("1000000001,2026-02-10,2026-02-10,,0"), as: UTF8.self), accountId: "synthetic-account", appId: appId, importedAt: "2026-03-01T12:00:00.000Z")
        #expect(reports.count == 1 && reports[0].noSales == nil && reports[0].source == nil)
        #expect(reports[0].json["noSales"] == nil)
        #expect(throws: SalesFileFailure.source) { try SalesFileFormats.original(reports[0], format: .originalTxt) }
    }

    @Test func fullCsvPreservesMultilineCellsWhileTxtAndGzipRefuseLossyExport() throws {
        guard case .array(let vectors)? = try golden()["vectors"] else { return }
        let vector = try #require(vectors.first { $0["id"] == .string("literal-multiline") })
        let reports = try JSONDecoder().decode([SalesRecord].self, from: vector["expected"]!.data)
        for format in [SalesFileFormats.Format.originalTxt, .originalGzip] {
            #expect(throws: SalesFileFailure.multiline) { try SalesFileFormats.original(reports[0], format: format) }
        }
        #expect(String(decoding: try SalesFileFormats.original(reports[0], format: .originalCsv), as: UTF8.self) == vector["original"]?.text)
    }

    @Test func removalOnlyDeletesTheChosenPeriodAndMissingPeriodsCannotDeleteAnything() async throws {
        let (session, root) = try SalesSyncTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try await account(session), oldAnalytics = try await session.analytics(accountId: account.id, appId: appId).map(\.key)
        let other = try await session.sales(accountId: account.id, appId: "1000000002").map(\.id)
        try await session.removeSalesFilePeriod(account: account, appId: appId, beginDate: "2026-01-31", endDate: "2026-01-31")
        let saved = try await records(session, account)
        #expect(saved.map(\.beginDate) == ["2026-01-30", "2026-02-01"])
        await #expect(throws: SalesFileFailure.missing) { try await session.removeSalesFilePeriod(account: account, appId: appId, beginDate: "2026-01-31", endDate: "2026-01-31") }
        #expect(try await session.sales(accountId: account.id, appId: "1000000002").map(\.id) == other)
        #expect(try await session.analytics(accountId: account.id, appId: appId).map(\.key) == oldAnalytics)
        try await session.verifyBuckets(family: "sales", accountId: account.id, appId: appId)
    }

    @Test func separateSessionsSerializeImportsWithoutLosingPeriodsOrChangingTheMutexInode() async throws {
        let (first, root) = try SalesSyncTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let vault = await first.vault
        let second = try WorkspaceSession(workspace: Workspace(root: root), vault: vault), account = try await account(first)
        let mutex = root.appendingPathComponent("state-v2/sales-\(JSONText.string("\(account.id)\u{0}\(appId)").rawSHA256.prefix(32)).mutex")
        try FileMutex.withLock(mutex) {}
        let inode = try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber
        async let one = first.importSalesFile(account: account, appId: appId, data: input())
        async let two = second.importSalesFile(account: account, appId: appId, data: input("1000000001,2026-02-11,2026-02-11,GBR,2"))
        let (a, b) = try await (one, two)
        #expect(a.added == 1 && b.added == 1)
        #expect(try await records(first, account).count == 5)
        #expect(try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber == inode)
        try await first.verifyBuckets(family: "sales", accountId: account.id, appId: appId)
    }

    @Test func catalogueRequestsReleaseAllReportLocksAndLateAppRemovalStopsTheSave() async throws {
        let (session, root) = try SalesSyncTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try await account(session), host = "sales-file-late-scope.appstoreconnect.test"
        let mutex = root.appendingPathComponent("state-v2/sales-\(JSONText.string("\(account.id)\u{0}\(appId)").rawSHA256.prefix(32)).mutex")
        StubProtocol.handle(host) { _ in
            let available = try! FileMutex.tryLock(mutex); #expect(available != nil); available?.release()
            let store = try! EncryptedDocumentStore(url: EncryptedDocumentStore.databaseURL(root: root), key: Data(0..<32), writable: true)
            let changed = Account(id: account.id, name: account.name, keyId: account.keyId, keyType: account.keyType, issuerId: account.issuerId, appIds: [], appNames: nil)
            try! store.transaction { _ in [.put(namespace: "accounts", key: "all", json: JSONText.array([WorkspaceSession.json(changed)]).data)] }
            return (200, [:], Data(#"{"data":[],"links":{}}"#.utf8))
        }
        let before = try await session.sales(accountId: account.id, appId: appId).map(\.id)
        let data = SalesSyncTests.report([["APPLE", "SYNTHETIC", appId, "1F", "3", ".99", "02/10/2026", "02/10/2026", "US", ""]])
        await #expect(throws: SalesFileFailure.scope) { try await session.importSalesFile(account: account, appId: appId, data: data, client: SalesSyncTests().client(host, account: account)) }
        #expect(try await session.sales(accountId: account.id, appId: appId).map(\.id) == before)
    }

    @Test func cancelledImportsDoNotChangeTheHistory() async throws {
        let (session, root) = try SalesSyncTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try await account(session), before = try await records(session, account).map(\.json)
        let pending = Task { try await session.importSalesFile(account: account, appId: appId, data: input()) }; pending.cancel()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(try await records(session, account).map(\.json) == before)
    }

    @Test func exportsAndDeletesRejectForeignAppsAndMalformedSelections() async throws {
        let (session, root) = try SalesSyncTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try await account(session)
        await #expect(throws: SalesFileFailure.scope) { try await session.exportSalesFile(account: account, appId: "1000000099", format: .summary) }
        await #expect(throws: SalesFileFailure.scope) { try await session.removeSalesFilePeriod(account: account, appId: "1000000099", beginDate: "2026-01-31", endDate: "2026-01-31") }
        await #expect(throws: SalesFileFailure.missing) { try await session.exportSalesFile(account: account, appId: appId, beginDate: "2026-02-10", endDate: "2026-02-10", format: .summary) }
        await #expect(throws: SalesFileFailure.source) { try await session.exportSalesFile(account: account, appId: appId, format: .originalGzip) }
    }
}

@Suite struct SalesFileProcessTests {
    init() throws { _ = try TestIsolation.require() }
    @Test func manualImportWaitsForTheOwnedReportProcessAndRecoversWithoutReplacingItsMutex() async throws {
        let root = try TestIsolation.require().appendingPathComponent("sales-lock-policy")
        let (session, _) = try DraftTests().session(directory: root), appId = "1000000001"
        let account = try #require(try await session.accounts().first)
        let mutex = root.appendingPathComponent("state-v2/sales-\(JSONText.string("\(account.id)\u{0}\(appId)").rawSHA256.prefix(32)).mutex")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("lock-ready").path))
        #expect(try FileMutex.tryLock(mutex) == nil)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: mutex.path)
        let attributes = try FileManager.default.attributesOfItem(atPath: mutex.path), inode = try #require(attributes[.systemFileNumber] as? NSNumber)
        let reader = try EncryptedDocumentStore(url: EncryptedDocumentStore.databaseURL(root: root), key: Data(0..<32))
        let before = try PartitionedReports.items(SalesRecord.self, family: "sales", legacyKey: "reports", accountId: account.id, appId: appId, store: reader).map(\.json)
        let data = try SalesFileTests().input()
        let pending = Task { try await session.importSalesFile(account: account, appId: appId, data: data) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(try PartitionedReports.items(SalesRecord.self, family: "sales", legacyKey: "reports", accountId: account.id, appId: appId, store: reader).map(\.json) == before)
        try JobLock.exclusive(root.appendingPathComponent("lock-release"), "interrupt")
        let changes = try await pending.value
        #expect(changes.added == 1)
        #expect(try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber == inode)
        try await session.verifyBuckets(family: "sales", accountId: account.id, appId: appId)
    }
}
