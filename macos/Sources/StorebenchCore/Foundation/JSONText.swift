import CryptoKit
import Foundation

/// JSON with ordered object keys and deterministic number and string encoding.
/// Report buckets are fingerprinted with that output, so every write must produce identical bytes.
public indirect enum JSONText: Equatable, Sendable {
    case object([(String, JSONText)]), array([JSONText]), string(String), number(Double), bool(Bool), null

    public static func == (lhs: JSONText, rhs: JSONText) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case (.bool(let a), .bool(let b)): return a == b
        case (.string(let a), .string(let b)): return TextSemantics.same(a, b)
        case (.number(let a), .number(let b)): return a == b || !a.isFinite && !b.isFinite
        case (.null, .number(let value)), (.number(let value), .null): return !value.isFinite
        case (.array(let a), .array(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0 == $1 }
        case (.object(let a), .object(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { TextSemantics.same($0.0, $1.0) && $0.1 == $1.1 }
        default: return false
        }
    }

    public func stringify() -> String {
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .number(let value): return Self.number(value)
        case .string(let value): return Self.quote(value)
        case .array(let values): return "[" + values.map { $0.stringify() }.joined(separator: ",") + "]"
        case .object(let pairs): return "{" + pairs.map { Self.quote($0.0) + ":" + $0.1.stringify() }.joined(separator: ",") + "}"
        }
    }

    public var data: Data { Data(stringify().utf8) }
    public var sha256: String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func number(_ value: Double) -> String {
        TextSemantics.number(value) ?? "null"
    }

    static func quote(_ text: String) -> String {
        if !text.utf8.contains(where: { $0 < 0x20 || $0 == 34 || $0 == 92 }) { return "\"" + text + "\"" }
        // UTF-8 continuation bytes cannot be JSON's ASCII escapes. Copy them verbatim.
        var output: [UInt8] = [34]
        output.reserveCapacity(text.utf8.count + 2)
        let hex = Array("0123456789abcdef".utf8)
        for byte in text.utf8 {
            switch byte {
            case 34, 92: output.append(92); output.append(byte)
            case 8: output.append(contentsOf: [92, 98])
            case 12: output.append(contentsOf: [92, 102])
            case 10: output.append(contentsOf: [92, 110])
            case 13: output.append(contentsOf: [92, 114])
            case 9: output.append(contentsOf: [92, 116])
            case 0..<32: output.append(contentsOf: [92, 117, 48, 48, hex[Int(byte >> 4)], hex[Int(byte & 15)]])
            default: output.append(byte)
            }
        }
        output.append(34)
        return String(decoding: output, as: UTF8.self)
    }
}

extension JSONText {
    public enum ParseFailure: Error { case invalid }

    /// Parses JSON while preserving object key order for deterministic document serialization.
    public static func parse(_ data: Data) throws -> JSONText {
        var parser = Parser(bytes: Array(data))
        let value = try parser.value()
        parser.space()
        guard parser.index == parser.bytes.count else { throw ParseFailure.invalid }
        return value
    }

    public subscript(key: String) -> JSONText? {
        // Share the ordered-key search across callers in the size-optimized core.
        @inline(never) get {
            guard case .object(let pairs) = self else { return nil }
            return pairs.last { $0.0 == key }?.1
        }
    }

    public var text: String? { if case .string(let value) = self { value } else { nil } }

    struct Parser {
        let bytes: [UInt8]
        var index = 0, depth = 0

        mutating func space() { while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 } }

