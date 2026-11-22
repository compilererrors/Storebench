import Foundation
import Testing
@testable import StorebenchCore

extension WorkspaceSession {
    func useRateLimitPauses(_ pauses: [Duration]) { rateLimitPauses = pauses }
}

@Suite(.serialized) struct PublishingRateLimitTests {
    init() throws { _ = try TestIsolation.require() }

    /// Counts the writes Apple turns away for its rate limit before it accepts one.
    private final class Refusals: @unchecked Sendable {
        private let lock = NSLock()
        private var left: Int
        init(_ count: Int) { left = count }
        func take() -> Bool { lock.withLock { if left > 0 { left -= 1; return true }; return false } }
    }

    private func approved(host: String, refusals: Int, retryAfter: String?) async throws -> (review: PublishReview, writes: Int) {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticApple(), app = "1000000001", refused = Refusals(refusals)
        StubProtocol.handle(host) { request in
            if request.httpMethod != "GET", refused.take() { return (429, retryAfter.map { ["Retry-After": $0] } ?? [:], Data()) }
            return apple.handle(request)
        }
        await session.useRateLimitPauses([.milliseconds(1), .milliseconds(1)])
        let client = try PublishingTests().client(account, host: host)
        let request = PublishRequest(accountId: account.id, appId: app, scope: .versionCopyright, versionId: "version-1", copyright: "2026 Synthetic Studio")
        let review = try await session.preparePublishing(account: account, request: request, client: client)
        let result = try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: client)
        // What Apple last said about a key's limit is kept for the whole process; the next ordinary answer ends it for later tests.
        let address = try #require(URL(string: "https://\(host)"))
        let ordinary = try #require(HTTPURLResponse(url: address, statusCode: 200, httpVersion: nil, headerFields: ["X-Rate-Limit": "user-hour-lim:3600;user-hour-rem:3600;"]))
        AppleRequestBudget.record(ordinary, keyId: account.keyId)
        return (result, StubProtocol.requests(host).filter { $0.httpMethod != "GET" }.count)
    }

    @Test func aStepTurnedAwayForTheRateLimitIsSentAgainAndTheReviewFinishes() async throws {
        let result = try await approved(host: "rate-limit-resend.appstoreconnect.test", refusals: 2, retryAfter: "0")
        #expect(result.review.state == "complete" && result.review.steps.allSatisfy { $0.state == "done" })
        #expect(result.writes == 3)
    }

    @Test func aStepWithoutANamedWaitUsesTheSessionsPauses() async throws {
        let result = try await approved(host: "rate-limit-fallback.appstoreconnect.test", refusals: 1, retryAfter: nil)
        #expect(result.review.state == "complete")
        #expect(result.writes == 2)
    }

    @Test func aRateLimitThatStaysStopsTheReviewAndSaysSo() async throws {
        let result = try await approved(host: "rate-limit-stays.appstoreconnect.test", refusals: 10, retryAfter: "0")
        #expect(result.review.state == "failed")
        #expect(result.review.error?.contains("hourly request limit") == true && result.review.error?.contains("Completed steps remain applied") == true)
        #expect(result.writes == 3)
    }

    @Test func aWaitLongerThanTheLimitStopsWithoutSendingAgain() async throws {
        let result = try await approved(host: "rate-limit-long.appstoreconnect.test", refusals: 10, retryAfter: "600")
        #expect(result.review.state == "failed")
        #expect(result.writes == 1)
    }
}
