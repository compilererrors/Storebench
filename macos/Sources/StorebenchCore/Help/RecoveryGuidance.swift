import Foundation

/// Fixed public recovery actions. Targets select a view; they never retry a write or grant publishing approval.
public struct RecoveryGuidance: Sendable {
    public enum Failure: Error { case invalid, unavailable }
    public enum Module: String, Sendable { case finance }
    public enum Kind: String, Sendable { case setup, availability, input, retry }
    public struct Scope: Sendable, Equatable {
        public let accountId, appId: String
        public init(accountId: String, appId: String) throws {
            guard accountId.range(of: #"\A[A-Za-z0-9_-]{1,128}\z"#, options: .regularExpression) != nil,
                  appId.range(of: #"\A[0-9]{1,32}\z"#, options: .regularExpression) != nil else { throw Failure.invalid }
            self.accountId = accountId; self.appId = appId
        }
        public var root: String { "/apps/\(accountId)/\(appId)" }
    }
    public struct Target: Sendable, Equatable {
        public enum Area: String, Sendable { case overview, history, sales, analytics, finance, reviews, keywords, pricing, publishing, accounts, storage, unlock, developerAccount, help }
        public let area: Area
        public let anchor, focus, accountRecovery, helpTopic: String?
        public let opensConnection, analyticsOngoing: Bool
        public var requiresApp: Bool { switch area { case .overview, .history, .sales, .analytics, .finance, .reviews, .keywords, .pricing, .publishing: true; default: false } }
        public var section: AppNavigation.Section? {
            switch area {
            case .overview: .overview; case .history: .history; case .sales: .sales; case .analytics: .analytics
            case .finance: .finance; case .reviews: .reviews; case .keywords: .keywords; case .pricing: .pricing; case .publishing: .publish
            default: nil
            }
        }
        /// Opens one app section, such as Pricing, with nothing focused in it.
        public static func open(_ area: Area) -> Self { Self(area: area, anchor: nil, focus: nil, accountRecovery: nil, helpTopic: nil, opensConnection: false, analyticsOngoing: false) }
        /// Opens one app section scrolled to a card, such as App Privacy in App Store changes.
        public static func open(_ area: Area, anchor: String) -> Self { Self(area: area, anchor: anchor, focus: nil, accountRecovery: nil, helpTopic: nil, opensConnection: false, analyticsOngoing: false) }
        public func resolved(scope: Scope?) -> Action? {
            guard !requiresApp || scope != nil else { return nil }
            return Action(target: self, scope: scope)
        }
        public static func help(_ topic: String) throws -> Self {
            guard topic.range(of: #"\A[A-Za-z0-9_-]{1,100}\z"#, options: .regularExpression) != nil else { throw Failure.invalid }
            return Self(area: .help, anchor: nil, focus: nil, accountRecovery: nil, helpTopic: topic, opensConnection: false, analyticsOngoing: false)
        }
    }
    public struct Action: Sendable, Equatable {
        public let target: Target
        public let scope: Scope?
        /// Compare the displayed app and current navigation policy immediately before changing a view.
        public func allowed(current: Scope?, decision: EditorProtectionPolicy.Decision, discardConfirmed: Bool = false) -> Bool {
            guard !target.requiresApp || scope == current && scope != nil else { return false }
            switch decision { case .ready: return true; case .confirmDiscard: return discardConfirmed; case .wait: return false }
        }
    }
    public struct Entry: Sendable {
        public let status, action, guide, guideHref: String
        public let message: String?
        public let kind: Kind
        public let target: Target
        let raw: JSONText
        public var neutral: Bool { kind == .setup || kind == .availability }
        init(_ value: JSONText, helpTopics: Set<String>) throws {
            guard case .object(let pairs) = value,
                  Set(pairs.map(\.0)).count == pairs.count,
                  Set(pairs.map(\.0)).isSubset(of: ["status", "action", "path", "guide", "guideHref", "message", "kind", "global", "opensConnection", "opensNewTab", "focus"]),
                  let status = value["status"]?.text, let action = value["action"]?.text, let path = value["path"]?.text,
                  let guide = value["guide"]?.text, let guideHref = value["guideHref"]?.text,
                  [status, action, guide].allSatisfy({ !$0.isEmpty && $0.utf16.count <= 200 && !$0.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) }),
                  guideHref.hasPrefix("/settings/help#"), helpTopics.contains(String(guideHref.dropFirst("/settings/help#".count))),
                  let kind = Kind(rawValue: value["kind"]?.text ?? "setup") else { throw Failure.invalid }
            for key in ["global", "opensConnection", "opensNewTab"] { if let flag = value[key], flag != .bool(true) && flag != .bool(false) { throw Failure.invalid } }
            if let saved = value["kind"], saved.text == nil { throw Failure.invalid }
            if let message = value["message"] { guard let text = message.text, !text.isEmpty, text.utf16.count <= 4096, !text.contains("\0") else { throw Failure.invalid } }
            if let focus = value["focus"], focus != .string("finance-download-period") { throw Failure.invalid }
            let area: Target.Area, anchor: String?, reason: String?, ongoing: Bool
            switch path {
            case "": (area, anchor, reason, ongoing) = (.overview, nil, nil, false)
            case "/history": (area, anchor, reason, ongoing) = (.history, nil, nil, false)
            case "/sales#sales-reports": (area, anchor, reason, ongoing) = (.sales, "sales-reports", nil, false)
            case "/analytics": (area, anchor, reason, ongoing) = (.analytics, nil, nil, false)
            case "/analytics#analytics-download": (area, anchor, reason, ongoing) = (.analytics, "analytics-download", nil, false)
            case "/finance#financial-download": (area, anchor, reason, ongoing) = (.finance, "financial-download", nil, false)
            case "/reviews": (area, anchor, reason, ongoing) = (.reviews, nil, nil, false)
            case "/keywords": (area, anchor, reason, ongoing) = (.keywords, nil, nil, false)
            case "/pricing": (area, anchor, reason, ongoing) = (.pricing, nil, nil, false)
            case "/publish": (area, anchor, reason, ongoing) = (.publishing, nil, nil, false)
            case "/publish?scope=analytics-ongoing": (area, anchor, reason, ongoing) = (.publishing, nil, nil, true)
            case "/settings": (area, anchor, reason, ongoing) = (.storage, nil, nil, false)
            case "/settings/accounts?recovery=auth": (area, anchor, reason, ongoing) = (.accounts, nil, "auth", false)
            case "/settings/accounts?recovery=access": (area, anchor, reason, ongoing) = (.accounts, nil, "access", false)
            case "/settings/accounts?recovery=keychain": (area, anchor, reason, ongoing) = (.accounts, nil, "keychain", false)
            case "/login": (area, anchor, reason, ongoing) = (.unlock, nil, nil, false)
            case "https://developer.apple.com/account/": (area, anchor, reason, ongoing) = (.developerAccount, nil, nil, false)
            default: throw Failure.invalid
            }
            let global = value["global"] == .bool(true), opens = value["opensNewTab"] == .bool(true), connection = value["opensConnection"] == .bool(true)
            guard global == [.accounts, .storage, .unlock, .developerAccount].contains(area), opens == (area == .developerAccount),
                  !connection || area == .sales || area == .finance,
                  value["focus"] == nil || area == .finance else { throw Failure.invalid }
            self.status = status; self.action = action; self.guide = guide; self.guideHref = guideHref; self.kind = kind; self.message = value["message"]?.text
            target = Target(area: area, anchor: anchor, focus: value["focus"]?.text, accountRecovery: reason, helpTopic: nil, opensConnection: connection, analyticsOngoing: ongoing)
            raw = value
        }
        /// The public presentation contract, with app/account identifiers supplied only at runtime.
        public func presentation(scope: Scope? = nil) -> JSONText {
            var value = raw.setting("kind", .string(kind.rawValue))
            let path = raw["path"]!.text!, global = raw["global"] == .bool(true)
            if global { value = value.setting("href", .string(path + (target.area == .accounts ? scope.map { "#account-\($0.accountId)" } ?? "" : ""))) }
            else if let scope { value = value.setting("href", .string(scope.root + path)) }
            return value
        }
        public var help: Target { try! Target.help(String(guideHref.dropFirst("/settings/help#".count))) }
    }
    public let entries: [String: Entry]
    private let financeUnavailable: Entry
    private let connectionCodes: [String: String]
    public init(data: Data, help: HelpCatalog) throws {
        guard data.count <= 256_000, case .object(let top) = try JSONText.parse(data), Set(top.map(\.0)) == ["schemaVersion", "guidance", "financeUnavailable", "connectionCodes"], top.count == 4 else { throw Failure.invalid }
        let value = JSONText.object(top)
        guard value["schemaVersion"] == .number(1), case .object(let rows)? = value["guidance"], !rows.isEmpty, rows.count <= 256, Set(rows.map(\.0)).count == rows.count,
              let special = value["financeUnavailable"], case .object(let codes)? = value["connectionCodes"], codes.count == 6, Set(codes.map(\.0)).count == codes.count else { throw Failure.invalid }
        let ids = Set(help.topics.map(\.id)); var entries: [String: Entry] = [:], connection: [String: String] = [:]
        for (code, row) in rows {
            guard code.range(of: #"\ASB-[A-Z-]{1,100}\z"#, options: .regularExpression) != nil else { throw Failure.invalid }
            entries[code] = try Entry(row, helpTopics: ids)
        }
        for (status, code) in codes {
            guard ["apple_auth", "apple_access", "apple_agreement", "keychain", "apple", "empty"].contains(status), let text = code.text, entries[text]?.target.area == .accounts || entries[text]?.target.area == .developerAccount else { throw Failure.invalid }
            connection[status] = text
        }
        self.entries = entries; financeUnavailable = try Entry(special, helpTopics: ids); connectionCodes = connection
    }
    public func entry(_ code: String?, module: Module? = nil) -> Entry? {
        guard let code else { return nil }
        if module == .finance, code == "SB-REPORT-UNAVAILABLE" { return financeUnavailable }
        if module == .finance, code == "SB-REPORT-ACCESS" { return entries["SB-FINANCE-ACCESS"] }
        return entries[code]
    }
    public func connection(_ status: String?) -> Entry? { status.flatMap { connectionCodes[$0] }.flatMap { entries[$0] } }
    public func message(_ code: String, module: Module? = nil) -> String {
        if let message = entry(code, module: module)?.message { return message }
        return ReportingMessages.message(module == .finance && code == "SB-REPORT-ACCESS" ? "SB-FINANCE-ACCESS" : code)
    }
    public static func bundled(in bundle: Bundle = .main) throws -> Self {
        do { return try Self(data: CoreResources.json("recovery-guidance", in: bundle), help: HelpCatalog.bundled(in: bundle)) }
        catch HelpCatalog.Failure.unavailable { throw Failure.unavailable }
    }
}

enum CoreResources {
    static func json(_ name: String, in bundle: Bundle) throws -> Data {
        let roots = [bundle.resourceURL, bundle.bundleURL, bundle.executableURL?.deletingLastPathComponent()].compactMap { $0 }
        for root in roots {
            if let resource = Bundle(url: root.appendingPathComponent("Storebench_StorebenchCore.bundle"))?.url(forResource: name, withExtension: "json"), FileManager.default.fileExists(atPath: resource.path) { return try Data(contentsOf: resource) }
        }
        throw HelpCatalog.Failure.unavailable
    }
}
