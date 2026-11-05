import Foundation

public enum ShortcutCommand: String, CaseIterable, Codable, Sendable {
    case settings, help, save, refresh, syncApp, syncAll, retry, stop, chooseImages, nextSection, previousSection, back, forward
    case overview, apps, appOverview, information, history, journal, transfer, release, quickRelease, localizations, keywords, media, assetLibrary, createMedia, pricing, reviewInfo, publish
    case builds, groups, testers, testInformation, sales, analytics, aso, asoDiff, finance, reviews
    case startTesting, setUpReports, pricingAvailability, appPrivacy, accessibility, inAppPurchases, subscriptions, feedback, externalTesting
    public var section: AppNavigation.Section? {
        switch self {
        case .appOverview: .overview
        case .information: .information
        case .history: .history
        case .journal: .journal
        case .transfer: .transfer
        case .release: .release
        case .quickRelease: .quickRelease
        case .localizations: .localizations
        case .keywords: .keywords
        case .media: .media
        case .assetLibrary: .assetLibrary
        case .createMedia: .createMedia
        case .pricing: .pricing
        case .reviewInfo: .reviewInfo
        case .publish: .publish
        case .builds: .builds
        case .groups: .groups
        case .testers: .testers
        case .testInformation: .testInformation
        case .sales: .sales
        case .analytics: .analytics
        case .aso: .aso
        case .asoDiff: .asoDiff
        case .finance: .finance
        case .reviews: .reviews
        case .startTesting: .startTesting
        case .setUpReports: .setUpReports
        case .pricingAvailability: .pricingAvailability
        case .appPrivacy: .appPrivacy
        case .accessibility: .accessibility
        case .inAppPurchases: .inAppPurchases
        case .subscriptions: .subscriptions
        case .feedback: .feedback
        case .externalTesting: .externalTesting
        default: nil
        }
    }
    public var title: String {
        if let section { return section.title }
        return switch self {
        case .settings: "Settings"
        case .help: "Storebench Help"
        case .save: "Save Local Drafts"
        case .refresh: "Refresh Current View"
        case .syncApp: "Sync Current App"
        case .syncAll: "Sync All Apps"
        case .retry: "Retry Unfinished Sync"
        case .stop: "Stop Current Sync"
        case .chooseImages: "Choose Screenshots"
        case .nextSection: "Next Section"
        case .previousSection: "Previous Section"
        case .back: "Back"
        case .forward: "Forward"
        case .overview: "Workspace Overview"
        case .apps: "Connected Apps"
        default: rawValue
        }
    }
    public var group: String { section != nil || [.overview, .apps, .nextSection, .previousSection, .back, .forward].contains(self) ? "Navigation" : "Actions" }
    public var defaultSpecification: String? {
        switch self {
        case .settings: "command+,"
        case .help: "command+shift+/"
        case .save: "command+s"
        case .refresh: "command+r"
        case .syncApp: "command+shift+r"
        case .syncAll: "command+option+shift+r"
        case .retry: "command+option+r"
        case .stop: "command+."
        case .chooseImages: "command+shift+i"
        case .nextSection: "control+tab"
        case .previousSection: "control+shift+tab"
        case .back: "command+["
        case .forward: "command+]"
        case .overview: "command+1"
        case .apps: "command+2"
        case .release: "command+3"
        case .localizations: "command+4"
        case .keywords: "command+5"
        case .media: "command+6"
        case .pricing: "command+7"
        case .publish: "command+8"
        case .builds: "command+9"
        default: nil
        }
    }
}

public struct ShortcutBinding: Hashable, Sendable {
    public enum Modifier: String, CaseIterable, Sendable { case control, option, shift, command }
    public let key: String
    public let modifiers: Set<Modifier>
    public init(key: String, modifiers: Set<Modifier>) throws {
        let key = key.precomposedStringWithCanonicalMapping.lowercased()
        let named = ["tab", "space", "return", "escape", "left", "right", "up", "down"]
        let character = key.unicodeScalars.count == 1 && key.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) || ",./;'-=[]\\`".unicodeScalars.contains($0) }
        let function = (1...20).contains(where: { key == "f\($0)" })
        guard key.utf8.count <= 8, named.contains(key) || character || function,
              modifiers.contains(.command) || modifiers.contains(.control) else { throw ShortcutKeymap.Failure.invalid }
        self.key = key; self.modifiers = modifiers
    }
    public init(specification: String) throws {
        guard specification.utf8.count <= 100 else { throw ShortcutKeymap.Failure.invalid }
        let parts = specification.lowercased().split(separator: "+", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let key = parts.last, parts.count >= 2 else { throw ShortcutKeymap.Failure.invalid }
        let aliases = ["cmd": "command", "ctrl": "control", "alt": "option"]
        let modifiers = try parts.dropLast().map { part -> Modifier in
            guard let value = Modifier(rawValue: aliases[part] ?? part) else { throw ShortcutKeymap.Failure.invalid }; return value
        }
        guard Set(modifiers).count == modifiers.count else { throw ShortcutKeymap.Failure.invalid }
        try self.init(key: key, modifiers: Set(modifiers))
    }
    public var specification: String { (Modifier.allCases.filter(modifiers.contains).map(\.rawValue) + [key]).joined(separator: "+") }
    public var display: String {
        (Modifier.allCases.filter(modifiers.contains).map { $0 == .command ? "Cmd" : $0 == .control ? "Ctrl" : $0.rawValue.capitalized } + [key.count == 1 ? key.uppercased() : key.capitalized]).joined(separator: "+")
    }
    public var reserved: Bool {
        if modifiers == [.control], ["a", "b", "d", "e", "f", "h", "k", "l", "n", "o", "p", "t", "u", "v", "y"].contains(key) { return true }
        if modifiers == [.command], [",", "q", "w", "m", "h", "n", "t", "c", "x", "v", "z", "a", "f", "g", "p", "o", "`", "space", "tab", "return"].contains(key) { return true }
        if modifiers == [.command, .shift], ["z", "n", "w", "t", "g", "s", "3", "4", "5"].contains(key) { return true }
        if modifiers == [.command, .option], ["h", "w", "m", "escape", "space"].contains(key) { return true }
        if ["left", "right", "up", "down"].contains(key) { return true }
        return key == "escape" || key == "return" || key == "space"
    }
}

