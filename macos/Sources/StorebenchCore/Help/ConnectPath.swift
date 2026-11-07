import Foundation

/// Where to click in App Store Connect for one setup step: Apple's own labels, in order, each with its place on the page.
public struct ConnectPath: Sendable, Equatable {
    public enum Place: String, Sendable {
        case topMenu, accountMenu, tabs, sidebar, pageTopRight, page, opened
        public var description: String {
            switch self {
            case .topMenu: "in the menu at the top"
            case .accountMenu: "at the top right corner"
            case .tabs: "in the row of tabs under the top menu"
            case .sidebar: "in the left sidebar"
            case .pageTopRight: "at the top right of the page"
            case .page: "on the page"
            case .opened: "in the box that opens"
            }
        }
    }
    public struct Stop: Sendable, Equatable {
        public let label: String, place: Place
        /// Replaces the place's own description when the spot needs more words.
        public let detail: String?
        public var location: String { detail ?? place.description }
        init(_ label: String, _ place: Place, _ detail: String? = nil) { self.label = label; self.place = place; self.detail = detail }
    }
    public let stops: [Stop]
    /// The labels in click order, such as "Trends → Sales and Trends Reports".
    public var summary: String { stops.map(\.label).joined(separator: " → ") }

    public static let salesAndTrendsReports = ConnectPath(stops: [
        Stop("Trends", .topMenu),
        Stop("Sales and Trends Reports", .sidebar, "in the left sidebar, under Saved"),
    ])
    public static let reporterToken = ConnectPath(stops: salesAndTrendsReports.stops + [
        Stop("About Reports (?)", .pageTopRight, "at the top right of the page; click the question mark"),
        Stop("Generate Reporter Token", .opened, "in the box that opens, under Reporter"),
    ])
    static let teamKeys = [
        Stop("Users and Access", .topMenu),
        Stop("Integrations", .tabs),
        Stop("App Store Connect API", .sidebar),
        Stop("Team Keys", .page, "a tab on the page"),
    ]
    public static let teamKey = ConnectPath(stops: teamKeys + [Stop("Generate API Key", .page, "on the page; the + button if a key exists")])
    public static let issuerID = ConnectPath(stops: teamKeys + [Stop("Issuer ID", .page, "above the list of keys")])
    public static let individualKey = ConnectPath(stops: [
        Stop("Your name", .accountMenu, "your own name, at the top right corner"),
        Stop("Edit Profile", .opened, "in the menu that opens"),
        Stop("Individual API Key", .page, "a section further down the page"),
        Stop("Generate API Key", .page, "under Individual API Key"),
    ])
}
