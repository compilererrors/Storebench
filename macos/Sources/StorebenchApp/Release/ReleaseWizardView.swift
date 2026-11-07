import StorebenchCore
import SwiftUI

/// Next saves local edits on this Mac and moves on; it never changes Apple. Each Apple change is still a prepared review that you approve.
struct ReleaseWizardView: View {
    let account: Account, app: Account.App, session: WorkspaceSession?, changed: () -> Void
    let openCancellation: (AppOverviewVersions.Cancellation) -> Void
    let scrollTo: (String, UnitPoint) -> Void
    /// Counts Continue Version clicks made while the wizard is open; each opens the step that needs action.
    var continueRequests = 0
    @State private var model: ReleasePlanEditor?
    @State private var readiness: ReleaseReadinessEditor?
    @State private var listing: VersionListingEditor?
    @State private var history: [Revision] = []
    /// Whether step 3's Asset Library upload was read, and whether it still has files to upload before Save is offered.
    @State private var availability: NewVersionAvailability = .available(submittedDraft: nil)
    @State private var protectionId = UUID().uuidString
    @State private var loadStatus = ""
    @State private var loadMessage = "Reading the saved version plan…"
    @State private var loading = false
    @State private var loadTicket: UUID?
    @State private var phase = "plan"
    @State private var phaseChosen = false
    @State private var initialDecided = false
    @State private var focus: ReleaseWizard.Focus?
    @State private var focusedLocale: String?
    @State private var fieldFocus: ReleaseFieldFocus?
    @State private var submitBuildId: String?
    /// Counts the needs-action row's Add Build clicks; the Build step prepares that review in place.
    @State private var addBuildRequests = 0
    @State private var operation: Task<Void, Never>?
    /// Reads the listing editors for the plan it was started for; leaving the step does not stop it.
    @State private var listingWarm: (plan: String, task: Task<Void, Never>)?
    @Environment(\.readyReviews) private var readyReviews
    @Environment(\.editorProtection) private var protection
    @Environment(\.openURL) private var openURL
    @Environment(\.recoveryNavigation) private var recoveryNavigation
    /// Counts presses of the step's Add for Review command, which the Add for Review panel answers in place.
    @State private var submitRequests = 0
    @Environment(\.releaseStepHistory) private var stepHistory
    @Environment(\.navigationPresentation) private var presentation
    private var identity: String { JSONText.array([.string(account.id), .string(app.id)]).stringify() }
    private var confirmedPlan: String? { model.flatMap { $0.ready && !$0.dirty ? $0.expected : nil } }
    private var settled: Bool { model != nil && (initialDecided || phaseChosen) }

    var body: some View {
        Group {
            let guide = ReleaseGuide.guide(readiness?.snapshot?.steps, appleState: readiness?.snapshot?.targetState)
            ReleaseWizardLayout {
                // Real step names at once; statuses follow from the saved status or the first check.
                // Only a saved plan is checked against App Store Connect; with no version started the steps show where to begin.
                ReleaseStepRail(guide: guide, selected: phase, select: { go($0) }, checking: model == nil || (model?.plan != nil && confirmedPlan != nil && readiness?.snapshot == nil))
                    .storebenchWorking(model == nil)
                pane(guide: guide)
            }
        }
        .environment(\.releaseStepNavigation, { go($0) })
        .environment(\.releaseFieldFocus, fieldFocus)
        .environment(\.releaseChecklistReturn, { backToChecklist() })
        // Every save of the listing checks the step again, so the list matches what is saved.
        .onChange(of: listing?.dirty) { was, now in if was == true, now == false { recheck() } }
        .task(id: identity) {
            // Back and Forward reopen the step that was open in that history entry.
            if let saved = stepHistory?.wrappedValue, ReleaseWizard.phaseIds.contains(saved), !phaseChosen { phase = saved; phaseChosen = true }
            await load()
        }
        .onChange(of: continueRequests) { go(ReleaseWizard.initialPhase(ReleaseGuide.guide(readiness?.snapshot?.steps, appleState: readiness?.snapshot?.targetState))) }
        .onChange(of: settled ? phase : nil) { _, shown in if let shown, stepHistory?.wrappedValue != shown { stepHistory?.wrappedValue = shown } }
        // Background status reads continue with the parts the open step shows.
        .onChange(of: phase) { _, shown in readiness?.focus = ReleaseWizard.reads(shown) }
        .onChange(of: stepHistory?.wrappedValue) { _, saved in
            guard let saved, saved != phase, ReleaseWizard.phaseIds.contains(saved) else { return }
            phaseChosen = true; phase = saved; focus = nil; fieldFocus = nil
            if confirmedPlan != nil, readiness?.busy != true { operation = Task { await refreshStatus(initial: false) } }
        }
        .task(id: confirmedPlan) {
            // The remembered status shows first and decides the step. The step opens once its status is known.
            await refreshStatus(initial: true)
            if model != nil, !Task.isCancelled { initialDecided = true }
        }
        // Only the steps that show the listing read its editors, once the opening step is decided; Build and later steps never wait for them.
        .task(id: "\(confirmedPlan ?? "")/\(settled && ReleaseWizard.needsListing(phase))") { if settled, ReleaseWizard.needsListing(phase) { warmListing() } }
        .task(id: "\(confirmedPlan ?? "")/\(phase)/\(readiness?.snapshot?.targetVersionId ?? "")") { await prefetchNext() }
        // The language opened in a step stays open when Back returns to that step.
        .historyValue("release-language", $focusedLocale)
        // Each confirmed check, failure or Apple state change schedules the next automatic check.
        .task(id: "\(confirmedPlan ?? "")/\(readiness?.snapshot?.targetState ?? "")/\(readiness?.checkedAt?.timeIntervalSince1970 ?? 0)/\(readiness?.failures ?? 0)") { await syncStatus() }
        .onDisappear {
            loadTicket = nil; loading = false; operation?.cancel(); listingWarm?.task.cancel(); listingWarm = nil; listing?.retire(); readiness?.retire(); model?.retire()
            protection?.remove(id: protectionId)
        }
    }

