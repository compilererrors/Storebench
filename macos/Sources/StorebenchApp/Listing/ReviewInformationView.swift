import AppKit
import StorebenchCore
import SwiftUI
import UniformTypeIdentifiers

/// Local drafts and Apple attachments have separate actions; every Apple write has a Publish review.
struct ReviewInformationView: View {
    let account: Account, app: Account.App, session: WorkspaceSession?
    var initialVersionId: String? = nil
    /// Shows only this Apple version, without the version choice.
    var fixedVersionId: String? = nil
    @State private var latestReading = false
    @State private var saving = false
    @State private var editor = ReviewInformationEditor()
    @State private var layout = ReviewInformationLayout()
    @State private var fileSelection = FileDialogSelection<String>()
    @State private var status = ""
    @State private var problem = false
    @State private var review: PublishReview?
    @State private var working = false
    @State private var publishing = false
    @State private var fileTask: Task<Void, Never>?
    @State private var restoredVersion: String?
    @Environment(\.editorProtection) private var protection
    @Environment(\.navigationPresentation) private var history
    @Environment(\.pageScroll) private var pageScroll
    @Environment(\.pageReveal) private var pageReveal
    private struct Read { let editor: ReviewInformationEditor, layout: ReviewInformationLayout }
    private func readKey(_ versionId: String?) -> String { "app-review/\(account.id)/\(app.id)/\(versionId ?? "")" }
    private var busy: Bool { working || publishing || fileSelection.pending }
    private var editable: Bool { editor.snapshot?.version?.editable == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Card(title: "App Review Information", subtitle: "Contact details, sign-in information and notes for App Review. Save lists the changes for App Store Connect; nothing is sent until you approve them.", help: "review-information") {
                if fixedVersionId == nil {
                    StorebenchPicker("Version", selection: Binding(get: { editor.snapshot?.versionId ?? "" }, set: { value in
                        if !busy, value != editor.snapshot?.versionId, protection?.allowLeaving() != false { Task { await load(value) } }
                    })) { selectionOptions(editor.snapshot?.versions ?? []) { SelectionOption("\($0.name) · \($0.state)", value: $0.id) } }.storebenchFormColumn().storebenchWorking(busy)
                }
                if !editor.loaded { StorebenchBusyButton(title: "Read from Apple", loadingTitle: "Reading…", busy: busy) { Task { await load(fixedVersionId, fresh: true) } }.help("Read App Review Information").accessibilityLabel("Read App Review Information") }
                if editor.loaded {
                if let reused = editor.snapshot?.reusedFrom { Text("Reused from \(reused). Check these details before publishing.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted) }
                // Laid out as in App Store Connect: sign-in first, then contact details, always visible.
                VStack(alignment: .leading, spacing: StorebenchTheme.gap) {
                    StorebenchCardSection(title: "Sign-In Information") {
                        Text("Provide a user name and password so Apple's reviewer can sign in to your app.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: StorebenchTheme.space(1)) {
                            Toggle("Sign-in required", isOn: $editor.fields.demoAccountRequired)
                            StorebenchHelpButton(topic: "review-signin")
                        }
                        if editor.fields.demoAccountRequired {
                            StorebenchFormGrid() {
                                StorebenchTextField("User name", text: $editor.fields.demoAccountName).info("A working demo account Apple's reviewer can sign in with. Use a test account, not a personal one.")
                                StorebenchSecureField(editor.snapshot?.demoPasswordSaved == true ? "Replacement password" : "Password", text: $editor.fields.demoAccountPassword)
                            }.environment(\.fieldHintHeight, 17)
                            Text(editor.snapshot?.demoPasswordSaved == true ? "A password is saved. Leave this field empty to keep it, or enter a replacement." : "Enter the demo account password.").font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
                        }
                    }
                    StorebenchCardSection(title: "Contact Information") {
                        StorebenchFormGrid() {
                            StorebenchTextField("First name", text: $editor.fields.contactFirstName)
                            StorebenchTextField("Last name", text: $editor.fields.contactLastName)
                            StorebenchTextField("Phone number", text: $editor.fields.contactPhone).info("Apple may call this number during review. Include the country code, such as +46 70 123 45 67.")
                            StorebenchTextField("Email", text: $editor.fields.contactEmail).info("Apple writes to this address if the reviewer has questions about this version.")
                        }.environment(\.fieldHintHeight, 17)
                    }
                }.storebenchWorking(busy)
                HStack(spacing: StorebenchTheme.space(1)) {
                    Text("Notes · \(editor.fields.notes.utf8.count) / 4,000 UTF-8 bytes").font(.sbCaption.weight(.semibold)).foregroundStyle(StorebenchTheme.muted)
                    StorebenchHelpButton(topic: "review-notes")
                }
                StorebenchTextArea(text: $editor.fields.notes, height: StorebenchTheme.textarea()).accessibilityLabel("App Review notes").storebenchWorking(busy)
                VStack(alignment: .leading, spacing: 8) {
                    Text(editor.selectedFile != nil && !working ? "Attachment not saved: \(editor.attachmentName)" : "Local attachment: \(editor.attachmentName)").lineLimit(2).help(editor.attachmentName)
                        .foregroundStyle(editor.selectedFile != nil && !working ? StorebenchTheme.color("color-danger") : StorebenchTheme.muted)
                    HStack {
                        if editor.selectedFile != nil { Button("Try Again") { Task { await save(prepare: false) } }.buttonStyle(StorebenchButtonStyle(.primary)) }
                        else { Button("Choose File…") { if let versionId = editor.snapshot?.versionId { fileSelection.begin(versionId) } } }
                        if editor.selectedFile != nil || editor.attachment != nil { Button("Remove Attachment", role: .destructive) { editor.removeAttachment(); review = nil; problem = false; status = "" }.help("Remove Local Attachment").accessibilityLabel("Remove Local Attachment") }
                    }.storebenchWorking(busy)
                    HStack(alignment: .top, spacing: StorebenchTheme.space(1)) {
                        Text("PDF, PNG, JPEG, MP4 or MOV, up to 50 MB. A chosen file is saved in this draft on this Mac right away. Removing the local attachment does not remove files already at Apple.").font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
                        StorebenchHelpButton(topic: "review-attachment")
                    }
                    if editor.inheritedAttachmentFrom != nil { Text("The previous version's saved local attachment will be reused.").font(.sbCaption).foregroundStyle(StorebenchTheme.muted) }
                    ForEach(editor.snapshot?.unavailablePreviousAttachments ?? [], id: \.self) { name in Text("Previous Apple attachment unavailable locally: \(name). Choose the original file to upload it to this version.").font(.sbCaption).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true) }
                }
                if !(editor.snapshot?.appleAttachments ?? []).isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Attachments at Apple").font(.sbHeadline)
                        ForEach(editor.snapshot?.appleAttachments ?? []) { attachment in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(attachment.fileName).lineLimit(2).help(attachment.fileName)
                                StorebenchHeader(stackAt: 560) {
                                    StorebenchTextSlot(text: attachment.state, height: 34, font: .sbCaption, color: StorebenchTheme.muted, live: true)
                                } actions: {
                                    if editable { Button("Review Removal") { Task { await prepareRemoval(attachment.id) } }.storebenchWorking(busy) }
                                }
                            }
                        }
                    }
                }
                if editor.snapshot?.version?.platform == "MAC_OS" {
                    DisclosureGroup("Sandbox exceptions", isExpanded: layoutBinding(.sandbox)) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .top, spacing: StorebenchTheme.space(1)) {
    Text("Temporary entitlement explanations stay in this local draft. Copy each explanation to the matching macOS version in App Store Connect: click Apps, select the app and click the macOS version in the sidebar.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
                                StorebenchHelpButton(topic: "review-sandbox")
                            }
                            ForEach(editor.sandbox.indices, id: \.self) { index in
                                VStack(alignment: .leading, spacing: 8) {
                                    StorebenchTextField("Entitlement key (up to 200 characters)", text: $editor.sandbox[index].key)
                                    StorebenchTextArea(title: "Usage information", text: $editor.sandbox[index].usage, height: StorebenchTheme.textarea()).accessibilityLabel("Usage information (up to 4,000 characters)")
                                    HStack {
                                        Button("Copy Explanation") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(editor.sandbox[index].clipboardText, forType: .string); status = "Sandbox explanation copied." }
                                        Button("Remove Exception", role: .destructive) { editor.sandbox.remove(at: index); review = nil }
                                    }
                                }
                            }
                            if editor.sandbox.count < 20 { Button("Add Exception") { editor.sandbox.append(SandboxException()); review = nil } }
                            StorebenchActionLink("Open Version", destination: URL(string: "https://appstoreconnect.apple.com/apps/\(app.id)/distribution/macos/version/inflight")!, help: "Open the macOS version in App Store Connect")
                        }.padding(.top, 8)
                    }.storebenchWorking(busy)
                }
                }
                StorebenchFeedback(text: status, height: 34, error: problem)
                LatestSaveReview(busy: busy || !editor.loaded, reading: latestReading, hasEdits: editor.dirty, available: editor.loaded, changes: editor.changes?.map { SavedValueChange(id: $0.id, label: $0.label, saved: $0.saved, edited: $0.edited) }, note: "Choosing a baseline does not save or publish. An unchanged local attachment follows the latest save when you keep your edits.", onRead: { Task { await compareLatest() } },
                                 onKeep: editor.latest == nil ? nil : { editor.chooseLatest(keepEdits: true); review = nil; status = "Latest revision selected. Your edits remain unsaved." },
                                 onUse: editor.latest == nil ? nil : { editor.chooseLatest(keepEdits: false); layout = editor.snapshot?.layout ?? ReviewInformationLayout(); review = nil; status = "Showing the latest saved values. Nothing was saved." })
                if editor.loaded && (editable || editor.dirty) {
                    StorebenchFormFooter {
                        // Save keeps the details on this Mac and lists what App Store Connect would get; Save Draft only keeps them here.
                        StorebenchBusyButton(title: "Save", loadingTitle: "Saving…", busy: saving, variant: .primary) { Task { await save(prepare: true) } }
                            .help("Save on this Mac and list the changes for App Store Connect").storebenchWorking(!(editable))
                        Button("Save Draft") { Task { await save(prepare: false) } }.help("Save on this Mac only").storebenchWorking(!(editor.dirty))
                    }.storebenchWorking(busy)
                }
            }
            if review != nil && editor.dirty && review?.request.reviewAttachmentId == nil {
                Text("You changed the details after preparing this review. Choose Save again to list the current details.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
            } else {
                ReviewPanel(account: account, app: app, session: session, review: $review, done: { if review?.state == "complete" { Task { await refreshApple() } } }, busyChanged: { publishing = $0 })
                    .storebenchWorking(working || fileSelection.pending)
            }
        }
        .historyValue("app-review", Binding(get: { editor.snapshot?.versionId ?? restoredVersion ?? "" }, set: { restoredVersion = $0.isEmpty ? nil : $0 }))
        .task {
            guard !editor.loaded else { return }
            // Back returns to the version that was open. What was last read or saved shows at once, read-only until Apple's current answer arrives.
            let version = fixedVersionId ?? restoredVersion ?? initialVersionId
            if let read = history?.rememberedRead(readKey(version), as: Read.self) { editor = read.editor; layout = read.layout }
            await load(version)
        }
        .onDisappear { remember(editor.snapshot?.versionId) }
        .trackUnsavedChanges(editor.dirty, busy: busy, problem: { problem ? "App Review Information: " + status : nil }, onSave: { await save(prepare: false); return !editor.dirty })
        .onChange(of: editor.inputFingerprint) { _, _ in if editor.dirty { review = nil } }
        .onDisappear { fileTask?.cancel() }
        .fileImporter(isPresented: $fileSelection.isPresented, allowedContentTypes: [.pdf, .png, .jpeg, .mpeg4Movie, .quickTimeMovie]) { result in
            let target = fileSelection.finish()
            guard let target, case .success(let url) = result, target == editor.snapshot?.versionId, !working, !publishing else { return }
            working = true
            fileTask = Task {
                defer { working = false; fileTask = nil }
                let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do { _ = try ReviewAttachment.validateUploadName(url.lastPathComponent); let files = try await SelectedFiles.readAsync([url], purpose: .reviewAttachment); try Task.checkCancellation(); if target == editor.snapshot?.versionId, let file = files.first { try editor.stage(file); review = nil; working = false; await save(prepare: false) } }
                catch is CancellationError { }
                catch let failure as PublishFailure { problem = true; status = failure.message }
                catch { problem = true; status = "The attachment could not be read. Choose a supported file up to 50 MB." }
            }
        }
    }
    private func layoutBinding(_ section: ReviewInformationLayout.Section) -> Binding<Bool> {
        Binding(get: { section == .access ? layout.access : layout.sandbox }, set: { value in
            guard !busy, editor.loaded, let session else { return }
            working = true
            if section == .access { layout.access = value } else { layout.sandbox = value }
            Task { defer { working = false }; do { _ = try await session.saveReviewInformationLayout(accountId: account.id, appId: app.id, section: section, expanded: value) } catch { status = "The section layout could not be saved. Your draft is unchanged." } }
        })
    }
    private func load(_ versionId: String? = nil, fresh: Bool = false) async {
        guard !busy, let session else { return }; working = true; defer { working = false }
        if fresh { await session.invalidateAppleReads() }
        do { let snapshot = try await session.reviewInformationSnapshot(account: account, appId: app.id, versionId: versionId, client: try await session.readClient(for: account)); try Task.checkCancellation(); editor.load(snapshot); layout = snapshot.layout; review = nil; status = ""; remember(versionId) }
        catch is CancellationError { }
        catch { status = "App Review Information could not be read. Your current inputs remain here. Retry the read or choose another version." }
    }
    /// Keeps the editor as last read or saved, never with unsaved inputs, under the requested and the shown version.
    private func remember(_ requested: String?) {
        guard editor.loaded, !editor.dirty, let shown = editor.snapshot?.versionId else { return }
        let read = Read(editor: editor, layout: layout)
        history?.rememberRead(read, readKey(shown)); if requested != shown { history?.rememberRead(read, readKey(requested)) }
    }
    private func save(prepare: Bool) async {
        guard !busy, let session, let snapshot = editor.snapshot else { return }; working = true; saving = prepare; defer { working = false; saving = false }
        review = nil; problem = false
        do {
            let client = try await session.client(for: account)
            if prepare {
                let result = try await session.saveAndPrepareReviewInformation(account: account, appId: app.id, versionId: snapshot.versionId, fields: editor.fields, sandbox: editor.sandbox, attachment: editor.upload, keepAttachment: editor.attachment != nil, expectedRevision: editor.revision, inheritedAttachment: editor.inheritedAttachmentFrom == nil ? nil : editor.attachment, inheritFromVersionId: editor.inheritedAttachmentFrom, client: client)
                try editor.acknowledge(result.saved); review = result.review; status = result.issue ?? "Saved on this Mac. Read the changes below, then choose Send to Apple there to send them to App Store Connect."
                if let id = result.review?.id { Task { @MainActor in try? await Task.sleep(for: .milliseconds(150)); if let pageReveal { pageReveal(ReviewPanel.sendAnchor(id)) } else { pageScroll?(ReviewPanel.sendAnchor(id), .center) } } }
            } else {
                let saved = try await session.saveReviewInformationLocally(account: account, appId: app.id, versionId: snapshot.versionId, fields: editor.fields, sandbox: editor.sandbox, attachment: editor.upload, keepAttachment: editor.attachment != nil, expectedRevision: editor.revision, inheritedAttachment: editor.inheritedAttachmentFrom == nil ? nil : editor.attachment, inheritFromVersionId: editor.inheritedAttachmentFrom, client: client)
                try editor.acknowledge(saved); status = "Saved on this Mac."
            }
        } catch let failure as PublishFailure { problem = true; status = "Not saved. " + failure.message }
        catch { problem = true; status = "Not saved. Your entries remain here. Try again, or read the latest save to compare." }
    }
    private func compareLatest() async {
        guard !busy, let session, let snapshot = editor.snapshot else { return }; working = true; defer { working = false }
        latestReading = true; defer { latestReading = false }
        do { let latest = try await session.reviewInformationSnapshot(account: account, appId: app.id, versionId: snapshot.versionId, client: try await session.client(for: account)); try Task.checkCancellation(); try editor.readLatest(latest); status = "Compare the latest save, then explicitly choose a baseline. Your inputs and editor revision are unchanged." }
        catch { status = "The latest save could not be read. Your inputs and editor revision are unchanged." }
    }
    private func prepareRemoval(_ id: String) async {
        guard !busy, editable, let session, let snapshot = editor.snapshot else { return }; working = true; defer { working = false }; review = nil
        do { var request = PublishRequest(accountId: account.id, appId: app.id, scope: .reviewInfo, versionId: snapshot.versionId); request.reviewAttachmentId = id; review = try await session.preparePublishing(account: account, request: request, client: try await session.client(for: account)); status = "Read the attachment removal review before approving it. Your local draft is kept." }
        catch let failure as PublishFailure { status = failure.message }
        catch { status = "The attachment removal review could not be prepared. No file was removed." }
    }
    private func refreshApple() async {
        guard !working, let session, let snapshot = editor.snapshot else { return }; working = true; defer { working = false }
        do { let latest = try await session.reviewInformationSnapshot(account: account, appId: app.id, versionId: snapshot.versionId, client: try await session.client(for: account)); try editor.refreshApple(latest); status = "Published. Apple attachments refreshed; your local inputs are kept." }
        catch { status = "Published. Apple attachments could not be refreshed. Your local inputs are kept." }
    }
}
