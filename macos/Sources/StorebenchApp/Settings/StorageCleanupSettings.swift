import StorebenchCore
import SwiftUI

/// What Storebench removes from this workspace by itself and after how many days: reviews that were never sent, and the images
/// kept with older AI requests.
struct StorageCleanupSettings: View {
    let model: LibraryModel
    @State private var removesReviews = true
    @State private var reviewDays = StorageCleanup.standardReviewDays
    @State private var removesImages = true
    @State private var imageDays = StorageCleanup.standardImageDays
    @State private var baseline: StorageCleanup?
    @State private var working = false
    @State private var cleaning = false
    @State private var status = ""
    @State private var problem = false
    @State private var issueCode: String?
    /// The choice as entered, or nil while a number of days is outside what can be saved.
    private var choice: StorageCleanup? { try? StorageCleanup(unsentReviewDays: removesReviews ? reviewDays : nil, aiImageDays: removesImages ? imageDays : nil) }
    private var changed: Bool { baseline.map { choice != $0 } ?? false }
    var body: some View {
        StorebenchFormSection("Storage Cleanup") {
            if baseline != nil {
                StorebenchCheckbox("Remove Unsent Reviews", isOn: $removesReviews)
                StorebenchTextField("Days After an Unsent Review Expired", value: $reviewDays, format: .number,
                                    hint: "From \(StorageCleanup.dayRange.lowerBound) to \(StorageCleanup.dayRange.upperBound) days. A review with a note in Change Journal is always kept.")
                    .storebenchWorking(!removesReviews)
                StorebenchCheckbox("Remove Images of Older AI Requests", isOn: $removesImages)
                StorebenchTextField("Days After an AI Request Ended", value: $imageDays, format: .number,
                                    hint: "From \(StorageCleanup.dayRange.lowerBound) to \(StorageCleanup.dayRange.upperBound) days. The request's text and answer are always kept.")
                    .storebenchWorking(!removesImages)
            }
            Text("Storebench checks once a day while it is unlocked. Only reviews that were prepared and never sent, and the images in AI History, are removed. Nothing sent to Apple, no saved listing, no draft and no report is removed. What is removed cannot be brought back.")
                .font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
            StorebenchFeedback(text: status.isEmpty ? (model.lastStorageCleanup.map { "Last cleanup: " + $0.summary } ?? "") : status, height: 40, error: problem)
            RecoveryActions(code: issueCode)
            if baseline != nil && model.session != nil {
                StorebenchFormFooter {
                    StorebenchCommand(title: "Save", running: "Saving…", busy: working, unavailable: choice == nil ? "Enter a number of days from \(StorageCleanup.dayRange.lowerBound) to \(StorageCleanup.dayRange.upperBound)." : changed ? nil : "Nothing has changed.") {
                        Task { await save() }
                    }.storebenchControlID("settings.cleanup.save")
                    StorebenchCommand(title: "Clean Up Now", running: "Cleaning Up…", busy: cleaning, unavailable: changed ? "Save your changes first." : choice.map { $0.unsentReviewDays == nil && $0.aiImageDays == nil } == true ? "Nothing is set to be removed." : nil, primary: false) {
                        Task { await cleanUp() }
                    }.help("Remove now what these settings allow. This cannot be undone.").storebenchControlID("settings.cleanup.run")
                }
            }
        }
        .trackUnsavedChanges(changed, busy: working || cleaning, problem: { problem ? "Storage cleanup: " + status : nil }, onSave: { await save(); return !changed })
        .task {
            guard let session = model.session else { return }
            do {
                let saved = try await session.storageCleanup(); try Task.checkCancellation()
                show(saved); baseline = saved
            } catch { issueCode = "SB-SETTINGS-SAVE"; problem = true; status = "Storage cleanup settings could not be read. Reopen this tab to retry." }
        }
    }
    private func show(_ value: StorageCleanup) {
        removesReviews = value.unsentReviewDays != nil; reviewDays = value.unsentReviewDays ?? StorageCleanup.standardReviewDays
        removesImages = value.aiImageDays != nil; imageDays = value.aiImageDays ?? StorageCleanup.standardImageDays
    }
    private func save() async {
        guard !working, baseline != nil, let selected = choice, let session = model.session else { return }
        working = true; issueCode = nil; defer { working = false }
        do { try await session.setStorageCleanup(selected); baseline = selected; problem = false; status = "Storage cleanup settings saved. They apply at the next daily check, or with Clean Up Now." }
        catch { issueCode = "SB-SETTINGS-SAVE"; problem = true; status = "Storage cleanup settings were not saved. Your choice is kept; try again." }
    }
    private func cleanUp() async {
        guard !cleaning, !changed, model.session != nil else { return }
        cleaning = true; issueCode = nil; defer { cleaning = false }
        do { let result = try await model.cleanUpStorage(); problem = false; status = result.summary }
        catch { problem = true; status = "The cleanup could not finish. Nothing was removed beyond what it had already checked; try again." }
    }
}
