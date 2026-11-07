import StorebenchCore
import SwiftUI
import UniformTypeIdentifiers

/// This screen appears before any Keychain read, including existing installations.
struct StorageChoiceView: View {
    let model: LibraryModel
    var body: some View {
        StorebenchAuthScreen {
            StorebenchAuthCard(title: "Use Keychain?", message: "Choose how Storebench saves encryption keys and credentials. Your saved data and media are encrypted with either option.", wide: true) {
                StorebenchMetricGrid(maximumColumns: 2, minimumWidth: 260) {
                    StorebenchSetupOption(title: "Mac Keychain", description: "Unlock automatically with your Mac. macOS may ask for permission; choose Always Allow to remember it.", recommended: true) {
                        Button("Use Keychain") { Task { await model.selectStorage(.keychain) } }.buttonStyle(StorebenchButtonStyle(.primary))
                    }
                    StorebenchSetupOption(title: "Password without Keychain", description: "Encrypt keys and credentials with a Storebench password. Enter it when you open the app; it cannot be recovered.") {
                        Button("Use Password") { Task { await model.selectStorage(.password) } }.help("Use Password Without Keychain").accessibilityLabel("Use Password Without Keychain")
                    }
                    StorebenchSetupOption(title: "Explore first", description: "Look around with sample data before choosing storage or connecting Apple. Nothing is saved or sent to Apple.") {
                        Button("Load Sample Data") { Task { await model.openSampleData() } }.help("Explore Storebench with Fictional Apps").accessibilityLabel("Load Sample Data")
                    }
                }
                Text("If your existing data uses Keychain, choosing password storage offers an explicit copy step before accessing those saved keys.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
                StorebenchFeedback(text: model.lastError, error: true)
            }.frame(maxWidth: 760)
        }
    }
}

struct PasswordStorageMigrationView: View {
    let model: LibraryModel
    @State private var current = ""
    @State private var password = ""
    @State private var repeated = ""
    var body: some View {
        StorebenchAuthScreen {
            StorebenchAuthCard(title: "Keep your saved data", message: "Copy this workspace's encryption key and credentials from Keychain into password-encrypted storage. macOS may ask for access during this copy. Afterward Storebench uses your password and does not access Keychain.") {
                StorebenchSecureField("Current Storebench password, if you use one", text: $current)
                StorebenchSecureField("New Storebench password", text: $password)
                StorebenchSecureField("Repeat new password", text: $repeated)
                Text("Use 12 to 256 characters. The password cannot be recovered. Earlier copies remain in Keychain for older installations; this copy does not delete them.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
                StorebenchFeedback(text: model.lastError, error: true)
                if (12...256).contains(password.utf16.count) && password == repeated {
                    Button("Copy Saved Data") {
                        let previous = current.isEmpty ? nil : current, next = password
                        current = ""; password = ""; repeated = ""
                        Task { await model.migrateStorage(currentPassword: previous, newPassword: next) }
                    }.buttonStyle(StorebenchButtonStyle(.primary))
                }
                Button("Back") { model.reviewStorageChoice() }.help("Back to Storage Choice").accessibilityLabel("Back to Storage Choice")
            }
        }
    }
}

/// Setup uses the explicitly selected provider; password-only storage never accesses Keychain.
struct SetupView: View {
    let model: LibraryModel
    @State private var password = ""
    @State private var repeated = ""

