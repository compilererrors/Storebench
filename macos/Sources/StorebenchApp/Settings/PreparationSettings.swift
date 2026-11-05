import StorebenchCore
import SwiftUI

/// How many apps are read ahead so Release and Quick Release open with their material and status already saved.
struct PreparationSettings: View {
    let model: LibraryModel
    @State private var limit = BackgroundPreparation.standard
    @State private var baseline: Int?
    @State private var working = false
    @State private var status = ""
    @State private var problem = false
    @State private var issueCode: String?
    var body: some View {
        StorebenchFormSection("Background preparation") {
            if baseline != nil {
                StorebenchPicker("Apps to prepare", selection: Binding(get: { limit }, set: { limit = $0; Task { await save() } })) {
                    selectionOptions(BackgroundPreparation.limits) { SelectionOption(Self.label($0), value: $0) }
                }
            }
            Text("Storebench reads the release status and material of these apps in the background, so Release and Quick Release open without waiting. With more connected apps, the ones you open most often come first. Nothing is sent to App Store Connect.")
                .font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
            StorebenchFeedback(text: status, height: 40, error: problem)
            RecoveryActions(code: issueCode)
            if problem && baseline != nil && baseline != limit && model.session != nil {
                StorebenchFormFooter {
                    Button("Try Again") { Task { await save() } }.help("Save Apps to Prepare").accessibilityLabel("Save Apps to Prepare").buttonStyle(StorebenchButtonStyle(.primary))
                }
            }
        }
        .trackUnsavedChanges(baseline.map { limit != $0 } ?? false, busy: working, problem: { problem ? "Background preparation: " + status : nil }, onSave: { await save(); return baseline == limit })
        .task {
            guard let session = model.session else { return }
            do { limit = try await session.backgroundPreparation().appLimit; try Task.checkCancellation(); baseline = limit }
            catch { issueCode = "SB-SETTINGS-SAVE"; status = "Background preparation could not be read. Reopen this tab to retry." }
        }
    }
    private static func label(_ count: Int) -> String { count == 0 ? "Off" : count == 1 ? "1 app" : "\(count) apps" }
    private func save() async {
        guard !working, baseline != nil, let session = model.session else { return }
        working = true; issueCode = nil; defer { working = false }
        // A choice made while the previous one was saving is saved next.
        while let saved = baseline, saved != limit {
            let selected = limit
            do { try await session.setBackgroundPreparation(BackgroundPreparation(appLimit: selected)); baseline = selected; problem = false; status = "Background preparation saved." }
            catch { issueCode = "SB-SETTINGS-SAVE"; problem = true; status = "Background preparation was not saved. Your choice is kept; try again."; return }
        }
    }
}
