import StorebenchCore
import SwiftUI

/// One beta language owns its inputs and protected publishing review through page changes.
struct TestFlightLanguageInformationEditor: View {
    let account: Account, app: Account.App, session: WorkspaceSession?, source: TestFlightLocalization
    let available, parentBusy: Bool
    let summaryChanged: (String) -> Void, busyChanged: (Bool) -> Void
    @State private var draft: LocalEditorDraftEditor?
    @State private var baseline: TestFlightLocalization
    @State private var betaDescription: String
    @State private var feedbackEmail: String
    @State private var marketingUrl: String
    @State private var privacyPolicyUrl: String
    @State private var tvOsPrivacyPolicy: String
    @State private var review: PublishReview?
    @State private var working = false
    @State private var publishing = false
    @State private var status = ""
    @Environment(\.editorProtection) private var protection
    init(account: Account, app: Account.App, session: WorkspaceSession?, source: TestFlightLocalization, available: Bool, parentBusy: Bool,
         summaryChanged: @escaping (String) -> Void, busyChanged: @escaping (Bool) -> Void) {
        self.account = account; self.app = app; self.session = session; self.source = source; self.available = available; self.parentBusy = parentBusy
        self.summaryChanged = summaryChanged; self.busyChanged = busyChanged
        _baseline = State(initialValue: source); _betaDescription = State(initialValue: source.description); _feedbackEmail = State(initialValue: source.feedbackEmail)
        _marketingUrl = State(initialValue: source.marketingUrl); _privacyPolicyUrl = State(initialValue: source.privacyPolicyUrl); _tvOsPrivacyPolicy = State(initialValue: source.tvOsPrivacyPolicy)
    }
    private var edited: TestFlightLocalization { .init(locale: source.locale, description: betaDescription, feedbackEmail: feedbackEmail, marketingUrl: marketingUrl, privacyPolicyUrl: privacyPolicyUrl, tvOsPrivacyPolicy: tvOsPrivacyPolicy) }
    private var dirty: Bool { edited != baseline }
    private var busy: Bool { working || publishing }
    private var blocked: Bool { busy || parentBusy || !available }
    private var locked: Bool { busy || parentBusy || draft?.loaded != true }
    private var complete: Bool { !betaDescription.isEmpty && !feedbackEmail.isEmpty && betaDescription.utf16.count <= 4000 }
    private var summary: String { busy ? "Working…" : dirty ? "Unsaved TestFlight information" : "Current TestFlight information" }
    private var draftValue: JSONText { .object([("description", .string(betaDescription)), ("feedbackEmail", .string(feedbackEmail)), ("marketingUrl", .string(marketingUrl)), ("privacyPolicyUrl", .string(privacyPolicyUrl)), ("tvOsPrivacyPolicy", .string(tvOsPrivacyPolicy))]) }
    private func restoreDraft(_ value: JSONText) {
        betaDescription = value["description"]?.text ?? ""; feedbackEmail = value["feedbackEmail"]?.text ?? ""
        marketingUrl = value["marketingUrl"]?.text ?? ""; privacyPolicyUrl = value["privacyPolicyUrl"]?.text ?? ""
        tvOsPrivacyPolicy = value["tvOsPrivacyPolicy"]?.text ?? ""; review = nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: StorebenchTheme.gap) {
            if !available { Text("Read languages from Apple before changing this language.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted) }
            else {
            Text("Existing links and privacy text can be replaced; Apple does not allow clearing them.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
            StorebenchTextArea(title: "Beta App Description", text: $betaDescription, height: 120).storebenchWorking(locked)
            Text("\(betaDescription.utf16.count) of 4,000 characters").font(.sbCaption).foregroundStyle(betaDescription.utf16.count > 4000 ? StorebenchTheme.color("color-danger") : StorebenchTheme.muted)
            StorebenchFormGrid {
                StorebenchTextField("Feedback email", text: $feedbackEmail)
                StorebenchTextField("Marketing URL", text: $marketingUrl, hint: "Optional HTTPS link")
                StorebenchTextField("Privacy policy URL", text: $privacyPolicyUrl, hint: "Optional HTTPS link")
            }.storebenchWorking(locked)
            StorebenchTextArea(title: "tvOS privacy policy (optional)", text: $tvOsPrivacyPolicy, height: StorebenchTheme.textarea(rows: 2)).storebenchWorking(locked)
            StorebenchTextSlot(text: !dirty ? "" : complete ? "Not sent yet. Save Draft keeps these changes on this Mac. Sync to Apple prepares them for your approval." : "Enter a beta app description of up to 4,000 characters and a feedback email, then choose Prepare Review.",
                               height: 34, font: .sbCaption, color: dirty && !complete ? StorebenchTheme.color("color-danger") : StorebenchTheme.muted, live: true)
            StorebenchFeedback(text: status, height: 40)
            StorebenchFormFooter {
                Button("Read from Apple") { if !blocked, protection?.allowLeaving() != false { Task { await read() } } }.help("Read Language from Apple").accessibilityLabel("Read Language from Apple")

            }.storebenchWorking(busy || parentBusy)
            if let draft { LocalDraftActions(editor: draft, value: draftValue, restore: restoreDraft, blocked: busy || parentBusy, sync: { await prepare() }, syncBlocked: !dirty || !complete || !available) }
            }
            ReviewPanel(account: account, app: app, session: session, review: $review, done: { if review?.state == "complete" { Task { await read() } } }, busyChanged: { publishing = $0 }, syncConfirmation: true)
                .storebenchWorking(working || parentBusy && !publishing)
        }.trackUnsavedChanges(draft?.dirty(draftValue) == true, busy: busy || draft?.busy == true, onSave: { await draft?.saveCurrent(value: { draftValue }) == true })
            .task(id: source.locale) {
                guard let session else { return }
                let owner = LocalEditorDraftEditor(scope: .init(accountId: account.id, appId: app.id, editor: "testflight-language", resource: source.locale), session: session)
                draft = owner
                if let saved = await owner.load(initial: draftValue) { restoreDraft(saved) }
            }
            .onChange(of: busy) { busyChanged(busy) }
            .onChange(of: summary, initial: true) { summaryChanged(summary) }
            .onChange(of: edited) { if !busy, review?.state == "prepared" { review = nil } }
            .onChange(of: source) {
                if !dirty, !busy, review == nil { use(source) }
                else if source != baseline { status = "Apple's language information changed. Your inputs are kept. Read and compare before preparing another review." }
            }
    }
    private func use(_ value: TestFlightLocalization) {
        baseline = value; betaDescription = value.description; feedbackEmail = value.feedbackEmail; marketingUrl = value.marketingUrl
        privacyPolicyUrl = value.privacyPolicyUrl; tvOsPrivacyPolicy = value.tvOsPrivacyPolicy; review = nil
    }
    private func read() async {
        guard !busy, let session else { return }
        working = true; defer { working = false }
        do {
            let values = try await session.testFlightAppInformation(appId: app.id, client: try await session.client(for: account))
            let value = values.first { $0.locale == source.locale } ?? .init(locale: source.locale, description: "", feedbackEmail: "")
            try Task.checkCancellation(); use(value); status = "Current language information read from Apple."
        } catch { status = "This language could not be read. Your inputs are kept." }
    }
    private func prepare() async {
        guard !blocked else { return }
        working = true; defer { working = false }
        guard await draft?.save(draftValue) == true, draft?.dirty(draftValue) == false else { return }
        let inputs = edited
        (review, status) = await prepareTestFlight(account, app, session) {
            $0.testflightAction = "save-beta-info"; $0.locale = inputs.locale; $0.betaDescription = inputs.description; $0.feedbackEmail = inputs.feedbackEmail
            $0.betaMarketingUrl = inputs.marketingUrl; $0.betaPrivacyPolicyUrl = inputs.privacyPolicyUrl; $0.betaTvOsPrivacyPolicy = inputs.tvOsPrivacyPolicy
        }
    }
}
