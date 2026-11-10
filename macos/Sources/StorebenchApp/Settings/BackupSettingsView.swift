import AppKit
import StorebenchCore
import SwiftUI

struct BackupSettingsView: View {
    let model: LibraryModel
    @State private var latestReading = false
    @State private var editor = BackupSettingsEditor()
    @State private var message = ""
    @State private var working = false
    @State private var issueCode: String?
    private var changes: [SavedValueChange]? { editor.changes?.map { .init(id: $0.id, label: $0.label, saved: $0.saved, edited: $0.edited) } }

    var body: some View {
        StorebenchForm {
            StorebenchFormSection("Automatic backups") {
                if editor.ready {
                VStack(alignment: .leading, spacing: StorebenchTheme.space(3)) {
                    StorebenchSettingToggle("Back up automatically", isOn: $editor.inputs.enabled)
                    StorebenchFormField(label: "Backup folder", hint: editor.inputs.destination.isEmpty ? "No backup folder chosen." : editor.inputs.destination) {
                        Button("Choose Folder…", action: chooseFolder).help(editor.inputs.destination.isEmpty ? "Choose Backup Folder" : editor.inputs.destination)
                    }
                    StorebenchPicker("Frequency", selection: $editor.inputs.intervalHours) { SelectionOption("Every hour", value: 1); SelectionOption("Every 6 hours", value: 6); SelectionOption("Every 12 hours", value: 12); SelectionOption("Every day", value: 24); SelectionOption("Every week", value: 168) }
                    StorebenchLabeledContent("Backups to keep") {
                        StorebenchStepper("\(editor.inputs.retain) backup\(editor.inputs.retain == 1 ? "" : "s")", value: $editor.inputs.retain, in: 1...100)
                    }
                    StorebenchSecureField(editor.saved?.hasPassphrase == true ? "New restore passphrase (optional)" : "Restore passphrase", text: $editor.passphrase)
                    StorebenchSecureField("Repeat restore passphrase", text: $editor.confirmation)
                    Text("The restore passphrase protects each backup and is needed to restore it. Use 12–256 characters and keep it somewhere safe. An empty pair retains the saved passphrase; its contents are never displayed.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
                }.storebenchWorking(working || model.session == nil)
                }
                StorebenchFeedback(text: message, height: 64)
                Text(editor.dirty ? "You have unsaved changes." : editor.ready ? "Your saved schedule is up to date." : "Backup settings have not been read.").font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
                RecoveryActions(code: issueCode)
                if !editor.ready {
                    Button(working ? "Reading…" : "Read Backup Settings") { Task { await readInitial() } }.storebenchWorking(working || model.session == nil)
                } else {
                    LatestSaveReview(busy: working || model.session == nil, reading: latestReading, hasEdits: editor.dirty, available: editor.ready, changes: changes, note: "Passphrase contents are never read into the editor.",
                        onRead: { Task { latestReading = true; defer { latestReading = false }; await refresh(compare: true) } },
                        onKeep: editor.latest == nil ? nil : { editor.chooseLatest(keepEdits: true); message = "Your edits are kept against the chosen latest save. Save when ready."; issueCode = nil },
                        onUse: editor.latest == nil ? nil : { editor.chooseLatest(keepEdits: false); message = "Saved values loaded. Nothing was saved."; issueCode = nil })
                }
                if editor.canSave && model.session != nil {
                    StorebenchFormFooter {
                        Button(working ? "Working…" : "Save Backup Settings") { Task { await save() } }.buttonStyle(StorebenchButtonStyle(.primary)).storebenchWorking(working)
                    }
                }
            }
            StorebenchFormSection("Backup health") {
                StorebenchLabeledContent("Automatic backups", value: statusLabel)
                StorebenchLabeledContent("Last verified", value: editor.status?.lastVerifiedAt.map { timestamp($0) } ?? (editor.status == nil ? "Unknown" : "No verified backup"))
                StorebenchLabeledContent("Next backup", value: editor.status?.nextDueAt.map { timestamp($0) } ?? (editor.status == nil ? "Unknown" : editor.saved?.enabled == true ? "When Storebench is unlocked" : "Enable a schedule"))
                StorebenchLabeledContent("Verified copies", value: editor.status.map { String($0.generations) } ?? "Unknown")
                if let code = editor.status?.error {
                    Text(["SB-BACKUP-CREATE": "The last backup could not be created.", "SB-BACKUP-VERIFY": "The last backup failed verification and was set aside unchanged.",
                          "SB-BACKUP-PRUNE": "Older backups could not be removed.", "SB-BACKUP-INTERRUPTED": "The last backup was interrupted."][code] ?? "Backup storage could not be read.")
                        .font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
                }
                if editor.ready && !editor.canRun { Text("Save a schedule with a backup folder and restore passphrase to back up now.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted) }
                if editor.ready && model.session != nil {
                    StorebenchFormFooter {
                        Button("Refresh Status") { Task { await refresh(compare: false) } }
                        if editor.canRun { Button(working ? "Working…" : "Back Up Now") { Task { await runNow() } }.buttonStyle(StorebenchButtonStyle(.primary)) }
                    }.storebenchWorking(working)
                }
            }
            StorebenchFormSection("Restoring your workspace") {
                Text("Backups include encrypted saved data, media and staged build packages. Restore needs the passphrase used when that copy was created. Changing it protects future copies; older copies keep their original passphrase. Apple credentials must be connected again after restoring. Automatic backups run while Storebench is open and unlocked; overdue work resumes when you reopen it.")
                    .font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
            }
        }

        .trackUnsavedChanges(editor.dirty, busy: working)
        .task { await readInitial() }
    }
    private var statusLabel: String {
        guard let status = editor.status else { return "Status has not been verified" }
        switch status.state { case .disabled: return "Off"; case .locked: return "Paused while locked"; case .waiting: return "Scheduled"; case .due: return "Ready to back up"; case .running: return "Backup in progress"; case .error: return "Needs attention" }
    }
    private func timestamp(_ value: String) -> String { "\(value.prefix(16).replacingOccurrences(of: "T", with: " ")) UTC" }
    private func chooseFolder() {
        guard !working, editor.ready, model.session != nil else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            do { editor.chooseFolder(try BackupFolderAccess.system.capture(url)); message = ""; issueCode = nil }
            catch { report(error, fallback: "The backup folder could not be selected. Try choosing it again.") }
        }
    }
    private func readInitial() async {
        guard !working, !editor.ready, let session = model.session else { return }
        working = true; defer { working = false }
        do {
            let value = try await session.backupSettings(); try Task.checkCancellation(); guard model.session === session else { return }
            editor.load(value); issueCode = nil; message = "Backup settings read."
            try await readStatus(session)
        } catch is CancellationError { }
        catch { report(error, fallback: "Backup settings or status could not be read. Previously read values remain here; retry.") }
    }
    private func refresh(compare: Bool) async {
        guard !working, editor.ready, let session = model.session else { return }
        working = true; defer { working = false }
        do {
            if compare {
                let value = try await session.backupSettings(); try Task.checkCancellation(); guard model.session === session else { return }
                try editor.readLatest(value); message = "Latest saved values loaded. Compare them, then choose a baseline."
            }
            try await readStatus(session)
            issueCode = nil; if !compare { message = "Backup status refreshed. Your inputs and save revision are kept." }
        } catch is CancellationError { }
        catch { report(error, fallback: "Backup settings or status could not be read. Your inputs and save revision remain here; retry.") }
    }
    private func readStatus(_ session: WorkspaceSession) async throws {
        let value = try await session.backupStatus(); try Task.checkCancellation(); guard model.session === session else { throw CancellationError() }; editor.receiveStatus(value)
    }
    private func save() async {
        guard !working, editor.canSave, let session = model.session else { return }
        working = true; defer { working = false }
        do {
            let intent = try editor.saveIntent(), saved = try await session.saveBackupSettings(intent, writer: model.writer)
            guard model.session === session else { return }; editor.acknowledgeSave(saved); issueCode = nil; message = "Backup settings saved."
            do { try await readStatus(session) } catch { message = "Backup settings saved. Status could not be refreshed; retry Refresh Status." }
        } catch { report(error, fallback: "Backup settings could not be saved. Read the latest save before retrying.") }
    }
    private func runNow() async {
        guard !working, editor.canRun, let saved = editor.saved, let session = model.session else { return }
        working = true; defer { working = false }
        do {
            let value = try await session.runBackups(writer: model.writer, force: true, expectedRevision: saved.revision)
            try Task.checkCancellation(); guard model.session === session else { return }; editor.receiveStatus(value); issueCode = nil
            message = value.state == .error ? "Backup could not be verified. Existing verified copies are kept. Check folder access, then retry."
                : value.state == .locked ? "Unlock Storebench to create a backup." : value.state == .disabled ? "Automatic backups are off. Read the latest save before starting a backup."
                : value.state == .running ? "A backup is already in progress. Refresh its status to check the result." : value.lastVerifiedAt != nil ? "Encrypted backup created and verified." : "The backup is queued. Refresh its status to check the result."
        } catch { report(error, fallback: "The backup result could not be confirmed. Refresh its status before retrying.") }
    }
    private func report(_ error: Error, fallback: String) {
        issueCode = "SB-SETTINGS-SAVE"; message = (error as? BackupSettingsFailure)?.message ?? fallback
    }
}
