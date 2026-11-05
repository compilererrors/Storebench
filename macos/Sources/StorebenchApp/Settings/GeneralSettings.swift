import AppKit
import StorebenchCore
import SwiftUI

struct GeneralSettings: View {
    let model: LibraryModel
    @State private var currency = "USD"
    @State private var baseline: String?
    @State private var working = false
    @State private var status = ""
    @State private var problem = false
    @State private var issueCode: String?
    var body: some View {
        StorebenchForm {
            AppearanceSettings()
            StorebenchFormSection("Local storage", help: "storage") {
                StorebenchLabeledContent("Encrypted data folder") {
                    Text(Workspace.defaultRoot.path).lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(Workspace.defaultRoot.path)
                }
                Text("Saved history, reports and drafts stay encrypted in this folder. Check available disk space and folder permissions if a local save fails. Backups are managed in the Backups tab.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
                StorebenchFormFooter {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Workspace.defaultRoot]) }.help("Show Data Folder in Finder").accessibilityLabel("Show Data Folder in Finder")
                }
            }
            StorebenchFormSection("Display") {
                if baseline != nil {
                    StorebenchPicker("Display currency", selection: Binding(get: { currency }, set: { currency = $0; Task { await save() } })) { selectionOptions(DisplayPreferences.currencies) { SelectionOption($0, value: $0) } }
                }
                Text("Proceeds in other currencies are estimated with dated exchange rates. A new choice is saved right away.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
                StorebenchFeedback(text: status, height: 40, error: problem)
                RecoveryActions(code: issueCode)
                if problem && baseline != nil && baseline != currency && model.session != nil {
                    StorebenchFormFooter {
                        Button("Try Again") { Task { await save() } }.help("Save Display Currency").accessibilityLabel("Save Display Currency").buttonStyle(StorebenchButtonStyle(.primary))
                    }
                }
            }
            PreparationSettings(model: model)
            PerformanceSettings(model: model)
        }.storebenchWorking(working)
            .trackUnsavedChanges(baseline.map { currency != $0 } ?? false, busy: working, problem: { problem ? "Display currency: " + status : nil }, onSave: { await save(); return baseline == currency })
            .task {
                guard let session = model.session else { return }
                do { currency = try await session.displayCurrency(); try Task.checkCancellation(); baseline = currency }
                catch { issueCode = "SB-SETTINGS-SAVE"; status = "Display preferences could not be read. Reopen this tab to retry." }
            }
    }
    private func save() async {
        guard !working, baseline != nil, let session = model.session else { return }
        working = true; issueCode = nil; defer { working = false }
        // A choice made while the previous one was saving is saved next.
        while let saved = baseline, saved != currency {
            let selected = currency
            do { try await session.setDisplayCurrency(selected); baseline = selected; problem = false; status = "Display currency saved." }
            catch { issueCode = "SB-SETTINGS-SAVE"; problem = true; status = "Display currency was not saved. Your choice is kept; try again."; return }
        }
    }
}
