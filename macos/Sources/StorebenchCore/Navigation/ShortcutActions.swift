import Foundation
import Observation

@MainActor @Observable public final class ShortcutActions {
    private struct Entry { let owner: UUID; let priority: Int; let order: Int; let enabled: Bool; let action: @MainActor () async -> Void }
    private var entries: [ShortcutCommand: [UUID: Entry]] = [:]
    private var running: [UUID: UUID] = [:]
    private var order = 0
    public init() {}
    public func register(_ command: ShortcutCommand, owner: UUID, priority: Int = 0, enabled: Bool, action: @escaping @MainActor () async -> Void) {
        order += 1
        entries[command, default: [:]][owner] = Entry(owner: owner, priority: priority, order: order, enabled: enabled, action: action)
    }
    public func remove(_ command: ShortcutCommand, owner: UUID) { entries[command]?.removeValue(forKey: owner) }
    private func entry(_ command: ShortcutCommand) -> Entry? { entries[command]?.values.max { ($0.priority, $0.order) < ($1.priority, $1.order) } }
    public func enabled(_ command: ShortcutCommand) -> Bool { guard let entry = entry(command) else { return false }; return entry.enabled && running[entry.owner] == nil }
    public func busy(_ command: ShortcutCommand) -> Bool { entry(command).map { running[$0.owner] != nil } ?? false }
    public var hasPendingActions: Bool { !running.isEmpty }
    @discardableResult public func perform(_ command: ShortcutCommand) -> Bool {
        guard enabled(command), let entry = entry(command) else { return false }
        let ticket = UUID(); running[entry.owner] = ticket
        Task { @MainActor in
            defer { if running[entry.owner] == ticket { running.removeValue(forKey: entry.owner) } }
            guard self.entry(command)?.owner == entry.owner, self.entry(command)?.enabled == true else { return }
            await entry.action()
        }
        return true
    }
}
