import Foundation
import Testing
@testable import StorebenchCore

struct ReleaseMediaProgressTests {
    init() throws { _ = try TestIsolation.require() }

    func step(_ key: String, _ kind: PublishStep.Kind, _ guardKind: String, file: String, state: String, after: String? = nil) -> JSONText {
        let asset = JSONText.object([("fileName", .string(file))])
        var guardValue: [(String, JSONText)] = [("kind", .string(guardKind))]
        if guardKind.hasPrefix("release-media-re") || guardKind == "release-media-upload" { guardValue.append(("asset", asset)) }
        if guardKind == "asset-library-processed" { guardValue.append(("fileName", .string(file))) }
        var fields: [(String, JSONText)] = [("key", .string(key)), ("label", .string(key)), ("detail", .string("")), ("kind", .string(kind.rawValue)), ("path", .array([])), ("guard", .object(guardValue)), ("state", .string(state))]
        if let after { fields.append(("after", .string(after))) }
        return .object(fields)
    }
    func review(_ state: String, _ steps: [JSONText], settled: [String] = []) throws -> PublishReview {
        let request = PublishRequest(accountId: "account-1", appId: "1000000001", scope: .versionCopyright, versionId: "version-1", copyright: "2026 Synthetic Studio")
        return try #require(PublishReview(.object([("id", .string("review-1")), ("title", .string("Publish material")), ("fingerprint", .string("f")), ("createdAt", .string("2026-01-01T00:00:00Z")),
                                                   ("expiresAt", .string("2026-01-01T01:00:00Z")), ("updatedAt", .string("2026-01-01T00:00:00Z")), ("request", request.json), ("state", .string(state)), ("steps", .array(steps)), ("settled", .array(settled.map(JSONText.string)))])))
    }
    func steps(_ file: String, upload: String, processed: String, placed: String) -> [JSONText] {
        [step("\(file)-reserve", .api, "release-media-reserve", file: file, state: upload), step("\(file)-put", .upload, "release-media-upload", file: file, state: upload),
         step("\(file)-verify", .verify, "asset-library-processed", file: file, state: processed), step("\(file)-place", .api, "release-media-placement", file: "", state: placed, after: file)]
    }

    @Test func eachFileSaysWhetherItIsInAssetLibraryAndOnTheVersion() throws {
        let saved = try review("failed", steps("01-a.png", upload: "done", processed: "done", placed: "done") + steps("02-b.png", upload: "done", processed: "failed", placed: "pending")
                                + steps("03-c.png", upload: "pending", processed: "pending", placed: "pending")
                                + [step("reused-place", .api, "release-media-placement", file: "", state: "pending", after: "04-d.png"), step("order", .api, "release-media-order", file: "", state: "pending")])
        let progress = try #require(ReleaseMediaProgress(saved))
        #expect(progress.files.map(\.name) == ["01-a.png", "02-b.png", "03-c.png", "04-d.png"])
        #expect(progress.files.map(progress.status) == ["Added to this version", "In Asset Library · Apple had not finished processing it", "Not uploaded", "In Asset Library · not added to this version yet"])
        #expect(progress.summary == "3 of 4 files in Asset Library · 1 of 4 added to this version")
        #expect(progress.completed == 6 && progress.total == 14 && progress.stopped)
    }

    @Test func filesAppleAlreadyHasShowAsDoneWithoutASentStep() throws {
        let prepared = try #require(ReleaseMediaProgress(try review("prepared", [step("02-place", .api, "release-media-placement", file: "", state: "pending", after: "02-b.png")], settled: ["01-a.png"])))
        #expect(prepared.files.map(\.name) == ["02-b.png", "01-a.png"])
        #expect(prepared.files.map(prepared.status) == ["In Asset Library · add to this version", "Already in App Previews and Screenshots"])
        #expect(prepared.files.map(prepared.done) == [false, true])
        #expect(prepared.summary == "0 files to upload · 1 to add to App Previews and Screenshots · 1 already added")
        // A review with nothing to send for any file still shows them all as done.
        let settledOnly = try #require(ReleaseMediaProgress(try review("prepared", [], settled: ["01-a.png"])))
        #expect(settledOnly.files.map(settledOnly.done) == [true] && settledOnly.total == 0)
    }

    @Test func aRunningSaveShowsTheStageEachFileIsIn() throws {
        let progress = try #require(ReleaseMediaProgress(try review("running", steps("01-a.png", upload: "done", processed: "running", placed: "pending") + steps("02-b.png", upload: "pending", processed: "pending", placed: "pending"))))
        #expect(progress.files.map(progress.status) == ["In Asset Library · Apple is processing it…", "Waiting to upload"])
        #expect(!progress.stopped)
    }

    @Test func reviewsWithoutMediaHaveNoUploadProgress() throws {
        #expect(ReleaseMediaProgress(try review("complete", [])) == nil)
    }

    @Test func transferSpeedFollowsTheBytesSentInTheLastSeconds() {
        final class Clock: @unchecked Sendable { var now: TimeInterval = 100 }
        let clock = Clock(), transfer = PublishTransfer(clock: { clock.now })
        #expect(transfer.snapshot() == nil)
        transfer.begin("07-pricing.png", total: 4_000_000)
        clock.now = 101; transfer.sending(1_000_000)
        clock.now = 102; transfer.partFinished(2_000_000)
        let snapshot = transfer.snapshot()
        #expect(snapshot?.sent == 2_000_000 && snapshot?.bytesPerSecond == 1_000_000)
        #expect(snapshot?.text == "07-pricing.png · 2 MB of 4 MB · 1 MB/s")
        transfer.end(); #expect(transfer.snapshot() == nil)
    }
}
