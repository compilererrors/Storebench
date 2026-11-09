import StorebenchCore
import SwiftUI
import UniformTypeIdentifiers

struct BuildDeliveryView: View {
    let account: Account, app: Account.App, session: WorkspaceSession?
    @State private var draft: LocalEditorDraftEditor?
    @State private var package: StagedBuildPackage?
    @State private var deliveries: [BuildDelivery] = []
    @State private var version = ""
    @State private var number = ""
    @State private var platform = "IOS"
    @State private var choosingFile = false
    @State private var working = false
    @State private var publishing = false
    @State private var loaded = false
    @State private var status = ""
    @State private var deliveryStatus = ""
    @State private var readingDeliveries = false
    @State private var review: PublishReview?
    @Environment(\.navigationPresentation) private var history
    @Environment(\.confirmDestructive) private var confirm
    private var readKey: String { "build-deliveries/\(account.id)/\(app.id)" }

    private var draftValue: JSONText { .object([("version", .string(version)), ("number", .string(number)), ("platform", .string(platform))]) }
    private func restoreDraft(_ value: JSONText) {
        version = value["version"]?.text ?? ""; number = value["number"]?.text ?? ""; platform = value["platform"]?.text ?? "IOS"; review = nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card(title: "Build delivery", subtitle: "Stage a signed IPA or PKG locally, then review its exact destination before approving the upload. Apple processes delivered builds asynchronously.") {
                if let package {
                    Text(package.fileName).font(.sbHeadline).lineLimit(2).textSelection(.enabled)
                    Text("\(ByteCountFormatter.string(fromByteCount: Int64(package.size), countStyle: .binary)) · \(package.uti)").font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
                    ScrollView(.horizontal) { Text("SHA-256: \(package.sha256)").font(.sbCaption.monospaced()).textSelection(.enabled).fixedSize() }.frame(height: 28)
                    ViewThatFits {
                        HStack(alignment: .top, spacing: 12) { inputs }.storebenchWorking(draft?.loaded != true)
                        VStack(alignment: .leading, spacing: 12) { inputs }
                    }
                    ViewThatFits {
                        HStack(spacing: 12) { uploadActions(package) }
                        VStack(alignment: .leading, spacing: 12) { uploadActions(package) }
                    }
                } else {
                    Text("One package per app, up to 16 GiB. The staged copy is encrypted and included in your local backups.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
                    if loaded { Button("Choose IPA or PKG") { if !working { choosingFile = true } }.storebenchWorking(working) }
                }
                if let draft { LocalDraftActions(editor: draft, value: draftValue, restore: restoreDraft, blocked: working || publishing) }
                Text(status.isEmpty ? "Confirm that the version, build number and platform match the signed package." : status)
                    .font(.sbCallout).foregroundStyle(StorebenchTheme.muted).frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
            }
            ReviewPanel(account: account, app: app, session: session, review: $review, done: {
                if review?.state == "complete" { version = ""; number = "" }
                Task { await refresh() }
            }, busyChanged: { publishing = $0 }, syncConfirmation: true)
            Card(title: "Apple delivery status", subtitle: "Pending and failed delivery records can be removed through a separate publishing review. A processing or linked build cannot be removed here.", actions: AnyView(
                Button(readingDeliveries ? "Reading…" : "Refresh Status") { Task { await refresh() } }.help(readingDeliveries ? "Reading…" : "Refresh Delivery Status").accessibilityLabel(readingDeliveries ? "Reading…" : "Refresh Delivery Status").storebenchWorking(working)
            )) {
                if !deliveryStatus.isEmpty { Text(deliveryStatus).foregroundStyle(StorebenchTheme.muted) }
                StorebenchCollection(items: deliveries, title: { AppStoreNames.platform($0.platform) + " " + $0.version + " · Build " + $0.buildNumber }, subtitle: { $0.state }, empty: !deliveryStatus.isEmpty ? "" : loaded ? "Apple has not returned a delivery record for this app." : "Delivery records have not been read yet.") { delivery in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(AppStoreNames.platform(delivery.platform)) \(delivery.version) · Build \(delivery.buildNumber)").font(.sbHeadline).lineLimit(2)
                        Text(delivery.state).font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
                        if let date = delivery.uploadedDate ?? delivery.createdDate { Text("\(date.prefix(16).replacingOccurrences(of: "T", with: " ")) UTC").font(.sbCaption).foregroundStyle(StorebenchTheme.muted) }
                        if let id = delivery.buildId { Text("Processed build: \(id)").font(.sbCaption).lineLimit(2).textSelection(.enabled) }
                        if !delivery.details.isEmpty {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(Array(delivery.details.enumerated()), id: \.offset) { _, detail in
                                        Text("\(detail.kind) \(detail.code): \(detail.description)").font(.sbCallout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }.frame(maxHeight: 160)
                        }
                        if delivery.omittedDetails > 0 { Text("\(delivery.omittedDetails) additional diagnostics from Apple.").font(.sbCaption).foregroundStyle(StorebenchTheme.muted) }
                        if delivery.deletable {
                            Button("Review Removal", role: .destructive) { Task { await prepareRemoval(delivery) } }.help("Review Removal of Delivery Record").accessibilityLabel("Review Removal of Delivery Record").storebenchWorking(working)
                        }
                    }
                    StorebenchDivider()
                }
            }
        }
        .storebenchWorking(working || publishing)
        .trackUnsavedChanges(draft?.dirty(draftValue) == true, busy: working || publishing || draft?.busy == true, onSave: { await draft?.saveCurrent(value: { draftValue }) == true })
        .task {
            // Apple's delivery records read on an earlier visit show at once; the read that follows replaces them.
            if deliveries.isEmpty, let remembered = history?.rememberedRead(readKey, as: [BuildDelivery].self) { deliveries = remembered }
            await refresh()
            if let session {
                let owner = LocalEditorDraftEditor(scope: .init(accountId: account.id, appId: app.id, editor: "build-delivery", resource: "upload-metadata"), session: session)
                draft = owner
                if let saved = await owner.load(initial: draftValue) { restoreDraft(saved) }
            }
        }
        .onChange(of: version) { if review?.state == "prepared" { review = nil } }
        .onChange(of: number) { if review?.state == "prepared" { review = nil } }
        .onChange(of: platform) { if review?.state == "prepared" { review = nil } }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            if case .success(let files) = result, let file = files.first { Task { await stage(file) } }
        }
    }

    @ViewBuilder private var inputs: some View {
        StorebenchTextField("Version", text: $version, placeholder: "1.0")
        StorebenchTextField("Build number", text: $number, placeholder: "42")
        StorebenchPicker("Platform", selection: $platform) {
            SelectionOption("iOS", value: "IOS"); SelectionOption("macOS", value: "MAC_OS"); SelectionOption("tvOS", value: "TV_OS"); SelectionOption("visionOS", value: "VISION_OS")
        }
    }
    @ViewBuilder private func uploadActions(_ package: StagedBuildPackage) -> some View {
        let platformMatches = (platform == "MAC_OS") == (package.uti == "com.apple.pkg")
        if !version.isEmpty && !number.isEmpty && platformMatches {
            Button("Review Upload") { Task { await prepareUpload(package) } }.help("Prepare Upload Review").accessibilityLabel("Prepare Upload Review").buttonStyle(StorebenchButtonStyle(.primary))
        } else if !platformMatches {
            Text(package.uti == "com.apple.pkg" ? "A PKG package is uploaded for macOS. Choose macOS as the platform." : "An IPA package is not for macOS. Choose its platform.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
        }
        Button("Remove Package", role: .destructive) {
            guard confirm(.removeLocalFile, title: "Remove the encrypted local package?", message: "The original signed file and Apple's delivery record stay available.", action: "Remove Local Package") else { return }
            Task { await remove(package) }
        }.help("Remove Local Package").accessibilityLabel("Remove Local Package")
    }
    private func refresh() async {
        guard let session, !working, !readingDeliveries else { return }
        // The local package is read first and unlocks Choose at once; Apple's slower delivery read follows on its own.
        working = true
        do { package = try await session.stagedBuildPackage(accountId: account.id, appId: app.id); loaded = true }
        catch { status = "The encrypted local package could not be read." }
        working = false
        readingDeliveries = true; defer { readingDeliveries = false }
        do { deliveries = try await session.buildDeliveries(appId: app.id, client: try await session.client(for: account)); deliveryStatus = ""; history?.rememberRead(deliveries, readKey) }
        catch { deliveryStatus = "Apple delivery status could not be read. Refresh to check the current state." }
    }
    private func stage(_ file: URL) async {
        guard let session, !working else { return }
        working = true; status = "Encrypting the local package…"; review = nil
        defer { working = false }
        let scoped = file.startAccessingSecurityScopedResource(); defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        do {
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let size = values.fileSize else { status = "Choose a regular IPA or PKG file."; return }
            package = try await session.stageBuildPackage(accountId: account.id, appId: app.id, fileName: file.lastPathComponent, expectedSize: size, file: file)
            if package?.uti == "com.apple.pkg" { platform = "MAC_OS" }
            else if platform == "MAC_OS" { platform = "IOS" }
            status = "The encrypted package is staged. Prepare a review to send it to Apple."
        } catch let failure as PublishFailure { status = failure.message }
        catch { status = "The package could not be staged. Check its format, size and available disk space." }
    }
    private func remove(_ saved: StagedBuildPackage) async {
        guard let session, !working else { return }
        working = true; defer { working = false }
        do { try await session.removeStagedBuildPackage(accountId: account.id, appId: app.id, id: saved.id); package = nil; review = nil; status = "Local package removed." }
        catch { status = "The package changed or is in use. Refresh before removing it." }
    }
    private func prepareUpload(_ saved: StagedBuildPackage) async {
        guard !working else { return }
        working = true; defer { working = false }
        guard await draft?.save(draftValue) == true, draft?.dirty(draftValue) == false else { return }
        (review, status) = await prepareTestFlight(account, app, session) {
            $0.testflightAction = "upload-build"; $0.packageId = saved.id; $0.buildVersion = version; $0.buildNumber = number; $0.buildPlatform = platform
        }
    }
    private func prepareRemoval(_ delivery: BuildDelivery) async {
        guard !working else { return }
        working = true; defer { working = false }
        (review, status) = await prepareTestFlight(account, app, session) { $0.testflightAction = "delete-build-upload"; $0.buildUploadId = delivery.id }
    }
}
