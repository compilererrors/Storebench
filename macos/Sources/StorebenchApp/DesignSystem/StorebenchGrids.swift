import StorebenchCore
import SwiftUI

/// Every grid owns row equalization; cards elsewhere keep their natural height.
struct StorebenchMetricGrid<Content: View>: View {
    var maximumColumns = 4
    var balanced = false
    var minimumWidth: CGFloat = 190
    var workflow = false
    var evenRows = false
    var spacing: CGFloat = StorebenchTheme.gap
    var rowSpacing: CGFloat? = nil
    var bottomPadding: CGFloat = 0
    var keepColumns = false
    @ViewBuilder let content: () -> Content
    var body: some View {
        StorebenchGridLayout(maximumColumns: maximumColumns, balanced: balanced, minimumWidth: minimumWidth, workflow: workflow,
                             evenRows: evenRows, spacing: spacing, rowSpacing: rowSpacing, bottomPadding: bottomPadding, keepColumns: keepColumns) {
            content().environment(\.gridCardRows, true)
        }
    }
}

private struct GridCardRowsKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var gridCardRows: Bool { get { self[GridCardRowsKey.self] } set { self[GridCardRowsKey.self] = newValue } }
}

private struct StorebenchGridLayout: Layout {
    var maximumColumns = 4
    var balanced = false
    var minimumWidth: CGFloat = 190
    var workflow = false
    var evenRows = false
    var spacing: CGFloat = StorebenchTheme.gap
    var rowSpacing: CGFloat? = nil
    var bottomPadding: CGFloat = 0
    var keepColumns = false
    struct Cache { var measurement = LayoutMeasurementCache<CGFloat, ComponentLayout.Grid>() }
    func makeCache(subviews: Subviews) -> Cache { Cache() }
    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache.measurement.invalidate() }
    private func geometry(_ width: CGFloat, subviews: Subviews) -> ComponentLayout.Grid {
        let columns = ComponentLayout.columns(width: width, count: subviews.count, maximum: maximumColumns, minimumWidth: minimumWidth, spacing: spacing, balanced: balanced, workflow: workflow, evenRows: evenRows, keepColumns: keepColumns)
        let cellWidth = max(0, (width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
        return ComponentLayout.grid(width: width, heights: subviews.map { $0.sizeThatFits(ProposedViewSize(width: cellWidth, height: nil)).height + bottomPadding }, maximum: maximumColumns, minimumWidth: minimumWidth, spacing: spacing, balanced: balanced, workflow: workflow, evenRows: evenRows, rowSpacing: rowSpacing.map(Double.init), keepColumns: keepColumns)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.usableWidth()
        cache.measurement.invalidate()
        return CGSize(width: width, height: cache.measurement.resolve(width) { geometry(width, subviews: subviews) }.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let grid = cache.measurement.consume(bounds.width) ?? geometry(bounds.width, subviews: subviews)
        for (index, view) in subviews.enumerated() {
            let row = index / grid.columns
            view.place(at: CGPoint(x: bounds.minX + CGFloat(index % grid.columns) * (grid.cellWidth + spacing), y: bounds.minY + grid.rowOffsets[row]), proposal: ProposedViewSize(width: grid.cellWidth, height: max(0, grid.rowHeights[row] - bottomPadding)))
        }
    }
}

/// Fields in the page's shared columns. `keepColumns` keeps both columns with a single field, so it lines up with every other grid.
struct StorebenchFormGrid<Content: View>: View {
    var maximumColumns = 2
    var minimumWidth: CGFloat = StorebenchTheme.measure("formMinimumWidth")
    var keepColumns = true
    @ViewBuilder let content: () -> Content
    @Environment(\.settingsPresentation) private var settingsPresentation
    var body: some View {
        StorebenchMetricGrid(maximumColumns: settingsPresentation ? 1 : maximumColumns, minimumWidth: minimumWidth,
                             rowSpacing: settingsPresentation ? StorebenchTheme.gap : StorebenchTheme.measure("formRowGap"),
                             bottomPadding: settingsPresentation ? 0 : StorebenchTheme.measure("formBottomPadding"), keepColumns: keepColumns) { content() }
    }
}

/// Settings share one label track and one control track. Narrow panes stack both without compressing either.
struct StorebenchSettingsFieldLayout: StorebenchTrackLayout {
    func tracks(width: CGFloat, minimumHeight: CGFloat, subviews: Subviews) -> StorebenchTracks {
        let gap = StorebenchTheme.gap
        let stacked = width < StorebenchTheme.settingsLabelWidth + gap + StorebenchTheme.settingsControlWidth
        let controlWidth = stacked ? width : StorebenchTheme.settingsControlWidth
        let labelWidth = stacked ? width : max(0, width - gap - controlWidth)
        let copy = subviews.size(0, ProposedViewSize(width: labelWidth, height: nil))
        let input = subviews.size(1, ProposedViewSize(width: controlWidth, height: nil))
        let controlHeight = max(StorebenchTheme.controlHeight, input.height)
        return StorebenchTracks(frames: [CGRect(x: 0, y: 0, width: labelWidth, height: copy.height),
                                         CGRect(x: stacked ? 0 : width - controlWidth, y: stacked ? copy.height + gap : 0, width: controlWidth, height: controlHeight)],
                                height: stacked ? copy.height + gap + controlHeight : max(copy.height, controlHeight))
    }
}

/// Commands that belong to the field beside them in a grid, such as Preview Prices next to a guide price. They keep the field's
/// label and hint tracks, so the buttons sit on the field's own row and every row of the grid shares one baseline.
struct StorebenchFieldCommands<Content: View>: View {
    var hint = ""
    @ViewBuilder let content: () -> Content
    var body: some View {
        StorebenchFormField(label: "", hint: hint) { StorebenchActionGroup { content() } }.accessibilityElement(children: .contain)
    }
}

extension View {
    /// A field on its own takes one column of the form grid instead of a width of its own, so its edges line up with the fields around it.
    func storebenchFormColumn() -> some View { StorebenchFormGrid(keepColumns: true) { self } }
}

struct StorebenchFilterBar<Content: View>: View {
    var columns = 2
    @ViewBuilder let content: () -> Content
    @Environment(\.workspaceWidth) private var width
    var body: some View {
        StorebenchMetricGrid(maximumColumns: width <= 800 ? 1 : columns, minimumWidth: 1) { content() }
            .padding(.bottom, 12)
    }
}
