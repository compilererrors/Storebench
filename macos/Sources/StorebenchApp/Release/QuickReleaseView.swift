import StorebenchCore
import SwiftUI

/// A complete update in four steps, with other release settings kept inside this page.
/// Save keeps edits on this Mac; each change at App Store Connect is a prepared review that you approve.
struct QuickReleaseView: View {
    let account: Account, app: Account.App, session: WorkspaceSession?, changed: () -> Void
    var continueRequests = 0
    var providedModel: ReleasePlanEditor? = nil
    var providedHistory: [Revision] = []
    var providedSnapshot: ReleaseReadinessSnapshot? = nil
    @State private var model: ReleasePlanEditor?
    @State private var readiness: ReleaseReadinessEditor?
    @State private var listing: VersionListingEditor?
    @State private var history: [Revision] = []
    @State private var availability: NewVersionAvailability = .available(submittedDraft: nil)
    @State private var protectionId = UUID().uuidString
    @State private var listingProtectionId = UUID().uuidString
    @State private var loadStatus = ""
    @State private var loading = false
    @State private var locale: String?
    @State private var buildId: String?
    @State private var textStatus = ""
    @State private var textReview: PublishReview?
    @State private var publishingText = false
    @State private var operation: Task<Void, Never>?
    @State private var versionExpanded = false
    @State private var otherTextExpanded = false
    @State private var otherTextOpened = false
    @State private var details: Set<QuickReleaseDetail> = []
    @State private var fieldFocus: ReleaseFieldFocus?
    @State private var createRequests = 0
    @State private var requestedVersionPlan: String?
    @State private var notesRequired = true
    @State private var selectedStep: String?
    @State private var mountedSteps: Set<String> = []
    @Environment(\.editorProtection) private var protection
    @Environment(\.pageScroll) private var pageScroll
    @Environment(\.navigationPresentation) private var presentation
    @Environment(\.recoveryNavigation) private var parentRecovery
    /// Shared with Release and the background preparation.
    private var historyKey: String { "release-history/\(account.id)/\(app.id)" }
    private var identity: String { JSONText.array([.string(account.id), .string(app.id)]).stringify() }
    private var confirmedPlan: String? { model.flatMap { $0.ready && !$0.dirty ? $0.expected : nil } }
    private var snapshot: ReleaseReadinessSnapshot? { readiness?.snapshot ?? providedSnapshot }
    private var phases: [QuickRelease.Phase] {
        let values = listing.flatMap { owner -> [String: String]? in
            guard !owner.loading, !owner.languages.isEmpty, owner.languages.allSatisfy({ $0.text.editor != nil }) else { return nil }
            return Dictionary(uniqueKeysWithValues: owner.languages.compactMap { language in
                guard let editor = language.text.editor, let field = editor.fields.first(where: { $0.key == "whatsNew" }) else { return nil }
                return (language.locale, editor.value(field))
            })
        }
        return QuickRelease.progress(plan: model?.plan, snapshot: snapshot, edited: model?.dirty == true,
                                     notes: values, notesEdited: listing?.workflow.shown.dirty == true, notesRequired: notesRequired)
    }
    private var selected: String { selectedStep ?? "version" }
    private var initialSelectionPlan: String? {
        guard let plan = model?.plan, snapshot?.plan.token == plan.token else { return nil }
        return plan.token
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StorebenchTheme.gap) {
            if let model, model.loaded {
                    if let snapshot, case .submitted(let state) = QuickRelease.stage(snapshot) {
                        ReleaseSubmittedStatus(version: snapshot.plan.label, state: state)
                    }
                    StorebenchStepLayout {
                        StorebenchStepRail(title: "Quick Release", items: phases.map {
                            .init(id: $0.id, number: $0.number, title: $0.title, label: $0.check.label, complete: $0.complete,
                                  current: $0.id == QuickRelease.initialStep(phases), tone: $0.check.status.tone)
                        }, selected: selected, select: reveal, identifierPrefix: "quick.step.", showsNumbers: true)
                            .storebenchControlID("quick.rail")
                        pane(model).storebenchControlID("quick.pane")
                    }
            } else {
                Card(title: "Quick Release", subtitle: AppNavigation.Section.quickRelease.purpose) {
                    StorebenchLoadState(state: loadStatus.isEmpty ? .loading("Reading the saved version plan…") : .failed(loadStatus, retry: { await load() })) { EmptyView() }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .storebenchControlID("quick.release")
        .task(id: identity) { await load() }
        .onChange(of: initialSelectionPlan, initial: true) { _, token in
            if selectedStep == nil, token != nil { selectedStep = QuickRelease.initialStep(phases) }
        }
        .onChange(of: continueRequests) { reveal(QuickRelease.initialStep(phases)) }
        .environment(\.openReleaseStep, { reveal(QuickRelease.step(for: $0)) })
        .environment(\.openSection, { openHere($0) })
        .environment(\.editorNavigation, EditorNavigation(scope: try? .init(accountId: account.id, appId: app.id), navigate: { destination in
            guard destination.scope.accountId == account.id, destination.scope.appId == app.id else { return }
            locale = destination.context?.locale; openHere(destination.section)
        }))
        .environment(\.releaseFieldFocus, fieldFocus)
        .environment(\.recoveryNavigation, RecoveryNavigation(scope: try? .init(accountId: account.id, appId: app.id), navigate: { action in
            if action.target.requiresApp, let section = action.target.section { openHere(section) }
            else { parentRecovery.navigate?(action) }
        }))
        .task(id: confirmedPlan) {
            async let warm: Void = prepareListing()
            await refreshStatus()
            await warm
        }
        // Every save of the text checks the version again, so the list of what is still needed matches what is saved.
        .onChange(of: listing?.workflow.shown.dirty) { was, now in if was == true, now == false { recheck() } }
        .task(id: "\(confirmedPlan ?? "")/\(snapshot?.targetState ?? "")/\(readiness?.checkedAt?.timeIntervalSince1970 ?? 0)/\(readiness?.failures ?? 0)") { await syncStatus() }
        .onDisappear {
            operation?.cancel(); listing?.retire(); readiness?.retire(); model?.retire()
            protection?.remove(id: protectionId); protection?.remove(id: listingProtectionId)
        }
    }

    // MARK: Steps

    private func reveal(_ step: String) {
        selectedStep = QuickRelease.stepIDs.contains(step) ? step : QuickRelease.step(for: step)
        if selectedStep == "version" { versionExpanded = true }
        Task { @MainActor in await Task.yield(); pageScroll?("quick-step-heading", .top) }
    }

    private func pane(_ model: ReleasePlanEditor) -> some View {
        let current = phases.first { $0.id == selected } ?? phases[0]
        return VStack(alignment: .leading, spacing: StorebenchTheme.gap) {
            Card(title: "Step \(current.number) of 4: \(current.title)", subtitle: current.purpose,
                 actions: AnyView(StorebenchBusyButton(title: "Refresh Status", loadingTitle: "Checking…", busy: readiness?.busy == true) {
                     operation = Task { await refreshStatus(fresh: true) }
                 }.storebenchWorking(model.plan == nil))) {
                StorebenchCheckLabel(text: current.check.label, tone: current.check.status.tone)
                    .storebenchControlID("quick.current.status")
                StorebenchTextSlot(text: current.id == "version" && snapshot.map({ ReleaseCreation.blocker($0) != nil }) == true
                    ? "Open the current version below to resolve it. Your release draft stays saved here." : current.check.detail,
                                  height: 60, font: .sbCallout, color: StorebenchTheme.muted, live: true)
            }.id("quick-step-heading").storebenchControlID("quick.current." + current.id)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(phases) { step in
                    if mountedSteps.contains(step.id) || selected == step.id {
                        VStack(alignment: .leading, spacing: StorebenchTheme.gap) { stepContent(step.id, model: model) }
                            .onAppear { mountedSteps.insert(step.id) }.collectionVisibility(selected == step.id)
                    }
                }
            }
            if let plan = model.plan {
                QuickReleaseDetails(account: account, app: app, session: session, plan: plan, listing: listing,
                                    snapshot: snapshot, expanded: $details, editText: { openHere(.localizations) }, afterApple: afterApple)
            }
            StorebenchActionGroup(alignment: .trailing) {
                StorebenchCommand(title: "Back", busy: false, unavailable: current.number == 1 ? "This is the first step." : nil, primary: false) {
                    reveal(phases[current.number - 2].id)
                }.storebenchControlID("quick.back")
                if current.number < 4 {
                    StorebenchCommand(title: "Next", busy: false, unavailable: model.plan == nil ? "Prepare the release first." : nil) {
                        reveal(phases[current.number].id)
                    }.storebenchControlID("quick.next")
                }
            }
        }
    }

    @ViewBuilder private func stepContent(_ id: String, model: ReleasePlanEditor) -> some View {
        if id == "version" {
            DisclosureGroup("Version Settings", isExpanded: $versionExpanded) { versionCard(model) }
                .onChange(of: model.plan == nil, initial: true) { if model.plan == nil { versionExpanded = true } }
            if let plan = model.plan, phases[0].check.status != .ready || requestedVersionPlan == plan.token { create(plan) }
        } else if let plan = model.plan {
            switch id {
            case "text": text(plan)
            case "build": build(plan)
            default: status(plan); submit(plan)
            }
        } else {
            Card(title: "Prepare the Release First", subtitle: "Prepare the version in step 1. Then add What's New, choose the build and review the update here.") { EmptyView() }
        }
    }
    private func versionCard(_ model: ReleasePlanEditor) -> some View {
        VStack(alignment: .leading, spacing: StorebenchTheme.gap) {
            if let snapshot { ReleaseCreationNotice(snapshot: snapshot) }
            VersionPlanCard(model: model, history: history, availability: availability, protectionId: protectionId, didSave: { _ in
                selectedStep = "version"
                if let session { availability = await session.newVersionAvailability(accountId: account.id, appId: app.id) }
                if !model.dirty { changed() }
            }, quick: !QuickRelease.needsFullRelease(model.inputs, history: history), sync: { requestedVersionPlan = model.plan?.token; createRequests += 1; reveal("version") }, createTitle: "Prepare Release",
               syncTitle: snapshot?.targetVersionId == nil ? "Create Version" : "Sync to Apple")
        }
    }

    /// What Apple still reports for these checks, in its own words, such as "Subtitle · English (U.S.): differs from App Store Connect".
    private static func reasons(_ steps: [ReleaseReadiness.Step]) -> [String] {
        steps.map { $0.detail.isEmpty ? $0.label : "\($0.label): \($0.detail)" }
    }

    // MARK: Sections

    /// Confirmed requirements open their own fields or forms within the same workspace.
    @ViewBuilder private func status(_ plan: ReleasePlan) -> some View {
        let blockers = snapshot.map { QuickRelease.blockers($0.steps) } ?? []
        let unchecked = snapshot?.steps.filter { $0.state == .unknown && !QuickRelease.handledHere($0.id) } ?? []
        Card(title: "Release Requirements", subtitle: "Check what is still needed. Edit opens the relevant field or settings here in Quick Release.",
             actions: AnyView(StorebenchBusyButton(title: "Refresh Status", loadingTitle: "Checking…", busy: readiness?.busy == true) { operation = Task { await refreshStatus(fresh: true) } })) {
            if let snapshot {
                if case .submitted(let state) = QuickRelease.stage(snapshot) {
                    ReleaseSubmittedStatus(version: plan.label, state: state)
                } else if blockers.isEmpty && !unchecked.isEmpty {
                    StorebenchNotice(title: "Some Checks Are Still Pending", description: "No additional missing fields are confirmed. Refresh Status to finish checking the remaining release details.", icon: "info") { EmptyView() }
                } else if blockers.isEmpty {
                    StorebenchNotice(title: "Nothing else is needed", description: "Everything outside this page is ready for this version. Save the text, add the build, then Add for Review.", icon: "check") { EmptyView() }
                } else {
                    StorebenchNotice(title: blockers.count == 1 ? "1 thing still needed" : "\(blockers.count) things still needed",
                                     description: "Open the item below to complete it on this page, then continue with Add for Review.", icon: "warning") { EmptyView() }
                    ReleaseCheckList(steps: blockers.map(ReleaseWizard.presented), ready: readiness?.ready == true, open: { fix($0) }, fix: { fix($0, $1) })
                }
            } else {
                StorebenchLoadingStatus(message: readiness?.readFailed == true ? "The release status is not available yet. Choose Refresh Status." : "Checking this version against App Store Connect…", surface: false)
            }
            StorebenchTextSlot(text: readiness?.status ?? "", height: 40, font: .sbCallout, color: StorebenchTheme.muted, live: true)
            StorebenchTextSlot(text: freshness, height: 20, font: .sbCaption, color: StorebenchTheme.muted, live: true)
        }
    }

    /// Apple creates the version from the current one with its release option; its text follows in its own review.
    @ViewBuilder private func create(_ plan: ReleasePlan) -> some View {
        if let snapshot, ReleaseCreation.blocker(snapshot) != nil {
            if !versionExpanded { ReleaseCreationNotice(snapshot: snapshot) }
        } else if let snapshot, QuickRelease.stage(snapshot) == .create {
            PublishActionPanel(account: account, app: app, session: session, actions: [.release], initialRequest: PublishRequest(accountId: account.id, appId: app.id, scope: .release), automatic: requestedVersionPlan == plan.token,
                               guided: ("Create Version", "App Store Connect copies the current version's listing and screenshots. Review and approve creating version \(plan.targetVersion)."), prepareTitle: "Create Version", syncTitle: "Create Version",
                               fix: { fix(check: $0) }, checked: { requestedVersionPlan = nil; recheck() }, trigger: createRequests, done: { _ in afterApple() })
                .id("quick-create-\(plan.targetVersion)")
        } else if let snapshot, QuickRelease.stage(snapshot) == .prepare {
            // A release option changed after the version exists at Apple is saved there in its own review; an unchanged one needs nothing.
            PublishActionPanel(account: account, app: app, session: session, actions: [.release], initialRequest: PublishRequest(accountId: account.id, appId: app.id, scope: .release), automatic: requestedVersionPlan == plan.token,
                               guided: ("App Store Version Release", "\(plan.settings) for version \(plan.targetVersion). Review and approve the change."), prepareTitle: "Save", syncTitle: "Save",
                               refreshKey: plan.token, fix: { fix(check: $0) }, checked: { requestedVersionPlan = nil; recheck() }, trigger: createRequests, done: { _ in afterApple() })
                .id("quick-release-option-\(plan.targetVersion)")
        } else if snapshot == nil {
            Card(title: "Create in App Store Connect", subtitle: "Checking whether App Store Connect has version \(plan.targetVersion)…") { EmptyView() }
        } else {
            Card(title: "Create in App Store Connect", subtitle: "App Store Connect has version \(plan.targetVersion). Continue with its text.") { EmptyView() }
        }
    }

    /// Description, Subtitle, Keywords and What's New for one language at a time, saved for every language together.
    @ViewBuilder private func text(_ plan: ReleasePlan) -> some View {
        Card(title: "What's New in This Version", subtitle: "Write the release notes for each language. The existing listing is reused; other text is available below.", help: "listing") {
            if let listing, listing.active, listing.matchesPlan, !listing.loading, listing.revision != nil {
                let languages = listing.languages
                if languages.count > 1 {
                    StorebenchPicker("Language", selection: Binding(get: { selectedLocale(languages) ?? "" }, set: { value in locale = value })) {
                        selectionOptions(languages.map(\.locale)) { SelectionOption(StoreLocales.name($0) + " (\($0))", value: $0) }
                    }.storebenchFormColumn()
                }
                if let current = languages.first(where: { $0.locale == selectedLocale(languages) }) {
                    fields(current.text, keys: ["whatsNew"])
                    DisclosureGroup(isExpanded: $otherTextExpanded) {
                        if otherTextOpened, let revision = listing.revision, let version = listing.version {
                            LanguageEditor(account: account, revision: revision, version: version,
                                scope: .init(accountId: account.id, appId: app.id, revisionId: plan.sourceRevisionId, local: false), locale: current.locale,
                                targetMode: "release-plan", session: session, openReview: { textReview = $0.review; return true },
                                providedModel: current.text, contained: true, omittedFields: ["whatsNew"], didSync: afterApple, didCheck: recheck)
                                .id("quick-other-text-" + current.locale)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Text("Other Listing Text").font(.sbHeadline)
                            Spacer(minLength: 8)
                            let missing = snapshot?.steps.first { $0.id == "local:" + current.locale }?.issues.filter { $0.field != "whatsNew" && $0.field != "screenshots" }.count ?? 0
                            if missing > 0 { Text("\(missing) Need Action").font(.sbCaption).foregroundStyle(StorebenchTheme.color("color-danger")) }
                        }.storebenchControlID("quick.text.other")
                    }.onChange(of: otherTextExpanded) { if otherTextExpanded { otherTextOpened = true } }
                }
                else { Text("No saved language text is available. Refresh Status to check the version.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted) }
                let feedback = textStatus.isEmpty ? listing.status : textStatus
                StorebenchTextSlot(text: feedback, height: 40, font: .sbCallout, color: StorebenchTheme.muted, live: true)
                StorebenchFormFooter {
                    StorebenchBusyButton(title: "Save Draft", loadingTitle: "Saving…", busy: listing.workflow.phase == .saving) { save(listing) }
                        .help("Save the text of every language on this Mac")
                        .storebenchWorking(!listing.workflow.shown.dirty || listing.busy || listing.workflow.shown.blocked || publishingText)
                        .storebenchControlID("quick.text.save")
                    StorebenchBusyButton(title: "Sync to Apple", loadingTitle: "Preparing…", busy: listing.workflow.phase == .preparing, variant: .primary) { save(listing, sync: true) }
                        .storebenchWorking(listing.busy || listing.workflow.shown.blocked || publishingText)
                        .storebenchControlID("quick.text.sync")
                }
            } else {
                StorebenchLoadState(state: listing == nil && confirmedPlan == nil ? .loading("Save the version first.") : .loading("Reading the version's saved text…")) { EmptyView() }
            }
        }
        .id("quick-text")
        .onChange(of: listing?.workflow.lastResult) {
            if textReview?.state == "prepared", listing?.workflow.lastResult?.reviewReady != true { textReview = nil }
        }
        if let listing {
            ReviewPanel(account: account, app: app, session: session, review: $textReview, done: {
                if textReview?.state == "complete" { textReview = nil; textStatus = "Synced to Apple."; afterApple() }
            }, busyChanged: { publishingText = $0 }, actionsBusy: listing.busy || listing.workflow.shown.dirty || listing.workflow.shown.blocked, syncConfirmation: true)
                .id("quick-text-save")
        }
    }

    @ViewBuilder private func fields(_ language: LanguageDraftEditor, keys: [String]) -> some View {
        if let editor = language.editor {
            let problems = snapshot?.steps.first { $0.id == "local:" + language.locale }.map(QuickRelease.fieldIssues) ?? []
            ForEach(keys.compactMap { key in editor.fields.first { $0.key == key } }) { field in
                let value = editor.value(field), used = TextDrafts.used(field.key, value), limit = TextDrafts.limits[field.key] ?? 0
                let problem = field.key == "whatsNew" ? QuickRelease.releaseNotesIssue(value, required: notesRequired)
                    : problems.first { $0.field == field.key }?.message ?? (used > limit ? "Over Apple's limit of \(limit)\(field.key == "keywords" ? " bytes" : " characters")." : nil)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(field.label).font(.sbCaption.weight(.semibold)).foregroundStyle(problem == nil ? StorebenchTheme.muted : StorebenchTheme.color("color-danger"))
                        Spacer()
                        Text("\(used) / \(limit)\(field.key == "keywords" ? " bytes" : "")").font(.sbCaption.monospacedDigit()).foregroundStyle(used > limit ? StorebenchTheme.color("color-danger") : StorebenchTheme.muted)
                    }
                    LanguageTextControl(field: field.key, label: field.label, text: Binding(get: { language.editor?.value(field) ?? "" }, set: { change(language, field, $0) }),
                                        focusRequest: fieldFocus?.anchor == ReleaseReadiness.fieldAnchor(language.locale, field.key) ? fieldFocus?.ticket : nil)
                        .storebenchControlID("quick.field." + language.locale + "." + field.key)
                        .overlay(StorebenchControlOutline(border: problem == nil ? .clear : StorebenchTheme.color("color-danger-border")).allowsHitTesting(false))
                    StorebenchTextSlot(text: problem ?? "", height: 40, font: .sbCallout, color: StorebenchTheme.color("color-danger"), live: true)
                    if field.key == "keywords" { keywordCheck(language, field, value: value, title: editor.searchTitle) }
                }
                .storebenchWorking(language.busy || listing?.busy == true)
                .id(ReleaseReadiness.fieldAnchor(language.locale, field.key))
            }
        } else {
            StorebenchLoadingStatus(message: language.needsComparison ? "This language changed elsewhere. Open Other Listing Text below to compare the latest save." : "Reading saved language text…", surface: false)
        }
    }

    @ViewBuilder private func keywordCheck(_ language: LanguageDraftEditor, _ field: LanguageEditorState.Field, value: String, title: (name: String, subtitle: String)) -> some View {
        let lint = SearchLint(value, name: title.name, subtitle: title.subtitle, locale: language.locale)
        if !lint.findings.isEmpty || !lint.nameAndSubtitle.isEmpty {
            Text(SearchLintPresentation.lines(lint).joined(separator: " ")).font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
        }
        if lint.freedBytes > 0 {
            StorebenchActionGroup(alignment: .leading) {
                Button("Clean Up Keywords") { change(language, field, lint.cleaned) }
                    .help("Remove repeated words and words already in the name or subtitle. Frees \(lint.freedBytes) bytes and keeps your order.")
            }
        }
    }

    @ViewBuilder private func build(_ plan: ReleasePlan) -> some View {
        if snapshot.map({ QuickRelease.stage($0) == .create || QuickRelease.stage($0) == .prepare }) ?? true {
            ReleaseBuildStep(account: account, app: app, session: session, plan: plan, versionId: snapshot?.targetVersionId, selectedBuildId: $buildId,
                             focus: nil, addRequests: 0, goToSend: {}, done: afterApple,
                             createFirst: "Open Prepare Release in step 1 and approve creating version \(plan.targetVersion) in App Store Connect. Then return to Add Build in step 3.")
        }
    }

    /// Add for Review waits until Apple has the text and the build and nothing else is needed, since Apple refuses an incomplete version.
    @ViewBuilder private func submit(_ plan: ReleasePlan) -> some View {
        if let snapshot, QuickRelease.stage(snapshot) == .prepare, let version = snapshot.targetVersionId {
            let waiting = snapshot.steps.filter { QuickRelease.textNeedsAction($0) || ["build", "export-compliance"].contains($0.id) && $0.state != .ready }
            let blockers = QuickRelease.blockers(snapshot.steps)
            if waiting.isEmpty && blockers.isEmpty {
                PublishActionPanel(account: account, app: app, session: session, actions: [.submit], initialRequest: PublishRequest(accountId: account.id, appId: app.id, scope: .submit, versionId: version, buildId: buildId),
                                   guided: ("Add for Review", "Review the complete version, then approve sending it to App Review."), prepareTitle: "Add for Review", syncTitle: "Add for Review", showsDestinationChoices: false, fix: { fix(check: $0) }, done: { _ in afterApple() })
                    .id("quick-submit-\(buildId ?? "")")
            } else {
                // The command stays in its place, dimmed with what is still missing, so it is clear where Add for Review comes.
                Card(title: "Add for Review", subtitle: "Apple adds a version for review once its text, build and everything before are complete.") {
                    Text(Self.waitingFor(waiting: waiting, blockers: blockers.count)).font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
                    ForEach(Self.reasons(waiting), id: \.self) { StorebenchFact(label: "Needed", value: $0) }
                    StorebenchFormFooter {
                        StorebenchCommand(title: "Add for Review", busy: false, unavailable: ([Self.waitingFor(waiting: waiting, blockers: blockers.count)] + Self.reasons(waiting)).joined(separator: "\n")) {}
                    }
                }
            }
        }
    }

    /// What Add for Review still waits for, in the order of this page.
    static func waitingFor(waiting: [ReleaseReadiness.Step], blockers: Int) -> String {
        var parts: [String] = []
        if waiting.contains(where: { $0.id.hasPrefix("apple-text:") || $0.id.hasPrefix("apple-info:") }) { parts.append("the text saved to App Store Connect") }
        if waiting.contains(where: { $0.id == "build" || $0.id == "export-compliance" }) { parts.append("a build added to the version") }
        if blockers > 0 { parts.append(blockers == 1 ? "the 1 item listed under Release Requirements" : "the \(blockers) items listed under Release Requirements") }
        return "Waiting for " + ListFormatter.localizedString(byJoining: parts) + "."
    }

    private var freshness: String {
        guard let readiness else { return ReleaseStatusSync.label(checked: nil, busy: confirmedPlan != nil, failed: false, automatic: false, settling: false) }
        return ReleaseStatusSync.label(checked: readiness.checkedAt?.formatted(date: .omitted, time: .standard), busy: readiness.busy || readiness.filling, failed: readiness.readFailed,
                                       automatic: readiness.nextCheck != nil, settling: readiness.sinceWrite.map { $0 < .seconds(180) } == true && readiness.nextCheck != nil)
    }

    // MARK: Editing

    private func fix(check id: String) {
        if id == "version" || id == "plan" { versionExpanded = true; reveal("version"); return }
        if let step = snapshot?.steps.first(where: { $0.id == id }) { fix(step); return }
        reveal(QuickRelease.step(for: id))
    }
    private func fix(_ step: ReleaseReadiness.Step, _ issue: ReleaseMaterial.Issue? = nil) {
        if step.id.hasPrefix("local:") || step.id.hasPrefix("apple-text:") || step.id.hasPrefix("apple-info:") {
            locale = String(step.id.split(separator: ":", maxSplits: 1).last ?? "")
            if let issue, issue.field == "screenshots" { show(.media); return }
            if issue?.field != "whatsNew" { otherTextOpened = true; otherTextExpanded = true }
            if let issue, let locale { fieldFocus = .init(anchor: ReleaseReadiness.fieldAnchor(locale, issue.field)) }
            reveal("text"); return
        }
        if step.id.hasPrefix("media:") { locale = String(step.id.dropFirst(6)); show(.media); return }
        if let detail = QuickReleaseDetail(check: step.id) { show(detail) }
        else { reveal(QuickRelease.step(for: step.id)) }
    }
    private func show(_ detail: QuickReleaseDetail) {
        details.insert(detail)
        Task { @MainActor in await Task.yield(); pageScroll?("quick-detail-" + detail.rawValue, .top) }
    }
    private func openHere(_ section: AppNavigation.Section) {
        switch section {
        case .release: versionExpanded = true; reveal("version")
        case .localizations, .keywords: otherTextOpened = true; otherTextExpanded = true; reveal("text")
        case .media, .assetLibrary: show(.media)
        case .reviewInfo: show(.reviewInformation)
        case .information: show(.information)
        case .accessibility: show(.accessibility)
        case .appPrivacy: show(.privacy)
        case .pricingAvailability: show(.availability)
        case .builds: reveal("build")
        default: reveal("submit")
        }
    }

    private func selectedLocale(_ languages: [VersionListingEditor.Language]) -> String? {
        languages.first { $0.locale == locale }?.locale ?? languages.first?.locale
    }
    private func change(_ language: LanguageDraftEditor, _ field: LanguageEditorState.Field, _ value: String) {
        do { try language.change(field, to: value); textStatus = "" }
        catch { textStatus = "Keep each local text field within 10,000 UTF-16 characters. Your previous text is retained." }
    }
    private func save(_ listing: VersionListingEditor, sync: Bool = false) {
        guard listing.active, !listing.busy, !listing.workflow.blocked, !publishingText else { return }
        textReview = nil
        operation = Task {
            var prepared: LanguageListingReview?, failure: String?
            let prepare: (@MainActor () async throws -> Void)?
            if sync {
                prepare = {
                    guard let session, let plan = model?.plan else { throw PublishFailure.conflict }
                    do {
                        let request = QuickRelease.textRequest(accountId: account.id, appId: app.id, plan: plan, includingOtherText: otherTextOpened)
                        prepared = try await session.prepareLanguageListingReview(account: account, request: request, client: try await session.client(for: account))
                    } catch {
                        failure = (error as? PublishFailure)?.message
                        if error as? PublishFailure == .versionRequired { versionExpanded = true; requestedVersionPlan = model?.plan?.token; createRequests += 1; reveal("version") }
                        throw error
                    }
                }
            } else { prepare = nil }
            let result = await listing.run(prepare: prepare)
            guard listing.active, !Task.isCancelled, listing.workflow.owns(result) else { return }
            textStatus = failure ?? (result.complete ? "Saved on this Mac. Sync to Apple prepares a review for your approval." : listing.unsavedItem ?? "The text could not be saved. Your edits are kept.")
            if result.reviewReady, listing.workflow.ready { textReview = prepared?.review }
        }
    }
    /// A Save to App Store Connect clears the shared reads; the status is read again, then what the later steps show, so they open at once.
    private func afterApple() {
        requestedVersionPlan = nil
        changed()
        readiness?.noteAppleWrite()
        operation = Task {
            await refreshStatus(full: true)
            guard !Task.isCancelled, let session else { return }
            await session.warmReleaseSteps(after: "send", account: account, appId: app.id, versionId: snapshot?.targetVersionId, plan: snapshot?.plan)
        }
    }
    private func recheck() {
        guard confirmedPlan != nil else { return }
        operation = Task { await refreshStatus() }
    }

    // MARK: Loading

    private func load() async {
        guard model == nil, !loading, !Task.isCancelled else { return }
        if let providedModel {
            history = providedHistory; model = providedModel; await providedModel.load(); return
        }
        guard let session else { return }
        loading = true; loadStatus = ""; defer { loading = false }
        protection?.policy.update(id: protectionId, dirty: false, busy: true)
        do {
            // The starting versions read earlier, here, in Release or ahead in the background, open at once and are read again right after.
            let remembered = await presentation?.rememberedDecodedRead(historyKey, as: [Revision].self)
            try Task.checkCancellation()
            let savedPlan = try await session.releasePlan(accountId: account.id, appId: app.id)
            let savedHistory: [Revision]
            if let remembered { savedHistory = remembered }
            else { savedHistory = try await session.releaseStartingHistory(account: account, appId: app.id); presentation?.rememberRead(savedHistory, historyKey) }
            try Task.checkCancellation()
            history = savedHistory
            // Start from what is saved: the plan itself, else the version still being prepared at Apple, else a copy into the next number.
            let suggestionDate = Date().addingTimeInterval(7 * 86_400)
            let preference = savedPlan == nil ? try? await session.releasePreference(accountId: account.id, appId: app.id) : nil
            let initial = savedPlan.map { ReleasePlanInputs($0, fallbackDate: suggestionDate) } ?? ReleasePreference.applying(preference, to: ReleaseSetup.suggestion(savedHistory, date: suggestionDate))
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
            model = owner; await owner.load()
            guard owner.active, !Task.isCancelled else { return }
            // A new plan starts from current Apple material: the remembered versions are replaced by a fresh read, which may import first,
            // and an unedited suggestion follows it.
            if remembered != nil, let latest = try? await session.releaseStartingHistory(account: account, appId: app.id) {
                guard owner.active, !Task.isCancelled else { return }
                history = latest; presentation?.rememberRead(latest, historyKey)
                if savedPlan == nil { owner.suggest(ReleasePreference.applying(preference, to: ReleaseSetup.suggestion(latest, date: suggestionDate))) }
            }
            // A version App Store Connect is already preparing needs no Create: the plan to continue it is saved on this Mac right away.
            if savedPlan == nil, owner.plan == nil, owner.baseline.start == .reuse, owner.ready, await owner.save(), owner.active, !Task.isCancelled { changed() }
            availability = await session.newVersionAvailability(accountId: account.id, appId: app.id)
        } catch {
            protection?.remove(id: protectionId)
            if !Task.isCancelled { loadStatus = (error as? ImportFailure)?.message ?? "Saved starting versions could not be read." }
        }
    }

    /// The same listing owner as Release: every language's text, kept while the page is open and saved together.
    private func prepareListing() async {
        guard let model, let plan = model.plan, confirmedPlan != nil, let session, !Task.isCancelled else { return }
        if let listing, listing.scope.revisionId != plan.sourceRevisionId || listing.versionId != plan.baseVersionId {
            listing.retire(); self.listing = nil; protection?.remove(id: listingProtectionId)
        }
        // Quick Release edits text only, so no screenshot or preview editors are created or read.
        guard listing == nil, let owner = try? VersionListingEditor(planEditor: model, session: session, media: false) else { return }
        let ownerId = listingProtectionId
        owner.didChange = { [weak owner, weak editingProtection = protection] in
            guard let owner, owner.active else { editingProtection?.remove(id: ownerId); return }
            editingProtection?.policy.update(id: ownerId, dirty: owner.dirty, busy: owner.busy)
        }
        protection?.registerSave(id: ownerId, priority: -5, generation: String(describing: ObjectIdentifier(owner)), problem: { [weak owner] in
            owner?.unsavedItem ?? (owner?.status.isEmpty == false ? owner?.status : nil)
        }) { [weak owner] in
            guard let owner, owner.active, !owner.busy else { return false }
            let result = await owner.run()
            return result.complete && owner.active && !owner.dirty
        }
        listing = owner
        await owner.load()
        if owner.active, !Task.isCancelled { notesRequired = !((try? await session.isFirstVersion(accountId: account.id, appId: app.id, platform: plan.platform, number: plan.targetVersion)) ?? false) }
    }

    /// `full` reads everything again, as after an approved Apple change; otherwise an unchanged saved status costs one version-state read.
    private func refreshStatus(fresh: Bool = false, full: Bool = false) async {
        await ScreenReads.reading(fresh: fresh) {
            guard let model, let session, confirmedPlan != nil, !Task.isCancelled else { return }
            if readiness == nil {
                // The status remembered from an earlier visit, here or in Release, shows at once and is read again right away.
                var seed: (snapshot: ReleaseReadinessSnapshot, checkedAt: Date)?
                if let plan = model.plan { seed = await session.rememberedReleaseReadiness(accountId: account.id, appId: app.id, planToken: plan.token) }
                guard readiness == nil, !Task.isCancelled else { return }
                readiness = ReleaseReadinessEditor(planEditor: model, account: account, session: session, seed: seed)
            }
            readiness?.focus = .all
            // A save can invalidate an older background read. Let that owner finish before checking the new material.
            while readiness?.busy == true {
                do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
                guard !Task.isCancelled, readiness?.active == true else { return }
            }
            _ = fresh || full ? await readiness?.refresh() : await readiness?.revalidate()
        }
    }
    /// Checks App Store Connect again when the schedule says so, as Release does.
    private func syncStatus() async {
        guard confirmedPlan != nil, let delay = readiness?.nextCheck else { return }
        do { try await Task.sleep(for: delay) } catch { return }
        guard !Task.isCancelled, let readiness, readiness.active else { return }
        await readiness.sync()
    }
}


extension QuickRelease.Status {
    var tone: StorebenchStatusTone { self == .ready ? .success : self == .missing ? .problem : .caution }
}
