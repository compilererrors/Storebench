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
    /// Prepares the same change again once its review has expired: Apple is read again and the new review waits for approval.
    var prepareAgain: (() -> Void)? = nil
    var actionsBusy = false
    /// Changes when the page's own command asks to send this review; a review waiting for approval then asks for confirmation.
    var approveRequests = 0
    /// Whether a newly prepared review scrolls to its send command; a review a page prepared by itself on opening stays where it is.
    var reveals = true
    /// Editors use one sync command followed by this concrete approval sheet, whose send command uses App Store Connect's name.
    var syncConfirmation = false
    var syncTitle = "Sync to Apple"
    var localDraft: LocalEditorDraftEditor? = nil
    var draftPaths: [[String]]? = nil
    @State private var draftSnapshot: LocalEditorDraftEditor.SyncSnapshot?
    @State private var draftReviewId: String?
    @State private var syncPresented = false
    @Environment(\.pageScroll) private var pageScroll
    @Environment(\.pageReveal) private var pageReveal
    @Environment(\.recoveryNavigation) private var recoveryNavigation
    @Environment(\.readyReviews) private var readyReviews
    /// The send command takes focus when a new review appears, so Return or Space sends it after reading.
    @FocusState private var sendFocused: Bool

    /// The scroll anchor of a review's command row, unique per review so the window bar reaches the right one.
    static func sendAnchor(_ id: String) -> String { "publish-review-send-" + id }

    static func stateLabel(_ state: String) -> String {
        ["prepared": "Ready for approval", "running": "Publishing", "complete": "Published", "failed": "Stopped", "conflict": "Changed since review"][state] ?? state
    }

    var body: some View {
        if let close = dialogOnly {
            if let review { syncDialog(review, close: close) }
        } else { page }
    }
    /// Set when another view presents the sync dialog, such as a step that opens it while the review is still being prepared:
    /// this panel then shows only the dialog's content.
    var dialogOnly: (() -> Void)? = nil
    /// False when the view holding this panel presents the sync dialog itself.
    var presentsDialog = true

    @ViewBuilder private var page: some View {
        ZStack {
            Color.clear.frame(height: 0).accessibilityHidden(true)
            if !syncConfirmation || review?.state != "prepared" { panel }
        }
        .onChange(of: review?.id, initial: true) {
            if let review, review.state == "prepared" {
                draftSnapshot = localDraft?.syncSnapshot(paths: draftPaths); draftReviewId = review.id
                if syncConfirmation {
                    if review.steps.isEmpty {
                        let snapshot = draftSnapshot
                        Task { if let snapshot { await localDraft?.acknowledge(snapshot) }; done() }
                    } else if reveals && presentsDialog { syncPresented = true }
                }
            }
        }
        // A review prepared ahead, such as Add for Review on Quick Release's last step, opens when its command is pressed.
        .onChange(of: approveRequests) { if syncConfirmation, presentsDialog, review?.state == "prepared", !working { syncPresented = true } }
        // The dialog stays open while its changes are sent, showing their progress. Run in Background closes it and the sync
        // goes on, with its progress in the window's bottom bar; a sync that stopped shows why on this page.
        .sheet(isPresented: Binding(get: { syncPresented && (review?.state == "prepared" || review?.state == "running") }, set: { syncPresented = $0 })) {
            if let review { syncDialog(review) { syncPresented = false } }
        }
    }

    /// The sync dialog: the changes, then their progress once approved. `close` dismisses whatever presents it.
    @ViewBuilder func syncDialog(_ review: PublishReview, close: @escaping () -> Void) -> some View {
        let sending = working || review.state == "running"
        let expired = Self.expired(review, now: now)
        StorebenchDialog(title: syncTitle, kind: .content, subtitle: review.title, busy: working) {
            Text(sending ? "Sending to App Store Connect. Run in Background keeps it going while you work; its progress stays at the bottom of the window."
                 : expired ? Self.expiredText : "Review the changes below, then approve them.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
            let removals = PublishingReviewPresentation.removals(review)
            if !removals.isEmpty {
                StorebenchAttention(title: "Remove \(removals.count) Items") {
                    DisclosureGroup("Items to Remove") {
                        ForEach(removals, id: \.key) { step in
                            StorebenchFact(label: step.before ?? step.label, value: step.after ?? step.detail)
                        }
                    }
                }
            }
            content(review)
        } actions: {
            StorebenchActionGroup(alignment: .trailing) {
                Button(sending ? "Run in Background" : "Cancel", role: .cancel) {
                    close()
                    if !sending { self.review = nil }
                }
                .help(sending ? "Close this dialog; the sync keeps running and its progress stays at the bottom of the window" : "Close without sending anything")
                .storebenchControlID("publish.sync.cancel")
                if expired, let prepareAgain {
                    StorebenchBusyButton(title: "Prepare Again", loadingTitle: "Preparing…", busy: actionsBusy) { prepareAgain() }
                        .help("Read App Store Connect again and show the changes in a new review. Nothing is sent until you approve it.")
                        .storebenchControlID("publish.sync.prepare-again")
                } else {
                    StorebenchBusyButton(title: PublishCommandName.of(review).confirmation, loadingTitle: "Sending…", busy: sending,
                        variant: PublishingReviewPresentation.hasDestructiveChanges(review) ? .danger : .primary) {
                        Task { await approve(review) }
                    }.storebenchWorking(!sending && (actionsBusy || !PublishingReviewPresentation.canApprove(review, now: now)))
                        .storebenchControlID("publish.sync.approve")
                }
            }
        }
        .task { await StorebenchPolling.repeating(every: .seconds(1), while: { true }) { now = Date() } }
    }

    /// Reviews already brought into view, so a page opened again keeps its own scroll position.
    @MainActor private static var revealed: Set<String> = []
    /// A newly prepared review brings its send command into view and focus, so the next click after Save is the review's send command.
    /// It runs on the panel itself: modifiers on an empty view never see the review arrive.
    private func reveal(_ id: String) {
        guard !syncConfirmation, reveals, review?.state == "prepared", Self.revealed.insert(id).inserted else { return }
        if Self.revealed.count > 256 { Self.revealed = [id] }
        Task { @MainActor in
            guard review?.id == id else { return }
            showSend(id)
        }
    }

    /// Scrolls to this review's send command until the page settles, then focuses it, so Return or Space sends after reading.
    private func showSend(_ id: String) {
        if let pageReveal { pageReveal(Self.sendAnchor(id)) } else { pageScroll?(Self.sendAnchor(id), .center) }
        Task { @MainActor in try? await Task.sleep(for: .milliseconds(700)); if review?.id == id { sendFocused = true } }
    }

    @ViewBuilder private var panel: some View {
        if let review {
            Group {
                if embedded { VStack(alignment: .leading, spacing: StorebenchTheme.gap) { content(review) } }
                else {
                    Card(title: review.title, subtitle: review.state == "prepared" ? "\(PublishCommandName.of(review).confirmation) sends these changes to App Store Connect, in this order." : Self.stateLabel(review.state)) { content(review) }
                }
            }.id("publish-review").trackUnsavedChanges(false, busy: working || review.state == "running")
                .onChange(of: review.id) { old, id in opened = []; readyReviews?.leave(old); reveal(id) }
                .onAppear { reveal(review.id); readyReviews?.arrive(review.id); readyReviews?.update(review, listed: !syncConfirmation) }
                .onChange(of: "\(review.id):\(review.state):\(review.title)") { readyReviews?.update(review, listed: !syncConfirmation) }
                .onDisappear { readyReviews?.leave(review.id) }
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
                    StorebenchProgressStatus(message: "Checking App Store Connect again before sending…", height: 18)
                } else {
                    // The file being uploaded now, with its speed, so a long upload visibly moves.
                    StorebenchProgressStatus(message: review.state == "running" ? PublishingReviewPresentation.activity(review) + (PublishTransfer.shared.snapshot().map { " · " + $0.text } ?? "")
                                             : review.state == "complete" ? "All \(total) sent" : stopped ? "Stopped after \(completed) of \(total)" : "Nothing sent yet",
                                             value: Double(completed), total: Double(max(1, total)), height: 18)
                        .accessibilityLabel("Publishing and media upload progress")
                }
            }.frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34, alignment: .topLeading)
        }
        // Why it stopped and what to do, set apart from the review itself.
        // Sections App Store Connect now shows as answered move out of the warning; Apple checks them again on Resume.
        if stopped {
            let answered = review.problems.filter { fixed[$0.area]?.done == true }, remaining = review.problems.filter { fixed[$0.area]?.done != true }
            let scopeFailure = review.errorCode == "SB-PUBLISH-SCOPE" && review.request.scope == .reviewInfo
            let contextualActions = fix != nil || remaining.allSatisfy { PublishingReviewPresentation.recoveryTarget($0.area) != nil }
            if review.problems.isEmpty || !remaining.isEmpty {
                StorebenchAttention {
                    Text(review.problems.isEmpty ? review.error ?? "This review stopped before it finished. Completed steps remain applied." : AppleProblem.summary(remaining, status: 0)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    if !remaining.isEmpty { AppleProblemsView(problems: remaining, fixed: fixed, fix: fix) }
                    if scopeFailure {
                        StorebenchActionGroup {
                            Button("Open App Review") {
                                if let fix { fix(AppleProblem.Area.reviewInformation.rawValue) }
                                else if let action = PublishingReviewPresentation.recoveryTarget(.reviewInformation)?.resolved(scope: recoveryNavigation.scope) { recoveryNavigation.navigate?(action) }
                            }.help("Open App Review Information, refresh it and prepare a new review.")
                        }
                    }
                    RecoveryActions(code: review.errorCode ?? issueCode ?? "SB-PUBLISH-APPROVAL", compact: true, copyCode: true,
                                    showPrimaryAction: !scopeFailure && (remaining.isEmpty || !contextualActions))
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
        if let media = ReleaseMediaProgress(review), !media.files.isEmpty { ReleaseMediaFiles(progress: media) }
        // One entry per language, holding that language's changes; other changes stand on their own.
        let steps = shown(review)
        ForEach(PublishingReviewPresentation.changeGroups(steps.map(\.label)), id: \.id) { group in
            if group.indices.count == 1, let index = group.indices.first {
                change(steps[index], title: group.title, open: review.steps.count == 1 || opened.contains(steps[index].key))
            } else {
                changeGroup(group, steps: group.indices.map { steps[$0] }, open: opened.contains(group.id))
            }
        }
        DisclosureGroup {
            ForEach(review.notes, id: \.self) { Text($0).fixedSize(horizontal: false, vertical: true) }
            if review.state == "prepared" { Text("Review expires \(review.expiresAt.prefix(16).replacingOccurrences(of: "T", with: " ")) UTC.") }
            ForEach(review.steps, id: \.key) { step in StorebenchFact(label: Self.stepState(step), value: step.label, problem: step.state == "failed") }
        } label: { Text("Details · \(review.steps.count) \(review.steps.count == 1 ? "step" : "steps")") }
        StorebenchFeedback(text: statusText, height: 34)
        if !syncConfirmation { footer(review, stopped: stopped) }
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
                    Button("Discard") { self.review = nil }.storebenchWorking(working || review.state != "prepared")
                        .help(review.state == "prepared" ? "Discard this review; nothing was sent" : "Only a review waiting for approval can be discarded")
                    if Self.expired(review, now: now), let again = prepareAgain ?? resume {
                        Button("Prepare Again") { again() }.buttonStyle(StorebenchButtonStyle(.primary)).storebenchWorking(actionsBusy)
                            .help(Self.expiredText).storebenchControlID("publish.prepare-again")
                    } else { approveButton(review) }
                }
            }
            .id(Self.sendAnchor(review.id))
            .confirmationDialog("Send \(review.steps.count) changes to App Store Connect?", isPresented: $confirming) { confirmation(review) } message: { confirmationMessage }
        }
    }
    /// A prepared review past its approval time: it can no longer be sent, only prepared again.
    nonisolated static func expired(_ review: PublishReview, now: Date) -> Bool {
        review.state == "prepared" && !review.steps.isEmpty && !PublishingReviewPresentation.canApprove(review, now: now)
    }
    static let expiredText = "This review expired 15 minutes after it was prepared, so nothing was sent. Prepare Again reads App Store Connect again and shows the changes in a new review."
    private func approveButton(_ review: PublishReview) -> some View {
        let sending = working || review.state == "running", name = PublishCommandName.of(review)
        return Button(role: PublishingReviewPresentation.hasDestructiveChanges(review) ? .destructive : nil) { if !sending { confirming = true } } label: {
            StorebenchBusyLabel(name.command, loading: "Sending…", busy: sending)
        }.buttonStyle(StorebenchButtonStyle(.primary)).environment(\.actionBusy, sending)
            .focused($sendFocused)
            .help("As in App Store Connect: \(name.command) asks once, then \(name.confirmation) sends \(review.steps.count == 1 ? "this change" : "these \(review.steps.count) changes")")
            .storebenchWorking(!sending && !PublishingReviewPresentation.canApprove(review, now: now))
    }
    @ViewBuilder private func confirmation(_ review: PublishReview) -> some View {
        if PublishingReviewPresentation.canApprove(review, now: now) {
            Button(PublishCommandName.of(review).confirmation, role: PublishingReviewPresentation.hasDestructiveChanges(review) ? .destructive : nil) { Task { await approve(review) } }
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
        let active = review.steps.filter { $0.state == "running" }
        if active.count > 1 {
            return active.allSatisfy { $0.kind == .verify } ? "Checking \(active.count) files with Apple" : "\(active.count) jobs running in parallel"
        }
        if let current { return current.state == "failed" ? "Stopped at " + current.label : current.label }
        return review.state == "complete" ? "All steps done" : "Not started"
    }
    /// One change with its before and after.
    /// A language's changes in one entry: its name and how many changes, each change inside with its own state and values.
    private func changeGroup(_ group: PublishingReviewPresentation.ChangeGroup, steps: [PublishStep], open: Bool) -> some View {
        let failed = steps.contains { $0.state == "failed" }, running = steps.contains { $0.state == "running" }
        let done = steps.allSatisfy { $0.state == "done" }
        return DisclosureGroup(isExpanded: Binding(get: { open }, set: { value in
            if value { opened.insert(group.id) } else { opened.remove(group.id) }
        })) {
            VStack(alignment: .leading, spacing: StorebenchTheme.space(1)) {
                ForEach(steps, id: \.key) { step in change(step, title: PublishingReviewPresentation.changeTitle(step.label, grouped: true), open: opened.contains(step.key)) }
            }.padding(.top, 6)
        } label: {
            HStack {
                Text(group.title).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                StorebenchStepState(text: failed ? "Failed" : running ? "Sending" : done ? "Done" : "", running: running, problem: failed)
            }
        }
    }
    private func change(_ step: PublishStep, title: String? = nil, open: Bool) -> some View {
        DisclosureGroup(isExpanded: Binding(get: { open }, set: { value in
            if value { opened.insert(step.key) } else { opened.remove(step.key) }
        })) {
            VStack(alignment: .leading, spacing: 6) {
                Text(step.detail).font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
                if step.before != nil || step.after != nil {
                    if let rows = ReviewComparisonTable.rows(before: step.before ?? "", after: step.after ?? "") { ReviewComparisonTable(rows: rows) }
                    else { AsoSavedValues(beforeLabel: "Now", afterLabel: "After", before: step.before ?? "", after: step.after ?? "") }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
        } label: {
            HStack {
                Text(title ?? step.label).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                StorebenchStepState(text: Self.stepState(step, pending: ""), running: step.state == "running", problem: step.state == "failed")
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
        return PublishingReviewPresentation.canApprove(review, now: now) ? "Ready · \(changes) to sync" : "Expired"
    }

    /// Files show under their own line, so only the other changes are listed; a long sent review lists its current step.
    private func shown(_ review: PublishReview) -> [PublishStep] {
        let shown = review.steps.filter { !ReleaseMediaProgress.shows($0) }
        return review.state != "prepared" && shown.count > 8 ? shown.filter { ["running", "failed"].contains($0.state) } : shown
    }
    private func approve(_ prepared: PublishReview) async {
        guard !working, PublishingReviewPresentation.canApprove(prepared, now: Date()), let session else { return }
        working = true; issueCode = nil; busyChanged(true); defer { working = false; busyChanged(false) }
        // The window's list follows the send, not this view, so its progress and how it ended stay visible on any page.
        let reviews = readyReviews, listed = !syncConfirmation
        reviews?.sending(prepared)
        let progress = Task { await follow(prepared.id, session: session, reviews: reviews, listed: listed) }; defer { progress.cancel() }
        do {
            let completed = try await session.approvePublishing(account: account, appId: app.id, id: prepared.id, fingerprint: prepared.fingerprint, client: try await session.client(for: account))
            progress.cancel(); review = completed; reviews?.update(completed, listed: listed)
            if completed.state == "complete", draftReviewId == prepared.id, let draftSnapshot { await localDraft?.acknowledge(draftSnapshot) }
            statusText = review?.state == "complete" ? "Published." : ""
        } catch let failure as PublishFailure {
            progress.cancel()
            issueCode = failure.recoveryCode ?? "SB-PUBLISH-APPROVAL"
            statusText = failure.message
            let stopped = try? await session.publishReview(accountId: account.id, appId: app.id, id: prepared.id)
            review = stopped
            if let stopped { reviews?.update(stopped, listed: listed) } else { reviews?.update(id: prepared.id, title: prepared.title, state: "failed") }
        } catch {
            progress.cancel(); issueCode = RecoveryIssue.apple(error) ?? "SB-PUBLISH-APPROVAL"; statusText = ReportingMessages.message(issueCode!)
            reviews?.update(id: prepared.id, title: prepared.title, state: "failed")
        }
        done()
    }
    /// Reads the review's progress while it is sent. With `reviews` it reports to the window, also after this view is gone.
    private func follow(_ id: String, session: WorkspaceSession, reviews: ReadyReviews? = nil, listed: Bool = true) async {
        while !Task.isCancelled, reviews != nil || review?.id == id {
            do {
                let current = try await session.publishStatus(accountId: account.id, appId: app.id, id: id)
                guard !Task.isCancelled else { return }
                if current.state == "running" { reviews?.update(current, listed: listed) }
                if review?.id == id { review = current } else if reviews == nil { return }
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
    @Environment(\.recoveryNavigation) private var recoveryNavigation
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
                let action = PublishingReviewPresentation.recoveryTarget(area)?.resolved(scope: recoveryNavigation.scope)
                VStack(alignment: .leading, spacing: StorebenchTheme.space(1)) {
                    StorebenchHeader {
                        Text(answered ? area.title : "\(area.title) · \(items.count) \(items.count == 1 ? "item" : "items")").font(.sbHeadline).fixedSize(horizontal: false, vertical: true)
                    } actions: {
                        if let check = area.check, fix != nil || action != nil && recoveryNavigation.navigate != nil {
                            Button(area.action) {
                                if let fix { fix(check) }
                                else if let action { recoveryNavigation.navigate?(action) }
                            }.buttonStyle(StorebenchButtonStyle(fixed?[area]?.done == true ? .secondary : .primary)).help(area.actionHelp)
                            .storebenchControlID("apple.fix." + check) }
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
