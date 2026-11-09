import StorebenchCore
import SwiftUI

struct LibraryView: View {
    let accounts: [Account]
    let model: LibraryModel
    init(accounts: [Account], model: LibraryModel, initialLocation: LibraryLocation = LibraryLocation()) {
        self.accounts = accounts; self.model = model
        _selection = State(initialValue: initialLocation.selection)
        _appSection = State(initialValue: initialLocation.section)
        _editorContext = State(initialValue: initialLocation.context)
        _portfolioRange = State(initialValue: initialLocation.salesRange)
        _analyticsKind = State(initialValue: initialLocation.analyticsKind)
        _connecting = State(initialValue: initialLocation.connecting)
        _releaseStep = State(initialValue: initialLocation.releaseStep)
        _navigationHistory = State(initialValue: NavigationHistory(initialLocation))
    }
    @State private var selection: String? = LibraryOverview.Section.overview.selection
    @State private var connecting = false
    @State private var portfolioRange: SalesPresentation.Range?
    @State private var appSection: AppOverview.Section = .overview
    @State private var editorContext: AppNavigation.Context?
    @State private var analyticsKind: String?
    @State private var releaseStep: String?
    @State private var appRecovery: RecoveryIntent?
    @State private var libraryMessage = ""
    @State private var openingApp = false
    @State private var openingTask: Task<Void, Never>?
    @State private var navigationIntent = NavigationIntent()
    @State private var startingAppSync = false
    @State private var startingAllSync = false
    @State private var navigationHistory = NavigationHistory(LibraryLocation())
    @State private var navigationPresentation = NavigationPresentation()
    /// Reviews on the open page waiting for Send to Apple, named in the bar at the bottom of the window.
    @State private var readyReviews = ReadyReviews()
    /// The reads saved by an earlier launch are handed to the window before the first screen opens, so it shows them at once.
    @State private var savedReadsSession: ObjectIdentifier?
    @Environment(\.editorProtection) private var protection
    @Environment(\.openSettings) private var openSettings
    @Environment(\.recoveryNavigation) private var recoveryNavigation
    private var session: WorkspaceSession? { model.session }

    private var selected: (Account, Account.App)? {
        for account in accounts { if let app = account.apps.first(where: { "\(account.id)/\($0.id)" == selection }) { return (account, app) } }
        return nil
    }

