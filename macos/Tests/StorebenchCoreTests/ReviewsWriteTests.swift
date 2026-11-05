import CryptoKit
import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct ReviewsWriteTests {
    init() throws { _ = try TestIsolation.require() }
    @Test func jsonTextUsesDeterministicEncoding() throws {
        let review = CustomerReview(id: "r1", rating: 5, title: "Quote \" and \\ backslash", body: "Line\nbreak\ttab \u{01} ctrl å ä ö 🎉 </script>", createdDate: "2026-01-04T10:00:00.000Z", territory: "SWE")
        let text = JSONText.array([review.json])
        #expect(text.stringify() == #"[{"id":"r1","rating":5,"title":"Quote \" and \\ backslash","body":"Line\nbreak\ttab \u0001 ctrl å ä ö 🎉 </script>","createdDate":"2026-01-04T10:00:00.000Z","territory":"SWE"}]"#)
        #expect(text.sha256 == "ea895b8c4e70697a9b48ce22dd2b37c13dd7cb8d0bb1d0ff2c0c9955822ac8b3")
        #expect(JSONText.string("synthetic-account\u{0}1000000001").rawSHA256.prefix(32) == "737aafe803b67bf149c7cd40283a8cb6")
        #expect(try CustomerReview.isoDate("2026-01-04T12:00:00+02:00") == "2026-01-04T10:00:00.000Z")
        #expect(try JSONText.parse(JSONText.string("\u{feff}").data).text == "\u{feff}")
        #expect(JSONText.string("é") != JSONText.string("e\u{0301}"))
        #expect(!TextDrafts.sameFields(["description": "é"], ["description": "e\u{0301}"]))
    }

    @Test func downloadedReviewsMergeIntoTheSavedHistory() async throws {
        let root = (try TestIsolation.require()).appendingPathComponent("storebench-reviews-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("state-v2"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.copyItem(at: try SyntheticFixtures.database(), to: EncryptedDocumentStore.databaseURL(root: root))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: EncryptedDocumentStore.databaseURL(root: root).path)
        let key = Data(0..<32).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let record = #"{\"schemaVersion\":1,\"phase\":\"ready\",\"envelope\":{\"version\":1,\"mode\":\"device\",\"key\":\"\#(key)\"}}"#
        let vault = try CredentialVault(json: Data(#"{"version":1,"entries":{"\#(CredentialVault.databaseEntry(root: root))":"\#(record)"}}"#.utf8))
        let session = try WorkspaceSession(workspace: Workspace(root: root), vault: vault)
        let account = try #require(try await session.accounts().first)

        // A synthetic Apple: review-2 changed its title, review-3 is new, review-1 is no longer returned but stays saved.
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubProtocol.self]
        StubProtocol.handle("reviews.appstoreconnect.test") { request in
            #expect(request.url!.path == "/v1/apps/1000000001/customerReviews")
            let body: [String: Any] = ["data": [
                ["type": "customerReviews", "id": "review-3", "attributes": ["rating": 4, "title": "Synthetic new", "body": "New synthetic review.", "createdDate": "2026-03-01T08:00:00-08:00", "territory": "GBR", "reviewerNickname": "never stored"]],
                ["type": "customerReviews", "id": "review-2", "attributes": ["rating": 3, "title": "Synthetic idea, edited", "body": "Could add more synthetic options.", "createdDate": "2026-02-02T10:00:00Z", "territory": "SWE"]],
            ], "links": [:]]
            return (200, [:], try! JSONSerialization.data(withJSONObject: body))
        }
        let client = AppStoreConnectClient(token: try AppleToken(account: account, privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation),
                                           origin: URL(string: "https://reviews.appstoreconnect.test")!, configuration: configuration)
        let changes = try await session.downloadReviews(account: account, appId: "1000000001", client: client, now: Date(timeIntervalSince1970: 1_772_400_000))
        #expect(changes == ReviewChanges(added: 1, updated: 1, unchanged: 0, limited: false))

        let saved = try await session.reviews(accountId: account.id, appId: "1000000001")
        #expect(saved.map(\.id) == ["review-3", "review-2", "review-1"])
        #expect(saved[0].createdDate == "2026-03-01T16:00:00.000Z" && saved[1].title == "Synthetic idea, edited")
        let meta = try await session.reviewsMeta(accountId: account.id, appId: "1000000001")
        #expect(meta?["limited"] == .bool(false) && meta?["fullCheckedAt"]?.string == meta?["checkedAt"]?.string)
        // Each bucket document matches the fingerprint its index names, as every reader verifies.
        try await session.verifyBuckets(family: "reviews", accountId: account.id, appId: "1000000001")
    }
}
