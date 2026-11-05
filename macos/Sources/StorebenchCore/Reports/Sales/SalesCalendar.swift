import Foundation

/// Missing report days retain unknown activity; publication timing is an observed window, not a delivery promise.
public enum SalesCalendar {
    public enum Availability: String, Sendable, CaseIterable { case scheduled, publishing, late, missing }
    public struct Window: Sendable, Equatable { public let from, to: Date }
    public struct Day: Sendable, Identifiable {
        public let date: String, availability: Availability, window: Window
        public var id: String { date }
    }
    public struct Guidance: Sendable {
        public let waiting, late, missing: [Day]
    }
    private static let pacific = TimeZone(identifier: "America/Los_Angeles")!
    public static func publicationWindow(_ day: String) throws -> Window {
        guard let number = PeriodDates.number(day) else { throw SalesPresentationFailure.range }
        func instant(_ hour: Int) throws -> Date {
            let naive = Double(number + 1) * 86_400 + Double(hour * 3600 + 30 * 60)
            var candidate = Date(timeIntervalSince1970: naive)
            for _ in 0..<4 {
                let corrected = Date(timeIntervalSince1970: naive - Double(pacific.secondsFromGMT(for: candidate)))
                if corrected == candidate { return candidate }; candidate = corrected
            }
            throw SalesPresentationFailure.range
        }
        return try Window(from: instant(5), to: instant(7))
    }
    public static func availability(_ day: String, now: Date) throws -> Availability {
        guard now.timeIntervalSince1970.isFinite else { throw SalesPresentationFailure.range }
        let window = try publicationWindow(day)
        return status(window, now: now)
    }
    private static func status(_ window: Window, now: Date) -> Availability {
        if now < window.from { return .scheduled }
        if now < window.to { return .publishing }
        return now < window.to.addingTimeInterval(86_400) ? .late : .missing
    }
    public static func guidance(_ dates: [String], now: Date) throws -> Guidance {
        guard dates.count <= 401, Set(dates).count == dates.count, now.timeIntervalSince1970.isFinite else { throw SalesPresentationFailure.range }
        var waiting: [Day] = [], late: [Day] = [], missing: [Day] = []
        for date in dates.sorted() {
            let window = try publicationWindow(date), availability = status(window, now: now), day = Day(date: date, availability: availability, window: window)
            switch availability { case .scheduled, .publishing: waiting.append(day); case .late: late.append(day); case .missing: missing.append(day) }
        }
        return Guidance(waiting: waiting, late: late, missing: missing)
    }
    public static func label(_ days: [Day]) -> String {
        func short(_ day: String) -> String {
            let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
            return months[Int(day.dropFirst(5).prefix(2))! - 1] + " " + String(Int(day.suffix(2))!)
        }
        guard let first = days.first, let last = days.last else { return "" }
        return days.count > 4 ? "\(short(first.date)) – \(short(last.date)) (\(days.count) days)" : days.map { short($0.date) }.joined(separator: ", ")
    }
}
