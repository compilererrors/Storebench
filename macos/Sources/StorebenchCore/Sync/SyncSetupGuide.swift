import Foundation

/// The few steps that make report sync work, in order, from the latest setup check or sync.
/// The guide appears only while something is missing; when every source is set up it returns nil.
public enum SyncSetupGuide {
    public enum State: String, Sendable { case done, todo, unknown }
    public struct Step: Identifiable, Sendable, Equatable {
        public let id: String, title: String, detail: String, action: String
        /// The sync source whose view finishes this step; nil for the setup check itself.
        public let source: String?
        public let state: State
    }
    static let reporting: Set<String> = ["SB-SYNC-CONNECTION", "SB-REPORTER-KEYCHAIN", "SB-REPORTER-CHANGED"]
    static let analytics: Set<String> = ["SB-ANALYTICS-SETUP", "SB-ANALYTICS-INACTIVE"]

    public static func steps(_ items: [SyncItem]?) -> [Step]? {
        let all = progress(items)
        return all.contains { $0.state == .todo && $0.id != "sync" } ? all : nil
    }

    /// Every step with its state, also once all of them are done, for the Set Up Reports guide.
    public static func progress(_ items: [SyncItem]?) -> [Step] {
        guard let items, items.contains(where: { $0.state != .pending }) else {
            return [
                Step(id: "check", title: "Check what is set up", detail: "Storebench checks the reporting connection and Analytics reports. Nothing is downloaded.", action: "Check Setup", source: nil, state: .todo),
                reportsStep(.unknown), analyticsStep(.unknown), fiscalStep(.unknown), syncStep(.unknown),
            ]
        }
        func state(_ keys: [String], _ codes: Set<String>) -> State {
            let relevant = items.filter { keys.contains($0.key) }
            if relevant.contains(where: { $0.code.map(codes.contains) == true }) { return .todo }
            return relevant.contains(where: { $0.state == .pending || $0.state == .unchecked }) && relevant.allSatisfy({ $0.state == .pending || $0.state == .unchecked }) ? .unknown : .done
        }
        let reports = state(["sales", "finance"], reporting), analytics = state(["downloads", "engagement"], analytics), fiscal = state(["finance"], ["SB-SYNC-FISCAL-PERIOD"])
        let synced = items.contains { [.synced, .partial].contains($0.state) }
        return [reportsStep(reports), analyticsStep(analytics), fiscalStep(fiscal), syncStep(synced ? .done : .todo)]
    }
    static func reportsStep(_ state: State) -> Step {
        Step(id: "reports", title: "Connect Sales and Trends and financial reports", detail: "Paste a Reporter token from App Store Connect (Trends → Sales and Trends Reports → About Reports (?) → Generate Reporter Token), or save a vendor number for a team key. Done once, in Sales and Trends.", action: "Connect Reports", source: "sales", state: state)
    }
    static func analyticsStep(_ state: State) -> Step {
        Step(id: "analytics", title: "Turn on Analytics reports", detail: "Ask Apple to start preparing Analytics reports for this app. Apple takes a day or two to deliver the first ones.", action: "Set Up Analytics", source: "downloads", state: state)
    }
    static func fiscalStep(_ state: State) -> Step {
        Step(id: "fiscal", title: "Choose Financial report periods", detail: "Pick which fiscal months to download in Payments and Financial Reports. Apple's fiscal months differ from calendar months.", action: "Choose Periods", source: "finance", state: state)
    }
    static func syncStep(_ state: State) -> Step {
        Step(id: "sync", title: "Sync app data", detail: "Downloads every source that is set up. Sources that still need setup are skipped and keep their saved data.", action: "Sync", source: nil, state: state)
    }
}
