import Foundation
import Testing
@testable import StorebenchCore

struct PublishingBatchTests {
    init() throws { _ = try TestIsolation.require() }

    private func media(_ key: String, kind: PublishStep.Kind = .api, method: String? = nil, path: [JSONText], guardKind: String,
                       group: String? = nil, body: JSONText? = nil) -> PublishStep {
        PublishStep(key: key, group: group, label: "Synthetic media", detail: "", before: nil, after: nil, kind: kind, method: method, path: path, body: body, asset: nil,
                    guardValue: .object([("kind", .string(guardKind)), ("asset", .string(key))]), state: "pending", resultId: nil)
    }
    private func pipeline(_ index: Int) -> [PublishStep] {
        let key = "reserve-\(index)", path: [JSONText] = [.string("appAssetLibraryImages"), Apple.ref(key)]
        return [media(key, method: "POST", path: [.string("appAssetLibraryImages")], guardKind: "release-media-reserve", group: key),
                media("upload-\(index)", kind: .upload, path: path, guardKind: "release-media-upload", group: key),
                media("commit-\(index)", method: "PATCH", path: path, guardKind: "release-media-upload", group: key, body: .object([("id", Apple.ref(key))]))]
    }

    @Test func mediaPipelinesShareBoundedWavesAndKeepEveryFilesDependencies() {
        var steps = (0..<6).flatMap(pipeline), ids: [String: String] = [:]
        #expect(WorkspaceSession.stepsReadyTogether(steps, from: 0, ids: ids) == [0, 3, 6, 9])
        for index in [0, 3, 6, 9] { steps[index].state = "done"; ids[steps[index].key] = "synthetic-\(index)" }
        #expect(WorkspaceSession.stepsReadyTogether(steps, from: 1, ids: ids) == [1, 4, 7, 10])
        // Knowing a reservation ID never makes its commit ready before the bytes are uploaded.
        #expect(WorkspaceSession.stepsReadyTogether(steps, from: 2, ids: ids) == [2])
        for index in [1, 4, 7, 10] { steps[index].state = "done" }
        #expect(WorkspaceSession.stepsReadyTogether(steps, from: 2, ids: ids) == [2, 5, 8, 11])
        for index in [2, 5, 8, 11] { steps[index].state = "done" }
        #expect(WorkspaceSession.stepsReadyTogether(steps, from: 12, ids: ids) == [12, 15])
        #expect(WorkspaceSession.stepsReadyTogether(steps, from: 13, ids: ids) == [13])
    }

    @Test func removalsAndPlacementsNeverShareAWaveOrPassTheOrderingBarrier() {
        let removals = (0..<6).map { media("delete-\($0)", method: "DELETE", path: [.string("appAssetLibraryPlacements"), .string("synthetic-\($0)")], guardKind: "release-media-delete") }
        let placements = (0..<6).map { media("place-\($0)", method: "POST", path: [.string("appAssetLibraryPlacements")], guardKind: "release-media-placement",
            body: .object([("data", .object([("relationships", .object([("image", Apple.relationship("appAssetLibraryImages", .string("synthetic-\($0)")))]))]))])) }
        let order = media("order", method: "POST", path: [.string("appAssetLibraryPlacementOrderingRequests")], guardKind: "release-media-order")
        let steps = removals + placements + [order]
        #expect(WorkspaceSession.stepsReadyTogether(steps, from: 0, ids: [:]) == [0, 1, 2, 3])
        #expect(WorkspaceSession.stepsReadyTogether(steps, from: 4, ids: [:]) == [4, 5])
        #expect(WorkspaceSession.stepsReadyTogether(steps, from: 6, ids: [:]) == [6, 7, 8, 9])
        #expect(WorkspaceSession.stepsReadyTogether(steps, from: 10, ids: [:]) == [10, 11])
        #expect(WorkspaceSession.stepsReadyTogether(steps, from: 12, ids: [:]) == [12])
    }

    @Test func duplicatePlacementsAreNeverScheduledConcurrently() {
        let remove = media("remove", method: "DELETE", path: [.string("appAssetLibraryPlacements"), .string("same-id")], guardKind: "release-media-delete")
        #expect(WorkspaceSession.stepsReadyTogether([remove, remove], from: 0, ids: [:]) == [0])
        let body = JSONText.object([("data", .object([("relationships", .object([("image", Apple.relationship("appAssetLibraryImages", .string("same-image")))]))]))])
        let add = media("add", method: "POST", path: [.string("appAssetLibraryPlacements")], guardKind: "release-media-placement", body: body)
        #expect(WorkspaceSession.stepsReadyTogether([add, add], from: 0, ids: [:]) == [0])
    }

    @Test func processingWaitsShareAWaveButDoNotPassTheFirstRemoval() {
        let checks = (0..<6).map { media("check-\($0)", kind: .verify, path: [.string("appAssetLibraryImages"), .string("synthetic-\($0)")], guardKind: "asset-library-processed") }
        let remove = media("remove", method: "DELETE", path: [.string("appAssetLibraryPlacements"), .string("old")], guardKind: "release-media-delete")
        #expect(WorkspaceSession.stepsReadyTogether(checks + [remove] + checks, from: 0, ids: [:]) == Array(0..<6))
        #expect(WorkspaceSession.stepsReadyTogether(checks + [remove] + checks, from: 4, ids: [:]) == [4, 5])
    }

    @Test func aWholeScreenshotSetsProcessingStartsWithoutWaitingForTheFirstFour() {
        let checks = (0..<12).map { media("check-\($0)", kind: .verify, path: [.string("appAssetLibraryImages"), .string("synthetic-\($0)")], guardKind: "asset-library-processed") }
        #expect(WorkspaceSession.stepsReadyTogether(checks, from: 0, ids: [:]) == Array(0..<10))
        #expect(WorkspaceSession.publishingBatchLimit(checks[0]) == 10)
        #expect(WorkspaceSession.publishingBatchLimit(pipeline(0)[0]) == 4)
    }

    @Test func progressDistinguishesParallelUploadsFromWaitingForApple() {
        var steps = (0..<10).map { media("check-\($0)", kind: .verify, path: [.string("appAssetLibraryImages"), .string("synthetic-\($0)")], guardKind: "asset-library-processed") }
        for index in steps.indices { steps[index].state = "running" }
        var review = PublishReview(plan: .init(title: "Synthetic processing", request: .init(accountId: "synthetic-account", appId: "1000000001", scope: .metadata), fingerprint: "synthetic-progress", steps: steps, notes: []), id: "synthetic-progress-review", now: Date())
        review.state = "running"
        #expect(PublishingReviewPresentation.activity(review).contains("Waiting for Apple · 10 files processing"))
        review.steps[0].state = "done"
        #expect(PublishingReviewPresentation.activity(review).contains("9 files processing · 1 of 10 steps complete"))
        review.steps = pipeline(0) + pipeline(1)
        review.steps[1].state = "running"; review.steps[4].state = "running"
        #expect(PublishingReviewPresentation.activity(review).contains("Uploading · 2 jobs in parallel"))
        review.steps[2] = media("remove", method: "DELETE", path: [.string("appAssetLibraryPlacements"), .string("synthetic-old")], guardKind: "release-media-delete")
        #expect(PublishingReviewPresentation.removals(review).map(\.key) == [review.steps[2].key])
    }
}
