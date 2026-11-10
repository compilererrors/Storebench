import StorebenchCore
import SwiftUI

/// Editing the base prompt preserves the independently selected creative directions.
struct AICardPromptEditor: View {
    @Binding var customInstructions: String?
    let directions: [AICardDirection]
    @State private var editing = false
    private var text: String { customInstructions ?? AICards.defaultInstructions }
    private var binding: Binding<String> { Binding(get: { text }, set: { customInstructions = $0 }) }
    var body: some View {
        VStack(alignment: .leading, spacing: StorebenchTheme.space(2)) {
            StorebenchHeader(stackAt: 160) {
                StorebenchTextSlot(text: (customInstructions == nil ? "Default Instructions" : "Custom Instructions") + " · \(text.utf16.count)/\(AICards.customInstructionsLimit)", height: 32, font: .sbCaption, color: StorebenchTheme.muted, live: true)
            } actions: {
                HStack(spacing: StorebenchTheme.space(1)) {
                    Button { customInstructions = nil } label: { StorebenchIcon(name: "refresh", size: 16) }
                        .buttonStyle(StorebenchButtonStyle(.quiet, size: .icon))
                        .storebenchControlID("ai-cards.reset-prompt").disabled(customInstructions == nil)
                        .help("Reset Instructions to the Default").accessibilityLabel("Reset Instructions")
                    Button { editing.toggle() } label: {
                        if editing { StorebenchIcon(name: "check", size: 16) }
                        else { StorebenchIcon(name: "edit", size: 16) }
                    }.buttonStyle(StorebenchButtonStyle(.quiet, size: .icon))
                        .storebenchControlID("ai-cards.edit-prompt")
                        .help(editing ? "Finish Editing Prompt Instructions" : "Edit Prompt Instructions")
                        .accessibilityLabel(editing ? "Finish Editing Prompt Instructions" : "Edit Prompt Instructions")
                }
            }
            if editing {
                StorebenchTextArea(text: binding, height: 180).storebenchControlID("ai-cards.prompt-text")
                    .accessibilityLabel("Prompt Instructions")
            } else {
                StorebenchReadOnlyText(title: "", text: text, height: 180)
            }
            StorebenchTextSlot(text: AICards.customInstructionIssue(customInstructions) ?? "Creative directions are added automatically. Language and screenshot cropping follow this draft's selections.", height: 32, font: .sbCaption,
                               color: AICards.customInstructionIssue(customInstructions) == nil ? StorebenchTheme.muted : StorebenchTheme.color("color-danger"), live: true)
            if !directions.isEmpty {
                DisclosureGroup("Added Creative Directions · \(directions.count)") {
                    StorebenchReadOnlyText(title: "", text: directions.map(\.instruction).joined(separator: "\n\n"), height: 140)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
