import Foundation
import Observation

/// Each view loads its own starting choice once; changing Settings affects subsequent view openings.
@MainActor @Observable public final class PeriodSelection {
    public private(set) var preferences: PeriodPreferences?
    public private(set) var status = ""
    private var values: [PeriodKey: PeriodValue] = [:]
    @ObservationIgnored private var pending: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var tickets: [String: UUID] = [:]
    @ObservationIgnored private var scope: PeriodScope?
    @ObservationIgnored private var generation = UUID()
    public init() {}
    public func load(_ session: WorkspaceSession?, scope: PeriodScope? = nil) async {
        if self.scope != scope {
            self.scope = scope; values = [:]; preferences = nil; status = ""; generation = UUID()
        }
        guard preferences == nil, let session else { return }
        let expected = generation
        do { let saved = try await session.periodPreferences(); try Task.checkCancellation(); guard expected == generation else { return }; preferences = saved; status = "" }
        catch { if expected == generation { status = "Period preferences could not be read. Current choices are temporary; reopen this view to retry." } }
    }
    public func days(_ key: PeriodKey) -> Int { if case .days(let days) = values[key] ?? (preferences ?? PeriodPreferences()).value(key, scope: scope) { return days }; return 7 }
    public func range(_ key: PeriodKey) -> PeriodRangeChoice { if case .range(let range) = values[key] ?? (preferences ?? PeriodPreferences()).value(key, scope: scope) { return range }; return .all }
    public func choose(_ key: PeriodKey, _ value: PeriodValue, session: WorkspaceSession?) {
        guard let normalized = try? PeriodValue(key: key, value: value.json) else { return }
        values[key] = normalized
        let identity = (scope.map { $0.accountId + ":" + $0.appId } ?? "workspace") + ":" + key.rawValue
        pending[identity]?.cancel()
        guard preferences?.remember == true, let session else { return }
        let capturedScope = scope, expected = generation, ticket = UUID()
        tickets[identity] = ticket
        pending[identity] = Task { [weak self] in
            defer { if self?.tickets[identity] == ticket { self?.pending.removeValue(forKey: identity); self?.tickets.removeValue(forKey: identity) } }
            do {
                try await Task.sleep(for: .milliseconds(400)); try Task.checkCancellation()
                _ = try await session.rememberPeriod(key, value: normalized, scope: capturedScope)
            } catch is CancellationError { return }
            catch { if self?.generation == expected { self?.status = "This period choice could not be remembered. The current view still uses it." } }
        }
    }
}
