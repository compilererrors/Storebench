import Foundation
import Testing
@testable import StorebenchCore

@Suite struct TransferReviewPageTests {
    init() throws { _ = try TestIsolation.require() }
    @Test func allPagesAndCompleteUnicodeTextMatchThePrimaryComparison() throws {
        let fixture = try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/transfer-review.json")))
        guard case .array(let cases)? = fixture["cases"] else { throw TransferFailure.changed }
        #expect(cases.count == 72)
        for value in cases {
            guard case .array(let raw)? = value["changes"], case .number(let requested)? = value["page"] else { throw TransferFailure.changed }
            let changes = try raw.map { item in
                TransferChange(id: try #require(item["id"]?.text), label: try #require(item["label"]?.text), before: try #require(item["before"]?.text), after: try #require(item["after"]?.text))
            }
            let page = TransferReviewPage(changes: changes, page: Int(requested))
            let actual = JSONText.object([("pages", .number(Double(page.pages))), ("current", .number(Double(page.current))), ("shown", .array(page.changes.map {
                .object([("id", .string($0.id)), ("label", .string($0.label)), ("before", .string($0.before)), ("after", .string($0.after))])
            }))])
            #expect(actual == value["expected"])
            #expect(page.changes.count <= 8 && page.total == changes.count)
            let all = (1...page.pages).flatMap { TransferReviewPage(changes: changes, page: $0).changes }
            #expect(all == changes)
        }
    }
    @Test func extremePageNumbersRemainBoundedWithoutDroppingTheLastChange() {
        let changes = (0..<105).map { TransferChange(id: "synthetic-\($0)", label: "Synthetic field", before: "", after: "Synthetic imported text") }
        #expect(TransferReviewPage(changes: changes, page: Int.min).current == 1)
        #expect(TransferReviewPage(changes: changes, page: Int.max).changes.map(\.id) == ["synthetic-104"])
    }
}
