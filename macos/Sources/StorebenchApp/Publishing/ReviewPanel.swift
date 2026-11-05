import StorebenchCore
import SwiftUI

/// A prepared publishing review: every step with its before and after, approved explicitly and sent once.
struct ReviewPanel: View {
    let account: Account, app: Account.App, session: WorkspaceSession?
    @Binding var review: PublishReview?
    var done: () -> Void = {}
    var busyChanged: (Bool) -> Void = { _ in }
    @State private var working = false
    @State private var confirming = false
    @State private var statusText = ""
    @State private var issueCode: String?
    @State private var now = Date()
    /// Changes whose before and after are open. A single change opens by itself.
    @State private var opened: Set<String> = []
    /// What App Store Connect shows now for sections Apple refused: the saved check at once, then a fresh read whenever the stopped review is shown.
    @State private var fixed: [AppleProblem.Area: AppleProblemsView.Now] = [:]
    @Environment(LibraryModel.self) private var model
    /// Shown inside the card of the step that prepared it, such as a Release step, instead of in a card of its own.
    var embedded = false
    /// Opens the Release check where something Apple refused is fixed; the review stays saved for Resume.
    var fix: ((String) -> Void)? = nil
    /// Prepares a review for what a stopped review did not send. Nothing is sent until that review is approved.
    var resume: (() -> Void)? = nil
    /// Checks the saved selections again for a new review once this one is done.
    var recheck: (() -> Void)? = nil
    var actionsBusy = false
    /// Changes when the page's own command asks to send this review; a review waiting for approval then asks for confirmation.
    var approveRequests = 0
    /// Whether a newly prepared review scrolls to its Send to Apple; a review a page prepared by itself on opening stays where it is.
    var reveals = true
    @Environment(\.pageScroll) private var pageScroll
    @Environment(\.pageReveal) private var pageReveal
    @Environment(\.readyReviews) private var readyReviews
    /// The send command takes focus when a new review appears, so Return or Space sends it after reading.
    @FocusState private var sendFocused: Bool

    /// The scroll anchor of a review's command row, unique per review so the window bar reaches the right one.
    static func sendAnchor(_ id: String) -> String { "publish-review-send-" + id }

    /// The one command that sends a review to Apple, whatever App Store Connect calls the change it makes.
    static let sendTitle = "Send to Apple"

    /// App Store Connect's own button for the change being sent, named in the send command's help.
    static func approveTitle(_ scope: PublishRequest.Scope) -> String {
        switch scope {
        case .release, .metadata, .versionCopyright, .reviewInfo, .appInformation, .ageRating, .accessibility, .availability, .taxCategory, .pricingSetup, .productPricing: "Save"
        case .submit: "Add for Review"
        case .releaseVersion: "Release This Version"
        case .cancelSubmission: "Remove from Review"
        default: "Approve and Publish"
        }
    }
    /// App Store Connect's Upload, for a review that only uploads files to Asset Library.
    static func approveTitle(_ request: PublishRequest) -> String {
        if request.mediaStage == PublishRequest.uploadStage { return "Upload" }
        // Export Compliance is saved in App Store Connect, so its review uses the same word.
        if request.scope == .exportCompliance || request.testflightAction == "set-encryption-use" { return "Save" }
        return approveTitle(request.scope)
    }
    static func stateLabel(_ state: String) -> String {
        ["prepared": "Ready for approval", "running": "Publishing", "complete": "Published", "failed": "Stopped", "conflict": "Changed since review"][state] ?? state
    }

    var body: some View { panel }

    /// Reviews already brought into view, so a page opened again keeps its own scroll position.
    @MainActor private static var revealed: Set<String> = []
    /// A newly prepared review brings its send command into view and focus, so the next click after Save is Send to Apple.
    /// It runs on the panel itself: modifiers on an empty view never see the review arrive.
    private func reveal(_ id: String) {
        guard reveals, review?.state == "prepared", Self.revealed.insert(id).inserted else { return }
        if Self.revealed.count > 256 { Self.revealed = [id] }
        Task { @MainActor in
            guard review?.id == id else { return }
            showSend(id)
        }
    }

    /// Scrolls to this review's Send to Apple until the page settles, then focuses it, so Return or Space sends after reading.
    private func showSend(_ id: String) {
        if let pageReveal { pageReveal(Self.sendAnchor(id)) } else { pageScroll?(Self.sendAnchor(id), .center) }
        Task { @MainActor in try? await Task.sleep(for: .milliseconds(700)); if review?.id == id { sendFocused = true } }
    }

