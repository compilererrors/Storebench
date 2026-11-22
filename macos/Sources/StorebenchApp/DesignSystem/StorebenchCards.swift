import StorebenchCore
import SwiftUI

struct Card: View {
    let title: String, subtitle: String
    private let help: String
    private let icon: String
    private let content: AnyView
    private let actions: AnyView?
    private let accessory: AnyView?
    @Environment(\.gridCardRows) private var gridCardRows
    @Environment(\.settingsPresentation) private var settingsPresentation
    @Environment(\.disclosureIndent) private var disclosureIndent

    /// `help` names a public help topic; its (?) sits beside the title.
    init<Content: View>(title: String, subtitle: String, help: String = "", icon: String = "", actions: AnyView? = nil, accessory: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.subtitle = subtitle; self.help = help; self.icon = icon; self.actions = actions; self.accessory = accessory; self.content = AnyView(content())
    }

    /// Settings panes use the same cards as the workspace, so the whole app shares one look.
    var body: some View {
        StorebenchCardLayout(fillsRow: gridCardRows, spacing: settingsPresentation ? StorebenchTheme.space(2) : StorebenchTheme.measure("sectionSpacing")) {
            if let actions { StorebenchHeader { CardHeading(title: title, subtitle: subtitle, help: help, icon: icon, accessory: accessory) } actions: { actions } }
            else { CardHeading(title: title, subtitle: subtitle, help: help, icon: icon, accessory: accessory) }
            StorebenchCardBodyLayout(spacing: settingsPresentation ? StorebenchTheme.space(2) : StorebenchTheme.gap) { content.environment(\.gridCardRows, false) }
                .transformEnvironment(\.navigationPresentation) { $0 = $0?.scoped(title) }
        }
        .modifier(CardSurface())
        // A card shown by a disclosure keeps the page's grid: it takes back the room the disclosure gives its options.
        .padding(.leading, -disclosureIndent)
        .environment(\.disclosureIndent, 0)
        // A card taller than the page keeps its top in view while the user scrolls through it.
        .background { StorebenchStickySection(header: .init(id: "card." + title + "/" + subtitle, title: title, subtitle: subtitle, disclosure: false)) }
        // Content above the card changing height leaves it where the user sees it.
        .storebenchScrollAnchor()
    }
}

/// Grid rows offer their shared height to the body, keeping card headings at the top and commands at the bottom.
private struct StorebenchCardLayout: StorebenchTrackLayout {
    var fillsRow: Bool
    var spacing: CGFloat
    func tracks(width: CGFloat, minimumHeight: CGFloat, subviews: Subviews) -> StorebenchTracks {
        let heading = subviews.size(0, ProposedViewSize(width: width, height: nil)).height
        let top = heading + spacing
        let body = subviews.size(1, ProposedViewSize(width: width, height: nil)).height
        let height = max(top + body, minimumHeight)
        return StorebenchTracks(frames: [CGRect(x: 0, y: 0, width: width, height: heading),
                                         CGRect(x: 0, y: top, width: width, height: height - top)], height: height)
    }
}

struct StorebenchCardFooterKey: LayoutValueKey { static let defaultValue = false }

private struct StorebenchCardBodyLayout: StorebenchTrackLayout {
    var spacing: CGFloat
    var fillsRow: Bool { true }
    func tracks(width: CGFloat, minimumHeight: CGFloat, subviews: Subviews) -> StorebenchTracks {
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        let natural = heights.reduce(0, +) + CGFloat(max(0, subviews.count - 1)) * spacing
        let height = max(natural, minimumHeight)
        var y: CGFloat = 0, frames: [CGRect] = []
        var placedSpace = false
        for (index, view) in subviews.enumerated() {
            if view[StorebenchCardFooterKey.self], !placedSpace { y += height - natural; placedSpace = true }
            frames.append(CGRect(x: 0, y: y, width: width, height: heights[index]))
            y += heights[index] + spacing
        }
        return StorebenchTracks(frames: frames, height: height)
    }
}

