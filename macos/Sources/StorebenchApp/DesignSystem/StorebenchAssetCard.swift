import StorebenchCore
import SwiftUI

struct StorebenchAssetCard<Preview: View, Actions: View>: View {
    let title, metadata, status: String
    var position: Int? = nil
    var excluded = false
    var previewHeight = StorebenchTheme.measure("assetPreviewHeight")
    var compact = false
    /// When set, the card's name and details move it like its preview does, instead of selecting their text.
    var drag: MaterialDrag? = nil
    @ViewBuilder let preview: () -> Preview
    @ViewBuilder let actions: () -> Actions
    var body: some View {
        StorebenchAssetCardLayout(previewHeight: previewHeight, compact: compact) {
            preview().frame(maxWidth: .infinity)
                .padding(StorebenchTheme.measure("assetPreviewPadding")).frame(height: previewHeight)
                .background(StorebenchTheme.color(compact ? "color-surface-subtle" : "color-surface-sunken"), in: UnevenRoundedRectangle(topLeadingRadius: StorebenchTheme.measure("assetRadius") - 1, topTrailingRadius: StorebenchTheme.measure("assetRadius") - 1))
            ZStack {
                if compact { Color.clear.accessibilityHidden(true) }
                else {
                    HStack(spacing: StorebenchTheme.space(3)) {
                        if let position {
                            Text(String(position)).font(.sbCaption.bold())
                                .frame(width: StorebenchTheme.measure("assetBadgeHeight"), height: StorebenchTheme.measure("assetBadgeHeight"))
                                .background(StorebenchTheme.color("color-surface-sunken"), in: RoundedRectangle(cornerRadius: 6))
                                .accessibilityLabel("Position \(position)")
                        }
                        Spacer(minLength: 0)
                        Text(status).font(.sbCaption.weight(.semibold)).lineLimit(1)
                            .foregroundStyle(excluded ? StorebenchTheme.muted : StorebenchTheme.color("color-accent-muted"))
                            .padding(.horizontal, StorebenchTheme.space(2)).frame(height: StorebenchTheme.measure("assetBadgeHeight"))
                            .background(StorebenchTheme.color(excluded ? "color-surface-sunken" : "color-surface-accent"), in: RoundedRectangle(cornerRadius: 6))
                            .help(status).accessibilityLabel(status)
                    }
                }
            }.frame(height: compact ? 0 : StorebenchTheme.measure("assetBadgeHeight")).materialDragSource(drag)
            StorebenchAssetTitleLayout(numbered: compact && position != nil) {
                if compact, let position {
                    Text(String(position)).font(.sbCaption.weight(.semibold)).monospacedDigit().foregroundStyle(StorebenchTheme.muted)
                        .accessibilityLabel("Position \(position)")
                } else { Color.clear.accessibilityHidden(true) }
                StorebenchTextSlot(text: title, height: StorebenchTheme.measure(compact ? "assetCompactTitleHeight" : "assetTitleHeight"), font: compact ? .sbCallout.weight(.semibold) : .sbHeadline)
            }.help(title).materialDragSource(drag)
            StorebenchTextSlot(text: metadata, height: StorebenchTheme.measure("assetMetadataHeight"), font: .sbCaption, color: StorebenchTheme.muted).help(metadata).materialDragSource(drag)
            StorebenchDivider()
            actions().frame(maxWidth: .infinity, minHeight: StorebenchTheme.controlHeight, alignment: .leading)
        }
            .background(excluded ? StorebenchTheme.color("color-surface-subtle") : StorebenchTheme.surface, in: RoundedRectangle(cornerRadius: StorebenchTheme.measure("assetRadius")))
            .overlay(RoundedRectangle(cornerRadius: StorebenchTheme.measure("assetRadius")).strokeBorder(compact ? StorebenchTheme.border : StorebenchTheme.color("color-border-control")))
            .accessibilityElement(children: .contain).accessibilityLabel(title)
    }
}

/// The ordinal owns a fixed track; the filename receives only the remaining width, including during SwiftUI's first probe.
private struct StorebenchAssetTitleLayout: StorebenchTrackLayout {
    let numbered: Bool
    func tracks(width: CGFloat, minimumHeight: CGFloat, subviews: Subviews) -> StorebenchTracks {
        let number = numbered ? min(width, StorebenchTheme.measure("assetBadgeHeight")) : 0
        let gap = numbered ? min(max(0, width - number), StorebenchTheme.space(2)) : 0
        let available = max(0, width - number - gap)
        let title = subviews.size(1, ProposedViewSize(width: available, height: nil))
        let ordinal = subviews.size(0, ProposedViewSize(width: number, height: nil))
        return StorebenchTracks(frames: [CGRect(x: 0, y: 0, width: number, height: numbered ? ordinal.height : 0),
                                        CGRect(x: number + gap, y: 0, width: available, height: title.height)], height: max(title.height, numbered ? ordinal.height : 0))
    }
}

private struct StorebenchAssetCardLayout: StorebenchTrackLayout {
    let previewHeight: CGFloat
    let compact: Bool
    var fillsRow: Bool { true }
    var unspecifiedWidth: CGFloat { 360 }
    func tracks(width: CGFloat, minimumHeight: CGFloat, subviews: Subviews) -> StorebenchTracks {
        let reserved = ComponentLayout.assetCard(width: width, actionsHeight: 0, previewHeight: previewHeight, compact: compact)
        func height(_ index: Int) -> CGFloat { subviews.size(index, ProposedViewSize(width: reserved.actions.width, height: nil)).height }
        let card = ComponentLayout.assetCard(width: width, actionsHeight: height(5), previewHeight: previewHeight, titleHeight: height(2), metadataHeight: height(3), minimumHeight: minimumHeight, compact: compact)
        return StorebenchTracks(frames: [card.preview, card.identity, card.title, card.metadata, card.divider, card.actions], height: card.height)
    }
}
