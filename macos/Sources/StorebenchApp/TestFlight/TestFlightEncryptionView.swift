import StorebenchCore
import SwiftUI

/// Export compliance for a build with an answer at Apple. Every state names one next step: done, wait for Apple,
/// attach an approved declaration, or answer App Store Connect's questions here to create and attach one.
struct TestFlightEncryptionView: View {
    let account: Account, app: Account.App, build: TestFlightBuild, session: WorkspaceSession?
    var busyChanged: (Bool) -> Void = { _ in }
    var didPublish: () -> Void = {}
    @State private var compliance: BuildExportCompliance?
    @State private var failure = ""
    @State private var declarationId = ""
    @State private var creating = false
    @State private var encryption = EncryptionQuestionnaire()
    @State private var working = false
    @State private var readAt: Date?
    @State private var publishing = false
    @State private var status = ""
    @State private var review: PublishReview?
    @Environment(\.navigationPresentation) private var history
    private var readKey: String { "build-compliance/\(account.id)/\(app.id)/\(build.id)" }
    private var busy: Bool { working || publishing }
    private var answered: Bool { encryption.started || (!declarationId.isEmpty && declarationId != compliance?.currentId) }
    private var appInformation: URL { URL(string: "https://appstoreconnect.apple.com/apps/\(app.id)/distribution/info")! }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card(title: "Export Compliance Information · \(build.title)", subtitle: "Apple needs this for each build before it can be submitted for review.") {
                if build.usesNonExemptEncryption == false {
                    Text("Apple records that this build doesn't use non-exempt encryption, so it needs no declaration. This step is complete.")
                        .font(.sbCallout).fixedSize(horizontal: false, vertical: true)
                } else {
                    StorebenchLoadState(state: compliance != nil ? .ready : failure.isEmpty ? .loading("Reading Apple's declarations…") : .failed(failure, retry: { await load(fresh: true) })) {
                        StorebenchReadAge(readAt: readAt, reading: working)
                        if let compliance { content(compliance) }
                    } placeholder: {
                        Text("Current declaration: placeholder").font(.sbCallout)
                        StorebenchPicker("Approved declaration", selection: .constant("")) { SelectionOption("Choose a declaration", value: "") }.storebenchFormColumn()
                    }
                    StorebenchFeedback(text: status, height: 40, error: !status.isEmpty)
                    StorebenchActionGroup(alignment: .leading) {
                        if compliance != nil { StorebenchBusyButton(title: "Refresh Declarations", loadingTitle: "Reading…", busy: working) { Task { await load(fresh: true) } } }
                        StorebenchActionLink("Open in Browser", destination: appInformation, help: "Open App Information in App Store Connect, where App Encryption Documentation lists this app's declarations")
                    }
                }
            }.storebenchWorking(busy)
            if compliance?.next == .waiting {
                // Apple may ask for documents before it approves a declaration; they are uploaded here through their own review.
                ExportComplianceCard(account: account, app: app, session: session, prepare: { request in await prepare(request) }, changed: { review = nil }, offersNewDeclaration: false)
            }
            ReviewPanel(account: account, app: app, session: session, review: $review, done: { if review?.state == "complete" { reset(); didPublish() }; Task { await load(fresh: true) } }, busyChanged: { publishing = $0 })
        }
        .task(id: build.id) { await load() }
        .onChange(of: busy) { busyChanged(busy) }
        .onDisappear { busyChanged(false) }
        .trackUnsavedChanges(answered, busy: busy)
    }

    @ViewBuilder private func content(_ compliance: BuildExportCompliance) -> some View {
        Text("Current declaration: " + (compliance.currentId.map { id in compliance.current.map(describe) ?? id } ?? "None"))
            .font(.sbCallout).lineLimit(3).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        switch compliance.next {
        case .done:
            Text("Apple approved this declaration. This step is complete.").font(.sbCallout).fixedSize(horizontal: false, vertical: true)
        case .waiting:
            Text("Apple is reviewing this declaration. If Apple asks for documents, upload them below. Apple usually decides within two business days; refresh to see its decision.")
                .font(.sbCallout).fixedSize(horizontal: false, vertical: true)
        case .choose:
            StorebenchPicker("Approved declaration", selection: $declarationId) {
                SelectionOption("Choose a declaration", value: "")
                selectionOptions(compliance.approved.filter { $0.id != compliance.currentId }) { SelectionOption(describe($0), value: $0.id) }
            }.storebenchFormColumn().onChange(of: declarationId) { if !declarationId.isEmpty { creating = false } }
            if !creating {
                StorebenchActionGroup(alignment: .leading) {
                    StorebenchBusyButton(title: "Prepare Review", loadingTitle: "Preparing…", busy: working, variant: .primary) { Task { await assign() } }
                        .help(declarationId.isEmpty ? "Choose an approved declaration first" : "Prepare a review that attaches this declaration to the build")
                        .storebenchWorking(declarationId.isEmpty)
                    Button("New Declaration") { declarationId = ""; creating = true }.help("None of these describes this build? Answer App Store Connect's questions instead.")
                }
            }
            if creating { questions }
        case .create:
            Text(compliance.declarations.isEmpty ? "This app has no export compliance declaration at Apple yet. Answer App Store Connect's questions below to create one and attach it to this build."
                 : "None of this app's declarations is approved for \(Releases.platformName(build.platform)). Answer App Store Connect's questions below to create one and attach it to this build.")
                .font(.sbCallout).fixedSize(horizontal: false, vertical: true)
            questions
        }
    }

    /// App Store Connect's encryption. Encryption limited to the operating system answers No for the build instead of creating a declaration.
    @ViewBuilder private var questions: some View {
        StorebenchChoicePicker(EncryptionAlgorithms.question, selection: $encryption.algorithms, options: EncryptionAlgorithms.allCases.map { ($0.rawValue, $0.label) }, style: .radio)
        if let chosen = encryption.chosen, !chosen.exempt {
            StorebenchChoicePicker("Is your app going to be available on the App Store in France?", selection: $encryption.france, options: [("yes", "Yes"), ("no", "No")], style: .radio)
        }
        Text(encryption.nextStep).font(.sbCallout).foregroundStyle(StorebenchTheme.muted).frame(minHeight: 40, alignment: .topLeading).fixedSize(horizontal: false, vertical: true)
        StorebenchActionGroup(alignment: .leading) {
            StorebenchBusyButton(title: "Save", loadingTitle: "Preparing…", busy: working, variant: .primary) { Task { await answer() } }
                    .help(encryption.missing ?? "Shows exactly what is sent; Send to Apple in the review below sends it to App Store Connect")
                .storebenchWorking(!(encryption.missing == nil))
            if compliance?.next == .choose { Button("Cancel") { reset() } }
        }
    }

    private func describe(_ declaration: EncryptionDeclaration) -> String {
        "\(declaration.description.isEmpty ? declaration.id : declaration.description) · \(AppStoreNames.state(declaration.state))"
    }
    private func reset() { creating = false; encryption = EncryptionQuestionnaire(); declarationId = "" }

    private func load(fresh: Bool = false) async {
        await ScreenReads.reading(fresh: fresh) {
            guard !busy, let session, build.usesNonExemptEncryption != false else { return }
            working = true; defer { working = false }
            failure = ""
            // The declarations read earlier in this window show at once; actions stay busy until Apple is read again.
            if !fresh, compliance == nil, let saved = history?.rememberedRead(readKey, as: BuildExportCompliance.self) { compliance = saved; readAt = history?.rememberedReadAt(readKey) }
            do {
                let value = try await session.buildExportCompliance(appId: app.id, buildId: build.id, platform: build.platform, client: try await session.readClient(for: account))
                try Task.checkCancellation()
                compliance = value; status = ""; readAt = Date(); history?.rememberRead(value, readKey)
                if !value.approved.contains(where: { $0.id == declarationId }) { declarationId = "" }
            } catch {
                guard !Task.isCancelled else { return }
                compliance = nil; failure = AppInformation.loadMessage(error, subject: "this build's export compliance")
            }
        }
    }
    private func assign() async {
        guard !busy, compliance != nil else { return }
        working = true; defer { working = false }
        (review, status) = await prepareTestFlight(account, app, session, buildId: build.id) { $0.testflightAction = "assign-encryption-declaration"; $0.declarationId = declarationId }
    }
    private func answer() async {
        guard !busy, let needed = encryption.needsDeclaration else { return }
        working = true; defer { working = false }
        if !needed {
            (review, status) = await prepareTestFlight(account, app, session, buildId: build.id) { $0.testflightAction = "set-encryption-use"; $0.usesNonExemptEncryption = false }
        } else {
            var request = PublishRequest(accountId: account.id, appId: app.id, scope: .exportCompliance, buildId: build.id)
            request.encryptionDeclaration = encryption.answers
            (review, status) = await preparePublishReview(account, session, request)
        }
    }
    private func prepare(_ request: PublishRequest) async {
        guard !busy else { return }
        working = true; defer { working = false }
        (review, status) = await preparePublishReview(account, session, request)
    }
}
