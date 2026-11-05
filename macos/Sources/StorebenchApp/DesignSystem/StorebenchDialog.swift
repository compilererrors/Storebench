import StorebenchCore
import SwiftUI

/// A bounded sheet with separately reserved header, scrolling body and action footer.
struct StorebenchDialog<Content: View, Actions: View>: View {
    let title: String
    var wide = false
    var height: CGFloat = 720
    var scrollBody = true
    var inlineActions = false
    var media = false
    var subtitle = ""
    var busy = false
    var close: (() -> Void)? = nil
    @ViewBuilder let content: () -> Content
    @ViewBuilder let actions: () -> Actions
    @Environment(\.workspaceWidth) private var width
    @Environment(\.workspaceHeight) private var viewportHeight
    var body: some View {
        let dimensions = ComponentLayout.dialog(viewportWidth: width, viewportHeight: viewportHeight, wide: wide, preferredHeight: height)
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    StorebenchTextSlot(text: title, height: media ? 34 : 42, font: .system(size: media ? 16 : 18).bold(), centered: true)
                    if !subtitle.isEmpty { StorebenchTextSlot(text: subtitle, height: 18, font: .sbCaption, color: StorebenchTheme.muted) }
                }
                if let close {
                    Button(role: .cancel, action: close) { StorebenchIcon(name: "close") }
                        .buttonStyle(StorebenchButtonStyle(.quiet, size: .icon)).storebenchWorking(busy).help("Close dialog").accessibilityLabel("Close dialog")
                }
            }.padding(.vertical, media ? 12 : 18).padding(.horizontal, media ? 16 : 22)
            StorebenchDivider()
            Group {
                if scrollBody {
                    ScrollView {
                        VStack(alignment: .leading, spacing: StorebenchTheme.gap) {
                            content()
                            if inlineActions && Actions.self != EmptyView.self { VStack(alignment: .trailing, spacing: 12) { actions() }.environment(\.naturalActions, true) }
                        }.padding(StorebenchTheme.measure("dialogBodyPadding"))
                    }
                } else {
                    content().padding(media ? 0 : StorebenchTheme.measure("dialogBodyPadding"))
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if !inlineActions && Actions.self != EmptyView.self {
                StorebenchDivider()
                VStack(alignment: .trailing, spacing: 12) { actions() }.padding(.vertical, media ? 10 : 16).padding(.horizontal, media ? 16 : 20)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .environment(\.naturalActions, true)
            }
        }.frame(width: dimensions.width, height: dimensions.height)
            .background(StorebenchTheme.surface, in: RoundedRectangle(cornerRadius: media ? 12 : StorebenchTheme.measure("dialogRadius")))
            .overlay(RoundedRectangle(cornerRadius: media ? 12 : StorebenchTheme.measure("dialogRadius")).strokeBorder(StorebenchTheme.border))
            .modifier(StorebenchAppearance())
            .onExitCommand { if !busy { close?() } }
    }
}

struct StorebenchFeedback: View {
    let text: String
    var height: CGFloat = 34
    var error = false
    /// No message takes no space; a message keeps a fixed track, so later updates do not move the content below.
    var body: some View {
        if !text.isEmpty {
            StorebenchTextSlot(text: text, height: height, font: .sbCallout, color: error ? StorebenchTheme.color("color-danger") : StorebenchTheme.muted, live: true)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }
}
