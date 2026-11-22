import StorebenchCore
import SwiftUI

/// How new AI card sets in Create Media start. Remembered on this Mac; each card set can change them.
struct AICardDefaultsSettings: View {
    @State private var defaults = AICardDefaults.stored(in: .standard)
    private func binding<Value>(_ path: WritableKeyPath<AICardDefaults, Value>) -> Binding<Value> {
        Binding(get: { defaults[keyPath: path] }, set: { value in defaults[keyPath: path] = value; defaults.save(in: .standard) })
    }
    var body: some View {
        StorebenchFormSection("Screenshot Cards", icon: "screenshots", description: "How new AI card sets in Create Media start. Each card set can change these.") {
            StorebenchPicker("Start New Card Sets With", selection: binding(\.mode), hint: defaults.mode.detail) {
                selectionOptions(AICardDefaults.Mode.allCases) { SelectionOption($0.title, value: $0) }
            }.storebenchControlID("ai-cards.default-mode")
            StorebenchPicker("Card Language", selection: binding(\.language)) { selectionOptions(StoreLocales.codes) { SelectionOption(StoreLocales.name($0), value: $0) } }
            StorebenchPicker("Display Size", selection: binding(\.targetId)) { selectionOptions(MediaCards.targets) { SelectionOption($0.label, value: $0.id) } }
            StorebenchToggle("Use the App's App Store Text", isOn: binding(\.useListing))
            Text("The app's name, subtitle, description and keywords go with the screenshots, so the cards stay about this app. Translate a finished card set into other languages from Create Media or Release step 2.")
                .font(.sbCaption).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
}