private struct CardHeading: View {
    let title: String, subtitle: String
    var help = ""
    var icon = ""
    var accessory: AnyView? = nil
    var body: some View {
        HStack(alignment: .top, spacing: StorebenchTheme.space(2)) {
            if !icon.isEmpty {
                StorebenchIcon(name: icon, size: 14).foregroundStyle(StorebenchTheme.color("color-accent-muted"))
                    .frame(width: 24, height: 24)
                    .background(StorebenchTheme.color("color-surface-accent"), in: RoundedRectangle(cornerRadius: StorebenchTheme.controlRadius))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: StorebenchTheme.space(1)) {
                HStack(spacing: StorebenchTheme.space(2)) {
                    StorebenchHugWidth {
                        StorebenchTextSlot(text: title, height: StorebenchTheme.measure("sectionTitle"), font: .sbTitle3)
                    }.layoutPriority(1)
                    if !help.isEmpty { StorebenchHelpButton(topic: help) }
                    if !help.isEmpty || accessory != nil { Spacer(minLength: StorebenchTheme.space(2)) }
                    // The accessory is centred on the title's line without making that line taller, so a card with one
                    // keeps its title and description where every other card has them.
                    if let accessory { accessory.fixedSize().frame(height: StorebenchTheme.measure("sectionTitle")) }
                }
                if !subtitle.isEmpty { StorebenchTextSlot(text: subtitle, height: StorebenchTheme.measure("sectionDescription"), font: .sbCallout, color: StorebenchTheme.muted) }
            }
        }
    }
}

private struct CardSurface: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(StorebenchTheme.padding).frame(maxWidth: .infinity, alignment: .leading)
            .modifier(StorebenchPanelSurface())
    }
}

struct StorebenchPanelSurface: ViewModifier {
    func body(content: Content) -> some View {
        // The shadow belongs to the panel shape only. A shadow on the whole panel would be recomputed from all of its
        // content on every scroll frame and resize.
        content.background {
            RoundedRectangle(cornerRadius: StorebenchTheme.radius).fill(StorebenchTheme.surface)
                .shadow(color: StorebenchTheme.color("color-shadow").opacity(StorebenchTheme.design.number("panel-shadow-opacity")), radius: StorebenchTheme.design.number("panel-shadow-radius"), y: StorebenchTheme.design.number("panel-shadow-offset"))
        }
            .overlay(RoundedRectangle(cornerRadius: StorebenchTheme.radius).strokeBorder(StorebenchTheme.border))
    }
}

struct StorebenchCardSection<Content: View>: View {
    let title: String
    var description = ""
    var help = ""
    var accessory: AnyView? = nil
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(title).font(.sbHeadline).fixedSize(horizontal: false, vertical: true).layoutPriority(1)
                if !help.isEmpty { StorebenchHelpButton(topic: help) }
                StorebenchDivider()
                if let accessory { accessory.fixedSize() }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if !description.isEmpty { StorebenchAdaptiveText(text: description, color: StorebenchTheme.muted) }
            content()
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .contain).storebenchScrollAnchor()
    }
}

struct Fact: View {
    let title: String, value: String
    var hint = ""
    var compact = false
    var info = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: StorebenchTheme.space(1)) {
                StorebenchTextSlot(text: title, height: 18, font: .sbCallout.weight(.medium), color: StorebenchTheme.muted)
                if !info.isEmpty { StorebenchInfoTip(title: title, text: info) }
            }
            StorebenchTextSlot(text: value, height: 32, font: compact ? .sbHeadline : .sbMetric)
            if !compact { StorebenchTextSlot(text: hint, height: 28, font: .sbCaption, color: StorebenchTheme.subtle) }
        }
        .padding(.horizontal, 16).padding(.vertical, StorebenchTheme.space(3))
        .frame(maxWidth: .infinity, minHeight: StorebenchTheme.measure(compact ? "metricCompact" : "metricHeight"), maxHeight: .infinity)
        .modifier(StorebenchPanelSurface())
    }
}

/// Something inside a card that needs attention, such as why a Save stopped: set apart on a warning surface under its own
/// heading, so it never reads as part of the card's normal content.
struct StorebenchAttention<Content: View>: View {
    var title = "Attention"
    /// Shows what is already answered in the success colors, with a check instead of the warning.
    var done = false
    @ViewBuilder let content: () -> Content
    var body: some View {
        let tone = done ? "color-success" : "color-danger"
        VStack(alignment: .leading, spacing: StorebenchTheme.space(2)) {
            HStack(spacing: StorebenchTheme.space(2)) {
                StorebenchIcon(name: done ? "check" : "warning", size: 16).accessibilityHidden(true)
                Text(title).font(.sbHeadline)
            }.foregroundStyle(StorebenchTheme.color(tone))
            VStack(alignment: .leading, spacing: StorebenchTheme.space(2)) { content() }.font(.sbCallout).foregroundStyle(StorebenchTheme.ink)
        }.padding(StorebenchTheme.space(4)).frame(maxWidth: .infinity, alignment: .leading)
            .background(StorebenchTheme.color(tone + "-surface"), in: RoundedRectangle(cornerRadius: StorebenchTheme.measure("disclosureRadius")))
            .overlay(RoundedRectangle(cornerRadius: StorebenchTheme.measure("disclosureRadius")).strokeBorder(StorebenchTheme.color(tone + "-border")))
            .accessibilityElement(children: .contain).accessibilityLabel(title)
    }
}

