import StorebenchCore
import SwiftUI

/// Related options share a compact, bounded context instead of spreading across the page.
struct StorebenchOptionGroup<Content: View>: View {
    let title: String
    var description = ""
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: StorebenchTheme.space(2)) {
            StorebenchAdaptiveText(text: title, font: .sbHeadline)
            if !description.isEmpty { StorebenchAdaptiveText(text: description, font: .sbCaption, color: StorebenchTheme.muted) }
            content()
        }
        .padding(StorebenchTheme.measure("optionGroupPadding"))
        .frame(maxWidth: StorebenchTheme.measure("optionGroupWidth"), alignment: .leading)
        .background(StorebenchTheme.color("color-surface-subtle"), in: RoundedRectangle(cornerRadius: StorebenchTheme.controlRadius))
        .overlay(RoundedRectangle(cornerRadius: StorebenchTheme.controlRadius).strokeBorder(StorebenchTheme.border))
        .accessibilityElement(children: .contain).accessibilityLabel(title)
    }
}

/// Checkbox rows need no field-label, hint or feedback tracks. Long labels wrap; narrow groups stack.
struct StorebenchOptionGrid<Content: View>: View {
    var maximumColumns = 2
    /// Narrower columns for long lists of short names, such as languages, so more of them fit side by side.
    var minimumWidth = StorebenchTheme.measure("optionMinimumWidth")
    @ViewBuilder let content: () -> Content
    var body: some View {
        StorebenchMetricGrid(maximumColumns: maximumColumns, minimumWidth: minimumWidth,
                             spacing: StorebenchTheme.measure("optionColumnGap"), rowSpacing: StorebenchTheme.measure("optionRowGap")) { content() }
            .frame(maxWidth: StorebenchTheme.measure("optionGroupWidth"), alignment: .leading)
            .environment(\.gridCardRows, false)
    }
}
