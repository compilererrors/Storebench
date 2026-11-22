import StorebenchCore
import SwiftUI

/// The reviews on the open page that wait for approval, and every sync to Apple being sent, for the window's bottom bar.
/// A sync keeps running and keeps its progress here when its page closes or another page opens, and the bar names how it ended.
/// The bar only takes the person to a review; sending always starts on the review itself.
@MainActor @Observable final class ReadyReviews {
    struct Entry: Equatable {
        let id: String, title: String
        var sending: Bool
        var done = 0, total = 0
        /// Whether the page that shows this review is open, so Go to Review can bring it into view.
        var onPage = true
        /// A review still being prepared after its dialog was sent to the background.
        var preparing = false
        /// Named in the bar by Run in Background, so it stays there when its page closes.
        var background = false
        /// The page that started it, so the bar can open that page again.
        var location: LibraryLocation?
    }
    /// How the last sync or background preparation in this window ended. A finished one is named in the bar for a moment;
    /// one that stopped stays with Go to Resolve until it is opened.
    struct Finished: Equatable {
        enum Kind: Equatable { case synced, stopped, notPrepared, nothingToSync }
        let id: String, title: String, kind: Kind
        var location: LibraryLocation? = nil
        var complete: Bool { kind == .synced || kind == .nothingToSync }
    }
    /// How a preparation sent to the background ended.
    enum Prepared { case ready, nothingToSync, failed, cancelled }
    /// Set by the window: the page shown now, and how to open a page it showed before.
    var currentLocation: (() -> LibraryLocation)?
    var open: ((LibraryLocation) -> Void)?
    /// In the order the reviews appeared, so the bar names the one prepared first.
    private(set) var entries: [Entry] = []
    private(set) var finished: Finished?
    /// Asks the panel showing this review to scroll to its send command and focus it.
    private(set) var shown: (id: String, request: Int)?
    /// A guide's step bar names the waiting review itself, so the window shows one bar, not two.
    var coveredByStepBar = false
    private var requests = 0
    /// The review or stopped work the bar asked to show, until the view that owns it takes it, also after its page opens again.
    private var pending: String?

    /// `listed` names a review waiting for approval in the bar; a review approved in its own dialog is named only while it is sent.
    func update(_ review: PublishReview, listed: Bool = true) {
        let done = review.steps.filter { $0.state == "done" }.count
        guard review.state == "running" || listed || entries.contains(where: { $0.id == review.id }) else { return }
        update(id: review.id, title: review.title, state: review.state, done: done, total: review.steps.count)
    }
    func update(id: String, title: String, state: String, done: Int = 0, total: Int = 0) {
        let index = entries.firstIndex { $0.id == id }
        guard ["prepared", "running"].contains(state) else {
            if let index, entries[index].sending { finished = Finished(id: id, title: title, kind: state == "complete" ? .synced : .stopped, location: entries[index].location) }
            remove(id); return
        }
        var entry = Entry(id: id, title: title, sending: state == "running", done: done, total: total)
        if let index { entry.onPage = entries[index].onPage; entry.location = entries[index].location; entries[index] = entry }
        else { entry.location = currentLocation?(); entries.append(entry) }
    }
    /// Run in Background on a review still being prepared: the bar names it until it is ready or says why it is not.
    func preparing(id: String, title: String) {
        remove(id)
        var entry = Entry(id: id, title: title, sending: false)
        entry.preparing = true; entry.background = true; entry.location = currentLocation?()
        entries.append(entry)
    }
    func isPreparing(_ id: String) -> Bool { entries.contains { $0.id == id && $0.preparing } }
    /// How a preparation named in the bar ended: a ready review waits there with Go to Review, a failed one with Go to Resolve.
    func prepared(id: String, title: String, _ outcome: Prepared) {
        guard let index = entries.firstIndex(where: { $0.id == id && $0.preparing }) else { return }
        let location = entries[index].location
        switch outcome {
        case .ready: entries[index].preparing = false
        case .nothingToSync: remove(id); finished = Finished(id: id, title: title, kind: .nothingToSync, location: location)
        case .failed: remove(id); finished = Finished(id: id, title: title, kind: .notPrepared, location: location)
        case .cancelled: remove(id)
        }
    }
    /// Marks a review as being sent as soon as it is approved, before Apple's first step reports back.
    func sending(_ review: PublishReview) { update(id: review.id, title: review.title, state: "running", done: 0, total: review.steps.count) }
    /// The review's page closed: a review being sent stays in the bar until it ends; one waiting for approval leaves it.
    func leave(_ id: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        if entries[index].sending || entries[index].background { entries[index].onPage = false } else { entries.remove(at: index) }
    }
    func arrive(_ id: String) { if let index = entries.firstIndex(where: { $0.id == id }) { entries[index].onPage = true } }
    func remove(_ id: String) { entries.removeAll { $0.id == id } }
    func clearFinished(_ id: String) { if finished?.id == id { finished = nil } }
    func show(_ id: String) { requests += 1; pending = id; shown = (id, requests) }
    /// True once for the view that owns `id` after the bar asked to show it.
    func takePending(_ id: String) -> Bool {
        guard pending == id else { return false }
        pending = nil; return true
    }
    /// The bar's command: shows the first review, or why the last sync or preparation stopped. A page the window left opens again first.
    func go() {
        if let first = entries.first { reveal(first.id, at: first.location, onPage: first.onPage) }
        else if let stopped = finished, !stopped.complete { finished = nil; reveal(stopped.id, at: stopped.location, onPage: false) }
    }
    private func reveal(_ id: String, at location: LibraryLocation?, onPage: Bool) {
        if !onPage, let location, location != currentLocation?() { open?(location) }
        show(id)
    }
    /// The bar's command is named for what it does: it shows a review, or where to fix what stopped.
    static func command(_ entries: [Entry], finished: Finished? = nil) -> String {
        entries.isEmpty && finished?.complete == false ? "Go to Resolve" : "Go to Review"
    }

