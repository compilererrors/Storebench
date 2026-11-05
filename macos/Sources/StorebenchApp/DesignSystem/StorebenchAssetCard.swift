import StorebenchCore
import SwiftUI

struct StorebenchAssetCard<Preview: View, Actions: View>: View {
    let title, metadata, status: String
    var position: Int? = nil
    var excluded = false
    var previewHeight = StorebenchTheme.measure("assetPreviewHeight")
    /// When set, the card's name and details move it like its preview does, instead of selecting their text.
    var drag: MaterialDrag? = nil
    @ViewBuilder let preview: () -> Preview
    @ViewBuilder let actions: () -> Actions
    var body: some View {
        StorebenchAssetCardLayout(previewHeight: previewHeight) {
            preview().frame(maxWidth: .infinity)
                .padding(StorebenchTheme.measure("assetPreviewPadding")).frame(height: previewHeight)
                .background(StorebenchTheme.color("color-surface-sunken"), in: UnevenRoundedRectangle(topLeadingRadius: StorebenchTheme.measure("assetRadius") - 1, topTrailingRadius: StorebenchTheme.measure("assetRadius") - 1))
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
            }.frame(height: StorebenchTheme.measure("assetBadgeHeight")).materialDragSource(drag)
            StorebenchTextSlot(text: title, height: StorebenchTheme.measure("assetTitleHeight"), font: .sbHeadline).help(title).materialDragSource(drag)
            StorebenchTextSlot(text: metadata, height: StorebenchTheme.measure("assetMetadataHeight"), font: .sbCaption, color: StorebenchTheme.muted).help(metadata).materialDragSource(drag)
            StorebenchDivider()
            actions().frame(maxWidth: .infinity, minHeight: StorebenchTheme.controlHeight, alignment: .leading)
        }
            .background(excluded ? StorebenchTheme.color("color-surface-subtle") : StorebenchTheme.surface, in: RoundedRectangle(cornerRadius: StorebenchTheme.measure("assetRadius")))
            .overlay(RoundedRectangle(cornerRadius: StorebenchTheme.measure("assetRadius")).strokeBorder(StorebenchTheme.color("color-border-control")))
            .accessibilityElement(children: .contain).accessibilityLabel(title)
    }
}

private struct StorebenchAssetCardLayout: StorebenchTrackLayout {
    let previewHeight: CGFloat
    var fillsRow: Bool { true }
    var unspecifiedWidth: CGFloat { 360 }
    func tracks(width: CGFloat, minimumHeight: CGFloat, subviews: Subviews) -> StorebenchTracks {
        let reserved = ComponentLayout.assetCard(width: width, actionsHeight: 0, previewHeight: previewHeight)
        func height(_ index: Int) -> CGFloat { subviews.size(index, ProposedViewSize(width: reserved.actions.width, height: nil)).height }
        let card = ComponentLayout.assetCard(width: width, actionsHeight: height(5), previewHeight: previewHeight, titleHeight: height(2), metadataHeight: height(3), minimumHeight: minimumHeight)
        return StorebenchTracks(frames: [card.preview, card.identity, card.title, card.metadata, card.divider, card.actions], height: card.height)
    }
}
