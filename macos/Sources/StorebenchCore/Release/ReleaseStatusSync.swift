import Foundation

/// When the release guide checks App Store Connect again, and how it describes the age of what it shows.
/// The last confirmed status stays visible while a newer read runs; it never stands in for a fresh read before an Apple change.
public enum ReleaseStatusSync {
    /// After an approved change Apple can take a while to show its result, such as Developer Rejected after Cancel Submission.
    static let settleWindow: Duration = .seconds(180)
    static let longest: Duration = .seconds(300)
    /// How long a remembered status for unchanged saved material is confirmed by a single version-state read instead of a full read.
    public static let rememberedFreshness: TimeInterval = 300

    /// The wait before the next automatic check, or nil when only opening a step or Refresh Status checks again.
    /// Shortly after a change made here, check often until Apple shows its result; while Apple reviews or processes the version, check now and then.
    /// Each consecutive failure doubles the wait, up to five minutes.
    public static func delay(appleState: String?, sinceWrite: Duration?, failures: Int) -> Duration? {
        let base: Duration
        if let sinceWrite, sinceWrite < settleWindow { base = .seconds(10) }
        else if let appleState, ReleaseReadiness.waiting.contains(appleState) { base = .seconds(60) }
        else { return nil }
        return min(base * (1 << min(max(failures, 0), 5)), longest)
    }

    /// One line about the shown status. `checked` is the time of the last confirmed read, already formatted for display.
    public static func label(checked: String?, busy: Bool, failed: Bool, automatic: Bool, settling: Bool) -> String {
        guard let checked else { return busy ? "Checking App Store Connect…" : failed ? "App Store Connect could not be checked. Refresh when ready." : "" }
        if busy { return "Checked at \(checked). Checking App Store Connect again…" }
        if failed { return "Last confirmed at \(checked). The latest check failed; this is what was confirmed then." }
        if settling { return "Checked at \(checked). Checking again until App Store Connect shows the change." }
        return automatic ? "Checked at \(checked). Checking again while Apple works on this version." : "Checked at \(checked)."
    }
}
