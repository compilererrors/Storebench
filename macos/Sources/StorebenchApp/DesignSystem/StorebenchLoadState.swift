import StorebenchCore
import SwiftUI

enum StorebenchLoadPhase {
    case loading(String)
    case failed(String, retry: @MainActor () async -> Void)
    case ready
}

/// Loading and failure replace the content instead of showing it unavailable. Both keep fixed status tracks,
/// so a long message scrolls inside its track rather than moving the step.
/// With a placeholder, loading draws the content's final structure as neutral bars under its status, and a failure
/// keeps that footprint, so the content fills in place instead of pushing everything below it. Placeholder views stack
/// with the card body's spacing, like the content they stand in for.
struct StorebenchLoadState<Content: View, Placeholder: View>: View {
    let state: StorebenchLoadPhase
    @ViewBuilder let content: () -> Content
    @ViewBuilder let placeholder: () -> Placeholder
    init(state: StorebenchLoadPhase, @ViewBuilder content: @escaping () -> Content, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.state = state; self.content = content; self.placeholder = placeholder
    }
    var body: some View {
        switch state {
        case .loading(let message):
            // The real section around this shows; while its data is read only one status line stands here, never stand-in bars.
            StorebenchLoadingStatus(message: message, surface: false)
        case .failed(let message, let retry):
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: StorebenchTheme.gap) { placeholder() }.frame(maxWidth: .infinity, alignment: .leading).hidden().accessibilityHidden(true)
                VStack(alignment: .leading, spacing: StorebenchTheme.space(3)) {
                    StorebenchFeedback(text: message, height: StorebenchLoadPhase.statusHeight, error: true)
                    StorebenchActionGroup { StorebenchReadButton("Retry") { await retry() }.buttonStyle(StorebenchButtonStyle()) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        case .ready:
            content()
        }
    }
}

extension StorebenchLoadState where Placeholder == EmptyView {
    init(state: StorebenchLoadPhase, @ViewBuilder content: @escaping () -> Content) { self.init(state: state, content: content, placeholder: { EmptyView() }) }
}

/// Over a placeholder the status floats as a compact, centred panel inside the placeholder's top padding, so it never
/// covers a card edge and never moves the layout. Without a placeholder it keeps its fixed track in the flow.
struct StorebenchLoadingStatus: View {
    let message: String
    var surface = true
    var body: some View {
        if surface {
            HStack(alignment: .top, spacing: StorebenchTheme.space(2)) {
                StorebenchSpinner().frame(height: StorebenchProgressStyle.lineHeight(StorebenchTheme.design.number("font-size-body")))
                Text(message).font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, StorebenchTheme.space(2)).padding(.horizontal, StorebenchTheme.space(3))
            .background {
                RoundedRectangle(cornerRadius: StorebenchTheme.controlRadius).fill(StorebenchTheme.surface)
                    .shadow(color: StorebenchTheme.color("color-shadow").opacity(StorebenchTheme.design.number("panel-shadow-opacity")),
                            radius: StorebenchTheme.design.number("panel-shadow-radius"), y: StorebenchTheme.design.number("panel-shadow-offset"))
            }
            .overlay { RoundedRectangle(cornerRadius: StorebenchTheme.controlRadius).strokeBorder(StorebenchTheme.border) }
            .frame(maxWidth: 480).padding(.horizontal, StorebenchTheme.padding).padding(.top, StorebenchTheme.space(3))
            .accessibilityElement(children: .ignore).accessibilityLabel(message)
        } else {
            ProgressView { StorebenchTextSlot(text: message, height: StorebenchLoadPhase.statusHeight, font: nil, color: nil, live: true) }
                .progressViewStyle(StorebenchProgressStyle())
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension View {
    /// Keeps this view in place, drawn as bars under a loading status, while `message` is set. The view keeps its
    /// identity, so fields keep their state when the data arrives.
    func storebenchLoading(_ message: String?) -> some View {
        storebenchPlaceholder(message != nil).overlay(alignment: .top) { if let message { StorebenchLoadingStatus(message: message) } }
    }
    func storebenchPlaceholder(_ active: Bool = true) -> some View {
        redacted(reason: active ? .placeholder : []).allowsHitTesting(!active).accessibilityHidden(active)
    }
}

/// A record list still being read: one status line where the records will appear, instead of stand-in rows.
struct StorebenchCollectionPlaceholder: View {
    var rows = 3
    var icon = false
    var message = "Reading saved records…"
    var body: some View { StorebenchLoadingStatus(message: message, surface: false) }
}

/// A card still being read: the card surface with one status line inside, instead of stand-in headings and rows.
struct StorebenchPlaceholderCard: View {
    var rows = 3
    var message = "Reading saved data…"
    var body: some View {
        StorebenchLoadingStatus(message: message, surface: false)
            .padding(StorebenchTheme.padding).frame(maxWidth: .infinity, alignment: .leading)
            .background { RoundedRectangle(cornerRadius: StorebenchTheme.radius).fill(StorebenchTheme.surface) }
            .overlay { RoundedRectangle(cornerRadius: StorebenchTheme.radius).strokeBorder(StorebenchTheme.border) }
    }
}

extension StorebenchLoadPhase {
    static let statusHeight: CGFloat = 40
}

/// A step that needs an earlier one says which one, without a jump: the steps are worked through in order with Next and Back.
struct StorebenchStepLink: View {
    let sentence: String
    let phaseNumber: Int
    let phaseTitle: String
    var body: some View {
        StorebenchNotice(title: sentence, description: "Step \(phaseNumber): \(phaseTitle).", icon: "info") { EmptyView() }
    }
}

private struct ReleaseStepNavigationKey: EnvironmentKey { static var defaultValue: ((String) -> Void)? { nil } }
extension EnvironmentValues {
    /// Opens a release phase by its identifier; nil outside the release flow.
    var releaseStepNavigation: ((String) -> Void)? { get { self[ReleaseStepNavigationKey.self] } set { self[ReleaseStepNavigationKey.self] = newValue } }
}

private struct OpenReleaseStepKey: EnvironmentKey { static var defaultValue: ((String) -> Void)? { nil } }
extension EnvironmentValues {
    /// Opens Release at a phase from another section of the app; nil outside an app's workspace.
    var openReleaseStep: ((String) -> Void)? { get { self[OpenReleaseStepKey.self] } set { self[OpenReleaseStepKey.self] = newValue } }
}

/// The field or media a release check pointed to. It is highlighted until another one is chosen.
struct ReleaseFieldFocus: Equatable { let anchor: String, ticket = UUID() }
private struct ReleaseFieldFocusKey: EnvironmentKey { static var defaultValue: ReleaseFieldFocus? { nil } }
private struct ReleaseChecklistReturnKey: EnvironmentKey { static var defaultValue: (() -> Void)? { nil } }
extension EnvironmentValues {
    var releaseFieldFocus: ReleaseFieldFocus? { get { self[ReleaseFieldFocusKey.self] } set { self[ReleaseFieldFocusKey.self] = newValue } }
    /// Scrolls back to the step's list of things to fix; nil outside the release flow.
    var releaseChecklistReturn: (() -> Void)? { get { self[ReleaseChecklistReturnKey.self] } set { self[ReleaseChecklistReturnKey.self] = newValue } }
}

private struct PageScrollKey: EnvironmentKey { static var defaultValue: ((String, UnitPoint) -> Void)? { nil } }
private struct PageRevealKey: EnvironmentKey { static var defaultValue: ((String) -> Void)? { nil } }
extension EnvironmentValues {
    /// Scrolls the page to a view id with a visible animation; nil outside an app workspace.
    var pageScroll: ((String, UnitPoint) -> Void)? { get { self[PageScrollKey.self] } set { self[PageScrollKey.self] = newValue } }
    /// Brings an anchor to the middle of the page and keeps it there while the page restores its position and lays out, such as
    /// Send to Apple after Save prepared its review.
    var pageReveal: ((String) -> Void)? { get { self[PageRevealKey.self] } set { self[PageRevealKey.self] = newValue } }
}

private struct ReleaseStepHistoryKey: EnvironmentKey { static var defaultValue: Binding<String?>? { nil } }
extension EnvironmentValues {
    /// The Release step kept in Back and Forward history, so returning opens the same step.
    var releaseStepHistory: Binding<String?>? { get { self[ReleaseStepHistoryKey.self] } set { self[ReleaseStepHistoryKey.self] = newValue } }
}

/// A quiet frame around the field a release check opened. It sits outside the content, so showing it never moves the layout.
struct ReleaseFocusFrame: View {
    let visible: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: StorebenchTheme.radius)
            .fill(StorebenchTheme.color("color-surface-accent"))
            .overlay(RoundedRectangle(cornerRadius: StorebenchTheme.radius).strokeBorder(StorebenchTheme.color("color-border-accent")))
            .padding(-10).opacity(visible ? 1 : 0).allowsHitTesting(false).accessibilityHidden(true)
    }
}
