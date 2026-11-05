import AppKit
import StorebenchCore
import SwiftUI

struct StorebenchPageContent: ViewModifier {
    @Environment(\.workspaceWidth) private var width
    func body(content: Content) -> some View {
        let insets = ComponentLayout.pageInsets(viewportWidth: width)
        VStack(alignment: .leading, spacing: 24) {
            content
            VStack(alignment: .leading, spacing: 16) {
                StorebenchDivider()
                Text("Storebench").font(.sbCaption).foregroundStyle(StorebenchTheme.color("color-neutral"))
            }
        }
        .padding(.horizontal, insets.horizontal)
        .padding(.top, insets.top).padding(.bottom, 24)
        .frame(maxWidth: 1380, alignment: .leading).frame(maxWidth: .infinity)
        .background(StorebenchScrollCheckpoint().allowsHitTesting(false).accessibilityHidden(true))
    }
}

struct StorebenchPageHeader: View {
    let title: String, description: String
    var eyebrow = ""
    var actions: AnyView? = nil
    var feedback: AnyView? = nil
    /// A public help topic for the whole view; its (?) sits beside the title.
    var help = ""
    var body: some View {
        VStack(alignment: .leading, spacing: StorebenchTheme.space(2)) {
            if !eyebrow.isEmpty { StorebenchTextSlot(text: eyebrow, height: 18, font: .sbCaption.bold(), color: StorebenchTheme.color("color-accent-medium")) }
            if actions != nil || feedback != nil {
                StorebenchHeader { copy } actions: {
                    VStack(alignment: .trailing, spacing: StorebenchTheme.space(2)) {
                        if let actions { actions }
                        if let feedback { feedback }
                    }
                }
            } else { copy }
        }
    }
    private var copy: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: StorebenchTheme.space(2)) {
                StorebenchTextSlot(text: title, height: StorebenchTheme.measure("pageTitle"), tracking: -0.6, font: .sbLargeTitle, centered: true)
                    .fixedSize(horizontal: !help.isEmpty, vertical: false)
                if !help.isEmpty { StorebenchHelpButton(topic: help); Spacer(minLength: 0) }
            }
            StorebenchTextSlot(text: description, height: StorebenchTheme.measure("pageDescription"), color: StorebenchTheme.muted)
        }.accessibilityElement(children: .contain)
    }
}

/// Copy and commands occupy explicit slots, so every command is included in layout.
struct StorebenchHeader<Copy: View, Actions: View>: View {
    var stackAt: CGFloat = 760
    var actionTopInset: CGFloat = 0
    @ViewBuilder let copy: () -> Copy
    @ViewBuilder let actions: () -> Actions
    var body: some View {
        StorebenchHeaderLayout(stackAt: stackAt, actionTopInset: actionTopInset) {
            VStack(alignment: .leading, spacing: 0) { copy() }
            VStack(alignment: .trailing, spacing: StorebenchTheme.gap) { actions() }
        }
    }
}

private struct StorebenchHeaderLayout: Layout {
    var stackAt: CGFloat = 760
    var actionTopInset: CGFloat = 0
    private func geometry(_ width: CGFloat, subviews: Subviews) -> ComponentLayout.Header {
        let inset = width > stackAt ? actionTopInset : 0
        let actionWidth = min(width, min((2 * StorebenchTheme.actionWidth + StorebenchTheme.design.number("action-gap")), subviews.size(1, .unspecified).width))
        let tracks = ComponentLayout.header(width: width, copyHeight: 0, actionWidth: actionWidth, actionHeight: 0, stackAt: stackAt)
        let copy = subviews.size(0, ProposedViewSize(width: tracks.copy.width, height: nil))
        let actions = subviews.size(1, ProposedViewSize(width: tracks.actions.width, height: nil))
        return ComponentLayout.header(width: width, copyHeight: copy.height, actionWidth: actionWidth, actionHeight: actions.height + inset, stackAt: stackAt)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.usableWidth()
        return CGSize(width: width, height: geometry(width, subviews: subviews).height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let header = geometry(bounds.width, subviews: subviews)
        let inset = bounds.width > stackAt ? actionTopInset : 0
        for (index, frame) in [header.copy, header.actions].enumerated() {
            subviews.place(index, at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY + (index == 1 ? inset : 0)), proposal: ProposedViewSize(width: frame.width, height: frame.height - (index == 1 ? inset : 0)))
        }
    }
}

/// Flow tracks are measured by available width; long labels cannot grow the outer layout.
struct StorebenchFlow: Layout {
    enum Alignment { case leading, trailing }
    var spacing: CGFloat = 4
    var alignment: Alignment = .leading
    private func geometry(_ subviews: Subviews, width: CGFloat) -> ComponentLayout.Flow {
        let sizes = subviews.map { view in
            let intrinsic = view.sizeThatFits(.unspecified)
            let offered = min(max(0, intrinsic.width), max(0, width))
            let measured = view.sizeThatFits(ProposedViewSize(width: offered, height: nil))
            return CGSize(width: offered, height: measured.height)
        }
        return ComponentLayout.flow(width: width, sizes: sizes, spacing: spacing, trailing: alignment == .trailing)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.usableWidth()
        return CGSize(width: width, height: geometry(subviews, width: width).height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, frame) in geometry(subviews, width: bounds.width).frames.enumerated() {
            subviews.place(index, at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }
}

struct StorebenchTabs: View {
    let sections: [AppNavigation.Section], selected: AppNavigation.Section
    let select: (AppNavigation.Section) -> Void
    var body: some View {
        StorebenchNavigationTabs(items: sections.map { .init(id: $0, title: $0.title, icon: $0.designIcon, help: $0.purpose.isEmpty ? nil : $0.purpose) }, selected: selected, label: "App sections", select: select)
    }
}
