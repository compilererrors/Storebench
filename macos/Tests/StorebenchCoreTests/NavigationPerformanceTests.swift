import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) @MainActor struct NavigationPerformanceTests {
    init() throws { _ = try TestIsolation.require() }
    @Test func repeatedNavigationRetiresObserversAndWorkAndBoundsPresentationHistory() {
        let work = PresentationWork(), book = NavigationPresentation()
        var history = NavigationHistory("overview", limit: 100)
        var live = 0, disposed = 0
        for cycle in 0..<10_000 {
            let previous = work.generation, ticket = work.begin()
            #expect(!work.accepts(previous))
            for _ in 0..<5 { live += 1; work.own({ live -= 1; disposed += 1 }, ticket: ticket) }
            history.visit("synthetic-view-\(cycle % 7)")
            book.retain(history.entryIDs)
            book.save(CGPoint(x: 0, y: CGFloat(cycle)), for: history.currentID)
            book.saveCollection(cycle, key: "page", entry: history.currentID)
            #expect(work.resourceCount == 5 && live == 5)
            work.end(); work.end()
            #expect(work.resourceCount == 0 && live == 0 && !work.accepts(ticket))
            #expect(book.retainedEntryCount <= 100 && book.retainedCollectionCount <= 100)
        }
        #expect(disposed == 50_000)
    }
    @Test func lateRegistrationRetirementReentrancyAndDeallocationDisposeExactlyOnce() {
        var count = 0
        var work: PresentationWork? = PresentationWork()
        let old = work!.begin()
        work!.own({ count += 1 }, ticket: old)
        let next = work!.begin()
        #expect(count == 1)
        work!.own({ count += 1 }, ticket: old)
        #expect(count == 2 && work!.resourceCount == 0)
        work!.own({ count += 1 }, ticket: next)
        work = nil
        #expect(count == 3)
        let reentrant = PresentationWork(), ticket = reentrant.begin()
        reentrant.own({ reentrant.own({ count += 1 }, ticket: ticket) }, ticket: ticket)
        reentrant.end()
        #expect(count == 4 && reentrant.resourceCount == 0)
    }
    @Test func retiringHiddenPresentationCancelsOwnedTasksAndRejectsResourceAccumulation() async {
        let work = PresentationWork()
        for _ in 0..<100 {
            let ticket = work.begin()
            let task = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(30)) } catch { return Task.isCancelled }
                return false
            }
            work.own({ task.cancel() }, ticket: ticket)
            work.end()
            let cancelled = await task.value
            #expect(cancelled && work.resourceCount == 0 && !work.accepts(ticket))
        }
        let ticket = work.begin(); var rejected = 0
        for _ in 0..<100 { work.own({ rejected += 1 }, ticket: ticket) }
        #expect(work.resourceCount == 16 && rejected == 84)
        work.end(); #expect(rejected == 100)
    }
    @Test func libraryMetadataInvalidatesOnForeignCorruptionDeletionAndSessionLock() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let baseline = try await session.connectedApps()
        #expect(!baseline.isEmpty && baseline.contains { ($0.revisionCount ?? 0) > 0 })
        for _ in 0..<100 { #expect(try await session.connectedApps() == baseline) }
        let account = try #require(try await session.accounts().first)
        let other = try EncryptedDocumentStore(url: EncryptedDocumentStore.databaseURL(root: root), key: Data(0..<32), writable: true)
        let documents = try other.documents(namespace: "revisions", prefix: account.id + ":1000000001:")
        let document = try #require(documents.first)
        try other.transaction { _ in [.put(namespace: "revisions", key: document.key, json: Data("{}".utf8))] }
        #expect(try await session.connectedApps().first { $0.app.id == "1000000001" }?.revisionCount == nil)
        try other.transaction { _ in [.delete(namespace: "revisions", key: document.key)] }
        try other.transaction { _ in [.put(namespace: "revisions", key: document.key, json: document.payload)] }
        #expect(try await session.connectedApps() == baseline)
        try other.transaction { _ in [.delete(namespace: "revisions", key: document.key)] }
        let next = try await session.connectedApps().first { $0.app.id == "1000000001" }
        #expect(next?.revisionCount == documents.count - 1)
        try await session.signOut()
        await #expect(throws: (any Error).self) { try await session.connectedApps() }
    }
}
