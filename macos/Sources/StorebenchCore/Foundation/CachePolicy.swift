import Foundation

/// How much this Mac keeps in memory between screens, and how long a read from App Store Connect is reused.
/// Session and window memory follow it. Credentials are unaffected, publishing always reads Apple again and saved work is kept.
public struct CachePolicy: Equatable, Sendable, Codable {
    public enum Level: String, CaseIterable, Sendable, Codable {
        case automatic, conservative, balanced, responsive, performance, maximum, custom
        public var title: String { rawValue.prefix(1).uppercased() + String(rawValue.dropFirst()) }
    }
    /// One cache's entry count and estimated retained bytes.
    public struct Limit: Equatable, Sendable {
        public let count: Int, bytes: Int
        public init(count: Int, bytes: Int) { self.count = count; self.bytes = bytes }
    }

    public static let memoryRange = 32...4_096
    public static let lifetimeRange = 1...60
    public static let memoryChoices = [32, 64, 128, 192, 256, 384, 512, 768, 1_024, 1_536, 2_048, 3_072, 4_096]
    public static let lifetimeChoices = [1, 2, 3, 5, 10, 15, 20, 30, 45, 60]

    public var level: Level
    /// Used by Custom; the other levels use their own budget.
    public var customMemoryMB: Int
    public var customLifetimeMinutes: Int

    public init(level: Level = .automatic, customMemoryMB: Int = 192, customLifetimeMinutes: Int = 3) {
        self.level = level
        self.customMemoryMB = min(max(customMemoryMB, Self.memoryRange.lowerBound), Self.memoryRange.upperBound)
        self.customLifetimeMinutes = min(max(customLifetimeMinutes, Self.lifetimeRange.lowerBound), Self.lifetimeRange.upperBound)
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(level: (try? values.decode(Level.self, forKey: .level)) ?? .automatic,
                  customMemoryMB: (try? values.decode(Int.self, forKey: .customMemoryMB)) ?? 192,
                  customLifetimeMinutes: (try? values.decode(Int.self, forKey: .customLifetimeMinutes)) ?? 3)
    }

    /// The level Automatic chooses for this much memory: more and longer-lived reads on a Mac with more memory.
    public static func recommended(physicalMemory: UInt64) -> Level {
        switch physicalMemory / 1_073_741_824 {
        case ..<12: .balanced
        case ..<24: .responsive
        case ..<48: .performance
        default: .maximum
        }
    }
    public func resolved(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Level {
        level == .automatic ? Self.recommended(physicalMemory: physicalMemory) : level
    }

    public func memoryMB(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Int {
        switch resolved(physicalMemory: physicalMemory) {
        case .conservative: 64
        case .balanced, .automatic: 192
        case .responsive: 384
        case .performance: 768
        case .maximum: 1_536
        case .custom: customMemoryMB
        }
    }
    public func lifetimeMinutes(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Int {
        switch resolved(physicalMemory: physicalMemory) {
        case .conservative: 1
        case .balanced, .automatic: 3
        case .responsive: 5
        case .performance: 10
        case .maximum: 15
        case .custom: customLifetimeMinutes
        }
    }

    /// Each session cache's share of the memory budget.
    public struct Budget: Equatable, Sendable {
        public let appleReads: Limit, appleReadLifetime: Duration
        public let decodedRevisions: Limit, archivedRevisions: Limit, releaseStatus: Limit, pricingScreens: Limit
        /// Screen reads one window keeps to show at once when a screen opens again, decoded and saved alike.
        public let windowReads: Limit
        /// Screen reads saved by earlier launches that a window loads at start; they count toward `windowReads` once loaded.
        public let savedReads: Limit

        init(memoryMB: Int, lifetimeMinutes: Int) {
            let total = memoryMB * 1_048_576
            func share(_ percent: Int, count: Int) -> Limit { Limit(count: count, bytes: total / 100 * percent) }
            appleReads = share(30, count: min(4_096, max(64, memoryMB * 2)))
            appleReadLifetime = .seconds(lifetimeMinutes * 60)
            decodedRevisions = share(32, count: min(1_024, max(24, memoryMB / 2)))
            archivedRevisions = share(18, count: min(512, max(8, memoryMB / 6)))
            releaseStatus = Limit(count: min(256, max(8, memoryMB / 12)), bytes: max(256 * 1_024, total / 200))
            pricingScreens = share(5, count: min(128, max(4, memoryMB / 24)))
            savedReads = share(8, count: min(1_000, max(100, memoryMB)))
            windowReads = share(12, count: min(512, max(24, memoryMB / 4)))
        }
    }
    public func budget(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Budget {
        Budget(memoryMB: memoryMB(physicalMemory: physicalMemory), lifetimeMinutes: lifetimeMinutes(physicalMemory: physicalMemory))
    }
    /// The budget a session starts with before a policy is applied.
    public static let standardBudget = CachePolicy(level: .balanced).budget()

    /// The policy is remembered on this Mac, not in the workspace, because it follows this Mac's memory.
    public static let defaultsKey = "performance.cachePolicy"
    public static func stored(in defaults: UserDefaults) -> CachePolicy {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(CachePolicy.self, from: $0) } ?? CachePolicy()
    }
    public func save(in defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}
