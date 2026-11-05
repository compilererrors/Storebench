import StorebenchCore
import SwiftUI

struct AppOverview: View {
    let account: Account, app: Account.App, session: WorkspaceSession?
    @Binding var section: Section
    @Binding var editorContext: AppNavigation.Context?
    let accounts: [Account]
    let switchApp: (String?) -> Void
    @State private var continueRequests = 0
    @State private var revealTask: Task<Void, Never>?
    @State private var languageSummaries: [String: String] = [:]
    @State private var salesRequest: ReportNavigation.SalesRequest?
    let initialRecovery: RecoveryIntent?
    init(account: Account, app: Account.App, session: WorkspaceSession?, section: Binding<Section>, editorContext: Binding<AppNavigation.Context?>, initialSalesRange: SalesPresentation.Range? = nil, initialAnalyticsKind: String? = nil, initialRecovery: RecoveryIntent? = nil, accounts: [Account], switchApp: @escaping (String?) -> Void) {
        self.account = account; self.app = app; self.session = session
        _section = section; _editorContext = editorContext
        self.accounts = accounts; self.switchApp = switchApp
        _salesRequest = State(initialValue: (try? RecoveryGuidance.Scope(accountId: account.id, appId: app.id)).map { ReportNavigation.SalesRequest(scope: $0, range: initialSalesRange) })
        _syncAnalyticsKind = State(initialValue: initialAnalyticsKind == "engagement" ? "engagement" : "downloads")
        let scope = try? RecoveryGuidance.Scope(accountId: account.id, appId: app.id)
        let requested = initialRecovery.flatMap { $0.action.allowed(current: scope, decision: .ready) && $0.action.target.section == section.wrappedValue ? $0 : nil }
        self.initialRecovery = requested
        _recoveryIntent = State(initialValue: requested)
    }

    typealias Group = AppNavigation.Group
    typealias Section = AppNavigation.Section

    @State private var revisions: [Revision] = []
    @State private var plan: ReleasePlan?
    /// Set once you choose between the version draft and the imported Apple version; until then a saved plan's draft opens.
    @State private var editorChosen = false
    @State private var overviewMaterial: AppOverviewMaterial.Snapshot?
    @State private var publishingCancellation: AppOverviewVersions.Cancellation?
    @State private var languagePublishReview: PublishReview?
    @State private var readinessRequest: PublishRequest?
    @State private var readinessReviewVersion: String?
    @State private var readinessBuildId: String?
    @State private var readinessBuildAction: String?
    private struct ReadinessFocus { let id = UUID(); let anchor: String }
    @State private var readinessFocus: ReadinessFocus?
    @Environment(\.openURL) private var openURL
    @Environment(\.releaseStepHistory) private var releaseStepHistory
    private var editDraft: Bool { editorContext?.scope == recoveryScope && editorContext?.draft == true && section.usesVersion }
    @State private var workspace: Revision?
    @State private var workspaceDraft = false
    @State private var reading = false
    @State private var readIdentity = UUID()
    @State private var loaded = false
    @Environment(\.navigationPresentation) private var presentation
    /// The editors' saved material, kept so Localizations and Previews open at once and read again behind it.
    private struct EditorRead: Codable { let revisions: [Revision], plan: ReleasePlan?, workspace: Revision?, draft: Bool }
    private var editorReadKey: String { "app-editor/\(account.id)/\(app.id)" }
    @Environment(\.editorProtection) private var protection
    @Environment(\.recoveryNavigation) private var parentRecovery
    @State private var recoveryIntent: RecoveryIntent?
    @State private var focusedJournalEvent: String?
    @State private var languageLayout = LanguageLayoutEditor()
    private var recoveryScope: RecoveryGuidance.Scope? { try? RecoveryGuidance.Scope(accountId: account.id, appId: app.id) }

