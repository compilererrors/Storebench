import Testing
@testable import StorebenchCore

@Suite struct NavigationHistoryTests {
    init() throws { _ = try TestIsolation.require() }
    @Test func historyPreservesContextBranchesAndBoundsWithoutDuplicateVisits() throws {
        var history = NavigationHistory("workspace-overview", limit: 3)
        history.visit("synthetic-app/localizations/en-US/v1"); history.visit(history.current)
        history.visit("synthetic-app/media/sv/v2")
        let back = try #require(history.request(.back))
        #expect(history.current == "synthetic-app/media/sv/v2")
        let committed = history.commit(back), repeated = history.commit(back)
        #expect(committed && !repeated)
        #expect(history.current == "synthetic-app/localizations/en-US/v1")
        #expect(history.canGoForward)
        history.visit("synthetic-other/pricing")
        #expect(!history.canGoForward && history.count == 3)
        history.visit("workspace-apps"); #expect(history.count == 3)
        let first = history.commit(try #require(history.request(.back)))
        let second = history.commit(try #require(history.request(.back)))
        #expect(first && second)
        #expect(history.current == "synthetic-app/localizations/en-US/v1" && !history.canGoBack)
    }
    @Test func cancelledAndSupersededDeparturesCannotMoveTheHistoryCursor() throws {
        var history = NavigationHistory("overview"); history.visit("apps"); history.visit("release")
        let cancelled = try #require(history.request(.back))
        #expect(history.current == "release" && history.canGoBack && !history.canGoForward)
        history.visit("pricing")
        let rejected = history.commit(cancelled)
        #expect(!rejected && history.current == "pricing")
        let accepted = try #require(history.request(.back)), wentBack = history.commit(accepted)
        let forward = try #require(history.request(.forward)), wentForward = history.commit(forward)
        #expect(wentBack && wentForward)
        #expect(history.current == "pricing")
    }
    @Test func reopenAlwaysTargetsTheWorkspaceRatherThanSettingsOrAClosingWindow() {
        #expect(WindowLifecycle.reopen([]) == .createWorkspace)
        #expect(WindowLifecycle.reopen([.init(id: 2, role: .settings, visible: true)]) == .createWorkspace)
        #expect(WindowLifecycle.reopen([.init(id: 1, role: .workspace, visible: false, closing: true), .init(id: 2, role: .auxiliary, visible: true)]) == .createWorkspace)
        #expect(WindowLifecycle.reopen([.init(id: 1, role: .workspace, visible: false, miniaturized: true), .init(id: 2, role: .settings, visible: true)]) == .present(1))
        #expect(WindowLifecycle.reopen([.init(id: 1, role: .workspace, visible: true), .init(id: 3, role: .workspace, visible: false)], lastWorkspace: 3) == .present(3))
    }
    @Test func editsMadeDuringAHistoryReadKeepTheCurrentViewAndCursor() throws {
        var history = NavigationHistory("overview"); history.visit("synthetic-app/release")
        let request = try #require(history.request(.back))
        var starting = EditorProtectionPolicy()
        starting.update(id: "library-navigation", dirty: false, busy: true)
        starting = starting.excluding(id: "library-navigation")
        var latest = starting
        latest.update(id: "synthetic-editor", dirty: true, busy: false)
        if starting.allowsNavigation(after: latest, discardConfirmed: true) { _ = history.commit(request) }
        #expect(history.current == "synthetic-app/release" && !history.canGoForward)
        latest.update(id: "synthetic-editor", dirty: false, busy: true)
        let allowed = starting.allowsNavigation(after: latest, discardConfirmed: true)
        let committed = allowed && history.commit(request)
        #expect(committed && history.current == "overview")
    }
    @Test func aStepChosenOnOpeningRefinesItsEntryAndLaterStepsGoBackOneByOne() throws {
        var history = NavigationHistory("synthetic-app/overview")
        history.visit("synthetic-app/release"); let opened = history.currentID
        history.replace("synthetic-app/release/listing")
        #expect(history.count == 2 && history.currentID == opened && history.current == "synthetic-app/release/listing")
        history.visit("synthetic-app/release/send")
        #expect(history.commit(try #require(history.request(.back))) && history.current == "synthetic-app/release/listing" && history.currentID == opened)
        let stale = try #require(history.request(.forward)); history.replace("synthetic-app/release/build")
        #expect(!history.commit(stale) && history.current == "synthetic-app/release/build")
    }
}
