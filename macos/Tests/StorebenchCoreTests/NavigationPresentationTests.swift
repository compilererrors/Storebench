import Foundation
import Testing
@testable import StorebenchCore

@Suite struct NavigationPresentationTests {
    init() throws { _ = try TestIsolation.require() }
    @Test func repeatedDestinationsHaveDistinctPositionsAndCancelledNavigationKeepsTheEntry() throws {
        var history = NavigationHistory("overview", limit: 3)
        let original = history.currentID
        history.visit("prices"); let prices = history.currentID
        history.visit("overview"); #expect(history.currentID != original)
        let cancelled = try #require(history.request(.back))
        #expect(history.current == "overview" && history.currentID != prices)
        let accepted = history.commit(cancelled); #expect(accepted); #expect(history.currentID == prices)
        let first = try #require(history.request(.back)), returned = history.commit(first); #expect(returned); #expect(history.currentID == original)
        history.visit("languages"); #expect(history.entryIDs.count == 2 && !history.entryIDs.contains(prices))
        history.visit("assets"); history.visit("reports"); #expect(!history.entryIDs.contains(original))
    }
    @MainActor @Test func savedReadsReachTheNextWindow() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        struct Value: Codable, Equatable { let names: [String] }
        let first = NavigationPresentation()
        first.persist = { key, data, date, epoch in Task { await session.saveViewRead(key: key, data: data, readAt: date, epoch: epoch) } }
        first.preload([:], epoch: await session.viewReadEpoch, clearCount: first.clearCount)
        first.remember(Value(names: ["Synthetic"]), read: "synthetic/saved")
        first.remember(["synthetic", "list"] as [String], read: "synthetic/plain")
        // Saving runs in the background; wait for both reads to reach the database.
        let deadline = ContinuousClock.now + .seconds(5)
        while await session.savedViewReads().count < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        await session.saveViewRead(key: "synthetic/saved", data: try JSONEncoder().encode(Value(names: ["Synthetic"])), readAt: Date(), epoch: await session.viewReadEpoch)
        // A new window, as after a relaunch, shows the saved value before reading again.
        let next = NavigationPresentation()
        next.preload(await session.savedViewReads(), epoch: await session.viewReadEpoch, clearCount: next.clearCount)
        #expect(next.remembered(read: "synthetic/saved", as: Value.self)?.value == Value(names: ["Synthetic"]))
        #expect(next.remembered(read: "synthetic/missing", as: Value.self) == nil)
        #expect(await session.savedViewReads().keys.sorted() == ["synthetic/plain", "synthetic/saved"])
    }
    @Test func lateContentRestoresTheExactOffsetAndUserInputCancelsPendingRestoration() {
        var state = ScrollRestoration(CGPoint(x: 40, y: 1520))
        let resolution1 = state.resolve(content: CGSize(width: 1000, height: 400), viewport: CGSize(width: 800, height: 600))
        #expect(resolution1 == nil)
        #expect(state.target?.y == 1520)
        let resolution2 = state.resolve(content: CGSize(width: 1000, height: 2300), viewport: CGSize(width: 800, height: 600))
        #expect(resolution2 == CGPoint(x: 40, y: 1520))
        let resolution3 = state.resolve(content: CGSize(width: 1000, height: 4000), viewport: CGSize(width: 800, height: 600))
        #expect(resolution3 == nil)
        state = ScrollRestoration(CGPoint(x: 0, y: 4000)); state.cancel()
        let resolution4 = state.resolve(content: CGSize(width: 1000, height: 8000), viewport: CGSize(width: 800, height: 600))
        #expect(resolution4 == nil)
    }
    @Test func changedContentAndInvalidOffsetsClampOnlyAfterWaitingFinishes() {
        var state = ScrollRestoration(CGPoint(x: CGFloat.infinity, y: 4000))
        let resolution5 = state.resolve(content: CGSize(width: 700, height: 800), viewport: CGSize(width: 800, height: 600), finishedWaiting: true)
        #expect(resolution5 == CGPoint(x: 0, y: 200))
        var empty = ScrollRestoration(CGPoint(x: -10, y: CGFloat.nan))
        let resolution6 = empty.resolve(content: .zero, viewport: CGSize(width: 800, height: 600))
        #expect(resolution6 == .zero)
    }
    @Test func pageAndExpansionSnapshotsRetainExactPresentationWithoutRetainingEditors() {
        let ids = Array(1...67)
        var original = CollectionPresentation<Int>(pageSize: 20, openingLimit: 0)
        original.choosePage(3); original.setExpanded(44, true); original.setExpanded(43, false)
        var restored = original; restored.reconcile(ids)
        #expect(restored == original && restored.page(ids).number == 3)
        #expect(restored.expanded(44, on: restored.page(ids)) && !restored.expanded(43, on: restored.page(ids)))
    }
    @MainActor @Test func historyMemoryPreservesSeparateVisitsAndRejectsLateWritesAfterBranchPruning() {
        let store = NavigationPresentation(), first = UUID(), repeated = UUID()
        store.retain([first, repeated])
        store.save(CGPoint(x: 0, y: 1520), for: first); store.save(CGPoint(x: 0, y: 400), for: repeated)
        store.saveCollection(true, key: "synthetic-card/sync", entry: first)
        store.saveCollection(false, key: "synthetic-card/sync", entry: repeated)
        #expect(store.offset(first).y == 1520 && store.offset(repeated).y == 400)
        #expect(store.collection("synthetic-card/sync", entry: first, as: Bool.self) == true)
        #expect(store.collection("synthetic-card/sync", entry: repeated, as: Bool.self) == false)
        store.retain([repeated])
        store.save(CGPoint(x: 0, y: 9000), for: first)
        store.saveCollection(true, key: "synthetic-late-disclosure", entry: first)
        #expect(store.count == 1 && store.offset(first) == .zero)
        #expect(store.collection("synthetic-card/sync", entry: repeated, as: Bool.self) == false)
    }
    @MainActor @Test func aFullPageOfExpandedSourcesFitsWhileHistoryMemoryRemainsBounded() {
        let store = NavigationPresentation(), entry = UUID(); store.retain([entry])
        for index in 0..<600 { store.saveCollection(true, key: "synthetic-source-\(index)", entry: entry) }
        #expect(store.collection("synthetic-source-399", entry: entry, as: Bool.self) == true)
        #expect(store.collection("synthetic-source-511", entry: entry, as: Bool.self) == true)
        #expect(store.collection("synthetic-source-512", entry: entry, as: Bool.self) == nil)
        store.saveCollection(false, key: "synthetic-source-399", entry: entry)
        #expect(store.collection("synthetic-source-399", entry: entry, as: Bool.self) == false)
    }
    @MainActor @Test func rememberedReadsShowTheLastResultAcrossEntriesAndStayBounded() {
        let store = NavigationPresentation(), read = Date(timeIntervalSince1970: 1_800_000_000)
        store.remember(["synthetic-build-2", "synthetic-build-1"], read: "testflight-builds/synthetic-account/1000000001", at: read)
        store.retain([UUID()])
        let builds = store.remembered(read: "testflight-builds/synthetic-account/1000000001", as: [String].self)
        #expect(builds?.value == ["synthetic-build-2", "synthetic-build-1"] && builds?.readAt == read)
        #expect(store.remembered(read: "testflight-builds/synthetic-account/1000000001", as: Int.self) == nil)
        #expect(store.remembered(read: "testflight-builds/synthetic-account/1000000002", as: [String].self) == nil)
        for index in 0..<(NavigationPresentation.readLimit + 5) { store.remember(index, read: "synthetic-read-\(index)") }
        #expect(store.rememberedReadCount == NavigationPresentation.readLimit)
        #expect(store.remembered(read: "testflight-builds/synthetic-account/1000000001", as: [String].self) == nil)
        #expect(store.remembered(read: "synthetic-read-\(NavigationPresentation.readLimit + 4)", as: Int.self)?.value == NavigationPresentation.readLimit + 4)
        store.remember(1, read: "synthetic-read-0"); store.remember(2, read: "synthetic-read-0")
        #expect(store.remembered(read: "synthetic-read-0", as: Int.self)?.value == 2 && store.rememberedReadCount == NavigationPresentation.readLimit)
    }

    @Test func theAgeOfAShownReadIsWrittenOutAndReadingAgainIsNamed() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        #expect(ReadAge.text(readAt: nil, now: now, reading: false).isEmpty)
        #expect(ReadAge.text(readAt: nil, now: now, reading: true) == "Reading App Store Connect…")
        #expect(ReadAge.text(readAt: now.addingTimeInterval(-20), now: now, reading: false) == "Last read just now")
        #expect(ReadAge.text(readAt: now.addingTimeInterval(-60), now: now, reading: true) == "Last read 1 minute ago · Reading again…")
        #expect(ReadAge.text(readAt: now.addingTimeInterval(-7_300), now: now, reading: false) == "Last read 2 hours ago")
        #expect(ReadAge.text(readAt: now.addingTimeInterval(-3 * 86_400), now: now, reading: false) == "Last read 3 days ago")
        // A clock that moved back never shows a negative age.
        #expect(ReadAge.text(readAt: now.addingTimeInterval(120), now: now, reading: false) == "Last read just now")
    }

    @MainActor @Test func aSavedReadDecodedAwayFromTheMainThreadIsKeptAndNotRestoredAfterClearCache() async throws {
        let window = NavigationPresentation()
        let data = try JSONEncoder().encode(["synthetic": [1, 2, 3]]), at = Date(timeIntervalSince1970: 2_000_000_000)
        window.preload(["synthetic/large": (data, at)], epoch: 1, clearCount: window.clearCount)
        let decoded = await window.rememberedDecoded(read: "synthetic/large", as: [String: [Int]].self)
        #expect(decoded?.value == ["synthetic": [1, 2, 3]] && decoded?.readAt == at)
        #expect(window.remembered(read: "synthetic/large", as: [String: [Int]].self)?.value == ["synthetic": [1, 2, 3]])
        window.clearReads()
        #expect(await window.rememberedDecoded(read: "synthetic/large", as: [String: [Int]].self) == nil)
    }
}
