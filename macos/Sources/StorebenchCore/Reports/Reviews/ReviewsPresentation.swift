import Foundation

public enum ReviewsPresentation {
    public struct Filters: Equatable, Sendable {
        public var query = "", rating = "", territory = "", begin = "", end = "", sort = "newest"
        public init(query: String = "", rating: String = "", territory: String = "", begin: String = "", end: String = "", sort: String = "newest") {
            self.query = query; self.rating = rating; self.territory = territory; self.begin = begin; self.end = end; self.sort = sort
        }
        public var validDates: Bool {
            (begin.isEmpty || PeriodDates.number(begin) != nil) && (end.isEmpty || PeriodDates.number(end) != nil) && (begin.isEmpty || end.isEmpty || begin <= end)
        }
        public var json: JSONText { .object([("query", .string(query)), ("rating", .string(rating)), ("territory", .string(territory)), ("begin", .string(begin)), ("end", .string(end)), ("sort", .string(sort))]) }
        public static func == (lhs: Self, rhs: Self) -> Bool { lhs.json == rhs.json }
    }
    public struct Territory: Identifiable, Sendable {
        public var id: String { territory }
        public let territory: String, count: Int, average: Double, low: Int
        public var json: JSONText { .object([("territory", .string(territory)), ("count", .number(Double(count))), ("average", .number(average)), ("low", .number(Double(low)))]) }
    }
    public struct Summary: Sendable {
        public let count: Int, average: Double?, low: Int, ratings: [Int], territories: [Territory]
        public var shouldReadLowFeedback: Bool { count >= 10 && low >= 3 && Double(low) / Double(count) >= 0.3 }
        public var json: JSONText { .object([("count", .number(Double(count))), ("average", average.map(JSONText.number) ?? .null), ("low", .number(Double(low))), ("ratings", .array(ratings.map { .number(Double($0)) })), ("territories", .array(territories.map(\.json)))]) }
    }
    /// Stable sorting keeps the canonical review ID order when dates and ratings are equal.
    public static func filter(_ rows: [CustomerReview], _ filters: Filters) -> [CustomerReview] {
        guard filters.validDates else { return [] }
        let query = TextSemantics.trim(filters.query).lowercased(with: Locale(identifier: "en"))
        return rows.enumerated().filter { _, row in
            (query.isEmpty || (row.title + "\n" + row.body).lowercased(with: Locale(identifier: "en")).range(of: query, options: .literal) != nil) &&
            (filters.rating.isEmpty || (filters.rating == "low" ? row.rating <= 2 : String(row.rating) == filters.rating)) &&
            (filters.territory.isEmpty || row.territory == filters.territory) &&
            (filters.begin.isEmpty || String(row.createdDate.prefix(10)) >= filters.begin) && (filters.end.isEmpty || String(row.createdDate.prefix(10)) <= filters.end)
        }.sorted { lhs, rhs in
            if lhs.element.rating != rhs.element.rating {
                if filters.sort == "lowest" { return lhs.element.rating < rhs.element.rating }
                if filters.sort == "highest" { return lhs.element.rating > rhs.element.rating }
            }
            return lhs.element.createdDate == rhs.element.createdDate ? lhs.offset < rhs.offset : lhs.element.createdDate > rhs.element.createdDate
        }.map(\.element)
    }
    public static func summarize(_ rows: [CustomerReview]) -> Summary {
        var ratings = Array(repeating: 0, count: 5), sum = 0, countries: [String: (count: Int, sum: Int, low: Int)] = [:]
        for row in rows {
            ratings[row.rating - 1] += 1; sum += row.rating
            var country = countries[row.territory] ?? (0, 0, 0); country.count += 1; country.sum += row.rating; if row.rating <= 2 { country.low += 1 }; countries[row.territory] = country
        }
        var territories: [Territory] = []
        for (code, facts) in countries {
            let average = Double(facts.sum) / Double(facts.count)
            territories.append(Territory(territory: code, count: facts.count, average: average, low: facts.low))
        }
        territories.sort { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs.territory.compare(rhs.territory, locale: Locale(identifier: "en")) == .orderedAscending
        }
        return Summary(count: rows.count, average: rows.isEmpty ? nil : Double(sum) / Double(rows.count), low: ratings[0] + ratings[1], ratings: ratings, territories: territories)
    }
    public static func pages(count: Int, size: Int) -> Int { guard count > 0, size > 0 else { return 1 }; return 1 + (count - 1) / size }
    private enum SortValue { case text(String), number(Double) }
    private static func ordered<T>(_ rows: [T], descending: Bool, read: (T) -> SortValue) -> [T] {
        rows.enumerated().sorted { lhs, rhs in
            let left = read(lhs.element), right = read(rhs.element)
            if case .text("") = left { if case .text("") = right { return lhs.offset < rhs.offset }; return false }
            if case .text("") = right { return true }
            let comparison: ComparisonResult
            switch (left, right) {
            case (.number(let a), .number(let b)): comparison = a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
            case (.text(let a), .text(let b)): comparison = a.compare(b, options: [.numeric, .caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en"))
            default: comparison = .orderedSame
            }
            return comparison == .orderedSame ? lhs.offset < rhs.offset : comparison == (descending ? .orderedDescending : .orderedAscending)
        }.map(\.element)
    }
    /// Independent table ordering changes presentation, preserving filter totals and stable equal-value order.
    public static func orderedReviews(_ rows: [CustomerReview], key: String, descending: Bool) -> [CustomerReview] {
        guard ["rating", "date", "territory", "title"].contains(key) else { return rows }
        return ordered(rows, descending: descending) { row in
            switch key {
            case "rating": .number(Double(row.rating))
            case "date": .text(row.createdDate)
            case "territory": .text(row.territory == "UNKNOWN" ? "Unknown territory" : WorkspaceSession.countryName(row.territory))
            default: .text(row.title + " " + row.body)
            }
        }
    }
    public static func orderedTerritories(_ rows: [Territory], key: String, descending: Bool) -> [Territory] {
        guard ["territory", "count", "average", "low"].contains(key) else { return rows }
        return ordered(rows, descending: descending) { row in
            switch key {
            case "count": .number(Double(row.count))
            case "average": .number(row.average)
            case "low": .number(Double(row.low))
            default: .text(row.territory == "UNKNOWN" ? "Unknown territory" : WorkspaceSession.countryName(row.territory))
            }
        }
    }
    public static func page<T>(_ rows: [T], number: Int, size: Int) -> [T] {
        guard size > 0 else { return [] }; let page = min(max(number, 1), pages(count: rows.count, size: size))
        return Array(rows.dropFirst((page - 1) * size).prefix(size))
    }
}
