import Foundation
import Testing
@testable import StorebenchCore

@Suite struct ISODateParserTests {
    init() throws { _ = try TestIsolation.require() }
    @Test func sharedParsersMatchFreshFormattersUnderConcurrentUse() async {
        let values = ["2026-02-03T12:34:56Z", "2026-02-03T12:34:56.123Z", "2026-02-03T12:34:56.123+02:00", "2026-02-03T12:34:56-04:30", "invalid", "", "2026-02-30T00:00:00Z"]
        let plain = ISO8601DateFormatter(), fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; fractional.timeZone = TimeZone(secondsFromGMT: 0)
        let expected = values.map { fractional.date(from: $0) ?? plain.date(from: $0) }
        let rendered = expected.map { $0.map { fractional.string(from: $0) } }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 { group.addTask {
                for index in values.indices {
                    let date = ISODateParser.date(values[index])
                    #expect(date == expected[index])
                    #expect(date.map(ISODateParser.text) == rendered[index])
                }
            } }
        }
    }
}
