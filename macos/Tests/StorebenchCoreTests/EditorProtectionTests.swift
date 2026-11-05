import Testing
@testable import StorebenchCore

@Suite struct EditorProtectionTests {
    init() throws { _ = try TestIsolation.require() }
    @Test func readingOrAcceptingADiscardDoesNotReleaseOtherEditors() {
        var policy = EditorProtectionPolicy()
        #expect(policy.decision == .ready)
        policy.update(id: "text-editor-1", dirty: true, busy: false)
        policy.update(id: "text-editor-2", dirty: true, busy: false)
        #expect(policy.decision == .confirmDiscard)
        #expect(policy.decision == .confirmDiscard)
        policy.remove(id: "text-editor-1")
        #expect(policy.decision == .confirmDiscard)
        policy.update(id: "text-editor-2", dirty: false, busy: false)
        #expect(policy.decision == .ready)
    }
    @Test func busyOwnersCannotBeDiscardedAndWindowsAreCombinedForQuit() {
        var main = EditorProtectionPolicy(), settings = EditorProtectionPolicy()
        main.update(id: "draft-save", dirty: true, busy: true)
        settings.update(id: "shared-profile", dirty: true, busy: false)
        #expect(EditorProtectionPolicy.combined([main, settings]) == .wait)
        main.remove(id: "another-save")
        #expect(main.decision == .wait)
        main.update(id: "draft-save", dirty: false, busy: false)
        #expect(main.decision == .ready && EditorProtectionPolicy.combined([main, settings]) == .confirmDiscard)
        settings.remove(id: "shared-profile")
        #expect(EditorProtectionPolicy.combined([main, settings]) == .ready)
    }
    @Test func savingOneEditorStillProtectsEveryOtherWindow() {
        var settings = EditorProtectionPolicy(), main = EditorProtectionPolicy()
        settings.update(id: "synthetic-security-editor", dirty: true, busy: false)
        #expect(settings.excluding(id: "synthetic-security-editor").decision == .ready)
        #expect(settings.decision == .confirmDiscard)
        main.update(id: "synthetic-publish", dirty: false, busy: true)
        #expect(EditorProtectionPolicy.combined([settings.excluding(id: "synthetic-security-editor"), main]) == .wait)
        main.update(id: "synthetic-publish", dirty: true, busy: false)
        #expect(EditorProtectionPolicy.combined([settings.excluding(id: "synthetic-security-editor"), main]) == .confirmDiscard)
        #expect(settings.excluding(id: "synthetic-other").decision == .confirmDiscard)
    }
    @Test func aModalDiscardCannotAuthorizeNewDirtyOrBusyOwners() {
        let ready = EditorProtectionPolicy()
        var dirty = ready; dirty.update(id: "synthetic-draft", dirty: true, busy: false)
        #expect(!ready.allowsLeaving(after: dirty, discardConfirmed: true))
        #expect(!dirty.allowsLeaving(after: dirty, discardConfirmed: false))
        #expect(dirty.allowsLeaving(after: dirty, discardConfirmed: true))
        var busy = dirty; busy.update(id: "synthetic-draft", dirty: true, busy: true)
        #expect(!dirty.allowsLeaving(after: busy, discardConfirmed: true))
        var replaced = dirty; replaced.remove(id: "synthetic-draft"); replaced.update(id: "synthetic-new-draft", dirty: true, busy: false)
        #expect(replaced.decision == dirty.decision)
        #expect(!dirty.allowsLeaving(after: replaced, discardConfirmed: true))
        var added = dirty; added.update(id: "synthetic-other-editor", dirty: true, busy: false)
        #expect(!dirty.allowsLeaving(after: added, discardConfirmed: true))
        #expect(dirty.allowsLeaving(after: ready, discardConfirmed: false))
    }
    @Test func aGlobalConfirmationCannotAuthorizeAnotherWindowOrNewSave() {
        var dirty = EditorProtectionPolicy(); dirty.update(id: "synthetic-draft", dirty: true, busy: false)
        let starting = ["synthetic-main-window": dirty]
        #expect(EditorProtectionPolicy.allowsLeaving(starting: starting, latest: starting, discardConfirmed: true))
        #expect(!EditorProtectionPolicy.allowsLeaving(starting: starting, latest: ["synthetic-settings-window": dirty], discardConfirmed: true))
        var busy = dirty; busy.update(id: "synthetic-save", dirty: false, busy: true)
        #expect(!EditorProtectionPolicy.allowsLeaving(starting: starting, latest: ["synthetic-main-window": busy], discardConfirmed: true))
        #expect(EditorProtectionPolicy.allowsLeaving(starting: starting, latest: [:], discardConfirmed: true))
    }
}
