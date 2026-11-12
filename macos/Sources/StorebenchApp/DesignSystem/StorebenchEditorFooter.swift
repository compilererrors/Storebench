import StorebenchCore
import SwiftUI

/// Static editing instructions keep their full text and share the editor's command column.
struct StorebenchEditorGuide<Actions: View>: View {
    let title, detail: String
    var hint = ""
    var identifier = "editor.guide"
    @ViewBuilder let actions: () -> Actions
    var body: some View {
        StorebenchHeader(stackAt: 640) {
            VStack(alignment: .leading, spacing: StorebenchTheme.space(1)) {
                StorebenchTextSlot(text: title, height: 18, font: .sbHeadline)
                    .storebenchControlID(identifier + ".title")
                StorebenchTextSlot(text: detail, height: 18, font: .sbCallout, color: StorebenchTheme.muted)
                    .storebenchControlID(identifier + ".detail")
                if !hint.isEmpty {
                    StorebenchTextSlot(text: hint, height: 16, font: .sbCaption, color: StorebenchTheme.muted)
                        .storebenchControlID(identifier + ".hint")
                }
            }
        } actions: { actions() }
        .padding(StorebenchTheme.padding)
        .background(StorebenchTheme.color("color-surface-accent"), in: RoundedRectangle(cornerRadius: StorebenchTheme.radius))
        .overlay(RoundedRectangle(cornerRadius: StorebenchTheme.radius).strokeBorder(StorebenchTheme.color("color-border-accent")))
        .accessibilityElement(children: .contain).accessibilityLabel(title)
        .storebenchControlID(identifier)
    }
}

/// A contextual command area shared by editors, with feedback inside the same rounded surface.
struct StorebenchEditorFooter<Actions: View>: View {
    let title, detail: String
    var hint = ""
    var reservesStatusIcon = false
    var statusIcon: String? = nil
    var statusColor: Color? = nil
    @ViewBuilder let actions: () -> Actions
    var body: some View {
        StorebenchHeader(stackAt: 640) {
            VStack(alignment: .leading, spacing: StorebenchTheme.space(1)) {
                StorebenchTextSlot(text: title, height: StorebenchTheme.measure("fieldLabel"), font: .sbHeadline)
                HStack(alignment: .top, spacing: StorebenchTheme.space(2)) {
                    if reservesStatusIcon {
                        StorebenchIcon(name: statusIcon ?? "check", size: 14).foregroundStyle(statusColor ?? StorebenchTheme.muted)
                            .opacity(statusIcon == nil ? 0 : 1).accessibilityHidden(true).padding(.top, 2)
                    }
                    StorebenchTextSlot(text: detail, height: 40, font: .sbCallout, color: statusColor ?? StorebenchTheme.muted, live: true)
                }
                if !hint.isEmpty { StorebenchAdaptiveText(text: hint, maximumHeight: 40, font: .sbCaption, color: StorebenchTheme.muted) }
            }
        } actions: { actions() }
        .padding(StorebenchTheme.padding)
        .background(StorebenchTheme.color("color-surface-subtle"), in: RoundedRectangle(cornerRadius: StorebenchTheme.radius))
        .overlay(RoundedRectangle(cornerRadius: StorebenchTheme.radius).strokeBorder(StorebenchTheme.border))
        .accessibilityElement(children: .contain).accessibilityLabel(title)
        .layoutValue(key: StorebenchFullWidthAction.self, value: true)
    }
}
