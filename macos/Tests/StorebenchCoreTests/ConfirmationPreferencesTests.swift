import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct ConfirmationPreferencesTests {
    init() throws { _ = try TestIsolation.require() }

    @Test func everyDestructiveActionAsksUntilDontAskAgainAndSettingsTurnsItBackOn() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let initial = try await session.editingPreferences()
        #expect(DestructiveConfirmation.allCases.allSatisfy(initial.asks))
        // Don't ask again changes only its own action and keeps the autosave choice.
        _ = try await session.updateEditingPreferences { $0.autosaveDrafts = true }
        let skipped = try await session.updateEditingPreferences { $0.skippedConfirmations.insert(.removeVersion) }
        #expect(!skipped.asks(.removeVersion) && skipped.asks(.deleteRevision) && skipped.autosaveDrafts)
        // Changing autosave afterwards keeps the skipped question skipped.
        _ = try await session.updateEditingPreferences { $0.autosaveDrafts = false }
        var saved = try await session.editingPreferences()
        #expect(!saved.asks(.removeVersion) && !saved.autosaveDrafts)
        _ = try await session.updateEditingPreferences { $0.skippedConfirmations.remove(.removeVersion) }
        saved = try await session.editingPreferences()
        #expect(saved.asks(.removeVersion))
    }

    @Test func savedPreferencesReadEarlierVersionsAndRejectUnknownActions() throws {
        let earlier = try EditingPreferences(.object([("schemaVersion", .number(1)), ("autosaveDrafts", .bool(true))]))
        #expect(earlier.autosaveDrafts && earlier.skippedConfirmations.isEmpty)
        let current = EditingPreferences(autosaveDrafts: false, skippedConfirmations: [.disconnectReporter, .removeVersion])
        #expect(try EditingPreferences(current.json) == current)
        // Saved in a stable order, so the same choices always store the same document.
        #expect(current.json["skippedConfirmations"] == .array([.string("remove-version"), .string("disconnect-reporter")]))
        #expect(throws: DraftFailure.self) { try EditingPreferences(.object([("schemaVersion", .number(2)), ("autosaveDrafts", .bool(false)), ("skippedConfirmations", .array([.string("synthetic-unknown")]))])) }
        #expect(throws: DraftFailure.self) { try EditingPreferences(.object([("schemaVersion", .number(2)), ("autosaveDrafts", .bool(false))])) }
        #expect(Set(DestructiveConfirmation.allCases.map(\.title)).count == DestructiveConfirmation.allCases.count)
    }
}
