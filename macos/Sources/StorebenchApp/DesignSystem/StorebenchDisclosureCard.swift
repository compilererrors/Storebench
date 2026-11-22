import StorebenchCore
import SwiftUI

/// A record card whose heading is its main command, such as Continue Release, and whose details open from a smaller command
/// beside it. The details stay mounted when closed.
struct StorebenchDisclosureCard<Header: View, Content: View>: View {
    @Binding var expanded: Bool
    var identifier = ""
    /// The main command the whole heading runs, such as "Continue Release".
    let actionTitle: String
    /// What the side command shows or hides, such as "Requirements".
    var disclosureTitle = "Details"
    var unavailable = false
    let open: () -> Void
    @ViewBuilder let header: () -> Header
    @ViewBuilder let content: () -> Content
    @State private var mounted = false
    var body: some View {
        VStack(alignment: .leading, spacing: expanded ? StorebenchTheme.gap : 0) {
            StorebenchDisclosureHeaderLayout {
                StorebenchCardAction(title: actionTitle, unavailable: unavailable, action: open, label: header)
                    .storebenchControlID(identifier + ".open")
                StorebenchDisclosureButton(isExpanded: $expanded, card: true, fillsHeight: true) {
                    Text((expanded ? "Hide " : "Show ") + disclosureTitle).font(.sbCallout.weight(.medium)).lineLimit(1)
                }
                .storebenchControlID(identifier + ".disclosure")
            }
            if mounted || expanded {
                VStack(alignment: .leading, spacing: StorebenchTheme.gap) {
                    StorebenchDivider()
                    content()
                }.collectionVisibility(expanded)
            }
        }.padding(StorebenchTheme.padding).frame(maxWidth: .infinity, alignment: .leading).modifier(StorebenchPanelSurface())
            .onChange(of: expanded, initial: true) { if expanded { mounted = true } }
    }
}

/// The heading and the side command share one row and one height; the side command keeps the standard command width.
private struct StorebenchDisclosureHeaderLayout: StorebenchTrackLayout {
    func tracks(width: CGFloat, minimumHeight: CGFloat, subviews: Subviews) -> StorebenchTracks {
        let gap = StorebenchTheme.gap, side = min(width, StorebenchTheme.actionWidth)
        let stacked = width < StorebenchTheme.actionWidth + 260 + gap
        let mainWidth = stacked ? width : max(0, width - side - gap)
        let mainHeight = subviews.size(0, ProposedViewSize(width: mainWidth, height: nil)).height
        let sideHeight = subviews.size(1, ProposedViewSize(width: side, height: nil)).height
        let row = max(mainHeight, sideHeight)
        return StorebenchTracks(frames: [CGRect(x: 0, y: 0, width: mainWidth, height: stacked ? mainHeight : row),
            CGRect(x: width - side, y: stacked ? mainHeight + gap : 0, width: side, height: stacked ? sideHeight : row)],
            height: stacked ? mainHeight + gap + sideHeight : row)
    }
}

/// A card's main command across its heading: the heading's content with the command's name and an arrow at its end. The whole
/// heading is the target and shows the shared hover fill and border, like every other target.
struct StorebenchCardAction<Label: View>: View {
    let title: String
    var unavailable = false
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var pointer = false
    @Environment(\.hoverPreview) private var preview
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        let hovering = (preview ?? pointer) && enabled && !unavailable
        Button(action: action) {
            HStack(spacing: StorebenchTheme.space(3)) {
                label().frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                HStack(spacing: StorebenchTheme.space(2)) {
                    Text(title).font(.sbCallout.weight(.semibold)).lineLimit(1).fixedSize()
                    StorebenchIcon(name: "right")
                }.foregroundStyle(StorebenchTheme.color("color-accent-muted"))
            }
            .padding(StorebenchTheme.space(2)).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .frame(minHeight: StorebenchTheme.controlHeight)
            .foregroundStyle(StorebenchTheme.ink)
            .storebenchHoverFill(hovering)
            .overlay(StorebenchControlOutline(border: .clear))
        }
        .buttonStyle(StorebenchPressStyle()).storebenchHover { pointer = $0 }
        .storebenchWorking(unavailable)
        .help(title).accessibilityHint(title)
    }
}
