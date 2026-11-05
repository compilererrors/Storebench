import AppKit
import StorebenchCore
import SwiftUI
import UniformTypeIdentifiers

struct FastlaneMetadataCard: View {
    let account: Account, app: Account.App, session: WorkspaceSession?
    @State private var versions: [Revision.Version] = []
    @State private var revisionId: String?
    @State private var versionId = ""
    @State private var archive: Data?
    @State private var preview: FastlanePreview?
    @State private var working = false
    @State private var message = ""

    var body: some View {
        Card(title: "Fastlane metadata", subtitle: "Import or export a version's language text as a Fastlane ZIP. Preview every change before saving drafts locally.", help: "imports") {
            if session != nil && !versions.isEmpty {
                StorebenchFormGrid {
                    StorebenchPicker("Version", selection: $versionId) { selectionOptions(versions) { SelectionOption("\($0.number) · \($0.platform)", value: $0.id) } }
                    StorebenchFieldCommands {
                        Button("Export ZIP…") { Task { await export() } }.help(versionId.isEmpty ? "Choose a version first." : "Save this version's language text as a Fastlane ZIP")
                        Button("Import ZIP…") { Task { await choose() } }.help(versionId.isEmpty ? "Choose a version first." : "Choose a Fastlane ZIP to preview its changes")
                    }.storebenchWorking(versionId.isEmpty)
                }.storebenchWorking(working)
            }
            StorebenchFeedback(text: message, height: 34)
            if let preview {
                Text("\(preview.archive.files) text files · \(preview.archive.locales.count) languages · \(preview.archive.clears) explicit clears · \(preview.archive.ignored) ignored files").font(.sbCallout)
                Text("\(preview.archive.omitted.count) missing fields stay unchanged. \(preview.transfer.added) languages will be added.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(preview.transfer.changes) { change in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(change.label).font(.sbSubheadline.weight(.semibold))
                                Text("Now").font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
                                Text(change.before).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                Text("After").font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
                                Text(change.after).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }.frame(maxHeight: 320)
                HStack {
                    Button("Cancel") { if !working { self.preview = nil; archive = nil } }
                    if !preview.transfer.changes.isEmpty {
                        Button(working ? "Saving…" : "Import") { Task { await apply(preview) } }.buttonStyle(StorebenchButtonStyle(.primary))
                    }
                }.storebenchWorking(working)
            }
        }
        .task(id: "\(account.id):\(app.id)") { await load() }
        .onChange(of: versionId) { _, _ in preview = nil; archive = nil }
    }

    private func load() async {
        guard let session else { return }
        working = true; defer { working = false }
        do {
            let plan = try await session.releasePlan(accountId: account.id, appId: app.id)
            let history = try await session.revisions(accountId: account.id, appId: app.id)
            guard let source = history.first(where: { $0.id == (plan?.sourceRevisionId ?? history.first?.id) }) else { message = "Import app metadata first."; return }
            revisionId = source.id; versions = source.versions.filter { plan == nil || $0.id == plan!.baseVersionId }
            versionId = versions.first?.id ?? ""
        } catch { message = "The saved workspace could not be read." }
    }

    private func export() async {
        guard !working, !versionId.isEmpty, let session else { return }
        working = true; defer { working = false }
        do {
            let bytes = try await session.exportFastlaneMetadata(account: account, appId: app.id, versionId: versionId, revisionId: revisionId)
            let panel = NSSavePanel(); panel.allowedContentTypes = [.zip]; panel.nameFieldStringValue = "storebench-fastlane-metadata.zip"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try bytes.write(to: url, options: .atomic); message = "Exported Fastlane metadata."
        } catch let failure as TransferFailure { message = failure.message }
        catch { message = "The metadata ZIP could not be exported." }
    }

    private func choose() async {
        guard !working, !versionId.isEmpty, let session else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.zip]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        working = true; preview = nil; archive = nil; defer { working = false }
        do {
            // Bound bytes during reading even if the selected file grows after selection.
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            let bytes = try handle.read(upToCount: 4_000_001) ?? Data()
            guard !bytes.isEmpty, bytes.count <= 4_000_000 else { message = "Choose a ZIP file under 4 MB."; return }
            preview = try await session.importFastlaneMetadata(account: account, appId: app.id, versionId: versionId, archive: bytes, revisionId: revisionId)
            archive = bytes; message = preview?.transfer.changes.isEmpty == true ? "The archive matches the saved text." : ""
        } catch let failure as TransferFailure { message = failure.message }
        catch { message = "The ZIP could not be read." }
    }

    private func apply(_ preview: FastlanePreview) async {
        guard !working, let session, let archive else { return }
        working = true; defer { working = false }
        do {
            let saved = try await session.importFastlaneMetadata(account: account, appId: app.id, versionId: versionId, archive: archive, revisionId: revisionId, fingerprint: preview.transfer.fingerprint)
            message = "Imported \(saved.transfer.changes.count) changes locally. Nothing was sent to App Store Connect."
            self.preview = nil; self.archive = nil
        } catch let failure as TransferFailure { message = failure.message; self.preview = nil; self.archive = nil }
        catch { message = "The drafts could not be saved." }
    }
}
