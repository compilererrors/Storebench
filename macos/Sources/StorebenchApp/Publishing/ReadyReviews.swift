import StorebenchCore
import SwiftUI

/// The reviews on the open page that wait for Send to Apple or are being sent, for the window's bottom bar.
/// The bar only takes the person to a review; sending always happens on the review card itself.
@MainActor @Observable final class ReadyReviews {
    struct Entry: Equatable { let id: String, title: String; var sending: Bool }
    /// In the order the reviews appeared, so the bar names the one prepared first.
    private(set) var entries: [Entry] = []
    /// Asks the panel showing this review to scroll to its Send to Apple and focus it.
    private(set) var shown: (id: String, request: Int)?
    private var requests = 0

    func update(_ review: PublishReview) { update(id: review.id, title: review.title, state: review.state) }
    func update(id: String, title: String, state: String) {
        guard ["prepared", "running"].contains(state) else { remove(id); return }
        let entry = Entry(id: id, title: title, sending: state == "running")
        if let index = entries.firstIndex(where: { $0.id == id }) { entries[index] = entry } else { entries.append(entry) }
    }
    func remove(_ id: String) { entries.removeAll { $0.id == id } }
    func show(_ id: String) { requests += 1; shown = (id, requests) }

    /// The bar's line: the first review and how many more wait.
    static func text(_ entries: [Entry]) -> String {
        guard let first = entries.first else { return "" }
        let more = entries.count > 1 ? " · \(entries.count - 1) more" : ""
        return (first.sending ? "Sending · " : "Ready to send · ") + first.title + more
    }
}

private struct ReadyReviewsKey: EnvironmentKey { static var defaultValue: ReadyReviews? { nil } }
extension EnvironmentValues {
    /// The window's list of reviews ready to send; nil outside a workspace window.
    var readyReviews: ReadyReviews? { get { self[ReadyReviewsKey.self] } set { self[ReadyReviewsKey.self] = newValue } }
}

/// The window's bottom bar while a review on the page waits for Send to Apple: it names the review and goes to it.
struct ReadyReviewBar: View {
    let reviews: ReadyReviews
    var body: some View {
        if let first = reviews.entries.first {
            HStack(spacing: StorebenchTheme.space(3)) {
                Spacer(minLength: 0)
                Text(ReadyReviews.text(reviews.entries)).font(.sbCallout).foregroundStyle(StorebenchTheme.ink)
                    .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.trailing)
                StorebenchCommand(title: "Go to Review", running: "Opening…", busy: false, unavailable: nil) { reviews.show(first.id) }
                    .help("Show this review with its changes and \(ReviewPanel.sendTitle). Nothing is sent from this bar.")
            }
            .padding(.horizontal, StorebenchTheme.space(6)).padding(.vertical, StorebenchTheme.space(3))
            .background(StorebenchTheme.surface)
            .overlay(alignment: .top) { StorebenchDivider() }
        }
    }
}
