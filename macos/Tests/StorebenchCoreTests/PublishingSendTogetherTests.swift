import Foundation
import Testing
@testable import StorebenchCore

struct PublishingSendTogetherTests {
    init() throws { _ = try TestIsolation.require() }

    private func step(_ method: String, _ path: [JSONText], body: JSONText? = nil, guardValue: JSONText? = nil) -> PublishStep {
        PublishStep(key: "step", group: nil, label: "Synthetic", detail: "", before: nil, after: nil, kind: .api, method: method, path: path, body: body, asset: nil, guardValue: guardValue, state: "pending", resultId: nil)
    }
    private func text(_ root: String, _ id: String) -> PublishStep {
        step("PATCH", [.string(root), .string(id)], body: .object([("data", .object([("type", .string(root)), ("id", .string(id)), ("attributes", .object([("description", .string("Synthetic"))]))]))]))
    }
    private func price(_ subscription: String, _ territory: String) -> PublishStep {
        step("POST", [.string("subscriptionPrices")], body: .object([("data", .object([("type", .string("subscriptionPrices"))]))]),
             guardValue: .object([("kind", .string("pricing-setup")), ("action", .string("subscription-prices")), ("territory", .string(territory)), ("subscriptionId", .string(subscription))]))
    }

    @Test func textUpdatesToExistingLanguagesAndPricesAcrossSubscriptionsGoTogether() {
        let steps = [text("appStoreVersionLocalizations", "loc-1"), text("appStoreVersionLocalizations", "loc-2"), text("appInfoLocalizations", "info-1"),
                     price("sub-1", "USA"), price("sub-2", "SWE"), step("POST", [.string("reviewSubmissions")])]
        #expect(WorkspaceSession.stepsSentTogether(steps, from: 0) == 0..<2)
        #expect(WorkspaceSession.stepsSentTogether(steps, from: 2) == 2..<3)
        #expect(WorkspaceSession.stepsSentTogether(steps, from: 3) == 3..<5)
        #expect(WorkspaceSession.stepsSentTogether(steps, from: 5) == 5..<6)
    }

    @Test func stepsThatUseAnEarlierResultOrChangeRelationshipsStayInOrder() {
        let reference = step("PATCH", [.string("appStoreVersionLocalizations"), .object([("$ref", .string("step-1"))])],
                             body: .object([("data", .object([("type", .string("appStoreVersionLocalizations"))]))]))
        let relinked = step("PATCH", [.string("appInfoLocalizations"), .string("info-1")],
                            body: .object([("data", .object([("type", .string("appInfoLocalizations")), ("id", .string("info-1")), ("relationships", .object([]))]))]))
        let guarded = step("PATCH", [.string("appStoreVersionLocalizations"), .string("loc-3")],
                           body: .object([("data", .object([("type", .string("appStoreVersionLocalizations")), ("id", .string("loc-3"))]))]), guardValue: .object([("kind", .string("synthetic"))]))
        for single in [reference, relinked, guarded] {
            #expect(WorkspaceSession.stepsSentTogether([single, text("appStoreVersionLocalizations", "loc-1")], from: 0) == 0..<1)
        }
    }
}
