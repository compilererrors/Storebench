import StorebenchCore
import SwiftUI

struct MessageView: View {
    let title: String, message: String, action: (String, () -> Void)

    var body: some View {
        StorebenchAuthScreen {
            StorebenchAuthCard(title: title, message: message) {
                Button(action.0, action: action.1).buttonStyle(StorebenchButtonStyle(.primary))
            }
        }
    }
}

struct UnlockView: View {
    let model: LibraryModel
    @State private var password = ""

    var body: some View {
        StorebenchAuthScreen {
            StorebenchAuthCard(title: "Unlock Storebench", message: model.requiresDeviceAuthentication ? "Use Touch ID or your Mac login password to open Keychain-backed storage." : model.lockMode == .device ? "Open saved data with the encryption key in your Mac Keychain." : "Enter the password that protects your encrypted local data.") {
                if model.lockMode != .device { StorebenchSecureField("Storebench password", text: $password).onSubmit(unlock) }
                StorebenchFeedback(text: model.lastError, error: true)
                if model.lockMode == .device || password.utf16.count >= 12 {
                    Button(model.requiresDeviceAuthentication ? "Unlock with Your Mac" : model.lockMode == .device ? "Open Saved Data" : "Unlock", action: unlock).buttonStyle(StorebenchButtonStyle(.primary))
                } else { Text("Your Storebench password has at least 12 characters.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted) }
            }
        }
    }

    private func unlock() { let value = password; password = ""; Task { await model.unlock(password: value) } }
}
