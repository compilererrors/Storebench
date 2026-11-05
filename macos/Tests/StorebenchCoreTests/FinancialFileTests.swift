import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct FinancialFileTests {
    init() throws { _ = try TestIsolation.require() }
    let appId = "1000000001"
    let now = Date(timeIntervalSince1970: 1_772_366_400)
    func golden() throws -> JSONText { try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/financial-file-formats.json"))) }
    func vector(_ id: String) throws -> JSONText {
        guard case .array(let vectors)? = try golden()["vectors"], let value = vectors.first(where: { $0["id"] == .string(id) }) else { throw FinanceFailure.format }
        return value
    }
    func input(_ id: String = "apple-csv") throws -> FinancialFileInput { try input(vector(id)) }
    func input(_ value: JSONText) throws -> FinancialFileInput {
        guard case .array(let files)? = value["files"] else { throw FinanceFailure.format }
        let regions: [String]; if case .array(let raw)? = value["regions"] { regions = raw.compactMap(\.text) } else { regions = [] }
        return FinancialFileInput(files: files.map { Data($0.text!.utf8) }, regions: regions, complete: value["complete"] == .bool(true))
    }
    func reports(_ session: WorkspaceSession, _ account: Account) async throws -> [FinancialReport] { try await session.savedFinancialFiles(account: account, appId: appId).reports }
    func history(_ reports: [FinancialReport], accountId: String = "synthetic-account") -> FinancialFileInput {
        FinancialFileInput(files: [FinancialFileFormats.history(accountId: accountId, appId: appId, reports: reports).data])
    }

    @Test func fileFormatsFingerprintsAndSourceExportsMatchTheWeb() throws {
        let value = try golden(), stamp = now
        #expect(CustomerReview.isoString(stamp) == value["importedAt"]?.text)
        guard case .array(let vectors)? = value["vectors"] else { Issue.record("Missing synthetic financial vectors"); return }
        #expect(vectors.count >= 45)
        for vector in vectors {
            let label = vector["id"]!.text!
            if vector["invalid"] == .bool(true) {
                #expect(throws: (any Error).self) { try FinancialFileFormats.parse(input(vector), accountId: "synthetic-account", appId: appId, now: stamp) }
            } else {
                let actual = try FinancialFileFormats.parse(input(vector), accountId: "synthetic-account", appId: appId, now: stamp)
                let expected = try JSONDecoder().decode([FinancialReport].self, from: vector["expected"]!.data)
                #expect(JSONText.array(actual.reports.map(\.json)).stringify().utf8.elementsEqual(JSONText.array(expected.map(\.json)).stringify().utf8), "Synthetic financial vector: \(label)")
                #expect(actual.importId == vector["importId"]?.text && actual.noAppFiles == Int(vector["noAppFiles"]!.stringify()), "Synthetic financial fingerprint: \(label)")
                guard case .array(let exports)? = vector["exports"] else { throw FinanceFailure.format }
                for (report, expectedExport) in zip(actual.reports, exports) {
                    #expect(try FinancialFileFormats.source(report, format: .sourceCsv).elementsEqual(Data(expectedExport["csv"]!.text!.utf8)), "Synthetic CSV: \(label)")
                    #expect(FinancialReports.summary(report) == expectedExport["summary"]?.text)
                    if let text = expectedExport["txt"]?.text {
                        #expect(try FinancialFileFormats.source(report, format: .sourceTxt).elementsEqual(Data(text.utf8)))
                        #expect(try ReportFiles.texts([FinancialFileFormats.source(report, format: .sourceGzip)], purpose: .reports) == [text])
                    } else {
                        #expect(throws: ReportTables.ExportFailure.multiline) { try FinancialFileFormats.source(report, format: .sourceTxt) }
                        #expect(throws: ReportTables.ExportFailure.multiline) { try FinancialFileFormats.source(report, format: .sourceGzip) }
                    }
                }
            }
        }
    }

    @Test func storedIsoAndRfcTimestampsMatchWebDateValidation() throws {
        guard case .array(let vectors)? = try golden()["timestamps"] else { Issue.record("Missing synthetic timestamp vectors"); return }
        #expect(vectors.count >= 18)
        for vector in vectors { #expect(ReportTimestamps.valid(vector["value"]!.text!) == (vector["valid"] == .bool(true)), "Synthetic timestamp: \(vector["value"]!.text!)") }
    }

    @Test func previewChangesNoReportDocumentsAndSavingNeedsNoCredentialsOrConnection() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), files = try input()
        let review = try await session.previewFinancialFiles(account: account, appId: appId, input: files, now: now)
        #expect(review.changes.map(\.action) == ["added"])
        #expect(try await reports(session, account).isEmpty)
        let index = try await session.storeAccess { try $0.document(namespace: "financial_index", key: "\(account.id):\(appId)") }
        #expect(index == nil)
        let changes = try await session.saveFinancialFiles(review, input: files, now: now)
        #expect(changes.map(\.action) == ["added"])
        #expect(try await reports(session, account).first?.source.rows.count == 2)
        try await session.verifyBuckets(family: "financial", accountId: account.id, appId: appId)
    }

    @Test func changedFilesAndRegionChoicesCannotReuseAnEarlierReview() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), files = try input()
        let review = try await session.previewFinancialFiles(account: account, appId: appId, input: files, now: now)
        await #expect(throws: FinancialFileFailure.changedFiles) { try await session.saveFinancialFiles(review, input: input("rounded-amount"), now: now) }
        await #expect(throws: FinancialFileFailure.changedFiles) { try await session.saveFinancialFiles(review, input: FinancialFileInput(files: files.files, regions: ["US"], complete: true), now: now) }
        await #expect(throws: FinancialFileFailure.metadata) { try await session.saveFinancialFiles(review, input: FinancialFileInput(files: files.files, regions: ["ALL"]), now: now) }
        #expect(try await reports(session, account).isEmpty)
    }

    @Test func importTimestampAndFileOrderingDoNotInventContentChanges() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), files = try input("history-json")
        let review = try await session.previewFinancialFiles(account: account, appId: appId, input: files, now: now)
        _ = try await session.saveFinancialFiles(review, input: files, now: now)
        let before = try await reports(session, account).map(\.json)
        let again = try await session.previewFinancialFiles(account: account, appId: appId, input: input("reordered-history-source"), now: now.addingTimeInterval(3600))
        #expect(again.importId == review.importId && again.changes.map(\.action) == ["unchanged"])
        _ = try await session.saveFinancialFiles(again, input: files, now: now.addingTimeInterval(7200))
        #expect(try await reports(session, account).map(\.json) == before)
    }

    @Test func multiselectSkipsOnlyFilesWithoutOwnedRowsAndKeepsSummaryAndDetailSeparate() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), files = try input("skip-foreign-file")
        let review = try await session.previewFinancialFiles(account: account, appId: appId, input: files, now: now)
        #expect(review.noAppFiles == 1 && review.reports.count == 1)
        _ = try await session.saveFinancialFiles(review, input: files, now: now)
        let detail = try input("detailed"), next = try await session.previewFinancialFiles(account: account, appId: appId, input: detail, now: now)
        _ = try await session.saveFinancialFiles(next, input: detail, now: now)
        #expect(Set(try await reports(session, account).map(\.basis)) == ["consolidated", "detailed"])
        let before = try await reports(session, account).map(\.json)
        await #expect(throws: FinanceFailure.format) { try await session.previewFinancialFiles(account: account, appId: appId, input: input("bad-foreign-dates"), now: now) }
        #expect(try await reports(session, account).map(\.json) == before)
    }

    @Test func staleReviewsAndStaleDeletionBaselinesPreserveTheLatestSave() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), files = try input()
        let old = try await session.previewFinancialFiles(account: account, appId: appId, input: files, now: now)
        let latest = try await session.previewFinancialFiles(account: account, appId: appId, input: files, now: now)
        _ = try await session.saveFinancialFiles(latest, input: files, now: now)
        let saved = try await session.savedFinancialFiles(account: account, appId: appId)
        await #expect(throws: FinanceFailure.stale) { try await session.saveFinancialFiles(old, input: files, now: now) }
        let changed = try input("rounded-amount"), revised = try await session.previewFinancialFiles(account: account, appId: appId, input: changed, now: now)
        _ = try await session.saveFinancialFiles(revised, input: changed, now: now)
        await #expect(throws: FinanceFailure.stale) { try await session.removeFinancialFilePeriod(saved, key: saved.reports[0].key) }
        #expect(try await reports(session, account).map(\.json) == revised.reports.map(\.json))
    }

    @Test func concurrentSessionsCannotBothSaveTheSameReviewBaseline() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let second = try WorkspaceSession(workspace: Workspace(root: root), vault: await session.vault)
        let account = try #require(try await session.accounts().first), files = try input()
        let firstReview = try await session.previewFinancialFiles(account: account, appId: appId, input: files, now: now)
        let secondReview = try await second.previewFinancialFiles(account: account, appId: appId, input: files, now: now)
        let results = await withTaskGroup(of: Bool.self) { group in
            group.addTask { do { _ = try await session.saveFinancialFiles(firstReview, input: files, now: now); return true } catch { #expect(error as? FinanceFailure == .stale); return false } }
            group.addTask { do { _ = try await second.saveFinancialFiles(secondReview, input: files, now: now); return true } catch { #expect(error as? FinanceFailure == .stale); return false } }
            var values: [Bool] = []; for await value in group { values.append(value) }; return values
        }
        #expect(results.filter { $0 }.count == 1 && results.filter { !$0 }.count == 1)
        #expect(try await reports(session, account).count == 1)
        try await session.verifyBuckets(family: "financial", accountId: account.id, appId: appId)
    }

    @Test func overlapAcrossYearPartitionsIsRejectedWithoutChangingTheSavedIndex() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), files = try input()
        let review = try await session.previewFinancialFiles(account: account, appId: appId, input: files, now: now)
        _ = try await session.saveFinancialFiles(review, input: files, now: now)
        let before = try await reports(session, account), source = before[0].source
        let changedRows = source.rows.map { cells in source.columns.enumerated().map { index, name in name == "Start Date" ? "01/01/2026" : name == "End Date" ? "01/15/2026" : cells[index] } }
        let record = try FinancialReports.fromTable(ReportTable(columns: source.columns, rows: changedRows), scope: "ZZ", appId: appId, importedAt: before[0].importedAt)
        await #expect(throws: FinanceFailure.overlap) { try await session.previewFinancialFiles(account: account, appId: appId, input: history([record]), now: now) }
        #expect(try await reports(session, account).map(\.json) == before.map(\.json))
        try await session.verifyBuckets(family: "financial", accountId: account.id, appId: appId)
    }

    @Test func exportsRestoreAllDatasetsAndDeletingOnePeriodKeepsOtherFeatures() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), files = try input("summary-and-detail")
        let salesBefore = try await session.salesFileRecords(account: account, appId: appId).map(\.json)
        let review = try await session.previewFinancialFiles(account: account, appId: appId, input: files, now: now)
        _ = try await session.saveFinancialFiles(review, input: files, now: now)
        let saved = try await session.savedFinancialFiles(account: account, appId: appId)
        let exported = try await session.exportFinancialFile(account: account, appId: appId, key: saved.reports[0].key, format: .historyJson)
        #expect(try FinancialFileFormats.parse(FinancialFileInput(files: [exported]), accountId: account.id, appId: appId, now: now).reports.count == 2)
        let summary = try #require(saved.reports.first { $0.region == "ZZ" })
        for format in [FinancialFileFormats.Format.sourceCsv, .sourceTxt, .sourceGzip] {
            let bytes = try await session.exportFinancialFile(account: account, appId: appId, key: summary.key, format: format)
            let restored = try FinancialFileFormats.parse(FinancialFileInput(files: [bytes], regions: ["ALL"], complete: true), accountId: account.id, appId: appId, now: now)
            #expect(ReportTables.literalEqual(restored.reports[0].source, summary.source))
        }
        try await session.removeFinancialFilePeriod(saved, key: summary.key)
        #expect(try await reports(session, account).map(\.region) == ["Z1"])
        #expect(try await session.salesFileRecords(account: account, appId: appId).map(\.json) == salesBefore)
        await #expect(throws: FinancialFileFailure.missing) { try await session.exportFinancialFile(account: account, appId: appId, key: summary.key, format: .sourceCsv) }
        let last = try await session.savedFinancialFiles(account: account, appId: appId)
        try await session.removeFinancialFilePeriod(last, key: last.reports[0].key)
        #expect(try await reports(session, account).isEmpty)
        await #expect(throws: FinancialFileFailure.missing) { try await session.exportFinancialFile(account: account, appId: appId, format: .historyJson) }
        try await session.verifyBuckets(family: "financial", accountId: account.id, appId: appId)
    }

    @Test func cancellationAndChangedAccountMembershipCannotSaveAnOldReview() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), files = try input()
        let review = try await session.previewFinancialFiles(account: account, appId: appId, input: files, now: now)
        let pending = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await session.saveFinancialFiles(review, input: files, now: now) }
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(try await reports(session, account).isEmpty)
        try await session.storeAccess { store in
            let accounts = try #require(try store.document(namespace: "accounts", key: "all")), value = try JSONText.parse(accounts.payload)
            guard case .array(let array) = value, case .object(let fields) = array[0] else { throw FinanceFailure.format }
            let updated = JSONText.array([.object(fields.map { ($0.0, $0.0 == "appIds" ? .array([.string("1000000002")]) : $0.1) })])
            try store.transaction { _ in [.put(namespace: "accounts", key: "all", json: updated.data)] }
        }
        await #expect(throws: FinanceFailure.scope) { try await session.saveFinancialFiles(review, input: files, now: now) }
        await #expect(throws: FinanceFailure.scope) { try await session.exportFinancialFile(account: account, appId: appId, format: .historyJson) }
        #expect(try await session.financialReports(accountId: account.id, appId: appId).isEmpty)
    }

    @Test func corruptLegacyOwnershipAndSourceDataFailClosedBeforeReplacingOrExporting() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), incoming = try FinancialFileFormats.parse(input(), accountId: account.id, appId: appId, now: now)
        let foreign = FinancialFileFormats.history(accountId: "other-synthetic-account", appId: appId, reports: incoming.reports)
        try await session.storeAccess { store in try store.transaction { _ in [.put(namespace: "financial", key: "\(account.id):\(appId)", json: foreign.data)] } }
        await #expect(throws: FinancialFileFailure.storage) { try await session.savedFinancialFiles(account: account, appId: appId) }
        await #expect(throws: FinancialFileFailure.storage) { try await session.previewFinancialFiles(account: account, appId: appId, input: input(), now: now) }
        await #expect(throws: FinancialFileFailure.storage) { try await session.exportFinancialFile(account: account, appId: appId, format: .historyJson) }
        let bad = FinancialReport(beginDate: "2025-12-29", endDate: "2026-01-31", region: "ZZ", basis: "consolidated", importedAt: "2026-03-01T12:00:00.000Z", source: ReportTable(columns: ["Synthetic"], rows: [["Synthetic"]]))
        try await session.storeAccess { store in try store.transaction { _ in [.put(namespace: "financial", key: "\(account.id):\(appId)", json: FinancialFileFormats.history(accountId: account.id, appId: appId, reports: [bad]).data)] } }
        await #expect(throws: FinancialFileFailure.storage) { try await session.financialReports(accountId: account.id, appId: appId) }
        let index = try await session.storeAccess { try $0.document(namespace: "financial_index", key: "\(account.id):\(appId)") }
        #expect(index == nil)
    }

    @Test func aggregateUnitsAreBoundedAcrossTheWholeFinancialHistory() throws {
        let columns = FinanceSyncTests.columns + ["Title"]
        func report(_ begin: String, _ end: String) throws -> FinancialReport {
            let rows = (0..<5_000).map { [begin, end, "999999999999", "0", "0", "USD", "S", appId, "1F", "US", "0", "USD", "Synthetic large total \($0)"] }
            return try FinancialReports.fromTable(ReportTable(columns: columns, rows: rows), scope: "ZZ", appId: appId, importedAt: "2026-03-01T12:00:00.000Z")
        }
        let first = try report("01/01/2026", "01/31/2026"), second = try report("02/01/2026", "02/28/2026")
        #expect(try FinancialFileFormats.normalize([first], appId: appId).count == 1)
        #expect(throws: FinanceFailure.format) { try FinancialFileFormats.normalize([first, second], appId: appId) }
    }
}

