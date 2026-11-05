import StorebenchCore
import SwiftUI

private struct ReportToolsExpandedKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var reportToolsExpanded: Bool { get { self[ReportToolsExpandedKey.self] } set { self[ReportToolsExpandedKey.self] = newValue } }
}

/// Content stays mounted when collapsed, keeping local reviews, editor protection and owned job polling.
struct ReportTools<Content: View>: View {
    let hasData: Bool?, area: RecoveryGuidance.Target.Area
    @ViewBuilder let content: Content
    @Environment(\.recoveryIntent) private var intent
    @Environment(\.recoveryNavigation) private var navigation
    @State private var state = ReportNavigation.Tools()
    var body: some View {
        VStack(alignment: .leading, spacing: state.expanded ? 16 : 0) {
            StorebenchDisclosureButton(isExpanded: Binding(get: { state.expanded }, set: { if state.expanded != $0 { state.toggle() } })) {
                Text("Download and import reports").font(.sbHeadline)
            }
            // The heading is drawn as a card, so it never floats on the page background; the tools open below it as their own cards.
            .padding(StorebenchTheme.padding).frame(maxWidth: .infinity, alignment: .leading)
            .background { RoundedRectangle(cornerRadius: StorebenchTheme.radius).fill(StorebenchTheme.surface) }
            .overlay { RoundedRectangle(cornerRadius: StorebenchTheme.radius).strokeBorder(StorebenchTheme.border) }
            content
                .environment(\.reportToolsExpanded, state.expanded)
                .frame(height: state.expanded ? nil : 0, alignment: .top)
                .clipped().opacity(state.expanded ? 1 : 0)
                .environment(\.isEnabled, state.expanded).allowsHitTesting(state.expanded).accessibilityHidden(!state.expanded)
        }.frame(maxWidth: .infinity, alignment: .leading).id("report-tools-\(area.rawValue)")
            .historyDisclosure("report-tools:" + area.rawValue, isExpanded: Binding(get: { state.expanded }, set: { if state.expanded != $0 { state.toggle() } }))
            .onChange(of: hasData, initial: true) { if let hasData { state.loaded(hasData: hasData) } }
            .onChange(of: intent?.id, initial: true) { state.open(intent?.action, current: navigation.scope, area: area) }
    }
}

struct ReportDownloadButton: View {
    let area: RecoveryGuidance.Target.Area
    @Environment(\.recoveryNavigation) private var navigation
    private var action: RecoveryGuidance.Action? { (try? ReportNavigation.downloads(area))?.resolved(scope: navigation.scope) }
    var body: some View {
        if action != nil && navigation.navigate != nil { Button("Go to Downloads") { if let action { navigation.navigate?(action) } } }
    }
}

struct ReportFocusID: Equatable { let request: UUID?, enabled: Bool }
private struct ReportFocus: ViewModifier {
    let field: String, available: Bool
    let focused: FocusState<Bool>.Binding
    @Environment(\.recoveryIntent) private var intent
    @Environment(\.recoveryNavigation) private var navigation
    @Environment(\.reportToolsExpanded) private var expanded
    @State private var fulfilled: UUID?
    private var enabled: Bool { ReportNavigation.Tools.focus(intent?.action, current: navigation.scope, field: field, expanded: expanded, available: available) }
    func body(content: Content) -> some View {
        content.focused(focused).task(id: ReportFocusID(request: intent?.id, enabled: enabled)) {
            guard enabled else { focused.wrappedValue = false; return }
            guard let request = intent?.id, fulfilled != request else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }; focused.wrappedValue = true; fulfilled = request
        }
    }
}
extension View {
    func reportFocus(_ field: String, available: Bool, focused: FocusState<Bool>.Binding) -> some View { modifier(ReportFocus(field: field, available: available, focused: focused)) }
}
