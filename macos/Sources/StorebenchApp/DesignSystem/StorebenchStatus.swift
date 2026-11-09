import StorebenchCore
import SwiftUI

struct StorebenchStatusList<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One labelled line, such as "Stopped at" and the step: the label keeps a fixed track and the value wraps beside it,
/// or under it in a narrow track, so a list of facts lines up like a form.
struct StorebenchFact: View {
    let label: String, value: String
    var problem = false
    /// Marks a finished fact, such as a file already in place, with a check in the success colour.
    var done = false
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: StorebenchTheme.space(3)) {
                labelText.frame(width: StorebenchTheme.measure("factLabel"), alignment: .leading)
                valueText.frame(minWidth: StorebenchTheme.measure("factValue"), maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 2) { labelText; valueText }
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }
    private var labelText: some View { Text(label).font(.sbCallout.weight(.semibold)).foregroundStyle(StorebenchTheme.ink).fixedSize(horizontal: false, vertical: true) }
    private var valueText: some View {
        HStack(alignment: .firstTextBaseline, spacing: StorebenchTheme.space(1)) {
            if done { StorebenchIcon(name: "check", size: 14).accessibilityHidden(true) }
            Text(value).font(.sbCallout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }.foregroundStyle(problem ? StorebenchTheme.color("color-danger") : done ? StorebenchTheme.color("color-success") : StorebenchTheme.muted)
    }
}

/// A compact source header with contained copy; recovery and expanded details span the complete row. Every row keeps its status
/// in one fixed column and its command, such as Open, at the shared button width in the trailing column, so rows line up.
struct StorebenchStatusRow<Status: View, Action: View, Details: View>: View {
    let title: String, detail: String
    var separator = true
    private let actionWidth = CGFloat(StorebenchTheme.actionWidth)
    @ViewBuilder let status: () -> Status
    @ViewBuilder let action: () -> Action
    @ViewBuilder let details: () -> Details
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StorebenchStatusRowLayout(actionWidth: actionWidth) {
                VStack(alignment: .leading, spacing: StorebenchTheme.measure("sectionGap")) {
                    StorebenchTextSlot(text: title, height: StorebenchTheme.measure("sectionTitle"), font: .sbHeadline)
                    StorebenchTextSlot(text: detail, height: StorebenchTheme.measure("fieldHint"), font: .sbCallout, color: StorebenchTheme.muted)
                }
                HStack(spacing: 0) { status() }.frame(maxWidth: .infinity, minHeight: StorebenchTheme.controlHeight, alignment: .leading)
                HStack(spacing: 0) { action().environment(\.actionFill, true) }.frame(width: actionWidth, height: StorebenchTheme.controlHeight, alignment: .trailing)
                VStack(alignment: .leading, spacing: StorebenchTheme.space(2)) { details() }
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                    .transformEnvironment(\.navigationPresentation) { $0 = $0?.scoped(title) }
            }.padding(.vertical, StorebenchTheme.space(3))
            if separator { StorebenchDivider() }
        }.frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
    }
}

