import StorebenchCore
import SwiftUI

/// App Store Connect's export compliance questions for one build, answered through a Publish review. Encryption that needs a
/// declaration answers Yes, creates or reuses the declaration and attaches it, all in the same review.
struct BuildEncryptionAnswerCard: View {
    /// The caller's review and feedback, shown by the caller's own review panel. Without it the card keeps its own and shows the review below itself.
    struct Shared { var review: Binding<PublishReview?>; var status: Binding<String> }
    let account: Account, app: Account.App, session: WorkspaceSession?, build: TestFlightBuild
    var shared: Shared? = nil
    /// Other work on the page that must finish before an answer is prepared.
    var blocked = false
    var busyChanged: (Bool) -> Void = { _ in }
    var answered: () -> Void = {}
    var cancel: (() -> Void)? = nil
    var done: (PublishReview?) -> Void = { _ in }
    @State private var ownReview: PublishReview?
    @State private var ownStatus = ""
    @State private var preparing = false
    @State private var publishing = false
    @State private var questions = EncryptionQuestionnaire()
    @State private var restored = false
    @Environment(\.pageScroll) private var pageScroll
    private var review: Binding<PublishReview?> { shared?.review ?? $ownReview }
    private var status: Binding<String> { shared?.status ?? $ownStatus }

    var body: some View {
        if shared != nil { card }
        else {
            VStack(alignment: .leading, spacing: 20) {
                card.storebenchWorking(preparing || publishing || ownReview?.state == "running")
                ReviewPanel(account: account, app: app, session: session, review: $ownReview, done: { if ownReview?.state == "complete" { Task { try? await session?.saveEncryptionAnswers(EncryptionQuestionnaire(), accountId: account.id, appId: app.id, buildId: build.id) } }; done(ownReview) }, busyChanged: { publishing = $0; busyChanged(preparing || $0) },
                            fix: { _ in pageScroll?("encryption-questions-\(build.id)", .top) })
                    .storebenchWorking(preparing)
            }
        }
    }

    private var card: some View {
        Card(title: "Export Compliance Information · \(build.title)", subtitle: "App Store Connect's App Encryption Documentation questions. Answer based on the encryption your app actually uses; nothing is sent before you approve the review.") {
            StorebenchChoicePicker(EncryptionAlgorithms.question, selection: $questions.algorithms, options: EncryptionAlgorithms.allCases.map { ($0.rawValue, $0.label) }, style: .radio)
            if let chosen = questions.chosen, !chosen.exempt {
                StorebenchChoicePicker("Is your app going to be available on the App Store in France?", selection: $questions.france, options: [("yes", "Yes"), ("no", "No")], style: .radio)
            }
            Text(questions.nextStep).font(.sbCallout).foregroundStyle(StorebenchTheme.muted).frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading).fixedSize(horizontal: false, vertical: true)
            StorebenchActionGroup(alignment: .leading) {
                // App Store Connect's Save: it shows exactly what is sent, and Send to Apple in that review sends it.
                StorebenchBusyButton(title: "Save", loadingTitle: "Preparing…", busy: preparing, variant: .primary) { Task { await answer() } }
                        .help(questions.missing ?? "Shows exactly what is sent; Send to Apple in the review below sends it to App Store Connect")
                .storebenchWorking(!(questions.missing == nil))
                if let cancel { Button("Cancel") { cancel() } }
            }
            StorebenchFeedback(text: status.wrappedValue, height: 34)
        }
        // The answers are kept for this build as they are given, so they stay until Apple records them.
        .id("encryption-questions-\(build.id)")
        .task(id: build.id) { await restore() }
        .onChange(of: questions) { if restored { let answers = questions; Task { try? await session?.saveEncryptionAnswers(answers, accountId: account.id, appId: app.id, buildId: build.id) } } }
    }

    /// The build's saved answers and, without a shared review, its newest review that is still waiting for Save.
    private func restore() async {
        guard let session else { return }
        questions = (try? await session.encryptionAnswers(accountId: account.id, appId: app.id, buildId: build.id)) ?? EncryptionQuestionnaire()
        restored = true
        guard shared == nil, ownReview == nil, let history = try? await session.publishHistory(accountId: account.id, appId: app.id) else { return }
        ownReview = history.first { review in
            review.request.buildId == build.id && (review.request.scope == .exportCompliance || review.request.testflightAction == "set-encryption-use") && review.waitingForSave
        }
    }

    private func answer() async {
        guard !blocked, !preparing, !publishing, let needed = questions.needsDeclaration else { return }
        preparing = true; busyChanged(true); defer { preparing = false; busyChanged(publishing) }
        if !needed {
            (review.wrappedValue, status.wrappedValue) = await prepareTestFlight(account, app, session, buildId: build.id) { $0.testflightAction = "set-encryption-use"; $0.usesNonExemptEncryption = false }
        } else {
            var request = PublishRequest(accountId: account.id, appId: app.id, scope: .exportCompliance, buildId: build.id)
            request.encryptionDeclaration = questions.answers
            (review.wrappedValue, status.wrappedValue) = await preparePublishReview(account, session, request)
        }
        if review.wrappedValue != nil { answered() }
    }
}
