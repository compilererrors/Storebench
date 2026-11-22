import AppKit
import StorebenchCore
import SwiftUI

/// One command in a guide's step bar, such as Back, Next or the step's own Add for Review. Two commands are equal when they
/// look and behave the same, whatever closure runs them.
struct StorebenchStepCommand: Equatable {
    let title: String
    var running = "Preparing…"
    var busy = false
    /// Why the command cannot run now; nil when it can.
    var unavailable: String? = nil
    var primary = true
    var help = ""
    var controlID = ""
    let action: @MainActor () -> Void
    static func == (left: Self, right: Self) -> Bool {
        left.title == right.title && left.running == right.running && left.busy == right.busy && left.unavailable == right.unavailable
            && left.primary == right.primary && left.help == right.help && left.controlID == right.controlID
    }
    var runnable: Bool { !busy && unavailable == nil }
}

/// What the step bar shows for the open step of a guide: where the person is, what is still needed, and its commands.
struct StorebenchStepBarState: Equatable {
    /// The guide and step, so a guide that closes only removes its own bar.
    let id: String
    let title: String
    var detail = ""
    var back: StorebenchStepCommand?
    var next: [StorebenchStepCommand] = []
}

/// The page's step bar: the open guide step names itself here, and the page shows it in a bar fixed to its bottom edge.
/// SwiftUI draws the bar again only when what it shows changes; the latest commands are kept without drawing anything.
@MainActor @Observable final class StorebenchStepBarModel {
    private(set) var state: StorebenchStepBarState?
    @ObservationIgnored private var latest: StorebenchStepBarState?
    func show(_ next: StorebenchStepBarState) {
        latest = next
        if next != state { state = next }
    }
    func clear(_ id: String) {
        guard state?.id == id else { return }
        latest = nil; state = nil
    }
    /// The commands as the guide last described them, so a press always runs the current closure.
    func runBack() { if let back = latest?.back, back.runnable { back.action() } }
    func runNext() { if let next = latest?.next.last, next.runnable { next.action() } }
}

private struct StepBarKey: EnvironmentKey { static var defaultValue: StorebenchStepBarModel? { nil } }
extension EnvironmentValues {
    /// The page's fixed step bar; nil where the page has none, such as a dialog, so guides keep their commands in place.
    var stepBar: StorebenchStepBarModel? { get { self[StepBarKey.self] } set { self[StepBarKey.self] = newValue } }
}

/// A guide step's Back and Next: in the page's fixed bottom bar, or in place at the end of the step where the page has no bar.
struct StorebenchStepCommands: View {
    let state: StorebenchStepBarState
    @Environment(\.stepBar) private var bar
    var body: some View {
        if let bar { StepBarRegistrar(state: state, bar: bar).frame(width: 0, height: 0).accessibilityHidden(true) }
        else { StorebenchStepBarCommands(state: state) }
    }
}

/// Hands the open step to the page's bar on every update without drawing anything itself, and takes it away when the step closes.
private struct StepBarRegistrar: NSViewRepresentable {
    let state: StorebenchStepBarState
    let bar: StorebenchStepBarModel
    @MainActor final class Coordinator { var id: String?; weak var bar: StorebenchStepBarModel? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        if let previous = context.coordinator.id, previous != state.id { context.coordinator.bar?.clear(previous) }
        context.coordinator.id = state.id; context.coordinator.bar = bar
        let state = state, bar = bar, coordinator = context.coordinator
        // Outside SwiftUI's update, so changing the bar never edits state while a view is being drawn.
        Task { @MainActor in if coordinator.id == state.id { bar.show(state) } }
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        guard let id = coordinator.id, let bar = coordinator.bar else { return }
        coordinator.id = nil; bar.clear(id)
    }
}

/// The commands of a step, Back first, in their fixed trailing order.
struct StorebenchStepBarCommands: View {
    let state: StorebenchStepBarState
    var body: some View {
        StorebenchActionGroup(alignment: .trailing) {
            if let back = state.back { command(back) }
            ForEach(Array(state.next.enumerated()), id: \.offset) { _, next in command(next) }
        }
    }
    private func command(_ value: StorebenchStepCommand) -> some View {
        StorebenchCommand(title: value.title, running: value.running, busy: value.busy, unavailable: value.unavailable, primary: value.primary, action: value.action)
            .help(value.busy ? value.running : value.unavailable ?? (value.help.isEmpty ? value.title : value.help))
            .storebenchControlID(value.controlID.isEmpty ? "step-bar." + value.title.lowercased().replacingOccurrences(of: " ", with: "-") : value.controlID)
    }
}

/// The bar fixed to the bottom of a page while a guide is open: the step and what it still needs on the leading edge, and
/// Back and Next on the trailing edge. Its height never changes, and a review waiting to be sent is named in it, so the page
/// never shows two bars.
struct StorebenchStepBar: View {
    let model: StorebenchStepBarModel
    @Environment(\.readyReviews) private var reviews
    @Environment(\.workspaceWidth) private var width
    static let height: CGFloat = 64
    var body: some View {
        if let state = model.state {
            let insets = ComponentLayout.pageInsets(viewportWidth: width), entries = reviews?.entries ?? [], waiting = entries.first
            HStack(alignment: .center, spacing: StorebenchTheme.space(4)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title).font(.sbHeadline).foregroundStyle(StorebenchTheme.ink).lineLimit(1).truncationMode(.tail).help(state.title)
                    let detail = waiting != nil || reviews?.finished != nil ? ReadyReviews.text(entries, finished: reviews?.finished) : state.detail
                    Text(detail).font(.sbCaption).foregroundStyle(StorebenchTheme.muted).lineLimit(1).truncationMode(.tail).help(detail)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if waiting != nil || reviews?.finished?.complete == false {
                    StorebenchBackgroundWorkMark(entries: entries)
                    StorebenchSyncProgress(value: ReadyReviews.progress(entries), working: ReadyReviews.working(entries))
                    StorebenchCommand(title: ReadyReviews.command(entries, finished: reviews?.finished), running: "Opening…", busy: false,
                                      unavailable: ReadyReviews.unavailable(entries, finished: reviews?.finished), primary: false) { reviews?.go() }
                        .help("Show this review with its changes and its send command, or where to fix what stopped. Nothing is sent from this bar.")
                }
                StorebenchStepBarCommands(state: state)
            }
            .padding(.horizontal, insets.horizontal)
            .frame(maxWidth: 1380).frame(maxWidth: .infinity)
            .frame(height: Self.height)
            .background(StorebenchTheme.surface)
            .overlay(alignment: .top) { StorebenchDivider() }
            .overlay(alignment: .top) { StorebenchBackgroundWorkLine(entries: entries) }
            .storebenchControlID("page.step-bar")
            .shortcutAction(.previousStep, enabled: state.back?.runnable == true, priority: 20, identity: state.id) { model.runBack() }
            .shortcutAction(.nextStep, enabled: state.next.last?.runnable == true, priority: 20, identity: state.id) { model.runNext() }
            .modifier(OptionalFinishedSync(reviews: reviews))
            .onAppear { reviews?.coveredByStepBar = true }
            .onDisappear { reviews?.coveredByStepBar = false }
        }
    }
}

private struct OptionalFinishedSync: ViewModifier {
    let reviews: ReadyReviews?
    func body(content: Content) -> some View {
        if let reviews { content.modifier(StorebenchFinishedSync(reviews: reviews)) } else { content }
    }
}
