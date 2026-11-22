import Foundation

/// How hard Storebench works behind the open screen on this Mac: how many requests go to App Store Connect at once, how often
/// it reads ahead and how many other apps it prepares. What the open screen asks for is always read, and saved work is unaffected.
public struct WorkPolicy: Equatable, Sendable, Codable {
    public enum Level: String, CaseIterable, Sendable, Codable {
        case automatic, full, balanced, light
        public var title: String { rawValue.prefix(1).uppercased() + String(rawValue.dropFirst()) }
    }
    /// What this Mac reports about itself, for Automatic.
    public struct Conditions: Equatable, Sendable {
        public let lowPower: Bool, thermal: ProcessInfo.ThermalState
        public init(lowPower: Bool = false, thermal: ProcessInfo.ThermalState = .nominal) { self.lowPower = lowPower; self.thermal = thermal }
        /// Guarded test runs always see a cool Mac on power, so their timing does not follow the machine they run on.
        public static var current: Conditions {
            Network.testMode ? Conditions() : Conditions(lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, thermal: ProcessInfo.processInfo.thermalState)
        }
    }
    /// What one level allows.
    public struct Plan: Equatable, Sendable {
        public let level: Level
        /// Requests to App Store Connect running at once, in all and behind the open screen.
        public let requests: AppleReadAdmission.Limits
        /// The scheduled background check runs this many times less often.
        public let backgroundIntervalFactor: Int
        /// Whether the scheduled background check also runs while another app is in front.
        public let readsWhileInactive: Bool
        /// The most apps prepared ahead, whatever Background Preparation allows; nil leaves that setting alone.
        public let preparedApps: Int?
        /// Whether release status and pricing are also read ahead on the scheduled check.
        public let preparesOnSchedule: Bool
        /// Whether the interface animates its changes.
        public let animations: Bool

        public static let full = Plan(.full)
        init(_ level: Level) {
            self.level = level
            var limits = AppleReadAdmission.Limits()
            switch level {
            case .balanced:
                limits.active = 4; limits.nextActive = 3; limits.backgroundActive = 2; limits.accountActive = 3
                backgroundIntervalFactor = 2; readsWhileInactive = false; preparedApps = 3; preparesOnSchedule = true; animations = true
            case .light:
                limits.active = 3; limits.nextActive = 2; limits.backgroundActive = 1; limits.accountActive = 2
                backgroundIntervalFactor = 5; readsWhileInactive = false; preparedApps = 1; preparesOnSchedule = false; animations = false
            case .full, .automatic:
                backgroundIntervalFactor = 1; readsWhileInactive = true; preparedApps = nil; preparesOnSchedule = true; animations = true
            }
            requests = limits
        }
    }

    public var level: Level
    public init(level: Level = .automatic) { self.level = level }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(level: (try? values.decode(Level.self, forKey: .level)) ?? .automatic)
    }

    /// The level Automatic chooses: Light in Low Power Mode or on a hot Mac, Balanced on a warm one, otherwise Full.
    public static func recommended(_ conditions: Conditions) -> Level {
        if conditions.lowPower || conditions.thermal == .serious || conditions.thermal == .critical { return .light }
        return conditions.thermal == .fair ? .balanced : .full
    }
    public func resolved(_ conditions: Conditions = .current) -> Level { level == .automatic ? Self.recommended(conditions) : level }
    public func plan(_ conditions: Conditions = .current) -> Plan { Plan(resolved(conditions)) }

    /// Remembered on this Mac, not in the workspace, because it follows this Mac's power and temperature.
    public static let defaultsKey = "performance.workPolicy"
    public static func stored(in defaults: UserDefaults) -> WorkPolicy {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(WorkPolicy.self, from: $0) } ?? WorkPolicy()
    }
    public func save(in defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

/// Tells its owner when this Mac enters or leaves Low Power Mode or changes temperature, until it is released.
final class WorkConditionWatch: @unchecked Sendable {
    private var observers: [NSObjectProtocol] = []
    init(_ changed: @escaping @MainActor @Sendable () -> Void) {
        for name in [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in MainActor.assumeIsolated { changed() } })
        }
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}
