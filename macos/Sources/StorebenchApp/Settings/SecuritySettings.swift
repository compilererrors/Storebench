import AppKit
import StorebenchCore
import SwiftUI

struct SecuritySettings: View {
    let model: LibraryModel
    @State private var editorId = UUID().uuidString
    @State private var current = ""
    @State private var password = ""
    @State private var repeated = ""
    @State private var lock: Workspace.Lock?
    @State private var status = ""
    @State private var working = false

    var body: some View {
        StorebenchForm {
            StorebenchFormSection("Encrypted local storage", help: "storage") {
                Text(model.writer.usesPasswordFile ? "Your database key, Apple API keys, Apple ID sign-ins, reporting tokens and backup passphrases are encrypted with your Storebench password. Storebench does not access Keychain." : lock == .password ? "Storebench asks for its password each time it starts. Credentials are stored in your Mac Keychain." : "The encryption key and credentials are kept in your Mac Keychain.").foregroundStyle(StorebenchTheme.muted)
                if lock == .password { StorebenchSecureField("Current password", text: $current) }
                StorebenchSecureField(lock == .password ? "New password" : "Storebench password", text: $password)
                StorebenchSecureField("Repeat new password", text: $repeated)
                Text("Passwords need at least 12 characters and cannot be recovered. Changing the lock signs out open sessions.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
                StorebenchFeedback(text: status, height: 40)
                if working || (12...256).contains(password.utf16.count) && password == repeated || lock == .password && model.writer.usesKeychain && !current.isEmpty {
                StorebenchFormFooter {
                    if lock == .password && model.writer.usesKeychain && !current.isEmpty { Button("Use Mac Keychain") { Task { await change(to: nil) } }.help("Use Mac Keychain Instead").accessibilityLabel("Use Mac Keychain Instead") }
                    if working || (12...256).contains(password.utf16.count) && password == repeated {
                        Button(working ? "Updating…" : lock == .password ? "Change Password" : "Use Password") { Task { await change(to: password) } }.help(working ? "Updating…" : lock == .password ? "Change Password" : "Use Storebench Password").accessibilityLabel(working ? "Updating…" : lock == .password ? "Change Password" : "Use Storebench Password")
                            .buttonStyle(StorebenchButtonStyle(.primary))
                    }
                }
                }
            }
            if model.writer.usesKeychain {
                StorebenchFormSection("Touch ID Keychain") {
                    Text(model.storageMode == .touchID ? "Credentials open with Touch ID, with your Mac login password as the fallback. Authentication is handled by the protected Keychain item." : "Use Touch ID to open credentials from a protected Keychain item. Switching verifies a new copy and signs out the current session.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
                    if model.storageMode != .touchID {
                        if TouchIDKeychainStorage.supported && lock != .password {
                            StorebenchFormFooter {
                                Button("Use Touch ID…") { Task { await enableTouchID() } }.help("Use Touch ID for Keychain").accessibilityLabel("Use Touch ID for Keychain")
                                    .buttonStyle(StorebenchButtonStyle(.primary))
                            }
                        }
                        Text(!TouchIDKeychainStorage.supported ? "Available in a provisioned, Apple-signed build. This ad hoc build keeps using the login Keychain." : lock == .password ? "Remove the separate Storebench password first to unlock saved data using only Mac authentication." : "macOS may ask once for permission to read your current login Keychain. The original copy is kept for recovery; future native changes use the protected copy.").font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
                    }
                }
                if model.storageMode == .keychain {
                StorebenchFormSection("Mac authentication") {
                    Text("Require Mac authentication before Storebench opens Keychain-backed storage. Touch ID uses your Mac login password as a fallback. macOS Keychain permission is separate.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
                    StorebenchFormFooter {
                        Button(model.requiresDeviceAuthentication ? "Turn Off…" : "Turn On…") {
                            Task { await changeMacAuthentication() }
                        }.help(model.requiresDeviceAuthentication ? "Turn Off Mac Authentication…" : "Require Touch ID or Mac Password…").accessibilityLabel(model.requiresDeviceAuthentication ? "Turn Off Mac Authentication…" : "Require Touch ID or Mac Password…")
                    }
                }
                StorebenchFormSection("Password storage") {
                    Text("Copy saved data and credentials to password-protected storage. Storebench stops using Keychain after the copy.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
                    StorebenchFormFooter {
                        Button("Use Password…") {
                            guard EditorWindows.allowLeaving() else { return }
                            current = ""; password = ""; repeated = ""
                            Task { await model.choosePasswordStorage() }
                        }.help("Use Password Without Keychain").accessibilityLabel("Use Password Without Keychain")
                    }
                }
                }
            }
            if lock == .password {
                StorebenchFormSection("Session") {
                    Text("Sign out closes saved data and credentials after active work finishes. Unlock with your Storebench password to continue.").foregroundStyle(StorebenchTheme.muted)
                    if model.session != nil {
                        StorebenchFormFooter {
                            Button("Sign Out Now") {
                                guard EditorWindows.allowLeaving() else { return }
                                Task { await model.signOut() }
                            }
                        }
                    }
                }
            }
        }

        .storebenchWorking(working || model.session == nil)
        .trackUnsavedChanges(!current.isEmpty || !password.isEmpty || !repeated.isEmpty, busy: working, id: editorId)
        .task { lock = model.lockMode }
        .onChange(of: model.lockMode) { lock = model.lockMode }
    }

    private func change(to newPassword: String?) async {
        guard !working, model.session != nil else { return }
        guard EditorWindows.allowLeaving(excluding: editorId) else { return }
        working = true; defer { working = false }
        do {
            try await model.changeLock(currentPassword: lock == .password ? current : nil, newPassword: newPassword)
            status = newPassword == nil ? "Storebench now opens with your Mac Keychain." : "Password changed."
            current = ""; password = ""; repeated = ""
            lock = model.lockMode
        } catch KeyEnvelope.Failure.incorrectPassword { status = "The current password is not correct." }
        catch { status = "The lock could not be changed. Saved data is unchanged." }
    }

    private func enableTouchID() async {
        guard !working, model.session != nil, EditorWindows.allowLeaving(excluding: editorId) else { return }
        working = true; defer { working = false }
        do { try await model.enableTouchIDKeychain(); status = "Touch ID Keychain enabled. Unlock to continue." }
        catch { status = WorkspaceController.message(for: error) }
    }

    private func changeMacAuthentication() async {
        guard !working, model.session != nil, EditorWindows.allowLeaving(excluding: editorId) else { return }
        working = true; defer { working = false }
        do {
            try await model.changeDeviceAuthentication(required: !model.requiresDeviceAuthentication)
            status = model.requiresDeviceAuthentication ? "Mac authentication is required next time Storebench opens saved data." : "Mac authentication requirement removed."
        } catch { status = WorkspaceController.message(for: error) }
    }
}
