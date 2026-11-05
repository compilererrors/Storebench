import Darwin
import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct RevisionHistoryTests {
    init() throws { _ = try TestIsolation.require() }
    let account = "synthetic-account", app = "1000000001"
    let older = "00000000-0000-4000-8000-000000000001", newer = "00000000-0000-4000-8000-000000000002"
    func key(_ id: String) -> String { "\(account):\(app):\(id)" }
    func put(_ store: EncryptedDocumentStore, namespace: String, key: String, json: Data, expectedRevision: Int) throws {
        try store.transaction { current in
            guard (try current(namespace, key)?.revision ?? 0) == expectedRevision else { throw RevisionHistoryFailure.stale }
            return [.put(namespace: namespace, key: key, json: json)]
        }
    }
    func importMutex(_ root: URL) -> URL { root.appendingPathComponent("state-v2/import_\(JSONText.string(account + "\u{0}" + app).rawSHA256.prefix(48)).lock.mutex") }

    @Test func comparisonMatchesEveryWebContractVector() throws {
        let fixture = try JSONText.parse(Data(contentsOf: try TestIsolation.require().appendingPathComponent("native-fixtures/revision-history.json")))
        guard case .array(let vectors)? = fixture["vectors"] else { Issue.record("Missing synthetic vectors"); return }
        #expect(vectors.count >= 35)
        for vector in vectors {
            let before = try #require(vector["before"]), after = try #require(vector["after"])
            if vector["rejected"] == .bool(true) {
                #expect(throws: RevisionHistoryFailure.invalid) { try RevisionComparison.compare(before: before, after: after) }
            } else {
                let changes = try RevisionComparison.compare(before: before, after: after)
                #expect(JSONText.array(changes.map(\.json)).stringify() == vector["expected"]?.stringify(), "\(vector["name"]?.text ?? "Synthetic vector")")
            }
        }
        let benchmark = try #require(fixture["benchmark"])
        let count = try RevisionComparison.compare(before: #require(benchmark["before"]), after: #require(benchmark["after"])).count
        #expect(count == 1400)
    }

    @Test func archivedIdentityAndConfiguredScopeAreRequired() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let history = try await session.archivedHistory(accountId: account, appId: app)
        #expect(history.map(\.id) == [newer, older] && history.allSatisfy { $0.documentRevision == 1 })
        let changes = try await session.compareArchivedRevisions(accountId: account, appId: app, beforeId: older, afterId: newer)
        #expect(changes.contains { $0.label == "Description" && $0.before == "First synthetic description" && $0.after == "Second synthetic description" })
        #expect(try await session.compareArchivedRevisions(accountId: account, appId: app, beforeId: older, afterId: older).isEmpty)
        await #expect(throws: RevisionHistoryFailure.invalid) { try await session.archivedHistory(accountId: "other-synthetic-account", appId: app) }
        await #expect(throws: RevisionHistoryFailure.invalid) { try await session.archivedHistory(accountId: account, appId: "../synthetic") }
        try await session.storeAccess { store in
            let source = try JSONText.parse(#require(try store.document(namespace: "revisions", key: key(newer))).payload)
            guard case .object(let fields) = source else { throw RevisionHistoryFailure.invalid }
            let foreign = JSONText.object(fields.map { ($0.0, $0.0 == "account" ? .object([("id", .string("other-synthetic-account"))]) : $0.1) })
            try put(store, namespace: "revisions", key: key(newer), json: foreign.data, expectedRevision: 1)
        }
        #expect(try await session.archivedHistory(accountId: account, appId: app).map(\.id) == [older])
        await #expect(throws: RevisionHistoryFailure.invalid) { try await session.compareArchivedRevisions(accountId: account, appId: app, beforeId: older, afterId: newer) }
    }

    @Test func versionHistoryShowsEachVersionAsItsNewestImportSawIt() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let history = VersionHistory(try await session.archivedHistory(accountId: account, appId: app))
        #expect(!history.entries.isEmpty && history.entries.count == Set(history.entries.map(\.id)).count)
        let descriptions = history.entries.flatMap { $0.languages.flatMap { $0.fields.filter { $0.key == "description" }.map(\.value) } }
        #expect(descriptions.contains("Second synthetic description") && !descriptions.contains("First synthetic description"))
        #expect(history.entries.allSatisfy { $0.previous != nil || $0.languages.allSatisfy { $0.changedCount == 0 } })
    }

    @Test func deletionRemovesOnlyTheSelectedRevisionAndDraft() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        try await session.storeAccess { store in
            try put(store, namespace: "drafts", key: key(newer), json: Data("{}".utf8), expectedRevision: 0)
            try put(store, namespace: "drafts", key: key(older), json: Data("{}".utf8), expectedRevision: 0)
        }
        let media = try EncryptedMediaStore(directory: root.appendingPathComponent("state-v2/media"), key: Data(0..<32))
        let bytes = Data("Synthetic shared image bytes".utf8), hash = try media.write(bytes).hash
        try await session.storeAccess { store in
            for id in [newer, older] {
                let source = try JSONText.parse(#require(try store.document(namespace: "revisions", key: key(id))).payload)
                let original = try #require(try RevisionComparison.entries(source).values.values.compactMap(\.images).first?.first)
                let payload = Data(source.stringify().replacingOccurrences(of: original, with: hash).utf8)
                try put(store, namespace: "revisions", key: key(id), json: payload, expectedRevision: 1)
            }
        }
        #expect(try await session.archivedScreenshot(accountId: account, appId: app, revisionId: newer, hash: hash) == bytes)
        #expect(try await session.deleteArchivedRevision(accountId: account, appId: app, revisionId: newer, expectedRevision: 2))
        let documents = try await session.storeAccess { (try $0.document(namespace: "revisions", key: key(newer)), try $0.document(namespace: "drafts", key: key(newer)), try $0.document(namespace: "drafts", key: key(older))) }
        #expect(documents.0 == nil && documents.1 == nil && documents.2 != nil)
        #expect(try await session.archivedScreenshot(accountId: account, appId: app, revisionId: older, hash: hash) == bytes)
        await #expect(throws: RevisionHistoryFailure.missing) { try await session.archivedScreenshot(accountId: account, appId: app, revisionId: newer, hash: hash) }
        await #expect(throws: RevisionHistoryFailure.missing) { try await session.archivedScreenshot(accountId: account, appId: app, revisionId: older, hash: String(repeating: "b", count: 64)) }
    }

    @Test func missingRevisionPreservesAnOrphanDraftAndPlanStillBlocks() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        try await session.storeAccess { store in
            try put(store, namespace: "drafts", key: key(newer), json: Data("{}".utf8), expectedRevision: 0)
            try store.transaction { _ in [.delete(namespace: "revisions", key: key(newer))] }
        }
        #expect(try await session.deleteArchivedRevision(accountId: account, appId: app, revisionId: newer, expectedRevision: 1) == false)
        #expect(try await session.storeAccess { try $0.document(namespace: "drafts", key: key(newer)) } != nil)
        try await session.storeAccess { store in
            let entry = JSONText.object([("accountId", .string(account)), ("appId", .string(app)), ("sourceRevisionId", .string(newer))])
            let plan = JSONText.object([("schemaVersion", .number(1)), ("plans", .array([entry]))])
            try put(store, namespace: "release_plans", key: "all", json: plan.data, expectedRevision: 0)
        }
        await #expect(throws: RevisionHistoryFailure.planned) { try await session.deleteArchivedRevision(accountId: account, appId: app, revisionId: newer, expectedRevision: 1) }
    }

    @Test func changedRevisionAndActivePlanLeaveBothDocumentsIntact() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        try await session.storeAccess { store in
            let source = try #require(try store.document(namespace: "revisions", key: key(newer)))
            try put(store, namespace: "revisions", key: key(newer), json: source.payload, expectedRevision: 1)
            try put(store, namespace: "drafts", key: key(newer), json: Data("{}".utf8), expectedRevision: 0)
        }
        await #expect(throws: RevisionHistoryFailure.stale) { try await session.deleteArchivedRevision(accountId: account, appId: app, revisionId: newer, expectedRevision: 1) }
        try await session.storeAccess { store in
            let entry = JSONText.object([("accountId", .string(account)), ("appId", .string(app)), ("sourceRevisionId", .string(newer))])
            let plan = JSONText.object([("schemaVersion", .number(1)), ("plans", .array([entry]))])
            try put(store, namespace: "release_plans", key: "all", json: plan.data, expectedRevision: 0)
        }
        await #expect(throws: RevisionHistoryFailure.planned) { try await session.deleteArchivedRevision(accountId: account, appId: app, revisionId: newer, expectedRevision: 2) }
        let intact = try await session.storeAccess { try $0.document(namespace: "revisions", key: key(newer)) != nil && $0.document(namespace: "drafts", key: key(newer)) != nil }
        #expect(intact)
    }

    @Test func legacyOwnerAndUnverifiableFilesFailClosed() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let lock = importMutex(root).deletingPathExtension()
        let legacy = JSONText.object([("id", .string(older)), ("pid", .number(Double(getpid()))), ("createdAt", .string("2000-01-01T00:00:00Z"))]).stringify()
        try JobLock.exclusive(lock, legacy)
        await #expect(throws: RevisionHistoryFailure.busy) { try await session.deleteArchivedRevision(accountId: account, appId: app, revisionId: newer, expectedRevision: 1) }
        #expect(try JobLock.privateFile(lock) == legacy)
        try FileManager.default.removeItem(at: lock)
        try JobLock.exclusive(lock, "invalid owner")
        await #expect(throws: JobLock.Failure.unverifiable) { try await session.deleteArchivedRevision(accountId: account, appId: app, revisionId: newer, expectedRevision: 1) }
        try FileManager.default.removeItem(at: lock)
        try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: root.appendingPathComponent("state-v2/storebench-v2.sqlite"))
        await #expect(throws: JobLock.Failure.unverifiable) { try await session.deleteArchivedRevision(accountId: account, appId: app, revisionId: newer, expectedRevision: 1) }
        try FileManager.default.removeItem(at: lock)
        let stopped = JSONText.object([("id", .string(older)), ("pid", .number(Double(getpid()))), ("protocol", .number(2))]).stringify()
        try JobLock.exclusive(lock, stopped)
        #expect(try await session.deleteArchivedRevision(accountId: account, appId: app, revisionId: newer, expectedRevision: 1))
        #expect(try JobLock.privateFile(lock) == stopped)
    }

    @Test func ownedProcessImportGateNeverExpiresAndCrashReleasesTheSameInode() async throws {
        let root = try TestIsolation.require().appendingPathComponent("history-lock-policy")
        let (session, _) = try DraftTests().session(directory: root)
        let mutex = importMutex(root), ready = root.appendingPathComponent("lock-ready"), release = root.appendingPathComponent("lock-release")
        let deadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: ready.path) {
            guard ContinuousClock.now < deadline else { Issue.record("Owned lock fixture did not become ready"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: mutex.path)
        let inode = try #require(FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber)
        await #expect(throws: RevisionHistoryFailure.busy) { try await session.deleteArchivedRevision(accountId: account, appId: app, revisionId: newer, expectedRevision: 1) }
        // Ask only the run-owned pure helper to exit without releasing its lock in Swift.
        try JobLock.exclusive(release, "interrupt")
        let releasedDeadline = ContinuousClock.now + .seconds(5)
        while true {
            if let probe = try FileMutex.tryLock(mutex) { probe.release(); break }
            guard ContinuousClock.now < releasedDeadline else { Issue.record("Owned fixture did not release its kernel lock after interruption"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await session.deleteArchivedRevision(accountId: account, appId: app, revisionId: newer, expectedRevision: 1))
        #expect(try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber == inode)
        #expect(try Data(contentsOf: mutex).isEmpty)
    }
}
