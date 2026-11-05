import Foundation

/// Temporary exception explanations stay in the encrypted local draft.
public struct SandboxException: Sendable, Equatable {
    public var key, usage: String
    public init(key: String = "", usage: String = "") { self.key = key; self.usage = usage }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.json == rhs.json }
    var json: JSONText { .object([("key", .string(key)), ("usage", .string(usage))]) }
    public var clipboardText: String { "Entitlement key: \(key)\nUsage information: \(usage)" }

    public static func validate(_ input: [SandboxException]) throws -> [SandboxException] {
        guard input.count <= 20 else { throw PublishFailure.invalid("Too many App Sandbox exceptions.") }
        return try input.map { item in
            guard item.key.utf16.count <= 200, item.usage.utf16.count <= 4000,
                  !item.key.unicodeScalars.contains(where: { $0.value < 32 }), !item.usage.unicodeScalars.contains(where: { $0.value < 32 && ![9, 10, 13].contains($0.value) }) else {
                throw PublishFailure.invalid("Check App Sandbox exception key and usage.")
            }
            return SandboxException(key: TextSemantics.trim(item.key), usage: TextSemantics.trim(item.usage))
        }.filter { !$0.key.isEmpty || !$0.usage.isEmpty }
    }
    public static func decode(_ value: JSONText?) throws -> [SandboxException] {
        guard let value, value != .null else { return [] }
        guard case .array(let rows) = value, rows.count <= 20 else { throw PublishFailure.invalid("Too many App Sandbox exceptions.") }
        return try validate(rows.map { row in
            guard case .object = row, let key = row["key"]?.text, let usage = row["usage"]?.text else { throw PublishFailure.invalid("Check App Sandbox exception.") }
            return SandboxException(key: key, usage: usage)
        })
    }
}

public struct ReviewInformationLayout: Sendable, Equatable {
    public enum Section: String, Sendable { case access, sandbox }
    public var access = true
    public var sandbox = true
    public init() {}
    var json: JSONText { .object([("access", .bool(access)), ("sandbox", .bool(sandbox))]) }
    init(_ value: JSONText) throws {
        guard case .bool(let access)? = value["access"], case .bool(let sandbox)? = value["sandbox"] else { throw PublishFailure.invalid("Invalid App Review layout.") }
        self.access = access; self.sandbox = sandbox
    }
}

extension ReviewAttachment {
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.json == rhs.json }
    public static let maximumBytes = 50_000_000
    public static func validateUploadName(_ name: String) throws -> String {
        guard !name.isEmpty, name.utf16.count <= 200, !name.unicodeScalars.contains(where: { $0 == "/" || $0 == "\\" || $0.value < 32 }),
              name.contains("."), let ext = name.split(separator: ".", omittingEmptySubsequences: false).last.map(String.init)?.lowercased(), ["pdf", "png", "jpg", "jpeg", "mp4", "mov"].contains(ext) else {
            throw PublishFailure.invalid("Choose a PDF, PNG, JPEG, MP4 or MOV attachment up to 50 MB.")
        }
        return ext
    }
    var json: JSONText { .object([("hash", .string(hash)), ("fileName", .string(fileName)), ("extension", .string(ext)), ("size", .number(Double(size)))]) }
    static func decode(_ value: JSONText?) throws -> ReviewAttachment? {
        guard let value, value != .null else { return nil }
        guard case .object = value, let hash = value["hash"]?.text, hash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              let name = value["fileName"]?.text, !name.isEmpty, name.utf16.count <= 200, !name.unicodeScalars.contains(where: { $0 == "/" || $0 == "\\" || $0.value < 32 }),
              let ext = value["extension"]?.text, ext.range(of: "^[a-z0-9]{1,8}$", options: .regularExpression) != nil,
              case .number(let size)? = value["size"], size.isFinite, size.rounded(.towardZero) == size, size >= 1, size <= Double(maximumBytes) else {
            throw PublishFailure.invalid("Invalid App Review attachment.")
        }
        return ReviewAttachment(hash: hash, fileName: name, ext: ext, size: Int(size))
    }
}

extension ReviewInformation {
    static func decodeSaved(_ value: JSONText?) throws -> ReviewInformation {
        guard case .object? = value, limits.allSatisfy({ value?[$0.0]?.text != nil }), case .bool? = value?["demoAccountRequired"] else { throw PublishFailure.invalid("Invalid App Review draft.") }
        return try ReviewInformation(value).validated()
    }
    public var visibleJSON: JSONText {
        .object(Self.limits.filter { $0.0 != "demoAccountPassword" }.map { ($0.0, .string(value($0.0))) } + [("demoAccountRequired", .bool(demoAccountRequired)), ("demoPasswordSaved", .bool(!demoAccountPassword.isEmpty))])
    }
    var hiddenPassword: ReviewInformation { var value = self; value.demoAccountPassword = ""; return value }
}