    private func compareSales(_ request: ReportNavigation.SalesRequest) {
        guard request.allowed(current: recoveryScope, decision: .ready), protection?.allowLeaving() != false,
              request.allowed(current: recoveryScope, decision: protection?.policy.navigationDecision ?? .ready, discardConfirmed: true),
              let session, (try? session.validateAccess()) != nil else { return }
        salesRequest = request; recoveryIntent = nil; section = .sales
    }

    private func navigateEditor(_ destination: AppNavigation.Destination) {
        guard destination.scope == recoveryScope, destination.allowed(current: recoveryScope, decision: .ready),
              protection?.allowLeaving() != false,
              destination.allowed(current: recoveryScope, decision: protection?.policy.navigationDecision ?? .ready, discardConfirmed: true),
              let session, (try? session.validateAccess()) != nil else { return }
        editorContext = destination.context; recoveryIntent = nil; section = destination.section
    }

    private func recover(_ action: RecoveryGuidance.Action) {
        guard action.target.requiresApp else { parentRecovery.navigate?(action); return }
        guard let destination = action.target.section else { return }
        guard action.allowed(current: recoveryScope, decision: .ready),
              destination == section ? protection?.policy.navigationDecision != .wait : protection?.allowLeaving() != false,
              let session, (try? session.validateAccess()) != nil else { return }
        section = destination; recoveryIntent = RecoveryIntent(action: action)
    }

    private var imported: Revision? { revisions.first { !$0.isLocalDraft } }
    private var appTitle: String {
        if section == .overview, let overviewMaterial { return overviewMaterial.name(configured: account.appNames?[app.id]) }
        return ConnectedApps.name(saved: revisions.first?.app.name, configured: account.appNames?[app.id], appId: app.id)
    }
    private var headerBundleId: String { section == .overview ? overviewMaterial?.bundleId ?? "" : imported?.app.bundleId ?? "" }
    private func openCancellation(_ destination: AppOverviewVersions.Cancellation) {
        guard destination.allowed(current: recoveryScope, decision: .ready), protection?.allowLeaving() != false,
              destination.allowed(current: recoveryScope, decision: protection?.policy.navigationDecision ?? .ready, discardConfirmed: true),
              let session, (try? session.validateAccess()) != nil else { return }
        publishingCancellation = destination; recoveryIntent = nil; editorContext = nil; section = .publish
    }
    private func openLanguageReview(_ destination: LanguageListingReview) -> Bool {
        guard destination.matches(accountId: account.id, appId: app.id, revisionId: editing?.id, versions: editing?.versions.map(\.id) ?? [], targetMode: editDraft ? "release-plan" : "apple-version"),
              protection?.allowLeaving() != false, let session, (try? session.validateAccess()) != nil else { return false }
        languagePublishReview = destination.review; publishingCancellation = nil; recoveryIntent = nil; editorContext = nil; section = .publish
        return true
    }
    /// The revision the editors work on: the latest Apple import, or the version draft when chosen.
    @State private var syncAnalyticsKind = "downloads"
    private var editing: Revision? { workspaceDraft == editDraft ? workspace : nil }

    /// Release opens at the given step, or where it continues; it works on the same version plan as Quick Release.
    private func openRelease(_ step: String?) {
        guard protection?.allowLeaving() != false else { return }
        if let step { releaseStepHistory?.wrappedValue = step }
        recoveryIntent = nil; editorContext = nil; section = .release
    }

    private func openSyncSource(_ key: String) {
        guard let scope = recoveryScope, let destination = try? ConnectedApps.Destination(scope: scope, source: key), protection?.allowLeaving() != false,
              let session, (try? session.validateAccess()) != nil else { return }
        recoveryIntent = nil; editorContext = nil
        if let kind = destination.analyticsKind { syncAnalyticsKind = kind }
        section = destination.section
    }

