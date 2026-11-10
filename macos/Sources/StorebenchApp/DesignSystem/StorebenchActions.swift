import StorebenchCore
import SwiftUI

/// Related controls wrap into complete rows while retaining the shared button footprint. The button rules are in docs/design-components.md.
struct StorebenchActionGroup<Content: View>: View {
    var alignment: StorebenchFlow.Alignment = .leading
    @ViewBuilder let content: () -> Content
    var body: some View {
        StorebenchActionLayout(trailing: alignment == .trailing) { content().environment(\.actionFill, true) }
            .frame(maxWidth: .infinity).fixedSize(horizontal: false, vertical: true)
    }
}

/// An explicit horizontal track, including inside custom layouts and retained disclosures.
struct StorebenchDivider: View {
    var body: some View {
        Rectangle().fill(StorebenchTheme.border).frame(maxWidth: .infinity).frame(height: 1)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// The final command area of a form, separate from its status and comparison content.
struct StorebenchFormFooter<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(spacing: StorebenchTheme.space(3)) {
            StorebenchDivider()
            StorebenchActionGroup(alignment: .trailing) { content() }
        }.frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            .layoutValue(key: StorebenchCardFooterKey.self, value: true)
    }
}

/// Inputs and their commands stay adjacent on the leading edge, and stack in narrow tracks.
struct StorebenchInputActions<Content: View, Actions: View>: View {
    @ViewBuilder let content: () -> Content
    @ViewBuilder let actions: () -> Actions
    var body: some View {
        // The field takes one column of the form grid and its commands sit on its row in the next one.
        StorebenchFormGrid(keepColumns: true) { content(); StorebenchFieldCommands { actions() } }.environment(\.fieldHintHeight, 0)
    }
}

struct StorebenchPagination: View {
    let page, count: Int, choose: (Int) -> Void
    @State private var target = ""
    private var requested: Int? { guard let value = Int(target), value >= 1, value <= count else { return nil }; return value }
    var body: some View {
        StorebenchFlow(spacing: StorebenchTheme.space(2), alignment: .trailing) {
            Button { choose(1) } label: { StorebenchIcon(name: "first") }.buttonStyle(StorebenchButtonStyle(.quiet, size: .icon)).opacity(page <= 1 ? 0 : 1).allowsHitTesting(!(page <= 1)).accessibilityHidden(page <= 1).help("First page").accessibilityLabel("First page")
            Button { choose(page - 1) } label: { StorebenchIcon(name: "previous") }.buttonStyle(StorebenchButtonStyle(.quiet, size: .icon)).opacity(page <= 1 ? 0 : 1).allowsHitTesting(!(page <= 1)).accessibilityHidden(page <= 1).help("Previous page").accessibilityLabel("Previous page")
            Text("Page \(page) of \(count)").font(.sbCaption.monospacedDigit()).frame(height: StorebenchTheme.controlHeight)
            StorebenchTextField("Page", text: $target).labelsHidden().frame(width: 56).accessibilityLabel("Go to page").onSubmit { if let requested { choose(requested) } }
            Button("Go") { if let requested { choose(requested) } }.buttonStyle(StorebenchButtonStyle(.secondary)).environment(\.naturalActions, true).opacity(requested == nil ? 0 : 1).allowsHitTesting(!(requested == nil)).accessibilityHidden(requested == nil)
            Button { choose(page + 1) } label: { StorebenchIcon(name: "next") }.buttonStyle(StorebenchButtonStyle(.quiet, size: .icon)).opacity(page >= count ? 0 : 1).allowsHitTesting(!(page >= count)).accessibilityHidden(page >= count).help("Next page").accessibilityLabel("Next page")
            Button { choose(count) } label: { StorebenchIcon(name: "last") }.buttonStyle(StorebenchButtonStyle(.quiet, size: .icon)).opacity(page >= count ? 0 : 1).allowsHitTesting(!(page >= count)).accessibilityHidden(page >= count).help("Last page").accessibilityLabel("Last page")
        }.accessibilityElement(children: .contain).accessibilityLabel("Pages")
            .onAppear { target = String(page) }.onChange(of: page) { target = String(page) }.onChange(of: count) { target = String(min(page, count)) }
    }
}

private struct StorebenchActionLayout: Layout {
    var trailing = false
    struct Cache { var measurement = LayoutMeasurementCache<CGFloat, ComponentLayout.ActionGrid>() }
    func makeCache(subviews: Subviews) -> Cache { Cache() }
    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache.measurement.invalidate() }
    /// Every command in every group takes the one shared button width, so groups line up with each other on the grid.
    private func geometry(_ width: CGFloat, subviews: Subviews) -> ComponentLayout.ActionGrid {
        let cell = min(max(0, width), StorebenchTheme.actionWidth)
        return ComponentLayout.actionGrid(width: width, heights: subviews.map { $0.sizeThatFits(ProposedViewSize(width: cell, height: nil)).height }, trailing: trailing, cell: cell)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.usableWidth()
        cache.measurement.invalidate()
        return CGSize(width: width, height: cache.measurement.resolve(width) { geometry(width, subviews: subviews) }.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let layout = cache.measurement.consume(bounds.width) ?? geometry(bounds.width, subviews: subviews)
        for (index, frame) in layout.frames.enumerated() {
            subviews.place(index, at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }
}

/// A command that stays in place: dimmed with the reason on hover when it cannot run, and dimmed with a spinner while it runs.
struct StorebenchCommand: View {
    let title: String
    var running = "Preparing…"
    let busy: Bool
    /// Why the command cannot run now; nil when it can.
    let unavailable: String?
    var primary = true
    let action: () -> Void
    var body: some View {
        Button { if !busy, unavailable == nil { action() } } label: { StorebenchBusyLabel(title, loading: running, busy: busy) }
            .buttonStyle(StorebenchButtonStyle(primary ? .primary : .secondary))
            .transformEnvironment(\.actionBusy) { if busy { $0 = true } }
            .disabled(!busy && unavailable != nil)
            .help(busy ? running : unavailable ?? title)
            .accessibilityLabel(busy ? running : title).accessibilityHint(busy ? "" : unavailable ?? "")
    }
}
