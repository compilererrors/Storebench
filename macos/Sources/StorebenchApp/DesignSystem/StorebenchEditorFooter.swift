import StorebenchCore
import SwiftUI

/// A contextual command area shared by editors, with feedback inside the same rounded surface.
struct StorebenchEditorFooter<Actions: View>: View {
    let title, detail: String
    var hint = ""
    @ViewBuilder let actions: () -> Actions
    var body: some View {
        StorebenchHeader {
            VStack(alignment: .leading, spacing: StorebenchTheme.space(1)) {
                StorebenchTextSlot(text: title, height: StorebenchTheme.measure("fieldLabel"), font: .sbHeadline)
                StorebenchTextSlot(text: detail, height: 40, font: .sbCallout, color: StorebenchTheme.muted, live: true)
                if !hint.isEmpty { StorebenchAdaptiveText(text: hint, maximumHeight: 40, font: .sbCaption, color: StorebenchTheme.muted) }
            }
        } actions: { actions() }
        .padding(StorebenchTheme.padding)
        .background(StorebenchTheme.color("color-surface-subtle"), in: RoundedRectangle(cornerRadius: StorebenchTheme.radius))
        .overlay(RoundedRectangle(cornerRadius: StorebenchTheme.radius).strokeBorder(StorebenchTheme.border))
        .accessibilityElement(children: .contain).accessibilityLabel(title)
    }
}