    private func reload() async {
        guard let session else { return }
        let identity = UUID(), requestedDraft = editDraft
        if !loaded, let saved = presentation?.rememberedRead(editorReadKey, as: EditorRead.self), saved.draft == requestedDraft {
            revisions = saved.revisions; plan = saved.plan; workspace = saved.workspace; workspaceDraft = saved.draft; loaded = true
        }
        readIdentity = identity; reading = true
        defer { if readIdentity == identity { reading = false } }
        let savedRevisions = (try? await session.revisions(accountId: account.id, appId: app.id)) ?? []
        let savedPlan = try? await session.releasePlan(accountId: account.id, appId: app.id)
        guard !Task.isCancelled, readIdentity == identity, requestedDraft == editDraft else { return }
        // The version being prepared is what you work on, so its draft opens unless you chose the Apple version or a specific version.
        if savedPlan != nil, !requestedDraft, !editorChosen, editorContext?.version == nil, section.usesVersion, let scope = recoveryScope {
            editorContext = try? AppNavigation.Context(scope: scope, locale: editorContext?.locale, draft: true)
            return
        }
        if savedPlan == nil, requestedDraft, let scope = recoveryScope {
            editorContext = try? AppNavigation.Context(scope: scope, locale: editorContext?.locale, version: editorContext?.version)
            return
        }
        let source = requestedDraft ? savedRevisions.first { $0.id == savedPlan?.sourceRevisionId } : savedRevisions.first { !$0.isLocalDraft }
        let savedWorkspace: Revision?
        if let source { savedWorkspace = try? await session.workspaceRevision(source, accountId: account.id, appId: app.id) } else { savedWorkspace = nil }
        guard !Task.isCancelled, readIdentity == identity, requestedDraft == editDraft else { return }
        revisions = savedRevisions; plan = savedPlan; workspace = savedWorkspace; workspaceDraft = requestedDraft; loaded = true
        presentation?.rememberRead(EditorRead(revisions: savedRevisions, plan: savedPlan, workspace: savedWorkspace, draft: requestedDraft), editorReadKey)
    }

    /// Scrolls to `id` and again while the page settles: a restored scroll position and editors still laying out would otherwise move it away.
    private func reveal(_ id: String, scroll: ScrollViewProxy) {
        revealTask?.cancel()
        revealTask = Task { @MainActor in
            // The first scroll animates; the later ones only correct the position after it has finished.
            for (index, wait) in [120, 650, 450, 700].enumerated() {
                try? await Task.sleep(for: .milliseconds(wait)); guard !Task.isCancelled else { return }
                presentation?.store.keepScroll?()
                if index == 0 { withAnimation(.easeInOut(duration: 0.5)) { scroll.scrollTo(id, anchor: .center) } } else { scroll.scrollTo(id, anchor: .center) }
            }
        }
    }

