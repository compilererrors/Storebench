import Foundation

public struct AsoPoint: Sendable, Equatable, Codable { public let date: String; public let value: Double }

public struct AsoTextSegment: Sendable, Equatable, Codable { public enum Kind: String, Sendable, Codable { case same, added, removed }; public let kind: Kind; public var text: String }

public struct AsoFieldChange: Sendable, Equatable, Identifiable, Codable {
    public enum Kind: String, Sendable, Codable { case list, text, media }
    public let key, section, field, locale: String, kind: Kind, added, removed: [String], segments: [AsoTextSegment]
    public var id: String { key }
}

public struct AsoProgressRow: Sendable, Equatable, Identifiable, Codable {
    public let id, at, date, version, platform: String, previousVersion: String?, isUpdate, dateKnown, baseline: Bool, changes: [AsoFieldChange]
}

public struct AsoImpact: Sendable, Equatable {
    public enum Basis: String, Sendable { case total, daily, missing }
    public let days: Int, basis: Basis, before, after, change, percent: Double?, beforeDays, afterDays: Int, future: Bool
}

/// Measures, change rows and before/after comparisons for listing changes.
public enum AsoProgress {
    public static let metrics: [(key: String, title: String)] = [("searchImpressions", "Search impressions"), ("searchViews", "Search page views"), ("searchFirst", "Search downloads"),
                                                                 ("impressions", "Impressions"), ("views", "Product page views"), ("get", "Get taps"), ("first", "First-time downloads"), ("paid", "Paid purchases"), ("free", "Free downloads (Sales)")]
    public static let rates: [(key: String, title: String, numerator: String, denominator: String)] = [
        ("viewRate", "Page views per 100 impressions", "views", "impressions"), ("tapRate", "Get taps per 100 page views", "get", "views"),
        ("searchViewRate", "Search page views per 100 search impressions", "searchViews", "searchImpressions")]
    static let ignored: Set<String> = ["whatsNew", "marketingUrl", "supportUrl"]

    struct Snapshot { let base: ASO.Snapshot; let at: String; let isUpdate, dateKnown: Bool; let platform, number: String }

    static func byVersion(_ a: String, _ b: String) -> ComparisonResult { a.compare(b, options: .numeric) }
    static func index(_ date: String) -> Int? { PeriodDates.number(date) }
    static func day(_ index: Int) -> String { PeriodDates.text(index) }

    /// Statistics use only confirmed released imports, anchored to the observed listing rather than draft creation.
    static func snapshots(_ revisions: [Revision]) -> [Snapshot] {
        let imported = revisions.filter { $0.origin == nil }, lookup = Dictionary(imported.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>(), result: [Snapshot] = []
        for snapshot in ASO.versionSnapshots(imported, releasedOnly: true).sorted(by: { ($0.savedAt, "\($0.revisionId):\($0.versionId)") < ($1.savedAt, "\($1.revisionId):\($1.versionId)") }) {
            guard let revision = lookup[snapshot.revisionId], let version = revision.versions.first(where: { $0.id == snapshot.versionId }) else { continue }
            let platform = version.fields["platform"]?.text ?? "App", number = version.fields["versionString"]?.text ?? version.id
            if !seen.contains(snapshot.version) {
                seen.insert(snapshot.version)
                result.append(Snapshot(base: snapshot, at: snapshot.savedAt, isUpdate: false, dateKnown: true, platform: Releases.platformName(platform), number: number))
                continue
            }
            let newest = revision.versions.filter { $0.released && ($0.fields["platform"]?.text ?? "App") == platform }.map { $0.fields["versionString"]?.text ?? $0.id }.max { byVersion($0, $1) == .orderedAscending }
            if number == newest { result.append(Snapshot(base: snapshot, at: snapshot.savedAt, isUpdate: true, dateKnown: true, platform: Releases.platformName(platform), number: number)) }
        }
        return result
    }

    public static func listChange(_ before: String, _ after: String) -> (added: [String], removed: [String]) {
        func terms(_ text: String) -> [String] { text.split(separator: ",").map { TextSemantics.trim(String($0)) }.filter { !$0.isEmpty } }
        let previous = terms(before), next = terms(after), had = Set(previous.map { Array($0.lowercased().utf8) }), has = Set(next.map { Array($0.lowercased().utf8) })
        return (next.filter { !had.contains(Array($0.lowercased().utf8)) }, previous.filter { !has.contains(Array($0.lowercased().utf8)) })
    }

    static func tokens(_ text: String) -> [String] {
        var result: [String] = [], current = "", space: Bool?
        for character in text.unicodeScalars {
            let isSpace = TextSemantics.whitespace.contains(character)
            if let space, space != isSpace { result.append(current); current = "" }
            current.unicodeScalars.append(character); space = isSpace
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Whitespace-preserving longest common subsequence diff; oversized inputs use whole-text replacement.
    public static func wordDiff(_ before: String, _ after: String) -> [AsoTextSegment] {
        let a = tokens(before), b = tokens(after)
        if a.count * b.count > 1_500_000 { return merge((before.isEmpty ? [] : [AsoTextSegment(kind: .removed, text: before)]) + (after.isEmpty ? [] : [AsoTextSegment(kind: .added, text: after)])) }
        var table = Array(repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) { for j in stride(from: b.count - 1, through: 0, by: -1) { table[i][j] = TextSemantics.same(a[i], b[j]) ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1]) } }
        var segments: [AsoTextSegment] = [], i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count && j < b.count && TextSemantics.same(a[i], b[j]) { segments.append(.init(kind: .same, text: a[i])); i += 1; j += 1 }
            else if i < a.count && (j >= b.count || table[i + 1][j] >= table[i][j + 1]) { segments.append(.init(kind: .removed, text: a[i])); i += 1 }
            else { segments.append(.init(kind: .added, text: b[j])); j += 1 }
        }
        return merge(segments)
    }
    static func merge(_ segments: [AsoTextSegment]) -> [AsoTextSegment] {
        var merged: [AsoTextSegment] = []
        for segment in segments { if let last = merged.last, last.kind == segment.kind { merged[merged.count - 1].text += segment.text } else { merged.append(segment) } }
        return merged
    }