    // MARK: Step content

    @ViewBuilder private func pane(guide: ReleaseGuide.Guide) -> some View {
        let current = guide.phases.first { $0.id == phase } ?? guide.phases[0]
        VStack(alignment: .leading, spacing: 20) {
            heading(current, guide: guide).id("release-step-heading")
            if let model, settled { content(current, guide: guide, model: model).id("release-phase-\(current.id)") }
            else { placeholderContent(current).id("release-phase-\(current.id)") }
            navigation(current, guide: guide)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    /// While the step's data is read, its real card is drawn with one status line inside it, never stand-in bars.
    private func placeholderContent(_ current: ReleaseGuide.Phase) -> some View {
        Card(title: current.title, subtitle: current.purpose) {
            StorebenchLoadState(state: model != nil ? .loading("Checking this step against App Store Connect…")
                                : loadStatus.isEmpty ? .loading(loadMessage) : .failed(loadStatus, retry: { await load() })) { EmptyView() }
        }
    }
    private func heading(_ current: ReleaseGuide.Phase, guide: ReleaseGuide.Guide) -> some View {
        let reserving = model == nil || (!settled && model?.plan != nil)
        // Every step can read App Store Connect again, for example after a build is uploaded with Transporter or Xcode.
        // It is dimmed until a saved version exists, and shows its spinner while it checks.
        return Card(title: "Step \(current.number) of \(guide.phases.count): \(current.title)", subtitle: current.purpose, help: "versions",
             actions: AnyView(StorebenchBusyButton(title: "Refresh Status", loadingTitle: "Checking…", busy: readiness?.busy == true) { operation = Task { await refreshStatus(initial: false, fresh: true) } }
                .storebenchWorking(model?.plan == nil || reserving).help(model?.plan == nil ? "Create the new version first" : "Check this version against App Store Connect again"))) {
            let missing = ReleaseWizard.missing(current)
            if reserving {
                StorebenchLoadingStatus(message: model == nil ? "Reading the saved version plan…" : "Checking this step against App Store Connect…", surface: false)
            } else if model?.plan == nil && current.id != "plan" {
                StorebenchStepLink(sentence: "Create the new version first. Every later step belongs to it.", phaseNumber: 1, phaseTitle: "New Version")
            } else if current.locked, let notice = guide.lockNotice {
                StorebenchNotice(title: notice.title, description: notice.description, icon: "info") { EmptyView() }
            } else if current.id == "release", current.steps.contains(where: { $0.id == "release" && $0.state == .blocked }),
                      let next = guide.current.flatMap({ $0.id == "release" ? nil : $0 }) ?? guide.phases.first(where: { $0.id == "submit" }) {
                // Nothing here can be done before App Review approves the version, so the step names where to continue instead.
                StorebenchStepLink(sentence: "This step follows App Review. Finish the steps above in order; the next one is",
                                   phaseNumber: next.number, phaseTitle: next.title)
            } else if !missing.isEmpty {
                StorebenchNotice(title: missing.count == 1 ? "1 thing still needed" : "\(missing.count) things still needed",
                                 description: missing.count == 1 ? "Fix it below, then continue with Next." : "Fix them below, then continue with Next.", icon: "warning") { EmptyView() }
                if let readiness { ReleaseCheckList(steps: missing.map(ReleaseWizard.presented), ready: readiness.ready, open: { open($0) }, fix: { fix($0, $1) },
                                                       actionable: { !opensBelow($0, in: current.id) }) }
            } else if current.status == .done {
                StorebenchNotice(title: "This step is done", description: "Continue with Next.", icon: "check") { EmptyView() }
            }
            // Edits here stay on this Mac; say so where they are made, with the one step that sends them.
            if current.id == "listing", !reserving, !current.locked, let send = guide.phases.first(where: { $0.id == "send" }), !send.locked,
               send.steps.contains(where: { $0.state == .blocked && $0.id != "version" }) || send.status == .current {
                StorebenchStepLink(sentence: "Saved on this Mac only. Screenshots go to App Store Connect with Save to App Previews and Screenshots below; text when you save it in step \(send.number).",
                                   phaseNumber: send.number, phaseTitle: send.title)
            }
            if let readiness, !readiness.status.isEmpty, model?.plan != nil {
                StorebenchTextSlot(text: readiness.status, height: 40, font: .sbCallout, color: StorebenchTheme.muted, live: true)
            }
            if model?.plan != nil {
                StorebenchTextSlot(text: freshness, height: 20, font: .sbCaption, color: StorebenchTheme.muted, live: true)
            }
        }
    }
    @ViewBuilder private func content(_ current: ReleaseGuide.Phase, guide: ReleaseGuide.Guide, model: ReleasePlanEditor) -> some View {
        switch current.id {
        case "plan":
            VersionPlanCard(model: model, history: history, availability: availability, protectionId: protectionId, didSave: { creating in
                guard let session else { return }
                availability = await session.newVersionAvailability(accountId: account.id, appId: app.id)
                if !model.dirty { changed() }
                if creating { go("listing") }
            })
        case "listing":
            if let saved = model.plan, let listing, listing.active, listing.scope.revisionId == saved.sourceRevisionId, listing.versionId == saved.baseVersionId {
                VersionListingView(account: account, planEditor: model, session: session, focusedLocale: $focusedLocale, providedModel: listing, saved: { continueToSend(guide) })
                .id("version-listing-\(saved.accountId)/\(saved.appId)/\(saved.sourceRevisionId)/\(saved.baseVersionId)")
                screenshotsSave(guide: guide, listing: listing)
            } else if model.plan != nil {
                StorebenchLoadState(state: .loading("Reading planned listing…")) { EmptyView() } placeholder: { StorebenchCollectionPlaceholder(rows: 3) }
            }
        case "send":
            if current.locked {
                // Apple rejects version changes after submission, so only removing the version from review is offered here.
                Card(title: "Saved at Apple", subtitle: current.status == .differs ? "The draft on this Mac differs from what Apple has for this version. It stays on this Mac and is not sent while Apple reports \(AppStoreNames.state(guide.appleState ?? ""))."
                     + (guide.removable ? " To save it to Apple, remove the version from review below. This step offers the review again once App Store Connect shows Developer Rejected." : "")
                     : "Apple has this version's text and screenshots from its submission. Inputs on this Mac stay in their editors.") { EmptyView() }
                removeFromReview(current, guide: guide)
            } else if let snapshot = readiness?.snapshot {
                let scope = focusScope ?? ReleaseWizard.sendScope(current)
                // Screenshots and app previews are saved in step 2; this Save sends the version's text and copyright.
                PublishActionPanel(account: account, app: app, session: session, actions: [.release, .metadata, .copyright],
                                   initialRequest: scope == .metadata ? stageRequest(snapshot, PublishRequest.textStage) : request(scope, snapshot: snapshot), automatic: true,
                                   guided: (scope == .release ? "Create the version in App Store Connect" : "Save to App Store Connect",
                                            scope == .release ? "Creates the version with its release option. Its text follows in the next review on this step, and its screenshots in step 2. Nothing is sent until you approve."
                                                              : "Saves this version's text and copyright. Screenshots and app previews are saved in step 2."),
                                   fix: { fix(check: $0, in: guide) }, done: { _ in afterApple() })
                    .id("send-\(scope.rawValue)")
                ReleaseRecentSaves(account: account, app: app, session: session, scopes: [.release, .metadata, .versionCopyright])
            } else if model.plan != nil { statusPending }
        case "build":
            if current.locked, let saved = model.plan {
                Card(title: "Build for \(saved.targetVersion)", subtitle: guide.removable ? "Apple has this version with its attached build. To submit a new build, remove this version from review below. Once App Store Connect shows Developer Rejected, choose the new build here and add the version for review again."
                     : "Apple has this version with its attached build. A new build needs a new version.") { EmptyView() }
                removeFromReview(current, guide: guide)
                // Declarations are only for a build that uses non-exempt encryption; a build Apple records as No, or with an approved declaration, needs nothing more.
                if readiness?.snapshot?.steps.first(where: { $0.id == "export-compliance" })?.state != .ready {
                    AppInformationView(account: account, app: app, session: session, parts: [.exportCompliance], changed: { afterApple() })
                }
            } else if let saved = model.plan {
                // The build's own export compliance card covers declarations, documents and the answer, with one refresh.
                ReleaseBuildStep(account: account, app: app, session: session, plan: saved, versionId: readiness?.snapshot?.targetVersionId, selectedBuildId: $submitBuildId,
                                 focus: buildFocus, addRequests: addBuildRequests, goToSend: { go("send") }, done: afterApple)
            }
        case "review-information":
            if let snapshot = readiness?.snapshot {
                if let version = snapshot.targetVersionId {
                    ReviewInformationView(account: account, app: app, session: session, fixedVersionId: version).id("review-\(version)")
                } else {
                    StorebenchStepLink(sentence: "Save the version to App Store Connect first. App Review Information belongs to that version.", phaseNumber: 3, phaseTitle: "Save to App Store Connect")
                }
            } else if model.plan != nil { statusPending }
        case "submit":
            let information = informationParts(current)
            if !information.isEmpty { AppInformationView(account: account, app: app, session: session, parts: information, changed: { afterApple() }) }
            if let snapshot = readiness?.snapshot {
                if snapshot.targetVersionId == nil {
                    StorebenchStepLink(sentence: "Save the version to App Store Connect first. Only a version that exists there can be added for review.", phaseNumber: 3, phaseTitle: "Save to App Store Connect")
                } else {
                    let submitted = current.steps.contains { $0.id == "submission" && [.ready, .waiting].contains($0.state) }
                    // A build Apple already has for the version is submitted with it; only a missing one sends you back to Build.
                    let attached = snapshot.steps.contains { $0.id == "build" && $0.state == .ready }
                    // An unfinished earlier step is named above Add for Review, which stays in place: Apple's own check then says exactly what is missing.
                    if !submitted, let earlier = ReleaseWizard.unfinished(before: "submit", in: guide) {
                        StorebenchStepLink(sentence: "An earlier step may not be finished. Apple refuses to add a version for review while anything is missing; check",
                                           phaseNumber: earlier.number, phaseTitle: earlier.title)
                    }
                    Group {
                        if !submitted && submitBuildId == nil && !attached {
                            StorebenchStepLink(sentence: "Choose the build for this version first.", phaseNumber: 4, phaseTitle: "Build")
                        }
                        if submitted && guide.removable {
                            // As in App Store Connect, a new build needs the version removed from review first.
                            StorebenchStepLink(sentence: "To submit a new build, remove this version from review with Cancel Submission below. Then choose the build in", phaseNumber: 4, phaseTitle: "Build")
                        }
                        PublishActionPanel(account: account, app: app, session: session, actions: submitted ? [.cancel] : [.submit],
                                           initialRequest: request(submitted ? .cancelSubmission : .submit, snapshot: snapshot), automatic: true,
                                           guided: (submitted ? "Cancel Submission" : "Add for Review", PublishActionPanel.purpose(submitted ? .cancel : .submit)), fix: { fix(check: $0, in: guide) }, trigger: submitted ? 0 : submitRequests, done: { review in
                                            afterApple()
                                            // Once the version is out of review, its build can be changed in Build.
                                            if submitted, review?.state == "complete" { go("build") }
                                           })
                            .id("submit-\(submitted)-\(submitBuildId ?? "")")
                    }
                }
                // Once the version is with App Review these answers are settled; the card helps only before submitting.
                if !current.steps.contains(where: { $0.id == "submission" && [.ready, .waiting].contains($0.state) }) {
                    // Each section with what App Store Connect showed at the last read: done in green, its command kept for changes.
                    Card(title: "App Privacy and Tax Category", subtitle: "Answered in App Store changes with an Apple ID, because the API key cannot set them. They are usually answered once, before an app's first version.") {
                        StorebenchStatusList {
                            appleIDSection(snapshot.steps.first { $0.id == "privacy" }, title: "App Privacy", command: "Answer App Privacy", anchor: "app-privacy")
                            appleIDSection(snapshot.steps.first { $0.id == "tax" }, title: "Tax Category", command: "Choose Tax Category", anchor: "tax-category", separator: false)
                        }
                    }
                }
            } else if model.plan != nil { statusPending }
        default:
            if let snapshot = readiness?.snapshot, snapshot.targetVersionId != nil {
                // Only a version Apple holds for a manual release can be released here.
                let pending = guide.appleState == "PENDING_DEVELOPER_RELEASE" && current.steps.contains { $0.id == "release" && $0.state == .review }
                if pending {
                    PublishActionPanel(account: account, app: app, session: session, actions: [.releaseVersion],
                                       initialRequest: request(.releaseVersion, snapshot: snapshot),
                                       guided: ("Release this version", PublishActionPanel.purpose(.releaseVersion)), done: { _ in afterApple() })
                } else {
                    Card(title: "After App Review", subtitle: model.plan?.settings ?? "Apple releases the version as you chose once App Review approves it.") {
                        Text(Self.afterReview(model.plan?.releaseType))
                            .font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if model.plan != nil { statusPending }
        }
    }
    /// What happens after approval for the chosen App Store Version Release option.
    static func afterReview(_ releaseType: String?) -> String {
        switch releaseType {
        case "AFTER_APPROVAL": "Apple releases the version on the App Store as soon as App Review approves it. Nothing else is needed here."
        case "SCHEDULED": "Apple releases the version on the chosen date once App Review has approved it. Nothing else is needed here."
        default: "Apple shows the version as Pending Developer Release when App Review approves it. Come back to this step to release it."
        }
    }
    /// Cancel Submission where a change needs it, through the same prepared review as step 6.
    @ViewBuilder private func removeFromReview(_ current: ReleaseGuide.Phase, guide: ReleaseGuide.Guide) -> some View {
        if guide.removable, let snapshot = readiness?.snapshot, snapshot.targetVersionId != nil {
            PublishActionPanel(account: account, app: app, session: session, actions: [.cancel],
                               initialRequest: request(.cancelSubmission, snapshot: snapshot), done: { _ in afterApple() })
                .id("remove-\(current.id)-\(guide.appleState ?? "")")
        }
    }
    private var freshness: String {
        guard let readiness else { return ReleaseStatusSync.label(checked: nil, busy: model?.plan != nil && confirmedPlan != nil, failed: false, automatic: false, settling: false) }
        return ReleaseStatusSync.label(checked: readiness.checkedAt?.formatted(date: .omitted, time: .standard), busy: readiness.busy || readiness.filling, failed: readiness.readFailed,
                                       automatic: readiness.nextCheck != nil, settling: readiness.sinceWrite.map { $0 < .seconds(180) } == true && readiness.nextCheck != nil)
    }
    private var statusPending: some View {
        // The step's data is read from App Store Connect; one status line shows it, inside a real card rather than stand-in bars.
        Card(title: "App Store Connect", subtitle: "This step shows what Apple has for the version.") {
            StorebenchLoadState(state: readiness?.busy == true || readiness == nil ? .loading("Checking this step against App Store Connect…")
                                : .failed(readiness?.status.isEmpty == false ? readiness!.status : "The release status is not available yet.", retry: { await refreshStatus(initial: false) })) { EmptyView() }
        }
    }
    private func navigation(_ current: ReleaseGuide.Phase, guide: ReleaseGuide.Guide) -> some View {
        let (previous, next) = ReleaseWizard.neighbors(current.id)
        let title = { (id: String) in guide.phases.first { $0.id == id }.map { "step \($0.number): \($0.title)" } ?? "" }
        return StorebenchActionGroup(alignment: .trailing) {
            if let previous { Button("Back") { go(previous) }.help("Back to " + title(previous)) }
            // Add for Review is this step's work, so it is the step's main command; Next stays beside it.
            let submitting = current.id == "submit" && !current.steps.contains { $0.id == "submission" && [.ready, .waiting].contains($0.state) } && readiness?.snapshot?.targetVersionId != nil
            if let next { Button("Next") { go(next) }.buttonStyle(StorebenchButtonStyle(submitting ? .secondary : .primary)).help("Save and continue to " + title(next)) }
            else if !submitting { StorebenchGuideExit(guide: .release) }
            if let submit = submitting ? { submitRequests += 1 } : nil as (() -> Void)? {
                Button("Add for Review", action: submit).buttonStyle(StorebenchButtonStyle(.primary)).help("Prepare, then confirm adding this version for review")
            }
        }
    }

    // MARK: Navigation

    private var focusScope: PublishRequest.Scope? {
        if case .publish(let request)? = focus, [.release, .metadata, .versionCopyright].contains(request.scope) { return request.scope }
        return nil
    }
    private var buildFocus: ReleaseWizard.Focus? {
        if case .build? = focus { return focus }
        return nil
    }
    /// The one place screenshots reach App Store Connect: below the editor that chooses and orders them. Its review is prepared
    /// again after edits are saved on this Mac, while the last one stays on screen.
    @ViewBuilder private func screenshotsSave(guide: ReleaseGuide.Guide, listing: VersionListingEditor) -> some View {
        if let send = guide.phases.first(where: { $0.id == "send" }), !send.locked, let snapshot = readiness?.snapshot {
            if ReleaseWizard.sendScope(send) == .metadata {
                PublishActionPanel(account: account, app: app, session: session, actions: [.metadata], initialRequest: stageRequest(snapshot, PublishRequest.screenshotsStage), automatic: true,
                                   guided: ("Save to App Previews and Screenshots", "Uploads files Apple does not have yet to Asset Library, then adds them to this version's App Previews and Screenshots in the order above. Text is saved in step \(send.number)."),
                                   refreshKey: listing.dirty || listing.busy ? "editing" : "saved", fix: { fix(check: $0, in: guide) }, done: { _ in afterApple() })
                    .id("listing-screenshots")
            } else {
                Card(title: "Save to App Previews and Screenshots", subtitle: "The version must exist in App Store Connect first. Create it in step \(send.number), then save its screenshots here.") { EmptyView() }
            }
        }
    }
    /// The step 2 screenshots Save or the step 3 text Save of this version's saved listing.
    private func stageRequest(_ snapshot: ReleaseReadinessSnapshot, _ stage: String) -> PublishRequest {
        var request = self.request(.metadata, snapshot: snapshot); request.mediaStage = stage; return request
    }
    private func request(_ scope: PublishRequest.Scope, snapshot: ReleaseReadinessSnapshot) -> PublishRequest {
        switch scope {
        case .metadata:
            return .init(accountId: account.id, appId: app.id, scope: .metadata, targetMode: "release-plan", revisionId: snapshot.plan.sourceRevisionId, versionId: snapshot.plan.baseVersionId)
        case .release:
            return .init(accountId: account.id, appId: app.id, scope: .release)
        case .submit:
            return .init(accountId: account.id, appId: app.id, scope: .submit, versionId: snapshot.targetVersionId, buildId: submitBuildId)
        default:
            return .init(accountId: account.id, appId: app.id, scope: scope, versionId: snapshot.targetVersionId)
        }
    }
    /// Every move between steps saves local edits on this Mac first, then checks the new step against App Store Connect.
    /// After Save in step 2 the text is sent from its own step: Release opens it and goes to Send to Apple once its review is ready.
    /// A screenshots review still waiting in step 2 keeps the step open, so it is not left behind.
    private func continueToSend(_ guide: ReleaseGuide.Guide) {
        guard phase == "listing", readyReviews?.entries.isEmpty != false, let send = guide.phases.first(where: { $0.id == "send" }), !send.locked else { return }
        go("send")
        Task { @MainActor in
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(150)); guard phase == "send" else { return }
                if let first = readyReviews?.entries.first, !first.sending { readyReviews?.show(first.id); return }
            }
        }
    }

    private func go(_ id: String, _ target: ReleaseWizard.Focus? = nil) {
        guard ReleaseWizard.phaseIds.contains(id) else { return }
        let change: @MainActor () -> Void = {
            let moved = id != phase
            phaseChosen = true; phase = id; focus = target
            if case .language? = target {} else { fieldFocus = nil }
            if moved, confirmedPlan != nil, readiness?.busy != true { operation = Task { await refreshStatus(initial: false) } }
            if case .language(let locale)? = target { focusedLocale = locale }
            let destination: (String, UnitPoint)
            if case .information(let anchor)? = target { destination = ("release-info-" + anchor, .top) }
            else if case .language(let locale)? = target { destination = fieldFocus.map { ($0.anchor, .center) } ?? (ReleaseReadiness.languageAnchor(locale), .top) }
            else if id == "build", target != nil { destination = ("release-build", .top) }
            // A new step opens at its heading, so its notice, such as Waiting for Review at Apple, is in view.
            else { destination = ("release-step-heading", .top) }
            Task { @MainActor in
                scrollTo(destination.0, destination.1)
                // A step that was not open yet lays out its editors first; scroll again once they exist.
                guard moved else { return }
                try? await Task.sleep(for: .milliseconds(400)); guard phase == id else { return }
                scrollTo(destination.0, destination.1)
            }
        }
        if id == phase { change(); return }
        if let protection { protection.saveAndContinue(change) } else { change() }
    }
    /// One Apple ID section as the last status check read it: Done with what App Store Connect showed, otherwise not checked yet.
    private func appleIDSection(_ step: ReleaseReadiness.Step?, title: String, command: String, anchor: String, separator: Bool = true) -> some View {
        let done = step?.state == .ready
        return StorebenchStatusRow(title: title, detail: step?.detail ?? "Not checked yet. Refresh Status reads it from App Store Connect.", separator: separator) {
            StorebenchFact(label: "Status", value: done ? "Done" : step == nil || step?.state == .manual ? "Not checked" : "Needed", done: done)
        } action: {
            Button(command) { openAppPrivacy(anchor: anchor) }.buttonStyle(StorebenchButtonStyle(.secondary)).help("Open \(title) in App Store changes")
        } details: { EmptyView() }
    }
    /// App Privacy and Tax Category are answered in App Store changes, with an Apple ID, because the API key cannot answer them.
    private func openAppPrivacy(anchor: String = "app-privacy") {
        if let action = RecoveryGuidance.Target.open(.publishing, anchor: anchor).resolved(scope: recoveryNavigation.scope) { recoveryNavigation.navigate?(action) }
    }
    private func open(_ step: ReleaseReadiness.Step) {
        fieldFocus = nil
        if step.id == AppleProblem.Area.privacy.rawValue { openAppPrivacy(); return }
        if step.id == AppleProblem.Area.tax.rawValue { openAppPrivacy(anchor: "tax-category"); return }
        guard let readiness, readiness.ready, let snapshot = readiness.snapshot, let action = try? ReleaseReadinessAction(snapshot: snapshot, stepId: step.id) else { return }
        // Add Build prepares its review in the Build step instead of only showing the build picker.
        if step.id == "build", step.state == .blocked, snapshot.targetVersionId != nil {
            go("build", .build(id: submitBuildId, action: nil)); addBuildRequests += 1; return
        }
        switch ReleaseWizard.destination(stepId: step.id, target: action.target) {
        case .external(let url): openURL(url)
        case .phase(let id, let target): go(id, target)
        }
    }
    /// A check whose command would only open what this step already shows below it. Fields and cards named by an anchor still get their command.
    private func opensBelow(_ step: ReleaseReadiness.Step, in phase: String) -> Bool {
        guard let snapshot = readiness?.snapshot, let action = try? ReleaseReadinessAction(snapshot: snapshot, stepId: step.id),
              case .phase(let id, let target) = ReleaseWizard.destination(stepId: step.id, target: action.target), id == phase else { return false }
        // The language editors live in Text and Screenshots and the App Information cards in their steps; anything else is the content below.
        switch target {
        case .language?: return phase != "listing"
        case .information?: return false
        default: return true
        }
    }
    /// Done saves the listing, returns to the step's list and checks it again.
    private func backToChecklist() {
        let back: @MainActor () -> Void = { fieldFocus = nil; scrollTo("release-step-heading", .top); recheck() }
        if let protection { protection.saveAndContinue(back) } else { back() }
    }
    private func recheck() {
        guard confirmedPlan != nil else { return }
        operation = Task { await refreshStatus(initial: false) }
    }
    /// Fix opens the exact field or the screenshots a language problem names, scrolled into view and highlighted.
    /// Opens the Release check Apple's refusal points to, such as Age Ratings. Back returns to the review, which stays saved.
    private func fix(check id: String, in guide: ReleaseGuide.Guide) {
        if id == AppleProblem.Area.pricing.rawValue, let action = RecoveryGuidance.Target.open(.pricing).resolved(scope: recoveryNavigation.scope) { recoveryNavigation.navigate?(action); return }
        if id == AppleProblem.Area.privacy.rawValue { openAppPrivacy(); return }
        if id == AppleProblem.Area.tax.rawValue { openAppPrivacy(anchor: "tax-category"); return }
        if let step = guide.phases.flatMap(\.steps).first(where: { $0.id == id }) { open(step) }
        // Text, screenshots and the version's own fields are edited in step 2 and saved in step 3.
        else if id == AppleProblem.Area.listing.rawValue { go("listing") }
        else if [AppleProblem.Area.version.rawValue, AppleProblem.Area.copyright.rawValue].contains(id) { go("send") }
    }
    private func fix(_ step: ReleaseReadiness.Step, _ issue: ReleaseMaterial.Issue) {
        guard step.id.hasPrefix("local:") else { open(step); return }
        let locale = String(step.id.dropFirst("local:".count))
        fieldFocus = ReleaseFieldFocus(anchor: ReleaseReadiness.fieldAnchor(locale, issue.section == "screenshots" ? "screenshots" : issue.field))
        go("listing", .language(locale))
    }
    /// App Information cards shown before Add for Review, only for what Apple still needs.
    private func informationParts(_ phase: ReleaseGuide.Phase) -> Set<AppInformationView.Part> {
        let parts: [String: AppInformationView.Part] = ["app-configuration": .categories, "age-rating": .ageRating, "accessibility": .accessibility, "territories": .availability]
        return Set(ReleaseWizard.missing(phase).compactMap { parts[$0.id] })
    }
    /// A Save to App Store Connect clears the shared reads; the status is read again, then what the later steps show, so they open at once.
    private func afterApple() {
        changed()
        readiness?.noteAppleWrite()
        let step = phase
        operation = Task {
            await refreshStatus(initial: false, full: true)
            guard !Task.isCancelled, let session else { return }
            await session.warmReleaseSteps(after: step, account: account, appId: app.id, versionId: readiness?.snapshot?.targetVersionId, plan: readiness?.snapshot?.plan)
            if let session = self.session { await prepareSubmissionAhead(session) }
        }
    }
    /// Checks App Store Connect again when the schedule says so; a full read runs only when Apple's version state changed.
    private func syncStatus() async {
        guard confirmedPlan != nil, let delay = readiness?.nextCheck else { return }
        do { try await Task.sleep(for: delay) } catch { return }
        guard !Task.isCancelled, let readiness, readiness.active else { return }
        await readiness.sync()
    }

    // MARK: Loading

    /// Starts reading the listing editors once per saved plan. Moving to another step lets it finish, so a step that is left and opened
    /// again keeps the same owners and their unsaved edits.
    private func warmListing() {
        guard let plan = confirmedPlan, listingWarm?.plan != plan else { return }
        listingWarm?.task.cancel()
        listingWarm = (plan, Task { await prepareListing() })
    }
    /// Keep the same local editor owners when moving Back and Next.
    private func prepareListing() async {
        guard let model, let plan = model.plan, confirmedPlan != nil, let session, !Task.isCancelled else { return }
        if let listing, listing.scope.revisionId != plan.sourceRevisionId || listing.versionId != plan.baseVersionId {
            listing.retire(); self.listing = nil
        }
        if listing == nil { listing = try? VersionListingEditor(planEditor: model, session: session) }
        await listing?.load()
    }

    /// Warm only reads for the next step. Local drafts are always read again by their editor.
    private func prefetchNext() async {
        guard confirmedPlan != nil, ["listing", "send", "build", "review-information", "submit"].contains(phase) else { return }
        // Editing a listing can take longer than the cache lifetime. Keep the next step warm while it is open, as next-step
        // reads behind what the open step shows, and back off while Apple's answers fail.
        var failures = 0
        repeat {
            let read = await ScreenReads.ahead { await prefetchNextRead() }
            failures = read ? 0 : failures + 1
            let lifetime = await session?.appleReadLifetime ?? .seconds(300)
            do { try await Task.sleep(for: ReleaseWizard.prefetchDelay(failures: failures, lifetime: lifetime)) } catch { return }
        } while !Task.isCancelled
    }
    /// Once every step before Add for Review is done, its review is prepared in the background, so step 6 shows it at once.
    /// Nothing is sent to Apple; Send to Apple in step 6 still sends it.
    private func prepareSubmissionAhead(_ session: WorkspaceSession) async {
        guard let snapshot = readiness?.snapshot, snapshot.targetVersionId != nil, !(readiness?.busy ?? true) else { return }
        let guide = ReleaseGuide.guide(snapshot.steps, appleState: snapshot.targetState)
        guard let submit = guide.phases.first(where: { $0.id == "submit" }), !submit.locked,
              !submit.steps.contains(where: { $0.id == "submission" && [.ready, .waiting].contains($0.state) }),
              ReleaseWizard.unfinished(before: "submit", in: guide) == nil else { return }
        await session.preparePublishingAhead(account: account, request: request(.submit, snapshot: snapshot), basis: ReleaseWizard.submissionBasis(snapshot))
    }
    /// Whether the next step's reads succeeded.
    private func prefetchNextRead() async -> Bool {
        guard confirmedPlan != nil, let session, !Task.isCancelled else { return true }
        do {
            let client = try await session.readClient(for: account)
            switch phase {
            case "listing": _ = try await session.publishingWorkspace(account: account, appId: app.id, client: client)
            case "send":
                if let plan = readiness?.snapshot?.plan {
                    _ = try await session.releaseBuildPage(account: account, appId: app.id, versionId: readiness?.snapshot?.targetVersionId, platform: plan.platform, version: plan.targetVersion)
                }
            case "build":
                // While the build is chosen and its export compliance answered, what Add for Review needs besides the build is read.
                // Its review is prepared only once every earlier step is done; the answer is never chosen for you.
                await prepareSubmissionAhead(session)
                let guide = ReleaseGuide.guide(readiness?.snapshot?.steps, appleState: readiness?.snapshot?.targetState)
                await session.warmProblemScreens(ReleaseWizard.submissionAhead(guide), account: account, appId: app.id, versionId: readiness?.snapshot?.targetVersionId)
            case "review-information":
                await prepareSubmissionAhead(session)
                // Only the App Information cards Add for Review will show, the ones Apple still needs.
                let guide = ReleaseGuide.guide(readiness?.snapshot?.steps, appleState: readiness?.snapshot?.targetState)
                let shown = guide.phases.first { $0.id == "submit" }.map(informationParts) ?? []
                if shown.contains(.accessibility) { _ = try await session.accessibilityDeclarations(appId: app.id, client: client) }
                if shown.contains(.ageRating) { _ = try await session.ageRatingAnswers(appId: app.id, client: client) }
                if !shown.isDisjoint(with: [.categories, .availability]) {
                    _ = try await session.appInformationState(appId: app.id, categories: shown.contains(.categories), availability: shown.contains(.availability), client: client)
                }
                _ = try await session.publishingWorkspace(account: account, appId: app.id, includeBuilds: true, client: client)
            case "submit":
                // What Add for Review still warns about, and the price Apple checks when the version is added, so each fix opens at once.
                let guide = ReleaseGuide.guide(readiness?.snapshot?.steps, appleState: readiness?.snapshot?.targetState)
                let warned = guide.phases.first { $0.id == "submit" }?.steps.filter { [.blocked, .unknown].contains($0.state) }.compactMap { AppleProblem.Area(rawValue: $0.id) } ?? []
                await session.warmProblemScreens(Set(warned + [.pricing]), account: account, appId: app.id)
            default: break
            }
            return true
        } catch { return false /* The destination owns retry and feedback for speculative reads. */ }
    }

    /// `full` reads everything again, as after an approved Apple change, the open step's parts first; otherwise unchanged saved material costs one version-state read.
    private func refreshStatus(initial: Bool, fresh: Bool = false, full: Bool = false) async {
        await ScreenReads.reading(fresh: fresh) {
            guard let model, let session, confirmedPlan != nil, !Task.isCancelled else { return }
            if readiness == nil {
                // The status remembered from an earlier visit shows at once and is read again right away.
                var seed: (snapshot: ReleaseReadinessSnapshot, checkedAt: Date)?
                if let plan = model.plan { seed = await session.rememberedReleaseReadiness(accountId: account.id, appId: app.id, planToken: plan.token) }
                guard readiness == nil, !Task.isCancelled else { return }
                let owner = ReleaseReadinessEditor(planEditor: model, account: account, session: session, seed: seed)
                readiness = owner
                if initial, !phaseChosen, owner.snapshot != nil {
                    phase = ReleaseWizard.initialPhase(ReleaseGuide.guide(owner.snapshot?.steps, appleState: owner.snapshot?.targetState)); initialDecided = true
                }
            }
            // The open step's parts are read first. Without a remembered status the first step is not known yet, so every part is read before choosing it.
            readiness?.focus = initial && !phaseChosen && readiness?.snapshot == nil ? .all : ReleaseWizard.reads(phase)
            // A save can invalidate an older background read. Let that owner finish before checking the new material.
            while readiness?.busy == true {
                do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
                guard !Task.isCancelled, readiness?.active == true else { return }
            }
            // Opening again with a recent remembered status costs one version-state read; otherwise everything is read.
            let current = fresh || full ? await readiness?.refresh() : await readiness?.revalidate()
            guard current == true, initial, !phaseChosen else { return }
            phase = ReleaseWizard.initialPhase(ReleaseGuide.guide(readiness?.snapshot?.steps, appleState: readiness?.snapshot?.targetState))
        }
    }
    private func load() async {
        guard model == nil, !loading, let session, !Task.isCancelled else { return }
        let ticket = UUID(); loadTicket = ticket; loading = true; loadStatus = ""
        defer { if loadTicket == ticket { loading = false; loadTicket = nil } }
        protection?.policy.update(id: protectionId, dirty: false, busy: true)
        do {
            // A new plan starts from current Apple material, including downloaded screenshot originals.
            // Existing plans keep their saved source and every local edit.
            // Opening Release again shows the starting versions read earlier in this window at once and reads them again afterwards.
            let historyKey = "release-history/\(account.id)/\(app.id)"
            let remembered = await presentation?.rememberedDecodedRead(historyKey, as: [Revision].self)
            try Task.checkCancellation(); guard loadTicket == ticket else { return }
            // A saved plan opens straight from its own small record; the starting versions behind it are read after the step is shown.
            let savedPlan = remembered == nil ? try await session.releasePlan(accountId: account.id, appId: app.id) : nil
            var savedHistory = remembered
            if savedHistory == nil, savedPlan == nil {
                // Without a saved plan the version starts from current Apple material, which can take a while to download.
                if (try? await session.releaseStartNeedsImport(account: account, appId: app.id)) == true, loadTicket == ticket { loadMessage = "Reading the current version from App Store Connect…" }
                savedHistory = try await session.releaseStartingHistory(account: account, appId: app.id)
            }
            try Task.checkCancellation(); guard loadTicket == ticket else { return }
            if let savedHistory { history = savedHistory; presentation?.rememberRead(savedHistory, historyKey) }
            // Start from what is saved: the plan itself, else the version still being prepared at Apple, else a copy into the next number, else a first version.
            let suggestionDate = Date().addingTimeInterval(7 * 86_400)
            let preference = savedPlan == nil ? try? await session.releasePreference(accountId: account.id, appId: app.id) : nil
            let initial = savedPlan.map { ReleasePlanInputs($0, fallbackDate: suggestionDate) } ?? ReleasePreference.applying(preference, to: ReleaseSetup.suggestion(savedHistory ?? [], date: suggestionDate))
            let owner = ReleasePlanEditor(account: account, appId: app.id, initial: initial, session: session), ownerId = protectionId
            owner.didChange = { [weak owner, weak editingProtection = protection] in
                guard let owner, owner.active else { editingProtection?.remove(id: ownerId); return }
                editingProtection?.policy.update(id: ownerId, dirty: owner.dirty, busy: owner.busy)
            }
            protection?.registerSave(id: ownerId, priority: -10, generation: String(describing: ObjectIdentifier(owner))) { [weak owner] in
                guard let owner, owner.active, owner.ready else { return false }
                let saved = await owner.save()
                return saved && owner.active && !owner.dirty
            }
            model = owner; loadStatus = ""; await owner.load()
            guard owner.active, !Task.isCancelled else { return }
            // A version App Store Connect is already preparing needs no Create: the plan to continue it is saved on this Mac right away.
            // A plan read a moment ago is never saved again from its own record, even if it was removed meanwhile.
            if savedPlan == nil, owner.plan == nil, case .reuse = initial.start, owner.ready, await owner.save(), owner.active, !Task.isCancelled { changed() }
            availability = await session.newVersionAvailability(accountId: account.id, appId: app.id)
            // A plan that needs no status check opens at once; otherwise the first check decides the step.
            if confirmedPlan == nil { initialDecided = true }
            // The starting versions are read again after the step is shown: remembered ones may be old, and a saved plan opened without them.
            if remembered != nil || savedHistory == nil, let latest = try? await session.releaseStartingHistory(account: account, appId: app.id), owner.active, !Task.isCancelled {
                history = latest; presentation?.rememberRead(latest, historyKey)
                // An unedited suggestion from remembered versions follows the fresh read; a saved plan keeps its own source.
                if remembered != nil { owner.suggest(ReleasePreference.applying(preference, to: ReleaseSetup.suggestion(latest, date: suggestionDate))) }
            }
        } catch {
            guard loadTicket == ticket else { return }
            protection?.remove(id: protectionId)
            if !Task.isCancelled { loadStatus = (error as? ImportFailure)?.message ?? "Saved starting versions could not be read." }
        }
    }
}

private struct ReleaseWizardLayout: Layout {
    private let railWidth: CGFloat = 248, gap: CGFloat = 24, stackAt: CGFloat = 880
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 1000
        guard subviews.count == 2 else { return .zero }
        if width >= stackAt {
            let rail = subviews[0].sizeThatFits(.init(width: railWidth, height: nil))
            let pane = subviews[1].sizeThatFits(.init(width: width - railWidth - gap, height: nil))
            return CGSize(width: width, height: max(rail.height, pane.height))
        }
        let rail = subviews[0].sizeThatFits(.init(width: width, height: nil))
        let pane = subviews[1].sizeThatFits(.init(width: width, height: nil))
        return CGSize(width: width, height: rail.height + gap + pane.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        if bounds.width >= stackAt {
            subviews[0].place(at: bounds.origin, proposal: .init(width: railWidth, height: nil))
            subviews[1].place(at: CGPoint(x: bounds.minX + railWidth + gap, y: bounds.minY), proposal: .init(width: bounds.width - railWidth - gap, height: nil))
        } else {
            let rail = subviews[0].sizeThatFits(.init(width: bounds.width, height: nil))
            subviews[0].place(at: bounds.origin, proposal: .init(width: bounds.width, height: nil))
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + rail.height + gap), proposal: .init(width: bounds.width, height: nil))
        }
    }
}
