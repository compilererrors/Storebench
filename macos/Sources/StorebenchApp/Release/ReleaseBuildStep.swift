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
    var body: some View {
        Card(title: "Build for \(plan.targetVersion)", subtitle: "Upload the build with Xcode or Transporter. It appears here once Apple has processed it, usually within 30 minutes. Then add it to the version.") {
            StorebenchLoadState(state: builds != nil ? .ready : failure.isEmpty ? .loading("Reading builds from App Store Connect…") : .failed(failure, retry: { await load() })) {
                StorebenchReadAge(readAt: readAt, reading: !confirmed)
                if matching.isEmpty && !complete {
                    StorebenchLoadingStatus(message: "Reading more builds for version \(plan.targetVersion)…", surface: false)
                } else if matching.isEmpty {
                    Text("No processed build for version \(plan.targetVersion) yet. Upload it, wait for processing, then refresh.")
                        .font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
                } else {
                    StorebenchPicker("Build to submit", selection: Binding(get: { selectedBuildId ?? "" }, set: { selectedBuildId = $0.isEmpty ? nil : $0; review = nil; status = "" })) {
                        selectionOptions([("", "Choose a build")] + matching.map { ($0.id, "Build \($0.version) · \($0.usesNonExemptEncryption == nil ? "Missing Compliance" : $0.processingState.capitalized)\($0.id == attachedId ? " · Added to \(versionName)" : "")") }) { SelectionOption($0.1, value: $0.0) }
                    }.storebenchFormColumn()
                    attachment
                }
                // A first page names only the newest builds; an older one is not reported missing before the rest is read.
                StorebenchTextSlot(text: complete || matching.isEmpty ? "" : "The newest builds are shown. Older builds for version \(plan.targetVersion) are still being read.",
                                   height: 20, font: .sbCaption, color: StorebenchTheme.muted, live: true)
                StorebenchFeedback(text: status, height: 40, error: !status.isEmpty)
                StorebenchActionGroup(alignment: .leading) {
                    // Once its review is prepared, Send to Apple in the review below is the one next action.
                    // As in App Store Connect, a build is added once its export compliance is answered.
                    // Add Build stays in place; its hover text names what is still missing.
                    let blocker: String? = !confirmed ? "Save this step's changes on this Mac first" : versionId == nil ? "Save the version to App Store Connect in step 3 first"
                        : selected == nil ? "Choose a processed build first" : selected?.id == attachedId ? "This build is already added to \(versionName)"
                        : selected?.usesNonExemptEncryption == nil ? "Answer Export Compliance for this build first" : review != nil ? "Approve or discard the prepared review below" : nil
                    StorebenchBusyButton(title: "Add Build", loadingTitle: "Preparing…", busy: preparing, variant: .primary) { Task { await addBuild() } }
                        .storebenchWorking(blocker != nil && !preparing)
                        .help(blocker ?? "Prepare a review that adds build \(selected?.version ?? "") to \(versionName) at Apple")
                    StorebenchReadButton("Refresh Builds") { await load(fresh: true) }
                }
            } placeholder: {
                StorebenchPicker("Build to submit", selection: .constant("")) { SelectionOption("Choose a build", value: "") }.storebenchFormColumn()
                StorebenchActionGroup { Button("Refresh Builds") {} }
            }
        }
        .id("release-build")
        .storebenchWorking(preparing || publishing)
        .task(id: readScope) {
            if reader?.scope != readScope {
                builds = nil; attachedId = nil; confirmed = false; complete = true
                review = nil; readAt = nil; status = ""; failure = ""
            }
            reader?.retire()
            guard let session else { return }
            let account = self.account, appId = self.app.id, versionId = self.versionId, platform = self.plan.platform, version = self.plan.targetVersion
            let owner = ReleaseBuildReader(scope: readScope) { all, latest in
                try await session.releaseBuildPage(account: account, appId: appId, versionId: versionId, platform: platform, version: version, all: all, latest: latest)
            }
            reader = owner
            await load()
            guard owner.active, !Task.isCancelled else { return }
            await followUploads()
        }
        .onDisappear { reader?.retire() }
        .onChange(of: matching.map(\.id)) { chooseDefault() }
        .onChange(of: addRequests) { Task { await addBuild() } }
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
        }, busyChanged: { publishing = $0 }).id("release-build-review")
    }
    /// What Apple has for the version's build, and the one next step.
    @ViewBuilder private var attachment: some View {
        if versionId == nil, let createFirst {
            Text(createFirst).font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
        } else if versionId == nil {
            StorebenchStepLink(sentence: "\(versionName) is not in App Store Connect yet. Save it there first, then add the build here.", phaseNumber: 3, phaseTitle: "Save to App Store Connect")
        } else if let selected, selected.id == attachedId {
            Text("Build \(selected.version) is added to \(versionName) at Apple.").font(.sbCallout).fixedSize(horizontal: false, vertical: true)
        } else if let selected, selected.usesNonExemptEncryption == nil {
            StorebenchNotice(title: "Answer export compliance for build \(selected.version) first", description: "Apple asks whether the build uses encryption before it can be added to \(versionName). The questions are right below; Add Build appears once they are answered.", icon: "info") { EmptyView() }
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
        let next = ReleaseWizard.chosenBuild(selectedBuildId, matching: matching, attachedId: attachedId, complete: complete)
        if next != selectedBuildId { selectedBuildId = next }
    }
    /// How often the step checks App Store Connect while a build for the version is uploading or processing.
    static let uploadCheck: Duration = .seconds(60)
    /// While no build for the version is ready, App Store Connect is checked again every minute, so an upload appears without Refresh Builds.
    private func followUploads() async {
        while !Task.isCancelled {
            do { try await Task.sleep(for: Self.uploadCheck) } catch { return }
            let waiting = builds != nil && (matching.isEmpty || matching.contains { $0.processingState == "PROCESSING" })
            // A background check waits behind the reads the open screen needs.
            if waiting, !preparing, !publishing, review == nil { await ScreenReads.ahead { await load(latest: true) } }
        }
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
