import Foundation

struct LocalSessionKey {
    let key: String
    init(_ value: JSONText) throws {
        guard case .object = value, value["version"] == .number(1), let text = value["key"]?.text,
              text.range(of: #"\A[A-Za-z0-9_-]{43}\z"#, options: .regularExpression) != nil,
              let bytes = try? Base64URL.decode(text, length: 32), Base64URL.encode(bytes) == text else { throw SessionFailure.revocation }
        key = text
    }
    static func fresh() throws -> Self {
        var bytes = try Setup.random(32); defer { bytes.resetBytes(in: 0..<bytes.count) }
        return try Self(.object([("version", .number(1)), ("key", .string(Base64URL.encode(bytes)))]))
    }
    var json: JSONText { .object([("version", .number(1)), ("key", .string(key))]) }
}
