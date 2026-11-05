import StorebenchCore
import SwiftUI

/// A numbered list of steps beside their content: each step shows its number, or a check once done, and its status in words.
struct StorebenchStepRail: View {
    struct Item: Identifiable {
        let id: String, number: Int, title: String, label: String
        let complete: Bool, current: Bool
    }
    let title: String
    let items: [Item]
    let selected: String
    let select: (String) -> Void
    private var completed: Int { items.filter(\.complete).count }

    var body: some View {
        VStack(alignment: .leading, spacing: StorebenchTheme.space(1)) {
            Text(title).font(.sbHeadline)
            Text("\(completed) of \(items.count) complete").font(.sbCaption).foregroundStyle(StorebenchTheme.muted).padding(.bottom, StorebenchTheme.space(2))
            ForEach(items) { item($0) }
        }
        .padding(StorebenchTheme.space(3))
        .background(StorebenchTheme.color("color-surface"), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain).accessibilityLabel("\(title), \(completed) of \(items.count) complete")
    }

    private func item(_ item: Item) -> some View {
        let selected = item.id == self.selected
        return Button { select(item.id) } label: {
            HStack(alignment: .top, spacing: StorebenchTheme.space(2)) {
                ZStack {
                    Circle().fill(StorebenchTheme.color(item.complete ? "color-success" : selected || item.current ? "color-accent" : "color-surface-accent-strong"))
                    if item.complete { StorebenchIcon(name: "check", size: 12).foregroundStyle(StorebenchTheme.color("color-on-accent")) }
                    else {
                        Text("\(item.number)").font(.sbCaption.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(StorebenchTheme.color(selected || item.current ? "color-on-accent" : "color-accent-muted"))
                    }
                }.frame(width: 24, height: 24).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.sbCallout.weight(selected ? .semibold : .regular)).fixedSize(horizontal: false, vertical: true)
                    Text(item.label).font(.sbCaption).fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(item.current ? StorebenchTheme.color("color-accent-deep") : StorebenchTheme.muted)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(StorebenchTheme.space(2))
            .background(selected ? StorebenchTheme.color("color-surface-accent-strong") : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(StorebenchPressStyle())
        .accessibilityLabel("Step \(item.number): \(item.title), \(item.label)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The step list on the left and the open step beside it; on narrow windows the list sits above the step.
struct StorebenchStepLayout: Layout {
    private let railWidth: CGFloat = 248, gap: CGFloat = 24, stackAt: CGFloat = 880
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 1000
        guard subviews.count == 2 else { return .zero }
        if width >= stackAt {
            let rail = subviews[0].sizeThatFits(.init(width: railWidth, height: nil)), pane = subviews[1].sizeThatFits(.init(width: width - railWidth - gap, height: nil))
            return CGSize(width: width, height: max(rail.height, pane.height))
        }
        let rail = subviews[0].sizeThatFits(.init(width: width, height: nil)), pane = subviews[1].sizeThatFits(.init(width: width, height: nil))
        return CGSize(width: width, height: rail.height + gap + pane.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        if bounds.width >= stackAt {
            subviews[0].place(at: bounds.origin, proposal: .init(width: railWidth, height: nil))
            subviews[1].place(at: CGPoint(x: bounds.minX + railWidth + gap, y: bounds.minY), proposal: .init(width: bounds.width - railWidth - gap, height: nil))
        } else {
            let rail = subviews[0].sizeThatFits(.init(width: bounds.width, height: nil))
            subviews[0].place(at: bounds.origin, proposal: .init(width: bounds.width, height: nil))
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + rail.height + gap), proposal: .init(width: bounds.width, height: nil))
        }
    }
}

/// One step of a guide: what it is for, whether it is done, and what is still needed in plain words.
struct StorebenchGuideStep: Identifiable, Equatable {
    let id: String, number: Int, title: String, purpose: String
    var complete = false, current = false, optional = false
    /// What App Store Connect still lacks for this step, one short line each.
    var needed: [String] = []
    var label: String { complete ? "Done" : current ? "Next step" : optional ? "Optional" : "To do" }
}

/// A guide: the numbered steps beside the open one, its "Step N of M" heading with what is still needed, the step's own view,
/// and Back and Next, which stay in place on every step.
struct StorebenchStepPage<Content: View>: View {
    let title: String
    let steps: [StorebenchGuideStep]
    @Binding var selected: String?
    var actions: AnyView? = nil
    /// The guide this page is; its last step continues to the page the guide leads to.
    var guide: AppNavigation.Section? = nil
    @ViewBuilder let content: (String) -> Content
    @Environment(\.pageScroll) private var pageScroll

    /// The open step: the one chosen, else the first step not done, else the last.
    private var open: StorebenchGuideStep? {
        steps.first { $0.id == selected } ?? steps.first { $0.current } ?? steps.first { !$0.complete && !$0.optional } ?? steps.last
    }

    var body: some View {
        if let open {
            let index = steps.firstIndex(of: open) ?? 0
            StorebenchStepLayout {
                StorebenchStepRail(title: title, items: steps.map { .init(id: $0.id, number: $0.number, title: $0.title, label: $0.label, complete: $0.complete, current: $0.current) },
                                   selected: open.id, select: go)
                VStack(alignment: .leading, spacing: 20) {
                    Card(title: "Step \(open.number) of \(steps.count): \(open.title)", subtitle: open.purpose, actions: actions) {
                        if open.complete { StorebenchFact(label: "Status", value: "This step is done.", done: true) }
                        else if open.needed.isEmpty { StorebenchFact(label: "Status", value: open.optional ? "Optional. Skip it if you don't need it." : open.label) }
                        else {
                            StorebenchStatusList {
                                ForEach(open.needed, id: \.self) { StorebenchFact(label: "Needed", value: $0) }
                            }
                        }
                    }.id("guide-step-heading")
                    content(open.id).id("guide-step-\(open.id)")
                    StorebenchActionGroup(alignment: .trailing) {
                        StorebenchCommand(title: "Back", busy: false, unavailable: index == 0 ? "This is the first step." : nil, primary: false) { go(steps[index - 1].id) }
                        if index + 1 >= steps.count, let guide { StorebenchGuideExit(guide: guide) }
                        else { StorebenchCommand(title: "Next", busy: false, unavailable: index + 1 >= steps.count ? "This is the last step." : nil) { go(steps[index + 1].id) } }
                    }.help(index + 1 < steps.count ? "Continue to step \(steps[index + 1].number): \(steps[index + 1].title)" : "")
                }
            }
        }
    }

    private func go(_ id: String) {
        selected = id
        pageScroll?("guide-step-heading", .top)
    }
}

/// One step of a guide read from top to bottom: its number, title and state, what is still needed, and one command that shows or hides
/// the step's own cards below it.
struct StorebenchGuideSection: View {
    let step: StorebenchGuideStep
    let open: Bool
    let toggle: () -> Void
    var body: some View {
        Card(title: "\(step.number). \(step.title)", subtitle: step.purpose,
             actions: AnyView(StorebenchCommand(title: open ? "Hide" : "Show", busy: false, unavailable: nil, primary: false, action: toggle)
                .help(open ? "Hide this step's details" : "Show this step's details"))) {
            if step.complete { StorebenchFact(label: "Status", value: "Done", done: true) }
            else if step.needed.isEmpty { StorebenchFact(label: "Status", value: step.label) }
            else {
                StorebenchStatusList {
                    StorebenchFact(label: "Status", value: step.label)
                    ForEach(step.needed, id: \.self) { StorebenchFact(label: "Needed", value: $0) }
                }
            }
        }
    }
}

/// Next on a guide's last step: opens the page the finished guide leads to, such as Release after Set Up Pricing.
struct StorebenchGuideExit: View {
    let guide: AppNavigation.Section
    @Environment(\.openSection) private var openSection
    var body: some View {
        if let target = guide.afterGuide {
            StorebenchCommand(title: "To \(target.title)", busy: false, unavailable: openSection == nil ? "Open this app to continue." : nil) { openSection?(target) }
                .help("This is the last step. Continue in \(target.title).")
        } else {
            StorebenchCommand(title: "Next", busy: false, unavailable: "This is the last step.") {}
        }
    }
}

/// What an App Store Connect page still needs, at the top of its menu page: each part with a check once App Store Connect has it,
/// and one command that opens the guide for the rest.
struct StorebenchChecklist: View {
    struct Row: Identifiable {
        let id: String, title: String
        let done: Bool
        var optional = false
        var value: String { done ? "Done" : optional ? "Optional" : "Needed" }
    }
    let rows: [Row]
    /// The guide that walks through this page's task.
    var guide: AppNavigation.Section? = nil
    @Environment(\.openSection) private var openSection

    var body: some View {
        let missing = rows.filter { !$0.done && !$0.optional }.count
        Card(title: missing == 0 ? "Everything is set up" : missing == 1 ? "1 thing still needed" : "\(missing) things still needed",
             subtitle: missing == 0 ? "App Store Connect has what this page sets up." : "What App Store Connect still needs on this page. The guide takes you through it step by step.") {
            StorebenchStatusList {
                ForEach(rows) { row in StorebenchFact(label: row.title, value: row.value, done: row.done) }
            }
            if let guide, let openSection {
                StorebenchFormFooter {
                    Button("Open \(guide.title)") { openSection(guide) }.buttonStyle(StorebenchButtonStyle(missing == 0 ? .secondary : .primary))
                }
            }
        }
    }
}

private struct OpenSectionKey: EnvironmentKey { static var defaultValue: ((AppNavigation.Section) -> Void)? { nil } }
extension EnvironmentValues {
    /// Opens another page of the current app, such as a guide from its menu page; leaving unsaved changes is confirmed first.
    var openSection: ((AppNavigation.Section) -> Void)? { get { self[OpenSectionKey.self] } set { self[OpenSectionKey.self] = newValue } }
}
