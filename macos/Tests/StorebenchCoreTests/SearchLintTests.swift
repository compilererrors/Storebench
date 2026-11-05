import Foundation
import Testing
@testable import StorebenchCore

@Suite struct SearchLintTests {
    init() throws { _ = try TestIsolation.require() }
    @Test func completeCleanupFindingsMatchTheActualPrimaryHelper() throws {
        let fixture = try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/search-lint.json")))
        guard case .array(let cases)? = fixture["cases"] else { throw DraftFailure.invalid }
        #expect(cases.count == 88)
        for row in cases {
            let input = try #require(row["keywords"]?.text)
            let result = SearchLint(input, name: row["title"]?["name"]?.text ?? "", subtitle: row["title"]?["subtitle"]?.text ?? "")
            #expect(result.json == row["expected"], "Synthetic keyword input: \(input)")
            #expect(result.freedBytes >= 0)
        }
    }
}
