import Foundation
import StorebenchCore
import SwiftUI

/// Prepares one general App Store change and shows its review, using the same one-use publishing service.
struct PublishActionPanel: View {
    /// Links the panel to a publishing history shown beside it: the history's reading state, a saved review to open and a refresh after each review.
    struct History {
        var opening: Binding<String?>
        var reading: Bool
        var busyChanged: (Bool) -> Void
        var changed: () async -> Void
    }
    let account: Account, app: Account.App, session: WorkspaceSession?
    let actions: [PublishingWorkspace.Action]
    let history: History?
    /// Opens the review still waiting for this exact change, or prepares one, as soon as the panel appears. Preparing only reads.
    var automatic = false
    /// Inside Release the plan decides the change, its source and its version, so only what you still choose is shown, under the step's own name.
    var guided: (title: String, purpose: String)? = nil
    /// Told the review shown here, or nil, once the panel has opened or prepared it and whenever it changes state.
    var reviewChanged: ((PublishReview?) -> Void)? = nil
    /// Changes when the saved material behind an automatic review changes, so a waiting review is prepared again in place.
    var refreshKey: String? = nil
    /// Opens the Release check where something Apple refused is fixed, such as Age Ratings.
    var fix: ((String) -> Void)? = nil
    /// Changes when the page's own command for this change is pressed: it prepares a review, resumes a stopped one, or asks to send a prepared one.
    var trigger = 0
    @State private var approveRequests = 0
    let done: (PublishReview?) -> Void
    @State private var editor: PublishingWorkspace.Editor
    @State private var review: PublishReview?
    /// Whether the review shown next scrolls to its Send to Apple: after a Save, not when a page opens with one prepared for it.
    @State private var revealReview = true
    @State private var working = false
    @State private var publishing = false
    @State private var status = ""
    @State private var issueCode: String?
    @State private var failed = false
    /// An Asset Library upload found every file already there, so there is nothing to prepare.
    @State private var upToDate = false
    /// Where to fix what stopped the last Prepare Review, such as unanswered Age Ratings.
    @State private var prepareProblems: [AppleProblem] = []
    @Environment(\.editorProtection) private var protection
    @Environment(\.recoveryIntent) private var recoveryIntent
    @Environment(\.pageScroll) private var pageScroll
    @Environment(\.pageReveal) private var pageReveal
    @Environment(\.navigationPresentation) private var presentation
    private var ownBusy: Bool { working || publishing || review?.state == "running" }
    private var busy: Bool { ownBusy || history?.reading == true }
    private var managedReview: Bool { review.map { PublishingWorkspace.Action(scope: $0.request.scope) == nil } ?? false }
    init(account: Account, app: Account.App, session: WorkspaceSession?, actions: [PublishingWorkspace.Action] = PublishingWorkspace.Action.allCases, initialRequest: PublishRequest? = nil, initialReview: PublishReview? = nil, history: History? = nil, automatic: Bool = false, guided: (title: String, purpose: String)? = nil, reviewChanged: ((PublishReview?) -> Void)? = nil, refreshKey: String? = nil, fix: ((String) -> Void)? = nil, trigger: Int = 0, done: @escaping (PublishReview?) -> Void = { _ in }) {
        self.account = account; self.app = app; self.session = session; self.actions = actions; self.history = history; self.automatic = automatic; self.guided = guided; self.reviewChanged = reviewChanged; self.refreshKey = refreshKey; self.fix = fix; self.trigger = trigger; self.done = done
        var selected = PublishingWorkspace.Editor(accountId: account.id, appId: app.id)
        var initialStatus = ""
        let prepared = initialReview.flatMap { review in review.state == "prepared" && review.request.accountId == account.id && review.request.appId == app.id && (review.request.scope == .metadata || review.request.scope == .release || review.request.scope == .assetLibrary) ? review : nil }
        if initialReview != nil, prepared == nil { initialStatus = "The prepared review belongs to unavailable app material. Prepare a current review before continuing." }
        if let initialRequest = prepared?.request ?? initialRequest, PublishingWorkspace.Action(scope: initialRequest.scope) != nil {
            do { try selected.restore(initialRequest) }
            catch { initialStatus = "The requested selections could not be confirmed for this app. Read and choose current material before preparing a review." }
        }
        if !actions.contains(selected.action), let first = actions.first { selected.chooseAction(first) }
        _editor = State(initialValue: selected); _status = State(initialValue: initialStatus)
        _review = State(initialValue: prepared)
    }

