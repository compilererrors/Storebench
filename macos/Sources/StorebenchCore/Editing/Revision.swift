import Foundation

public enum FieldValue: Codable, Equatable, Sendable {
    case text(String), number(Double), null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let number = try? container.decode(Double.self) { self = .number(number) }
        else { self = .text(try container.decode(String.self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self { case .text(let value): try container.encode(value); case .number(let value): try container.encode(value); case .null: try container.encodeNil() }
    }
    public var text: String? {
        switch self { case .text(let value): value; case .number(let value): TextSemantics.number(value); case .null: nil }
    }
}

public typealias Fields = [String: FieldValue]

/// One saved import or local draft of an app's App Store material, as stored in `revisions`.
public struct Revision: Codable, Identifiable, Sendable {
    public struct Screenshot: Codable, Identifiable, Sendable {
        public let id, fileName, sha256: String
        public let width, height: Int?
        public var contentType: String?
        enum CodingKeys: String, CodingKey { case id, fileName, sha256, width, height, contentType }
        init(id: String, fileName: String, sha256: String, width: Int?, height: Int?, contentType: String? = nil) {
            self.id = id; self.fileName = fileName; self.sha256 = sha256; self.width = width; self.height = height; self.contentType = contentType
        }
        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            func dimension(_ key: CodingKeys) throws -> Int? {
                guard values.contains(key) else { return nil }
                let number = try values.decode(Int.self, forKey: key)
                guard number > 0, number <= 9_007_199_254_740_991 else {
                    throw DecodingError.dataCorruptedError(forKey: key, in: values, debugDescription: "Saved image dimensions must be positive safe integers when present.")
                }
                return number
            }
            id = try values.decode(String.self, forKey: .id); fileName = try values.decode(String.self, forKey: .fileName); sha256 = try values.decode(String.self, forKey: .sha256)
            width = try dimension(.width); height = try dimension(.height); contentType = try values.decodeIfPresent(String.self, forKey: .contentType)
        }
    }
    public struct ScreenshotSet: Codable, Identifiable, Sendable { public let id: String; public let displayType: String; public let screenshots: [Screenshot] }
    public struct Localization: Codable, Identifiable, Sendable { public let id: String; public let fields: Fields; public let screenshotSets: [ScreenshotSet] }
    public struct Version: Codable, Identifiable, Sendable { public let id: String; public let fields: Fields; public let localizations: [Localization] }
    public struct AppInfoLocalization: Codable, Identifiable, Sendable { public let id: String; public let fields: Fields }
    public struct AppInfo: Codable, Identifiable, Sendable { public let id: String; public let fields: Fields; public let localizations: [AppInfoLocalization] }
    public struct AppIdentity: Codable, Sendable { public let id: String; public let name: String; public let bundleId: String; public let sku: String; public let primaryLocale: String }

    public let schemaVersion: Int
    public let origin: String?
    public let id: String
    public let importedAt: String
    public let app: AppIdentity
    public let appInfos: [AppInfo]
    public let versions: [Version]

    public var isLocalDraft: Bool { origin == "local" }
}

extension Revision.Version {
    /// Approved and pending versions are excluded until an import confirms distribution or replacement.
    public var released: Bool {
        ["READY_FOR_DISTRIBUTION", "READY_FOR_SALE", "REPLACED_WITH_NEW_VERSION"].contains(fields["appVersionState"]?.text ?? fields["appStoreState"]?.text ?? "")
    }
    public var platform: String { fields["platform"]?.text ?? "" }
    public var number: String { fields["versionString"]?.text ?? "" }
    public var state: String { AppStoreNames.state(fields["appVersionState"]?.text ?? fields["appStoreState"]?.text ?? "") }
    public var title: String { "\(AppStoreNames.platform(platform)) \(number)" }
}

extension Revision.Localization { public var locale: String { fields["locale"]?.text ?? id } }

/// App Store Connect's own names, so every view reads the same.
public enum AppStoreNames {
    static let states: [String: String] = [
        "PROCESSING": "Processing", "READY_FOR_BETA_TESTING": "Ready to Test", "READY_FOR_BETA_SUBMISSION": "Ready to Submit", "EXPIRED": "Expired", "FAILED": "Failed",
        "MISSING_EXPORT_COMPLIANCE": "Missing Compliance", "IN_BETA_TESTING": "Testing", "WAITING_FOR_BETA_REVIEW": "Waiting for Review", "IN_BETA_REVIEW": "In Review", "BETA_REJECTED": "Rejected", "BETA_APPROVED": "Approved",
        "ACCEPTED": "Accepted", "APPROVED": "Approved", "DEVELOPER_REJECTED": "Developer Rejected", "DEVELOPER_REMOVED_FROM_SALE": "Developer Removed from Sale",
        "IN_REVIEW": "In Review", "INVALID_BINARY": "Invalid Binary", "METADATA_REJECTED": "Metadata Rejected", "PENDING_APPLE_RELEASE": "Pending Apple Release",
        "PENDING_CONTRACT": "Pending Contract", "PENDING_DEVELOPER_RELEASE": "Pending Developer Release", "PREORDER_READY_FOR_SALE": "Pre-Order Ready for Sale",
        "PREPARE_FOR_SUBMISSION": "Prepare for Submission", "PROCESSING_FOR_APP_STORE": "Processing for Distribution", "PROCESSING_FOR_DISTRIBUTION": "Processing for Distribution",
        "READY_FOR_DISTRIBUTION": "Ready for Distribution", "READY_FOR_REVIEW": "Ready for Review", "READY_FOR_SALE": "Ready for Distribution", "REJECTED": "Rejected",
        "REMOVED_FROM_SALE": "Removed from Sale", "REPLACED_WITH_NEW_VERSION": "Replaced with New Version", "WAITING_FOR_EXPORT_COMPLIANCE": "Waiting for Export Compliance",
        "WAITING_FOR_REVIEW": "Waiting for Review", "LOCAL_DRAFT": "Version draft",
        "MISSING_METADATA": "Missing Metadata", "READY_TO_SUBMIT": "Ready to Submit", "DEVELOPER_ACTION_NEEDED": "Developer Action Needed",
        "AWAITING_UPLOAD": "Uploading", "UPLOAD_COMPLETE": "Processing", "ARCHIVED": "Archived",
        "NOT_INVITED": "Not Invited", "INVITED": "Invited", "INSTALLED": "Installed", "REVOKED": "Revoked",
    ]
    /// The status mark App Store Connect shows beside a state: a green check, a yellow or red dot, or a grey dot.
    public enum Tone: String, Sendable { case complete, pending, problem, inactive }
    public static func tone(_ code: String) -> Tone {
        switch code {
        case "APPROVED", "ACCEPTED", "READY_FOR_DISTRIBUTION", "READY_FOR_SALE", "BETA_APPROVED", "IN_BETA_TESTING", "READY_FOR_BETA_TESTING": .complete
        case "REJECTED", "METADATA_REJECTED", "INVALID_BINARY", "FAILED", "BETA_REJECTED", "DEVELOPER_REJECTED", "EXPIRED", "MISSING_EXPORT_COMPLIANCE": .problem
        case "ARCHIVED", "REPLACED_WITH_NEW_VERSION", "REMOVED_FROM_SALE", "DEVELOPER_REMOVED_FROM_SALE", "LOCAL_DRAFT", "": .inactive
        default: .pending
        }
    }
    static let placementTypes: [String: String] = [
        "APP_SCREENSHOT": "App Screenshots", "APP_PREVIEW": "App Previews", "IMESSAGE_APP_SCREENSHOT": "iMessage App Screenshots",
        "PRODUCT_PAGE_HEADER_ASSET": "Product Page Header", "EVENT_CARD_ASSET": "Event Card", "EVENT_DETAILS_PAGE_ASSET": "Event Details Page",
    ]
    /// Asset Library's Works With names; an unlisted code reads as its words in title case.
    public static func placementType(_ code: String) -> String {
        if let label = placementTypes[code] { return label }
        return code.split(separator: "_").map { $0.lowercased().prefix(1).uppercased() + $0.lowercased().dropFirst() }.joined(separator: " ")
    }
    /// App Store Connect's table date, such as "Oct 25, 2026".
    public static func date(_ value: Date, timeZone: TimeZone = .current) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: Locale(identifier: "en_US"), calendar: Calendar(identifier: .gregorian), timeZone: timeZone)
        style.capitalizationContext = .standalone
        return value.formatted(style)
    }
    public static func date(_ iso: String?, timeZone: TimeZone = .current) -> String? { iso.flatMap(ISODateParser.date).map { date($0, timeZone: timeZone) } }
    public static func state(_ code: String) -> String {
        if let label = states[code] { return label }
        guard !code.isEmpty else { return "Unknown state" }
        let words = code.lowercased().split(separator: "_")
        return ([words.first.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? ""] + words.dropFirst().map(String.init)).joined(separator: " ")
    }
    public static func primaryState(_ code: String) -> String { code == "LOCAL_DRAFT" ? "Local draft" : state(code) }
    public static func platform(_ code: String) -> String { ["IOS": "iOS", "MAC_OS": "macOS", "TV_OS": "tvOS", "VISION_OS": "visionOS"][code] ?? code }
}

extension Revision.AppInfo {
    /// The same App Information record with more localizations, such as languages added in a local draft.
    public func adding(_ localizations: [Revision.AppInfoLocalization]) -> Revision.AppInfo {
        Revision.AppInfo(id: id, fields: fields, localizations: self.localizations + localizations)
    }
}
