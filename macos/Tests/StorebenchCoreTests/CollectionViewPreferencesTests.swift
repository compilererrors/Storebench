import Foundation
import Testing
@testable import StorebenchCore

struct CollectionViewPreferencesTests {
    init() throws { _ = try TestIsolation.require() }

    @Test(arguments: CollectionPresentation<Int>.openingLimits) func restoresPageDefaultsAndIndividualChoices(_ opening: Int) throws {
        let ids = Array(0..<45)
        var state = CollectionPresentation<Int>(pageSize: 20, openingLimit: opening)
        state.choosePage(2); state.setExpanded(22, true); state.setExpanded(24, false)
        let saved = try state.preferences(ids: ids, sort: "rating", descending: true)
        let decoded = try CollectionViewPreferences(json: saved.json)
        #expect(decoded == saved && decoded.sort == "rating" && decoded.descending)
        let restored = CollectionPresentation<Int>(preferences: decoded, ids: ids)
        #expect(restored.page(ids).number == 2 && restored.pageSize == 20 && restored.openingLimit == opening)
        #expect(restored.expanded(22, on: restored.page(ids)) && !restored.expanded(24, on: restored.page(ids)))
        let fewer = CollectionPresentation<Int>(preferences: decoded, ids: [0, 1])
        #expect(fewer.page([0, 1]).number == 1)
    }

    @Test func rejectsInvalidOrOversizedSavedOptions() throws {
        let valid = try CollectionViewPreferences()
        for (key, value) in [("page", JSONText.number(0)), ("pageSize", .number(11)), ("openingLimit", .number(9)), ("descending", .string("true")), ("sort", .string("invalid sort")), ("schemaVersion", .number(2))] {
            guard case .object(let fields) = valid.json else { throw CollectionViewPreferences.Failure.invalid }
            let changed = JSONText.object(fields.map { ($0.0, $0.0 == key ? value : $0.1) })
            #expect(throws: CollectionViewPreferences.Failure.invalid) { try CollectionViewPreferences(json: changed) }
        }
        #expect(throws: CollectionViewPreferences.Failure.invalid) { try CollectionViewPreferences(overrides: ["raw-record-id": true]) }
        let many = Dictionary(uniqueKeysWithValues: (0..<1025).map { (CollectionViewPreferences.key([String($0)]), true) })
        #expect(throws: CollectionViewPreferences.Failure.invalid) { try CollectionViewPreferences(overrides: many) }
        #expect(CollectionViewPreferences.key(["a", "bc"]) != CollectionViewPreferences.key(["ab", "c"]))
    }

    @Test func sessionsReopenTheirOwnViewsAndConcurrentWritersKeepOtherViews() async throws {
        let (first, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let second = try WorkspaceSession(workspace: Workspace(root: root), vault: await first.vault)
        let keys = (0..<20).map { CollectionViewPreferences.key(["synthetic-view", String($0)]) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, key) in keys.enumerated() {
                let owner = index.isMultiple(of: 2) ? first : second
                group.addTask { try await owner.saveCollectionViewPreference(key, value: CollectionViewPreferences(page: index + 1, pageSize: 5, openingLimit: index.isMultiple(of: 2) ? -1 : 0, sort: "date")) }
            }
            try await group.waitForAll()
        }
        let reopened = try WorkspaceSession(workspace: Workspace(root: root), vault: await first.vault)
        for (index, key) in keys.enumerated() {
            let saved = try #require(try await reopened.collectionViewPreference(key))
            #expect(saved.page == index + 1 && saved.pageSize == 5 && saved.sort == "date")
            #expect(saved.openingLimit == (index.isMultiple(of: 2) ? -1 : 0))
        }
        #expect(try await reopened.collectionViewPreference(CollectionViewPreferences.key(["other-synthetic-view"])) == nil)
        await #expect(throws: CollectionViewPreferences.Failure.invalid) { try await reopened.saveCollectionViewPreference("raw-view", value: CollectionViewPreferences()) }
    }
}
