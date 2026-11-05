import Foundation

/// Stored report timestamps remain literal; file import replaces them only after validating the original history.
enum ReportTimestamps {
    private static let iso = try! NSRegularExpression(pattern: #"\A([0-9]{4})-([0-9]{2})-([0-9]{2})(?:[Tt]([0-9]{2}):([0-9]{2})(?::([0-9]{2})(?:\.([0-9]+))?)?(?:[Zz]|[+-]([0-9]{2}):?([0-9]{2}))?)?\z"#)
    static func valid(_ value: String) -> Bool {
        if let match = iso.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) {
            func number(_ index: Int) -> Int { guard let range = Range(match.range(at: index), in: value) else { return 0 }; return Int(value[range]) ?? 0 }
            guard (1...12).contains(number(2)), (1...31).contains(number(3)), number(4) <= 24, number(5) < 60, number(6) < 60, number(8) < 24, number(9) < 60 else { return false }
            // Stored timestamps allow calendar rollover and 24:00 only with zero smaller components.
            if number(4) == 24 {
                guard number(5) == 0, number(6) == 0 else { return false }
                if let fraction = Range(match.range(at: 7), in: value), value[fraction].contains(where: { $0 != "0" }) { return false }
            }
            return true
        }
        if value.range(of: #"\A[A-Za-z]{3}, [0-9]{2} [A-Za-z]{3} [0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2} (?:GMT|UTC|[+-][0-9]{4})\z"#, options: .regularExpression) != nil {
            let parser = DateFormatter(); parser.locale = Locale(identifier: "en_US_POSIX"); parser.timeZone = TimeZone(secondsFromGMT: 0); parser.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            return parser.date(from: value) != nil
        }
        return false
    }
    /// Interprets accepted legacy timestamps without changing their stored spelling.
    static func date(_ value: String) -> Date? {
        guard valid(value) else { return nil }
        if let match = iso.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) {
            func text(_ index: Int) -> String? { Range(match.range(at: index), in: value).map { String(value[$0]) } }
            func number(_ index: Int) -> Int { text(index).flatMap(Int.init) ?? 0 }
            var calendar = Calendar(identifier: .gregorian)
            let timed = text(4) != nil, zoned = value.hasSuffix("Z") || value.hasSuffix("z") || text(8) != nil
            calendar.timeZone = timed && !zoned ? .current : TimeZone(secondsFromGMT: 0)!
            let date: Date
            if timed && !zoned {
                guard let local = calendar.date(from: DateComponents(year: number(1), month: number(2), day: number(3), hour: number(4), minute: number(5), second: number(6))) else { return nil }
                date = local
            } else {
                // Use the proleptic Gregorian calendar, including year zero.
                let month = number(2), year = number(1) - (month <= 2 ? 1 : 0)
                let era = (year >= 0 ? year : year - 399) / 400, yearOfEra = year - era * 400
                let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + number(3) - 1
                let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
                let days = era * 146097 + dayOfEra - 719468
                date = Date(timeIntervalSince1970: Double(days * 86400 + number(4) * 3600 + number(5) * 60 + number(6)))
            }
            let fraction = text(7).flatMap { Double("0." + $0.prefix(3)) } ?? 0
            let offset = text(8) == nil ? 0 : (number(8) * 60 + number(9)) * 60 * (value.contains("+") ? 1 : -1)
            return date.addingTimeInterval(fraction - Double(offset))
        }
        let parser = DateFormatter(); parser.locale = Locale(identifier: "en_US_POSIX"); parser.timeZone = TimeZone(secondsFromGMT: 0)
        parser.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"; return parser.date(from: value)
    }
    /// Stable UTC text without Foundation's historical calendar cutover or era-based year spelling.
    static func isoUtcText(_ date: Date) -> String {
        let seconds = Int(floor(date.timeIntervalSince1970)), days = Int(floor(Double(seconds) / 86400))
        let time = seconds - days * 86400, shifted = days + 719468
        let era = (shifted >= 0 ? shifted : shifted - 146096) / 146097, dayOfEra = shifted - era * 146097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthPrime = (5 * dayOfYear + 2) / 153, day = dayOfYear - (153 * monthPrime + 2) / 5 + 1
        let month = monthPrime + (monthPrime < 10 ? 3 : -9), year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        let yearText = (0...9999).contains(year) ? String(format: "%04d", year) : String(format: "%@%06d", year < 0 ? "-" : "+", abs(year))
        return yearText + String(format: "-%02d-%02dT%02d:%02d:%02dZ", month, day, time / 3600, time % 3600 / 60, time % 60)
    }
    static func shortValid(_ value: String) -> Bool { value.utf16.count <= 40 && valid(value) }
}
