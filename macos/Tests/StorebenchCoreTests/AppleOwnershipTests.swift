import Testing
@testable import StorebenchCore

@Suite struct AppleOwnershipTests {
    init() throws { _ = try TestIsolation.require() }
    private func locale(_ relation: JSONValue?) -> AppStoreConnectClient.Resource {
        .init(type: "appStoreVersionLocalizations", id: "synthetic-locale", attributes: ["locale": .string("en-GB")], relationships: relation.map { ["appStoreVersion": $0] })
    }
    @Test func listsReadThroughTheirParentAcceptLinksOnlyButNeverAnotherParent() {
        let links = locale(.object(["links": .object(["related": .string("synthetic")])]))
        let same = locale(.object(["data": .object(["type": .string("appStoreVersions"), "id": .string("version-1")])]))
        let other = locale(.object(["data": .object(["type": .string("appStoreVersions"), "id": .string("version-2")])]))
        #expect(Apple.within(links, "appStoreVersion", "appStoreVersions", "version-1") && Apple.within(locale(nil), "appStoreVersion", "appStoreVersions", "version-1"))
        #expect(Apple.within(same, "appStoreVersion", "appStoreVersions", "version-1") && !Apple.within(other, "appStoreVersion", "appStoreVersions", "version-1"))
        #expect(!Apple.owned(links, "appStoreVersion", "appStoreVersions", "version-1"))
    }
    private func item(_ type: String, _ id: String, _ relations: [String: JSONValue], attributes: [String: JSONValue] = [:]) -> AppStoreConnectClient.Resource {
        .init(type: type, id: id, attributes: attributes, relationships: relations)
    }
    private func data(_ type: String, _ id: String) -> JSONValue { .object(["data": .object(["type": .string(type), "id": .string(id)])]) }
    private let links = JSONValue.object(["links": .object(["related": .string("synthetic")])])

    @Test func appReviewAttachmentsAndBetaReviewsReadThroughTheirParentAcceptLinksOnly() throws {
        let attachment = item("appStoreReviewAttachments", "synthetic-attachment", ["appStoreReviewDetail": links])
        #expect(try ReviewInformation.scopedAttachments([attachment], detailId: "detail-1").count == 1)
        #expect(throws: PublishFailure.self) { try ReviewInformation.scopedAttachments([item("appStoreReviewAttachments", "synthetic-attachment", ["appStoreReviewDetail": data("appStoreReviewDetails", "detail-2")])], detailId: "detail-1") }
        try TestFlightBetaReview.submissions([item("betaAppReviewSubmissions", "synthetic-review", ["build": links])], buildId: "build-1")
        #expect(throws: PublishFailure.self) { try TestFlightBetaReview.submissions([item("betaAppReviewSubmissions", "synthetic-review", ["build": data("builds", "build-2")])], buildId: "build-1") }
    }
    @Test func cancellationAcceptsALinksOnlySubmissionButStillNeedsTheIncludedVersion() throws {
        let submission = item("reviewSubmissions", "submission-1", ["app": links], attributes: ["state": .string("WAITING_FOR_REVIEW"), "platform": .string("IOS")])
        let included = item("reviewSubmissionItems", "item-1", ["reviewSubmission": links, "appStoreVersion": data("appStoreVersions", "version-1")], attributes: ["state": .string("READY_FOR_REVIEW")])
        #expect(!(try WorkspaceSession.cancellationDigest(submission, items: [included], appId: "1000000001", versionId: "version-1")).isEmpty)
        let unknown = item("reviewSubmissionItems", "item-1", ["reviewSubmission": links, "appStoreVersion": links])
        #expect(throws: PublishFailure.self) { try WorkspaceSession.cancellationDigest(submission, items: [unknown], appId: "1000000001", versionId: "version-1") }
        let otherApp = item("reviewSubmissions", "submission-1", ["app": data("apps", "1000000002")], attributes: ["state": .string("WAITING_FOR_REVIEW")])
        #expect(throws: PublishFailure.self) { try WorkspaceSession.cancellationDigest(otherApp, items: [included], appId: "1000000001", versionId: "version-1") }
    }
}