struct StorebenchNotice<Action: View>: View {
    let title: String, description: String
    var icon = "release"
    @ViewBuilder let action: () -> Action
    var body: some View {
        StorebenchNoticeLayout {
            StorebenchIcon(name: icon, size: 20).foregroundStyle(StorebenchTheme.color("color-accent-medium"))
                .frame(maxWidth: 40, maxHeight: 40).background(StorebenchTheme.color("color-surface-accent-strong"), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                StorebenchTextSlot(text: title, height: 20, font: .sbHeadline)
                StorebenchTextSlot(text: description, height: 18, font: .sbCallout, color: StorebenchTheme.color("color-accent-slate"))
            }
            action()
        }.padding(StorebenchTheme.padding).modifier(StorebenchPanelSurface())
    }
}

/// The copy track grows with the description; icon and command stay level with its first lines, or the command moves below it when narrow.
private struct StorebenchNoticeLayout: StorebenchTrackLayout {
    func tracks(width: CGFloat, minimumHeight: CGFloat, subviews: Subviews) -> StorebenchTracks {
        let narrow = width <= 560, offset: CGFloat = narrow ? 44 : 56, icon: CGFloat = narrow ? 32 : 40
        // The command keeps its label on one line: its column is as wide as the label, within the shared bounds.
        let natural = subviews.size(2, .unspecified).width
        let command = natural > 0 ? min(max(natural, StorebenchTheme.actionMinWidth), StorebenchTheme.actionMaxWidth) : 0
        let textWidth = max(0, width - offset - (narrow || command == 0 ? 0 : 16 + command))
        let copy = max(narrow ? 78 : 60, subviews.size(1, ProposedViewSize(width: textWidth, height: nil)).height)
        let control = StorebenchTheme.controlHeight, actionWidth = min(narrow ? textWidth : width, command)
        return StorebenchTracks(frames: [CGRect(x: 0, y: ((narrow ? 78 : 60) - icon) / 2, width: icon, height: icon),
                                         CGRect(x: offset, y: 0, width: textWidth, height: copy),
                                         CGRect(x: narrow ? offset : width - actionWidth, y: narrow ? copy + 12 : (60 - control) / 2, width: actionWidth, height: control)],
                                height: narrow ? copy + 12 + control : copy)
    }
}

struct StorebenchWorkflowHeading<Leading: View>: View {
    let title: String
    var symbol: String? = nil
    @ViewBuilder let leading: () -> Leading
    var body: some View {
        HStack(spacing: StorebenchTheme.space(3)) {
            if let symbol {
                StorebenchIcon(name: symbol, size: 18).foregroundStyle(StorebenchTheme.color("color-accent-muted"))
                    .frame(width: StorebenchTheme.controlHeight, height: StorebenchTheme.controlHeight)
                    .background(StorebenchTheme.color("color-surface-accent"), in: RoundedRectangle(cornerRadius: StorebenchTheme.radius))
                    .accessibilityHidden(true)
            } else { leading() }
            StorebenchTextSlot(text: title, height: 42, font: .sbHeadline, color: StorebenchTheme.color("color-text-secondary"), centered: true)
        }
    }
}
extension StorebenchWorkflowHeading where Leading == EmptyView {
    init(title: String, symbol: String? = nil) { self.title = title; self.symbol = symbol; leading = { EmptyView() } }
}

