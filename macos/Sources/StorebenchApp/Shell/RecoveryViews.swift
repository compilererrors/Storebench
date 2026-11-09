import AppKit
import Observation
import StorebenchCore
import SwiftUI

@MainActor enum NativeRecoveryCatalog {
    static let shared = try? RecoveryGuidance.bundled()
    static let helpTopics = Set((try? HelpCatalog.bundled())?.topics.map(\.id) ?? [])
}

struct RecoveryNavigation: Sendable {
    let scope: RecoveryGuidance.Scope?
    let navigate: (@MainActor @Sendable (RecoveryGuidance.Action) -> Void)?
    static let empty = Self(scope: nil, navigate: nil)
}
struct RecoveryIntent: Sendable, Equatable {
    let id = UUID()
    let action: RecoveryGuidance.Action
}
private struct RecoveryNavigationKey: EnvironmentKey { static let defaultValue = RecoveryNavigation.empty }
private struct RecoveryIntentKey: EnvironmentKey { static let defaultValue: RecoveryIntent? = nil }
extension EnvironmentValues {
    var recoveryNavigation: RecoveryNavigation { get { self[RecoveryNavigationKey.self] } set { self[RecoveryNavigationKey.self] = newValue } }
    var recoveryIntent: RecoveryIntent? { get { self[RecoveryIntentKey.self] } set { self[RecoveryIntentKey.self] = newValue } }
}

/// Opening a settings tab protects only editors in that settings window; app editors stay mounted.
@MainActor @Observable final class RecoveryCoordinator {
    private(set) var request: RecoveryIntent?
    private(set) var aiRequest: UUID?
    private var aiConfirmedPolicy = EditorProtectionPolicy()
    private var confirmedPolicy = EditorProtectionPolicy()
    @ObservationIgnored weak var settingsProtection: EditorProtection?
    @ObservationIgnored var selectedArea: RecoveryGuidance.Target.Area?
    @ObservationIgnored var selectedPane: SettingsNavigation.Pane?
    func openAI(onOpen: @escaping @MainActor () -> Void) {
        let proceed: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            let latest = settingsProtection?.policy ?? EditorProtectionPolicy()
            guard latest.navigationDecision != .wait else { return }
            aiConfirmedPolicy = latest; aiRequest = UUID(); onOpen()
        }
        if let settingsProtection, selectedPane != .ai { settingsProtection.requestLeaving(proceed) }
        else { proceed() }
    }
    func authorizeAI(_ id: UUID, current: EditorProtectionPolicy) -> Bool {
        guard aiRequest == id, current.navigationDecision != .wait else { return false }
        return selectedPane == .ai || aiConfirmedPolicy.allowsNavigation(after: current, discardConfirmed: true)
    }
    func consumeAI(_ id: UUID) { if aiRequest == id { aiRequest = nil } }
    private func decision(_ action: RecoveryGuidance.Action, _ current: EditorProtectionPolicy.Decision) -> EditorProtectionPolicy.Decision {
        selectedArea == action.target.area && current != .wait ? .ready : current
    }
    func open(_ action: RecoveryGuidance.Action, onOpen: (@MainActor () -> Void)? = nil) -> Bool {
        guard [.accounts, .storage, .help].contains(action.target.area) else { return false }
        if let topic = action.target.helpTopic, !NativeRecoveryCatalog.helpTopics.contains(topic) { return false }
        var opened = false
        let proceed: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            let latest = settingsProtection?.policy ?? EditorProtectionPolicy()
            guard action.allowed(current: nil, decision: decision(action, latest.navigationDecision), discardConfirmed: true) else { return }
            confirmedPolicy = latest; request = RecoveryIntent(action: action); opened = true; onOpen?()
        }
        if let settingsProtection, selectedArea != action.target.area { settingsProtection.requestLeaving(proceed) }
        else { proceed() }
        return opened
    }
    func authorize(_ id: UUID, current policy: EditorProtectionPolicy) -> Bool {
        guard let request, request.id == id else { return false }
        let current = decision(request.action, policy.navigationDecision)
        guard current == .ready ? policy.navigationDecision != .wait : confirmedPolicy.allowsNavigation(after: policy, discardConfirmed: true) else { return false }
        return request.action.allowed(current: nil, decision: current, discardConfirmed: true)
    }
    func consume(_ id: UUID) { if request?.id == id { request = nil } }
}

