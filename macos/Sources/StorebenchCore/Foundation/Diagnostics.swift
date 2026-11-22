import Foundation
import os

/// Timing for Instruments and Console, to find what makes the app wait. Only a fixed name and a duration are recorded:
/// never an account, app, path, key, address or value.
enum Diagnostics {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "Storebench"
    private static let signposter = OSSignposter(subsystem: subsystem, category: .pointsOfInterest)
    private static let log = Logger(subsystem: subsystem, category: "performance")

    /// Notes work that took at least `slow`, by its fixed name.
    static func note(_ name: StaticString, since start: ContinuousClock.Instant, slow: Duration = .milliseconds(250)) {
        let elapsed = ContinuousClock.now - start
        guard elapsed >= slow else { return }
        let milliseconds = Int(elapsed.components.seconds) * 1_000 + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
        log.info("\(name.description, privacy: .public) took \(milliseconds, privacy: .public) ms")
    }

    /// Marks `body` as one interval in Instruments and notes it when it was slow.
    static func measure<T>(_ name: StaticString, slow: Duration = .milliseconds(250), _ body: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name), start = ContinuousClock.now
        defer { signposter.endInterval(name, state); note(name, since: start, slow: slow) }
        return try body()
    }
    static func measure<T>(_ name: StaticString, slow: Duration = .milliseconds(250), isolation: isolated (any Actor)? = #isolation, _ body: () async throws -> T) async rethrows -> T {
        let state = signposter.beginInterval(name), start = ContinuousClock.now
        defer { signposter.endInterval(name, state); note(name, since: start, slow: slow) }
        return try await body()
    }
}
