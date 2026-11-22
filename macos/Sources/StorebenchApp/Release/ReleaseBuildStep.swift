import StorebenchCore
import SwiftUI

/// The processed build for the new version and its export compliance answer, in Release's Build step and in Quick Release.
/// Add Build adds the chosen build to the Apple version through its own review; submitting is a separate review.
struct ReleaseBuildStep: View {
    let account: Account, app: Account.App, session: WorkspaceSession?, plan: ReleasePlan
    let versionId: String?
    @Binding var selectedBuildId: String?
    let focus: ReleaseWizard.Focus?
    let addRequests: Int
    let goToSend: () -> Void
    let done: () -> Void
    /// Says where the version is created when Apple does not have it yet; nil names Release's step 3.
    var createFirst: String? = nil
    /// Opens the version step and starts its Sync to Apple, so a version Apple does not have yet is one command away.
    var syncVersion: (() -> Void)? = nil
    /// True once the version is removed from review to send a newer build: the step looks for builds uploaded after the one the version has.
    var replacing = false
    @State private var builds: [TestFlightBuild]?
    @State private var attachedId: String?
    /// False while only the first page of the version's builds is read; the rest follow it.
    @State private var complete = true
    @State private var failure = ""
    @State private var status = ""
    @State private var readAt: Date?
    @State private var review: PublishReview?
    @State private var preparing = false
    @State private var publishing = false
    /// False while remembered builds show and App Store Connect is read again.
    @State private var confirmed = false
    @State private var reader: ReleaseBuildReader?
    @State private var readCount = 0
    @State private var draft: LocalEditorDraftEditor?
    /// Apple's upload records for the app, read while the step waits for a build, so an upload shows before its build is listed.
    @State private var uploads: [BuildDelivery] = []
    @Environment(\.pageScroll) private var pageScroll
    @Environment(\.navigationPresentation) private var presentation
    /// Shared with the background preparation, which reads builds without a version.
    private var buildsKey: String { "release-builds/\(account.id)/\(app.id)" }
    private var readScope: String { JSONText.array([.string(account.id), .string(app.id), .string(plan.token), .string(versionId ?? "")]).stringify() }
    private var matching: [TestFlightBuild] {
        (builds ?? []).filter { $0.platform == plan.platform && $0.appVersion == plan.targetVersion && $0.expired != true }
    }
    private var selected: TestFlightBuild? { matching.first { $0.id == selectedBuildId } }
    private var versionName: String { "\(Releases.platformName(plan.platform)) \(plan.targetVersion)" }
    private var draftValue: JSONText { .string(selectedBuildId ?? "") }
    private var newer: [TestFlightBuild] { ReleaseWizard.newerBuilds(matching, attachedId: attachedId) }
    /// Whether the step still waits for a newer build: none was uploaded after the version's build, or the newest one is still processing.
    private var waitingForNewer: Bool { replacing && attachedId != nil && newer.first?.processingState != "VALID" }
    /// The newest upload Apple received for the version that is not listed as a build yet.
    private var pendingUpload: BuildDelivery? {
        let after = replacing ? matching.first { $0.id == attachedId }?.uploadedDate : nil
        return ReleaseWizard.pendingUploads(uploads, platform: plan.platform, version: plan.targetVersion, builds: matching, after: after).first
    }
    var body: some View {
        Card(title: "Build for \(plan.targetVersion)", subtitle: "Upload the build with Xcode or Transporter. It appears here once Apple has processed it, usually within 30 minutes. Then add it to the version.",
             actions: AnyView(StorebenchReadButton("Refresh Builds") { await load(fresh: true) })) {
            StorebenchLoadState(state: builds != nil ? .ready : failure.isEmpty ? .loading("Reading builds from App Store Connect…") : .failed(failure, retry: { await load() })) {
                StorebenchReadAge(readAt: readAt, reading: !confirmed)
                if matching.isEmpty && !complete {
                    StorebenchLoadingStatus(message: "Reading more builds for version \(plan.targetVersion)…", surface: false)
                } else if matching.isEmpty, let upload = pendingUpload {
                    uploadLine(upload)
                } else if matching.isEmpty {
                    Text("No processed build for version \(plan.targetVersion) yet. Upload it, wait for processing, then refresh.")
                        .font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
                } else {
                    StorebenchPicker("Build to Submit", selection: Binding(get: { selectedBuildId ?? "" }, set: { selectedBuildId = $0.isEmpty ? nil : $0; review = nil; status = "" })) {
                        selectionOptions([("", "Choose a build")] + matching.map { ($0.id, Self.option($0, attached: $0.id == attachedId ? versionName : nil)) }) { SelectionOption($0.1, value: $0.0) }
                    }.storebenchFormColumn()
                    attachment
                    if replacing { replacement }
                }
                // A first page names only the newest builds; an older one is not reported missing before the rest is read.
                StorebenchTextSlot(text: complete || matching.isEmpty ? "" : "The newest builds are shown. Older builds for version \(plan.targetVersion) are still being read.",
                                   height: 20, font: .sbCaption, color: StorebenchTheme.muted, live: true)
                StorebenchFeedback(text: status, height: 40, error: !status.isEmpty)
                if let draft {
                    // Once its review is prepared, the review's Save below is the one next action.
                    // As in App Store Connect, a build is added once its export compliance is answered.
                    // Add Build stays in place; its hover text names what is still missing.
                    let blocker: String? = !confirmed ? "Wait for the current builds to finish loading" : versionId == nil ? createFirst ?? "Sync the version to Apple in its version step first"
                        : selected == nil ? "Choose a processed build first" : selected?.id == attachedId ? "This build is already added to \(versionName)"
                        : selected?.processingState != "VALID" ? "Wait until Apple finishes processing build \(selected?.version ?? "")"
                        : selected?.usesNonExemptEncryption == nil ? "Answer Export Compliance for this build first" : review != nil ? "Approve or discard the prepared review below" : nil
                    LocalDraftActions(editor: draft, value: draftValue, restore: { selectedBuildId = $0.text.flatMap { $0.isEmpty ? nil : $0 }; review = nil },
                                      blocked: preparing || publishing, sync: { await addBuild() }, syncBlocked: blocker != nil,
                                      title: "Build Selection", hint: blocker ?? "Sync to Apple saves your selection and opens a review that adds this build to the version. The version is submitted in Add for Review.")
                }
            } placeholder: {
                StorebenchPicker("Build to Submit", selection: .constant("")) { SelectionOption("Choose a build", value: "") }.storebenchFormColumn()
                StorebenchActionGroup { Button("Refresh Builds") {} }
            }
        }
        .id("release-build")
        .storebenchWorking(preparing || publishing)
        .task(id: readScope) {
            if reader?.scope != readScope {
                builds = nil; attachedId = nil; confirmed = false; complete = true; uploads = []
                review = nil; readAt = nil; status = ""; failure = ""
            }
            reader?.retire()
            guard let session else { return }
            let account = self.account, appId = self.app.id, versionId = self.versionId, platform = self.plan.platform, version = self.plan.targetVersion
            let owner = ReleaseBuildReader(scope: readScope) { all, latest in
                try await session.releaseBuildPage(account: account, appId: appId, versionId: versionId, platform: platform, version: version, all: all, latest: latest)
            }
            reader = owner
            let local = LocalEditorDraftEditor(scope: .init(accountId: account.id, appId: appId, editor: "release-build", resource: plan.token), session: session)
            draft = local
            if let saved = await local.load(initial: draftValue), let id = saved.text { selectedBuildId = id.isEmpty ? nil : id }
            await load()
            guard owner.active, !Task.isCancelled else { return }
            await readUploads()
            await followUploads()
        }
        .onDisappear { reader?.retire() }
        .onChange(of: matching.map(\.id)) { chooseDefault() }
        // Right after Remove from Review, App Store Connect is read again at once rather than after the first minute.
        .onChange(of: replacing) { if replacing { Task { await load(latest: true); await readUploads() } } }
        .onChange(of: selectedBuildId) { if review?.state == "prepared" { review = nil } }
        .onChange(of: addRequests) { Task { await addBuild() } }
        .trackUnsavedChanges(draft?.dirty(draftValue) == true, busy: preparing || publishing || draft?.busy == true, onSave: { await draft?.saveCurrent(value: { draftValue }) == true })
        .pageRefreshParticipant(readScope,
            state: { .init(dirty: draft?.dirty(draftValue) == true, busy: preparing || publishing || draft?.busy == true || readCount > 0, signature: draftValue.stringify()) },
            save: { await draft?.saveCurrent(value: { draftValue }) == true }, discard: {
                guard let baseline = draft?.baseline else { return false }
                selectedBuildId = baseline.text.flatMap { $0.isEmpty ? nil : $0 }; review = nil; return draft?.dirty(draftValue) == false
            }, refresh: { await load(fresh: true); return confirmed && failure.isEmpty })
        // Export compliance comes right after choosing the build, before Add Build and its review.
        if let build = selected ?? focusedBuild {
            if build.usesNonExemptEncryption == nil {
                BuildEncryptionAnswerCard(account: account, app: app, session: session, build: build, done: { review in
                    // Once the answer is sent, the build list follows Apple without Refresh Builds.
                    if review?.state == "complete" { Task { await followCompliance(build.id) } }
                    done()
                }).id("encryption-\(build.id)")
            } else {
                TestFlightEncryptionView(account: account, app: app, build: build, session: session, didPublish: { Task { await load(fresh: true); done() } }).id("declaration-\(build.id)")
            }
        }
        ReviewPanel(account: account, app: app, session: session, review: $review, done: {
            if review?.state == "complete" { review = nil; Task { await load(fresh: true) }; done() }
        }, busyChanged: { publishing = $0 }, syncConfirmation: true, localDraft: draft).id("release-build-review")
    }
    /// A build as the picker lists it: its number, state, upload day and time, and whether the version has it.
    static func option(_ build: TestFlightBuild, attached version: String?) -> String {
        ["Build \(build.version)", build.usesNonExemptEncryption == nil ? "Missing Compliance" : build.processingState.capitalized,
         AppStoreNames.dateTime(build.uploadedDate).map { "Uploaded \($0)" } ?? "", version.map { "Added to \($0)" } ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }
    /// After Remove from Review: whether a newer build has arrived, or that the step keeps looking for one.
    private var replacement: some View {
        // One fixed track, so the line changing from looking to found never moves the card.
        Group { replacementLine }.frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44, alignment: .topLeading)
    }
    @ViewBuilder private var replacementLine: some View {
        if let build = newer.first, build.processingState == "VALID" {
            StorebenchTextSlot(text: "Build \(build.version) was uploaded \(AppStoreNames.dateTime(build.uploadedDate) ?? "after the current build"). Choose it above, then Sync to Apple adds it to \(versionName).",
                               height: 40, font: .sbCallout, color: StorebenchTheme.ink, live: true)
        } else if newer.first == nil, let upload = pendingUpload {
            uploadLine(upload)
        } else if let build = newer.first {
            StorebenchLoadingStatus(message: "Build \(build.version) was uploaded \(AppStoreNames.dateTime(build.uploadedDate) ?? "") and is processing at Apple. Checking again every minute…", surface: false)
        } else {
            StorebenchLoadingStatus(message: "Looking for a newer build of \(plan.targetVersion). Checking App Store Connect every minute; an upload appears here once Apple has processed it, usually within 30 minutes…", surface: false)
        }
    }
    /// An upload Apple has received but not listed as a build yet: still being processed, or failed with Apple's first message.
    @ViewBuilder private func uploadLine(_ upload: BuildDelivery) -> some View {
        let when = AppStoreNames.dateTime(upload.uploadedDate ?? upload.createdDate).map { " at \($0)" } ?? ""
        if upload.state == "Failed" {
            StorebenchFeedback(text: "Apple could not process build \(upload.buildNumber), uploaded\(when)\(upload.details.first.map { ": " + $0.description } ?? "."). Upload a corrected build; it appears here once Apple has processed it.",
                               height: 40, error: true)
        } else {
            StorebenchLoadingStatus(message: "Build \(upload.buildNumber) reached Apple\(when) and is being processed. It is listed here once Apple finishes, usually within 30 minutes. Checking every minute…", surface: false)
        }
    }
    /// What Apple has for the version's build, and the one next step.
    @ViewBuilder private var attachment: some View {
        if versionId == nil, let createFirst {
            Text(createFirst).font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
            if let syncVersion {
                StorebenchActionGroup {
                    Button("Sync Version to Apple") { syncVersion() }.buttonStyle(StorebenchButtonStyle(.primary))
                        .help("Open step 1 and sync \(versionName) to Apple").storebenchControlID("release.build.sync-version")
                }
            }
        } else if versionId == nil {
            StorebenchStepLink(sentence: "\(versionName) is not in App Store Connect yet. Save it there first, then add the build here.", phaseNumber: 3, phaseTitle: "Save to App Store Connect")
        } else if let selected, selected.id == attachedId {
            Text("Build \(selected.version) is added to \(versionName) at Apple.").font(.sbCallout).fixedSize(horizontal: false, vertical: true)
        } else if let selected, selected.usesNonExemptEncryption == nil {
            StorebenchNotice(title: "Answer export compliance for build \(selected.version) first", description: "Answer the questions below to enable Add Build for \(versionName).", icon: "info") { EmptyView() }
        } else if let selected, let review, review.state == "prepared", review.request.buildId == selected.id {
            // Preparing only shows the change; the build is added when the review below is approved.
            StorebenchNotice(title: "Build \(selected.version) is not added yet", description: "Approve the review below to add it to \(versionName). Nothing changes at Apple before that.", icon: "info") { EmptyView() }
        } else if let selected {
            Text(attachedId == nil ? "Apple has no build for \(versionName) yet. Add Build adds build \(selected.version) to the version. It is not submitted for review yet."
                 : "Apple has a different build for \(versionName). Add Build replaces it with build \(selected.version). It is not submitted for review yet.")
                .font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Choose the build to add to \(versionName).").font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var focusedBuild: TestFlightBuild? {
        guard case .build(let id?, _)? = focus else { return nil }
        return (builds ?? []).first { $0.id == id }
    }
    /// The build Apple already has for the version comes first, then the first valid one.
    private func chooseDefault() {
        let next = ReleaseWizard.chosenBuild(selectedBuildId, matching: matching, attachedId: attachedId, complete: complete, replacing: replacing)
        if next != selectedBuildId { selectedBuildId = next }
    }
    /// How often the step checks App Store Connect while a build for the version is uploading or processing.
    static let uploadCheck: Duration = .seconds(60)
    /// While no build for the version is ready, App Store Connect is checked again every minute, so an upload appears without Refresh Builds.
    private func followUploads() async {
        while !Task.isCancelled {
            do { try await Task.sleep(for: Self.uploadCheck) } catch { return }
            let waiting = builds != nil && (matching.isEmpty || matching.contains { $0.processingState == "PROCESSING" } || waitingForNewer)
            // A background check waits behind the reads the open screen needs.
            if waiting, !preparing, !publishing, review == nil { await ScreenReads.ahead { await load(latest: true); await readUploads() } }
        }
    }
    /// Apple's upload records, read only while the step waits for a build. A failed read keeps the last ones; the build list stays the source of truth.
    private func readUploads() async {
        guard let session, let reader, reader.active, builds != nil, matching.isEmpty || waitingForNewer else { return }
        let account = self.account, appId = app.id
        guard let read = try? await session.buildDeliveries(appId: appId, client: try await session.client(for: account)), reader.active, self.reader === reader, !Task.isCancelled else { return }
        uploads = read
    }
    /// Apple can show a sent export compliance answer on the build a few seconds later, so the build is read again until it does.
    private func followCompliance(_ buildId: String) async {
        await load()
        for wait in [2, 4, 8] {
            guard (builds ?? []).first(where: { $0.id == buildId })?.usesNonExemptEncryption == nil else { return }
            do { try await Task.sleep(for: .seconds(wait)) } catch { return }
            await load(latest: true)
        }
    }
    /// Refresh replaces this step's shared reads; `latest` reads past the cache for an automatic check.
    private func load(fresh: Bool = false, latest: Bool = false) async {
        guard let reader, reader.scope == readScope, reader.active, !Task.isCancelled else { return }
        readCount += 1; defer { readCount -= 1 }
        failure = ""; if !latest { confirmed = false; status = "" }
        if !fresh, builds == nil, let saved = await presentation?.rememberedDecodedRead(buildsKey, as: RememberedBuilds.self), !Task.isCancelled, reader.active, self.reader === reader, builds == nil {
            // A remembered list cannot establish that a chosen build is missing; wait for the new read before replacing it.
            builds = saved.builds; attachedId = saved.versionId == versionId ? saved.attachedId : nil; complete = false; chooseDefault()
            readAt = presentation?.rememberedReadAt(buildsKey)
        }
        guard !Task.isCancelled, reader.active, self.reader === reader else { return }
        await reader.load(fresh: fresh, latest: latest, received: { show($0) }) { error, shown in
            if shown { status = "Older builds for version \(plan.targetVersion) could not be read. Refresh Builds reads them again."; return }
            builds = nil; failure = AppInformation.loadMessage(error, subject: "builds")
        }
    }
    private func show(_ page: ReleaseBuildPage) {
        builds = page.builds; attachedId = page.attachedId; complete = page.complete; confirmed = true; readAt = Date(); chooseDefault()
        presentation?.rememberRead(RememberedBuilds(builds: page.builds, versionId: versionId, attachedId: page.attachedId, complete: page.complete), buildsKey)
    }
    private func addBuild() async {
        guard let reader, reader.scope == readScope, reader.active, !Task.isCancelled,
              !preparing, !publishing, let versionId, let selectedBuildId, selectedBuildId != attachedId else { return }
        preparing = true; defer { preparing = false }
        guard await draft?.save(draftValue) == true else { return }
        let prepared = await preparePublishReview(account, session, PublishRequest(accountId: account.id, appId: app.id, scope: .versionBuild, versionId: versionId, buildId: selectedBuildId))
        guard reader.active, self.reader === reader, self.selectedBuildId == selectedBuildId, !Task.isCancelled else { return }
        (review, status) = prepared
        // The prepared review opens below the build card; bring it into view so the next step is visible.
        if review != nil {
            try? await Task.sleep(for: .milliseconds(100))
            guard reader.active, !Task.isCancelled else { return }
            pageScroll?("release-build-review", .top)
        }
    }
}

/// The builds last read for an app, and the build Apple had for the version they were read with.
/// `complete` is false for a first page of the version's builds; nil for a list read without that limit.
struct RememberedBuilds: Codable, Sendable {
    let builds: [TestFlightBuild], versionId: String?, attachedId: String?
    var complete: Bool? = nil
}
