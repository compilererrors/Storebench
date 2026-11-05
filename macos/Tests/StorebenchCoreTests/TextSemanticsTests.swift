import Foundation
import Testing
@testable import StorebenchCore

@Suite struct TextSemanticsTests {
    init() throws { _ = try TestIsolation.require() }

    @Test func byteComparisonsPreserveLiteralUnicodeAndOptionalValues() {
        #expect(TextSemantics.same(nil, nil))
        #expect(!TextSemantics.same(nil, ""))
        #expect(TextSemantics.same("", ""))
        #expect(!TextSemantics.same("é", "e\u{301}"))
        #expect(!TextSemantics.same("a\u{0}b", "a"))
        for value in ["synthetic", "🧪 e\u{301} 👩‍💻", String(repeating: "x", count: 4096)] {
            #expect(TextSemantics.same(value, String(decoding: Data(value.utf8), as: UTF8.self)))
            #expect(!TextSemantics.same(value, value + "x"))
        }
    }

    @Test func storeTextIgnoresLineBreakStyleAndOuterWhitespaceButNotWording() {
        #expect(TextSemantics.sameStoreText("Fixes\r\n• Faster — search\r\n", "Fixes\n• Faster — search"))
        #expect(TextSemantics.sameStoreText("Line one  \rLine two\u{2028}Line three\t", "Line one\nLine two\nLine three"))
        #expect(TextSemantics.sameStoreText(" \u{feff}Synthetic\u{a0}\n\n", "Synthetic"))
        #expect(TextSemantics.sameStoreText("Synthetic\n\nParagraph", "Synthetic\r\n\r\nParagraph"))
        #expect(!TextSemantics.sameStoreText("Synthetic\n\nParagraph", "Synthetic\nParagraph"))
        #expect(!TextSemantics.sameStoreText("Faster — search", "Faster - search"))
        #expect(!TextSemantics.sameStoreText("é", "e\u{301}"))
        #expect(!TextSemantics.sameStoreText("Inner  space", "Inner space"))
        #expect(TextSemantics.sameStoreText(nil, nil) && !TextSemantics.sameStoreText(nil, ""))
    }

    @Test func orderedJSONEqualityMatchesSerializedBytesWithoutNormalizingOrReordering() {
        let values: [JSONText] = [.null, .bool(false), .bool(true), .number(0), .number(-0), .number(1), .number(.nan), .number(.infinity), .number(-.infinity),
            .string(""), .string("é"), .string("e\u{301}"), .string("\u{0}\\\""), .array([.number(.nan), .string("🧪")]), .array([.null, .string("🧪")]),
            .object([("first", .number(1)), ("second", .null)]), .object([("second", .null), ("first", .number(1))]),
            .object([("é", .null)]), .object([("e\u{301}", .null)]), .object([("first", .null), ("first", .bool(true))])]
        for lhs in values { for rhs in values {
            #expect((lhs == rhs) == lhs.stringify().utf8.elementsEqual(rhs.stringify().utf8))
        } }
    }

    @Test func controlValidationKeepsOnlyTheExistingASCIIRestrictions() {
        for code in 0...255 {
            let value = "Synthetic e\u{301} 🧪 " + String(UnicodeScalar(code)!)
            let previous = value.utf8.allSatisfy { $0 >= 32 && $0 != 127 || $0 == 9 || $0 == 10 || $0 == 13 }
            #expect(TextSemantics.validControlText(value) == previous)
        }
        #expect(TextSemantics.validControlText(String(repeating: "Synthetic 🧪\t\n\r", count: 1000)))
        #expect(!TextSemantics.validControlText(String(repeating: "Synthetic 🧪", count: 1000) + "\u{7f}"))
    }
}
