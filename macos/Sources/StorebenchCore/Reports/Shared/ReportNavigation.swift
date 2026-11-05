import Foundation

/// Read-only report destinations and retained tool visibility; no report or preference writes.
public enum ReportNavigation {
    public static func section(_ area: RecoveryGuidance.Target.Area) throws -> RecoveryGuidance.Target {
        guard [.sales, .analytics, .finance].contains(area) else { throw RecoveryGuidance.Failure.invalid }
        return .init(area: area, anchor: nil, focus: nil, accountRecovery: nil, helpTopic: nil, opensConnection: false, analyticsOngoing: false)
    }
    public static func downloads(_ area: RecoveryGuidance.Target.Area) throws -> RecoveryGuidance.Target {
        let anchor: String, focus: String
        switch area {
        case .sales: (anchor, focus) = ("sales-reports", "sales-download-period")
        case .analytics: (anchor, focus) = ("analytics-download", "analytics-download-report")
        case .finance: (anchor, focus) = ("financial-download", "finance-download-period")
        default: throw RecoveryGuidance.Failure.invalid
        }
        return .init(area: area, anchor: anchor, focus: focus, accountRecovery: nil, helpTopic: nil, opensConnection: false, analyticsOngoing: false)
    }
    public static func financialDates(_ periods: [FinancialPresentation.Period], basis: String) -> [FinancialPresentation.Period] {
        var dates: [String: FinancialPresentation.Period] = [:]
        for period in periods where period.basis == basis { dates[period.dateKey] = period }
        return dates.values.sorted { $0.beginDate < $1.beginDate }
    }
    public static func financialSalesRange(_ periods: [FinancialPresentation.Period], basis: String, fiscal: String) throws -> SalesPresentation.Range? {
        guard let period = financialDates(periods, basis: basis).first(where: { $0.dateKey == fiscal }) else { return nil }
        return try .init(beginDate: period.beginDate, endDate: period.endDate)
    }
    public struct SalesRequest: Sendable, Equatable {
        public let id: UUID, scope: RecoveryGuidance.Scope, range: SalesPresentation.Range?
        public init(scope: RecoveryGuidance.Scope, range: SalesPresentation.Range?) { id = UUID(); self.scope = scope; self.range = range }
        public func allowed(current: RecoveryGuidance.Scope?, decision: EditorProtectionPolicy.Decision, discardConfirmed: Bool = false) -> Bool {
            let target = RecoveryGuidance.Target(area: .sales, anchor: nil, focus: nil, accountRecovery: nil, helpTopic: nil, opensConnection: false, analyticsOngoing: false)
            return target.resolved(scope: scope)!.allowed(current: current, decision: decision, discardConfirmed: discardConfirmed)
        }
        /// A contextual range overrides this view only; a request without dates keeps its saved choice.
        public func initialRange(current: RecoveryGuidance.Scope?) -> SalesPresentation.Range? { allowed(current: current, decision: .ready) ? range : nil }
    }
    public struct Tools: Sendable, Equatable {
        public private(set) var expanded: Bool, initialized: Bool
        public init(hasData: Bool? = nil) { expanded = hasData.map { !$0 } ?? true; initialized = hasData != nil }
        public mutating func loaded(hasData: Bool) { guard !initialized else { return }; expanded = !hasData; initialized = true }
        public mutating func toggle() { expanded.toggle(); initialized = true }
        public static func requested(_ action: RecoveryGuidance.Action?, current: RecoveryGuidance.Scope?, area: RecoveryGuidance.Target.Area) -> Bool {
            guard let action, action.allowed(current: current, decision: .ready), action.target.area == area,
                  let target = try? downloads(area) else { return false }
            return action.target.opensConnection && [.sales, .finance].contains(area) || action.target.anchor == target.anchor
        }
        @discardableResult public mutating func open(_ action: RecoveryGuidance.Action?, current: RecoveryGuidance.Scope?, area: RecoveryGuidance.Target.Area) -> Bool {
            guard Self.requested(action, current: current, area: area) else { return false }
            expanded = true; initialized = true; return true
        }
        public static func focus(_ action: RecoveryGuidance.Action?, current: RecoveryGuidance.Scope?, field: String, expanded: Bool, available: Bool) -> Bool {
            guard expanded, available, let action, action.allowed(current: current, decision: .ready),
                  requested(action, current: current, area: action.target.area) else { return false }
            return action.target.focus == field
        }
    }
}
