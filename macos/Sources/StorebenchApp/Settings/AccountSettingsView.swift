import StorebenchCore
import SwiftUI
import UniformTypeIdentifiers

struct AccountSettings: View {
    let model: LibraryModel
    var recoveryRequest: RecoveryIntent? = nil
    @State private var working: String?
    @State private var messages: [String: String] = [:]
    @State private var issueCodes: [String: String] = [:]
    @State private var connecting = false
    @State private var reconnecting: Account?
    private var connectedAccounts: [Account] { if case .unlocked(let accounts) = model.state { accounts } else { [] } }
    var body: some View {
        ScrollViewReader { scroll in
        StorebenchForm {
            StorebenchFormSection("Connected Apple accounts", help: "apple-connection") {
                if let reason = recoveryRequest?.action.target.accountRecovery,
                   let entry = NativeRecoveryCatalog.shared?.connection(reason == "auth" ? "apple_auth" : reason == "access" ? "apple_access" : "keychain") {
                    Text(entry.status).font(.sbHeadline)
                    Text(ReportingMessages.message(reason == "auth" ? "SB-APPLE-AUTH" : reason == "access" ? "SB-APPLE-ACCESS" : "SB-APPLE-KEYCHAIN")).font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
                    if let requested = recoveryRequest?.action.scope?.accountId,
                       connectedAccounts.contains(where: { $0.id == requested }) == false {
                        Text("The requested account is no longer connected. Choose the account you intend to recover.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
                    }
                }
                if case .unlocked(let accounts) = model.state {
                    StorebenchCollection(items: accounts, title: { $0.name }, empty: "No Apple account connected yet. Choose Connect Account… to add one.") { account in
                        VStack(alignment: .leading, spacing: 10) {
                            StorebenchTextSlot(text: account.name, height: StorebenchTheme.measure("sectionTitle"), font: .sbHeadline)
                            StorebenchTextSlot(text: "\(account.keyType == "team" ? "Team API key" : "Individual key") · Key ID \(account.keyId) · \(account.appIds.count) apps", height: 36, font: .sbCaption, color: StorebenchTheme.muted)
                            StorebenchFeedback(text: messages[account.id] ?? "", height: 48)
                            RecoveryActions(code: issueCodes[account.id])
                            StorebenchFormFooter { actions(account) }
                        }.padding(.vertical, 6).id("account-\(account.id)")
                    }
                }
                if model.session != nil {
                    StorebenchFormFooter {
                        Button("Connect Account…") { if working == nil { connecting = true } }.help("Connect Apple Account").accessibilityLabel("Connect Apple Account")
                            .buttonStyle(StorebenchButtonStyle(.primary)).storebenchWorking(working != nil)
                    }
                }
            }
            StorebenchFormSection("Credential storage and connection help") {
                if model.writer.usesKeychain { Text("If macOS asks to access Storebench credentials, choose Always Allow. After a failed Keychain request, unlock your login keychain and choose Retry Keychain Access for the affected account.") }
                else { Text("Credentials are encrypted with your Storebench password. Storebench does not access Keychain. Sign out and unlock again if storage protection changed in another session.") }
                Text("Reconnect This Key verifies the original Key ID and issuer, then replaces its saved private key. Saved app history and drafts remain available. To use a different Key ID, connect another account.")
                Text("An individual key uses your app access. A team key needs its Issuer ID. If Apple refuses the connection, check in App Store Connect: the key's role and active status under Users and Access → Integrations (an individual key under your name → Edit Profile), app access under Users and Access → People and agreements under Business → Agreements.")
                StorebenchActionLink("Open in Browser", destination: URL(string: "https://appstoreconnect.apple.com")!, help: "Open App Store Connect")
            }.font(.sbCallout)
        }.storebenchWorking(working != nil)
            .task(id: recoveryRequest?.id) {
                guard let accountId = recoveryRequest?.action.scope?.accountId,
                      connectedAccounts.contains(where: { $0.id == accountId }) else { return }
                await Task.yield(); guard !Task.isCancelled else { return }; scroll.scrollTo("account-\(accountId)", anchor: .top)
            }
            .trackUnsavedChanges(false, busy: working != nil)
            .sheet(isPresented: $connecting) {
                ConnectAccountView(model: model, canCancel: true, asDialog: true) { connecting = false }
            }
            .sheet(item: $reconnecting) { account in
                ReconnectAccountView(model: model, account: account) { reconnecting = nil }
            }
        }
    }
    @ViewBuilder private func actions(_ account: Account) -> some View {
        Button(working == account.id ? "Checking…" : "Check Connection") { Task { await run(account, action: "check") } }
            .help("Checks the key with Apple and updates the list of apps it can reach.")
        Button("Reconnect This Key") { if working == nil { reconnecting = account } }
            .storebenchWorking(working != nil)
        StorebenchMenu("More", icon: "settings") {
            Button("Test Connection") { Task { await run(account, action: "test") } }.help("Verify the key with Apple without changing the app list.")
            Button("Refresh Apps") { Task { await run(account, action: "refresh") } }.help("Update the list of apps this key can reach. Saved app history stays available.")
            if model.writer.usesKeychain { Button("Retry Keychain Access") { Task { await run(account, action: "retry") } }.help("Ask macOS again for access to this key in Keychain.") }
        }.storebenchWorking(working != nil)
    }
    private func run(_ account: Account, action: String) async {
        guard working == nil, let session = model.session else { return }
        working = account.id; issueCodes[account.id] = nil; defer { working = nil }
        do {
            switch action {
            case "retry":
                try await session.retryKeychainAccess(accountId: account.id, writer: model.writer)
                messages[account.id] = "Keychain access can be tried again. Choose Test Connection or retry your report download."
            case "refresh":
                let updated = try await session.refreshAccountApps(account, client: try await session.client(for: account))
                messages[account.id] = "\(updated.appIds.count) apps found. Saved app history remains available."
            case "test":
                try await session.testAccountConnection(account, client: try await session.client(for: account))
                messages[account.id] = "Connection verified."
            default:
                if model.writer.usesKeychain { try? await session.retryKeychainAccess(accountId: account.id, writer: model.writer) }
                let client = try await session.client(for: account)
                try await session.testAccountConnection(account, client: client)
                let updated = try await session.refreshAccountApps(account, client: client)
                messages[account.id] = "Connection verified. \(updated.appIds.count) \(updated.appIds.count == 1 ? "app" : "apps") found."
            }
            await model.reloadAccounts()
        } catch { issueCodes[account.id] = RecoveryIssue.apple(error); messages[account.id] = accountMessage(error); await model.reloadAccounts() }
    }
}

struct ReconnectAccountView: View {
    let model: LibraryModel, account: Account, done: () -> Void
    @State private var privateKey = ""
    @State private var fileName = ""
    @State private var choosing = false
    @State private var working = false
    @State private var status = ""
    @State private var issueCode: String?
    @State private var protection = EditorProtection()
    var body: some View {
        StorebenchDialog(title: "Reconnect This Key", height: 600, busy: working, close: { if protection.allowLeaving() { privateKey = ""; done() } }) {
                StorebenchTextSlot(text: account.name, height: StorebenchTheme.measure("sectionTitle"), font: .sbHeadline)
                StorebenchTextSlot(text: "Key ID \(account.keyId)\(account.issuerId.map { " · Issuer ID \($0)" } ?? "")", height: 54, font: .sbCallout)
                Text("Choose the original downloaded P-256 .p8 file for this key. Storebench verifies app access before replacing the private key in your selected encrypted credential storage. Saved app selections, history and drafts remain available.")
                    .font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
                HStack {
                    Button("Choose File…") { if !working { choosing = true } }.storebenchWorking(working)
                    Text(fileName.isEmpty ? "No private key selected" : fileName).lineLimit(1).truncationMode(.middle).help(fileName.isEmpty ? "Choose the original App Store Connect API key file" : fileName)
                }
                StorebenchFeedback(text: status, height: 64)
                RecoveryActions(code: issueCode)
        } actions: {
                StorebenchActionGroup(alignment: .trailing) {
                    Button("Cancel") { if !working, protection.allowLeaving() { privateKey = ""; done() } }.storebenchWorking(working)
                    if working || !privateKey.isEmpty {
                        Button { Task { await reconnect() } } label: { StorebenchBusyLabel("Verify and Reconnect", loading: "Verifying…", busy: working) }
                            .buttonStyle(StorebenchButtonStyle(.primary)).storebenchWorking(working)
                    }

                }
        }.interactiveDismissDisabled(working || !privateKey.isEmpty)
            .trackUnsavedChanges(!privateKey.isEmpty, busy: working)
            .environment(\.editorProtection, protection)
            .background(EditorWindowGuard(protection: protection).frame(width: 0, height: 0))
            .onDisappear { privateKey = "" }
            .fileImporter(isPresented: $choosing, allowedContentTypes: [UTType(filenameExtension: "p8") ?? .data, .data]) { result in
                guard case .success(let url) = result else { return }
                let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do { privateKey = try AppleAccountInputs.privateKeyFile(url); fileName = url.lastPathComponent; issueCode = nil; status = "" }
                catch { privateKey = ""; fileName = ""; issueCode = nil; status = (error as? AccountFailure ?? .invalid).message }
            }
    }
    private func reconnect() async {
        guard !working, let session = model.session else { return }
        working = true; issueCode = nil
        do {
            try await session.reconnectAccount(account, privateKeyPEM: privateKey, writer: model.writer)
            privateKey = ""; working = false; await model.reloadAccounts(); done()
        } catch { issueCode = RecoveryIssue.apple(error); status = accountMessage(error); working = false; await model.reloadAccounts() }
    }
}

func accountMessage(_ error: Error) -> String {
    if let code = RecoveryIssue.apple(error) { return ReportingMessages.message(code) }
    if let failure = error as? AccountFailure { return failure.message }
    if let failure = error as? CredentialAccessFailure { return failure.message }
    if error is CredentialVault.Failure || error is VaultWriter.Failure || error as? ReviewsFailure == .noKey { return AccountFailure.keychain.message }
    return AccountFailure.importFailed.message
}
