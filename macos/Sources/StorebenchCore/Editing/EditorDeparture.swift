import Foundation
import Observation

/// Saves local drafts through their existing validators and scopes continuation to the latest navigation intent.
@MainActor @Observable public final class EditorDeparture {
    public var policy = EditorProtectionPolicy()
    private var savers: [String: @MainActor () async -> Bool] = [:]
    private var priorities: [String: Int] = [:]
    private var generations: [String: String] = [:]
    private var problems: [String: @MainActor () -> String?] = [:]
    /// After a failed save, the item marked in red that stopped it, so the alert can point to it.
    public private(set) var failure: String?
    private var savingOwners: Set<String> = []
    private let savingPolicyId = UUID().uuidString
    private var intent = UUID()
    public init() {}
    public func begin() -> UUID { intent = UUID(); return intent }
    public func owns(_ ticket: UUID) -> Bool { intent == ticket }
    public enum CloseChoice: Equatable, Sendable { case save, discard, cancel }
    public struct CloseSnapshot: Sendable {
        fileprivate let ticket: UUID, policy: EditorProtectionPolicy, generations: [String: String]
        public let canSave: Bool
        public var hasEdits: Bool { !policy.dirtyIds.isEmpty }
    }
    /// Closing a view leaves admitted jobs owned by the session. Quitting separately drains that session.
    public func beginClose() -> CloseSnapshot {
        .init(ticket: begin(), policy: policy, generations: generations,
              canSave: !policy.dirtyIds.isEmpty && policy.dirtyIds.allSatisfy { savers[$0] != nil })
    }
    public func allowsClose(_ snapshot: CloseSnapshot) -> Bool {
        owns(snapshot.ticket) && snapshot.policy.allowsNavigation(after: policy, discardConfirmed: true) &&
            policy.dirtyIds.allSatisfy { generations[$0] == snapshot.generations[$0] }
    }
    public func ownsClose(_ snapshot: CloseSnapshot) -> Bool { owns(snapshot.ticket) }
    /// Save waits for this exact editor's current work; Discard never revokes a running write's ownership.
    public func finishClose(_ snapshot: CloseSnapshot, choice: CloseChoice, wait: Duration = .seconds(5)) async -> Bool {
        guard choice != .cancel, allowsClose(snapshot) else { return false }
        guard choice == .save else { return true }
        guard snapshot.canSave || policy.dirtyIds.isEmpty else { return failed(nil) }
        let deadline = ContinuousClock.now + wait
        while !policy.dirtyIds.isEmpty && (!savingOwners.isDisjoint(with: policy.dirtyIds) || policy.dirtyIds.contains(where: { policy.isBusy(id: $0) })) {
            guard allowsClose(snapshot), !Task.isCancelled else { return false }
            // Stop waiting for Save, without cancelling or expiring any operation's ownership.
            guard ContinuousClock.now < deadline else { return failed(nil) }
            do { try await Task.sleep(for: .milliseconds(20)) } catch { return false }
        }
        guard allowsClose(snapshot), !Task.isCancelled else { return false }
        if policy.dirtyIds.isEmpty { return true }
        return await saveChanges(for: snapshot.ticket) && allowsClose(snapshot)
    }
    public func register(id: String, priority: Int = 0, generation: String? = nil, problem: (@MainActor () -> String?)? = nil, save: @escaping @MainActor () async -> Bool) {
        savers[id] = save; priorities[id] = priority; generations[id] = generation ?? id; problems[id] = problem
    }
    public func unregisterSave(id: String) { savers.removeValue(forKey: id); priorities.removeValue(forKey: id); generations.removeValue(forKey: id); problems.removeValue(forKey: id) }
    public func remove(id: String) { if savers[id] != nil || savingOwners.contains(id) { _ = begin() }; unregisterSave(id: id); policy.remove(id: id) }
    public var closingPolicy: EditorProtectionPolicy {
        var result = policy
        for id in savingOwners { result.update(id: "saving:\(savingPolicyId):\(id)", dirty: false, busy: true) }
        return result
    }
    public var canSave: Bool {
        !policy.dirtyIds.isEmpty && policy.dirtyIds.allSatisfy { savers[$0] != nil && !policy.isBusy(id: $0) && !savingOwners.contains($0) }
    }
    public func saveChanges(for ticket: UUID) async -> Bool {
        failure = nil
        guard owns(ticket), canSave else { return failed(nil) }
        let owners = policy.dirtyIds
        let startingGenerations = generations
        let ordered = owners.sorted { (priorities[$0] ?? 0, $0) < (priorities[$1] ?? 0, $1) }
        for id in ordered {
            guard owns(ticket), policy.dirtyIds.isSubset(of: owners) else { return failed(nil) }
            if !policy.dirtyIds.contains(id) { continue }
            guard !policy.isBusy(id: id), !savingOwners.contains(id), generations[id] == startingGenerations[id], let save = savers[id] else { return failed(id) }
            savingOwners.insert(id)
            let saved = await save()
            savingOwners.remove(id)
            guard saved, owns(ticket), generations[id] == startingGenerations[id] || generations[id] == nil && !policy.dirtyIds.contains(id) else { return failed(id) }
            // Success means this exact owner's inputs were validated and saved; other owners stay protected.
            policy.update(id: id, dirty: false, busy: policy.isBusy(id: id))
        }
        return owns(ticket) && policy.navigationDecision == .ready || failed(nil)
    }
    /// Records the marked item of the owner that failed, or of the first still-unsaved owner that names one.
    private func failed(_ id: String?) -> Bool {
        let candidates = (id.map { [$0] } ?? []) + policy.dirtyIds.sorted { (priorities[$0] ?? 0, $0) < (priorities[$1] ?? 0, $1) }
        failure = candidates.lazy.compactMap { self.problems[$0]?() }.first { !$0.isEmpty }
        return false
    }
}
