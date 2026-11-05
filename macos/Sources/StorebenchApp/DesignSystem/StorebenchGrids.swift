import StorebenchCore
import SwiftUI

struct StorebenchMetricGrid: Layout {
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
struct StorebenchFormGrid: Layout {
    var maximumColumns = 2
    var minimumWidth: CGFloat = StorebenchTheme.measure("formMinimumWidth")
    var keepColumns = false
    private var grid: StorebenchMetricGrid {
        StorebenchMetricGrid(maximumColumns: maximumColumns, minimumWidth: minimumWidth, rowSpacing: StorebenchTheme.measure("formRowGap"), bottomPadding: StorebenchTheme.measure("formBottomPadding"), keepColumns: keepColumns)
    }
    func makeCache(subviews: Subviews) -> StorebenchMetricGrid.Cache { grid.makeCache(subviews: subviews) }
    func updateCache(_ cache: inout StorebenchMetricGrid.Cache, subviews: Subviews) { grid.updateCache(&cache, subviews: subviews) }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout StorebenchMetricGrid.Cache) -> CGSize { grid.sizeThatFits(proposal: proposal, subviews: subviews, cache: &cache) }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout StorebenchMetricGrid.Cache) { grid.placeSubviews(in: bounds, proposal: proposal, subviews: subviews, cache: &cache) }
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