    var body: some View {
        StorebenchAuthScreen {
            VStack(alignment: .leading, spacing: 20) {
                StorebenchAuthCard(title: model.writer.usesPasswordFile ? "Create your Storebench password" : "Set up Storebench", message: model.writer.usesPasswordFile ? "Your database key, Apple API keys, Apple ID sign-ins, reporting tokens and backup passphrases are encrypted locally. Storebench will not access Keychain." : "Storebench encrypts your saved data and keeps its encryption key and credentials in your Mac Keychain.") {
                    if model.writer.usesPasswordFile {
                        StorebenchSecureField("Storebench password", text: $password)
                        StorebenchSecureField("Repeat password", text: $repeated)
                        Text("Use 12 to 256 characters. You will need it when opening Storebench; it cannot be recovered.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
                        if (12...256).contains(password.utf16.count) && password == repeated {
                            Button("Create Storage") {
                                let value = password; password = ""; repeated = ""
                                Task { await model.setUp(password: value) }
                            }.help("Create Password Storage").accessibilityLabel("Create Password Storage").buttonStyle(StorebenchButtonStyle(.primary))
                        }
                    } else {
                        Button("Create Storage") { Task { await model.setUp(password: nil) } }.help("Create Encrypted Storage").accessibilityLabel("Create Encrypted Storage").buttonStyle(StorebenchButtonStyle(.primary))
                    }
                    StorebenchFeedback(text: model.lastError, error: true)
                    Button("Back") { model.reviewStorageChoice() }.help("Back to Storage Choice").accessibilityLabel("Back to Storage Choice")
                }
                RestoreBackupCard(model: model)
                Card(title: "Explore first", subtitle: "Look around with sample data before creating storage. Nothing is saved or sent to Apple, and you return here when you close it.") {
                    StorebenchFormFooter { Button("Load Sample Data") { Task { await model.openSampleData() } }.help("Explore Storebench with Fictional Apps").accessibilityLabel("Load Sample Data") }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
        }

    }
}

/// Connects an API key using the workspace's selected credential storage.
struct ConnectAccountView: View {
    @State private var issueCode: String?
    let model: LibraryModel, canCancel: Bool
    var asDialog = false
    let done: () -> Void
    @State private var keyType = "individual"
    @State private var name = ""
    @State private var keyId = ""
    @State private var issuerId = ""
    @State private var fileName = ""
    @State private var privateKey = ""
    @State private var choosing = false
    @State private var working = false
    @State private var status = ""
    @Environment(\.editorProtection) private var protection

    var body: some View {
        Group {
            if asDialog {
                StorebenchDialog(title: "Connect Apple account", wide: true, height: 760, inlineActions: true, busy: working, close: {
                    if protection?.allowLeaving() ?? true { privateKey = ""; done() }
                }) { connectionContent } actions: { EmptyView() }
            } else { ScrollView { connectionContent } }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [UTType(filenameExtension: "p8") ?? .data, .data]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let text: String
            do { text = try AppleAccountInputs.privateKeyFile(url) }
            catch { privateKey = ""; fileName = ""; keyId = ""; issueCode = nil; status = (error as? AccountFailure ?? .invalid).message; return }
            privateKey = text; fileName = url.lastPathComponent; issueCode = nil; status = ""
            // Filled from the original filename; check it against the ID shown by Apple.
            keyId = AppleAccountInputs.keyId(filename: fileName) ?? ""
        }
        .interactiveDismissDisabled(working || !privateKey.isEmpty || !name.isEmpty || !keyId.isEmpty || !issuerId.isEmpty)
        .trackUnsavedChanges(!privateKey.isEmpty || !name.isEmpty || !keyId.isEmpty || !issuerId.isEmpty, busy: working)
        .onDisappear { privateKey = "" }
    }

    private var connectionContent: some View {
            VStack(alignment: .leading, spacing: 20) {
                if !asDialog {
                    StorebenchPageHeader(title: "Connect your Apple apps", description: "Select your App Store Connect API key once. Storebench checks it, finds your apps, and saves it in your selected encrypted credential storage.")
                }
                Card(title: "Connect Apple account", subtitle: "Storebench reads and updates your apps with an App Store Connect API key. You create it once; Storebench never needs your Apple Account password.", help: "apple-connection") {
                    StorebenchSetupStep(number: 1, title: "Choose the key type", detail: "Most people use an individual key. A team key is for teams that share one key.", done: !privateKey.isEmpty) {
                        StorebenchChoicePicker("Key type", selection: $keyType, options: [("individual", "Individual key"), ("team", "Team API key")]).labelsHidden().storebenchFormColumn()
                        Text(keyType == "team" ? "A team key works for everyone in your team. It needs the Admin or App Manager role, and an issuer ID." : "An individual key acts with your own access to apps. It is the quickest way to start.")
                        .font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    StorebenchSetupStep(number: 2, title: "Create the key in App Store Connect",
                        detail: keyType == "team" ? "Click Users and Access at the top, then the Integrations tab. Select App Store Connect API in the left sidebar and the Team Keys tab, then click Generate API Key (or + if a key exists). Enter a name, choose App Manager or Admin under Access and click Generate." : "Click your name at the top right, then Edit Profile. Scroll down to Individual API Key and click Generate API Key.", done: !privateKey.isEmpty, path: keyType == "team" ? .teamKey : .individualKey) {
                        StorebenchActionLink("Open in Browser", destination: URL(string: keyType == "team" ? "https://appstoreconnect.apple.com/access/integrations/api" : "https://appstoreconnect.apple.com/")!, help: "Open App Store Connect")
                    }
                    StorebenchSetupStep(number: 3, title: "Download the key file", detail: "Right after creating the key, click Download, then Download in the dialog, to save its .p8 file. Apple lets you download it only once, so keep it somewhere private.", done: !privateKey.isEmpty)
                    StorebenchSetupStep(number: 4, title: "Choose the file here", detail: "Storebench fills in the Key ID from the file name. Check it against the Key ID shown in App Store Connect.", done: !privateKey.isEmpty && !keyId.trimmingCharacters(in: .whitespaces).isEmpty) {
                        HStack {
                            Button("Choose File…") { choosing = true }
                            Text(fileName.isEmpty ? "No file chosen" : fileName).foregroundStyle(StorebenchTheme.muted).lineLimit(1).truncationMode(.middle)
                        }.accessibilityElement(children: .contain).accessibilityLabel("Private key (.p8)")
                        StorebenchTextField("Key ID", text: $keyId, hint: "Filled in from the file name when possible.")
                        .info("The 10-character identifier App Store Connect shows next to the key, such as 2X9R4HXF34.")
                    }
                    if keyType == "team" {
                        StorebenchSetupStep(number: 5, title: "Copy the issuer ID", detail: "In Users and Access → Integrations → App Store Connect API → Team Keys, it is shown above the list of keys. Paste it here.", done: !issuerId.trimmingCharacters(in: .whitespaces).isEmpty, path: .issuerID) {
                            StorebenchTextField("Issuer ID", text: $issuerId, hint: "A long identifier with dashes.")
                            .info("Identifies your team. It is shown above the list of team keys under Users and Access → Integrations → App Store Connect API.")
                        }
                    }
                    StorebenchSetupStep(number: keyType == "team" ? 6 : 5, title: "Connect", detail: "Storebench checks the key with Apple, finds your apps and saves the key in your encrypted storage.") {
                        StorebenchTextField("Account name (optional)", text: $name, hint: "A local label that helps you tell your Apple accounts apart.")
                    }
                    StorebenchFeedback(text: status, height: 52)
                    RecoveryActions(code: issueCode)
                    StorebenchFormFooter {
                        if working || !privateKey.isEmpty && !keyId.trimmingCharacters(in: .whitespaces).isEmpty && !(keyType == "team" && issuerId.isEmpty) {
                            Button(working ? "Connecting…" : "Connect Account") { Task { await connect() } }.help(working ? "Connecting…" : "Connect Apple Account").accessibilityLabel(working ? "Connecting…" : "Connect Apple Account")
                                .buttonStyle(StorebenchButtonStyle(.primary)).controlSize(.large).storebenchWorking(working)
                        }
                        if canCancel { Button("Cancel") { if !working, protection?.allowLeaving() ?? true { privateKey = ""; done() } }.controlSize(.large).storebenchWorking(working) }
                    }
                }
                Text("Your Apple password stays with Apple. Connecting checks access and finds apps; publishing uses a separate review and approval.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
            }
            .padding(asDialog ? 0 : 28).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func connect() async {
        guard let session = model.session else { return }
        working = true; issueCode = nil; defer { working = false }
        do {
            let key = privateKey
            let account = try await session.connectAccount(name: name, keyType: keyType, issuerId: keyType == "team" ? issuerId.trimmingCharacters(in: .whitespaces) : nil,
                                                           keyId: keyId, privateKeyPEM: key, writer: model.writer)
            privateKey = ""; status = "Account connected. \(account.appIds.count) apps are ready to import."
            await model.reloadAccounts()
            done()
        } catch let failure as AccountFailure { issueCode = RecoveryIssue.apple(failure); status = failure.message }
        catch { issueCode = RecoveryIssue.apple(error); status = accountMessage(error) }
    }
}

/// Restores a Storebench encrypted backup on a Mac that has no Storebench data yet.
struct RestoreBackupCard: View {
    let model: LibraryModel
    @State private var folder: URL?
    @State private var passphrase = ""

    var body: some View {
        Card(title: "Restore from a backup", subtitle: "Choose a Storebench encrypted backup folder and enter its restore passphrase. Storebench checks every file before restoring, and then asks for that passphrase when it starts.") {
            HStack(spacing: 12) {
                Button("Choose Backup…") {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK { folder = panel.url }
                }.fixedSize()
                Text(folder?.path ?? "No backup chosen").font(.sbCallout).foregroundStyle(StorebenchTheme.muted).lineLimit(1).truncationMode(.middle).help(folder?.path ?? "")
            }
            StorebenchSecureField("Restore passphrase", text: $passphrase).storebenchFormColumn()
            if folder != nil && passphrase.utf16.count >= 12 {
                StorebenchFormFooter {
                    Button("Restore Backup") {
                        guard let folder else { return }
                        let value = passphrase; passphrase = ""
                        Task {
                            let scoped = folder.startAccessingSecurityScopedResource()
                            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
                            await model.restore(backup: folder, password: value)
                        }
                    }.fixedSize()
                }
            }
        }
    }
}