    var body: some View {
        ScrollViewReader { scroll in
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StorebenchPageHeader(title: section == .overview ? appTitle : section.title,
                    description: section == .overview ? "\(account.name) · Apple ID \(app.id)\(headerBundleId.isEmpty ? "" : " · \(headerBundleId)")" : section.purpose,
                    eyebrow: section == .overview ? "APP OVERVIEW" : appTitle.uppercased(), help: section.helpTopic)
                workspaceNavigation
                content(scroll)
                    .environment(\.pageScroll, { id, anchor in withAnimation(.easeInOut(duration: 0.6)) { scroll.scrollTo(id, anchor: anchor) } })
                    .environment(\.pageReveal, { id in reveal(id, scroll: scroll) })
            }
            .modifier(StorebenchPageContent())
            .id("app-workspace-top")
        }
        .onChange(of: recoveryIntent?.id, initial: true) {
            guard let intent = recoveryIntent else { return }; let target = intent.action.target
            Task { @MainActor in
                await Task.yield()
                guard recoveryIntent?.id == intent.id else { return }
                if ReportNavigation.Tools.requested(intent.action, current: recoveryScope, area: target.area) { scroll.scrollTo("report-tools-\(target.area.rawValue)", anchor: .top) }
                else if let anchor = target.anchor {
                    // The page restores its saved position and finishes loading after a section change; the card is scrolled to again
                    // until it settles, and its position is then kept for Back and Forward.
                    for wait in [0, 300, 700, 1_200] {
                        if wait > 0 { try? await Task.sleep(for: .milliseconds(wait)) }
                        guard recoveryIntent?.id == intent.id else { return }
                        presentation?.store.keepScroll?(); scroll.scrollTo(anchor, anchor: .top)
                    }
                }
            }
        }
        .onChange(of: readinessFocus?.id) {
            guard let focus = readinessFocus else { return }
            Task { @MainActor in
                await Task.yield(); guard readinessFocus?.id == focus.id else { return }; scroll.scrollTo(focus.anchor, anchor: .top)
            }
        }
        }
        .environment(\.recoveryNavigation, RecoveryNavigation(scope: recoveryScope, navigate: recover))
        .environment(\.openSection, { open($0) })
        .environment(\.openReleaseStep, { openRelease($0) })
        .environment(\.recoveryIntent, recoveryIntent)
        .onChange(of: initialRecovery?.id) { if let initialRecovery { recover(initialRecovery.action) } }
        .environment(\.editorNavigation, EditorNavigation(scope: recoveryScope, navigate: navigateEditor))
        .environment(\.languageLayout, languageLayout)
        .trackUnsavedChanges(false, busy: reading)
        .shortcutAction(.refresh, enabled: !reading && session != nil, priority: 5, identity: account.id + "/" + app.id) { await reload() }
        .onChange(of: section) { old, new in
            if old == .sales && new != .sales { salesRequest = nil }
            if old == .publish && new != .publish { publishingCancellation = nil; languagePublishReview = nil; readinessRequest = nil }
            if old == .reviewInfo && new != .reviewInfo { readinessReviewVersion = nil }
            if old == .builds && new != .builds { readinessBuildId = nil; readinessBuildAction = nil }
            if old == .information && new != .information { readinessFocus = nil }
            if let scope = recoveryScope { editorContext = editorContext?.forSection(new, scope: scope) }
        }
        .task(id: editDraft) { await reload() }
        // A plan whose version Apple has already released is closed in the background, so Continue Version never offers a finished release.
        .task(id: plan?.token) {
            guard let plan, let session, section != .release, await session.checkReleasePlan(account: account, plan: plan)?.released == true, !Task.isCancelled else { return }
            await reload()
        }
    }

    private var workspaceNavigation: some View {
        VStack(alignment: .leading, spacing: StorebenchTheme.space(4)) {
            StorebenchHeader(stackAt: 600, actionTopInset: StorebenchTheme.measure("fieldLabel") + StorebenchTheme.measure("fieldGap")) { appChooser } actions: { newVersion }
            // The version page's parts, as App Store Connect shows them on one version, switch here as well as in the sidebar.
            if Self.versionParts.contains(section) {
                StorebenchTabs(sections: Self.versionParts, selected: section) { value in
                    guard value != section else { return }
                    let change: @MainActor () -> Void = { recoveryIntent = nil; section = value }
                    if let protection { protection.requestLeaving(change) } else { change() }
                }
            }
        }
    }
    static let versionParts: [Section] = [.localizations, .media, .reviewInfo]
    private func open(_ target: Section) {
        guard target != section else { return }
        let change: @MainActor () -> Void = { recoveryIntent = nil; section = target }
        if let protection { protection.requestLeaving(change) } else { change() }
    }
    private var appChooser: some View {
        StorebenchNavigationSelect(title: "App", selected: appTitle) {
            ForEach(accounts) { account in
                ForEach(account.apps) { app in
                    Button(app.name + (accounts.count > 1 ? " · " + account.name : "")) { switchApp("\(account.id)/\(app.id)") }
                }
            }
        }.frame(maxWidth: 440).frame(maxWidth: .infinity, alignment: .leading)
    }
    private var newVersion: some View {
        Button {
            // On the Release page itself, Continue Version opens the step that needs action instead of doing nothing.
            if section == .release { continueRequests += 1 }
            else if protection?.allowLeaving() != false { recoveryIntent = nil; editorContext = nil; section = .release }
        } label: { StorebenchLabel(plan == nil ? "New Version" : "Continue Version", icon: plan == nil ? "plus" : "release", size: 16) }
            .help(plan == nil ? "Create a new version step by step" : "A new version is in progress. Continue where you left off.")
    }

    @ViewBuilder private func content(_ scroll: ScrollViewProxy) -> some View {
        switch section {
        case .overview: OverviewSection(account: account, app: app, session: session, snapshot: $overviewMaterial, changed: { Task { await reload() } }, openSource: openSyncSource, openCancellation: openCancellation)
        case .information: AppInformationView(account: account, app: app, session: session, parts: [.categories, .ageRating, .exportCompliance], checklist: true)
        case .accessibility: AppInformationView(account: account, app: app, session: session, parts: [.accessibility])
        case .appPrivacy: AppPrivacyView(account: account, app: app, session: session, checklist: true)
        case .pricingAvailability: PricingView(account: account, app: app, session: session, pages: [.appAvailability, .priceSchedule, .temporaryPrice])
        case .inAppPurchases: PricingView(account: account, app: app, session: session, pages: [.inAppPurchases, .inAppPurchasePrices])
        case .subscriptions: PricingView(account: account, app: app, session: session, pages: [.subscriptionGroup, .subscriptions, .subscriptionPrices, .introductoryOffers, .otherOffers])
        case .startTesting: TestFlightGuideView(account: account, app: app, session: session)
        case .setUpReports: ReportsGuideView(account: account, app: app, session: session)
        case .feedback: TestFlightFeedbackView(account: account, app: app, session: session)
        case .externalTesting: TestFlightGroupsView(account: account, app: app, session: session, internalOnly: false)
        case .history: HistoryView(account: account, app: app, session: session) { Task { await reload() } }
        case .journal: ChangeJournalView(account: account, app: app, session: session, initialEventId: focusedJournalEvent)
        case .transfer: TransferView(account: account, app: app, session: session)
        case .release: ReleaseWizardView(account: account, app: app, session: session, changed: { Task { await reload() } }, openCancellation: openCancellation,
            scrollTo: { id, anchor in withAnimation(.easeInOut(duration: 0.6)) { scroll.scrollTo(id, anchor: anchor) } }, continueRequests: continueRequests)
        case .quickRelease: QuickReleaseView(account: account, app: app, session: session, changed: { Task { await reload() } }, openRelease: openRelease)
        case .localizations, .media: languageContent
        case .assetLibrary: AssetLibraryView(account: account, app: app, session: session, openReview: { review in
            guard review.request.scope == .assetLibrary, review.request.accountId == account.id, review.request.appId == app.id,
                  protection?.allowLeaving() != false else { return false }
            languagePublishReview = review; publishingCancellation = nil; readinessRequest = nil; editorContext = nil; recoveryIntent = nil; section = .publish; return true
        })
        case .createMedia: CreateMediaView(account: account, app: app, session: session)
        case .keywords: KeywordsView(account: account, app: app, session: session, locale: Binding(get: { editorContext?.scope == recoveryScope ? editorContext?.locale ?? "" : "" }, set: { value in
            if let scope = recoveryScope { editorContext = try? AppNavigation.Context(scope: scope, locale: value.isEmpty ? nil : value) }
        }))
        case .pricing: PricingView(account: account, app: app, session: session)
        case .reviewInfo: ReviewInformationView(account: account, app: app, session: session, initialVersionId: readinessReviewVersion)
        case .publish: PublishView(account: account, app: app, session: session, initialRequest: readinessRequest ?? publishingCancellation?.request, initialReview: languagePublishReview)
        case .builds: TestFlightBuildsView(account: account, app: app, session: session, initialBuildId: readinessBuildId, initialAction: readinessBuildAction, didSelectInitial: { scroll.scrollTo("selected-build", anchor: .top) })
        case .groups: TestFlightGroupsView(account: account, app: app, session: session, internalOnly: true)
        case .testers: TestFlightTestersView(account: account, app: app, session: session)
        case .testInformation: TestFlightInformationView(account: account, app: app, session: session)
        case .sales: ReportsSetupNotice(account: account, app: app, session: session)
            SalesView(account: account, app: app, session: session, navigationRequest: salesRequest, openSection: { target in
            guard protection?.allowLeaving() != false else { return }
            section = target == "pricing" ? .pricing : .localizations
        }, openReports: { if let action = (try? ReportNavigation.downloads(.sales))?.resolved(scope: recoveryScope) { recover(action) } })
        case .analytics: ReportsSetupNotice(account: account, app: app, session: session)
            AnalyticsView(account: account, app: app, session: session, initialKind: syncAnalyticsKind, onPublish: { if protection?.allowLeaving() ?? true { section = .publish } }, openLocalizations: { if protection?.allowLeaving() ?? true { section = .localizations } })
        case .aso: AsoProgressView(account: account, app: app, session: session)
        case .asoDiff: AsoDiffView(account: account, app: app, session: session, openJournal: { id in
            guard protection?.allowLeaving() != false else { return }; focusedJournalEvent = id; section = .journal
        })
        case .finance: ReportsSetupNotice(account: account, app: app, session: session)
            FinanceView(account: account, app: app, session: session, compareSales: compareSales)
        case .reviews: ReviewsView(account: account, app: app, session: session, onRelease: { if protection?.allowLeaving() ?? true { section = .release } })
        }
    }

    @ViewBuilder private var languageContent: some View {
        if plan != nil { draftChooser }
        if let editing, let navigationScope = recoveryScope {
            let scope = Editing(accountId: account.id, appId: app.id, revisionId: editing.id, local: false)
            let selection = AppNavigation.selection(scope: navigationScope, versions: editing.versions, appInfos: editing.appInfos, context: editorContext, section: section, planVersionId: plan?.baseVersionId)
            editorChooser(editing, selection: selection)
            if section == .localizations {
                LanguageLayoutControls(editor: languageLayout, accountId: account.id, appId: app.id, session: session)
            }
            if let version = editing.versions.first(where: { $0.id == selection.versionId }) {
                if section == .localizations {
                    StorebenchCollection(items: selection.locales.map { StorebenchCollectionEntry(id: $0, value: $0) },
                        title: { StoreLocales.name($0.value) }, subtitle: { $0.value + " · " + (languageSummaries[scope.revisionId + "/" + version.id + "/" + $0.value] ?? "Open to read saved text") },
                        focusedID: selection.locale, empty: "No languages in this version yet. Add a language to start editing its text.", onOpen: { chooseEditor(version: version.id, locale: $0.value) }) { language in
                        LanguageEditor(account: account, revision: editing, version: version, scope: scope, locale: language.value, targetMode: editDraft ? "release-plan" : "apple-version", session: session, openReview: openLanguageReview, contained: true, onSummary: { languageSummaries[scope.revisionId + "/" + version.id + "/" + language.value] = $0 })
                    }.id("\(scope.accountId)/\(scope.appId)/\(scope.revisionId)/languages/\(version.id)/\(editDraft)")
                }
                if section == .media { mediaChosenInRelease }
                // Previews and Screenshots are chosen and ordered in one place, Release step 2; here they are shown as saved.
                VersionCard(account: account, version: version, scope: section == .media ? Editing(accountId: scope.accountId, appId: scope.appId, revisionId: scope.revisionId, local: true) : scope, mode: section == .localizations ? .text : .media, locale: selection.locale, targetMode: editDraft ? "release-plan" : "apple-version", session: session, openReview: openLanguageReview, selectLanguage: { chooseEditor(version: version.id, locale: $0) }) { Task { await reload() } }
                    .id("\(scope.accountId)/\(scope.appId)/\(scope.revisionId)/\(section.key)/\(version.id)/\(editDraft)")
            }
        } else if reading || workspaceDraft != editDraft {
            // The editor's own card with a status line while its saved material is read; no stand-in cards.
            Card(title: section.title, subtitle: section.purpose) { StorebenchLoadingStatus(message: "Reading saved editor material…", surface: false) }
        } else if loaded {
            Card(title: "No saved app material", subtitle: "Sync app material in App overview, or start a version in Release.") { EmptyView() }
        }
    }

    private var mediaChosenInRelease: some View {
        StorebenchNotice(title: "Choose screenshots in Release", description: "Add, order and save app previews and screenshots in Release step 2, Text and Screenshots. This page shows what is saved.", icon: "info") {
            Button("Open Text and Screenshots") { openRelease(ReleaseWizard.phase(containing: "local:") ?? "listing") }
                .buttonStyle(StorebenchButtonStyle(.primary)).help("Open Release step 2, Text and Screenshots")
        }
    }

    /// The imported Apple version and the version draft are edited separately; saving locally never changes Apple.
    private var draftChooser: some View {
        Card(title: editDraft ? "Editing the version draft" : "Version draft available", subtitle: editDraft ? "Changes go into \(plan?.label ?? "the draft"). The imported Apple version is unchanged." : "You are editing the imported Apple version. Open the version draft to prepare \(plan?.label ?? "the next version").") {
            StorebenchFormFooter {
                Button(editDraft ? "Edit Apple Version" : "Open Version Draft") {
                guard protection?.allowLeaving() != false, let scope = recoveryScope else { return }
                editorChosen = true
                editorContext = try? AppNavigation.Context(scope: scope, locale: editorContext?.locale, draft: !editDraft)
            }.help(editDraft ? "Edit Imported Apple Version" : "Open Version Draft").accessibilityLabel(editDraft ? "Edit Imported Apple Version" : "Open Version Draft")
            }
        }
    }

    private func chooseEditor(version: String, locale: String) {
        guard let scope = recoveryScope else { return }
        editorContext = try? AppNavigation.Context(scope: scope, locale: locale.isEmpty ? nil : locale, version: version, draft: editDraft)
    }

    private func editorChooser(_ revision: Revision, selection: AppNavigation.Selection) -> some View {
        Card(title: section == .localizations ? "Listing version" : "Version and language", subtitle: section == .localizations ? "Each language has its own card below. Expanding a language keeps your other edits available." : "Choose the saved material to edit. Language follows you into Keyword Ideas; version and draft stay in this app's text and media views.") {
            StorebenchMetricGrid(maximumColumns: 2, minimumWidth: 240) {
                StorebenchPicker("Version", selection: Binding(get: { selection.versionId }, set: { value in
                    guard value != selection.versionId, protection?.allowLeaving() != false, let scope = recoveryScope else { return }
                    let context = try? AppNavigation.Context(scope: scope, locale: editorContext?.locale, version: value, draft: editDraft)
                    let next = AppNavigation.selection(scope: scope, versions: revision.versions, appInfos: revision.appInfos, context: context, section: section, planVersionId: plan?.baseVersionId)
                    chooseEditor(version: next.versionId, locale: next.locale)
                })) {
                    selectionOptions(revision.versions.filter { !editDraft || $0.id == plan?.baseVersionId }) { SelectionOption($0.title, value: $0.id) }
                }
                if section != .localizations { StorebenchPicker("Localization", selection: Binding(get: { selection.locale }, set: { value in
                    if value != selection.locale, protection?.allowLeaving() != false { chooseEditor(version: selection.versionId, locale: value) }
                })) {
                    selectionOptions(selection.locales) { SelectionOption(StoreLocales.name($0), value: $0) }
                } }
            }.environment(\.fieldHintHeight, 0)
            if selection.locales.isEmpty { Text("No languages saved for this version.").foregroundStyle(StorebenchTheme.muted) }
        }
    }
}


extension ISO8601DateFormatter {
    static var fractional: ISO8601DateFormatter { let format = ISO8601DateFormatter(); format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return format }
}