    @ViewBuilder private var panel: some View {
        if let review {
            Group {
                if embedded { VStack(alignment: .leading, spacing: StorebenchTheme.gap) { content(review) } }
                else {
                    Card(title: review.title, subtitle: review.state == "prepared" ? "\(Self.sendTitle) sends these changes to App Store Connect, in this order." : Self.stateLabel(review.state)) { content(review) }
                }
            }.id("publish-review").trackUnsavedChanges(false, busy: working || review.state == "running")
                .onChange(of: review.id) { old, id in opened = []; readyReviews?.remove(old); reveal(id) }
                .onAppear { reveal(review.id); readyReviews?.update(review) }
                .onChange(of: "\(review.id):\(review.state):\(review.title)") { readyReviews?.update(review) }
                .onDisappear { readyReviews?.remove(review.id) }
                .onChange(of: readyReviews?.shown?.request) {
                    guard let shown = readyReviews?.shown, shown.id == review.id else { return }
                    showSend(review.id)
                }
                .onChange(of: approveRequests) { if review.state == "prepared", !working, PublishingReviewPresentation.canApprove(review, now: Date()) { confirming = true } }
                .task(id: review.id) { await StorebenchPolling.repeating(every: .seconds(1), while: { true }) { now = Date() } }
                .task(id: "\(review.id):\(review.state)") { if review.state == "running", !working, let session { await follow(review.id, session: session) } }
                .task(id: "fixed:\(review.id):\(review.state)") { await readFixed(review) }
        }
    }

