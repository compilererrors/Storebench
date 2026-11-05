import CryptoKit
import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct ReviewsFileTests {
    init() throws { _ = try TestIsolation.require() }
    let appId = "1000000001"
    func golden() throws -> JSONText { try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/reviews-file-formats.json"))) }
    func files(_ id: String = "base-json") throws -> [Data] {
        guard case .array(let vectors)? = try golden()["vectors"], let value = vectors.first(where: { $0["id"] == .string(id) }), case .array(let files)? = value["files"] else { throw ReviewsFailure.format }
        return try files.map { try #require(Data(base64Encoded: $0.text!)) }
    }
    func session() async throws -> (WorkspaceSession, Account, URL) { try await ReviewsJobTests().session() }
    func clear(_ session: WorkspaceSession) async throws {
        try await session.storeAccess { store in
            for namespace in ["reviews", "reviews_index", "reviews_part"] { for document in try store.documents(namespace: namespace) { try store.delete(namespace: namespace, key: document.key) } }
        }
    }
    func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }

    @Test func jsonCsvGzipFingerprintsAndRetainedReviewComparisonsMatchWeb() throws {
        let value = try golden(), previous = try ReviewsSnapshot(value["previous"]!)
        guard case .array(let vectors)? = value["vectors"] else { throw ReviewsFailure.format }
        #expect(vectors.count > 35)
        for vector in vectors {
            guard case .array(let raw)? = vector["files"] else { throw ReviewsFailure.format }
            let files = try raw.map { try #require(Data(base64Encoded: $0.text!)) }, label = vector["id"]!.text!
            if vector["rejected"] == .bool(true) { #expect(throws: (any Error).self, "Synthetic review input: \(label)") { try ReviewsFileFormats.parse(files, accountId: "synthetic-account", appId: appId) } }
            else {
                let incoming = try ReviewsFileFormats.parse(files, accountId: "synthetic-account", appId: appId)
                #expect(incoming.json == vector["expected"], "Synthetic review snapshot: \(label)")
                #expect(incoming.json.sha256 == vector["importId"]?.text, "Synthetic review fingerprint: \(label)")
                #expect(try ReviewsFileFormats.export(incoming, format: .csv) == Data(vector["csv"]!.text!.utf8), "Synthetic CSV export: \(label)")
                #expect(try ReviewsFileFormats.export(incoming, format: .json) == Data(vector["json"]!.text!.utf8))
                let compared = try ReviewsFileFormats.compare(previous, incoming), expected = vector["comparison"]!
                #expect(compared.snapshot.json == expected["snapshot"])
                #expect(compared.changes.added == Int(expected["changes"]!["added"]!.stringify()))
                #expect(compared.changes.updated == Int(expected["changes"]!["updated"]!.stringify()))
                #expect(compared.changes.unchanged == Int(expected["changes"]!["unchanged"]!.stringify()) && compared.changes.removed == 0)
                #expect(JSONText.array(compared.differences.map(\.json)) == expected["differences"], "Synthetic review differences: \(label)")
            }
        }
    }

    @Test func filtersSummaryUnicodeAndCompletePagingMatchWeb() throws {
        let value = try golden(), snapshot = try ReviewsSnapshot(value["base"]!)
        guard case .array(let vectors)? = value["filters"] else { throw ReviewsFailure.format }
        for vector in vectors {
            let raw = vector["filters"]!, filter = ReviewsPresentation.Filters(query: raw["query"]!.text!, rating: raw["rating"]!.text!, territory: raw["territory"]!.text!, begin: raw["begin"]!.text!, end: raw["end"]!.text!, sort: raw["sort"]!.text!)
            let rows = ReviewsPresentation.filter(snapshot.reviews, filter), summary = ReviewsPresentation.summarize(rows)
            #expect(JSONText.array(rows.map { .string($0.id) }) == vector["ids"])
            #expect(summary.json == vector["summary"])
        }
        for count in [0, 1, 10, 11, 100, 101, 6000] {
            let rows = Array(0..<count), pages = ReviewsPresentation.pages(count: count, size: 10)
            #expect((1...pages).flatMap { ReviewsPresentation.page(rows, number: $0, size: 10) } == rows)
            #expect(ReviewsPresentation.page(rows, number: Int.max, size: 10) == Array(rows.suffix(count == 0 ? 0 : (count - 1) % 10 + 1)))
        }
        for filters in [ReviewsPresentation.Filters(begin: "2026-02-30"), .init(end: "unknown"), .init(begin: "2026-02-02", end: "2026-02-01")] {
            #expect(!filters.validDates && ReviewsPresentation.filter(snapshot.reviews, filters).isEmpty)
        }
        #expect(ReviewsPresentation.summarize([]).average == nil)
        let review = snapshot.reviews[0]
        func sample(_ count: Int, low: Int) -> ReviewsPresentation.Summary {
            ReviewsPresentation.summarize((0..<count).map { .init(id: "synthetic-sample-\($0)", rating: $0 < low ? 2 : 5, title: review.title, body: review.body, createdDate: review.createdDate, territory: review.territory) })
        }
        #expect(!sample(9, low: 3).shouldReadLowFeedback && !sample(10, low: 2).shouldReadLowFeedback && !sample(11, low: 3).shouldReadLowFeedback)
        #expect(sample(10, low: 3).shouldReadLowFeedback && sample(20, low: 6).shouldReadLowFeedback)
    }

    @Test func independentColumnSortingMatchesWebWithoutChangingFilterTotals() throws {
        let golden = try #require(try golden()["tableSorts"]), snapshot = try ReviewsSnapshot(golden["snapshot"]!), summary = ReviewsPresentation.summarize(snapshot.reviews)
        guard case .array(let reviews)? = golden["reviews"], case .array(let territories)? = golden["territories"] else { throw ReviewsFailure.format }
        for vector in reviews {
            let ordered = ReviewsPresentation.orderedReviews(snapshot.reviews, key: vector["key"]!.text!, descending: vector["descending"] == .bool(true))
            #expect(JSONText.array(ordered.map { .string($0.id) }) == vector["ids"], "Synthetic column sort: \(vector["key"]!.text!) \(vector["descending"]!)")
            #expect(ReviewsPresentation.summarize(ordered).json == summary.json)
        }
        for vector in territories {
            let ordered = ReviewsPresentation.orderedTerritories(summary.territories, key: vector["key"]!.text!, descending: vector["descending"] == .bool(true))
            #expect(JSONText.array(ordered.map { .string($0.territory) }) == vector["ids"])
        }
        #expect(ReviewsPresentation.Filters(query: "café") != ReviewsPresentation.Filters(query: "cafe\u{0301}"))
    }

    @Test func previewIsReadOnlyAndSaveRereadsFilesWithExactHistoryRevision() async throws {
        let (session, account, root) = try await session(); defer { try? FileManager.default.removeItem(at: root) }; try await clear(session)
        let bytes = try files(), review = try await session.previewReviewsFile(account: account, appId: appId, files: bytes)
        #expect(review.changes.added == 24 && review.differences.count == 24)
        #expect(try await session.savedReviewsFiles(account: account, appId: appId).snapshot == nil)
        await #expect(throws: ReviewsFileFailure.changedFiles) { try await session.saveReviewsFile(review, files: files("changed-json")) }
        let gzipped = try files("base-json-gzip")
        #expect(try await session.saveReviewsFile(review, files: gzipped).added == 24)
        try await session.verifyBuckets(family: "reviews", accountId: account.id, appId: appId)
        await #expect(throws: ReviewsFailure.stale) { try await session.saveReviewsFile(review, files: bytes) }
        let update = try await session.previewReviewsFile(account: account, appId: appId, files: files("changed-json"))
        #expect(update.changes.added == 1 && update.changes.updated == 1 && update.changes.removed == 0)
        _ = try await session.saveReviewsFile(update, files: files("changed-json"))
        let saved = try #require(try await session.savedReviewsFiles(account: account, appId: appId).snapshot)
        #expect(saved.reviews.count == 25 && !saved.limited && saved.fullCheckedAt == "2026-01-31T00:00:00.000Z")
        #expect(saved.reviews.contains { $0.id == "synthetic-review-0" && $0.body == "Synthetic updated feedback" })
        let empty = try await session.previewReviewsFile(account: account, appId: appId, files: files("empty-csv"))
        #expect(empty.changes.added == 0 && empty.changes.updated == 0 && empty.differences.isEmpty)
        _ = try await session.saveReviewsFile(empty, files: files("empty-csv"))
        #expect(try await session.savedReviewsFiles(account: account, appId: appId).snapshot?.reviews.count == 25)
    }

    @Test func concurrentReviewedSavesHaveOneWinnerAndNeverDropHistory() async throws {
        let (session, account, root) = try await session(); defer { try? FileManager.default.removeItem(at: root) }; try await clear(session)
        let second = try WorkspaceSession(workspace: Workspace(root: root), vault: await session.vault), bytes = try files()
        let one = try await session.previewReviewsFile(account: account, appId: appId, files: bytes), two = try await second.previewReviewsFile(account: account, appId: appId, files: files("changed-json"))
        async let firstResult: Bool = saveResult(session, one, bytes)
        async let secondResult: Bool = saveResult(second, two, files("changed-json"))
        let results = try await [firstResult, secondResult]; #expect(results.filter { $0 }.count == 1)
        let saved = try #require(try await session.savedReviewsFiles(account: account, appId: appId).snapshot)
        #expect(saved.reviews.count == (results[0] ? 24 : 2))
        try await session.verifyBuckets(family: "reviews", accountId: account.id, appId: appId)
    }
    func saveResult(_ session: WorkspaceSession, _ review: ReviewsFileReview, _ files: [Data]) async throws -> Bool {
        do { _ = try await session.saveReviewsFile(review, files: files); return true } catch ReviewsFailure.stale { return false }
    }

    @Test func appScopeAndCancelledImportKeepExactSavedHistory() async throws {
        let (session, account, root) = try await session(); defer { try? FileManager.default.removeItem(at: root) }
        let before = try await session.savedReviewsFiles(account: account, appId: appId).snapshot?.json, bytes = try files()
        let review = try await session.previewReviewsFile(account: account, appId: appId, files: bytes)
        let task = Task { try await Task.sleep(for: .seconds(60)); return try await session.saveReviewsFile(review, files: bytes) }; task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await session.savedReviewsFiles(account: account, appId: appId).snapshot?.json == before)
        let reader = try ReviewsJobTests().store(root), original = try #require(try reader.document(namespace: "accounts", key: "all"))
        let removed = Account(id: account.id, name: account.name, keyId: account.keyId, keyType: account.keyType, issuerId: account.issuerId, appIds: [], appNames: nil)
        try reader.transaction { _ in [.put(namespace: "accounts", key: "all", json: JSONText.array([WorkspaceSession.json(removed)]).data)] }
        await #expect(throws: ReviewsFailure.scope) { try await session.saveReviewsFile(review, files: bytes) }
        try reader.transaction { _ in [.put(namespace: "accounts", key: "all", json: original.payload)] }
        #expect(try await session.savedReviewsFiles(account: account, appId: appId).snapshot?.json == before)
    }

    @Test func atomicExportsIncludeEveryRowAboveImportLimits() async throws {
        let vector = try golden(), expected = vector["exports"]!, template = try JSONDecoder().decode(CustomerReview.self, from: expected["template"]!.data)
        let rows = (0..<6001).map { index in CustomerReview(id: String(format: "synthetic-large-%05d", index), rating: template.rating, title: template.title, body: template.body, createdDate: template.createdDate, territory: template.territory) }
        let base = try ReviewsSnapshot(vector["base"]!), large = try ReviewsSnapshot(accountId: base.accountId, appId: base.appId, checkedAt: base.checkedAt, limited: base.limited, fullCheckedAt: base.fullCheckedAt, reviews: rows)
        #expect(large.reviews.count == 6001)
        let (session, account, root) = try await session(); defer { try? FileManager.default.removeItem(at: root) }
        try await session.storeAccess { store in
            try PartitionedReports.replaceAll(CustomerReview.self, family: "reviews", legacyKey: "reviews", accountId: account.id, appId: appId, store: store, stateDirectory: store.directory,
                bucketOf: { String($0.createdDate.prefix(7)) }, encode: \.json) { _, _ in (large.reviews, large.metadata) }
        }
        for (format, key) in [(ReviewsFileFormats.Format.json, "json"), (.csv, "csv")] {
            let url = root.appendingPathComponent("synthetic-export.\(key)")
            try ReportFiles.atomicStream(to: url) { try $0(Data("Synthetic old destination".utf8)) }
            try await session.writeReviewsFile(account: account, appId: appId, format: format, to: url)
            let bytes = try Data(contentsOf: url); #expect(bytes.count > 10_000_000)
            #expect(expected["\(key)Bytes"] == .number(Double(bytes.count)) && digest(bytes) == expected["\(key)Sha256"]?.text)
            #expect(throws: ReportFiles.Failure.size) { try ReportFiles.read([url], purpose: .reports) }
            let before = bytes
            #expect(throws: ReviewsFailure.scope) {
                try ReportFiles.atomicStream(to: url) { append in try append(Data("Synthetic partial output".utf8)); throw ReviewsFailure.scope }
            }
            #expect(try Data(contentsOf: url) == before)
        }
    }

    @Test func boundedReadersRejectGzipExpansionInvalidNormalizedSizeAndSymlinks() throws {
        let snapshot = try ReviewsSnapshot(golden()["base"]!)
        let expanded = try ReportFiles.gzip(Data(repeating: 32, count: 10_000_001))
        #expect(throws: ReportFiles.Failure.size) { try ReviewsFileFormats.parse([expanded], accountId: snapshot.accountId, appId: appId) }
        let root = try TestIsolation.require().appendingPathComponent("reviews-file-read-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("synthetic.json"), link = root.appendingPathComponent("synthetic-link.json")
        try ReportFiles.atomicStream(to: original) { try $0(snapshot.json.data) }; try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        #expect(throws: ReportFiles.Failure.read) { try ReportFiles.read([link], purpose: .reports) }
        #expect(throws: ReportFiles.Failure.write) { try ReportFiles.atomicStream(to: link) { try $0(Data()) } }
        let row = CustomerReview(id: "synthetic-large-import", rating: 4, title: "Synthetic", body: String(repeating: "\t", count: 16000), createdDate: "2026-01-30T00:00:00.000Z", territory: "SWE")
        let tooLarge = try ReviewsSnapshot(accountId: snapshot.accountId, appId: appId, checkedAt: snapshot.checkedAt, limited: false,
            reviews: (0..<400).map { CustomerReview(id: "synthetic-import-\($0)", rating: row.rating, title: row.title, body: row.body, createdDate: row.createdDate, territory: row.territory) })
        let source = try ReviewsFileFormats.export(tooLarge, format: .csv); #expect(source.count < 10_000_000)
        #expect(throws: ReviewsFileFailure.size) { try ReviewsFileFormats.parse([source], accountId: snapshot.accountId, appId: appId) }
    }
}

@Suite(.serialized) struct ReviewsFileProcessTests {
    init() throws { _ = try TestIsolation.require() }
    @Test(arguments: [true, false]) func importWaitingForOwnedMutexRechecksCancellationAndAccountScope(cancel: Bool) async throws {
        let fixture = try ReviewsJobTests(), root = try TestIsolation.require().appendingPathComponent(cancel ? "reviews-file-cancel-policy" : "reviews-file-scope-policy")
        let (session, account, _) = try await fixture.session(directory: root), reader = try fixture.store(root)
        let before = try #require(try reader.document(namespace: "reviews_index", key: "\(account.id):\(fixture.appId)"))
        let original = try #require(try reader.document(namespace: "accounts", key: "all")), bytes = try ReviewsFileTests().files("changed-json")
        let incoming = try ReviewsFileFormats.parse(bytes, accountId: account.id, appId: fixture.appId)
        // This immutable review represents a preview taken before the owned helper acquired the mutex.
        let review = ReviewsFileReview(changes: ReviewChanges(), differences: [], importId: incoming.json.sha256, account: account, appId: fixture.appId,
            revision: try PartitionedReports.revision(family: "reviews", accountId: account.id, appId: fixture.appId, store: reader))
        let name = "reviews-" + JSONText.string("\(account.id)\u{0}\(fixture.appId)").rawSHA256.prefix(32), mutex = reader.directory.appendingPathComponent("\(name).mutex")
        let inode = try #require(try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber)
        #expect(try FileMutex.tryLock(mutex) == nil)
        let ready = root.appendingPathComponent("save-ready"), operation = Task {
            try JobLock.exclusive(ready, "ready"); return try await session.saveReviewsFile(review, files: bytes)
        }
        try await fixture.wait { FileManager.default.fileExists(atPath: ready.path) }
        try await Task.sleep(for: .milliseconds(60))
        #expect(try reader.document(namespace: "reviews_index", key: "\(account.id):\(fixture.appId)")?.payload == before.payload)
        if cancel { operation.cancel() }
        else {
            let removed = Account(id: account.id, name: account.name, keyId: account.keyId, keyType: account.keyType, issuerId: account.issuerId, appIds: [], appNames: nil)
            try reader.transaction { _ in [.put(namespace: "accounts", key: "all", json: JSONText.array([WorkspaceSession.json(removed)]).data)] }
        }
        try JobLock.exclusive(root.appendingPathComponent("lock-release"), "interrupt")
        if cancel { await #expect(throws: CancellationError.self) { try await operation.value } }
        else { await #expect(throws: ReviewsFailure.scope) { try await operation.value } }
        #expect(try reader.document(namespace: "reviews_index", key: "\(account.id):\(fixture.appId)")?.payload == before.payload)
        #expect(try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber == inode)
        try reader.transaction { _ in [.put(namespace: "accounts", key: "all", json: original.payload)] }
    }
}