    /// The sync being sent first, as a share of its steps.
    static func progress(_ entries: [Entry]) -> Double? {
        guard let sending = entries.first(where: \.sending) else { return nil }
        return sending.total > 0 ? Double(sending.done) / Double(sending.total) : 0
    }
    /// The bar's line: the first review and how many more wait, or how the last sync ended.
    static func text(_ entries: [Entry], finished: Finished? = nil) -> String {
        guard let first = entries.first else {
            guard let finished else { return "" }
            switch finished.kind {
            case .synced: return "Synced to Apple · " + finished.title
            case .nothingToSync: return "Nothing to sync · " + finished.title
            case .stopped: return "Sync stopped · " + finished.title
            case .notPrepared: return "Review not prepared · " + finished.title
            }
        }
        let more = entries.count > 1 ? " · \(entries.count - 1) more" : ""
        if first.preparing { return "Preparing review · " + first.title + more }
        guard first.sending else { return "Ready to send · " + first.title + more }
        return "Syncing to Apple · " + first.title + (first.total > 0 ? " · \(first.done) of \(first.total) \(first.total == 1 ? "step" : "steps")" : "") + more
    }
    /// Why the bar's command cannot run: the review is still being prepared, its page is closed and unknown, or nothing waits.
    static func unavailable(_ entries: [Entry], finished: Finished? = nil) -> String? {
        guard let first = entries.first else { return finished?.complete == false ? nil : "Nothing waits for review." }
        if first.preparing { return "The review is still being prepared. Nothing is sent until you approve it." }
        return first.onPage || first.location != nil ? nil : "Open the page that started this sync to see its steps. It keeps running meanwhile."
    }
    /// Whether the first entry works without a known amount, so the bar shows activity instead of a share.
    static func working(_ entries: [Entry]) -> Bool { entries.first?.preparing == true }
}

private struct ReadyReviewsKey: EnvironmentKey { static var defaultValue: ReadyReviews? { nil } }
extension EnvironmentValues {
    /// The window's list of reviews ready to send; nil outside a workspace window.
    var readyReviews: ReadyReviews? { get { self[ReadyReviewsKey.self] } set { self[ReadyReviewsKey.self] = newValue } }
}