    /// What is sent first, then the files folded under one line, why a review stopped, and every step under Details.
    /// Every part keeps its place in every state, so preparing, sending, stopping and resuming change only the text and numbers:
    /// three status lines, one progress track, the files, Details and the command row.
    @ViewBuilder private func content(_ review: PublishReview) -> some View {
        let stopped = ["failed", "conflict"].contains(review.state)
        let completed = review.steps.filter { $0.state == "done" }.count, total = review.steps.count
        let current = review.steps.first { ["running", "failed"].contains($0.state) }
        VStack(alignment: .leading, spacing: StorebenchTheme.space(2)) {
            StorebenchFact(label: "Status", value: status(review))
            StorebenchFact(label: "Steps", value: "\(completed) of \(total) done")
            StorebenchFact(label: "Current step", value: currentStep(review, current: current))
        }
        if total == 0 { Text("There are no changes to publish.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted) }
        else {
            Group {
                if working && review.state == "prepared" {
                    ProgressView { Text("Checking App Store Connect again before sending…") }
                } else {
                    ProgressView(value: Double(completed), total: Double(max(1, total))) {
                        // The file being uploaded now, with its speed, so a long upload visibly moves.
                        Text(review.state == "running" ? "Sending \(min(completed + 1, total)) of \(total)…" + (PublishTransfer.shared.snapshot().map { " · Uploading " + $0.text } ?? "")
                             : review.state == "complete" ? "All \(total) sent" : stopped ? "Stopped after \(completed) of \(total)" : "Nothing sent yet")
                    }.accessibilityLabel("Publishing and media upload progress")
                }
            }.progressViewStyle(StorebenchProgressStyle()).frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34, alignment: .topLeading)
        }
        // Why it stopped and what to do, set apart from the review itself.
        // Sections App Store Connect now shows as answered move out of the warning; Apple checks them again on Resume.
        if stopped {
            let answered = review.problems.filter { fixed[$0.area]?.done == true }, remaining = review.problems.filter { fixed[$0.area]?.done != true }
            if review.problems.isEmpty || !remaining.isEmpty {
                StorebenchAttention {
                    Text(review.problems.isEmpty ? review.error ?? "This review stopped before it finished. Completed steps remain applied." : AppleProblem.summary(remaining, status: 0)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    if !remaining.isEmpty { AppleProblemsView(problems: remaining, fixed: fixed, fix: fix) }
                    RecoveryActions(code: issueCode ?? "SB-PUBLISH-APPROVAL", compact: true, copyCode: true)
                }
            }
            if !answered.isEmpty {
                StorebenchAttention(title: remaining.isEmpty ? "Ready to Resume" : "Answered in App Store Connect", done: true) {
                    Text(remaining.isEmpty ? "Everything Apple asked for is answered in App Store Connect now. Resume to add the version for review."
                         : "App Store Connect shows these answered now. Apple checks them again on Resume.").fixedSize(horizontal: false, vertical: true)
                    AppleProblemsView(problems: answered, fixed: fixed, fix: fix, answered: true)
                }
            }
        }
        if let media = ReleaseMediaProgress(review) { ReleaseMediaFiles(progress: media) }
        ForEach(shown(review), id: \.key) { step in change(step, open: review.steps.count == 1 || opened.contains(step.key)) }
        DisclosureGroup {
            ForEach(review.notes, id: \.self) { Text($0).fixedSize(horizontal: false, vertical: true) }
            if review.state == "prepared" { Text("Review expires \(review.expiresAt.prefix(16).replacingOccurrences(of: "T", with: " ")) UTC.") }
            ForEach(review.steps, id: \.key) { step in StorebenchFact(label: Self.stepState(step), value: step.label, problem: step.state == "failed") }
        } label: { Text("Details · \(review.steps.count) steps") }
        StorebenchFeedback(text: statusText, height: 34)
        footer(review, stopped: stopped)
    }

    /// One command row in every state: its buttons change name or dim, never appear or disappear.
    @ViewBuilder private func footer(_ review: PublishReview, stopped: Bool) -> some View {
        if !review.steps.isEmpty {
            StorebenchFormFooter {
                if stopped, let resume {
                    Button("Resume") { resume() }.buttonStyle(StorebenchButtonStyle(.primary)).storebenchWorking(actionsBusy)
                        .help("Prepare a review for what is still missing. Files already in Asset Library are reused; nothing is sent until you approve it.")
                } else if review.state == "complete", let recheck {
                    Button("Recheck Selections") { recheck() }.buttonStyle(StorebenchButtonStyle(.primary)).storebenchWorking(actionsBusy).help("Check saved selections again for a new review")
                } else {
                    approveButton(review)
                    Button("Discard") { self.review = nil }.storebenchWorking(working || review.state != "prepared")
                        .help(review.state == "prepared" ? "Discard this review; nothing was sent" : "Only a review waiting for approval can be discarded")
                }
            }
            .id(Self.sendAnchor(review.id))
            .confirmationDialog("Send \(review.steps.count) changes to App Store Connect?", isPresented: $confirming) { confirmation(review) } message: { confirmationMessage }
        }
    }
    private func approveButton(_ review: PublishReview) -> some View {
        let sending = working || review.state == "running"
        return Button(role: PublishingReviewPresentation.hasDestructiveChanges(review) ? .destructive : nil) { if !sending { confirming = true } } label: {
            StorebenchBusyLabel(Self.sendTitle, loading: "Sending…", busy: sending)
        }.buttonStyle(StorebenchButtonStyle(.primary)).environment(\.actionBusy, sending)
            .focused($sendFocused)
            .help("\(Self.approveTitle(review.request)) in App Store Connect: sends \(review.steps.count == 1 ? "this change" : "these \(review.steps.count) changes") after one confirmation")
            .storebenchWorking(!sending && !PublishingReviewPresentation.canApprove(review, now: now))
    }
    @ViewBuilder private func confirmation(_ review: PublishReview) -> some View {
        if PublishingReviewPresentation.canApprove(review, now: now) {
            Button(Self.sendTitle, role: PublishingReviewPresentation.hasDestructiveChanges(review) ? .destructive : nil) { Task { await approve(review) } }
        }
        Button("Cancel", role: .cancel) {}
    }
    private var confirmationMessage: Text { Text("Storebench checks App Store Connect and your drafts again first. If anything changed, nothing is sent.") }
    /// Shows the saved App Privacy, Tax Category and price checks for a stopped review Apple refused over them, then reads them again.
    /// Nothing is written to Apple; each read replaces the saved check.
    private func readFixed(_ review: PublishReview) async {
        let areas = Set(review.problems.map(\.area)).intersection([.privacy, .pricing, .tax])
        guard ["failed", "conflict"].contains(review.state), let session else { fixed = [:]; return }
        // The screens the other problems open are read meanwhile, so the fix the user is likely to open next appears at once.
        async let warmed: Void = session.warmProblemScreens(Set(review.problems.map(\.area)).subtracting(areas), account: account, appId: app.id)
        await readChecks(areas, session: session)
        await warmed
    }
    private func readChecks(_ areas: Set<AppleProblem.Area>, session: WorkspaceSession) async {
        guard !areas.isEmpty else { fixed = [:]; return }
        let saved = (try? await session.sectionChecks(accountId: account.id, appId: app.id)) ?? [:]
        fixed = saved.filter { areas.contains($0.key) }.mapValues { AppleProblemsView.Now($0) }
        var unread = Set<AppleProblem.Area>()
        // A section that cannot be read now keeps what App Store Connect showed last, such as App Privacy published before the
        // Apple ID session ended; only a section never read stays open. Apple checks every section again on Resume.
        /// `counts` keeps the last answer as done; a price that cannot be read now is shown as older information that is not done.
        func notRead(_ area: AppleProblem.Area, _ reason: String, counts: Bool = true) {
            unread.insert(area)
            fixed[area] = AppleProblemsView.Now.lastKnown(saved[area], reason: reason, counts: counts)
        }
        func reason(_ error: Error, _ fallback: String) -> String {
            if case .expired? = error as? AppleIDFailure { return "The Apple ID is signed out. Sign in again to check it now." }
            return (error as? AppleIDFailure)?.message ?? (error as? PublishFailure)?.message ?? fallback
        }
        if areas.contains(.privacy) {
            do { _ = try await session.appPrivacyState(account: account, appId: app.id, writer: model.writer) }
            catch is CancellationError { return }
            catch { notRead(.privacy, reason(error, "App Privacy could not be read from App Store Connect.")) }
        }
        if areas.contains(.tax) {
            do { _ = try await session.taxCategoryState(account: account, appId: app.id, writer: model.writer) }
            catch is CancellationError { return }
            catch { notRead(.tax, reason(error, "The tax category could not be read from App Store Connect.")) }
        }
        if areas.contains(.pricing) {
            // Read again from Apple, since the price may have changed in App Store Connect; the fresh answer also fills the shared
            // reads, so Open Pricing shows it at once.
            do {
                let state = try await session.pricingSetupState(account: account, appId: app.id, fresh: true)
                if state.appPrice == .unknown { notRead(.pricing, state.priceProblem ?? "The price could not be read from App Store Connect.", counts: false) }
            }
            catch is CancellationError { return }
            catch { notRead(.pricing, "The price could not be read from App Store Connect.", counts: false) }
        }
        guard !Task.isCancelled, let latest = try? await session.sectionChecks(accountId: account.id, appId: app.id) else { return }
        for (area, check) in latest where areas.contains(area) && !unread.contains(area) { fixed[area] = AppleProblemsView.Now(check) }
    }
    private func currentStep(_ review: PublishReview, current: PublishStep?) -> String {
        if let current { return current.state == "failed" ? "Stopped at " + current.label : current.label }
        return review.state == "complete" ? "All steps done" : "Not started"
    }
    /// One change with its before and after.
    private func change(_ step: PublishStep, open: Bool) -> some View {
        DisclosureGroup(isExpanded: Binding(get: { open }, set: { value in
            if value { opened.insert(step.key) } else { opened.remove(step.key) }
        })) {
            VStack(alignment: .leading, spacing: 6) {
                Text(step.detail).font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
                if step.before != nil || step.after != nil {
                    AsoSavedValues(beforeLabel: "Now", afterLabel: "After", before: step.before ?? "", after: step.after ?? "")
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
        } label: {
            HStack {
                Text(step.label).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    if step.state == "running" { StorebenchSpinner() }
                    Text(Self.stepState(step, pending: "")).font(.sbCaption).foregroundStyle(step.state == "failed" ? StorebenchTheme.color("color-danger") : StorebenchTheme.muted)
                }.frame(width: 100, height: 22, alignment: .trailing)
            }
        }
    }

    private static func stepState(_ step: PublishStep, pending: String = "Not sent") -> String {
        switch step.state {
        case "done": "Done"
        case "failed": "Failed"
        case "running": step.kind == .upload ? "Uploading" : step.kind == .verify ? "Verifying" : "Sending"
        default: pending
        }
    }
    private func status(_ review: PublishReview) -> String {
        guard review.state == "prepared" else { return PublishingReviewPresentation.label(review, now: now) }
        let changes = review.steps.count == 1 ? "1 change" : "\(review.steps.count) changes"
        return PublishingReviewPresentation.canApprove(review, now: now) ? "Ready · \(changes) to send when you choose \(Self.sendTitle)" : "Expired"
    }

    /// Files show under their own line, so only the other changes are listed; a long sent review lists its current step.
    private func shown(_ review: PublishReview) -> [PublishStep] {
        let shown = review.steps.filter { !ReleaseMediaProgress.shows($0) }
        return review.state != "prepared" && shown.count > 8 ? shown.filter { ["running", "failed"].contains($0.state) } : shown
    }
    private func approve(_ prepared: PublishReview) async {
        guard !working, PublishingReviewPresentation.canApprove(prepared, now: Date()), let session else { return }
        working = true; issueCode = nil; busyChanged(true); defer { working = false; busyChanged(false) }
        let progress = Task { await follow(prepared.id, session: session) }; defer { progress.cancel() }
        do {
            let completed = try await session.approvePublishing(account: account, appId: app.id, id: prepared.id, fingerprint: prepared.fingerprint, client: try await session.client(for: account))
            progress.cancel(); review = completed
            statusText = review?.state == "complete" ? "Published." : ""
        } catch let failure as PublishFailure {
            progress.cancel()
            issueCode = "SB-PUBLISH-APPROVAL"
            statusText = failure.message
            review = try? await session.publishReview(accountId: account.id, appId: app.id, id: prepared.id)
        } catch { progress.cancel(); issueCode = RecoveryIssue.apple(error) ?? "SB-PUBLISH-APPROVAL"; statusText = ReportingMessages.message(issueCode!) }
        done()
    }
    private func follow(_ id: String, session: WorkspaceSession) async {
        while !Task.isCancelled, review?.id == id {
            do {
                let current = try await session.publishStatus(accountId: account.id, appId: app.id, id: id)
                guard !Task.isCancelled, review?.id == id else { return }; review = current
                if !["prepared", "running"].contains(current.state) { return }
                try await Task.sleep(for: .milliseconds(600))
            } catch is CancellationError { return }
            catch { statusText = "Publishing status could not be refreshed. Nothing is retried; read the saved review again after this operation."; return }
        }
    }
}

/// What Apple refused, grouped by App Store Connect section: each section lists its fields and has one command that opens
/// where they are answered. Codes Storebench does not know stay under Other, as Apple sent them.
struct AppleProblemsView: View {
    let problems: [AppleProblem]
    /// What App Store Connect shows now for a section, read after Apple refused it.
    struct Now: Equatable {
        let done: Bool, text: String
        init(done: Bool, text: String) { self.done = done; self.text = text }
        /// `note` says why this is the last known state rather than one read now.
        init(_ check: SectionCheck, note: String? = nil) {
            done = check.answered
            let place = check.area == .pricing ? (check.answered ? "Price \(check.detail) is set" : "\(check.detail) is set") : check.detail
            text = "\(place) in App Store Connect · \(note == nil ? "checked" : "last read") \(LibraryOverview.timestamp(check.checkedAt))" + (note.map { " · " + $0 } ?? "")
        }
        /// A section that could not be read now: its last answer as older information, done only when `counts`, or not checked.
        static func lastKnown(_ saved: SectionCheck?, reason: String, counts: Bool) -> Now {
            guard let saved else { return Now(done: false, text: "Not checked: " + reason) }
            let now = Now(saved, note: reason)
            return counts ? now : Now(done: false, text: now.text)
        }
    }
    /// Sections App Store Connect now shows as answered, with what was read; Apple checks them again on Resume.
    /// nil leaves out the Now line, as for problems found while preparing.
    var fixed: [AppleProblem.Area: Now]? = nil
    var fix: ((String) -> Void)? = nil
    /// Lists sections App Store Connect shows as answered: only what was read, without Apple's original complaint.
    var answered = false
    var body: some View {
        let areas = AppleProblem.Area.allCases.filter { area in problems.contains { $0.area == area } }
        VStack(alignment: .leading, spacing: StorebenchTheme.space(3)) {
            ForEach(areas, id: \.self) { area in
                let items = problems.filter { $0.area == area }
                VStack(alignment: .leading, spacing: StorebenchTheme.space(1)) {
                    StorebenchHeader {
                        Text(answered ? area.title : "\(area.title) · \(items.count) \(items.count == 1 ? "item" : "items")").font(.sbHeadline).fixedSize(horizontal: false, vertical: true)
                    } actions: {
                        if let fix, let check = area.check { Button(area.action) { fix(check) }.buttonStyle(StorebenchButtonStyle(fixed?[area]?.done == true ? .secondary : .primary)) }
                    }
                    if !answered {
                        // Apple's own reason for each item, with the field it names; its code stays for support.
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.detail.map { item.field == nil ? $0 : "\(item.label): \($0)" } ?? item.label).font(.sbCallout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                Text(item.code).font(.sbCaption.monospaced()).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            }
                        }
                    }
                    if let fixed { StorebenchFact(label: "Now", value: fixed[area]?.text ?? "Apple checks this again on Resume.", done: fixed[area]?.done == true) }
                }
                if area != areas.last { StorebenchDivider() }
            }
        }
    }
}
