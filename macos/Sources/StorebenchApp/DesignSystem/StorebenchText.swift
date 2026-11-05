import AppKit
import StorebenchCore
import SwiftUI

/// Static copy takes only the height of its text and grows to show it completely; only copy beyond the
/// generous limit, or a fixed track offered by its container, scrolls. `live` status and feedback keep
/// a fixed track sized for realistic messages, so updates never move neighbouring content, and centered
/// titles keep theirs so they stay level with the icon beside them. Nothing else reserves empty space.
struct StorebenchTextTrack<Content: View>: View {
    let height: CGFloat
    var centered = false
    var live = false
    var maximumHeight: CGFloat = StorebenchTheme.textTrackLimit
    @ViewBuilder let content: () -> Content
    private var reserved: CGFloat { live || centered ? height : 0 }
    private var limit: CGFloat { live ? height : maximumHeight }
    @State private var overflows = false
    var body: some View {
        if overflows {
            StorebenchTextTrackFrame(height: reserved, maximumHeight: limit) {
                content().frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    .hidden().accessibilityHidden(true)
                ScrollView(.vertical) {
                    StorebenchTextTrackLayout(height: reserved, centered: centered) {
                        content().frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } else {
            StorebenchPlainTextTrack(height: reserved, maximumHeight: limit, centered: centered) {
                content().frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: Bool.self, of: { $0.size.height > limit + 0.5 }) { if $0 { overflows = true } }
            }.clipped()
        }
    }
}

private struct StorebenchTextTrackFrame: Layout {
    let height: CGFloat, maximumHeight: CGFloat
    private func frame(_ width: CGFloat, offered: CGFloat?, subviews: Subviews) -> CGFloat {
        let content = subviews.size(0, ProposedViewSize(width: width, height: nil)).height
        return ComponentLayout.textTrackFrame(minimumHeight: height, contentHeight: content, maximumHeight: maximumHeight, offeredHeight: offered.map(Double.init))
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.usableWidth(subviews.size(0, .unspecified).width)
        return CGSize(width: width, height: frame(width, offered: proposal.height, subviews: subviews))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.place(1, at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// Short content keeps its natural width instead of claiming the whole row, and wraps once the row is narrower.
struct StorebenchHugWidth: Layout {
    var hug = true
    private func width(_ proposal: ProposedViewSize, subviews: Subviews) -> CGFloat? {
        guard hug, let offered = proposal.width else { return proposal.width }
        return min(max(0, offered), subviews.size(0, .unspecified).width)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = width(proposal, subviews: subviews)
        let size = subviews.size(0, ProposedViewSize(width: width, height: proposal.height))
        return CGSize(width: hug ? size.width : (width ?? size.width), height: size.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.place(0, at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// A text track without a scroll view: as tall as its copy within the reserved and maximum heights, centred when asked.
private struct StorebenchPlainTextTrack: Layout {
    let height: CGFloat, maximumHeight: CGFloat, centered: Bool
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.usableWidth(subviews.size(0, .unspecified).width)
        let content = subviews.size(0, ProposedViewSize(width: width, height: nil)).height
        return CGSize(width: width, height: ComponentLayout.textTrackFrame(minimumHeight: height, contentHeight: content, maximumHeight: maximumHeight, offeredHeight: proposal.height.map(Double.init)))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let measured = subviews.size(0, ProposedViewSize(width: bounds.width, height: nil))
        let track = ComponentLayout.textTrack(minimumHeight: min(height, bounds.height), contentHeight: min(measured.height, bounds.height), centered: centered)
        subviews.place(0, at: CGPoint(x: bounds.minX, y: bounds.minY + track.contentOffset), proposal: ProposedViewSize(width: bounds.width, height: measured.height))
    }
}

private struct StorebenchTextTrackLayout: Layout {
    let height: CGFloat, centered: Bool
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.usableWidth()
        let measured = subviews.size(0, ProposedViewSize(width: width, height: nil))
        let track = ComponentLayout.textTrack(minimumHeight: height, contentHeight: measured.height, centered: centered)
        return CGSize(width: width, height: track.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let measured = subviews.size(0, ProposedViewSize(width: bounds.width, height: nil))
        let track = ComponentLayout.textTrack(minimumHeight: height, contentHeight: measured.height, centered: centered)
        subviews.place(0, at: CGPoint(x: bounds.minX, y: bounds.minY + track.contentOffset), proposal: ProposedViewSize(width: bounds.width, height: measured.height))
    }
}

/// The shared text track for one string. Pass `nil` for `font` or `color` to inherit them from the surrounding view.
struct StorebenchTextSlot: View {
    let text: String, height: CGFloat
    var tracking: CGFloat = 0
    var font: Font? = .sbBody
    var color: Color? = StorebenchTheme.ink
    var centered = false
    var live = false
    var body: some View {
        StorebenchTextTrack(height: height, centered: centered, live: live) {
            Text(text).font(font).tracking(tracking).foregroundStyle(color.map(AnyShapeStyle.init) ?? AnyShapeStyle(.foreground)).textSelection(.enabled)
        }.accessibilityLabel(text)
    }
}

struct StorebenchAdaptiveText: View {
    let text: String
    var maximumHeight: CGFloat = 60
    var font: Font = .sbCallout
    var color: Color = StorebenchTheme.ink
    private var label: some View { Text(text).font(font).foregroundStyle(color).fixedSize(horizontal: false, vertical: true) }
    @State private var overflows = false
    var body: some View {
        if overflows {
            AdaptiveTextLayout(text: text, font: font, maximumHeight: maximumHeight, empty: text.isEmpty) {
                label.hidden().accessibilityHidden(true)
                ScrollView(.vertical) { label.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            }.accessibilityLabel(text)
        } else if !text.isEmpty {
            label.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: Bool.self, of: { $0.size.height > maximumHeight + 0.5 }) { if $0 { overflows = true } }
                .accessibilityLabel(text)
        }
    }
}
private struct AdaptiveTextLayout: Layout {
    let text: String, font: Font
    let maximumHeight: CGFloat, empty: Bool
    struct Key: Equatable { let text: String, font: Font, width: CGFloat }
    struct Cache { var measurement = LayoutMeasurementCache<Key, CGSize>() }
    func makeCache(subviews: Subviews) -> Cache { Cache() }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.usableWidth()
        let measured = cache.measurement.resolve(Key(text: text, font: font, width: width)) {
            subviews.size(0, ProposedViewSize(width: width, height: nil))
        }
        return CGSize(width: width, height: ComponentLayout.boundedTextHeight(measured: measured.height, maximum: maximumHeight, empty: empty))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        subviews.place(1, at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
