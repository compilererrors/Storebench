import AppKit
import SwiftUI
import Testing
@testable import StorebenchApp
@testable import StorebenchCore

@MainActor @Suite(.serialized) struct AISetupPresentationTests {
    init() throws { _ = try TestIsolation.require() }

    @Test func introductionKeepsItsSizeWhileSavingOrShowingAnError() {
        func size(working: Bool, status: String) -> CGSize {
            NSHostingController(rootView: AISetupDialog(working: working, status: status) { _ in }).sizeThatFits(in: .init(width: 760, height: 800))
        }
        let ready = size(working: false, status: "")
        let saving = size(working: true, status: "Saving your choice…")
        let failed = size(working: false, status: "Your choice could not be saved. Try again; AI setup is always available in Settings.")
        #expect(ready.width > 0 && ready.height > 0 && ready == saving && ready == failed)
    }

    @Test func openingAISettingsUsesTheProtectedWindowAndRejectsNewerEdits() throws {
        let coordinator = RecoveryCoordinator(), protection = EditorProtection()
        coordinator.settingsProtection = protection; coordinator.selectedPane = .general
        var opens = 0
        coordinator.openAI { opens += 1 }
        let id = try #require(coordinator.aiRequest)
        #expect(opens == 1 && coordinator.authorizeAI(id, current: protection.policy))
        protection.policy.update(id: "synthetic-new-edit", dirty: true, busy: false)
        #expect(!coordinator.authorizeAI(id, current: protection.policy))
        coordinator.consumeAI(id)
        #expect(coordinator.aiRequest == nil)
    }

    @Test func openingTheAlreadySelectedAIPaneKeepsItsUnsavedInputs() throws {
        let coordinator = RecoveryCoordinator(), protection = EditorProtection()
        coordinator.settingsProtection = protection; coordinator.selectedPane = .ai
        protection.policy.update(id: "synthetic-ai-edit", dirty: true, busy: false)
        var opens = 0
        coordinator.openAI { opens += 1 }
        let id = try #require(coordinator.aiRequest)
        #expect(opens == 1 && coordinator.authorizeAI(id, current: protection.policy))
        #expect(protection.policy.dirtyIds == ["synthetic-ai-edit"])
        coordinator.consumeAI(id)
    }
}
