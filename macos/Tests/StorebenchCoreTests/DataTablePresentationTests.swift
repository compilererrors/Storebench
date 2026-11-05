import Foundation
import Testing
@testable import StorebenchCore

@Suite struct DataTablePresentationTests {
    init() throws { _ = try TestIsolation.require() }
    @Test func unknownFactsRemainLastAndTiesPreserveSourceOrderInBothDirections() {
        let rows: [(String, Double?)] = [("unknown", nil), ("ten", 10), ("two", 2), ("tie", 2), ("zero", 0), ("negative", -3), ("invalid", .infinity)]
        func sorted(_ descending: Bool) -> [String] { DataTablePresentation.sorted(rows, descending: descending) { $0.1.map { .number($0) } ?? .unknown }.map { $0.0 } }
        #expect(sorted(false) == ["negative", "zero", "two", "tie", "ten", "unknown", "invalid"])
        #expect(sorted(true) == ["ten", "two", "tie", "zero", "negative", "unknown", "invalid"])
    }
    @Test func moneySortingUsesExactDecimalAmountsAndSeparateCurrencies() {
        let rows = [("EUR", "2.01"), ("USD", "10.00"), ("EUR", "2.001"), ("USD", "2.00")]
        let result = DataTablePresentation.sorted(rows, descending: true) { .money(Decimal(string: $0.1)!, currency: $0.0) }
        #expect(result.map { $0.0 + $0.1 } == ["EUR2.01", "EUR2.001", "USD10.00", "USD2.00"])
        let names = DataTablePresentation.sorted(["Version 10", "Version 2", "Version 1"], descending: false) { .text($0) }
        #expect(names == ["Version 1", "Version 2", "Version 10"])
    }
    @Test func longTextAndActionsKeepAssignedTracksAtAllWindowSizes() {
        let minimum: [Double] = [72, 168, 128, 160, 112, 144, 104, 244]
        for available in [0.0, 320, 440, 768, 1132, 1440, 1920, 2560, Double.nan] {
            let widths = DataTablePresentation.widths(available: available, minimum: minimum, weights: [0, 2, 1, 2, 1, 1, 1, 0])
            #expect(widths.count == 8 && zip(widths, minimum).allSatisfy { $0 >= $1 })
            #expect(abs(widths.reduce(0, +) - max(available.isFinite ? available : 0, 1132)) < 0.0001)
            #expect(widths[7] >= 244 && widths[0] == 72)
        }
    }
    @Test func singleLineTablesKeepControlTracksAndCompleteInspectionValues() {
        let original = "China Mainland\nSynthetic territory\n\nOriginal amount: 123.456 USD"
        #expect(DataTablePresentation.compactText(original) == "China Mainland · Synthetic territory · Original amount: 123.456 USD")
        #expect(original.contains("\n\n"))
        for lines in [0, 1, 2, 3, 4, 30] {
            #expect(ComponentLayout.tableRowHeight(lines: lines) == DataTablePresentation.rowHeight)
        }
        #expect(DataTablePresentation.rowHeight >= StorebenchDesign.shared.number("control-height") + 8)
        for width in [-100.0, 64, 144, 320, 1000, .infinity, .nan] {
            let resized = DataTablePresentation.resizedWidth(width)
            #expect(resized.isFinite && (64...800).contains(resized))
        }
    }
}
