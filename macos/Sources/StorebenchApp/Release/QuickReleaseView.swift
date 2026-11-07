import StorebenchCore
import SwiftUI

/// The next version of a published app in five numbered steps. It edits the same version plan and local drafts as Release.
/// Save keeps edits on this Mac; each change at App Store Connect is a prepared review that you approve.
struct QuickReleaseView: View {
    let account: Account, app: Account.App, session: WorkspaceSession?, changed: () -> Void
    /// Opens Release at a step, or where it continues when nil. The plan, drafts and saved status are the same there.
    let openRelease: (String?) -> Void
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
    @State private var operation: Task<Void, Never>?
    /// Steps the person opened or closed themselves; the others follow their state.
    @State private var shown: Set<String> = []
    @State private var hidden: Set<String> = []
    /// Steps already done when the page opened start closed; a step finished here stays open, so nothing above moves.
    @State private var doneOnArrival: Set<String>?
    @Environment(\.editorProtection) private var protection
    @Environment(\.pageScroll) private var pageScroll
    @Environment(\.navigationPresentation) private var presentation
    /// Shared with Release and the background preparation.
    private var historyKey: String { "release-history/\(account.id)/\(app.id)" }
    private var identity: String { JSONText.array([.string(account.id), .string(app.id)]).stringify() }
    private var confirmedPlan: String? { model.flatMap { $0.ready && !$0.dirty ? $0.expected : nil } }
    private var snapshot: ReleaseReadinessSnapshot? { readiness?.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let model, model.loaded {
                if model.plan == nil, QuickRelease.needsFullRelease(model.inputs, history: history) { firstVersion }
                else {
                    // Every step in the order Apple needs them, worked from top to bottom: each Save and its Send to Apple stay in their step.
                    let all = steps(model)
                    Group {
                        ForEach(all) { step in
                            StorebenchGuideSection(step: step, open: isOpen(step, in: all)) { toggle(step, in: all) }.id("quick-step-\(step.id)")
                            if isOpen(step, in: all) { stepContent(step.id, model: model) }
                        }
                    }
                    .onChange(of: snapshot == nil, initial: true) { if doneOnArrival == nil, snapshot != nil { doneOnArrival = Set(all.filter(\.complete).map(\.id)) } }
                }
            } else {
                Card(title: "Quick Release", subtitle: AppNavigation.Section.quickRelease.purpose) {
                    StorebenchLoadState(state: loadStatus.isEmpty ? .loading("Reading the saved version plan…") : .failed(loadStatus, retry: { await load() })) { EmptyView() }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: identity) { await load() }
        .task(id: confirmedPlan) {
            async let warm: Void = prepareListing()
            await refreshStatus()
            await warm
        }
        // Every save of the text checks the version again, so the list of what is still needed matches what is saved.
        .onChange(of: listing?.dirty) { was, now in if was == true, now == false { recheck() } }
        .task(id: "\(confirmedPlan ?? "")/\(snapshot?.targetState ?? "")/\(readiness?.checkedAt?.timeIntervalSince1970 ?? 0)/\(readiness?.failures ?? 0)") { await syncStatus() }
        .onDisappear {
            operation?.cancel(); listing?.retire(); readiness?.retire(); model?.retire()
            protection?.remove(id: protectionId); protection?.remove(id: listingProtectionId)
        }
    }

    // MARK: Steps

    /// The current step, the first one not done, is open; done steps start closed unless finished on this visit; later steps wait closed.
    private func isOpen(_ step: StorebenchGuideStep, in all: [StorebenchGuideStep]) -> Bool {
        if hidden.contains(step.id) { return false }
        if shown.contains(step.id) || step.current { return true }
        return step.complete && doneOnArrival.map { !$0.contains(step.id) } == true
    }
    private func toggle(_ step: StorebenchGuideStep, in all: [StorebenchGuideStep]) {
        if isOpen(step, in: all) { hidden.insert(step.id); shown.remove(step.id) } else { shown.insert(step.id); hidden.remove(step.id) }
    }

    @ViewBuilder private func stepContent(_ id: String, model: ReleasePlanEditor) -> some View {
        if id == "version" {
            VersionPlanCard(model: model, history: history, availability: availability, protectionId: protectionId, didSave: { _ in
                guard let session else { return }
                availability = await session.newVersionAvailability(accountId: account.id, appId: app.id)
                if !model.dirty { changed() }
            }, quick: true)
        } else if let plan = model.plan {
            switch id {
            case "create": create(plan)
            case "text": text(plan)
            case "build": build(plan)
            default: status(plan); submit(plan)
            }
        } else {
            Card(title: "Save the Version First", subtitle: "Choose the version number and release option in step 1, then save it.") { EmptyView() }
        }
    }

    /// What Apple still reports for these checks, in its own words, such as "Subtitle · English (U.S.): differs from App Store Connect".
    private static func reasons(_ steps: [ReleaseReadiness.Step]) -> [String] {
        steps.map { $0.detail.isEmpty ? $0.label : "\($0.label): \($0.detail)" }
    }

    /// The five steps of a quick release, each done when App Store Connect has what it asks for.
    private func steps(_ model: ReleasePlanEditor) -> [StorebenchGuideStep] {
        let saved = model.plan != nil && !model.dirty, stage = snapshot.map(QuickRelease.stage)
        let submitted: Bool = { if case .submitted? = stage { return true }; return false }()
        let created = stage == .prepare || submitted
        let blocked = snapshot?.steps.filter { $0.state == .blocked } ?? []
        let textBlocked = blocked.filter { $0.id.hasPrefix("apple-text:") || $0.id.hasPrefix("apple-info:") }
        let buildBlocked = blocked.filter { $0.id == "build" || $0.id == "export-compliance" }
        let textWaiting = !textBlocked.isEmpty, buildWaiting = !buildBlocked.isEmpty
        let blockers = snapshot.map { QuickRelease.blockers($0.steps).count } ?? 0
        let known = snapshot != nil
        var submitNeeded: [String] = []
        if !created { submitNeeded.append("The version created in App Store Connect (step 2)") }
        if !known { submitNeeded.append("The status from App Store Connect, still being read") }
        submitNeeded += Self.reasons(textBlocked).map { "Step 3: " + $0 } + Self.reasons(buildBlocked).map { "Step 4: " + $0 }
        if blockers > 0 { submitNeeded.append(blockers == 1 ? "1 thing listed under Status" : "\(blockers) things listed under Status") }
        var steps = [
            StorebenchGuideStep(id: "version", number: 1, title: "Version", purpose: "The version number and how Apple releases it once approved.",
                                complete: saved, needed: saved ? [] : ["Save the version number and release option"]),
            StorebenchGuideStep(id: "create", number: 2, title: "Create in App Store Connect", purpose: "App Store Connect creates the version, with the current version's text and screenshots.",
                                complete: saved && created, needed: !saved ? ["Save the version in step 1"] : created || !known ? [] : ["Create the version, then Send to Apple"]),
            StorebenchGuideStep(id: "text", number: 3, title: "Text", purpose: "Description, Subtitle, Keywords and What's New: Save keeps them on this Mac, Save to App Store Connect sends them.",
                                complete: saved && created && known && !textWaiting, needed: created ? Self.reasons(textBlocked) : []),
            StorebenchGuideStep(id: "build", number: 4, title: "Build", purpose: "The build Apple reviews with this version, and its export compliance answer.",
                                complete: saved && created && known && !buildWaiting, needed: created ? Self.reasons(buildBlocked) : []),
            StorebenchGuideStep(id: "submit", number: 5, title: "Add for Review", purpose: "Apple adds the version for review once everything before is complete.",
                                complete: submitted, needed: submitted ? [] : submitNeeded),
        ]
        if let index = steps.firstIndex(where: { !$0.complete }) { steps[index].current = true }
        return steps
    }

    // MARK: Sections

    private var firstVersion: some View {
        Card(title: "Quick Release", subtitle: "Quick Release updates an app that already has a version in App Store Connect. A first version, or a new platform, is set up step by step in Release.") {
            StorebenchFormFooter {
                Button("Open Release") { openRelease(nil) }.buttonStyle(StorebenchButtonStyle(.primary)).help("Set up the first version step by step in Release")
            }
        }
    }

    /// What Apple has for the version, and what still blocks it that is fixed outside this page.
    @ViewBuilder private func status(_ plan: ReleasePlan) -> some View {
        let blockers = snapshot.map { QuickRelease.blockers($0.steps).filter { !QuickRelease.fixedHere($0) } } ?? []
        Card(title: "Status at App Store Connect", subtitle: "Checks this version against App Store Connect. Anything below that this page cannot change opens in Release.",
             actions: AnyView(StorebenchBusyButton(title: "Refresh Status", loadingTitle: "Checking…", busy: readiness?.busy == true) { operation = Task { await refreshStatus(fresh: true) } })) {
            if let snapshot {
                if case .submitted(let state) = QuickRelease.stage(snapshot) {
                    StorebenchNotice(title: "\(AppStoreNames.state(state)) at Apple", description: "App Store Connect has this version from its submission. Release shows what follows, such as releasing the version after approval.", icon: "info") { EmptyView() }
                } else if blockers.isEmpty {
                    StorebenchNotice(title: "Nothing else is needed", description: "Everything outside this page is ready for this version. Save the text, add the build, then Add for Review.", icon: "check") { EmptyView() }
                } else {
                    StorebenchNotice(title: blockers.count == 1 ? "1 thing still needed" : "\(blockers.count) things still needed",
                                     description: "Fix \(blockers.count == 1 ? "it" : "them") in Release. Your version and text here stay as they are.", icon: "warning") { EmptyView() }
                    ReleaseCheckList(steps: blockers.map(ReleaseWizard.presented), ready: readiness?.ready == true, open: { openRelease(ReleaseWizard.phase(containing: $0.id)) },
                                     fix: { step, _ in openRelease(ReleaseWizard.phase(containing: step.id)) })
                }
            } else {
                StorebenchLoadingStatus(message: readiness?.readFailed == true ? "The release status is not available yet. Choose Refresh Status." : "Checking this version against App Store Connect…", surface: false)
            }
            if let readiness, !readiness.status.isEmpty { StorebenchTextSlot(text: readiness.status, height: 40, font: .sbCallout, color: StorebenchTheme.muted, live: true) }
            StorebenchTextSlot(text: freshness, height: 20, font: .sbCaption, color: StorebenchTheme.muted, live: true)
            if let snapshot, case .submitted = QuickRelease.stage(snapshot) {
                StorebenchFormFooter { Button("Open Release") { openRelease(nil) }.help("Continue this version in Release") }
            }
        }
    }

    /// Apple creates the version from the current one with its release option; its text follows in its own review.
    @ViewBuilder private func create(_ plan: ReleasePlan) -> some View {
        if let snapshot, QuickRelease.stage(snapshot) == .create {
            PublishActionPanel(account: account, app: app, session: session, actions: [.release], initialRequest: PublishRequest(accountId: account.id, appId: app.id, scope: .release), automatic: true,
                               guided: ("Create the version in App Store Connect", "Creates version \(plan.targetVersion) with its release option. App Store Connect copies the current version's text and screenshots into it. Your text below follows in the next review. Nothing is sent until you approve."),
                               done: { _ in afterApple() })
                .id("quick-create-\(plan.targetVersion)")
        } else if let snapshot, QuickRelease.stage(snapshot) == .prepare {
            // A release option changed after the version exists at Apple is saved there in its own review; an unchanged one needs nothing.
            PublishActionPanel(account: account, app: app, session: session, actions: [.release], initialRequest: PublishRequest(accountId: account.id, appId: app.id, scope: .release), automatic: true,
                               guided: ("Save release option to App Store Connect", "\(plan.settings) for version \(plan.targetVersion). Nothing is sent until you approve."),
                               refreshKey: plan.token, done: { _ in afterApple() })
                .id("quick-release-option-\(plan.targetVersion)")
        } else if snapshot == nil {
            Card(title: "Create in App Store Connect", subtitle: "Checking whether App Store Connect has version \(plan.targetVersion)…") { EmptyView() }
        } else {
            Card(title: "Create in App Store Connect", subtitle: "App Store Connect has version \(plan.targetVersion). Continue with its text.") { EmptyView() }
        }
    }

    /// Description, Subtitle, Keywords and What's New for one language at a time, saved for every language together.
    @ViewBuilder private func text(_ plan: ReleasePlan) -> some View {
        Card(title: "Text for \(plan.targetVersion)", subtitle: "Description, Subtitle, Keywords and What's New in This Version. Save keeps them on this Mac; Save to App Store Connect below sends them.", help: "listing") {
            if let listing, listing.active, listing.matchesPlan, !listing.loading, listing.revision != nil {
                let languages = listing.languages
                if languages.count > 1 {
                    StorebenchPicker("Language", selection: Binding(get: { selectedLocale(languages) ?? "" }, set: { value in locale = value })) {
                        selectionOptions(languages.map(\.locale)) { SelectionOption(StoreLocales.name($0) + " (\($0))", value: $0) }
                    }.storebenchFormColumn()
                }
                if let current = languages.first(where: { $0.locale == selectedLocale(languages) }) { fields(current.text) }
                else { Text("No languages in this version yet. Add one in Release.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted) }
                let feedback = textStatus.isEmpty ? listing.status : textStatus
                if !feedback.isEmpty { StorebenchTextSlot(text: feedback, height: 40, font: .sbCallout, color: StorebenchTheme.muted, live: true) }
                if listing.dirty || listing.workflow.phase == .saving {
                    StorebenchFormFooter {
                        StorebenchBusyButton(title: "Save", loadingTitle: "Saving…", busy: listing.workflow.phase == .saving, variant: .primary) { save(listing) }
                            .help("Save the text of every language on this Mac")
                    }
                }
            } else {
                StorebenchLoadState(state: listing == nil && confirmedPlan == nil ? .loading("Save the version first.") : .loading("Reading the version's saved text…")) { EmptyView() }
            }
        }
        .id("quick-text")
        if let snapshot, QuickRelease.stage(snapshot) == .prepare, let listing {
            PublishActionPanel(account: account, app: app, session: session, actions: [.metadata], initialRequest: QuickRelease.textRequest(accountId: account.id, appId: app.id, plan: plan), automatic: true,
                               guided: ("Save to App Store Connect", "Saves Description, Subtitle, Keywords and What's New for every language. Screenshots, Promotional Text and other fields stay as they are at Apple. Nothing is sent until you approve."),
                               refreshKey: listing.dirty || listing.busy ? "editing" : "saved", fix: { openRelease(ReleaseWizard.phase(containing: $0)) }, done: { _ in afterApple() })
                .id("quick-text-save")
        }
    }

    @ViewBuilder private func fields(_ language: LanguageDraftEditor) -> some View {
        if let editor = language.editor {
            let problems = snapshot?.steps.first { $0.id == "local:" + language.locale }.map(QuickRelease.fieldIssues) ?? []
            ForEach(QuickRelease.fields.compactMap { key in editor.fields.first { $0.key == key } }) { field in
                let value = editor.value(field), used = TextDrafts.used(field.key, value), limit = TextDrafts.limits[field.key] ?? 0
                let problem = problems.first { $0.field == field.key }?.message ?? (used > limit ? "Over Apple's limit of \(limit)\(field.key == "keywords" ? " bytes" : " characters")." : nil)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(field.label).font(.sbCaption.weight(.semibold)).foregroundStyle(problem == nil ? StorebenchTheme.muted : StorebenchTheme.color("color-danger"))
                        Spacer()
                        Text("\(used) / \(limit)\(field.key == "keywords" ? " bytes" : "")").font(.sbCaption.monospacedDigit()).foregroundStyle(used > limit ? StorebenchTheme.color("color-danger") : StorebenchTheme.muted)
                    }
                    LanguageTextControl(field: field.key, label: field.label, text: Binding(get: { language.editor?.value(field) ?? "" }, set: { change(language, field, $0) }))
                        .overlay(StorebenchControlOutline(border: problem == nil ? .clear : StorebenchTheme.color("color-danger-border")).allowsHitTesting(false))
                    if let problem { Text(problem).font(.sbCallout).foregroundStyle(StorebenchTheme.color("color-danger")).fixedSize(horizontal: false, vertical: true) }
                    if field.key == "keywords" { keywordCheck(language, field, value: value, title: editor.searchTitle) }
                }
                .storebenchWorking(language.busy || listing?.busy == true)
                .id(ReleaseReadiness.fieldAnchor(language.locale, field.key))
            }
        } else {
            StorebenchLoadingStatus(message: language.needsComparison ? "This language changed elsewhere. Compare it in Release before editing here." : "Reading saved language text…", surface: false)
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
                             createFirst: "Version \(plan.targetVersion) is not in App Store Connect yet. Create it above first, then add the build here.")
        }
    }

