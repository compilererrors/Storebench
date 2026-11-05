import AppKit
import Observation
import StorebenchCore
import SwiftUI
import os

// UI mutations stay on the main actor; AppKit color providers receive immutable palette snapshots.
@Observable final class StorebenchAppearancePreferences: @unchecked Sendable {
    static let shared = StorebenchAppearancePreferences()
    private(set) var choice: AppearanceChoice
    private(set) var increasedContrast = false
    @ObservationIgnored private var accessibilityObserver: NSObjectProtocol?
    @ObservationIgnored private let colorState: OSAllocatedUnfairLock<(AppearanceChoice, Bool)>
    private init() {
        let value = AppearanceChoice(stored: UserDefaults.standard.string(forKey: "appearance.theme"))
        choice = value; colorState = OSAllocatedUnfairLock(initialState: (value, false))
    }
    func colorSnapshot() -> (AppearanceChoice, Bool) { colorState.withLock { $0 } }
    @MainActor func choose(_ value: AppearanceChoice) {
        choice = value; UserDefaults.standard.set(value.rawValue, forKey: "appearance.theme"); applyNativeAppearance()
    }
    @MainActor func applyNativeAppearance() {
        increasedContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        colorState.withLock { $0 = (choice, increasedContrast) }
        let increased = choice.highContrast || increasedContrast
        let name: NSAppearance.Name? = choice == .system ? nil : choice.scheme == "dark" ? increased ? .accessibilityHighContrastDarkAqua : .darkAqua : increased ? .accessibilityHighContrastAqua : .aqua
        NSApplication.shared.appearance = name.flatMap(NSAppearance.init(named:))
        if accessibilityObserver == nil {
            accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.applyNativeAppearance() }
            }
        }
    }
}

struct AppearanceSettings: View {
    private let preferences = StorebenchAppearancePreferences.shared
    var body: some View {
        StorebenchFormSection("Appearance") {
            StorebenchPicker("Theme", selection: Binding(get: { preferences.choice }, set: { preferences.choose($0) }), hint: "Applies immediately to all windows and is remembered on this Mac.") {
                selectionOptions(AppearanceChoice.allCases) { SelectionOption($0.title, value: $0) }
            }
            StorebenchTextSlot(text: preferences.choice.detail, height: 34, font: .sbCallout, color: StorebenchTheme.muted)
            Text("Every theme protects text and control contrast. Your Mac’s Increase Contrast setting adds stronger separation to any theme.")
                .font(.sbCaption).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
}
