import Foundation

/// Time and page policy for saved reviews; it never consumes an approval.
public enum PublishingReviewPresentation {
    public static func removals(_ review: PublishReview) -> [PublishStep] {
        review.steps.filter { $0.kind == .api && $0.method == "DELETE" }
    }
    public static func activity(_ review: PublishReview) -> String {
        let running = review.steps.filter { $0.state == "running" }
        let complete = review.steps.filter { $0.state == "done" }.count
        let summary = "\(complete) of \(review.steps.count) steps complete"
        guard !running.isEmpty else { return summary }
        if running.allSatisfy({ $0.kind == .verify }) {
            return "Waiting for Apple · \(running.count) file\(running.count == 1 ? "" : "s") processing · " + summary
        }
        let action = running.allSatisfy { $0.kind == .upload } ? "Uploading" : "Syncing"
        return action + " · \(running.count) job\(running.count == 1 ? "" : "s")" + (running.count > 1 ? " in parallel" : "") + " · " + summary
    }
    public static func hasDestructiveChanges(_ review: PublishReview) -> Bool {
        review.steps.contains { step in
            step.kind == .api && (step.method == "DELETE" ||
                step.method == "PATCH" && step.body?["data"]?["attributes"]?["archived"] == .bool(true))
        }
    }
    public static func canApprove(_ review: PublishReview, now: Date) -> Bool {
        review.state == "prepared" && !review.steps.isEmpty && (ISO8601DateFormatter.storebench.date(from: review.expiresAt) ?? .distantPast) > now
    }
    /// When a saved review was approved, or prepared if it never was, in the Mac's time zone.
    public static func started(_ review: PublishReview) -> String {
        ISO8601DateFormatter.storebench.date(from: review.approvedAt ?? review.createdAt).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? String(review.createdAt.prefix(16))
    }
    /// How far a saved review got: steps done, the step it is on or stopped at, and why it stopped.
    public static func progress(_ review: PublishReview) -> String {
        var parts = ["\(review.steps.filter { $0.state == "done" }.count) of \(review.steps.count) steps done"]
        if let step = review.steps.first(where: { ["running", "failed"].contains($0.state) }) { parts.append((step.state == "running" ? "Now: " : "Stopped at: ") + step.label) }
        if ["failed", "conflict"].contains(review.state), let error = review.error, !error.isEmpty { parts.append(error) }
        return parts.joined(separator: " · ")
    }
    /// The same progress as labelled lines, for a saved review opened to see where it got: steps, the current or stopping step,
    /// Apple's reason and the files. `problem` marks the lines to show as an error.
    public static func facts(_ review: PublishReview) -> [(label: String, value: String, problem: Bool)] {
        var facts: [(label: String, value: String, problem: Bool)] = [("Steps", "\(review.steps.filter { $0.state == "done" }.count) of \(review.steps.count) done", false)]
        if let step = review.steps.first(where: { ["running", "failed"].contains($0.state) }) { facts.append((step.state == "running" ? "Now" : "Stopped at", step.label, false)) }
        if ["failed", "conflict"].contains(review.state), let error = review.error, !error.isEmpty { facts.append(("Reason", error, true)) }
        if let media = ReleaseMediaProgress(review) { facts.append(("Files", media.summary, false)) }
        return facts
    }
    public static func label(_ review: PublishReview, now: Date) -> String {
        switch review.state {
        case "prepared": (ISO8601DateFormatter.storebench.date(from: review.expiresAt) ?? .distantPast) <= now ? "Expired" : "Awaiting approval"
        case "complete": review.request.scope == .release ? "Version step complete" : review.request.scope == .metadata ? "Content sent to Apple" : "Completed"
        case "failed": "Stopped · review needed"
        case "conflict": "Needs a new review"
        case "running": "Publishing…"
        default: "Unavailable"
        }
    }
    public struct Page: Sendable {
        public let items: [PublishReview]
        public let page, pages, total: Int
    }
    public static func page(_ history: [PublishReview], requested: Int) -> Page {
        let pages = max(1, (history.count + 9) / 10), page = min(max(1, requested), pages), start = min(history.count, (page - 1) * 10), end = min(history.count, start + 10)
        return Page(items: Array(history[start..<end]), page: page, pages: pages, total: history.count)
    }
}
