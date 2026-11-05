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