struct StorebenchWorkflowCard<Heading: View, Action: View>: View {
    let description: String, feedback: String
    var progress: Double? = nil
    var total: Double = 7
    var accessory = false
    /// Optional contextual rows between the description and the reserved feedback track.
    var details: AnyView? = nil
    @ViewBuilder let heading: () -> Heading
    @ViewBuilder let action: () -> Action
    /// Live feedback keeps the shared fixed track: two caption lines below the progress bar, so updates never move the card.
    private var feedbackLines: CGFloat { 34 }
    private var progressHeight: CGFloat { StorebenchTheme.measure("workflowFeedback") - feedbackLines }
    var body: some View {
        StorebenchWorkflowLayout(accessory: accessory, details: details != nil) {
            VStack(alignment: .leading, spacing: 0) { heading() }
            StorebenchTextSlot(text: description, height: StorebenchTheme.measure("workflowDescription"), font: .sbCaption, color: StorebenchTheme.muted)
            if let details { details }
            if let progress {
                VStack(alignment: .leading, spacing: 0) {
                    ProgressView(value: progress, total: total).frame(height: progressHeight).accessibilityLabel("Sources checked")
                    StorebenchTextSlot(text: feedback, height: feedbackLines, font: .sbCaption, color: StorebenchTheme.muted, live: true)
                }
            } else {
                StorebenchTextSlot(text: feedback, height: StorebenchTheme.measure("workflowFeedback"), font: .sbCaption, color: StorebenchTheme.muted, live: true)
            }
            HStack(spacing: 0) { action() }.frame(height: StorebenchTheme.controlHeight)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .modifier(StorebenchPanelSurface())
    }
}

/// Measures the copy tracks; a taller grid row keeps the command on the bottom edge shared by its neighbours.
private struct StorebenchWorkflowLayout: StorebenchTrackLayout {
    let accessory: Bool
    var details = false
    var fillsRow: Bool { true }
    func tracks(width: CGFloat, minimumHeight: CGFloat, subviews: Subviews) -> StorebenchTracks {
        let reserved = ComponentLayout.workflowCard(width: width, accessory: accessory)
        func height(_ index: Int) -> CGFloat { subviews.size(index, ProposedViewSize(width: reserved.heading.width, height: nil)).height }
        let extra = details ? height(2) + StorebenchTheme.space(2) : 0
        let card = ComponentLayout.workflowCard(width: width, accessory: accessory, headingHeight: height(0), descriptionHeight: height(1), minimumHeight: max(0, minimumHeight - extra))
        guard details else { return StorebenchTracks(frames: [card.heading, card.description, card.feedback, card.action], height: card.height) }
        let rows = CGRect(x: card.feedback.minX, y: card.feedback.minY, width: card.feedback.width, height: height(2))
        return StorebenchTracks(frames: [card.heading, card.description, rows, card.feedback.offsetBy(dx: 0, dy: extra), card.action.offsetBy(dx: 0, dy: extra)], height: card.height + extra)
    }
}

struct StorebenchNavigationCard<Icon: View>: View {
    let title: String, description: String, action: String
    var tile = false
    var descriptionLines = 2
    /// Inside a card the row keeps the card's own left edge, so its icon lines up with the card's other content.
    var embedded = false
    let activate: () -> Void
    @ViewBuilder let icon: () -> Icon
    @State private var hovering = false
    var body: some View {
        Button(action: activate) {
            StorebenchNavigationLayout(tile: tile) {
                icon().frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 5) {
                    StorebenchTextSlot(text: title, height: StorebenchTheme.measure("navigationTitle"), font: .sbHeadline, centered: true)
                    StorebenchTextSlot(text: description, height: CGFloat(max(1, min(12, descriptionLines)) * 18), font: .sbCallout, color: StorebenchTheme.muted, centered: true)
                }.frame(maxHeight: .infinity, alignment: .center)
                HStack(spacing: 12) {
                    Text(action).font(.sbCallout.weight(.semibold)).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                    StorebenchIcon(name: "right")
                }.padding(.horizontal, 12).foregroundStyle(StorebenchTheme.color("color-accent-muted"))
            }.padding(.vertical, embedded ? StorebenchTheme.space(2) : StorebenchTheme.padding).padding(.horizontal, embedded ? 0 : StorebenchTheme.padding)
                .background(StorebenchTheme.hoverColor(hovering, resting: StorebenchTheme.surface))
                .overlay(StorebenchControlOutline(border: StorebenchTheme.hoverOutline(hovering), radius: StorebenchTheme.radius))
                .contentShape(Rectangle())
        }.buttonStyle(StorebenchPressStyle()).storebenchHover { hovering = $0 }.help(title + " · " + action)
            .accessibilityLabel(title + " · " + action).accessibilityHint(description)
    }
}

private struct StorebenchNavigationLayout: StorebenchTrackLayout {
    let tile: Bool
    func tracks(width: CGFloat, minimumHeight: CGFloat, subviews: Subviews) -> StorebenchTracks {
        let initial = ComponentLayout.navigationRow(width: width, textHeight: 0, tile: tile)
        let height = subviews.size(1, ProposedViewSize(width: initial.text.width, height: nil)).height
        let row = ComponentLayout.navigationRow(width: width, textHeight: height, tile: tile)
        return StorebenchTracks(frames: [row.icon, row.text, row.action], height: row.height)
    }
}

/// Content under a card list's row, such as previews or an empty state: below a divider and inset to the row's own padding,
/// so it lines up with the row's icon and never touches the list's edge.
struct StorebenchCardListSection<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StorebenchDivider()
            VStack(alignment: .leading, spacing: StorebenchTheme.gap) { content() }
                .padding(StorebenchTheme.padding).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct StorebenchCardList<Content: View>: View {
    var padded = false
    var spacing: CGFloat = 0
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content() }
            .padding(padded ? StorebenchTheme.padding : 0).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: StorebenchTheme.radius))
            .modifier(StorebenchPanelSurface())
    }
}
