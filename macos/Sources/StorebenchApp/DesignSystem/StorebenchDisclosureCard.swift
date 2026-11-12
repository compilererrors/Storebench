import SwiftUI

/// A compact record header with an independent command, and details that stay mounted when closed.
struct StorebenchDisclosureCard<Header: View, Action: View, Content: View>: View {
    @Binding var expanded: Bool
    @ViewBuilder let header: () -> Header
    @ViewBuilder let action: () -> Action
    @ViewBuilder let content: () -> Content
    @State private var mounted = false
    var body: some View {
        VStack(alignment: .leading, spacing: expanded ? StorebenchTheme.gap : 0) {
            StorebenchDisclosureHeaderLayout {
                StorebenchDisclosureButton(isExpanded: $expanded, card: true, label: header)
                action()
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

private struct StorebenchDisclosureHeaderLayout: StorebenchTrackLayout {
    func tracks(width: CGFloat, minimumHeight: CGFloat, subviews: Subviews) -> StorebenchTracks {
        let gap = StorebenchTheme.gap, command = min(width, StorebenchTheme.actionWidth)
        let stacked = width < StorebenchTheme.actionWidth + 260 + gap
        let labelWidth = stacked ? width : max(0, width - command - gap)
        let labelHeight = subviews.size(0, ProposedViewSize(width: labelWidth, height: nil)).height
        let actionHeight = subviews.size(1, ProposedViewSize(width: command, height: nil)).height
        return StorebenchTracks(frames: [CGRect(x: 0, y: 0, width: labelWidth, height: labelHeight),
            CGRect(x: width - command, y: stacked ? labelHeight + gap : max(0, (labelHeight - actionHeight) / 2), width: command, height: actionHeight)],
            height: stacked ? labelHeight + gap + actionHeight : max(labelHeight, actionHeight))
    }
}
