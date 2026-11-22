import Foundation
import Testing
@testable import StorebenchApp
@testable import StorebenchCore

@Suite struct ReviewComparisonTableTests {
    init() throws { _ = try TestIsolation.require() }

    @Test func aLongKeyedChangeBecomesOneRowPerItemWithNowAndAfterSideBySide() throws {
        let before = "AFG: 9.99 USD · Now → ongoing\nAUS: 14.99 AUD · Now → ongoing\nSWE: 99 SEK · Now → ongoing\nUSA: 4.99 USD · Now → ongoing"
        let after = "AFG: 4.99 USD · Now → ongoing\nAUS: 14.99 AUD · Now → ongoing\nSWE: 49 SEK · Now → before 2026-12-01\nSWE: 39 SEK · 2026-12-01 → ongoing\nUSA: 4.99 USD · Now → ongoing"
        let rows = try #require(ReviewComparisonTable.rows(before: before, after: after))
        #expect(rows.map(\.id) == ["AFG", "AUS", "SWE", "USA", "SWE (2)"])
        #expect(rows.first { $0.id == "AFG" }?.after == "4.99 USD · Now → ongoing" && rows.first { $0.id == "AFG" }?.changed == true)
        #expect(rows.first { $0.id == "AUS" }?.changed == false, "Unchanged countries are kept and filtered, not dropped")
        #expect(rows.first { $0.id == "SWE (2)" }?.now == "—", "A line only Apple will have after the change has no value now")
        #expect(rows.first { $0.id == "AFG" }?.name.hasSuffix("· AFG") == true)
    }

    @Test func shortOrFreeTextChangesKeepTheSideBySideText() {
        #expect(ReviewComparisonTable.rows(before: "Old subtitle", after: "New subtitle") == nil)
        #expect(ReviewComparisonTable.rows(before: "USA: 4.99 USD", after: "USA: 5.99 USD") == nil, "A one-line change needs no table")
    }
}