    /// What the one change does at Apple, and that approval is still needed.
    static func purpose(_ action: PublishingWorkspace.Action) -> String {
        let approval = " Prepare Review shows the exact change; nothing is sent until you approve it."
        switch action {
        case .cancel: return "Removes this version from App Review so it can be changed again. App Store Connect then shows Developer Rejected, and its text, screenshots and build can be changed before adding it for review again." + approval
        case .submit: return "Adds this version for review and submits it to App Review." + approval
        case .releaseVersion: return "Releases the approved version on the App Store." + approval
        case .metadata: return "Saves this version's text, screenshots and app previews to App Store Connect." + approval
        case .release: return "Creates the version in App Store Connect with its release option, or updates that option." + approval
        case .copyright: return "Saves the version's copyright to App Store Connect." + approval
        case .pricing: return "Saves the planned prices to App Store Connect." + approval
        case .analytics: return "Asks Apple to start generating Analytics reports for this app." + approval
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // A panel for one change is named after it, in App Store Connect's words; a panel offering several changes keeps the general title.
            Card(title: guided?.title ?? (actions.count == 1 ? editor.action.rawValue : "Prepare a review"), subtitle: guided?.purpose ?? (actions.count == 1 ? Self.purpose(editor.action) : "Read current Apple choices and saved material, then review exactly what would change. Only explicit approval sends changes."), help: "publish-approval") {
                if actions.count > 1 && guided == nil {
                    StorebenchCardSection(title: "Review scope") {
                    StorebenchPicker("Change", selection: Binding(get: { editor.action }, set: { value in
                        guard !busy, protection?.allowLeaving() != false else { return }; editor.chooseAction(value); review = nil
                        if value == .submit, editor.snapshot?.builds == nil { Task { await loadChoices() } }
                    })) { selectionOptions(actions) { SelectionOption($0.rawValue, value: $0) } }.storebenchWorking(busy)
                    }
                }
                if managedReview { Text("This saved review belongs to another app section. Read its exact steps below, or recheck its saved selections to prepare a fresh review.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted) }
                // A guided submission still chooses its build; every other guided change takes its source and version from the plan.
                if guided == nil || editor.action == .submit { StorebenchCardSection(title: "Saved source and Apple destination") { actionFields } }
                ForEach(editor.snapshot?.issues ?? [], id: \.self) { Text($0).font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true) }
                // A guided step shows its review in this same card, so its own commands and messages give way to the review's.
                if guided == nil || review == nil || failed {
                    StorebenchActionGroup {
                        if guided == nil { StorebenchReadButton("Read Current Choices") { await loadChoices(fresh: true) }.storebenchWorking(busy) }
                        if session != nil {
                            // Always in place: dimmed while there is nothing to prepare, with its spinner while it prepares.
                            StorebenchBusyButton(title: "Prepare Review", loadingTitle: "Preparing…", busy: busy, variant: .primary) { Task { await prepare() } }
                                .storebenchWorking(!busy && (!editor.canPrepare || managedReview || review != nil || upToDate))
                        }
                    }
                    // A refused review says why in the error colour, with room for the files or fields it names.
                    StorebenchFeedback(text: status, height: failed ? 76 : 34, error: failed)
                    if !prepareProblems.isEmpty { StorebenchAttention { AppleProblemsView(problems: prepareProblems, fix: fix) } }
                    RecoveryActions(code: issueCode)
                }
                if guided != nil, review != nil { reviewPanel }
            }
            if guided == nil { reviewPanel }
            // Resume and Recheck Selections sit in the review's own command row; only the next part of a release is offered here.
            if guided == nil, let review, review.state == "complete", review.request.scope == .release, editor.snapshot?.plan != nil, actions.contains(.metadata) {
                Card(title: "After this review", subtitle: "The version was created. Its text, screenshots and app previews are reviewed next.") {
                    StorebenchFormFooter {
                        Button("Review Text & Media") { Task { await preparePlannedMaterial() } }.help("Review Saved Text and Media Next").accessibilityLabel("Review Saved Text and Media Next").storebenchWorking(busy)
                    }
                }
            }
        }
        .task {
            defer { reviewChanged?(review) }
            await loadChoices()
            // Coming back to this view shows the review that was open here, read again from its saved state.
            let remembered = presentation.flatMap { $0.store.collection(reviewKey, entry: $0.entry, as: String.self) }
            if review == nil, let id = remembered, !id.isEmpty { await openReview(id, scroll: false) }
            // App Store changes opens the review still waiting for approval, wherever it was prepared, such as in Release.
            // A Release step opens the one for its own change, or prepares it, so nothing needs to be prepared twice.
            guard review == nil, remembered == nil, history != nil || automatic, let session else { return }
            let wanted = automatic ? try? editor.request() : nil
            let saved = (try? await session.publishHistory(accountId: account.id, appId: app.id)) ?? []
            // An Asset Library upload and the Save after it are separate changes, each shown in its own panel.
            let mine = saved.filter { review in PublishingWorkspace.Action(scope: review.request.scope).map(actions.contains) == true && review.request.mediaStage == editor.mediaStage }
            if let waiting = saved
                .filter({ $0.state == "prepared" && PublishingReviewPresentation.canApprove($0, now: Date()) && (wanted == nil || $0.request == wanted) }).max(by: { $0.createdAt < $1.createdAt }) {
                await openReview(waiting.id, scroll: false)
                if review?.id == waiting.id { status = "Showing the review still waiting for your approval. Nothing is sent until you choose \(ReviewPanel.sendTitle)." }
            } else if automatic, let running = mine.filter({ $0.state == "running" }).max(by: { $0.createdAt < $1.createdAt }) {
                // A Save still sending keeps its progress here, wherever the step was opened again; nothing new is prepared beside it.
                await openReview(running.id, scroll: false)
                if review?.id == running.id { status = "This Save is still sending to App Store Connect. Its progress shows below." }
            } else if automatic, let wanted, let stopped = mine.filter({ $0.request == wanted }).max(by: { $0.createdAt < $1.createdAt }), ["failed", "conflict"].contains(stopped.state) {
                // The last Save for this change stopped: its steps and reason stay visible until Recheck Selections prepares a new review.
                await openReview(stopped.id, scroll: false)
                if review?.id == stopped.id { status = "The last Save stopped. Completed steps stay at Apple; Resume prepares a review for the rest." }
            } else if automatic, wanted != nil, editor.canPrepare, !managedReview {
                await prepare(reveal: false)
            }
        }
        .onChange(of: "\(review?.id ?? ""):\(review?.state ?? "")") { reviewChanged?(review) }
        .onChange(of: trigger) {
            guard !busy else { return }
            if let review, review.state == "prepared" { approveRequests += 1 }
            else { Task { await prepare(review.map { ["failed", "conflict"].contains($0.state) ? $0.request : nil } ?? nil, reveal: false) } }
        }
        .onChange(of: refreshKey) { _, key in
            // Edits saved on this Mac make a waiting review stale; a review being sent or one that stopped is left as it is.
            guard automatic, key == "saved", !busy, review == nil || review?.state == "prepared" || review?.state == "complete" else { return }
            // The person just saved, so the new review's Send to Apple comes into view.
            Task { await prepare(reveal: true) }
        }
        .onChange(of: review?.id) { if let presentation { presentation.store.saveCollection(review?.id ?? "", key: reviewKey, entry: presentation.entry) } }
        .trackUnsavedChanges(editor.dirty, busy: busy)
        .onChange(of: Data(editor.copyright.utf8)) { _, _ in if editor.dirty { review = nil } }
        .onChange(of: recoveryIntent?.id, initial: true) { if recoveryIntent?.action.target.analyticsOngoing == true, actions.contains(.analytics), !busy, review == nil { editor.chooseAction(.analytics); editor.analyticsSnapshot = false } }
        .onChange(of: ownBusy, initial: true) { history?.busyChanged(ownBusy) }
        .onChange(of: history?.opening.wrappedValue) { guard let opening = history?.opening, let id = opening.wrappedValue else { return }; opening.wrappedValue = nil; Task { await openReview(id) } }
    }
    @ViewBuilder private var reviewPanel: some View {
        if editor.matchesCopyright(review?.request) {
            ReviewPanel(account: account, app: app, session: session, review: $review, done: { Task { await afterPublishing() } }, busyChanged: { publishing = $0 },
                        embedded: guided != nil, fix: fix, resume: { Task { if let request = review?.request { await prepare(request) } } },
                        recheck: { Task { if let request = review?.request { await prepare(request) } } }, actionsBusy: busy, approveRequests: approveRequests, reveals: revealReview)
                .storebenchWorking(working)
        } else {
            Text("The copyright changed after this review was prepared. Prepare a new review to send the current text.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var actionFields: AnyView {
        switch editor.action {
        case .metadata:
            return AnyView(VStack(alignment: .leading, spacing: 12) {
                StorebenchFormGrid {
                StorebenchPicker("Source revision", selection: Binding(get: { editor.revisionId }, set: { editor.chooseSource($0); review = nil })) {
                    if !(editor.snapshot?.sources?.contains { $0.id == editor.revisionId } ?? false) { SelectionOption("Source unavailable · read or choose current material", value: editor.revisionId) }
                    selectionOptions(editor.snapshot?.sources ?? []) { SelectionOption($0.name, value: $0.id) }
                }.storebenchWorking(busy)
                StorebenchPicker("Source version", selection: Binding(get: { editor.sourceVersionId }, set: { editor.chooseSourceVersion($0); review = nil })) {
                    if !(editor.source?.versions.contains { $0.id == editor.sourceVersionId } ?? false) { SelectionOption("Choose a saved source version", value: editor.sourceVersionId) }
                    selectionOptions(editor.source?.versions ?? []) { SelectionOption($0.name, value: $0.id) }
                }.storebenchWorking(busy)
                StorebenchPicker("Apple destination", selection: Binding(get: { editor.targetMode }, set: { editor.chooseTarget($0); review = nil })) {
                    SelectionOption("Existing Apple version matching the source", value: "apple-version")
                    if editor.planSelected { SelectionOption("Version draft · \(editor.snapshot?.plan?.label ?? "")", value: "release-plan") }
                }.storebenchWorking(busy)
                }
                Text(editor.destination.map { "Apple target: \($0.name) · \(AppStoreNames.state($0.state))" } ?? (editor.snapshot?.versions == nil ? "Apple destination status is unknown. Read current choices before preparing changes." : editor.targetMode == "release-plan" ? "Create the planned Apple version before reviewing its saved text and media." : "This source version is not currently at Apple. Choose another saved source or its attached version draft."))
                    .font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
            })
        case .release:
            return AnyView(Group {
                Text(editor.snapshot?.plan.map { "Review \($0.label) with “\($0.settings)”. Version setup is separate from the later text and media review." } ?? "Save a version number in Version setup first.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
            })
        case .pricing:
            return AnyView(Group {
                StorebenchPicker("Saved pricing profile", selection: Binding(get: { editor.profileId }, set: { editor.chooseProfile($0); review = nil })) {
                    if !(editor.snapshot?.profiles?.contains { $0.id == editor.profileId } ?? false) { SelectionOption("Read and choose a saved profile", value: editor.profileId) }
                    selectionOptions(editor.snapshot?.profiles ?? []) { SelectionOption($0.name, value: $0.id) }
                }.storebenchFormColumn().storebenchWorking(busy)
                Text("Review the selected saved model and country overrides as one manual price schedule. Protected countries and Apple's future prices are kept.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
            })
        case .analytics:
            return AnyView(Group {
                StorebenchChoicePicker("Reports", selection: Binding(get: { editor.analyticsSnapshot }, set: { editor.analyticsSnapshot = $0; review = nil }), options: [(false, "Ongoing reports"), (true, "One-time historical snapshot")]).storebenchFormColumn().storebenchWorking(busy)
            })
        case .copyright, .submit, .cancel, .releaseVersion:
            return AnyView(Group {
                StorebenchPicker("Apple version", selection: Binding(get: { editor.versionId }, set: { value in
                    guard !busy, protection?.allowLeaving() != false else { return }; editor.chooseVersion(value); review = nil
                })) {
                    if editor.version == nil { SelectionOption("Read or choose a current Apple version", value: editor.versionId) }
                    selectionOptions(editor.snapshot?.versions ?? []) { SelectionOption("\($0.name) · \(AppStoreNames.state($0.state))\(editor.action == .releaseVersion ? " · \($0.releaseType.isEmpty ? "release method unknown" : $0.releaseType)" : "")", value: $0.id) }
                }.storebenchFormColumn().storebenchWorking(busy)
                if editor.action == .copyright {
                    if editor.version == nil { Text("Choose the Apple version above to enter its copyright.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted) }
                    else { StorebenchTextField("Year and rights holder", text: $editor.copyright).storebenchFormColumn().storebenchWorking(busy) }
                }
                if editor.action == .submit {
                    StorebenchPicker("Build for this version", selection: Binding(get: { editor.buildId }, set: { editor.chooseBuild($0); review = nil })) {
                        SelectionOption("Use build already attached at Apple", value: "")
                        if !editor.buildId.isEmpty, !editor.builds.contains(where: { $0.id == editor.buildId }) { SelectionOption("Saved build unavailable · choose again", value: editor.buildId) }
                        selectionOptions(editor.builds) { SelectionOption($0.name, value: $0.id) }
                    }.storebenchFormColumn().storebenchWorking(busy)
                    Text(editor.snapshot?.builds == nil ? "Build status is unknown. Retry before preparing a submission." : "Only processed App Store eligible builds for this platform and version appear. Apple rechecks the chosen or attached build, review details and export compliance before submission.").font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
                }
            })
        }
    }
    private func loadChoices(fresh: Bool = false) async {
        guard !working, !publishing, let session else { return }; working = true; defer { working = false }
        if fresh { await session.invalidateAppleReads() }
        do { let value = try await session.publishingWorkspace(account: account, appId: app.id, includeBuilds: editor.action == .submit, client: try await session.readClient(for: account)); try Task.checkCancellation(); try editor.receive(value); issueCode = nil; status = value.issues.isEmpty ? "Current choices read. Your existing inputs and selections are kept." : "Some choices remain unknown. Retry the read before preparing those changes." }
        catch is CancellationError { }
        catch { status = "Publishing choices could not be read. Your existing inputs remain here."; issueCode = RecoveryIssue.apple(error) ?? "SB-PUBLISH-PREPARE" }
    }
    private var reviewKey: String { "publish-review:" + (presentation?.scope ?? "") + ":" + actions.map(\.rawValue).joined(separator: ",") }
    private func openReview(_ id: String, scroll: Bool = true) async {
        guard !busy, protection?.allowLeaving() != false, let session else { return }; working = true; defer { working = false }
        revealReview = scroll
        do { let saved = try await session.publishStatus(accountId: account.id, appId: app.id, id: id); try Task.checkCancellation(); if let action = PublishingWorkspace.Action(scope: saved.request.scope), actions.contains(action) { try editor.restore(saved.request) }; review = saved; status = "Showing the saved review below. No changes were prepared or sent."; issueCode = nil
            if scroll { reveal() } }
        catch { status = "The saved review could not be opened. Current inputs remain here." }
    }
    private func prepare(_ savedRequest: PublishRequest? = nil, reveal shows: Bool = true) async {
        guard !busy, let session else { return }; working = true; defer { working = false }; issueCode = nil; failed = false; upToDate = false; prepareProblems = []; status = ""
        revealReview = shows
        // A guided step keeps its last review on screen until the new one is ready, so Resume updates the view instead of emptying it.
        if guided == nil { review = nil }
        do { let request = try savedRequest ?? editor.request(); guard request.accountId == account.id, request.appId == app.id else { throw PublishFailure.invalid("Choose a review belonging to this app.") }; // A review prepared ahead, such as Add for Review during the earlier Release steps, shows at once.
            if let ahead = await session.reviewPreparedAhead(request) { review = ahead } else { review = try await session.preparePublishing(account: account, request: request, client: try await session.client(for: account)) }; status = "The review is ready below. Nothing is sent until you choose \(ReviewPanel.sendTitle)."; if shows && guided == nil { reveal() } }
        // The message says what to change here; recovery steps would only point back to this same panel.
        catch PublishFailure.noChanges where editor.mediaStage == PublishRequest.uploadStage { issueCode = nil; upToDate = true; status = "Done. Every file is already in Asset Library, so nothing needs to be uploaded."; review = nil }
        catch PublishFailure.noChanges where editor.action == .release && guided != nil { issueCode = nil; upToDate = true; status = "Done. App Store Connect already has this version with this release option."; review = nil }
        catch PublishFailure.noChanges where editor.mediaStage == PublishRequest.quickStage { issueCode = nil; upToDate = true; status = "Done. App Store Connect already has this text, so there is nothing to save."; review = nil }
        catch PublishFailure.noChanges where editor.mediaStage == PublishRequest.screenshotsStage { issueCode = nil; upToDate = true; status = "Done. App Previews and Screenshots already match the files and order above."; review = nil }
        catch let failure as PublishFailure {
            issueCode = nil; failed = true; status = "No review was prepared. " + failure.message; if guided == nil { review = nil }
            if case .refused(_, let problems) = failure { prepareProblems = problems }
        }
        catch { issueCode = RecoveryIssue.apple(error) ?? "SB-PUBLISH-PREPARE"; failed = true; status = ReportingMessages.message(issueCode!) }
        await history?.changed()
    }
    /// Scrolls to the review once it is laid out, so it is clear where it appeared.
    private func reveal() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150)); guard let id = review?.id else { return }
            if let pageReveal { pageReveal(ReviewPanel.sendAnchor(id)) } else { pageScroll?(ReviewPanel.sendAnchor(id), .center) }
        }
    }
    private func afterPublishing() async {
        await history?.changed()
        if review?.state == "complete" { await loadChoices(fresh: true) }
        done(review)
    }
    private func preparePlannedMaterial() async {
        guard !busy else { return }
        do { try editor.choosePlannedMaterial(); review = nil; await prepare() }
        catch let failure as PublishFailure { status = failure.message }
        catch { status = "The version plan's saved material could not be selected. Read current choices before retrying." }
    }
}
