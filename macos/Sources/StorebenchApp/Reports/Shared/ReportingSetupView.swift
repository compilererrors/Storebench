import StorebenchCore
import SwiftUI

/// Shared Sales/Finance connection controls. Inputs stay in memory until verified; tokens are never shown in status.
struct ReportingSetupView: View {
    @Environment(LibraryModel.self) private var model
    @Environment(\.recoveryIntent) private var recoveryIntent
    @Environment(\.confirmDestructive) private var confirm
    @Environment(\.reportToolsExpanded) private var toolsExpanded
    @State private var focusedRequest: UUID?
    private enum ConnectionField: Hashable { case vendor, token }
    @FocusState private var focused: ConnectionField?
    let account: Account, app: Account.App, session: WorkspaceSession?
    @Binding var source: ReportingSource
    let disabled: Bool, onReady: (Bool) -> Void, onBusy: (Bool) -> Void
    var onUseFile: (() -> Void)? = nil
    @State private var baseline: ReportingConnectionState?
    @State private var token = ""
    @State private var vendor = ""
    @State private var savedVendor = ""
    @State private var accounts: [ReporterAccount] = []
    @State private var vendors: [String] = []
    @State private var selectedAccount = ""
    @State private var selectedVendor = ""
    @State private var working = false
    @State private var issueCode: String?
    @State private var status = "Reading reporting connection…"
    @State private var operation: Task<Void, Never>?
    @State private var contextId = UUID()
    @State private var replacing = false
    private var writer: VaultWriter { model.writer }
    private var dirty: Bool { !token.isEmpty || vendor != savedVendor }
    private var ready: Bool {
        guard !working, let baseline else { return false }
        return source == .reporter ? baseline.connection?.reporter != nil : account.keyType == "team" && !savedVendor.isEmpty && vendor == savedVendor
    }
    private var connectionFocusReady: Bool {
        guard let action = recoveryIntent?.action, action.target.opensConnection,
              let scope = try? RecoveryGuidance.Scope(accountId: account.id, appId: app.id) else { return false }
        return toolsExpanded && !disabled && !working && baseline != nil && ReportNavigation.Tools.requested(action, current: scope, area: action.target.area)
    }
    private var connected: ReportingConnection.Reporter? { replacing ? nil : baseline?.connection?.reporter }
    var body: some View {
        Card(title: "Reporting connection", subtitle: connected != nil || (source == .api && !savedVendor.isEmpty)
             ? "Sales, Finance and Analytics downloads use this connection."
             : "Sales, Finance and Analytics downloads need reporting access. Connect once; Storebench keeps the connection in your encrypted credential storage.",
             help: "reporter", actions: connectionMenu) {
            if account.keyType == "team" {
                StorebenchChoicePicker("Report source", selection: $source, options: [(ReportingSource.reporter, "Apple Reporter"), (.api, "App Store Connect API · team key")])
                    .storebenchFormColumn().storebenchWorking(disabled || working)
            }
            if source == .api {
                if baseline != nil {
                    StorebenchInputActions {
                        StorebenchTextField("Vendor number", text: $vendor, hint: "6–20 digits.", placeholder: "6–20 digits")
                            .info("In App Store Connect, click Reports at the top of the page. Your vendor number is at the top left, under your legal entity name.")
                            .focused($focused, equals: .vendor).storebenchWorking(disabled || working)
                    } actions: {
                        if vendor != savedVendor && ReportingConnection.validVendor(vendor.trimmingCharacters(in: .whitespacesAndNewlines)) {
                            Button("Save Vendor Number") { if !disabled, !working { operation = Task { await saveVendor() } } }.storebenchWorking(disabled || working)
                        }
                    }
                }
            } else if let connected {
                HStack(spacing: StorebenchTheme.space(2)) {
                    StorebenchIcon(name: "check", size: 16).foregroundStyle(StorebenchTheme.color("color-success"))
                    Text("Connected").font(.sbCallout.weight(.semibold))
                    Text("Reporting account \(connected.accountNumber) · vendor \(connected.vendorNumber)").font(.sbCallout).foregroundStyle(StorebenchTheme.muted).textSelection(.enabled)
                }.accessibilityElement(children: .combine)
            } else if baseline != nil {
                tokenEntry
            }
            StorebenchFeedback(text: status, height: 68)
            RecoveryActions(code: issueCode)
            StorebenchFormFooter {
                if issueCode != nil, !working, session != nil { Button("Try Again") { if !disabled { operation = Task { await retry() } } }.storebenchWorking(disabled) }
                Button("Read Connection") {
                    if EditorProtection.confirm(working ? .wait : dirty ? .confirmDiscard : .ready) { replacing = false; operation = Task { await load(reset: true) } }
                }.accessibilityLabel("Read Current Connection").storebenchWorking(working || disabled).help("Read the saved reporting connection again. Unsaved entries are cleared.")
                if writer.usesKeychain && session != nil { Button("Retry Keychain") { if !working, !disabled { operation = Task { await retryKeychain() } } }.accessibilityLabel("Retry Keychain Access").storebenchWorking(working || disabled).help("Ask macOS again for access to the saved Reporter token in Keychain.") }
                if working { Button("Stop Waiting") { operation?.cancel(); issueCode = nil; status = "Stopping. Any completed connection save is kept." } }
                if let onUseFile {
                    Button(working ? "Stop, Use a File" : "Use a Report File") {
                        operation?.cancel()
                        if working { issueCode = nil; status = "Stopping. Any completed connection save is kept." }
                        onUseFile()
                    }.accessibilityLabel(working ? "Stop and Use a Report File" : "Use a Report File").storebenchWorking(disabled).help("Import a report file you downloaded from App Store Connect instead of downloading it here.")
                }
            }
        }.id("reporting-connection").trackUnsavedChanges(dirty, busy: working)
            .task(id: ReportFocusID(request: recoveryIntent?.id, enabled: connectionFocusReady)) {
                guard connectionFocusReady, let request = recoveryIntent?.id, focusedRequest != request else { return }
                if source == .reporter, baseline?.connection?.reporter != nil { replacing = true; token = ""; clearChoices() }
                await Task.yield()
                guard !Task.isCancelled else { return }; focused = source == .api ? .vendor : .token; focusedRequest = request
            }
            .onChange(of: source) { onReady(ready) }
            .onChange(of: vendor) { onReady(ready) }
            .task(id: "\(account.id):\(app.id)") {
                contextId = UUID(); operation?.cancel(); operation = nil; working = false
                baseline = nil; token = ""; vendor = ""; savedVendor = ""; replacing = false; clearChoices()
                await load(reset: true)
            }
            .onDisappear { contextId = UUID(); operation?.cancel(); token = ""; onReady(false); onBusy(false) }
    }
    private var connectionMenu: AnyView? {
        guard source == .reporter, connected != nil else { return nil }
        return AnyView(StorebenchMenu("Connection", icon: "settings") {
            Button("Replace Reporter Token…") { replacing = true; token = ""; clearChoices(); issueCode = nil; status = "" }
            Button("Disconnect Reporter", role: .destructive) {
                guard confirm(.disconnectReporter, title: "Disconnect Reporter?", message: "Storebench stops using the Reporter token for this account. Saved reports remain available; downloading new ones needs a token again.", action: "Disconnect") else { return }
                operation = Task { await disconnect() }
            }
        }.storebenchWorking(disabled || working).frame(maxWidth: StorebenchTheme.actionWidth))
    }
    @ViewBuilder private var tokenEntry: some View {
        StorebenchSetupStep(number: 1, title: "Open Sales and Trends Reports", detail: "Sign in to App Store Connect, click Trends at the top, then Sales and Trends Reports in the left sidebar.", path: .salesAndTrendsReports) {
            StorebenchActionLink("Open in Browser", destination: URL(string: "https://appstoreconnect.apple.com")!, help: "Open App Store Connect")
        }
        StorebenchSetupStep(number: 2, title: "Generate Reporter Token", detail: "At the top right, click the question mark (?) beside About Reports, then Generate Reporter Token, and copy it. The token is separate from your .p8 key and your Apple Account password, and expires after 180 days.", path: .reporterToken)
        StorebenchSetupStep(number: 3, title: "Paste the token and connect", detail: "Storebench checks reporting access before it saves the token. If Apple returns several accounts or vendors, choose the one that owns this app.") {
            StorebenchSecureField(replacing ? "New Reporter token" : "Reporter token", text: $token).labelsHidden()
                .accessibilityLabel("Reporter access token").focused($focused, equals: .token).storebenchFormColumn()
                .onChange(of: token) { clearChoices(); if token.utf16.count > 200 { token = String(token.prefix(200)) } }
                .storebenchWorking(disabled || working)
        }
        if !accounts.isEmpty {
            StorebenchPicker("Reporting account", selection: Binding(get: { selectedAccount }, set: { selectedAccount = $0; vendors = []; selectedVendor = "" })) {
                SelectionOption("Choose account", value: "")
                selectionOptions(accounts) { item in SelectionOption("\(item.name) · \(item.number)", value: item.number) }
            }.storebenchFormColumn().storebenchWorking(disabled || working)
        }
        if !vendors.isEmpty {
            StorebenchPicker("Reporting vendor", selection: $selectedVendor) {
                SelectionOption("Choose vendor", value: "")
                selectionOptions(vendors) { SelectionOption($0, value: $0) }
            }.storebenchFormColumn().storebenchWorking(disabled || working)
        }
        StorebenchActionGroup {
            if working || !token.isEmpty && (accounts.isEmpty || !selectedAccount.isEmpty) && (vendors.isEmpty || !selectedVendor.isEmpty) {
                Button(working ? "Verifying…" : !vendors.isEmpty ? "Connect Vendor" : !accounts.isEmpty ? "Continue" : "Connect Reporter") { if !disabled, !working { operation = Task { await connect() } } }.help(working ? "Verifying…" : !vendors.isEmpty ? "Connect Selected Vendor" : !accounts.isEmpty ? "Continue with Account" : "Connect Reporter").accessibilityLabel(working ? "Verifying…" : !vendors.isEmpty ? "Connect Selected Vendor" : !accounts.isEmpty ? "Continue with Account" : "Connect Reporter")
                    .buttonStyle(StorebenchButtonStyle(.primary)).storebenchWorking(disabled || working)
            }
            if !accounts.isEmpty { Button("Clear Selections") { if !disabled, !working { clearChoices(); issueCode = nil; status = "Selections cleared. Connect again to read current choices." } }.storebenchWorking(disabled || working) }
            if replacing { Button("Cancel") { if !working { replacing = false; token = ""; clearChoices(); status = "" } }.storebenchWorking(working) }
        }
    }
    private func clearChoices() { accounts = []; vendors = []; selectedAccount = ""; selectedVendor = "" }
    private func setWorking(_ value: Bool) { working = value; onBusy(value); onReady(ready) }
    private func accept(_ value: ReportingConnectionState) { baseline = value; savedVendor = value.connection?.vendorNumber ?? ""; vendor = savedVendor; onReady(ready) }
    private func load(reset: Bool) async {
        guard !working, let session else { onReady(false); return }
        let context = contextId
        setWorking(true); defer { if contextId == context { setWorking(false) } }
        if reset { token = ""; clearChoices() }
        do {
            let value = try await session.reportingConnection(account: account, appId: app.id)
            try Task.checkCancellation(); guard contextId == context else { return }
            if baseline == nil { source = value.connection?.reporter != nil || account.keyType == "individual" ? .reporter : .api }
            accept(value); issueCode = nil; status = value.connection == nil ? "Choose a reporting source and connect." : "Saved reporting connection read."
        } catch { if contextId == context, !Task.isCancelled { baseline = nil; issueCode = RecoveryIssue.reporter(error); status = reportingSetupMessage(error) } }
    }
    private func connect() async {
        guard !working, let session, let baseline else { return }
        let context = contextId
        setWorking(true); defer { if contextId == context { setWorking(false) } }
        do {
            let result = try await session.connectReporter(account: account, appId: app.id, token: token, baseline: baseline, selectedAccount: selectedAccount, selectedVendor: selectedVendor, writer: writer)
            try Task.checkCancellation(); guard contextId == context else { return }
            switch result {
            case .chooseAccount(let choices): accounts = choices; selectedAccount = ""; vendors = []; selectedVendor = ""; issueCode = nil; status = "Choose the reporting account that owns this app, then continue."
            case .chooseVendor(let choices, let number, let choicesVendors): accounts = choices; selectedAccount = number; vendors = choicesVendors; selectedVendor = ""; issueCode = nil; status = "Choose the reporting vendor for this app, then connect."
            case .connected(let value): token = ""; replacing = false; clearChoices(); accept(value); issueCode = nil; status = "Reporter connected. Choose a report period and download."
            }
        } catch { if contextId == context, !Task.isCancelled { issueCode = RecoveryIssue.reporter(error); status = reportingSetupMessage(error) } }
    }
    private func saveVendor() async {
        guard !working, let session, let baseline else { return }
        let context = contextId
        setWorking(true); defer { if contextId == context { setWorking(false) } }
        do {
            let value = try await session.saveApiReportingVendor(account: account, appId: app.id, vendorNumber: vendor, baseline: baseline)
            try Task.checkCancellation(); guard contextId == context else { return }
            accept(value); issueCode = nil; status = "Vendor number saved for team API downloads."
        } catch { if contextId == context, !Task.isCancelled { issueCode = RecoveryIssue.reporter(error); status = reportingSetupMessage(error) } }
    }
    private func disconnect() async {
        guard !working, let session, let baseline else { return }
        let context = contextId
        setWorking(true); defer { if contextId == context { setWorking(false) } }
        do {
            let value = try await session.disconnectReporter(account: account, appId: app.id, baseline: baseline, writer: writer)
            try Task.checkCancellation(); guard contextId == context else { return }
            accept(value); issueCode = nil; status = "Reporter disconnected. Saved reports remain available."
        } catch { if contextId == context, !Task.isCancelled { issueCode = RecoveryIssue.reporter(error); status = reportingSetupMessage(error) } }
    }
    private func retryKeychain() async {
        guard !working, let session else { return }
        let context = contextId
        setWorking(true); defer { if contextId == context { setWorking(false) } }
        do {
            try await session.retryKeychainAccess(accountId: account.id, writer: writer)
            try Task.checkCancellation(); guard contextId == context else { return }
            issueCode = nil; status = "Keychain access can be tried again. Retry your connection or download explicitly."
        } catch { if contextId == context, !Task.isCancelled { issueCode = RecoveryIssue.reporter(error); status = reportingSetupMessage(error) } }
    }
    private func retry() async {
        if writer.usesKeychain, let session { try? await session.retryKeychainAccess(accountId: account.id, writer: writer) }
        await load(reset: true)
    }

}