    static func locale(_ key: String) -> String {
        let parts = key.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        return parts[0] == "info" ? (parts.count > 1 ? parts[1] : "") : (parts.count > 2 ? parts[2] : "")
    }

    static func fieldChange(_ key: String, _ section: String, _ field: String, _ before: String, _ after: String) -> AsoFieldChange {
        let locale = locale(key)
        if field.hasPrefix("screenshots") || field == "keywords" {
            let change = listChange(before, after)
            return AsoFieldChange(key: key, section: section, field: field, locale: locale, kind: field == "keywords" ? .list : .media, added: change.added, removed: change.removed, segments: [])
        }
        let segments = wordDiff(before, after)
        func words(_ kind: AsoTextSegment.Kind) -> [String] { segments.filter { $0.kind == kind }.map { TextSemantics.trim($0.text) }.filter { !$0.isEmpty } }
        return AsoFieldChange(key: key, section: section, field: field, locale: locale, kind: .text, added: words(.added), removed: words(.removed), segments: segments)
    }

    /// Rows ordered by date and version. New versions compare with the latest earlier state of their platform; updates with the same version's previous state.
    public static func rows(_ revisions: [Revision], locale filter: String? = nil, fields: [String] = []) -> [AsoProgressRow] {
        let snapshots = snapshots(revisions)
        var sortDate: [Int: String] = [:]
        for platform in Set(snapshots.map(\.platform)) {
            var carried = "0000-00-00"
            for (offset, item) in snapshots.enumerated().filter({ $0.element.platform == platform && !$0.element.isUpdate }).sorted(by: { byVersion($0.element.number, $1.element.number) == .orderedAscending }) {
                if item.dateKnown { carried = String(item.at.prefix(10)) }
                sortDate[offset] = carried
            }
        }
        let ordered = snapshots.enumerated().sorted { x, y in
            let a = x.element, b = y.element, da = sortDate[x.offset] ?? String(a.at.prefix(10)), db = sortDate[y.offset] ?? String(b.at.prefix(10))
            if da != db { return da < db }
            if a.isUpdate != b.isUpdate { return !a.isUpdate }
            if a.platform != b.platform { return a.platform < b.platform }
            let version = byVersion(a.number, b.number)
            return version != .orderedSame ? version == .orderedAscending : a.base.savedAt < b.base.savedAt
        }.map(\.element)
        var latestPlatform: [String: Snapshot] = [:], latestVersion: [String: Snapshot] = [:]
        return ordered.map { snapshot in
            let previous = snapshot.isUpdate ? latestVersion[snapshot.base.version] : latestPlatform[snapshot.platform]
            latestPlatform[snapshot.platform] = snapshot; latestVersion[snapshot.base.version] = snapshot
            var changes: [AsoFieldChange] = []
            if let previous {
                let before = Dictionary(previous.base.fields.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last }), after = Dictionary(snapshot.base.fields.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
                var keys: [String] = []; for key in previous.base.fields.map(\.key) + snapshot.base.fields.map(\.key) where !keys.contains(key) { keys.append(key) }
                for key in keys {
                    let old = before[key], next = after[key], field = next?.field ?? old!.field
                    guard !TextSemantics.same(old?.value ?? "", next?.value ?? ""), !ignored.contains(field), (filter.map({ $0.isEmpty || locale(key) == $0 }) ?? true), fields.isEmpty || fields.contains(where: { field == $0 || field.hasPrefix($0 + " ·") }) else { continue }
                    changes.append(fieldChange(key, next?.section ?? old!.section, field, old?.value ?? "", next?.value ?? ""))
                }
                changes.sort {
                let order = $0.locale.compare($1.locale, locale: Locale(identifier: "en_US"))
                return order == .orderedSame ? $0.field.compare($1.field, locale: Locale(identifier: "en_US")) == .orderedAscending : order == .orderedAscending
            }
            }
            return AsoProgressRow(id: "\(snapshot.base.revisionId):\(snapshot.base.versionId)", at: snapshot.at, date: String(snapshot.at.prefix(10)), version: snapshot.base.version, platform: snapshot.platform,
                                  previousVersion: previous?.base.version, isUpdate: snapshot.isUpdate, dateKnown: snapshot.dateKnown, baseline: previous == nil, changes: changes)
        }
    }

