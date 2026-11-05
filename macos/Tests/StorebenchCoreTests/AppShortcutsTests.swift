import Foundation
import Testing
@testable import StorebenchCore

@Suite struct AppShortcutsTests {
    init() throws { _ = try TestIsolation.require() }

    @Test func defaultsAreUniqueAndCoverEveryAppSection() throws {
        let keymap = try ShortcutKeymap()
        #expect(keymap.overrides.isEmpty)
        #expect(Set(ShortcutCommand.allCases.compactMap(\.section)) == Set(AppNavigation.Section.allCases))
        for command in ShortcutCommand.allCases {
            if let binding = keymap.binding(command) { #expect(keymap.command(binding) == command) }
            #expect(!command.title.isEmpty)
        }
        #expect(keymap.binding(.settings)?.specification == "command+,")
        #expect(keymap.binding(.back)?.specification == "command+[")
        #expect(keymap.binding(.forward)?.specification == "command+]")
        #expect(SettingsNavigation.Pane.restored("shortcuts") == .shortcuts)
    }
    @Test func customBindingsDisableResetAndPersistWithoutChangingOtherCommands() throws {
        let original = try ShortcutKeymap()
        let disabled = try original.replacing(.refresh, specification: "none")
        let changed = try disabled.replacing(.save, specification: "cmd+r")
        #expect(changed.command(try ShortcutBinding(specification: "command+r")) == .save)
        #expect(changed.binding(.refresh) == nil && changed.binding(.syncApp) == original.binding(.syncApp))
        let restored = try ShortcutKeymap(serialized: changed.serialized())
        #expect(restored.overrides == changed.overrides)
        #expect(try restored.serialized() == changed.serialized())
        #expect(throws: ShortcutKeymap.Failure.self) { try changed.replacing(.refresh, specification: nil) }
        let reset = try changed.replacing(.save, specification: nil).replacing(.refresh, specification: nil)
        #expect(reset.overrides.isEmpty && reset.binding(.refresh) == original.binding(.refresh))
    }
    @Test func newHistoryDefaultsPreserveExistingCustomBindingsAndAllowMacHistoryArrows() throws {
        let existing = try ShortcutKeymap(overrides: ["refresh": "command+["])
        #expect(existing.binding(.refresh)?.key == "[" && existing.binding(.back) == nil)
        #expect(existing.overrides["back"] == "none")
        let restored = try ShortcutKeymap(serialized: existing.serialized())
        #expect(restored.binding(.refresh) == existing.binding(.refresh))
        let arrows = try restored.replacing(.back, specification: "command+option+left").replacing(.forward, specification: "command+option+right")
        #expect(arrows.command(try ShortcutBinding(specification: "command+option+left")) == .back)
        #expect(throws: ShortcutKeymap.Failure.reserved) { try arrows.replacing(.save, specification: "command+option+up") }
    }
    @Test func conflictsAndReservedCombinationsCannotReplaceTheCurrentKeymap() throws {
        let keymap = try ShortcutKeymap()
        #expect(throws: ShortcutKeymap.Failure.self) { try keymap.replacing(.save, specification: "command+r") }
        for key in ["q", "w", "m", "h", "n", "c", "x", "v", "z", "a", "f", "p", "o", ",", "left"] {
            #expect(throws: ShortcutKeymap.Failure.self) { try keymap.replacing(.save, specification: "command+" + key) }
        }
        #expect(throws: ShortcutKeymap.Failure.fixed) { try keymap.replacing(.settings, specification: "none") }
        #expect(keymap.binding(.save)?.key == "s" && keymap.binding(.settings)?.key == ",")
    }
    @Test func parsingNormalizesAliasesCaseModifierOrderAndNonEnglishLetters() throws {
        let a = try ShortcutBinding(specification: " Cmd + Shift + Å ")
        let b = try ShortcutBinding(key: "å", modifiers: [.shift, .command])
        #expect(a == b && a.specification == "shift+command+å")
        #expect(try ShortcutBinding(specification: "ALT+CTRL+F12").specification == "control+option+f12")
        for invalid in ["r", "shift+r", "command+command+r", "command+", "meta+r", "command+f21", "command+two", "command+\nq", "command+🙂"] {
            #expect(throws: ShortcutKeymap.Failure.self) { try ShortcutBinding(specification: invalid) }
        }
    }
    @Test func invalidStoredDocumentsFailClosedInsteadOfPartiallyApplyingOverrides() {
        for raw in ["{}", "{\"schemaVersion\":2,\"overrides\":{}}", "{\"schemaVersion\":1,\"overrides\":{\"unknown\":\"command+r\"}}", "{\"schemaVersion\":1,\"overrides\":{\"settings\":\"none\"}}", String(repeating: " ", count: 16_385)] {
            #expect(throws: ShortcutKeymap.Failure.self) { try ShortcutKeymap(serialized: raw) }
        }
    }
    @Test func recordingModalsDisabledActionsAndKeyRepeatsCannotDispatchWrites() {
        for command in ShortcutCommand.allCases {
            #expect(!ShortcutDispatchPolicy.allows(command, enabled: true, recording: true, modal: false, repeated: false))
            #expect(!ShortcutDispatchPolicy.allows(command, enabled: true, recording: false, modal: true, repeated: false))
            #expect(!ShortcutDispatchPolicy.allows(command, enabled: false, recording: false, modal: false, repeated: false))
            #expect(ShortcutDispatchPolicy.allows(command, enabled: true, recording: false, modal: false, repeated: false))
            #expect(ShortcutDispatchPolicy.allows(command, enabled: true, recording: false, modal: false, repeated: true) == [.nextSection, .previousSection].contains(command))
        }
    }
    @Test func keyboardFocusWrapsAndRecoversAfterTheVisibleSectionsChange() {
        let ids = ["synthetic-first", "synthetic-second", "synthetic-third"]
        #expect(KeyboardNavigation.adjacent(ids, current: ids.last, direction: 1) == ids.first)
        #expect(KeyboardNavigation.adjacent(ids, current: ids.first, direction: -1) == ids.last)
        #expect(KeyboardNavigation.adjacent(ids, current: "synthetic-retired", direction: 1) == ids.first)
        #expect(KeyboardNavigation.adjacent([String](), current: nil, direction: 1) == nil)
        #expect(KeyboardNavigation.adjacent(ids, current: nil, direction: 0) == nil)
        for pane in SettingsNavigation.Pane.allCases { #expect(KeyboardNavigation.adjacent(SettingsNavigation.Pane.allCases, current: pane, direction: 1) != nil) }
    }
    @Test func aRetiredRecorderCannotEnableCommandsWhileANewRecorderIsActive() {
        var recording = ShortcutRecording(); let old = UUID(), next = UUID()
        recording.update(active: true, owner: old)
        recording.update(active: true, owner: next)
        recording.update(active: false, owner: old)
        #expect(recording.active)
        recording.update(active: false, owner: next)
        #expect(!recording.active)
    }
}