public struct ShortcutKeymap: Sendable {
    public enum Failure: Error, Equatable { case invalid, reserved, fixed, conflict(ShortcutCommand) }
    private struct Document: Codable { let schemaVersion: Int; let overrides: [String: String] }
    public let overrides: [String: String]
    private let bindings: [ShortcutCommand: ShortcutBinding]
    private let commands: [ShortcutBinding: ShortcutCommand]
    public init(overrides: [String: String] = [:]) throws {
        guard overrides.count <= ShortcutCommand.allCases.count, overrides.keys.allSatisfy({ ShortcutCommand(rawValue: $0) != nil }) else { throw Failure.invalid }
        var bindings: [ShortcutCommand: ShortcutBinding] = [:], normalized: [String: String] = [:], commands: [ShortcutBinding: ShortcutCommand] = [:]
        let explicitBindings = Set(overrides.values.compactMap { try? ShortcutBinding(specification: $0) })
        for command in ShortcutCommand.allCases {
            if command == .settings, overrides[command.rawValue] != nil { throw Failure.fixed }
            var value = overrides[command.rawValue] ?? command.defaultSpecification
            if (command == .back || command == .forward), overrides[command.rawValue] == nil,
               let binding = value.flatMap({ try? ShortcutBinding(specification: $0) }), explicitBindings.contains(binding) { value = "none" }
            guard let value else { continue }
            if value == "none" { normalized[command.rawValue] = value; continue }
            let binding = try ShortcutBinding(specification: value)
            let historyArrow = (command == .back || command == .forward) && binding.modifiers == [.command, .option] && ["left", "right"].contains(binding.key)
            guard command == .settings || historyArrow || !binding.reserved else { throw Failure.reserved }
            if let existing = commands[binding] { throw Failure.conflict(existing) }
            bindings[command] = binding; commands[binding] = command
            if overrides[command.rawValue] != nil, command.defaultSpecification.flatMap({ try? ShortcutBinding(specification: $0) }) != binding { normalized[command.rawValue] = binding.specification }
        }
        self.overrides = normalized; self.bindings = bindings; self.commands = commands
    }
    public init(serialized: String) throws {
        guard serialized.utf8.count <= 16_384, let data = serialized.data(using: .utf8), let document = try? JSONDecoder().decode(Document.self, from: data), document.schemaVersion == 1 else { throw Failure.invalid }
        try self.init(overrides: document.overrides)
    }
    public func binding(_ command: ShortcutCommand) -> ShortcutBinding? { bindings[command] }
    public func command(_ binding: ShortcutBinding) -> ShortcutCommand? { commands[binding] }
    public func replacing(_ command: ShortcutCommand, specification: String?) throws -> Self {
        guard command != .settings else { throw Failure.fixed }
        var next = overrides; next[command.rawValue] = specification
        return try Self(overrides: next)
    }
    public func serialized() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(Document(schemaVersion: 1, overrides: overrides)), as: UTF8.self)
    }
}

public enum KeyboardNavigation {
    public static func adjacent<ID: Equatable>(_ ids: [ID], current: ID?, direction: Int) -> ID? {
        guard !ids.isEmpty, direction == -1 || direction == 1 else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else { return direction == 1 ? ids.first : ids.last }
        return ids[(index + direction + ids.count) % ids.count]
    }
}

public enum ShortcutDispatchPolicy {
    public static func allows(_ command: ShortcutCommand, enabled: Bool, recording: Bool, modal: Bool, repeated: Bool) -> Bool {
        enabled && !recording && !modal && (!repeated || command == .nextSection || command == .previousSection)
    }
}

public struct ShortcutRecording: Sendable {
    private var owner: UUID?
    public init() {}
    public var active: Bool { owner != nil }
    public mutating func update(active: Bool, owner: UUID) {
        if active { self.owner = owner }
        else if self.owner == owner { self.owner = nil }
    }
}
