import CryptoKit
import Foundation
import zlib

public struct FastlaneImport: Sendable, Equatable {
    public let table: Delimited.Table, files, ignored, clears: Int, omitted, locales: [String]
}

public struct FastlanePreview: Sendable, Equatable {
    public let archive: FastlaneImport, transfer: TransferPreview
}

/// Fastlane text archives with their supported fields, byte limits and ZIP integrity rules.
/// Entries are read in memory; archive paths never become filesystem paths.
public enum FastlaneMetadata {
    static let fields = [("description", "version", "description"), ("keywords", "version", "keywords"),
                         ("promotional_text", "version", "promotionalText"), ("release_notes", "version", "whatsNew"),
                         ("support_url", "version", "supportUrl"), ("marketing_url", "version", "marketingUrl"),
                         ("name", "appInfo", "name"), ("subtitle", "appInfo", "subtitle"), ("privacy_url", "appInfo", "privacyPolicyUrl")]
    static let maximumEntries = 500, maximumExpanded = 2_000_000

    static func crc(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(data.count))) }
    }

    static func inflateRaw(_ data: Data, limit: Int) throws -> Data {
        var stream = z_stream(), result = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw TransferFailure.invalid("The ZIP file could not be expanded.") }
        defer { inflateEnd(&stream) }
        let status = data.withUnsafeBytes { input -> Int32 in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress); stream.avail_in = uInt(data.count)
            var code = Z_OK
            while code == Z_OK {
                code = buffer.withUnsafeMutableBufferPointer { output in
                    stream.next_out = output.baseAddress; stream.avail_out = uInt(output.count)
                    let next = inflate(&stream, Z_NO_FLUSH), count = output.count - Int(stream.avail_out)
                    guard count <= limit - result.count else { return Z_BUF_ERROR }
                    result.append(output.baseAddress!, count: count)
                    return next
                }
            }
            return code
        }
        guard status == Z_STREAM_END else { throw TransferFailure.invalid("The ZIP is damaged or expands beyond the import limit.") }
        return result
    }

    static func entries(_ input: Data) throws -> [(String, Data)] {
        guard input.count <= 4_000_000 else { throw TransferFailure.invalid("Choose a ZIP file under 4 MB.") }
        let bytes = [UInt8](input)
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        func text(_ at: Int, _ count: Int) -> String? { String(bytes: bytes[at..<at + count], encoding: .utf8) }
        guard bytes.count >= 22, let end = stride(from: bytes.count - 22, through: max(0, bytes.count - 65_557), by: -1).first(where: { u32($0) == 0x06054b50 && $0 + 22 + u16($0 + 20) == bytes.count }),
              u16(end + 4) == 0, u16(end + 6) == 0 else { throw TransferFailure.invalid("Choose a regular ZIP archive.") }
        let count = u16(end + 10), size = u32(end + 12), offset = u32(end + 16)
        guard count == u16(end + 8), count <= maximumEntries, offset + size == end else { throw TransferFailure.invalid("The ZIP directory is invalid or too large.") }
        var cursor = offset, expanded = 0, found = Set<String>(), result: [(String, Data)] = []
        for _ in 0..<count {
            guard cursor + 46 <= end, u32(cursor) == 0x02014b50 else { throw TransferFailure.invalid("The ZIP directory is invalid.") }
            let flags = u16(cursor + 8), method = u16(cursor + 10), checksum = u32(cursor + 16), compressed = u32(cursor + 20), original = u32(cursor + 24)
            let nameLength = u16(cursor + 28), extra = u16(cursor + 30), comment = u16(cursor + 32), mode = u32(cursor + 38) >> 16, local = u32(cursor + 42)
            guard cursor + 46 + nameLength + extra + comment <= end, ![compressed, original, local].contains(0xffffffff), flags & 1 == 0, [0, 8].contains(method), mode & 0o170000 != 0o120000 else {
                throw TransferFailure.invalid("The ZIP contains an unsupported entry.")
            }
            guard let name = text(cursor + 46, nameLength), !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"),
                  name.utf8.allSatisfy({ (0x20...0x7e).contains($0) }), !name.components(separatedBy: "/").contains(where: { $0 == "." || $0 == ".." }) else {
                throw TransferFailure.invalid("The ZIP contains an unsafe file path.")
            }
            cursor += 46 + nameLength + extra + comment
            if name.hasSuffix("/") { continue }
            guard found.insert(name).inserted else { throw TransferFailure.invalid("The ZIP contains a duplicate file.") }
            guard local + 30 <= offset, u32(local) == 0x04034b50, u16(local + 8) == method else { throw TransferFailure.invalid("The ZIP has an invalid file header.") }
            let localName = u16(local + 26), localExtra = u16(local + 28), dataAt = local + 30 + localName + localExtra
            guard dataAt + compressed <= offset, text(local + 30, localName) == name else { throw TransferFailure.invalid("The ZIP has an invalid file range.") }
            guard original <= maximumExpanded - expanded else { throw TransferFailure.invalid("The ZIP expands beyond the import limit.") }
            let packed = Data(bytes[dataAt..<dataAt + compressed]), content = method == 0 ? packed : try inflateRaw(packed, limit: maximumExpanded - expanded)
            guard content.count == original, crc(content) == UInt32(checksum) else { throw TransferFailure.invalid("The ZIP file failed its integrity check.") }
            expanded += original; result.append((name, content))
        }
        guard cursor == end else { throw TransferFailure.invalid("The ZIP directory is invalid.") }
        return result
    }

    public static func parse(_ input: Data, appId: String, versionId: String) throws -> FastlaneImport {
        var rows: [[String]] = [], localeFiles: [String: Set<String>] = [:], ignored = 0, clears = 0
        for (path, bytes) in try entries(input) {
            let name = path.hasPrefix("fastlane/") ? String(path.dropFirst(9)) : path, parts = name.components(separatedBy: "/")
            guard parts.count == 3, parts[0] == "metadata", parts[2].hasSuffix(".txt"), let field = fields.first(where: { $0.0 + ".txt" == parts[2] }) else { ignored += 1; continue }
            let locale = parts[1]
            guard StoreLocales.codes.contains(locale) else { throw TransferFailure.invalid("The ZIP includes an unsupported App Store language.") }
            guard bytes.count <= 40_000, !bytes.contains(0), let value = String(data: bytes, encoding: .utf8), value.utf16.count <= 10_000 else { throw TransferFailure.invalid("A metadata text file is too large or invalid.") }
            guard localeFiles[locale, default: []].insert(field.0).inserted else { throw TransferFailure.invalid("The ZIP contains the same metadata field twice.") }
            if value.isEmpty { clears += 1 }
            rows.append([appId, versionId, locale, field.1, field.2, value])
        }
        guard !rows.isEmpty else { throw TransferFailure.invalid("No supported Fastlane metadata text files were found.") }
        let locales = localeFiles.keys.sorted(), omitted = locales.flatMap { locale in fields.filter { !localeFiles[locale]!.contains($0.0) }.map { "\(locale)/\($0.0).txt" } }
        return FastlaneImport(table: Delimited.Table(columns: Transfer.columns[.languages]!, rows: rows), files: rows.count, ignored: ignored, clears: clears, omitted: omitted, locales: locales)
    }

    static func storedZip(_ entries: [(String, Data)]) -> Data {
        func header(_ count: Int, _ values: [(Int, Int, Int)]) -> Data {
            var bytes = [UInt8](repeating: 0, count: count)
            for (at, width, value) in values { for index in 0..<width { bytes[at + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) } }
            return Data(bytes)
        }
        var files = Data(), directory = Data()
        for (path, content) in entries {
            let name = Data(path.utf8), checksum = Int(crc(content)), offset = files.count
            files.append(header(30, [(0,4,0x04034b50), (4,2,20), (6,2,0x800), (14,4,checksum), (18,4,content.count), (22,4,content.count), (26,2,name.count)]))
            files.append(name); files.append(content)
            directory.append(header(46, [(0,4,0x02014b50), (4,2,20), (6,2,20), (8,2,0x800), (16,4,checksum), (20,4,content.count), (24,4,content.count), (28,2,name.count), (42,4,offset)])); directory.append(name)
        }
        let end = header(22, [(0,4,0x06054b50), (8,2,entries.count), (10,2,entries.count), (12,4,directory.count), (16,4,files.count)])
        return files + directory + end
    }

    static func export(source: Revision, draft: JSONText, versionId: String) throws -> Data {
        guard source.versions.contains(where: { $0.id == versionId }) else { throw TransferFailure.invalid("Choose a version in this workspace.") }
        let rows = Transfer.materialTable(.languages, source: source, draft: draft, versionId: versionId).rows
        let values = Dictionary(rows.map { ("\($0[2]):\($0[3]):\($0[4])", $0[5]) }, uniquingKeysWith: { _, latest in latest })
        let entries = Set(rows.map { $0[2] }).sorted().flatMap { locale in fields.compactMap { field -> (String, Data)? in
            guard let value = values["\(locale):\(field.1):\(field.2)"] else { return nil }
            return ("metadata/\(locale)/\(field.0).txt", Data(value.utf8))
        } }
        guard !entries.isEmpty, entries.count <= maximumEntries, entries.reduce(0, { $0 + $1.1.count }) <= maximumExpanded else { throw TransferFailure.invalid("The metadata export is unavailable for this version.") }
        return storedZip(entries)
    }
}