/// The window's bottom bar while a review on the page waits for approval or a sync to Apple runs: it names the review, shows how
/// far the sync is and goes to it. When a sync ends it says how, for a moment.
struct ReadyReviewBar: View {
    let reviews: ReadyReviews
    var body: some View {
        if !reviews.entries.isEmpty || reviews.finished != nil, !reviews.coveredByStepBar {
            HStack(spacing: StorebenchTheme.space(3)) {
                Spacer(minLength: 0)
                StorebenchBackgroundWorkMark(entries: reviews.entries)
                Text(ReadyReviews.text(reviews.entries, finished: reviews.finished)).font(.sbCallout).foregroundStyle(StorebenchTheme.ink)
                    .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.trailing)
                StorebenchSyncProgress(value: ReadyReviews.progress(reviews.entries), working: ReadyReviews.working(reviews.entries))
                StorebenchCommand(title: ReadyReviews.command(reviews.entries, finished: reviews.finished), running: "Opening…", busy: false,
                                  unavailable: ReadyReviews.unavailable(reviews.entries, finished: reviews.finished)) { reviews.go() }
                    .help("Show this review with its changes and its send command, or where to fix what stopped. Nothing is sent from this bar.")
            }
            .padding(.horizontal, StorebenchTheme.space(6)).padding(.vertical, StorebenchTheme.space(3))
            .background(StorebenchTheme.surface)
            .overlay(alignment: .top) { StorebenchDivider() }
            .overlay(alignment: .top) { StorebenchBackgroundWorkLine(entries: reviews.entries) }
            .modifier(StorebenchFinishedSync(reviews: reviews))
        }
    }
}

/// A sync's progress in the window's bars: a bar that fills while it is sent, a moving bar while a review is prepared, and empty
/// while nothing runs. Both bars share one fixed track, so the window's bar never moves and never changes kind.
struct StorebenchSyncProgress: View {
    let value: Double?
    var working = false
    var body: some View {
        Group {
            if let value { StorebenchProgressStatus(message: "", value: value, height: 0).accessibilityLabel("Sync to Apple progress") }
            else if working { StorebenchActivityBar().accessibilityLabel("Preparing review") }
            else { Color.clear.accessibilityHidden(true) }
        }.frame(width: 140, height: StorebenchTheme.measure("progressHeight") + 8)
    }
}

/// Work that continues behind the page shows along the whole top edge of the window's bar: a moving line while a review is
/// prepared, a line that fills while a sync is sent, and nothing otherwise. It is seen from anywhere on the page.
struct StorebenchBackgroundWorkLine: View {
    let entries: [ReadyReviews.Entry]
    var body: some View {
        if ReadyReviews.working(entries) { StorebenchActivityBar(height: 3).accessibilityHidden(true) }
        else if let value = ReadyReviews.progress(entries) {
            GeometryReader { geometry in
                Rectangle().fill(StorebenchTheme.accent).frame(width: geometry.size.width * min(1, max(0.02, value)))
            }.frame(height: 3).accessibilityHidden(true)
        }
    }
}

/// A spinner beside the bar's text while a review is prepared or a sync is sent in the background. Its place is kept while nothing runs.
struct StorebenchBackgroundWorkMark: View {
    let entries: [ReadyReviews.Entry]
    var body: some View {
        let running = entries.first.map { $0.preparing || $0.sending } ?? false
        Group { if running { StorebenchProgressStatus(message: "", height: 0).accessibilityLabel("Working in the background") } else { Color.clear.accessibilityHidden(true) } }
            .frame(width: 16, height: 16)
    }
}

/// Clears how the last sync ended after a few seconds. One that stopped stays several minutes, so Go to Resolve can be reached.
struct StorebenchFinishedSync: ViewModifier {
    let reviews: ReadyReviews
    func body(content: Content) -> some View {
        content.task(id: reviews.finished?.id) {
            guard let id = reviews.finished?.id else { return }
            try? await Task.sleep(for: .seconds(reviews.finished?.complete == false ? 300 : 8))
            reviews.clearFinished(id)
        }
    }
}