    public static func locales(_ revisions: [Revision]) -> [String] {
        Array(Set(ASO.versionSnapshots(revisions, releasedOnly: true).flatMap { $0.fields.map { locale($0.key) } }.filter { !$0.isEmpty })).sorted()
    }

    /// Saved daily reports prefer the first standard report for a date, matching Progress and Compare.
    public static func points(_ metric: String, analytics: [AnalyticsPeriod], sales: [SalesPresentation.Period]) -> [AsoPoint] {
        if metric == "free" {
            return sales.filter { $0.beginDate == $0.endDate && $0.detailsComplete }
                .map { AsoPoint(date: $0.beginDate, value: $0.rows.reduce(0) { $0 + Double($1.free) }) }.sorted { $0.date < $1.date }
        }
        guard let measured = ["searchImpressions": "impressions", "searchViews": "views", "searchFirst": "first"][metric] else {
            return AsoComparison.points(metric, analytics: analytics, sales: sales)
        }
        var chosen: [String: AnalyticsPeriod] = [:]
        for period in analytics where period.kind == (measured == "first" ? "downloads" : "engagement") && period.granularity == "DAILY" && period.date == period.endDate {
            if let prior = chosen[period.date], prior.level == "standard" || period.level != "standard" { continue }
            chosen[period.date] = period
        }
        return chosen.values.map { period in
            AsoPoint(date: period.date, value: period.facts.filter { $0.metric == measured && $0.source == "App Store search" }.reduce(0) { $0 + $1.count })
        }.sorted { $0.date < $1.date }
    }

    static func coverage(_ points: [AsoPoint], _ date: String, _ days: Int) -> (before: [Double?], after: [Double?])? {
        Reports(["metric": points]).coverage("metric", date: date, days: days)
    }

    public static func dayNumber(_ date: String) -> Int? { index(date) }

    /// The total for the days after a date, only when every one of them was reported.
    public static func afterTotal(_ points: [AsoPoint], date: String, days: Int) -> (total: Double?, saved: Int) {
        guard let coverage = coverage(points, date, days) else { return (nil, 0) }
        let saved = coverage.after.compactMap { $0 }
        return (saved.count == days ? saved.reduce(0, +) : nil, saved.count)
    }

    /// Before and after a change, excluding the change day. Missing days are never counted as zero.
    public static func impact(_ points: [AsoPoint], date: String, days: Int, today: String) -> AsoImpact {
        Reports(["metric": points]).impact("metric", date: date, days: days, today: today)
    }

    /// A ratio per 100 over the same reported days before and after a change.
    public static func rateImpact(_ numerator: [AsoPoint], _ denominator: [AsoPoint], date: String, days: Int) -> AsoRateImpact {
        Reports(["numerator": numerator, "denominator": denominator]).rate("numerator", "denominator", date: date, days: days)
    }


}

extension WorkspaceSession {
    /// Listing change rows for this app's imported versions.
    public func asoProgress(accountId: String, appId: String) throws -> (revisions: [Revision], locales: [String], primaryLocale: String) {
        let revisions = try self.revisions(accountId: accountId, appId: appId)
        return (revisions, AsoProgress.locales(revisions), revisions.first?.app.primaryLocale ?? "")
    }
}
