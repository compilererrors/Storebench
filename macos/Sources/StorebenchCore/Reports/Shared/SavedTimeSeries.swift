import Foundation

/// Saved report periods, gaps and inspection state independent of chart rendering.
public enum SavedTimeSeries {
    public struct Scale: Sendable {
        public let maximum: Double, ticks: [Double]
        public var minimum: Double { ticks.first ?? 0 }
        public var json: JSONText { .object([("max", .number(maximum)), ("ticks", .array(ticks.map(JSONText.number)))]) }
    }
    public static func niceScale(_ maximum: Double, integer: Bool, intervals: Int = 4) -> Scale {
        guard maximum.isFinite, maximum > 0, intervals > 0 else { return Scale(maximum: 1, ticks: [0, 1]) }
        let raw = maximum / Double(intervals), magnitude = pow(10, floor(log10(raw))), residual = raw / magnitude
        var step = (residual <= 1 ? 1 : residual <= 2 ? 2 : residual <= 2.5 ? 2.5 : residual <= 5 ? 5 : 10) * magnitude
        if integer { step = max(1, ceil(step)) }
        let top = ceil(maximum / step - 1e-9) * step, count = Int((top / step).rounded())
        let ticks = (0...count).map { Double(String(format: "%.12g", locale: Locale(identifier: "en_US_POSIX"), Double($0) * step))! }
        return Scale(maximum: top, ticks: ticks)
    }
    public struct Point: Sendable, Codable, Equatable {
        public let start, end: String, value: Double?
        public let exactLabel: String?
        public init(start: String, end: String, value: Double?, exactLabel: String? = nil) { self.start = start; self.end = end; self.value = value; self.exactLabel = exactLabel }
        public var json: JSONText { .object([("start", .string(start)), ("end", .string(end)), ("value", value.map(JSONText.number) ?? .null)]) }
        public var middle: Double { Double(PeriodDates.number(start)!) + Double(PeriodDates.number(end)! - PeriodDates.number(start)! + 1) / 2 }
        public var date: Date { Date(timeIntervalSince1970: middle * 86_400) }
    }
    public struct Series: Sendable, Codable, Equatable {
        public let key, label: String, points: [Point]
        public init(key: String, label: String, points: [Point]) { self.key = key; self.label = label; self.points = points }
        public var json: JSONText { .object([("key", .string(key)), ("label", .string(label)), ("points", .array(points.map(\.json)))]) }
    }
    public struct Marker: Sendable, Codable, Equatable {
        public let date, label: String
        public let active: Bool
        /// What the marker stands for, such as a kind of listing change or a note, which sets its color; nil for a plain marker.
        public let kind: String?
        /// The item the marker opens when chosen; nil when it opens nothing.
        public let target: String?
        public init(date: String, label: String, active: Bool = false, kind: String? = nil, target: String? = nil) {
            self.date = date; self.label = label; self.active = active; self.kind = kind; self.target = target
        }
        public var json: JSONText { .object([("date", .string(date)), ("label", .string(label))]) }
    }
    public struct Slot: Sendable, Equatable {
        public let start, end: String, values: [Double?]
        public var middle: Double { Double(PeriodDates.number(start)!) + Double(PeriodDates.number(end)! - PeriodDates.number(start)! + 1) / 2 }
        public var label: String { start == end ? start : "\(start) – \(end)" }
        public var json: JSONText { .object([("start", .string(start)), ("end", .string(end)), ("values", .array(values.map { $0.map(JSONText.number) ?? .null }))]) }
    }
    public struct Gap: Sendable, Equatable {
        public let start, end: String
        public var json: JSONText { .object([("start", .string(start)), ("end", .string(end))]) }
    }
    public struct Layout: Sendable {
        public let series: [Series], slots: [Slot], gaps: [Gap], markers: [Marker]
        public let startDay, endDay: Int, runs: [[[Point]]]
        let centers: [Double], centerSlots: [Int]
        public var domain: ClosedRange<Date> { Date(timeIntervalSince1970: Double(startDay) * 86_400)...Date(timeIntervalSince1970: Double(endDay + 1) * 86_400) }
        public let scale: Scale
        /// Min/max envelopes reduce drawing work only. Exact values, inspection and gaps are retained.
        public func drawingRuns(maximumPerRun: Int = 512) -> [[[Point]]] {
            let limit = max(4, maximumPerRun)
            return runs.map { series in series.map { run in
                guard run.count > limit else { return run }
                let bucket = max(1, (run.count - 2 + (limit - 2) / 2 - 1) / ((limit - 2) / 2))
                var kept: [Point] = [run[0]]
                for start in stride(from: 1, to: run.count - 1, by: bucket) {
                    let end = min(run.count - 1, start + bucket)
                    let indices = Array(start..<end)
                    let low = indices.min { run[$0].value! < run[$1].value! }!
                    let high = indices.max { run[$0].value! < run[$1].value! }!
                    for index in Set([low, high]).sorted() { kept.append(run[index]) }
                }
                kept.append(run[run.count - 1]); return kept
            } }
        }
        public var json: JSONText { .object([("slots", .array(slots.map(\.json))), ("gaps", .array(gaps.map(\.json))), ("markers", .array(markers.map(\.json))), ("series", .array(series.enumerated().map { index, item in .object([("key", .string(item.key)), ("paths", .number(Double(runs[index].filter { $0.count > 1 }.count))), ("isolated", .number(Double(runs[index].filter { $0.count == 1 }.count)))]) }))]) }
        public func nearest(_ day: Double) -> Int? {
            guard day.isFinite else { return nil }
            guard !centers.isEmpty else { return nil }
            var lower = 0, upper = centers.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if centers[middle] < day { lower = middle + 1 } else { upper = middle }
            }
            guard lower > 0 else { return centerSlots[0] }
            guard lower < centers.count else { return centerSlots[centers.count - 1] }
            let left = day - centers[lower - 1], right = centers[lower] - day
            if left == right { return min(centerSlots[lower - 1], centerSlots[lower]) }
            return left < right ? centerSlots[lower - 1] : centerSlots[lower]
        }
        public func selection(_ current: Int?, key: String) -> Int? {
            guard !slots.isEmpty else { return nil }
            let last = slots.count - 1
            let selected = current.map { min(max(0, $0), last) }
            switch key {
            case "ArrowLeft": return max(0, (selected ?? slots.count) - 1)
            case "ArrowRight": return min(last, selected.map { $0 + 1 } ?? 0)
            case "Home": return 0
            case "End": return last
            case "Escape": return nil
            default: return current
            }
        }
    }
    private struct Interval: Hashable { let first, last: Int }
    private struct Prepared { let point: Point, interval: Interval }
    public static func layout(_ input: [Series], markers: [Marker] = []) -> Layout? {
        let prepared = input.prefix(4).map { item in
            var chosen: [Int: Prepared] = [:]
            for point in item.points {
                guard let first = PeriodDates.number(point.start), let last = PeriodDates.number(point.end), last >= first else { continue }
                let value = Point(start: point.start, end: point.end, value: point.value.flatMap { $0.isFinite ? $0 : nil }, exactLabel: point.exactLabel)
                chosen[first] = Prepared(point: value, interval: Interval(first: first, last: last))
            }
            return chosen.keys.sorted().map { chosen[$0]! }
        }
        let all = prepared.flatMap { $0 }
        guard let first = all.map({ $0.interval.first }).min(), let last = all.map({ $0.interval.last }).max() else { return nil }
        let series = zip(input.prefix(4), prepared).map { item, points in Series(key: item.key, label: item.label, points: points.map(\.point)) }
        let lookups = prepared.map { Dictionary($0.map { ($0.interval, $0.point) }, uniquingKeysWith: { _, last in last }) }
        let unique = Dictionary(all.map { ($0.interval, $0.point) }, uniquingKeysWith: { _, last in last })
        let keys = unique.keys.sorted { ($0.first, $0.last) < ($1.first, $1.last) }
        let slots = keys.map { key in let point = unique[key]!; return Slot(start: point.start, end: point.end, values: lookups.map { $0[key]?.value }) }
        // Merging coverage intervals avoids allocating or iterating every day of a long missing range.
        var covered: [Interval] = []
        for interval in keys {
            if let prior = covered.last, interval.first <= prior.last + 1 { covered[covered.count - 1] = Interval(first: prior.first, last: max(prior.last, interval.last)) }
            else { covered.append(interval) }
        }
        var gaps: [Gap] = []
        for index in covered.indices.dropFirst() {
            let before = covered[index - 1], after = covered[index]
            if after.first > before.last + 1 { gaps.append(Gap(start: PeriodDates.text(before.last + 1), end: PeriodDates.text(after.first - 1))) }
        }
        let runs = prepared.map { points in
            var result: [[Point]] = [], current: [Point] = [], prior: Interval?
            for value in points {
                guard value.point.value != nil else { if !current.isEmpty { result.append(current); current = [] }; prior = nil; continue }
                if let prior, value.interval.first != prior.last + 1 { result.append(current); current = [] }
                current.append(value.point); prior = value.interval
            }
            if !current.isEmpty { result.append(current) }; return result
        }
        let values = series.flatMap { $0.points.compactMap(\.value) }
        var firstSlot: [Double: Int] = [:]
        for (index, key) in keys.enumerated() {
            let center = Double(key.first) + Double(key.last - key.first + 1) / 2
            if firstSlot[center] == nil { firstSlot[center] = index }
        }
        let centers = firstSlot.keys.sorted()
        let positive = niceScale(values.max() ?? 0, integer: values.allSatisfy { $0.rounded() == $0 })
        let negative = niceScale(-(values.min() ?? 0), integer: values.allSatisfy { $0.rounded() == $0 })
        let scale = (values.min() ?? 0) < 0 ? Scale(maximum: positive.maximum, ticks: negative.ticks.dropFirst().reversed().map { -$0 } + positive.ticks) : positive
        return Layout(series: series, slots: slots, gaps: gaps, markers: markers.filter { marker in PeriodDates.number(marker.date).map { $0 >= first && $0 <= last } ?? false }, startDay: first, endDay: last, runs: runs, centers: centers, centerSlots: centers.map { firstSlot[$0]! },
                      scale: scale)
    }
    /// How a chart draws its series. Values, gaps and inspection are the same in every style.
    public enum Style: String, CaseIterable, Sendable {
        case line, bars, area
        public var title: String { switch self { case .line: "Line"; case .bars: "Bars"; case .area: "Area" } }
    }
    /// The day span one series' bar takes inside a report period, so the bars of overlaid series sit side by side.
    public static func barSpan(_ point: Point, index: Int, count: Int) -> (start: Double, end: Double)? {
        guard let first = PeriodDates.number(point.start), let last = PeriodDates.number(point.end), last >= first, count > 0, (0..<count).contains(index) else { return nil }
        let length = Double(last - first + 1), inset = length * 0.1, width = (length - 2 * inset) / Double(count)
        let start = Double(first) + inset + width * Double(index)
        return (start, start + width)
    }
    /// Scales each series so the average of its reported values is 100, to compare measures of different size or unit.
    /// A series without reported values, or whose values average zero, keeps its values.
    public static func indexed(_ series: [Series]) -> [Series] {
        series.map { item in
            let known = item.points.compactMap(\.value).filter(\.isFinite)
            let average = known.isEmpty ? 0 : abs(known.reduce(0, +) / Double(known.count))
            guard average > 0 else { return item }
            return Series(key: item.key, label: item.label, points: item.points.map { Point(start: $0.start, end: $0.end, value: $0.value.map { $0 / average * 100 }) })
        }
    }
    public static func runs(_ points: [Point]) -> [[Point]] {
        var result: [[Point]] = [], current: [Point] = []
        for point in points {
            guard point.value != nil else { if !current.isEmpty { result.append(current); current = [] }; continue }
            if let prior = current.last, PeriodDates.number(point.start) != PeriodDates.number(prior.end).map({ $0 + 1 }) { result.append(current); current = [] }
            current.append(point)
        }
        if !current.isEmpty { result.append(current) }; return result
    }
}
