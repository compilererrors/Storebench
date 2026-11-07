import StorebenchCore
import SwiftUI

struct TestFlightBuildAccessView: View {
    let account: Account, app: Account.App, build: TestFlightBuild, session: WorkspaceSession?
    var busyChanged: (Bool) -> Void = { _ in }
    var didPublish: () -> Void = {}
    @State private var assigned: [TestFlightTester] = []
    @State private var testers: [TestFlightTester] = []
    @State private var testerId = ""
    @State private var email = ""
    @State private var automatic = ""
    @State private var loaded = false
    @State private var readAt: Date?
    @State private var reading = false
    @State private var publishing = false
    @State private var status = ""
    @State private var notificationStatus = ""
    /// The review being prepared, so its command shows that it is working.
    @State private var preparing = ""
    @State private var review: PublishReview?
    @Environment(\.navigationPresentation) private var history
    private struct Read { let assigned: [TestFlightTester], testers: [TestFlightTester] }
    private var readKey: String { "build-access/\(account.id)/\(app.id)/\(build.id)" }
    private var busy: Bool { reading || publishing || !preparing.isEmpty }
    private var baseline: String { build.autoNotifyEnabled.map { $0 ? "on" : "off" } ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card(title: "Individual testers · \(build.title)", subtitle: "Direct access to this build. Apple controls invitation delivery and eligibility.") {
                StorebenchCollection(items: assigned, title: { $0.email }, subtitle: { $0.name }, empty: loaded ? "No individual testers assigned to this build." : "Reading individual testers…") { tester in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading) {
                            Text(tester.email).lineLimit(2).textSelection(.enabled)
                            Text(AppStoreNames.state(tester.state)).font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
                        }
                        Spacer()
                        Button(role: .destructive) { Task { await prepare("remove-\(tester.id)") { $0.testflightAction = "remove-individual-tester"; $0.testerId = tester.id } } } label: {
                            StorebenchBusyLabel("Review Removal", loading: "Preparing…", busy: preparing == "remove-\(tester.id)")
                        }.storebenchWorking(busy).fixedSize()
                    }
                }
                StorebenchDivider()
                StorebenchReadAge(readAt: loaded ? readAt : nil, reading: reading)
                if loaded && build.processed {
                    StorebenchPicker("Existing app tester", selection: $testerId) {
                        SelectionOption("Choose a tester", value: "")
                        selectionOptions(testers.filter { candidate in !assigned.contains { $0.id == candidate.id } }) { SelectionOption($0.email, value: $0.id) }
                    }.storebenchFormColumn()
                    if build.audience == "APP_STORE_ELIGIBLE" { StorebenchTextField("Tester email", text: $email).storebenchFormColumn() }
                    else { Text("Invitations by email need a build that Apple lists as eligible for the App Store.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted) }
                } else if loaded {
                    Text("Apple must finish processing this build before you can give testers access.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
                }
                Text("A tester in an app group must get build access through that group. Removing direct access keeps any access granted by a group.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
                StorebenchFormFooter {
                    Button { Task { await load(fresh: true) } } label: { StorebenchBusyLabel("Refresh Access", loading: "Reading…", busy: reading) }.help("Refresh Individual Access")
                    if loaded && !testerId.isEmpty && build.processed {
                        Button { Task { await prepare("assign") { $0.testflightAction = "assign-individual-tester"; $0.testerId = testerId } } } label: {
                            StorebenchBusyLabel("Review Assignment", loading: "Preparing…", busy: preparing == "assign")
                        }.help("Prepare a review that gives this tester access to \(build.title)")
                    }
                    if loaded && !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && build.processed && build.audience == "APP_STORE_ELIGIBLE" {
                        Button { Task { await prepare("invite") { $0.testflightAction = "invite-individual-tester"; $0.testerEmail = email } } } label: {
                            StorebenchBusyLabel("Review Invitation", loading: "Preparing…", busy: preparing == "invite")
                        }.help("Prepare a review that invites this email to \(build.title)")
                    }
                }.storebenchWorking(busy)
                StorebenchFeedback(text: status, height: 40)
            }.storebenchWorking(publishing)
            Card(title: "Automatic tester notification", subtitle: "Choose whether Apple should notify assigned testers when this build is approved for external testing.") {
                Text("Current setting: \(baseline.isEmpty ? "Unknown" : baseline == "on" ? "On" : "Off")").font(.sbHeadline)
                if build.canSetAutomaticNotification {
                    StorebenchPicker("Automatic notification", selection: $automatic) {
                        SelectionOption("Choose On or Off", value: "")
                        SelectionOption("On", value: "on")
                        SelectionOption("Off", value: "off")
                    }.storebenchFormColumn()
                }
                Text(build.canSetAutomaticNotification ? "Available before beta approval. This setting does not itself start testing." : "Apple must confirm a processed, unexpired build awaiting external beta submission or review, and its current On or Off setting.")
                    .font(.sbCallout).foregroundStyle(StorebenchTheme.muted).frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
                if build.canSetAutomaticNotification && !automatic.isEmpty && automatic != baseline {
                    StorebenchFormFooter {
                        Button { Task { await prepare("notify") { $0.testflightAction = "set-auto-notify"; $0.autoNotifyEnabled = automatic == "on" } } } label: {
                            StorebenchBusyLabel("Review Notification", loading: "Preparing…", busy: preparing == "notify")
                        }.help("Review Notification Change")
                    }
                }
                StorebenchFeedback(text: notificationStatus, height: 40)
            }.storebenchWorking(busy)
            ReviewPanel(account: account, app: app, session: session, review: $review, done: {
                if review?.state == "complete" { email = ""; testerId = ""; automatic = ""; didPublish() }
                Task { await load() }
            }, busyChanged: { publishing = $0 })
        }
        .task(id: build.id) {
            automatic = baseline
            // The testers last read, or read ahead by Start Testing, show at once while Apple's current answer is read.
            if !loaded, let read = history?.rememberedRead(readKey, as: Read.self) { assigned = read.assigned; testers = read.testers; loaded = true; readAt = history?.rememberedReadAt(readKey) }
            await load()
        }
        .onChange(of: busy) { busyChanged(busy) }
        .onChange(of: baseline) { previous, current in if automatic.isEmpty || automatic == previous { automatic = current } }
        .onDisappear { busyChanged(false) }
        .trackUnsavedChanges(!email.isEmpty || (!automatic.isEmpty && automatic != baseline), busy: busy)
    }
    private func load(fresh: Bool = false) async {
        await ScreenReads.reading(fresh: fresh) {
            guard !busy, let session else { return }
            reading = true; status = ""
            defer { reading = false }
            do {
                let (members, candidates) = try await session.individualBuildAccess(account: account, appId: app.id, buildId: build.id)
                try Task.checkCancellation()
                assigned = members; testers = candidates; loaded = true; readAt = Date()
                history?.rememberRead(Read(assigned: members, testers: candidates), readKey)
                if !testers.contains(where: { $0.id == testerId }) || assigned.contains(where: { $0.id == testerId }) { testerId = "" }
            } catch is CancellationError { }
            catch { assigned = []; testers = []; status = "Individual tester access could not be confirmed. Refresh before preparing a review." }
        }
    }
    /// Prepares one review. Its command shows Preparing… meanwhile, and a problem shows under the card it came from.
    private func prepare(_ action: String, _ configure: (inout PublishRequest) -> Void) async {
        guard !busy else { return }
        preparing = action; defer { preparing = "" }
        status = ""; notificationStatus = ""
        let (prepared, problem) = await prepareTestFlight(account, app, session, buildId: build.id, configure)
        review = prepared
        if action == "notify" { notificationStatus = problem } else { status = problem }
    }
}
