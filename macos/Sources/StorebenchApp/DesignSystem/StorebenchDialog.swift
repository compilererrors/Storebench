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
        let shape = RoundedRectangle(cornerRadius: StorebenchTheme.measure("dialogRadius"))
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    StorebenchTextSlot(text: title, height: media ? 34 : 42, font: .system(size: media ? 16 : 18).bold(), centered: true)
                    if !subtitle.isEmpty { StorebenchTextSlot(text: subtitle, height: 18, font: .sbCaption, color: StorebenchTheme.muted) }
                }
                if let close {
                    Button(role: .cancel, action: close) { StorebenchIcon(name: "close") }
                        .storebenchControlID("dialog.close")
                        .buttonStyle(StorebenchButtonStyle(.quiet, size: .icon)).storebenchWorking(busy).help("Close dialog").accessibilityLabel("Close dialog")
                }
            }.padding(.vertical, media ? 12 : 18).padding(.horizontal, media ? 16 : 22)
            StorebenchDivider()
            Group {
                if scrollBody {
                    ScrollView {
                        VStack(alignment: .leading, spacing: StorebenchTheme.gap) {
                            content()
                            if inlineActions && Actions.self != EmptyView.self { VStack(alignment: .trailing, spacing: 12) { actions() } }
                        }.padding(StorebenchTheme.measure("dialogBodyPadding"))
                    }
                } else {
                    content().padding(media ? 0 : StorebenchTheme.measure("dialogBodyPadding"))
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if !inlineActions && Actions.self != EmptyView.self {
                StorebenchDivider()
                VStack(alignment: .trailing, spacing: 12) { actions() }.padding(.vertical, media ? 10 : 16).padding(.horizontal, StorebenchTheme.measure("dialogBodyPadding"))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }.frame(width: dimensions.width, height: dimensions.height)
            .background(StorebenchTheme.surface, in: shape)
            .clipShape(shape)
            .overlay(shape.strokeBorder(StorebenchTheme.border))
            .modifier(StorebenchAppearance())
            .onExitCommand { if !busy { close?() } }
    }
}

struct StorebenchFeedback: View {
    let text: String
    var height: CGFloat = 34
    var error = false
    /// The empty and populated states share one track so feedback never moves the controls below.
    var body: some View {
        StorebenchTextSlot(text: text, height: height, font: .sbCallout, color: error ? StorebenchTheme.color("color-danger") : StorebenchTheme.muted, live: true)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

/// How old the shown read is and whether it is being read again. Its line is always reserved, so updates never move the list.
struct StorebenchReadAge: View {
    let readAt: Date?
    let reading: Bool
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            StorebenchTextSlot(text: ReadAge.text(readAt: readAt, now: context.date, reading: reading), height: 18, font: .sbCaption, color: StorebenchTheme.muted, live: true)
        }
    }
}