        mutating func value() throws -> JSONText {
            space()
            guard index < bytes.count else { throw ParseFailure.invalid }
            switch bytes[index] {
            case UInt8(ascii: "{"):
                depth += 1; defer { depth -= 1 }
                guard depth <= 512 else { throw ParseFailure.invalid }
                index += 1; var pairs: [(String, JSONText)] = []
                space()
                if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(pairs) }
                while true {
                    space()
                    let key = try string()
                    space()
                    guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw ParseFailure.invalid }
                    index += 1
                    // A repeated key keeps its first position and its last value.
                    let item = try value()
                    if let existing = pairs.firstIndex(where: { $0.0 == key }) { pairs[existing].1 = item } else { pairs.append((key, item)) }
                    space()
                    guard index < bytes.count else { throw ParseFailure.invalid }
                    if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                    guard bytes[index] == UInt8(ascii: "}") else { throw ParseFailure.invalid }
                    index += 1; return .object(pairs)
                }
            case UInt8(ascii: "["):
                depth += 1; defer { depth -= 1 }
                guard depth <= 512 else { throw ParseFailure.invalid }
                index += 1; var items: [JSONText] = []
                space()
                if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
                while true {
                    items.append(try value())
                    space()
                    guard index < bytes.count else { throw ParseFailure.invalid }
                    if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                    guard bytes[index] == UInt8(ascii: "]") else { throw ParseFailure.invalid }
                    index += 1; return .array(items)
                }
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            default:
                let start = index
                while index < bytes.count, "+-0123456789.eE".utf8.contains(bytes[index]) { index += 1 }
                guard let text = String(bytes: bytes[start..<index], encoding: .ascii),
                      text.range(of: #"^-?(0|[1-9]\d*)(\.\d+)?([eE][+-]?\d+)?$"#, options: .regularExpression) != nil, let number = Double(text) else { throw ParseFailure.invalid }
                return .number(number)
            }
        }

        mutating func literal(_ word: String) throws {
            let expected = Array(word.utf8)
            guard index + expected.count <= bytes.count, Array(bytes[index..<index + expected.count]) == expected else { throw ParseFailure.invalid }
            index += expected.count
        }

        mutating func string() throws -> String {
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw ParseFailure.invalid }
            index += 1
            let start = index
            // Unescaped strings need no intermediate UTF-16 array. Validate UTF-8,
            // then decode without Foundation removing a leading BOM.
            while index < bytes.count {
                let byte = bytes[index]
                guard byte >= 0x20 else { throw ParseFailure.invalid }
                if byte == UInt8(ascii: "\\") { index = start; break }
                if byte == UInt8(ascii: "\"") {
                    let raw = bytes[start..<index]
                    guard String(bytes: raw, encoding: .utf8) != nil else { throw ParseFailure.invalid }
                    index += 1
                    return String(decoding: raw, as: UTF8.self)
                }
                index += 1
            }
            var units: [UInt16] = []
            var raw: [UInt8] = []
            func flush() throws {
                if !raw.isEmpty {
                    // Foundation validates UTF-8 but removes a leading BOM. JSON string values must retain it.
                    guard String(bytes: raw, encoding: .utf8) != nil else { throw ParseFailure.invalid }
                    units += Array(String(decoding: raw, as: UTF8.self).utf16); raw = []
                }
            }
            while index < bytes.count {
                let byte = bytes[index]
                if byte == UInt8(ascii: "\"") {
                    index += 1; try flush()
                    return String(decoding: units, as: UTF16.self)
                }
                guard byte >= 0x20 else { throw ParseFailure.invalid }
                if byte == UInt8(ascii: "\\") {
                    try flush()
                    index += 1
                    guard index < bytes.count else { throw ParseFailure.invalid }
                    let escape = bytes[index]; index += 1
                    switch escape {
                    case UInt8(ascii: "\""): units.append(0x22)
                    case UInt8(ascii: "\\"): units.append(0x5C)
                    case UInt8(ascii: "/"): units.append(0x2F)
                    case UInt8(ascii: "b"): units.append(0x08)
                    case UInt8(ascii: "f"): units.append(0x0C)
                    case UInt8(ascii: "n"): units.append(0x0A)
                    case UInt8(ascii: "r"): units.append(0x0D)
                    case UInt8(ascii: "t"): units.append(0x09)
                    case UInt8(ascii: "u"):
                        guard index + 4 <= bytes.count, let hex = String(bytes: bytes[index..<index + 4], encoding: .ascii), let unit = UInt16(hex, radix: 16) else { throw ParseFailure.invalid }
                        units.append(unit); index += 4
                    default: throw ParseFailure.invalid
                    }
                } else { raw.append(byte); index += 1 }
            }
            throw ParseFailure.invalid
        }
    }
}

/// Saved as its own JSON text and parsed with the same limits when read back.
extension JSONText: Codable {
    public init(from decoder: Decoder) throws { self = try JSONText.parse(Data(try decoder.singleValueContainer().decode(String.self).utf8)) }
    public func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(stringify()) }
}