/// Shared native error/guidance presentation. Copy and support use only fixed public explanations.
struct RecoveryActions: View {
    let code: String?
    var module: RecoveryGuidance.Module? = nil
    var compact = false
    var showMessage = false
    /// In a compact row, also offers the error code to copy for support.
    var copyCode = false
    @Environment(\.recoveryNavigation) private var navigation
    @State private var errorExpanded = false
    private var safe: String { ReportingMessages.normalized(code) }
    private var guidance: RecoveryGuidance.Entry? {
        NativeRecoveryCatalog.shared?.entry(code, module: module) ?? NativeRecoveryCatalog.shared?.entry(safe, module: module)
    }
    private var contact: SupportContact? { try? SupportContact(info: Bundle.main.infoDictionary?.compactMapValues { $0 as? String } ?? [:]) }
    /// The form of the reply that caused this error, when Storebench saw it: status, type, kind and size only.
    private var reply: String? { ReplyDiagnostics.latest(forCode: safe) }

    var body: some View {
        if code != nil {
            VStack(alignment: .leading, spacing: StorebenchTheme.space(2)) {
                if showMessage {
                    HStack(alignment: .top, spacing: StorebenchTheme.space(1)) {
                    Text(guidance?.message ?? (ReportingMessages.values[code ?? ""] != nil ? NativeRecoveryCatalog.shared?.message(safe, module: module) ?? ReportingMessages.message(safe) : guidance?.status ?? ReportingMessages.message(safe)))
                        .font(.sbCallout).foregroundStyle(guidance?.neutral == true ? StorebenchTheme.muted : StorebenchTheme.ink).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    if let topic = guidance?.help.helpTopic { StorebenchHelpButton(topic: topic) }
                    }
                }
                if !compact, let reply {
                    HStack(alignment: .top, spacing: StorebenchTheme.space(1)) {
                        Text("What Apple sent: " + reply).font(.sbCaption).foregroundStyle(StorebenchTheme.muted).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        StorebenchInfoTip(title: "What Apple sent", text: "The form of Apple's last reply: HTTP status, content type, kind of data and size, or the report rule it broke. It never includes report rows, account details or Apple's message text, so it is safe to copy into an issue.")
                    }
                }
                if let guidance {
                    if compact {
                        StorebenchActionGroup {
                            guidanceButtons(guidance)
                            if copyCode { IssueCopyActions(code: safe, reply: nil, contact: nil, compact: true).id(safe) }
                        }
                    } else {
                        StorebenchSetupStep(number: 1, title: guidance.action, detail: guidance.status) { HStack(spacing: StorebenchTheme.space(2)) { guidanceButtons(guidance, guide: !(showMessage && guidance.help.helpTopic != nil)) } }
                        StorebenchSetupStep(number: 2, title: "Try again", detail: guidance.kind == .availability ? "Apple publishes reports on a schedule. Try again later; saved reports are kept." : "When step 1 is done, start the same action again. Finished work and saved data are kept.")
                        StorebenchSetupStep(number: 3, title: "Still not working?", detail: reply == nil ? "Copy the error code and send it to support. It contains no private information." : "Copy the issue details and send them to support. They name the error and the form of Apple's reply, with no private information.") {
                            IssueCopyActions(code: safe, reply: reply, contact: ReportingMessages.supportAvailable(code) ? contact : nil, compact: reply == nil).id(safe + (reply ?? ""))
                        }
                    }
                } else { IssueCopyActions(code: safe, reply: compact ? nil : reply, contact: ReportingMessages.supportAvailable(code) ? contact : nil, compact: compact).id(safe + (reply ?? "")) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    /// The guide button is left out when the message already carries its (?) help.
    @ViewBuilder private func guidanceButtons(_ entry: RecoveryGuidance.Entry, guide: Bool = true) -> some View {
        let action = entry.target.resolved(scope: navigation.scope), help = entry.help.resolved(scope: navigation.scope)
        if action != nil && navigation.navigate != nil {
            Button { if let action { navigation.navigate?(action) } } label: {
                if entry.target.area == .developerAccount { StorebenchLabel(entry.action, icon: "external") }
                else { Text(entry.action) }
            }.help(entry.status)
        } else if action == nil { Text("Select an app to open its recovery view.").font(.sbCaption).foregroundStyle(StorebenchTheme.muted) }
        if guide && help != nil && navigation.navigate != nil { Button(entry.guide) { if let help { navigation.navigate?(help) } }.help("Read the setup and recovery steps in " + entry.guide + ".") }
    }
}

private struct IssueCopyActions: View {
    let code: String
    let contact: SupportContact?
    let compact: Bool
    @State private var copy: IssueCopy
    init(code: String, reply: String? = nil, contact: SupportContact?, compact: Bool) { self.code = code; self.contact = contact; self.compact = compact; _copy = State(initialValue: IssueCopy(code: code, reply: reply)) }
    var body: some View {
        StorebenchActionGroup { actions }
        .task(id: copy.copied) {
            guard copy.copied != nil else { return }
            AccessibilityNotification.Announcement(copy.status).post()
            try? await Task.sleep(for: .seconds(2)); copy.clearCopied()
        }
        .sheet(isPresented: Binding(get: { copy.fallback != nil }, set: { if !$0 { copy.dismissFallback() } })) {
            StorebenchDialog(title: "Copy error details", height: 340, close: { copy.dismissFallback() }) {
                Text("Clipboard access is unavailable. Select this text and use Copy.").foregroundStyle(StorebenchTheme.muted)
                ScrollView { Text(copy.fallback ?? "").font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.accessibilityLabel("Text to copy")
            } actions: {
                Button("Done") { copy.dismissFallback() }.keyboardShortcut(.defaultAction)
            }
        }
    }
    @ViewBuilder private var actions: some View {
        Button { put(.code) } label: { CopyLabel(title: compact ? "Copy Error Code" : "Error code " + code, copied: copy.copied == .code) }.accessibilityLabel("Copy error code \(code)").help("\(code)\n\(ReportingMessages.message(code))\nClick to copy the complete code.")
        if !compact { Button { put(.details) } label: { CopyLabel(title: "Copy issue details", copied: copy.copied == .details) } }
        if let contact { StorebenchActionLink("Contact Support", destination: contact.support).help("Open the support page in your browser. Copy the error code first and paste it there; it contains no private information.") }
    }
    private func put(_ part: IssueCopy.Part) {
        guard let value = copy.begin(part) else { return }
        NSPasteboard.general.clearContents()
        copy.finish(part, success: NSPasteboard.general.setString(value, forType: .string))
    }
}

/// A copy command and its confirmation in one track, so the button keeps its width while "Copied" shows.
private struct CopyLabel: View {
    let title: String
    let copied: Bool
    var body: some View {
        ZStack {
            StorebenchLabel(title, icon: "copy").opacity(copied ? 0 : 1).accessibilityHidden(copied)
            StorebenchLabel("Copied", icon: "check").opacity(copied ? 1 : 0).accessibilityHidden(!copied)
        }.animation(.easeOut(duration: 0.15), value: copied)
    }
}

private struct StorebenchInlineDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            StorebenchDisclosureButton(isExpanded: Binding(get: { configuration.isExpanded }, set: { configuration.isExpanded = $0 }), compact: true) { configuration.label }
            if configuration.isExpanded { configuration.content.padding(.leading, 22) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