func reportingSetupMessage(_ error: Error) -> String {
    if let failure = error as? ReporterSetupFailure { return failure.message }
    if let failure = error as? AccountFailure { return failure.message }
    if let failure = error as? CredentialAccessFailure { return failure.message }
    if error is CancellationError || (error as? URLError)?.code == .cancelled { return "Reporter setup was cancelled. Read the current connection before retrying; any completed save is kept." }
    let reply = ReplyDiagnostics.latest(.reporterSales).map { " Apple answered: \($0)." } ?? ""
    if let failure = error as? ReporterClient.Failure {
        switch failure {
        case .expiredToken:
            return "Apple did not accept this Reporter token. In App Store Connect, click Trends at the top, then Sales and Trends Reports in the left sidebar. Click the question mark (?) beside About Reports, choose Generate Reporter Token and paste the new token." + reply
        case .invalidToken: return ReporterSetupFailure.invalid.message
        case .access:
            return "Apple did not give this token access to Sales and Trends reports. The Apple Account that created it needs the Account Holder, Admin, Finance or Sales role, or Access to Reports. Check it under Users and Access → People in App Store Connect." + reply
        case .wrongAccount:
            return "Apple returned a different account or vendor for this token. Choose the account and vendor that own this app, then connect again." + reply
        case .serviceUnavailable: return "Apple's Reporter service is not answering right now. Try again in a few minutes; saved reports are kept." + reply
        case .unsupported, .size: return "Apple answered in a form Storebench does not recognise, so nothing was saved. Try again, or use a report file." + reply
        }
    }
    if let failure = error as? URLError {
        return failure.code == .notConnectedToInternet || failure.code == .networkConnectionLost || failure.code == .timedOut || failure.code == .cannotFindHost || failure.code == .cannotConnectToHost
            ? "Storebench could not reach Apple's Reporter service. Check the network connection, then try again."
            : "The connection to Apple's Reporter service failed (\(failure.code.rawValue)). Try again, or use a report file."
    }
    return ReporterSetupFailure.unavailable.message + reply
}
