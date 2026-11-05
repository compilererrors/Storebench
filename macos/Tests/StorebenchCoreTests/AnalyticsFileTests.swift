import CryptoKit
import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct AnalyticsFileTests {
    init() throws { _ = try TestIsolation.require() }
    let appId = "1000000001", now = Date(timeIntervalSince1970: 1_772_366_400)
    func golden() throws -> JSONText { try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/analytics-file-formats.json"))) }
    func vector(_ id: String) throws -> JSONText {
        guard case .array(let values)? = try golden()["vectors"], let value = values.first(where: { $0["id"] == .string(id) }) else { throw AnalyticsFailure.format }; return value
    }
    func input(_ id: String = "apple-csv") throws -> AnalyticsFileInput { try input(vector(id)) }
    func input(_ value: JSONText) throws -> AnalyticsFileInput {
        guard case .array(let files)? = value["files"] else { throw AnalyticsFailure.format }
        let meta = try value["metadata"].map { try AnalyticsMetadata(kind: $0["kind"]!.text!, level: $0["level"]!.text!, granularity: $0["granularity"]!.text!, processingDate: $0["processingDate"]!.text!) }
        return AnalyticsFileInput(files: files.map { Data($0.text!.utf8) }, metadata: meta, segments: Int(value["segments"]?.stringify() ?? "1")!, complete: value["complete"] == .bool(true))
    }
    func session(directory: URL? = nil) async throws -> (WorkspaceSession, URL) {
        let (session, root) = try DraftTests().session(directory: directory)
        try await session.storeAccess { store in
            for namespace in ["analytics", "analytics_index", "analytics_part", "analytics_view"] {
                for document in try store.documents(namespace: namespace) { try store.delete(namespace: namespace, key: document.key) }
            }
        }
        return (session, root)
    }
    func partitions(_ session: WorkspaceSession, _ account: Account) async throws -> [AnalyticsPartition] { try await session.savedAnalyticsFiles(account: account, appId: appId).partitions }
    func history(_ partitions: [AnalyticsPartition]) -> AnalyticsFileInput { AnalyticsFileInput(files: [AnalyticsFileFormats.history(accountId: "synthetic-account", appId: appId, partitions: partitions).data]) }
    func changeJSON(_ value: AnalyticsFileFormats.Change) -> JSONText {
        var fields: [(String, JSONText)] = [("key", .string(value.key)), ("date", .string(value.date)), ("action", .string(value.action)), ("beforeRows", .number(Double(value.beforeRows))), ("afterRows", .number(Double(value.afterRows)))]
        if let before = value.beforeProcessingDate { fields.append(("beforeProcessingDate", .string(before))) }
        fields += [("processingDate", .string(value.processingDate)), ("beforeActivity", .string(value.beforeActivity)), ("afterActivity", .string(value.afterActivity))]
        return .object(fields)
    }

    @Test func fileValidationFingerprintsFactsAndOriginalExportsMatchWebVectors() throws {
        let value = try golden(), base = try AnalyticsFileFormats.parse(input(), accountId: "synthetic-account", appId: appId, now: now)
        #expect(CustomerReview.isoString(now) == value["importedAt"]?.text)
        guard case .array(let vectors)? = value["vectors"] else { throw AnalyticsFailure.format }
        #expect(vectors.count > 300)
        for vector in vectors {
            let label = vector["id"]!.text!
            if vector["invalid"] == .bool(true) {
                #expect(throws: (any Error).self, "Synthetic Analytics vector: \(label)") { try AnalyticsFileFormats.parse(input(vector), accountId: "synthetic-account", appId: appId, now: now) }
            } else {
                let incoming = try AnalyticsFileFormats.parse(input(vector), accountId: "synthetic-account", appId: appId, now: now)
                #expect(JSONText.array(incoming.partitions.map(\.json)).data == vector["expected"]!.data, "Synthetic Analytics source: \(label)")
                #expect(incoming.importId == vector["importId"]?.text, "Synthetic Analytics fingerprint: \(label)")
                #expect(try AnalyticsReports.view(incoming.partitions).data == vector["view"]!.data, "Synthetic Analytics facts: \(label)")
                let review = try AnalyticsFileFormats.review(base.partitions, incoming.partitions)
                #expect(JSONText.array(review.changes.map(changeJSON)).data == vector["changes"]!.data, "Synthetic Analytics review: \(label)")
                guard case .array(let exports)? = vector["exports"] else { throw AnalyticsFailure.format }
                for (item, exported) in zip(incoming.partitions, exports) {
                    #expect(try AnalyticsFileFormats.source(item, format: .sourceCsv) == Data(exported["csv"]!.text!.utf8))
                    if let text = exported["txt"]?.text {
                        #expect(try AnalyticsFileFormats.source(item, format: .sourceTxt) == Data(text.utf8))
                        #expect(try ReportFiles.texts([AnalyticsFileFormats.source(item, format: .sourceGzip)], purpose: .reports) == [text])
                    } else { #expect(throws: ReportTables.ExportFailure.multiline) { try AnalyticsFileFormats.source(item, format: .sourceGzip) } }
                }
            }
        }
    }

    @Test func previewIsReadOnlyAndSaveNeedsNoAppleCredential() async throws {
        let (session, root) = try await session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), files = try input()
        let review = try await session.previewAnalyticsFiles(account: account, appId: appId, input: files, now: now)
        #expect(review.changes.map(\.action) == ["added"] && review.partitions[0].source.rows.count == 5)
        #expect(try await partitions(session, account).isEmpty)
        let index = try await session.storeAccess { try $0.document(namespace: "analytics_index", key: "\(account.id):\(appId)") }
        #expect(index == nil)
        #expect(try await session.saveAnalyticsFiles(review, input: files, now: now).map(\.action) == ["added"])
        #expect(try await session.analytics(accountId: account.id, appId: appId).first?.total("first") == 60)
        try await session.verifyBuckets(family: "analytics", accountId: account.id, appId: appId)
    }

    @Test func combinedAnalyticsSourceAboveGenericRowLimitExportsEveryOriginalRow() throws {
        let expected = try #require(try golden()["largeExport"])
        let rawColumns = try #require(expected["columns"]), rawRow = try #require(expected["row"])
        let columns = try JSONDecoder().decode([String].self, from: rawColumns.data)
        let base = try JSONDecoder().decode([String].self, from: rawRow.data)
        let nameColumn = try #require(columns.firstIndex(of: "App Name")), countColumn = try #require(columns.firstIndex(of: "Counts"))
        let rows = (0..<100_001).map { index in
            var row = base; row[nameColumn] = "Synthetic large row \(index)"; row[countColumn] = "1"; return row
        }
        let segments = [ReportTable(columns: columns, rows: Array(rows.prefix(50_000))), ReportTable(columns: columns, rows: Array(rows.dropFirst(50_000)))]
        let metadata = try AnalyticsMetadata(kind: "downloads", level: "standard", granularity: "DAILY", processingDate: "2026-02-11")
        let partition = try #require(try AnalyticsReports.importSegments(segments, meta: metadata, accountId: "synthetic-account", appId: appId, importedAt: "2026-03-01T12:00:00.000Z").first)
        #expect(partition.source.rows.count == 100_001 && partition.segments == 2)
        #expect(expected["rows"] == .number(100_001))
        #expect(throws: AnalyticsFailure.format) { try ReportTables.text(partition.source, format: .csv) }
        let csv = try AnalyticsFileFormats.source(partition, format: .sourceCsv), txt = try AnalyticsFileFormats.source(partition, format: .sourceTxt)
        #expect(SHA256.hash(data: csv).map { String(format: "%02x", $0) }.joined() == expected["csvSha256"]?.text)
        #expect(SHA256.hash(data: txt).map { String(format: "%02x", $0) }.joined() == expected["txtSha256"]?.text)
        #expect(txt.filter { $0 == 10 }.count == 100_002)
        let gzip = try AnalyticsFileFormats.source(partition, format: .sourceGzip)
        #expect(try ReportFiles.unpack(gzip, limit: 32_000_000) == txt)
        var invalidRow = base; invalidRow[countColumn] = "1.5"
        let invalid = AnalyticsPartition(kind: partition.kind, level: partition.level, granularity: partition.granularity, processingDate: partition.processingDate, date: partition.date, importedAt: partition.importedAt, segments: 2, source: ReportTable(columns: columns, rows: [invalidRow]))
        #expect(throws: AnalyticsFailure.format) { try AnalyticsFileFormats.source(invalid, format: .sourceCsv) }
    }

    @Test func changedBytesMetadataAndIncompleteSegmentsCannotReuseReview() async throws {
        let (session, root) = try await session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), files = try input(), review = try await session.previewAnalyticsFiles(account: account, appId: appId, input: files, now: now)
        await #expect(throws: AnalyticsFileFailure.changedFiles) { try await session.saveAnalyticsFiles(review, input: input("changed-count"), now: now) }
        let meta = try AnalyticsMetadata(kind: "downloads", level: "standard", granularity: "DAILY", processingDate: "2026-02-12")
        await #expect(throws: AnalyticsFileFailure.changedFiles) { try await session.saveAnalyticsFiles(review, input: AnalyticsFileInput(files: files.files, metadata: meta, complete: true), now: now) }
        await #expect(throws: AnalyticsFailure.segments) { try await session.saveAnalyticsFiles(review, input: AnalyticsFileInput(files: files.files, metadata: files.metadata), now: now) }
        #expect(try await partitions(session, account).isEmpty)
    }

    @Test func olderReportsAndLaterImportTimestampsRetainExactSavedSource() async throws {
        let (session, root) = try await session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), files = try input()
        let review = try await session.previewAnalyticsFiles(account: account, appId: appId, input: files, now: now)
        _ = try await session.saveAnalyticsFiles(review, input: files, now: now)
        let before = try await partitions(session, account).map(\.json)
        let beforeViews = try await session.storeAccess { try $0.documents(namespace: "analytics_view", prefix: "\(account.id):\(appId):") }
        let again = try await session.previewAnalyticsFiles(account: account, appId: appId, input: input("reordered-history"), now: now.addingTimeInterval(3600))
        #expect(again.importId == review.importId && again.changes.map(\.action) == ["unchanged"])
        _ = try await session.saveAnalyticsFiles(again, input: files, now: now.addingTimeInterval(7200))
        let meta = try AnalyticsMetadata(kind: "downloads", level: "standard", granularity: "DAILY", processingDate: "2026-02-10")
        let older = AnalyticsFileInput(files: files.files, metadata: meta, complete: true)
        let oldReview = try await session.previewAnalyticsFiles(account: account, appId: appId, input: older, now: now)
        #expect(oldReview.changes.map(\.action) == ["older"] && oldReview.changes[0].beforeActivity == oldReview.changes[0].afterActivity)
        _ = try await session.saveAnalyticsFiles(oldReview, input: older, now: now)
        #expect(try await partitions(session, account).map(\.json) == before)
        #expect(try await session.storeAccess { try $0.documents(namespace: "analytics_view", prefix: "\(account.id):\(appId):") } == beforeViews)
    }

    @Test func independentBasesExportAndExactRemovalKeepOtherFeatures() async throws {
        let (session, root) = try await session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), salesBefore = try await session.salesFileRecords(account: account, appId: appId).map(\.json)
        for id in ["apple-csv", "detailed", "engagement", "weekly", "monthly"] {
            let files = try input(id), review = try await session.previewAnalyticsFiles(account: account, appId: appId, input: files, now: now)
            _ = try await session.saveAnalyticsFiles(review, input: files, now: now)
        }
        let saved = try await session.savedAnalyticsFiles(account: account, appId: appId), target = root.appendingPathComponent("synthetic-export.json")
        #expect(saved.partitions.count == 5)
        try await session.writeAnalyticsFile(account: account, appId: appId, format: .historyJson, to: target)
        let restored = try AnalyticsFileFormats.parse(AnalyticsFileInput(files: [Data(contentsOf: target)]), accountId: account.id, appId: appId, now: now)
        #expect(restored.partitions.map(\.key) == saved.partitions.map(\.key))
        let selected = saved.partitions[0], meta = try AnalyticsMetadata(kind: selected.kind, level: selected.level, granularity: selected.granularity, processingDate: selected.processingDate)
        for format in [AnalyticsFileFormats.Format.sourceCsv, .sourceTxt, .sourceGzip] {
            try await session.writeAnalyticsFile(account: account, appId: appId, key: selected.key, format: format, to: target)
            let parsed = try AnalyticsFileFormats.parse(AnalyticsFileInput(files: [Data(contentsOf: target)], metadata: meta, complete: true), accountId: account.id, appId: appId, now: now)
            #expect(ReportTables.literalEqual(parsed.partitions[0].source, selected.source))
        }
        try await session.removeAnalyticsFilePeriod(saved, key: selected.key)
        #expect(try await partitions(session, account).count == 4)
        await #expect(throws: AnalyticsFileFailure.missing) { try await session.writeAnalyticsFile(account: account, appId: appId, key: selected.key, format: .sourceCsv, to: target) }
        #expect(try await session.salesFileRecords(account: account, appId: appId).map(\.json) == salesBefore)
        try await session.verifyBuckets(family: "analytics", accountId: account.id, appId: appId)
    }

    @Test func concurrentSessionsAndStaleDeletionCannotOverwriteNewerSave() async throws {
        let (session, root) = try await session(); defer { try? FileManager.default.removeItem(at: root) }
        let second = try WorkspaceSession(workspace: Workspace(root: root), vault: await session.vault)
        let account = try #require(try await session.accounts().first), files = try input()
        let first = try await session.previewAnalyticsFiles(account: account, appId: appId, input: files, now: now), other = try await second.previewAnalyticsFiles(account: account, appId: appId, input: files, now: now)
        let results = await withTaskGroup(of: Bool.self) { group in
            group.addTask { do { _ = try await session.saveAnalyticsFiles(first, input: files, now: now); return true } catch { #expect(error as? AnalyticsFileFailure == .stale); return false } }
            group.addTask { do { _ = try await second.saveAnalyticsFiles(other, input: files, now: now); return true } catch { #expect(error as? AnalyticsFileFailure == .stale); return false } }
            var values: [Bool] = []; for await value in group { values.append(value) }; return values
        }
        #expect(results.filter { $0 }.count == 1 && results.filter { !$0 }.count == 1)
        let stale = try await session.savedAnalyticsFiles(account: account, appId: appId), updated = try input("changed-count")
        let review = try await session.previewAnalyticsFiles(account: account, appId: appId, input: updated, now: now)
        _ = try await session.saveAnalyticsFiles(review, input: updated, now: now)
        await #expect(throws: AnalyticsFileFailure.stale) { try await session.removeAnalyticsFilePeriod(stale, key: stale.partitions[0].key) }
        #expect(try await partitions(session, account).map(\.json) == review.partitions.map(\.json))
    }

    @Test func canceledSaveCannotCommitAndAtomicExportPreservesDestination() async throws {
        let (session, root) = try await session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), files = try input(), review = try await session.previewAnalyticsFiles(account: account, appId: appId, input: files, now: now)
        let pending = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await session.saveAnalyticsFiles(review, input: files, now: now) }
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(try await partitions(session, account).isEmpty)
        let target = root.appendingPathComponent("synthetic-destination.json"), original = Data("Synthetic previous export".utf8)
        try original.write(to: target)
        let export = Task { try ReportFiles.atomicStream(to: target) { append in try append(Data("Synthetic partial chunk".utf8)); withUnsafeCurrentTask { $0?.cancel() } } }
        await #expect(throws: CancellationError.self) { try await export.value }
        #expect(try Data(contentsOf: target) == original)
        #expect(throws: AnalyticsFileFailure.missing) { try ReportFiles.atomicStream(to: target) { append in try append(Data([123])); throw AnalyticsFileFailure.missing } }
        #expect(try Data(contentsOf: target) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".storebench-export-") }.isEmpty)
        let link = root.appendingPathComponent("synthetic-link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: ReportFiles.Failure.write) { try ReportFiles.atomicStream(to: link) { try $0(Data([123])) } }
        let outside = root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("synthetic-disallowed-export")
        #expect(throws: (any Error).self) { try ReportFiles.atomicStream(to: outside) { _ in Issue.record("Disallowed export reached the writer") } }
    }

    @Test func removedAndRecreatedIndexCannotReuseAnOlderNumericRevision() async throws {
        let (session, root) = try await session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), files = try input()
        let initial = try await session.previewAnalyticsFiles(account: account, appId: appId, input: files, now: now)
        _ = try await session.saveAnalyticsFiles(initial, input: files, now: now)
        let old = try await session.previewAnalyticsFiles(account: account, appId: appId, input: files, now: now), saved = try await session.savedAnalyticsFiles(account: account, appId: appId)
        try await session.removeAnalyticsFilePeriod(saved, key: saved.partitions[0].key)
        let updated = try input("changed-count"), current = try await session.previewAnalyticsFiles(account: account, appId: appId, input: updated, now: now)
        _ = try await session.saveAnalyticsFiles(current, input: updated, now: now)
        let latest = try await session.savedAnalyticsFiles(account: account, appId: appId)
        #expect(saved.revision.index == latest.revision.index && saved.revision != latest.revision)
        await #expect(throws: AnalyticsFileFailure.stale) { try await session.saveAnalyticsFiles(old, input: files, now: now) }
        await #expect(throws: AnalyticsFileFailure.stale) { try await session.removeAnalyticsFilePeriod(saved, key: saved.partitions[0].key) }
        #expect(try await partitions(session, account).map(\.json) == latest.partitions.map(\.json))
    }

    @Test func malformedLegacyOwnershipAndSourceFailBeforeExportReplacement() async throws {
        let (session, root) = try await session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), incoming = try AnalyticsFileFormats.parse(input(), accountId: account.id, appId: appId, now: now)
        let target = root.appendingPathComponent("synthetic-export.json"), original = Data("Synthetic previous export".utf8); try original.write(to: target)
        let foreign = AnalyticsFileFormats.history(accountId: "other-synthetic-account", appId: appId, partitions: incoming.partitions)
        try await session.storeAccess { store in try store.transaction { _ in [.put(namespace: "analytics", key: "\(account.id):\(appId)", json: foreign.data)] } }
        await #expect(throws: AnalyticsFileFailure.storage) { try await session.savedAnalyticsFiles(account: account, appId: appId) }
        await #expect(throws: AnalyticsFileFailure.storage) { try await session.writeAnalyticsFile(account: account, appId: appId, format: .historyJson, to: target) }
        #expect(try Data(contentsOf: target) == original)
        let bad = AnalyticsPartition(kind: "downloads", level: "standard", granularity: "DAILY", processingDate: "2026-02-11", date: "2026-02-10", importedAt: "2026-03-01T12:00:00.000Z", segments: 1, source: ReportTable(columns: ["Synthetic"], rows: [["Synthetic"]]))
        try await session.storeAccess { store in try store.transaction { _ in [.put(namespace: "analytics", key: "\(account.id):\(appId)", json: AnalyticsFileFormats.history(accountId: account.id, appId: appId, partitions: [bad]).data)] } }
        await #expect(throws: AnalyticsFileFailure.storage) { try await session.analytics(accountId: account.id, appId: appId) }
        await #expect(throws: AnalyticsFileFailure.storage) { try await session.previewAnalyticsFiles(account: account, appId: appId, input: input(), now: now) }
        #expect(try Data(contentsOf: target) == original)
    }

    @Test func aggregateCountsAreBoundedAcrossMonthsAndIndependentBases() throws {
        func part(_ date: String) throws -> AnalyticsPartition {
            let rows = (0..<5_000).map { [date, "Synthetic total \($0)", appId, "First-time Download", "1.0", "iPhone", "26.0", "Synthetic source", "Product page", "No", "US", "999999999999"] }
            return try AnalyticsReports.importSegments([ReportTable(columns: AnalyticsSyncTests.columns, rows: rows)], meta: AnalyticsMetadata(kind: "downloads", level: "standard", granularity: "DAILY", processingDate: "2026-02-28"), accountId: "synthetic-account", appId: appId, importedAt: "2026-03-01T12:00:00.000Z")[0]
        }
        let first = try part("2026-01-01"), second = try part("2026-02-01")
        #expect(try AnalyticsFileFormats.normalize([first], accountId: "synthetic-account", appId: appId).count == 1)
        #expect(throws: AnalyticsFailure.format) { try AnalyticsFileFormats.normalize([first, second], accountId: "synthetic-account", appId: appId) }
        #expect(throws: AnalyticsFailure.format) { try AnalyticsFileFormats.review([first], [second]) }
    }

    @Test func preparedViewsCannotBypassSavedIndexOwnership() async throws {
        let (session, root) = try await session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), files = try input(), review = try await session.previewAnalyticsFiles(account: account, appId: appId, input: files, now: now)
        _ = try await session.saveAnalyticsFiles(review, input: files, now: now)
        try await session.storeAccess { store in
            let document = try #require(try store.document(namespace: "analytics_index", key: "\(account.id):\(appId)")), value = try JSONText.parse(document.payload)
            guard case .object(let fields) = value else { throw AnalyticsFailure.format }
            try store.transaction { _ in [.put(namespace: "analytics_index", key: "\(account.id):\(appId)", json: JSONText.object(fields.map { ($0.0, $0.0 == "accountId" ? .string("other-synthetic-account") : $0.1) }).data)] }
        }
        await #expect(throws: PartitionedReports.Failure.invalid) { try await session.analytics(accountId: account.id, appId: appId) }
        await #expect(throws: AnalyticsFileFailure.storage) { try await session.savedAnalyticsFiles(account: account, appId: appId) }
    }

    @Test func modifiedBucketCannotExportUnderAnEarlierFingerprint() async throws {
        let (session, root) = try await session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), files = try input(), review = try await session.previewAnalyticsFiles(account: account, appId: appId, input: files, now: now)
        _ = try await session.saveAnalyticsFiles(review, input: files, now: now)
        let modified = try AnalyticsFileFormats.parse(input("changed-count"), accountId: account.id, appId: appId, now: now)
        try await session.storeAccess { store in
            let document = try #require(try store.documents(namespace: "analytics_part", prefix: "\(account.id):\(appId):").first), value = try JSONText.parse(document.payload)
            guard case .object(let fields) = value else { throw AnalyticsFailure.format }
            try store.transaction { _ in [.put(namespace: "analytics_part", key: document.key, json: JSONText.object(fields.map { ($0.0, $0.0 == "items" ? .array(modified.partitions.map(\.json)) : $0.1) }).data)] }
        }
        let target = root.appendingPathComponent("synthetic-export.json"), original = Data("Synthetic earlier export".utf8); try original.write(to: target)
        await #expect(throws: AnalyticsFileFailure.storage) { try await session.savedAnalyticsFiles(account: account, appId: appId) }
        await #expect(throws: AnalyticsFileFailure.storage) { try await session.writeAnalyticsFile(account: account, appId: appId, format: .historyJson, to: target) }
        #expect(try Data(contentsOf: target) == original)
    }

    @Test func completeSavedHistoryLargerThanUploadLimitExportsWithoutTruncation() async throws {
        let (session, root) = try await session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first)
        let partitions = try ["2026-01-01", "2026-02-01"].map { date in
            let rows = (0..<700).map { [date, "Synthetic \($0) " + String(repeating: "x", count: 8_000), appId, "First-time Download", "1.0", "iPhone", "26.0", "Synthetic source", "Product page", "No", "US", "1"] }
            return try AnalyticsReports.importSegments([ReportTable(columns: AnalyticsSyncTests.columns, rows: rows)], meta: AnalyticsMetadata(kind: "downloads", level: "standard", granularity: "DAILY", processingDate: "2026-02-28"), accountId: account.id, appId: appId, importedAt: "2026-03-01T12:00:00.000Z")[0]
        }
        try await session.storeAccess { store in
            try PartitionedReports.replaceAll(AnalyticsPartition.self, family: "analytics", legacyKey: "partitions", accountId: account.id, appId: appId, store: store, stateDirectory: store.directory, bucketOf: \.bucket, encode: \.json, view: (1, { try AnalyticsReports.view($0) })) { _, _ in (partitions, nil) }
        }
        let target = root.appendingPathComponent("synthetic-full-history.json")
        try await session.writeAnalyticsFile(account: account, appId: appId, format: .historyJson, to: target)
        let actual = try Data(contentsOf: target)
        #expect(actual.count > 10_000_000 && actual == AnalyticsFileFormats.history(accountId: account.id, appId: appId, partitions: partitions).data)
        #expect(throws: ReportFiles.Failure.size) { try AnalyticsFileFormats.parse(AnalyticsFileInput(files: [actual]), accountId: account.id, appId: appId, now: now) }
        try await session.verifyBuckets(family: "analytics", accountId: account.id, appId: appId)
    }
}

