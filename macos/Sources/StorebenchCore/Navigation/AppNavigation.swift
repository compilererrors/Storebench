import Foundation

public enum AppNavigation {
    public enum Failure: Error { case invalid }
    /// Guides walk through a task step by step; Distribution, TestFlight and Reports mirror App Store Connect's own pages and names;
    /// Storebench holds the tools App Store Connect does not have.
    public enum Group: String, CaseIterable, Sendable {
        case guides = "Guides", distribution = "Distribution", testflight = "TestFlight", reports = "Trends and Reports", storebench = "Storebench"
        public var key: String { self == .testflight ? "testing" : String(describing: self) }
    }
    public enum Section: String, CaseIterable, Sendable {
        case release = "Version setup", quickRelease = "Quick Release", startTesting = "Start Testing", pricing = "Pricing", createMedia = "Create Media", setUpReports = "Set Up Reports"
        case localizations = "Localizations", media = "Previews and Screenshots", reviewInfo = "App Review Information", information = "App Information"
        case pricingAvailability = "Pricing and Availability", appPrivacy = "App Privacy", accessibility = "Accessibility", inAppPurchases = "In-App Purchases", subscriptions = "Subscriptions", reviews = "Ratings and Reviews"
        case builds = "Builds", feedback = "Feedback", groups = "Internal Testing", externalTesting = "External Testing", testers = "All Testers", testInformation = "Test Information"
        case analytics = "Analytics", sales = "Sales and Trends", finance = "Payments and Financial Reports"
        case overview = "App overview", publish = "App Store changes", history = "History", journal = "Change journal", keywords = "Keyword Ideas", assetLibrary = "Asset Library", aso = "ASO Progress", asoDiff = "ASO Diff", transfer = "Import and Export"
        public var key: String {
            switch self {
            case .media: "screenshots"
            case .quickRelease: "quick-release"
            case .startTesting: "start-testing"
            case .setUpReports: "set-up-reports"
            case .assetLibrary: "asset-library"
            case .createMedia: "create-media"
            case .pricingAvailability: "pricing-and-availability"
            case .appPrivacy: "app-privacy"
            case .inAppPurchases: "in-app-purchases"
            case .builds: "testflight"
            case .feedback: "testflight-feedback"
            case .groups: "testflight-groups"
            case .externalTesting: "testflight-external"
            case .testers: "testflight-testers"
            case .aso: "aso-progress"
            case .asoDiff: "aso-diff"
            case .reviewInfo: "review-information"
            case .testInformation: "test-information"
            default: String(describing: self)
            }
        }
        public init?(key: String) {
            guard let value = Self.allCases.first(where: { $0.key == key }) else { return nil }
            self = value
        }
        public var group: Group {
            switch self {
            case .release, .quickRelease, .startTesting, .pricing, .createMedia, .setUpReports: .guides
            case .localizations, .media, .reviewInfo, .information, .pricingAvailability, .appPrivacy, .accessibility, .inAppPurchases, .subscriptions, .reviews: .distribution
            case .builds, .feedback, .groups, .externalTesting, .testers, .testInformation: .testflight
            case .analytics, .sales, .finance: .reports
            case .overview, .publish, .history, .journal, .keywords, .assetLibrary, .aso, .asoDiff, .transfer: .storebench
            }
        }
        public var usesLanguage: Bool { self == .localizations || self == .media || self == .keywords }
        public var designIcon: String {
            guard let definition = StorebenchDesign.shared.sections.first(where: { $0.key == key }) else { preconditionFailure("Shared navigation icon is missing.") }
            return definition.icon
        }
        public var usesVersion: Bool { self == .localizations || self == .media }
        /// The name shown in the sidebar and page title. Keys stay stable for saved links.
        public var title: String { self == .release ? "Release" : self == .pricing ? "Set Up Pricing" : rawValue }
        /// Where a guide continues once its last step is reached: the page the finished task leads to.
        public var afterGuide: Section? {
            switch self {
            case .release, .setUpReports: .overview
            case .quickRelease, .startTesting, .pricing: .release
            case .createMedia: .media
            default: nil
            }
        }
        /// A guide that walks through the task this App Store Connect page belongs to.
        public var guide: Section? {
            switch self {
            case .localizations, .media, .reviewInfo: .release
            case .pricingAvailability, .inAppPurchases, .subscriptions: .pricing
            case .builds, .feedback, .groups, .externalTesting, .testers, .testInformation: .startTesting
            case .analytics, .sales, .finance: .setUpReports
            case .assetLibrary: .createMedia
            default: nil
            }
        }
        private var path: String {
            switch self { case .overview: ""; case .groups: "/testflight/groups"; case .externalTesting: "/testflight/external"; case .feedback: "/testflight/feedback"; case .testers: "/testflight/testers"; default: "/" + key }
        }
        public func href(scope: RecoveryGuidance.Scope, context: Context? = nil) -> String {
            let selected = context?.forSection(self, scope: scope)
            var query: [String] = []
            if let locale = selected?.locale { query.append("locale=" + AppNavigation.encoded(locale)) }
            if let version = selected?.version { query.append("version=" + AppNavigation.encoded(version)) }
            if selected?.draft == true { query.append("draft=1") }
            return scope.root + path + (query.isEmpty ? "" : "?" + query.joined(separator: "&"))
        }
    }
    public struct Context: Sendable, Equatable {
        public let scope: RecoveryGuidance.Scope
        public let locale, version: String?
        public let draft: Bool
        public init(scope: RecoveryGuidance.Scope, locale: String? = nil, version: String? = nil, draft: Bool = false) throws {
            guard locale == nil || StoreLocales.codes.contains(locale!),
                  version == nil || !version!.isEmpty && version!.utf8.count <= 256 && !version!.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { throw Failure.invalid }
            self.scope = scope; self.locale = locale; self.version = version; self.draft = draft
        }
        /// Another app can retain the language, but cannot retain a version or release-plan choice.
        public func forSection(_ section: Section, scope: RecoveryGuidance.Scope, switchingApp: Bool = false) -> Context? {
            guard section.usesLanguage else { return nil }
            let same = scope == self.scope && !switchingApp && section.usesVersion
            return try! Context(scope: scope, locale: locale, version: same ? version : nil, draft: same && draft)
        }
    }
    public struct Destination: Sendable, Equatable {
        public let source, scope: RecoveryGuidance.Scope
        public let section: Section
        public let context: Context?
        public init(source: RecoveryGuidance.Scope, scope: RecoveryGuidance.Scope, section: Section, context: Context?, switchingApp: Bool = false) {
            self.source = source; self.scope = scope; self.section = section
            self.context = context?.scope == source ? context?.forSection(section, scope: scope, switchingApp: switchingApp) : nil
        }
        public var href: String { section.href(scope: scope, context: context) }
        public func allowed(current: RecoveryGuidance.Scope?, decision: EditorProtectionPolicy.Decision, discardConfirmed: Bool = false) -> Bool {
            guard current == source else { return false }
            return switch decision { case .ready: true; case .confirmDiscard: discardConfirmed; case .wait: false }
        }
    }
    public struct Selection: Sendable, Equatable {
        public let versionId, locale: String
        public let locales: [String]
        public var json: JSONText { .object([("version", .string(versionId)), ("locale", .string(locale))]) }
    }
    /// Resolve only existing saved material. A release draft exposes only its attached version.
    public static func selection(scope: RecoveryGuidance.Scope, versions: [Revision.Version], appInfos: [Revision.AppInfo], context: Context?, section: Section, planVersionId: String? = nil) -> Selection {
        let context = context?.scope == scope ? context : nil
        let versions = context?.draft == true ? versions.filter { $0.id == planVersionId } : versions
        let selected = versions.first { $0.id == context?.version } ?? versions.first
        let appLocales = section == .localizations ? appInfos.flatMap { $0.localizations.map { $0.fields["locale"]?.text ?? $0.id } } : []
        func languages(_ version: Revision.Version) -> [String] {
            var result: [String] = []
            for code in version.localizations.map(\.locale) + appLocales where !result.contains(code) { result.append(code) }
            return result
        }
        let locales = selected.map(languages) ?? []
        let requested = context?.locale ?? versions.first.flatMap { languages($0).first } ?? ""
        return Selection(versionId: selected?.id ?? "", locale: locales.contains(requested) ? requested : locales.first ?? "", locales: locales)
    }
    private static func encoded(_ value: String) -> String {
        var result = ""
        for byte in value.utf8 {
            switch byte {
            case 65...90, 97...122, 48...57, 42, 45, 46, 95: result.append(Character(UnicodeScalar(byte)))
            case 32: result.append("+")
            default: result += String(format: "%%%02X", byte)
            }
        }
        return result
    }
}
