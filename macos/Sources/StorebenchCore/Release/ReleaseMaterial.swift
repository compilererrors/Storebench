import Foundation
import Darwin

/// Local listing checks for the saved source and draft; they do not establish Apple's submission requirements.
public enum ReleaseMaterial {
    public enum Failure: Error { case invalid }
    public struct Issue: Sendable {
        public let field, message, section: String
        public init(field: String, message: String, section: String) { self.field = field; self.message = message; self.section = section }
        public var json: JSONText { .object([("field", .string(field)), ("message", .string(message)), ("section", .string(section))]) }
    }
    public struct Language: Identifiable, Sendable {
        public let locale, versionId: String
        public let changedFields, screenshots, previews: Int
        public let issues: [Issue]
        public var id: String { locale }
        public var json: JSONText { .object([("locale", .string(locale)), ("versionId", .string(versionId)), ("changedFields", .number(Double(changedFields))),
            ("screenshots", .number(Double(screenshots))), ("previews", .number(Double(previews))), ("issues", .array(issues.map(\.json)))]) }
    }
    private static let labels = ["name": "App name", "subtitle": "Subtitle", "privacyPolicyUrl": "Privacy policy URL", "privacyChoicesUrl": "Privacy choices URL", "privacyPolicyText": "Privacy policy text",
        "description": "Description", "keywords": "Keywords", "promotionalText": "Promotional text", "whatsNew": "What's new", "supportUrl": "Support URL", "marketingUrl": "Marketing URL"]
    /// The saved check in App Store Connect's field names, saying what is wrong and what to do.
    public static func presented(_ issue: Issue) -> Issue {
        let label = TextDrafts.labels[issue.field] ?? issue.field, detail = issue.message.split(separator: ":", maxSplits: 1).last.map { TextSemantics.trim(String($0)) } ?? ""
        let message: String
        if issue.section == "screenshots" {
            message = issue.field == "screenshots" ? "No screenshots yet. Add screenshots for this language." : "\(StoreLocales.displayTypeName(issue.field)) has more than 10 screenshots. Remove some."
        } else if issue.message.hasPrefix("App Information:") { message = "Name and privacy information are missing for this language." }
        else if detail == "add text" { message = "\(label) is empty. Add text." }
        else if detail.hasSuffix("over the limit") { message = "\(label) is \(detail.dropLast(" the limit".count)) Apple’s limit. Shorten it." }
        else if detail == "remove control characters" { message = "\(label) contains control characters. Remove them." }
        else if detail.hasPrefix("use a complete public") { message = "\(label) is not a complete public URL. Enter one that starts with https://." }
        else { message = issue.message }
        return Issue(field: issue.field, message: message, section: issue.section)
    }
    /// Fields App Store Connect requires before a version can be added for review.
    public static func required(platform: String, whatsNew: Bool) -> Set<String> {
        Set(["description", "keywords", "supportUrl", "name"] + (whatsNew ? ["whatsNew"] : []) + (["IOS", "MAC_OS"].contains(platform) ? ["privacyPolicyUrl"] : platform == "TV_OS" ? ["privacyPolicyText"] : []))
    }
    /// What is wrong with one text field, in App Store Connect's field names, and what to do about it; nil when the value passes.
    public static func problem(_ field: String, value: String, required: Bool) -> String? {
        let label = TextDrafts.labels[field] ?? field, used = TextDrafts.used(field, value), limit = TextDrafts.limits[field] ?? 0
        if required, TextSemantics.trim(value).isEmpty { return "\(label) is empty. Add text." }
        if used > limit { return "\(label) is \(used - limit) \(field == "keywords" ? "bytes" : "characters") over Apple’s limit. Shorten it." }
        if !TextSemantics.validControlText(value) { return "\(label) contains control characters. Remove them." }
        if field.hasSuffix("Url"), !value.isEmpty, !publicURL(value) { return "\(label) is not a complete public URL. Enter one that starts with https://." }
        return nil
    }
    @inline(never) private static func validNumericHost(_ host: String) -> Bool {
        var parts = host.lowercased().split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if parts.last == "" { parts.removeLast() }
        guard let last = parts.last else { return true }
        func digit(_ byte: UInt8) -> UInt64? {
            if (48...57).contains(byte) { return UInt64(byte - 48) }
            if (97...102).contains(byte) { return UInt64(byte - 87) }; return nil
        }
        let endsInNumber = !last.isEmpty && last.utf8.allSatisfy { (48...57).contains($0) } || last.hasPrefix("0x") && last.dropFirst(2).utf8.allSatisfy { digit($0) != nil }
        guard endsInNumber else { return true }
        guard (1...4).contains(parts.count) else { return false }
        var numbers: [UInt64] = []
        for part in parts {
            guard !part.isEmpty else { return false }
            let radix: UInt64 = part.hasPrefix("0x") ? 16 : part.count > 1 && part.hasPrefix("0") ? 8 : 10
            let digits = part.dropFirst(radix == 16 ? 2 : radix == 8 ? 1 : 0)
            var value: UInt64 = 0
            for byte in digits.utf8 {
                guard let next = digit(byte), next < radix, value <= (UInt64.max - next) / radix else { return false }
                value = value * radix + next
            }
            numbers.append(value)
        }
        return numbers.dropLast().allSatisfy { $0 <= 255 } && numbers.last! < (UInt64(1) << (8 * (5 - numbers.count)))
    }
    @inline(never) private static func publicURL(_ value: String) -> Bool {
        // The WHATWG URL parser for special schemes also accepts a missing pair of slashes and normalizes backslashes.
        let cleaned = TextSemantics.trim(value).replacingOccurrences(of: "\t", with: "").replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
        guard let separator = cleaned.firstIndex(of: ":"), ["http", "https"].contains(cleaned[..<separator].lowercased()) else { return false }
        let path = cleaned[cleaned.index(after: separator)...].replacingOccurrences(of: "\\", with: "/").drop(while: { $0 == "/" })
        guard let url = URLComponents(string: cleaned[..<separator].lowercased() + "://" + path), let host = url.host, !host.isEmpty,
              url.user?.isEmpty != false, url.password?.isEmpty != false else { return false }
        if host.contains(":") || host.hasPrefix("[") {
            var address = in6_addr()
            let literal = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
            guard literal.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return false }
        } else if host.unicodeScalars.contains(where: { $0.value <= 32 || [35, 37, 47, 58, 60, 62, 63, 64, 91, 92, 93, 94, 124, 127].contains($0.value) }) || !validNumericHost(host) { return false }
        return url.port.map { (0...65_535).contains($0) } ?? true
    }
    @inline(never) private static func validateMedia(_ draft: JSONText) throws {
        func entries(_ key: String, optional: Bool = false) throws -> [(String, JSONText)] {
            if optional && (draft[key] == nil || draft[key] == .null) { return [] }
            guard case .object(let values)? = draft[key], values.count <= 2000 else { throw Failure.invalid }; return values
        }
        func ids(_ value: JSONText?) throws -> [String] {
            guard case .array(let values)? = value, values.count <= 2000, values.allSatisfy({ $0.text.map { $0.utf16.count <= 256 } == true }) else { throw Failure.invalid }
            return values.compactMap(\.text)
        }
        func positive(_ value: JSONText?, maximum: Double = 9_007_199_254_740_991) throws -> Int {
            guard case .number(let number)? = value, let integer = Int(exactly: number), number >= 1, number <= maximum else { throw Failure.invalid }; return integer
        }
        for (_, layout) in try entries("screenshotLayouts") { _ = try ids(layout["order"]); _ = try ids(layout["hidden"]) }
        for (key, upload) in try entries("uploads") {
            guard TextSemantics.same(key, upload["id"]?.text), key.range(of: #"\Alocal-[a-f0-9-]{36}\z"#, options: .regularExpression) != nil,
                  upload["sha256"]?.text?.range(of: #"\A[a-f0-9]{64}\z"#, options: .regularExpression) != nil, let set = upload["setId"]?.text, set.utf16.count <= 256,
                  let name = upload["fileName"]?.text, name.utf16.count <= 100 else { throw Failure.invalid }
            _ = try positive(upload["width"]); _ = try positive(upload["height"])
            if let type = upload["contentType"] { guard type.text.map(["image/png", "image/jpeg"].contains) == true else { throw Failure.invalid } }
            if let archived = upload["archiveSource"] { guard archived == .bool(true) else { throw Failure.invalid } }
        }
        let previews = try entries("previewUploads", optional: true)
        for (key, video) in previews {
            guard TextSemantics.same(key, video["id"]?.text), key.range(of: #"\Apreview-[a-f0-9-]{36}\z"#, options: .regularExpression) != nil,
                  video["sha256"]?.text?.range(of: #"\A[a-f0-9]{64}\z"#, options: .regularExpression) != nil, let locale = video["localizationId"]?.text, AppOverviewMaterial.identifier(locale),
                  let type = video["previewType"]?.text, let ext = video["extension"]?.text, ["mp4", "mov", "m4v"].contains(ext), let name = video["fileName"]?.text, !name.isEmpty, name.utf16.count <= 100,
                  case .number(let duration)? = video["duration"], duration.isFinite, (15...30.05).contains(duration), case .number(let rate)? = video["frameRate"], rate.isFinite, rate > 0, rate <= 30.01,
                  let codec = video["codec"]?.text else { throw Failure.invalid }
            _ = try positive(video["bytes"], maximum: 500_000_000)
            let width = try positive(video["width"]), height = try positive(video["height"])
            do { try PreviewSpecs.validate(.init(width: width, height: height, duration: duration, frameRate: rate, codec: codec), type: type, extension: ext) } catch { throw Failure.invalid }
        }
        for (key, layout) in try entries("previewLayouts", optional: true) {
            let order = try ids(layout["order"]), hidden = try ids(layout["hidden"]), available = previews.filter { ($0.1["localizationId"]?.text ?? "") + ":" + ($0.1["previewType"]?.text ?? "") == key }.map(\.0)
            guard Set(order.map { Data($0.utf8) }) == Set(available.map { Data($0.utf8) }), order.count == available.count,
                  Set(hidden.map { Data($0.utf8) }).count == hidden.count, hidden.allSatisfy({ available.contains($0) }),
                  case .object(let times)? = layout["posterTimes"] else { throw Failure.invalid }
            for (id, value) in times {
                guard available.contains(id), case .number(let time) = value, time.isFinite, time >= 0,
                      case .number(let duration)? = previews.first(where: { $0.0 == id })?.1["duration"], time < duration else { throw Failure.invalid }
            }
        }
    }
    public static func languages(source: JSONText, draft: JSONText, versionId: String, requireWhatsNew: Bool = false) throws -> [Language] {
        guard let sourceId = source["id"]?.text, !sourceId.isEmpty, TextSemantics.same(sourceId, draft["revisionId"]?.text), case .array? = source["versions"], case .array? = source["appInfos"] else { throw Failure.invalid }
        try LanguageDrafts.validateTextDocument(draft)
        try validateMedia(draft)
        let working = WorkspaceSession.overlayJSON(source, draft: draft)
        guard let version = WorkspaceSession.items(working["versions"]).first(where: { TextSemantics.same($0["id"]?.text, versionId) }) else { throw Failure.invalid }
        let locales = WorkspaceSession.items(version["localizations"])
        guard locales.count <= 2000 else { throw Failure.invalid }
        return try locales.map { locale in
            let code = locale["fields"]?["locale"].map { $0 == .null ? "null" : (try? LanguageDrafts.originalText($0)) ?? "" } ?? "undefined"
            var issues: [Issue] = [], changedFields = 0
            func check(_ item: JSONText, fields: [String], required: Set<String>) throws {
                guard let id = item["id"]?.text else { throw Failure.invalid }
                for field in fields {
                    let imported = try LanguageDrafts.originalText(item["fields"]?[field]), value = draft["texts"]?[id]?[field]?.text ?? imported
                    if !TextSemantics.same(value, imported) { changedFields += 1 }
                    let used = TextDrafts.used(field, value), limit = TextDrafts.limits[field] ?? 0
                    var message: String?
                    if required.contains(field), TextSemantics.trim(value).isEmpty { message = "add text" }
                    else if used > limit { message = "\(used - limit) \(field == "keywords" ? "bytes" : "characters") over the limit" }
                    else if !TextSemantics.validControlText(value) { message = "remove control characters" }
                    else if field.hasSuffix("Url"), !value.isEmpty, !publicURL(value) { message = "use a complete public HTTP or HTTPS URL" }
                    if let message { issues.append(Issue(field: field, message: (labels[field] ?? field) + ": " + message, section: "text")) }
                }
            }
            let platform = version["fields"]?["platform"]?.text ?? "", needed = required(platform: platform, whatsNew: requireWhatsNew)
            try check(locale, fields: TextDrafts.versionFields, required: needed)
            let info = WorkspaceSession.items(working["appInfos"]).flatMap { WorkspaceSession.items($0["localizations"]) }.filter { TextSemantics.same($0["fields"]?["locale"]?.text, code) }
            if info.isEmpty { issues.append(Issue(field: "name", message: "App Information: review the name and privacy information for this language", section: "text")) }
            for record in info { try check(record, fields: TextDrafts.appInfoFields, required: needed) }
            var screenshots = 0
            for set in WorkspaceSession.items(locale["screenshotSets"]) {
                guard let id = set["id"]?.text, let type = set["displayType"]?.text else { throw Failure.invalid }
                let imported = WorkspaceSession.items(set["screenshots"]).compactMap { $0["id"]?.text }, uploaded = WorkspaceSession.uploads(draft).filter { TextSemantics.same($0.1["setId"]?.text, id) }.compactMap { $0.1["id"]?.text }
                let hidden = Set(WorkspaceSession.strings(draft["screenshotLayouts"]?[id]?["hidden"]).map { Data($0.utf8) })
                let included = Set((imported + uploaded).map { Data($0.utf8) }).subtracting(hidden).count
                screenshots += included
                if included > ScreenshotSpecs.maximum { issues.append(Issue(field: type, message: type + ": select no more than 10 screenshots", section: "screenshots")) }
            }
            if screenshots == 0 { issues.append(Issue(field: "screenshots", message: "No screenshots selected locally. Reuse images or check inherited screenshots in Apple.", section: "screenshots")) }
            let videos: [(String, JSONText)]
            if case .object(let entries)? = draft["previewUploads"] { videos = entries } else { videos = [] }
            let previews = videos.filter { _, video in
                guard TextSemantics.same(video["localizationId"]?.text, locale["id"]?.text), let id = video["id"]?.text else { return false }
                let key = (locale["id"]?.text ?? "") + ":" + (video["previewType"]?.text ?? "")
                return !WorkspaceSession.strings(draft["previewLayouts"]?[key]?["hidden"]).contains { TextSemantics.same($0, id) }
            }.count
            return Language(locale: code, versionId: versionId, changedFields: changedFields, screenshots: screenshots, previews: previews, issues: issues)
        }
    }
}
