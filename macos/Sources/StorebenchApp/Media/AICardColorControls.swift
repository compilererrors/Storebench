import StorebenchCore
import SwiftUI

struct AICardColorControls: View {
    @Binding var custom: Bool
    @Binding var palette: AICardPalette
    var body: some View {
        StorebenchCardSection(title: "Card Colors") {
            StorebenchChoicePicker("Color Direction", selection: $custom, options: [(false, "AI Chooses"), (true, "Choose Colors")])
                .storebenchControlID("ai-cards.color-direction")
            if custom {
                StorebenchFormGrid {
                    StorebenchPicker("Background", selection: $palette.fill) { selectionOptions(MediaCardStyle.Fill.allCases) { SelectionOption($0.label, value: $0) } }.storebenchControlID("ai-cards.color-fill")
                    StorebenchColorField("Text Color", hex: $palette.textColor).storebenchControlID("ai-cards.color-text")
                    StorebenchColorField(palette.fill == .gradient ? "Start Color" : "Background Color", hex: $palette.color).storebenchControlID("ai-cards.color-start")
                    if palette.fill == .gradient { StorebenchColorField("End Color", hex: $palette.secondColor).storebenchControlID("ai-cards.color-end") }
                }
            }
            StorebenchTextSlot(text: custom ? "These exact colors apply to every generated card. You can adjust each card's colors afterward." : "AI chooses colors for the set. Choose Colors to set the background and text yourself.", height: 34, font: .sbCaption, color: StorebenchTheme.muted, live: true)
        }
    }
}