    /// Add for Review waits until Apple has the text and the build and nothing else is needed, since Apple refuses an incomplete version.
    @ViewBuilder private func submit(_ plan: ReleasePlan) -> some View {
        if let snapshot, QuickRelease.stage(snapshot) == .prepare, let version = snapshot.targetVersionId {
            let waiting = snapshot.steps.filter { $0.state == .blocked && ($0.id.hasPrefix("apple-text:") || $0.id.hasPrefix("apple-info:") || $0.id == "build" || $0.id == "export-compliance") }
            let blockers = QuickRelease.blockers(snapshot.steps)
            if waiting.isEmpty && blockers.isEmpty {
                PublishActionPanel(account: account, app: app, session: session, actions: [.submit], initialRequest: PublishRequest(accountId: account.id, appId: app.id, scope: .submit, versionId: version, buildId: buildId),
                                   guided: ("Add for Review", PublishActionPanel.purpose(.submit)), fix: { openRelease(ReleaseWizard.phase(containing: $0)) }, done: { _ in afterApple() })
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
        if blockers > 0 { parts.append(blockers == 1 ? "the 1 thing listed under Status" : "the \(blockers) things listed under Status") }
        return "Waiting for " + ListFormatter.localizedString(byJoining: parts) + "."
    }

    private var freshness: String {
        guard let readiness else { return ReleaseStatusSync.label(checked: nil, busy: confirmedPlan != nil, failed: false, automatic: false, settling: false) }
        return ReleaseStatusSync.label(checked: readiness.checkedAt?.formatted(date: .omitted, time: .standard), busy: readiness.busy || readiness.filling, failed: readiness.readFailed,
                                       automatic: readiness.nextCheck != nil, settling: readiness.sinceWrite.map { $0 < .seconds(180) } == true && readiness.nextCheck != nil)
    }

    // MARK: Editing

    private func selectedLocale(_ languages: [VersionListingEditor.Language]) -> String? {
        languages.first { $0.locale == locale }?.locale ?? languages.first?.locale
    }
    private func change(_ language: LanguageDraftEditor, _ field: LanguageEditorState.Field, _ value: String) {
        do { try language.change(field, to: value); textStatus = "" }
        catch { textStatus = "Keep each local text field within 10,000 UTF-16 characters. Your previous text is retained." }
    }
    private func save(_ listing: VersionListingEditor) {
        guard listing.active, !listing.busy, !listing.workflow.blocked else { return }
        operation = Task {
            let result = await listing.run()
            guard listing.active, !Task.isCancelled else { return }
            textStatus = result.complete ? "Saved on this Mac. Save to App Store Connect sends it." : listing.unsavedItem ?? "The text could not be saved. Your edits are kept."
        }
    }
    /// A Save to App Store Connect clears the shared reads; the status is read again, then what the later steps show, so they open at once.
    private func afterApple() {
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
        guard model == nil, !loading, let session, !Task.isCancelled else { return }
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