extension WorkspaceSession {
    public func exportFastlaneMetadata(account: Account, appId: String, versionId: String, revisionId: String? = nil) throws -> Data {
        guard account.appIds.contains(appId) else { throw TransferFailure.invalid("App not found.") }
        let context = try materialContext(accountId: account.id, appId: appId, revisionId: revisionId)
        guard context.versionId == nil || context.versionId == versionId else { throw TransferFailure.invalid("Choose a version in this workspace.") }
        return try FastlaneMetadata.export(source: context.source, draft: context.draft, versionId: versionId)
    }

    /// The archive bytes and entire saved draft are part of the review, including ignored entries.
    /// Import revalidates the release source while holding the release-plan lock before the draft lock.
    public func importFastlaneMetadata(account: Account, appId: String, versionId: String, archive: Data, revisionId: String? = nil, fingerprint: String? = nil) throws -> FastlanePreview {
        guard account.appIds.contains(appId) else { throw TransferFailure.invalid("App not found.") }
        let context = try materialContext(accountId: account.id, appId: appId, revisionId: revisionId)
        guard context.source.versions.contains(where: { $0.id == versionId }), context.versionId == nil || context.versionId == versionId else { throw TransferFailure.invalid("Choose a version in this workspace.") }
        let parsed = try FastlaneMetadata.parse(archive, appId: appId, versionId: versionId)
        // SHA-256 binds the exact archive, rather than only its supported rows.
        let archiveHash = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined(), apply = fingerprint != nil
        let names = Dictionary(context.source.versions.map { ($0.id, $0.number) }, uniquingKeysWith: { first, _ in first })
        func run(_ draft: JSONText) throws -> (JSONText, FastlanePreview) {
            let signature = Apple.sha(JSONText.object([("accountId", .string(account.id)), ("appId", .string(appId)), ("revisionId", .string(context.source.id)),
                ("versionId", .string(versionId)), ("planVersionId", context.versionId.map(JSONText.string) ?? .null), ("archiveHash", .string(archiveHash)), ("draft", draft)]).stringify())
            guard !apply || signature == fingerprint else { throw TransferFailure.changed }
            let result = try Transfer.importMaterials(.languages, parsed.table, source: context.source, draft: draft, versionId: versionId)
            let changes = Transfer.changes(.languages, before: Transfer.materialTable(.languages, source: context.source, draft: draft, versionId: versionId),
                                           after: Transfer.materialTable(.languages, source: context.source, draft: result.draft, versionId: versionId), versionNames: names)
            return (result.draft, FastlanePreview(archive: parsed, transfer: TransferPreview(changes: changes, fingerprint: signature, count: result.count, added: result.added, totalRows: parsed.files, saved: apply)))
        }
        guard apply else { return try run(context.draft).1 }
        let directory = try storeAccess { $0.directory }
        return try FileMutex.withLock(directory.appendingPathComponent("release_plans.mutex")) {
            let plan = try releasePlan(accountId: account.id, appId: appId)
            guard plan?.sourceRevisionId == context.plan?.sourceRevisionId, plan?.baseVersionId == context.versionId else { throw TransferFailure.changed }
            return try mutateDraft(accountId: account.id, appId: appId, revisionId: context.source.id) { draft, _ in try run(draft) }
        }
    }
}
