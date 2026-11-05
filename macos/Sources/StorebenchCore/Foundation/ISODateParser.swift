import Foundation
import os

/// Reuses immutable formatter configuration; the lock contains every formatter access.
enum ISODateParser {
    private struct Parsers {
        let plain = ISO8601DateFormatter()
        let fractional: ISO8601DateFormatter = {
            let parser = ISO8601DateFormatter()
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            parser.timeZone = TimeZone(secondsFromGMT: 0)
            return parser
        }()
    }
    // Formatter references are created here, accessed under the lock and never returned to callers.
    private static let parsers = OSAllocatedUnfairLock(uncheckedState: Parsers())
    static func date(_ value: String) -> Date? {
        parsers.withLock { $0.fractional.date(from: value) ?? $0.plain.date(from: value) }
    }
    static func text(_ value: Date) -> String { parsers.withLock { $0.fractional.string(from: value) } }
}