@Suite struct FinancialFileProcessTests {
    init() throws { _ = try TestIsolation.require() }
    @Test func saveRechecksAppOwnershipAfterTheOwnedProcessExitsAndPreservesThePermanentMutex() async throws {
        let root = try TestIsolation.require().appendingPathComponent("financial-lock-policy")
        let (session, _) = try DraftTests().session(directory: root), fixture = try FinancialFileTests(), appId = fixture.appId
        let account = try #require(try await session.accounts().first), files = try fixture.input()
        let mutex = root.appendingPathComponent("state-v2/financial-\(JSONText.string("\(account.id)\u{0}\(appId)").rawSHA256.prefix(32)).mutex")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("lock-ready").path))
        #expect(try FileMutex.tryLock(mutex) == nil)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: mutex.path)
        let inode = try #require(try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber)
        let reader = try EncryptedDocumentStore(url: EncryptedDocumentStore.databaseURL(root: root), key: Data(0..<32), writable: true)
        let baseline = try PartitionedReports.revision(family: "financial", accountId: account.id, appId: appId, store: reader)
        let incoming = try FinancialFileFormats.parse(files, accountId: account.id, appId: appId, now: fixture.now)
        let changes = try FinancialReports.merge([], incoming.reports).changes
        let review = FinancialFileReview(reports: incoming.reports, changes: changes, noAppFiles: incoming.noAppFiles, importId: incoming.importId, account: account, appId: appId, revision: baseline)
        let pending = Task { try await session.saveFinancialFiles(review, input: files, now: fixture.now) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(try reader.document(namespace: "financial_index", key: "\(account.id):\(appId)") == nil)
        let accountDocument = try #require(try reader.document(namespace: "accounts", key: "all"))
        let removed = Account(id: account.id, name: account.name, keyId: account.keyId, keyType: account.keyType, issuerId: account.issuerId, appIds: [], appNames: nil)
        try reader.transaction { _ in [.put(namespace: "accounts", key: "all", json: JSONText.array([WorkspaceSession.json(removed)]).data)] }
        try JobLock.exclusive(root.appendingPathComponent("lock-release"), "interrupt")
        await #expect(throws: FinanceFailure.scope) { try await pending.value }
        #expect(try reader.document(namespace: "financial_index", key: "\(account.id):\(appId)") == nil)
        try reader.transaction { _ in [.put(namespace: "accounts", key: "all", json: accountDocument.payload)] }
        #expect(try await session.saveFinancialFiles(review, input: files, now: fixture.now).map(\.action) == ["added"])
        #expect(try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber == inode)
        try await session.verifyBuckets(family: "financial", accountId: account.id, appId: appId)
    }
}
