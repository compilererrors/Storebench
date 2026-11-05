import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct ReviewThemeTests {
    init() throws { _ = try TestIsolation.require() }
    let appId = "1000000001"
    func session() async throws -> (WorkspaceSession, Account, URL) { try await ReviewsJobTests().session() }
    func input(_ state: ReviewThemeState) throws -> ReviewThemeInput {
        let version = try #require(state.versions.first), row = try #require(state.snapshot?.reviews.first)
        return ReviewThemeInput(reviewIds: [row.id], revisionId: version.revisionId, versionId: version.versionId, theme: "Synthetic export requests", action: "Add an export option",
                                decision: "Plan for the chosen version", followUp: "Read feedback after release")
    }
    func put(_ session: WorkspaceSession, namespace: String, key: String, value: JSONText) async throws {
        try await session.storeAccess { store in try store.transaction { _ in [.put(namespace: namespace, key: key, json: value.data)] } }
    }
    func legacy(_ session: WorkspaceSession, account: Account) async throws {
        let value = try #require(try await session.savedReviewsFiles(account: account, appId: appId).snapshot)
        try await session.storeAccess { store in
            try store.transaction { _ in [.delete(namespace: "reviews_index", key: "\(account.id):\(appId)"), .delete(namespace: "reviews", key: "\(account.id):\(appId)")] }
            try store.transaction { _ in [.put(namespace: "reviews", key: "\(account.id):\(appId)", json: value.json.data)] }
        }
    }

    @Test func reviewedEvidenceSavesOnceAndEditsRequireAnotherReview() async throws {
        let (session, account, root) = try await session(); defer { try? FileManager.default.removeItem(at: root) }
        let initial = try await session.reviewThemes(account: account, appId: appId), input = try input(initial)
        let review = try await session.prepareReviewTheme(account: account, appId: appId, input: input, baseline: initial)
        let waiting = try await session.reviewThemes(account: account, appId: appId)
        #expect(waiting.themes.isEmpty && waiting.revision == initial.revision + 1)
        #expect(review.theme.evidence.map(\.id) == input.reviewIds && review.theme.decision == input.decision)
        await #expect(throws: ReviewThemeFailure.conflict) { try await session.prepareReviewTheme(account: account, appId: appId, input: input, baseline: initial) }
        let revision = try await session.saveReviewTheme(account: account, appId: appId, preparation: review)
        let saved = try await session.reviewThemes(account: account, appId: appId)
        #expect(saved.revision == revision && saved.themes.count == 1)
        #expect(saved.themes[0].evidence.map(\.json) == review.theme.evidence.map(\.json))
        await #expect(throws: ReviewThemeFailure.conflict) { try await session.saveReviewTheme(account: account, appId: appId, preparation: review) }
        var empty = input; empty.decision = " \u{feff} "
        await #expect(throws: ReviewThemeFailure.incomplete) { try await session.prepareReviewTheme(account: account, appId: appId, input: empty, baseline: saved) }
        var edit = input; edit.id = saved.themes[0].id; edit.followUp = "Compare ratings after two weeks"
        let changed = try await session.prepareReviewTheme(account: account, appId: appId, input: edit, baseline: saved)
        try await session.saveReviewTheme(account: account, appId: appId, preparation: changed)
        #expect(try await session.reviewThemes(account: account, appId: appId).themes.map(\.followUp) == [edit.followUp])
    }

    @Test func replacedLegacyWithTheSameCounterCannotConsumeOrRefreshAnOldBaseline() async throws {
        let (session, account, root) = try await session(); defer { try? FileManager.default.removeItem(at: root) }
        try await legacy(session, account: account)
        let state = try await session.reviewThemes(account: account, appId: appId), input = try input(state)
        let review = try await session.prepareReviewTheme(account: account, appId: appId, input: input, baseline: state), key = "\(account.id):\(appId)"
        let snapshot = try #require(state.snapshot), row = snapshot.reviews[0]
        let updated = try ReviewsSnapshot(accountId: account.id, appId: appId, checkedAt: snapshot.checkedAt, limited: snapshot.limited, reviews: [CustomerReview(id: row.id, rating: row.rating, title: row.title, body: "Changed synthetic feedback", createdDate: row.createdDate, territory: row.territory)])
        try await session.storeAccess { store in
            try store.transaction { _ in [.delete(namespace: "reviews", key: key)] }
            try store.transaction { _ in [.put(namespace: "reviews", key: key, json: updated.json.data)] }
            #expect(try store.document(namespace: "reviews", key: key)?.revision == 1)
        }
        let latest = try await session.reviewThemes(account: account, appId: appId)
        #expect(latest.themes.isEmpty && latest.snapshot?.reviews.first?.body == "Changed synthetic feedback")
        await #expect(throws: ReviewThemeFailure.conflict) { try await session.saveReviewTheme(account: account, appId: appId, preparation: review) }
        await #expect(throws: ReviewThemeFailure.conflict) { try await session.prepareReviewTheme(account: account, appId: appId, input: input, baseline: review.baseline) }
        let fresh = try await session.prepareReviewTheme(account: account, appId: appId, input: input, baseline: latest)
        try await session.saveReviewTheme(account: account, appId: appId, preparation: fresh)
    }

    @Test func anyReleaseChangeOrDeletionInvalidatesTheConcreteReview() async throws {
        for delete in [false, true] {
            let (session, account, root) = try await session(); defer { try? FileManager.default.removeItem(at: root) }
            let state = try await session.reviewThemes(account: account, appId: appId), input = try input(state)
            let review = try await session.prepareReviewTheme(account: account, appId: appId, input: input, baseline: state)
            try await session.storeAccess { store in
                let key = "\(account.id):\(appId):\(input.revisionId)", original = try #require(try store.document(namespace: "revisions", key: key))
                if delete { try store.transaction { _ in [.delete(namespace: "revisions", key: key)] } }
                else {
                    guard case .object(var fields) = try JSONText.parse(original.payload) else { throw ReviewThemeFailure.invalid }
                    fields.append(("syntheticRevisionNote", .string("Changed synthetic material outside the selected version")))
                    try store.transaction { _ in [.put(namespace: "revisions", key: key, json: JSONText.object(fields).data)] }
                }
            }
            await #expect(throws: ReviewThemeFailure.conflict) { try await session.saveReviewTheme(account: account, appId: appId, preparation: review) }
            await #expect(throws: ReviewThemeFailure.conflict) { try await session.prepareReviewTheme(account: account, appId: appId, input: input, baseline: review.baseline) }
        }
    }

    @Test func expiryAndReplacementRequireAnotherReviewWithoutChangingSavedThemes() async throws {
        let (session, account, root) = try await session(); defer { try? FileManager.default.removeItem(at: root) }
        let state = try await session.reviewThemes(account: account, appId: appId), input = try input(state), now = try #require(ASO.iso("2026-02-01T00:00:00.000Z"))
        let review = try await session.prepareReviewTheme(account: account, appId: appId, input: input, baseline: state, now: now)
        await #expect(throws: ReviewThemeFailure.conflict) { try await session.saveReviewTheme(account: account, appId: appId, preparation: review, now: now.addingTimeInterval(600)) }
        var changed = input; changed.decision = "Read new synthetic evidence"
        let replacement = try await session.prepareReviewTheme(account: account, appId: appId, input: changed, baseline: review.baseline, now: now)
        await #expect(throws: ReviewThemeFailure.conflict) { try await session.saveReviewTheme(account: account, appId: appId, preparation: review, now: now) }
        try await session.saveReviewTheme(account: account, appId: appId, preparation: replacement, now: now.addingTimeInterval(599))
        #expect(try await session.reviewThemes(account: account, appId: appId).themes.map(\.decision) == [changed.decision])
    }

    @Test func twoIndependentSessionsHaveOnePrepareWinnerAndOneSaveWinner() async throws {
        let (session, account, root) = try await session(); defer { try? FileManager.default.removeItem(at: root) }
        let vault = await session.vault, second = try WorkspaceSession(workspace: Workspace(root: root), vault: vault)
        let baseline = try await session.reviewThemes(account: account, appId: appId), input = try input(baseline)
        func attempt(_ target: WorkspaceSession) async throws -> ReviewThemePreparation? {
            do { return try await target.prepareReviewTheme(account: account, appId: appId, input: input, baseline: baseline) }
            catch ReviewThemeFailure.conflict { return nil }
        }
        async let a = attempt(session), b = attempt(second)
        let reviews = try await [a, b].compactMap { $0 }; #expect(reviews.count == 1)
        let review = try #require(reviews.first)
        func save(_ target: WorkspaceSession) async throws -> Bool {
            do { try await target.saveReviewTheme(account: account, appId: appId, preparation: review); return true }
            catch ReviewThemeFailure.conflict { return false }
        }
        async let x = save(session), y = save(second)
        #expect(try await [x, y].filter { $0 }.count == 1)
        #expect(try await session.reviewThemes(account: account, appId: appId).themes.count == 1)
    }

    @Test func foreignScopeAndCancellationKeepTheStoredReviewUnconsumed() async throws {
        let (session, account, root) = try await session(); defer { try? FileManager.default.removeItem(at: root) }
        let state = try await session.reviewThemes(account: account, appId: appId), input = try input(state)
        let review = try await session.prepareReviewTheme(account: account, appId: appId, input: input, baseline: state)
        await #expect(throws: ReviewThemeFailure.conflict) { try await session.saveReviewTheme(account: account, appId: "9999999999", preparation: review) }
        let cancelled = Task {
            while !Task.isCancelled { await Task.yield() }
            try await session.saveReviewTheme(account: account, appId: appId, preparation: review)
        }
        cancelled.cancel(); await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try await session.reviewThemes(account: account, appId: appId).themes.isEmpty)
        try await session.saveReviewTheme(account: account, appId: appId, preparation: review)
    }

    @Test func malformedEvidenceAndUnicodeChangesCannotBeHidden() async throws {
        let (session, account, root) = try await session(); defer { try? FileManager.default.removeItem(at: root) }
        let state = try await session.reviewThemes(account: account, appId: appId), input = try input(state)
        let review = try await session.prepareReviewTheme(account: account, appId: appId, input: input, baseline: state)
        let row = review.theme.evidence[0]
        for patch in [JSONText.object([("body", .string("\u{0000}"))]), .object([("createdDate", .string("2026-02-30T00:00:00.000Z"))]), .object([("id", .string("bad id"))])] {
            guard case .object(let changes) = patch, case .object(var fields) = row.json, case .object(var theme) = review.theme.json else { throw ReviewThemeFailure.invalid }
            for (key, value) in changes { if let i = fields.firstIndex(where: { $0.0 == key }) { fields[i].1 = value } }
            theme[theme.firstIndex(where: { $0.0 == "evidence" })!].1 = .array([.object(fields)])
            #expect(throws: ReviewThemeFailure.invalid) { try ReviewTheme(.object(theme)) }
        }
        var composed = input; composed.theme = "Synthetic café"
        var decomposed = composed; decomposed.theme = "Synthetic cafe\u{0301}"
        #expect(composed != decomposed)
        var tooLong = input; tooLong.followUp = String(repeating: "🎉", count: 501)
        #expect(throws: ReviewThemeFailure.incomplete) { try tooLong.validated() }
        let duplicated = ReviewThemeInput(reviewIds: [row.id, row.id], revisionId: input.revisionId, versionId: input.versionId, theme: input.theme, action: input.action, decision: input.decision, followUp: input.followUp)
        #expect(throws: ReviewThemeFailure.selection) { try duplicated.validated() }
    }

    @Test func reusedThemeCounterCannotConsumeAlteredPreparedDecisions() async throws {
        let (session, account, root) = try await session(); defer { try? FileManager.default.removeItem(at: root) }
        let state = try await session.reviewThemes(account: account, appId: appId), input = try input(state)
        let review = try await session.prepareReviewTheme(account: account, appId: appId, input: input, baseline: state), key = "\(account.id):\(appId)"
        try await session.storeAccess { store in
            let original = try JSONText.parse(try #require(try store.document(namespace: "review_themes", key: key)).payload)
            guard case .object(var fields) = original, let position = fields.firstIndex(where: { $0.0 == "prepared" }), case .object(var prepared) = fields[position].1 else { throw ReviewThemeFailure.invalid }
            prepared.append(("syntheticChange", .string("Changed synthetic prepared document"))); fields[position].1 = .object(prepared)
            try store.transaction { _ in [.delete(namespace: "review_themes", key: key)] }
            try store.transaction { _ in [.put(namespace: "review_themes", key: key, json: JSONText.object(fields).data)] }
            #expect(try store.document(namespace: "review_themes", key: key)?.revision == review.revision)
        }
        await #expect(throws: ReviewThemeFailure.conflict) { try await session.saveReviewTheme(account: account, appId: appId, preparation: review) }
    }

    @Test func themeCountAndSerializedEvidenceLimitAreEnforcedWithoutConsumingTheReview() async throws {
        let (session, account, root) = try await session(); defer { try? FileManager.default.removeItem(at: root) }
        let state = try await session.reviewThemes(account: account, appId: appId), input = try input(state)
        let example = try await session.prepareReviewTheme(account: account, appId: appId, input: input, baseline: state), key = "\(account.id):\(appId)"
        func theme(_ index: Int, evidence: [CustomerReview]) -> ReviewTheme {
            let item = example.theme
            return ReviewTheme(id: String(format: "00000000-0000-4000-8000-%012d", index), theme: item.theme, action: item.action, decision: item.decision, followUp: item.followUp,
                               revisionId: item.revisionId, versionId: item.versionId, versionLabel: item.versionLabel, evidence: evidence, snapshotCheckedAt: item.snapshotCheckedAt, limited: item.limited, savedAt: item.savedAt)
        }
        try await put(session, namespace: "review_themes", key: key, value: .object([("schemaVersion", .number(1)), ("themes", .array((0..<100).map { theme($0, evidence: example.theme.evidence).json }))]))
        let full = try await session.reviewThemes(account: account, appId: appId)
        await #expect(throws: ReviewThemeFailure.full) { try await session.prepareReviewTheme(account: account, appId: appId, input: input, baseline: full) }
        let row = example.theme.evidence[0], evidence = (0..<50).map { CustomerReview(id: "synthetic-evidence-\($0)", rating: 3, title: String(repeating: "S", count: 1000), body: String(repeating: "Synthetic text. ", count: 1000), createdDate: row.createdDate, territory: row.territory) }
        let snapshot = try ReviewsSnapshot(accountId: account.id, appId: appId, checkedAt: example.theme.snapshotCheckedAt, limited: false, reviews: evidence)
        try await session.storeAccess { store in
            try store.transaction { _ in [.delete(namespace: "reviews_index", key: key), .put(namespace: "reviews", key: key, json: snapshot.json.data),
                                          .put(namespace: "review_themes", key: key, json: JSONText.object([("schemaVersion", .number(1)), ("themes", .array((0..<9).map { theme($0, evidence: evidence).json }))]).data)] }
        }
        let baseline = try await session.reviewThemes(account: account, appId: appId); var large = input; large.reviewIds = evidence.map(\.id)
        let review = try await session.prepareReviewTheme(account: account, appId: appId, input: large, baseline: baseline)
        await #expect(throws: ReviewThemeFailure.full) { try await session.saveReviewTheme(account: account, appId: appId, preparation: review) }
        #expect(try await session.reviewThemes(account: account, appId: appId).themes.count == 9)
        #expect(try await session.pendingReviewTheme(account: account, appId: appId)?.token == review.token)
    }

    @Test func webPreparedReviewsCanBeReadAndConsumedInSwiftWithAllFiftyReviews() async throws {
        let fixture = try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/review-theme-vectors.json")))
        guard case .array(let vectors)? = fixture["vectors"] else { throw ReviewThemeFailure.invalid }
        #expect(ReviewThemeStorage.mutex("synthetic-account:\(appId)") == fixture["mutexName"]?.text)
        for vector in vectors {
            let (session, account, root) = try await session(); defer { try? FileManager.default.removeItem(at: root) }
            try await session.storeAccess { store in
                for namespace in ["reviews", "reviews_index", "reviews_part", "revisions", "review_themes"] {
                    try store.transaction { _ in try store.documents(namespace: namespace).map { .delete(namespace: namespace, key: $0.key) } }
                }
                guard case .array(let sources)? = vector["sources"] else { throw ReviewThemeFailure.invalid }
                try store.transaction { _ in sources.map { .put(namespace: $0["namespace"]!.text!, key: $0["key"]!.text!, json: $0["value"]!.data) } }
                try store.transaction { _ in [.put(namespace: "review_themes", key: "\(account.id):\(appId)", json: vector["document"]!.data)] }
            }
            let timestamp = try #require(vector["prepared"]?["review"]?["theme"]?["savedAt"]?.text), now = try #require(ASO.iso(timestamp))
            let review = try #require(try await session.pendingReviewTheme(account: account, appId: appId, now: now))
            #expect(review.json == vector["prepared"]?["review"] && review.theme.evidence.count == 50)
            #expect(review.theme.evidence.map(\.id) == review.theme.evidence.map(\.id).sorted())
            let revision = try await session.saveReviewTheme(account: account, appId: appId, preparation: review, now: now)
            let state = try await session.reviewThemes(account: account, appId: appId)
            #expect(revision == 2 && state.themes.first?.json == review.theme.json)
            #expect(try await session.pendingReviewTheme(account: account, appId: appId, now: now) == nil)
            var edit = try input(state); edit.id = review.theme.id; edit.reviewIds = review.theme.evidence.map(\.id)
            edit.theme = review.theme.theme; edit.action = review.theme.action; edit.decision = review.theme.decision; edit.followUp = review.theme.followUp
            let native = try await session.prepareReviewTheme(account: account, appId: appId, input: edit, baseline: state, now: now)
            #expect(native.theme.json == review.theme.json)
            try await session.storeAccess { store in
                let stored = try JSONText.parse(try #require(try store.document(namespace: "review_themes", key: "\(account.id):\(appId)")).payload)
                #expect(stored["prepared"]?["basis"] == vector["document"]?["prepared"]?["basis"])
                #expect(stored["prepared"]?["releaseBasis"] == vector["document"]?["prepared"]?["releaseBasis"])
            }
        }
    }
}

@Suite(.serialized) struct ReviewThemeProcessTests {
    init() throws { _ = try TestIsolation.require() }
    @Test(arguments: ["prepare", "save"], [true, false]) func waitingForAnOwnedProcessRechecksCancellationAndScope(action: String, cancel: Bool) async throws {
        let fixture = try ReviewsJobTests(), root = try TestIsolation.require().appendingPathComponent("review-theme-\(action)-\(cancel ? "cancel" : "scope")-policy")
        let (session, account, _) = try await fixture.session(directory: root), reader = try fixture.store(root)
        let (source, _, sourceRoot) = try await fixture.session(); defer { try? FileManager.default.removeItem(at: sourceRoot) }
        let baseline = try await source.reviewThemes(account: account, appId: fixture.appId), input = try ReviewThemeTests().input(baseline)
        let preparation = try await source.prepareReviewTheme(account: account, appId: fixture.appId, input: input, baseline: baseline)
        let key = "\(account.id):\(fixture.appId)"
        if action == "save" {
            let original = try await source.storeAccess { try #require(try $0.document(namespace: "review_themes", key: key)) }
            try reader.transaction { _ in [.put(namespace: "review_themes", key: key, json: original.payload)] }
        }
        let before = try reader.document(namespace: "review_themes", key: key), accounts = try #require(try reader.document(namespace: "accounts", key: "all"))
        let mutex = reader.directory.appendingPathComponent(ReviewThemeStorage.mutex(key)), inode = try #require(try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber)
        #expect(try FileMutex.tryLock(mutex) == nil)
        let ready = root.appendingPathComponent("save-ready"), operation = Task {
            try JobLock.exclusive(ready, "ready")
            if action == "prepare" { _ = try await session.prepareReviewTheme(account: account, appId: fixture.appId, input: input, baseline: baseline) }
            else { try await session.saveReviewTheme(account: account, appId: fixture.appId, preparation: preparation) }
        }
        try await fixture.wait { FileManager.default.fileExists(atPath: ready.path) }
        try await Task.sleep(for: .milliseconds(60))
        if cancel { operation.cancel() }
        else {
            let removed = Account(id: account.id, name: account.name, keyId: account.keyId, keyType: account.keyType, issuerId: account.issuerId, appIds: [], appNames: nil)
            try reader.transaction { _ in [.put(namespace: "accounts", key: "all", json: JSONText.array([WorkspaceSession.json(removed)]).data)] }
        }
        try JobLock.exclusive(root.appendingPathComponent("lock-release"), "interrupt")
        if cancel { await #expect(throws: CancellationError.self) { try await operation.value } }
        else { await #expect(throws: ReviewsFailure.scope) { try await operation.value } }
        #expect(try reader.document(namespace: "review_themes", key: key) == before)
        #expect(try FileManager.default.attributesOfItem(atPath: mutex.path)[.systemFileNumber] as? NSNumber == inode)
        try reader.transaction { _ in [.put(namespace: "accounts", key: "all", json: accounts.payload)] }
    }
}
