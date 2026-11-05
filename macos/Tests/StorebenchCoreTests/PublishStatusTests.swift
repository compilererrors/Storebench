import Darwin
import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct PublishStatusTests {
    init() throws { _ = try TestIsolation.require() }
    struct Fixture {
        let session: WorkspaceSession, root: URL, account: Account, review: PublishReview, apple: SyntheticApple
        var owner: URL { root.appendingPathComponent("state-v2/publishing_" + JSONText.string("\(account.id)\u{0}1000000001").rawSHA256.prefix(48) + ".lock") }
        var mutex: URL { owner.appendingPathExtension("mutex") }
    }
    func fixture() async throws -> Fixture {
        let (session, root) = try DraftTests().session(), account = try #require(try await session.accounts().first)
        let host = "publish-status-\(UUID().uuidString.lowercased()).appstoreconnect.test", apple = SyntheticApple()
        StubProtocol.handle(host) { apple.handle($0) }
        let client = try PublishingTests().client(account, host: host)
        var review = try await session.preparePublishing(account: account, request: PublishRequest(accountId: account.id, appId: "1000000001", scope: .versionCopyright, versionId: "version-1", copyright: "2026 Synthetic Studio"), client: client)
        review.state = "running"
        #expect(try await session.savePublishReview(review, expected: 1) == 2)
        return Fixture(session: session, root: root, account: account, review: review, apple: apple)
    }
    func status(_ f: Fixture) async throws -> PublishReview { try await f.session.publishStatus(accountId: f.account.id, appId: "1000000001", id: f.review.id) }
    func saved(_ f: Fixture) async throws -> EncryptedDocumentStore.Document? {
        try await f.session.storeAccess { try $0.document(namespace: "publish_reviews", key: "\(f.account.id):1000000001:\(f.review.id)") }
    }
    @Test func anUnheldProtocolTwoOwnerIsRecoveredOnceWithoutReplayingAppleWrites() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try JobLock.exclusive(f.owner, #"{"id":"00000000-0000-4000-8000-000000000099","pid":\#(getpid()),"protocol":2}"#)
        let initial = try #require(try FileMutex.tryLock(f.mutex)); initial.release()
        var before = stat(); #expect(lstat(f.mutex.path, &before) == 0)
        let recovered = try await status(f); #expect(recovered.state == "failed" && recovered.error != nil)
        let once = try await saved(f); #expect(once?.revision == 3)
        #expect(try await status(f).state == "failed"); #expect(try await saved(f) == once)
        var after = stat(); #expect(lstat(f.mutex.path, &after) == 0 && before.st_ino == after.st_ino && after.st_size == 0)
        #expect(f.apple.writes.isEmpty)
    }
    @Test func liveLegacyOwnerAndHeldKernelLockAreNeverExpiredByAnOldTimestamp() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try JobLock.exclusive(f.owner, #"{"id":"00000000-0000-4000-8000-000000000099","pid":\#(getpid())}"#)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: f.owner.path)
        let before = try await saved(f)
        #expect(try await status(f).state == "running"); #expect(try await saved(f) == before)
        let held = try #require(try FileMutex.tryLock(f.mutex)); defer { held.release() }
        try FileManager.default.removeItem(at: f.owner)
        #expect(try await status(f).state == "running"); #expect(try await saved(f) == before)
        #expect(f.apple.writes.isEmpty)
    }
    @Test func unverifiableOwnerCannotChangeRunningReviewOrMutexIdentity() async throws {
        for mode in 0..<7 {
            let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
            let raw: String
            switch mode {
            case 0: raw = "malformed"
            case 1: raw = #"{"id":"00000000-0000-4000-8000-000000000099","pid":0,"protocol":2}"#
            case 2: raw = #"{"id":"00000000-0000-4000-8000-000000000099","pid":1,"protocol":3}"#
            case 3: raw = String(repeating: "a", count: 32_001)
            default: raw = #"{"id":"00000000-0000-4000-8000-000000000099","pid":1,"protocol":2}"#
            }
            if mode == 4 { try FileManager.default.createSymbolicLink(at: f.owner, withDestinationURL: EncryptedDocumentStore.databaseURL(root: f.root)) }
            else if mode == 6 { #expect(link(EncryptedDocumentStore.databaseURL(root: f.root).path, f.owner.path) == 0) }
            else { try JobLock.exclusive(f.owner, raw) }
            if mode == 5 { try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: f.owner.path) }
            let held = try #require(try FileMutex.tryLock(f.mutex)); held.release()
            var first = stat(); #expect(lstat(f.mutex.path, &first) == 0)
            let before = try await saved(f)
            await #expect(throws: JobLock.Failure.unverifiable) { try await status(f) }
            #expect(try await saved(f) == before)
            var last = stat(); #expect(lstat(f.mutex.path, &last) == 0 && first.st_ino == last.st_ino && last.st_size == 0)
            #expect(f.apple.writes.isEmpty)
        }
    }
}