@Suite struct AnalyticsFileProcessTests {
    init() throws { _ = try TestIsolation.require() }
    @Test func scopeIsRecheckedAfterOwnedProcessCrashWithoutExpiringOrReplacingMutex() async throws {
        let root = try TestIsolation.require().appendingPathComponent("analytics-lock-policy"), fixture = try AnalyticsFileTests(), appId = fixture.appId
        let (session, _) = try await fixture.session(directory: root), account = try #require(try await session.accounts().first), files = try fixture.input()
        let mutex = root.appendingPathComponent("state-v2/analytics-\(JSONText.string("\(account.id)\u{0}\(appId)").rawSHA256.prefix(32)).mutex")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("lock-ready").path))
        #expect(try FileMutex.tryLock(mutex) == nil)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: mutex.path)
        let inode = try #require(try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber)
        let reader = try EncryptedDocumentStore(url: EncryptedDocumentStore.databaseURL(root: root), key: Data(0..<32), writable: true)
        let baseline = try PartitionedReports.revision(family: "analytics", accountId: account.id, appId: appId, store: reader), incoming = try AnalyticsFileFormats.parse(files, accountId: account.id, appId: appId, now: fixture.now)
        let review = AnalyticsFileReview(partitions: incoming.partitions, changes: try AnalyticsFileFormats.review([], incoming.partitions).changes, importId: incoming.importId, account: account, appId: appId, revision: baseline)
        let pending = Task { try await session.saveAnalyticsFiles(review, input: files, now: fixture.now) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(try reader.document(namespace: "analytics_index", key: "\(account.id):\(appId)") == nil)
        let accountDocument = try #require(try reader.document(namespace: "accounts", key: "all"))
        let removed = Account(id: account.id, name: account.name, keyId: account.keyId, keyType: account.keyType, issuerId: account.issuerId, appIds: [], appNames: nil)
        try reader.transaction { _ in [.put(namespace: "accounts", key: "all", json: JSONText.array([WorkspaceSession.json(removed)]).data)] }
        try JobLock.exclusive(root.appendingPathComponent("lock-release"), "interrupt")
        await #expect(throws: AnalyticsFailure.scope) { try await pending.value }
        #expect(try reader.document(namespace: "analytics_index", key: "\(account.id):\(appId)") == nil)
        try reader.transaction { _ in [.put(namespace: "accounts", key: "all", json: accountDocument.payload)] }
        #expect(try await session.saveAnalyticsFiles(review, input: files, now: fixture.now).map(\.action) == ["added"])
        #expect(try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber == inode)
        try await session.verifyBuckets(family: "analytics", accountId: account.id, appId: appId)
    }
}
