import Foundation
import Testing
@testable import StorebenchCore

struct JSONEncodingTests {
    init() throws { _ = try TestIsolation.require() }
    @Test func numericJSONTextAndTypedFieldsPreserveValuesWithoutIntegerOverflow() throws {
        let data = try Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/json-number-encoding.json"))
        guard case .array(let cases) = try JSONText.parse(data) else { throw JSONText.ParseFailure.invalid }
        #expect(cases.count >= 5_000)
        for item in cases {
            guard case .number(let stored)? = item["value"] else { throw JSONText.ParseFailure.invalid }
            let number = item["negativeZero"] == .bool(true) ? -Double.zero : stored
            let text = try #require(item["text"]?.text), encoded = try #require(item["encoded"]?.text)
            #expect(JSONText.number(number) == encoded, "Synthetic number \(text)")
            #expect(JSONText.object([("value", .number(number))]).sha256 == item["digest"]?.text)
            #expect(FieldValue.number(number).text == text)
            #expect(WorkspaceSession.text(.number(number)) == text)
            #expect(try RevisionComparison.text(.number(number)) == text)
            #expect(try JSONDecoder().decode(FieldValue.self, from: Data(encoded.utf8)).text == text)
            #expect(try JSONText.parse(Data(encoded.utf8)).stringify() == encoded)
        }
        #expect(FieldValue.null.text == nil && WorkspaceSession.text(.null).isEmpty)
        #expect(FieldValue.text("e\u{301}").text?.utf8.elementsEqual("e\u{301}".utf8) == true)
        for value in [Double.nan, .infinity, -.infinity] {
            #expect(JSONText.number(value) == "null")
            #expect(FieldValue.number(value).text == nil && WorkspaceSession.text(.number(value)).isEmpty)
            #expect(throws: RevisionHistoryFailure.invalid) { try RevisionComparison.text(.number(value)) }
        }
    }

    @Test func utf8StringsPreserveControlsUnicodeAndLongText() throws {
        let data = try Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/json-string-encoding.json"))
        guard case .array(let cases) = try JSONText.parse(data) else { throw JSONText.ParseFailure.invalid }
        #expect(cases.count >= 270)
        for value in cases {
            let text = try #require(value["text"]?.text), expected = try #require(value["encoded"]?.text)
            let encoded = JSONText.string(text).stringify()
            #expect(encoded.utf8.elementsEqual(expected.utf8))
            #expect(try JSONText.parse(Data(encoded.utf8)).text?.utf8.elementsEqual(text.utf8) == true)
        }
        #expect(JSONText.string("é") != .string("e\u{301}"))
    }

    @Test func unescapedStringsRetainUnicodeAndRejectMalformedUTF8() throws {
        let text = "\u{FEFF}Synthetic é e\u{301} 😀"
        #expect(try JSONText.parse(Data(("\"" + text + "\"").utf8)).text?.utf8.elementsEqual(text.utf8) == true)
        let invalid: [[UInt8]] = [[0x80], [0xc0, 0xaf], [0xc3], [0xed, 0xa0, 0x80], [0xf4, 0x90, 0x80, 0x80], [0x0a]]
        for bytes in invalid {
            #expect(throws: JSONText.ParseFailure.self) { try JSONText.parse(Data([0x22] + bytes + [0x22])) }
        }
        #expect(throws: JSONText.ParseFailure.self) { try JSONText.parse(Data([0x22, 0x61])) }
        let mixed = try JSONText.parse(Data(#""Synthetic \uFEFF\u00e9 \ud83d\ude00""#.utf8))
        #expect(mixed.text?.utf8.elementsEqual("Synthetic \u{FEFF}é 😀".utf8) == true)
    }
}