private struct StorebenchStatusRowLayout: Layout {
    var actionWidth: CGFloat = 74
    struct Cache { var measurement = LayoutMeasurementCache<CGFloat, ComponentLayout.StatusRow>() }
    func makeCache(subviews: Subviews) -> Cache { Cache() }
    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache.measurement.invalidate() }
    private func geometry(_ width: CGFloat, subviews: Subviews) -> ComponentLayout.StatusRow {
        let tracks = ComponentLayout.statusRow(width: width, headingHeight: 0, statusHeight: 0, actionHeight: 0, statusWidth: StorebenchTheme.measure("statusColumn"), actionWidth: actionWidth)
        func height(_ index: Int, _ width: CGFloat) -> CGFloat { subviews.size(index, ProposedViewSize(width: width, height: nil)).height }
        return ComponentLayout.statusRow(width: width, headingHeight: height(0, tracks.heading.width), statusHeight: height(1, tracks.status.width), actionHeight: height(2, tracks.action.width), detailsHeight: height(3, tracks.details.width), statusWidth: StorebenchTheme.measure("statusColumn"), actionWidth: actionWidth)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.usableWidth()
        cache.measurement.invalidate()
        return CGSize(width: width, height: cache.measurement.resolve(width) { geometry(width, subviews: subviews) }.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let row = cache.measurement.consume(bounds.width) ?? geometry(bounds.width, subviews: subviews)
        for (index, frame) in [row.heading, row.status, row.action, row.details].enumerated() {
            subviews.place(index, at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }
}

struct StorebenchSyncBadge: View {
    let state: SyncItem.State
    var body: some View {
        let value = SyncStatusPresentation(state)
        let tone = value.tone.rawValue
        let ink = value.tone == .neutral ? StorebenchTheme.ink : StorebenchTheme.color("color-" + tone)
        let fill = value.tone == .neutral ? StorebenchTheme.color("color-surface-subtle") : StorebenchTheme.color("color-" + tone + "-surface")
        let border = value.tone == .neutral ? StorebenchTheme.border : StorebenchTheme.color("color-" + tone + "-border")
        HStack(spacing: 6) {
            if state == .running { StorebenchSpinner().frame(width: 14, height: 14) }
            else { StorebenchIcon(name: value.icon, size: 14) }
            Text(value.label).font(.sbCaption.weight(.semibold)).lineLimit(1)
        }.foregroundStyle(ink).padding(.horizontal, 8).frame(maxWidth: .infinity, alignment: .leading).frame(height: 30)
            .background(fill, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(border))
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(value.label).accessibilityElement(children: .ignore).accessibilityLabel(value.label)
    }
}

/// App Store Connect's state mark and name: a green check for completed states, a yellow or red dot otherwise.
struct StorebenchStateLabel: View {
    let code: String
    var lines = 2
    var body: some View {
        let tone = AppStoreNames.tone(code), label = AppStoreNames.state(code)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Group {
                if tone == .complete { StorebenchIcon(name: "check", size: 12).foregroundStyle(StorebenchTheme.color("color-success")) }
                else { Circle().fill(StorebenchTheme.color(tone == .pending ? "color-warning" : tone == .problem ? "color-danger" : "color-text-tertiary")).frame(width: 9, height: 9) }
            }.frame(width: 12, height: 12).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            Text(label).font(.sbCallout).foregroundStyle(StorebenchTheme.ink).lineLimit(lines).fixedSize(horizontal: false, vertical: true)
        }.help(label).accessibilityElement(children: .ignore).accessibilityLabel(label)
    }
}

/// Something the user added or changed that could not be saved. It stays where it was added, in red, with the reason and one next step.
struct StorebenchNotSavedRow: View {
    let title: String, reason: String
    let next: String
    let retry: () -> Void
    let discard: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            StorebenchHeader {
                Text(title).font(.sbHeadline).foregroundStyle(StorebenchTheme.color("color-danger")).fixedSize(horizontal: false, vertical: true)
            } actions: {
                StorebenchActionGroup(alignment: .trailing) {
                    Button(next, action: retry).buttonStyle(StorebenchButtonStyle(.primary))
                    Button("Discard", role: .destructive, action: discard)
                }
            }
            StorebenchFeedback(text: reason, height: 40, error: true)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(StorebenchTheme.color("color-surface-sunken"), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .contain).accessibilityLabel(title)
    }
}

/// Work in progress for an added item, in the same place its result or problem will appear.
struct StorebenchAddingRow<Progress: View>: View {
    @ViewBuilder let progress: () -> Progress
    var body: some View {
        progress().frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading).padding(12)
            .background(StorebenchTheme.color("color-surface-sunken"), in: RoundedRectangle(cornerRadius: 10))
    }
}
