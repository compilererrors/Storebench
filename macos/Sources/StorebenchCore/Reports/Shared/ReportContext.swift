import Foundation

/// Saved reporting definitions and destinations; this never downloads data or changes a preference.
public struct ReportContext: Sendable {
    public enum Failure: Error { case invalid }
    public enum Kind: String, CaseIterable, Sendable {
        case sales, analytics, finance
        public var area: RecoveryGuidance.Target.Area {
            switch self { case .sales: .sales; case .analytics: .analytics; case .finance: .finance }
        }
        public var target: RecoveryGuidance.Target { try! ReportNavigation.section(area) }
    }
    public enum Coverage: Sendable, Equatable { case loading, unavailable, saved([String]) }
    public struct Source: Sendable {
        public let kind: Kind, label, calendar, purpose, description, limits: String
    }
    public struct Related: Sendable, Identifiable {
        public let kind: Kind, label, description, action: String
        public var id: Kind { kind }
    }
    public struct Presentation: Sendable {
        public let title, latest, coverage, description, limits, helpLabel: String
        public let related: [Related]
        public var help: RecoveryGuidance.Target { try! .help("sales") }
        public func json(scope: RecoveryGuidance.Scope) -> JSONText {
            .object([("title", .string(title)), ("latest", .string(latest)), ("coverage", .string(coverage)), ("description", .string(description)), ("limits", .string(limits)),
                ("related", .array(related.map { row in .object([("kind", .string(row.kind.rawValue)), ("label", .string(row.label)), ("description", .string(row.description)), ("action", .string(row.action)), ("href", .string(scope.root + "/" + row.kind.rawValue))]) })),
                ("helpLabel", .string(helpLabel)), ("helpHref", .string("/settings/help#sales"))])
        }
    }
    public let sources: [Source]
    public init(data: Data) throws {
        guard data.count <= 40_000, case .object(let top) = try JSONText.parse(data), top.count == 2,
              Set(top.map(\.0)) == ["schemaVersion", "sources"], JSONText.object(top)["schemaVersion"] == .number(1),
              case .array(let rows)? = JSONText.object(top)["sources"], rows.count == 3 else { throw Failure.invalid }
        func text(_ value: JSONText?) throws -> String {
            guard let value = value?.text, !value.isEmpty, value.utf16.count <= 4096,
                  !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { throw Failure.invalid }
            return value
        }
        sources = try rows.map { row in
            guard case .object(let fields) = row, fields.count == 6,
                  Set(fields.map(\.0)) == ["kind", "label", "calendar", "purpose", "description", "limits"],
                  let kind = row["kind"]?.text.flatMap(Kind.init(rawValue:)) else { throw Failure.invalid }
            return try Source(kind: kind, label: text(row["label"]), calendar: text(row["calendar"]), purpose: text(row["purpose"]), description: text(row["description"]), limits: text(row["limits"]))
        }
        guard sources.map(\.kind) == Kind.allCases else { throw Failure.invalid }
    }
    public func presentation(_ kind: Kind, coverage: Coverage) throws -> Presentation {
        let source = sources.first { $0.kind == kind }!, latest: String
        switch coverage {
        case .loading: latest = "Reading saved report coverage…"
        case .unavailable: latest = "Saved reporting coverage could not be read."
        case .saved(let dates):
            guard dates.count <= 100_000, dates.allSatisfy({ PeriodDates.number($0) != nil }) else { throw Failure.invalid }
            latest = dates.max().map { "Latest saved period ends \($0)." } ?? "No saved periods yet."
        }
        return Presentation(title: source.label + " report basis · " + source.calendar, latest: latest,
            coverage: "This describes saved coverage, not a live sync or a guarantee that earlier days are complete.",
            description: source.description, limits: source.limits + " Each view keeps its own dates and metric definitions.", helpLabel: "Why reporting totals differ",
            related: sources.filter { $0.kind != kind }.map { Related(kind: $0.kind, label: $0.label, description: $0.purpose + ". " + $0.calendar + ".", action: "Open " + $0.label.lowercased()) })
    }
    public static func bundled(in bundle: Bundle = .main) throws -> Self { try Self(data: CoreResources.json("reporting-sources", in: bundle)) }
}
