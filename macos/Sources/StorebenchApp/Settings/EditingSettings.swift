import AppKit
import StorebenchCore
import SwiftUI

struct EditingSettings: View {
    let model: LibraryModel
    @State private var enabled = false
    @State private var baseline: Bool?
    @State private var working = false
    @State private var status = ""
    @State private var problem = false
    @State private var confirmationStatus = ""
    var body: some View {
        StorebenchForm {
            StorebenchFormSection("Local drafts") {
                if baseline != nil { StorebenchSettingToggle("Automatically save local drafts", isOn: Binding(get: { enabled }, set: { enabled = $0; Task { await save() } })) }
                Text("Saves language text and screenshot/app preview layouts after a short pause in the encrypted local database. With it off, each editor shows a Save button while it has changes. Apple changes still require a Publish review and explicit approval. This choice is saved right away.")
                    .font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
                StorebenchFeedback(text: status, height: 40, error: problem)
                if problem && baseline != nil && baseline != enabled && model.session != nil {
                    StorebenchFormFooter {
                        Button("Try Again") { Task { await save() } }.help("Save Editing Preferences").accessibilityLabel("Save Editing Preferences").buttonStyle(StorebenchButtonStyle(.primary))
                    }
                }
            }
            StorebenchFormSection("Confirmations") {
                Text("Removing or discarding work on this Mac asks first. Turn a question off here, or choose Don't ask again when it appears. Changes at App Store Connect always show a review you approve.")
                    .font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
                StorebenchOptionGrid(maximumColumns: 1) {
                ForEach(DestructiveConfirmation.allCases, id: \.self) { kind in
                    StorebenchToggle("Ask before " + kind.title.prefix(1).lowercased() + kind.title.dropFirst(), isOn: Binding(get: { model.editingPreferences?.asks(kind) ?? true }, set: { asks in setConfirmation(kind, asks: asks) }))
                        .storebenchWorking(model.session == nil || model.editingPreferences == nil)
                }
                }
                StorebenchFeedback(text: confirmationStatus, height: 40, error: !confirmationStatus.isEmpty)
            }
        }.storebenchWorking(working)
            .trackUnsavedChanges(baseline.map { $0 != enabled } ?? false, busy: working, problem: { problem ? "Automatically save local drafts: " + status : nil }, onSave: { await save(); return baseline == enabled })
            .task {
                guard let session = model.session else { return }
                working = true; defer { working = false }
                do { let value = try await session.editingPreferences(); try Task.checkCancellation(); enabled = value.autosaveDrafts; baseline = enabled }
                catch { baseline = nil; status = "Editing preferences could not be read. Reopen this tab before saving." }
            }
    }
    /// Saved right away, as Don't ask again is.
    private func setConfirmation(_ kind: DestructiveConfirmation, asks: Bool) {
        Task {
            do { try await model.setConfirmation(kind, asks: asks); confirmationStatus = "" }
            catch { confirmationStatus = "The confirmation setting was not saved. Try again." }
        }
    }
    private func save() async {
        guard !working, baseline != nil, let session = model.session else { return }
        working = true; defer { working = false }
        // A choice made while the previous one was saving is saved next.
        while let saved = baseline, saved != enabled {
            let value = enabled
            do {
                _ = try await session.updateEditingPreferences { $0.autosaveDrafts = value }
                baseline = value; await model.reloadEditingPreferences(); problem = false
                status = value ? "Autosave is on for language text and media layouts." : "Autosave is off. Each editor shows a Save button while it has changes."
            } catch { problem = true; status = "Editing preferences were not saved. Your choice is kept; try again."; return }
        }
    }
}
