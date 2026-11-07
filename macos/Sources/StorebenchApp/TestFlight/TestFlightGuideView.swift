import StorebenchCore
import SwiftUI

/// Start Testing: from an uploaded build to testers who can install it, one step at a time. Each step shows the same view as its
/// TestFlight page, so a change made here or there is the same change.
struct TestFlightGuideView: View {
    let account: Account, app: Account.App, session: WorkspaceSession?
    @State private var facts: TestFlightFlow.Facts?
    @State private var reading = false
    @State private var problem = ""
    @State private var step: String?
    @State private var warmed = false
    @Environment(\.navigationPresentation) private var history
    static func readKey(accountId: String, appId: String) -> String { "start-testing/\(accountId)/\(appId)" }
    private var readKey: String { Self.readKey(accountId: account.id, appId: app.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let facts {
                // A failed refresh is said here, above the steps it leaves as they were, in a track kept for it.
                StorebenchFeedback(text: Self.refreshStatus(problem: problem, reading: reading), height: 40, error: !problem.isEmpty)
                StorebenchStepPage(title: "Start Testing steps", steps: TestFlightFlow.steps(facts).map { .init(id: $0.id.rawValue, number: $0.number, title: $0.title, purpose: $0.purpose, complete: $0.done, current: $0.current, optional: $0.optional, needed: $0.needed) },
                                   selected: $step, actions: AnyView(refresh), guide: .startTesting) { id in
                    content(TestFlightFlow.StepId(rawValue: id) ?? .build, facts: facts)
                }
            } else {
                Card(title: "Start Testing", subtitle: AppNavigation.Section.startTesting.purpose, actions: AnyView(refresh)) {
                    StorebenchTextSlot(text: problem.isEmpty ? (session == nil ? "Connect the workspace to read TestFlight from App Store Connect." : "Reading TestFlight…") : problem, height: 36, font: .sbCallout, color: StorebenchTheme.muted, live: true)
                }
            }
        }
        .task {
            // The last check shows at once while Start Testing reads App Store Connect again.
            if facts == nil, let remembered = history?.rememberedRead(readKey, as: TestFlightFlow.Facts.self) { facts = remembered }
            guard !Task.isCancelled else { return }
            await load()
        }
        // Sending to Apple clears the shared reads, so the next step's check follows App Store Connect without reading everything again.
        .onChange(of: step) { Task { await load() } }
    }

    /// The line above steps already shown: a refresh in progress, or why the latest one failed while the last check stays.
    static func refreshStatus(problem: String, reading: Bool) -> String {
        if !problem.isEmpty { return "The latest refresh failed, so the steps show the last check. " + problem }
        return reading ? "Checking App Store Connect for changes…" : ""
    }

    private var refresh: some View {
        StorebenchReadButton("Refresh") { await load(fresh: true) }.storebenchWorking(session == nil || reading)
    }

    @ViewBuilder private func content(_ id: TestFlightFlow.StepId, facts: TestFlightFlow.Facts) -> some View {
        switch id {
        case .build: TestFlightBuildsView(account: account, app: app, session: session)
        case .compliance: TestFlightBuildsView(account: account, app: app, session: session, initialBuildId: facts.build?.id, initialAction: facts.build?.missingCompliance == true ? "set-encryption-use" : nil)
        case .information: TestFlightInformationView(account: account, app: app, session: session)
        case .group, .testers: TestFlightGroupsView(account: account, app: app, session: session, initialGroupId: facts.testingGroups.first?.id ?? facts.groups.first?.id)
        case .betaReview: TestFlightBuildsView(account: account, app: app, session: session, initialBuildId: facts.build?.id)
        }
    }

    private func load(fresh: Bool = false) async {
        guard let session, !reading else { return }
        reading = true; defer { reading = false }
        do {
            let next = try await ScreenReads.reading(fresh: fresh) { try await session.testFlightFacts(account: account, appId: app.id, fresh: false) }
            try Task.checkCancellation()
            facts = next; problem = ""
            history?.rememberRead(next, readKey)
            if !warmed {
                // The later steps' testers, notes and checks are read ahead while this step is open.
                warmed = true
                Task(priority: .utility) { [account, app] in await session.prewarmTestFlightSteps(account: account, appId: app.id, build: next.build) }
            }
        } catch is CancellationError {
        } catch { problem = ProductPricing.readProblem(error, reading: "TestFlight") }
    }
}