    var body: some View {
        let target = selection, scope = selected, expectedSession = session, currentSection = appSection
        return GeometryReader { geometry in
            HStack(spacing: 0) {
                StorebenchSidebar(selection: selection, section: appSection, hasApp: selected != nil,
                    selectLibrary: selectApp, selectSection: selectSection,
                    settings: { openSettings() },
                    help: { if let action = try? RecoveryGuidance.Target.help("apple-setup").resolved(scope: nil) { recoveryNavigation.navigate?(action) } })
                VStack(spacing: 0) {
                    StorebenchTopbar(breadcrumb: breadcrumb, appName: selected?.1.name, canGoBack: navigationHistory.canGoBack, canGoForward: navigationHistory.canGoForward,
                        back: { navigateHistory(.back) }, forward: { navigateHistory(.forward) }, overview: { selectApp(LibraryOverview.Section.overview.selection) }, signOut: model.lockMode == .password ? {
                        Task { if await EditorWindows.requestClosing(reason: .signOut) { await model.signOut() } }
                    } : nil)
                    Group { if savedReadsSession == session.map(ObjectIdentifier.init) { libraryContent } else { Color.clear } }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        .environment(\.navigationPresentation, NavigationPresentationContext(store: navigationPresentation, entry: navigationHistory.currentID))
                        .environment(\.releaseStepHistory, Binding(get: { releaseStep }, set: { releaseStep = $0 }))
                        .environment(\.collectionPersistence, CollectionPersistenceContext(store: session, view: location.identity))
                        .environment(\.readyReviews, readyReviews)
                        .safeAreaInset(edge: .bottom, spacing: 0) { ReadyReviewBar(reviews: readyReviews) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).layoutPriority(1)
            }.environment(\.workspaceWidth, geometry.size.width)
        }.background(StorebenchTheme.page)
        .trackUnsavedChanges(false, busy: openingApp, id: "library-navigation")
        .onChange(of: model.cachePolicy, initial: true) { navigationPresentation.readCapacity = model.cachePolicy.budget().windowReads }
        .task(id: session.map(ObjectIdentifier.init)) {
            guard let session else { savedReadsSession = nil; return }
            model.registerWindowReads(navigationPresentation)
            navigationPresentation.persist = { [weak session] key, data, date, epoch in Task { await session?.saveViewRead(key: key, data: data, readAt: date, epoch: epoch) } }
            navigationPresentation.restore = { [weak session] key, epoch in await session?.savedViewRead(key: key, epoch: epoch) }
            let clears = navigationPresentation.clearCount, epoch = await session.viewReadEpoch
            // The open app's saved reads come first, so its page shows at once; every other saved read follows in the background.
            if let app = selected?.1.id { navigationPresentation.preload(await session.savedViewReads(containing: "/" + app), epoch: epoch, clearCount: clears) }
            savedReadsSession = ObjectIdentifier(session)
            navigationPresentation.preload(await session.savedViewReads(), epoch: epoch, clearCount: clears)
        }
        // Each opened app is counted, then the apps worth preparing are read ahead, the open one first.
        .task(id: "\(String(describing: savedReadsSession))/\(selection ?? "")", priority: .utility) { await prepareApps() }
        .onChange(of: appSection) { _, section in
            guard section == .release || section == .quickRelease, let session, let (account, app) = selected else { return }
            Task { try? await session.recordAppOpened(accountId: account.id, appId: app.id, release: true, counts: false) }
        }
        .onDisappear { cancelOpening() }
        .onChange(of: location) { old, new in
            navigationPresentation.capture?()
            // The step Release opens on by itself belongs to the entry that opened it; each step chosen after that is its own entry.
            if old.releaseStep == nil, new.releaseStep != nil, old.sameView(new) { navigationHistory.replace(new) } else { navigationHistory.visit(new) }
            navigationPresentation.retain(navigationHistory.entryIDs)
        }
        .shortcutNavigation(shortcutDestinations, identity: (selection ?? "") + "/" + appSection.key) { command in
            guard selection == target, appSection == currentSection else { return }
            shortcutNavigate(command)
        }
        .shortcutAction(.syncApp, enabled: scope != nil && !startingAppSync, priority: 0, identity: target ?? "") {
            await shortcutSync(all: false, target: target, app: scope, expectedSession: expectedSession)
        }
        .shortcutAction(.syncAll, enabled: expectedSession != nil && !startingAllSync, priority: 0, identity: target ?? "") {
            await shortcutSync(all: true, target: target, app: scope, expectedSession: expectedSession)
        }
        .shortcutAction(.back, enabled: navigationHistory.canGoBack, priority: 0, identity: location.identity) { navigateHistory(.back) }
        .shortcutAction(.forward, enabled: navigationHistory.canGoForward, priority: 0, identity: location.identity) { navigateHistory(.forward) }
    }

    private var shortcutDestinations: [ShortcutCommand] {
        [.overview, .apps, .help, .nextSection, .previousSection] + ShortcutCommand.allCases.filter { command in
            guard let section = command.section else { return false }
            return selected != nil || LibraryChooser.sections.contains(section) || section == .sales || section == .history
        }
    }
    private func shortcutNavigate(_ command: ShortcutCommand) {
        switch command {
        case .overview: selectApp(LibraryOverview.Section.overview.selection)
        case .apps: selectApp("library:apps")
        case .help:
            if let action = try? RecoveryGuidance.Target.help("apple-setup").resolved(scope: nil) { recoveryNavigation.navigate?(action) }
        case .nextSection, .previousSection:
            let direction = command == .nextSection ? 1 : -1
            if selected != nil {
                if let next = KeyboardNavigation.adjacent(AppNavigation.Section.allCases.filter { $0.group == appSection.group }, current: appSection, direction: direction) { selectSection(next) }
            } else {
                let candidates = shortcutDestinations.filter { $0 == .overview || $0 == .apps || $0.section != nil }
                let current = candidates.first { librarySelection($0) == selection }
                if let next = KeyboardNavigation.adjacent(candidates, current: current, direction: direction) { shortcutNavigate(next) }
            }
        default:
            guard let section = command.section else { return }
            if selected != nil { selectSection(section) } else { selectApp(librarySelection(command)) }
        }
    }
    private func librarySelection(_ command: ShortcutCommand) -> String? {
        if command == .overview { return LibraryOverview.Section.overview.selection }
        if command == .apps { return "library:apps" }
        guard let section = command.section else { return nil }
        if section == .sales { return "library:sales" }
        if section == .history { return LibraryOverview.Section.history.selection }
        return LibraryChooser.selection(section)
    }
    private func shortcutSync(all: Bool, target: String?, app: (Account, Account.App)?, expectedSession: WorkspaceSession?) async {
        guard let session = expectedSession, model.session === session, selection == target else { return }
        if all { guard !startingAllSync else { return }; startingAllSync = true }
        else { guard !startingAppSync, app != nil else { return }; startingAppSync = true }
        defer { if all { startingAllSync = false } else { startingAppSync = false } }
        do {
            if all { _ = try await session.startAllSync() }
            else if let (account, app) = app { _ = try await session.startSync(account: account, appId: app.id, mode: .all) }
            if model.session === session, selection == target { libraryMessage = "Sync started or reused. Open the app's Overview for source progress." }
        } catch { if model.session === session, selection == target { libraryMessage = "Sync could not start. Refresh its status and try again." } }
    }

    private var breadcrumb: String {
        if connecting { return "Connect Apple Account" }
        if let (_, app) = selected { return appSection == .overview ? app.name : appSection.title }
        if let section = LibraryChooser.selected(selection) { return section.rawValue }
        if selection == "library:apps" { return "Apps" }
        if selection == "library:sales" { return "Sales and Trends" }
        if selection == LibraryOverview.Section.history.selection { return "History" }
        return "Overview"
    }

    private var location: LibraryLocation {
        LibraryLocation(selection: selection, section: appSection, context: editorContext, salesRange: portfolioRange, analyticsKind: analyticsKind, connecting: connecting,
                        releaseStep: appSection == .release ? releaseStep : nil)
    }
    private func navigateHistory(_ direction: NavigationHistory<LibraryLocation>.Direction) {
        cancelOpening(); navigationHistory.visit(location)
        guard let request = navigationHistory.request(direction), let session else { return }
        let destination = request.destination
        let configured = accounts.flatMap { account in account.apps.map { (account, $0) } }.first { "\($0.0.id)/\($0.1.id)" == destination.selection }
        let isLibrary = destination.selection?.hasPrefix("library:") == true
        guard isLibrary || configured != nil else { libraryMessage = "This app is no longer available. Refresh Apps before opening it."; return }
        let ticket = navigationIntent.begin()
        leave {
            guard model.session === session, navigationIntent.owns(ticket) else { return }
            let starting = protection?.policy.excluding(id: "library-navigation") ?? EditorProtectionPolicy()
            openingApp = true
            openingTask = Task {
                defer { if navigationIntent.owns(ticket) { openingApp = false; openingTask = nil } }
                do {
                    if let (account, app) = configured {
                        let row = try ConnectedApps.Row(account: account, app: app, savedName: nil, revisionCount: nil, latestImportedAt: nil)
                        try await session.validateConnectedApp(row)
                    }
                    try Task.checkCancellation(); try session.validateAccess()
                    guard model.session === session, navigationIntent.owns(ticket),
                          starting.allowsNavigation(after: protection?.policy.excluding(id: "library-navigation") ?? .init(), discardConfirmed: true),
                          commitHistory(request) else { return }
                    selection = destination.selection; appSection = destination.section; editorContext = destination.context
                    portfolioRange = destination.salesRange; analyticsKind = destination.analyticsKind; appRecovery = nil; connecting = destination.connecting; libraryMessage = ""
                    if destination.section == .release { releaseStep = destination.releaseStep }
                } catch {
                    if navigationIntent.owns(ticket), model.session === session { libraryMessage = "This destination changed or could not be opened. Your current view is kept." }
                }
            }
        }
    }

    private func commitHistory(_ request: NavigationHistory<LibraryLocation>.Request) -> Bool {
        navigationPresentation.capture?()
        return navigationHistory.commit(request)
    }

    private func selectSection(_ value: AppNavigation.Section) {
        cancelOpening()
        guard value != appSection, let session else { return }
        leave {
            guard model.session === session, (try? session.validateAccess()) != nil else { return }
            appSection = value
        }
    }

    @ViewBuilder private var libraryContent: some View {
        let content = LibraryOverview.content(selection: selection, connecting: connecting, hasApp: selected != nil)
        if content == .connection {
            ConnectAccountView(model: model, canCancel: true) { connecting = false }
        } else if case .chooser(let section) = content {
            LibraryChooserView(model: model, section: section, navigationMessage: libraryMessage,
                openApp: { destination in startOpening(destination.row, source: nil, section: destination.section) })
        } else if content == .library(.overview) || content == .library(.history) {
            LibraryDashboardView(model: model, section: LibraryOverview.Section.selected(selection) ?? .overview, navigationMessage: libraryMessage,
                openApp: { destination in startOpening(destination.row, source: nil, section: destination.section, plan: destination.plan) },
                openSource: { row, source in startOpening(row, source: source) },
                recover: { row, action in startOpening(row, source: nil, recovery: action) },
                connect: { if protection?.allowLeaving() != false { connecting = true } }, manageApps: { selectApp("library:apps") })
        } else if content == .library(.apps) {
            ConnectedAppsView(model: model, navigationMessage: libraryMessage, openApp: { row, source in startOpening(row, source: source) },
                recover: { row, action in startOpening(row, source: nil, recovery: action) },
                connect: { if protection?.allowLeaving() != false { connecting = true } })
        } else if content == .library(.sales) {
            SalesPortfolioView(session: session) { account, app, range in
                guard protection?.allowLeaving() != false else { return }
                portfolioRange = range; selection = "\(account)/\(app)"; appSection = .sales; editorContext = nil; analyticsKind = nil
            }
        } else if let (account, app) = selected {
            AppOverview(account: account, app: app, session: session, section: Binding(get: { appSection }, set: { value in
                if selected?.0.id == account.id && selected?.1.id == app.id { appSection = value }
            }), editorContext: Binding(get: {
                editorContext?.scope.accountId == account.id && editorContext?.scope.appId == app.id ? editorContext : nil
            }, set: { value in
                guard selected?.0.id == account.id, selected?.1.id == app.id,
                      value == nil || value?.scope.accountId == account.id && value?.scope.appId == app.id else { return }
                editorContext = value
            }), initialSalesRange: portfolioRange, initialAnalyticsKind: analyticsKind, initialRecovery: appRecovery, accounts: accounts, switchApp: selectApp).id("\(account.id)/\(app.id)")
        } else {
            MessageView(title: "Choose an app", message: "Open Apps to choose from your connected Apple accounts.", action: ("Open Apps", { selectApp("library:apps") }))
        }
    }

    private func prepareApps() async {
        guard let session, savedReadsSession == ObjectIdentifier(session) else { return }
        let current = selected.map { (accountId: $0.0.id, appId: $0.1.id) }
        if let current {
            try? await session.recordAppOpened(accountId: current.accountId, appId: current.appId, release: appSection == .release || appSection == .quickRelease)
        }
        // The keys Release, Quick Release, Pricing, Start Testing and the build step read first, so they open with this material at once.
        await session.prepareApps(current: current, prepared: { [navigationPresentation] app in
            if let history = app.history { navigationPresentation.remember(history, read: "release-history/\(app.accountId)/\(app.appId)") }
            if let pricing = app.pricing { navigationPresentation.remember(pricing, read: PricingView.readKey(accountId: app.accountId, appId: app.appId)) }
            if let facts = app.testFlight { navigationPresentation.remember(facts, read: TestFlightGuideView.readKey(accountId: app.accountId, appId: app.appId)) }
            guard let builds = app.builds else { return }
            let key = "release-builds/\(app.accountId)/\(app.appId)", previous = navigationPresentation.remembered(read: key, as: RememberedBuilds.self)?.value
            navigationPresentation.remember(RememberedBuilds(builds: builds, versionId: previous?.versionId, attachedId: previous?.attachedId), read: key)
        })
    }
    private func selectApp(_ value: String?) {
        cancelOpening()
        guard value != selection else { return }
        let startingSession = model.session
        leave { if model.session === startingSession { applySelection(value) } }
    }
    private func leave(_ action: @escaping @MainActor () -> Void) {
        if let protection { protection.requestLeaving(action) } else { action() }
    }
    private func cancelOpening() {
        protection?.invalidateNavigation()
        if openingTask != nil { libraryMessage = "" }
        _ = navigationIntent.begin(); openingTask?.cancel(); openingTask = nil; openingApp = false
    }
    private func startOpening(_ row: ConnectedApps.Row, source: String?, section: AppNavigation.Section? = nil, plan: ReleasePlan? = nil, recovery: RecoveryGuidance.Action? = nil) {
        cancelOpening()
        let ticket = navigationIntent.begin()
        openingApp = true; libraryMessage = "Opening app…"
        openingTask = Task { await openConnectedApp(row, source: source, section: section, plan: plan, recovery: recovery, ticket: ticket) }
    }
    private func applySelection(_ value: String?) {
        let source = selected.flatMap { try? RecoveryGuidance.Scope(accountId: $0.0.id, appId: $0.1.id) }
        let target = accounts.flatMap { account in account.apps.map { (account, $0) } }.first { "\($0.0.id)/\($0.1.id)" == value }
        let targetScope = target.flatMap { try? RecoveryGuidance.Scope(accountId: $0.0.id, appId: $0.1.id) }
        let action = source.flatMap { source in targetScope.map { AppNavigation.Destination(source: source, scope: $0, section: appSection, context: editorContext, switchingApp: true) } }
        guard action?.allowed(current: source, decision: .ready) != false,
              action?.allowed(current: selected.flatMap { try? RecoveryGuidance.Scope(accountId: $0.0.id, appId: $0.1.id) }, decision: protection?.policy.navigationDecision ?? .ready, discardConfirmed: true) != false else { return }
        if let session { guard (try? session.validateAccess()) != nil else { return } }
        if target != nil { editorContext = action?.context }
        else { appSection = .overview; editorContext = nil }
        selection = value; portfolioRange = nil; analyticsKind = nil; appRecovery = nil; connecting = false; libraryMessage = ""; releaseStep = nil
    }
    private func openConnectedApp(_ row: ConnectedApps.Row, source: String?, section: AppNavigation.Section? = nil, plan: ReleasePlan? = nil, recovery: RecoveryGuidance.Action? = nil, ticket: UUID) async {
        guard navigationIntent.owns(ticket), let session else { return }
        // This owned read must not count as another editor's busy owner during its own departure check.
        let owner = "library-navigation"
        openingApp = true; defer { if navigationIntent.owns(ticket) { openingApp = false; openingTask = nil } }
        do {
            let scope = try RecoveryGuidance.Scope(accountId: row.account.id, appId: row.app.id)
            let destination = try recovery.map { try ConnectedApps.Destination(scope: scope, recovery: $0) } ?? ConnectedApps.Destination(scope: scope, source: source)
            let libraryDestination = try section.map { try LibraryOverview.Destination(row: row, section: $0, plan: plan) }
            try await session.validateConnectedApp(row); try Task.checkCancellation()
            if let libraryDestination { try await session.validateLibraryDestination(libraryDestination) }
            guard navigationIntent.owns(ticket), model.session === session, destination.allowed(accounts: accounts, decision: .ready),
                  accounts.contains(where: { $0.id == row.account.id && $0 == row.account }) else { throw ConnectedApps.Failure.changed }
            let starting = protection?.policy.excluding(id: owner) ?? EditorProtectionPolicy()
            guard EditorProtection.confirm(starting.navigationDecision),
                  starting.allowsNavigation(after: protection?.policy.excluding(id: owner) ?? .init(), discardConfirmed: true) else { return }
            try await session.validateConnectedApp(row); try Task.checkCancellation()
            if let libraryDestination { try await session.validateLibraryDestination(libraryDestination) }
            guard navigationIntent.owns(ticket), model.session === session, starting.allowsNavigation(after: protection?.policy.excluding(id: owner) ?? .init(), discardConfirmed: true),
                  destination.allowed(accounts: accounts, decision: .ready) else { return }
            editorContext = nil; portfolioRange = nil; analyticsKind = libraryDestination == nil ? destination.analyticsKind : nil; appSection = section ?? destination.section
            appRecovery = destination.recoveryAction.map { RecoveryIntent(action: $0) }
            selection = row.id; connecting = false; libraryMessage = ""; releaseStep = nil
        } catch is CancellationError { }
        catch { if navigationIntent.owns(ticket), model.session === session { libraryMessage = "The connected app changed or could not be read. Choose Refresh Apps before opening it." } }
    }
}

struct LibraryLocation: Equatable, Sendable {
    var selection: String? = LibraryOverview.Section.overview.selection
    var section: AppNavigation.Section = .overview
    var context: AppNavigation.Context?
    var salesRange: SalesPresentation.Range?
    var analyticsKind: String?
    var connecting = false
    var releaseStep: String?
    func sameView(_ other: LibraryLocation) -> Bool {
        var a = self, b = other; a.releaseStep = nil; b.releaseStep = nil; return a == b
    }
    var identity: String { (selection ?? "") + "/" + section.key + "/" + (context?.locale ?? "") + "/" + (context?.version ?? "") }
}
