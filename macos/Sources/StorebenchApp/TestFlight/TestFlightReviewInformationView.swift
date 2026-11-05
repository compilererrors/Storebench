import StorebenchCore
import SwiftUI

struct TestFlightReviewInformationView: View {
    let account: Account, app: Account.App, session: WorkspaceSession?
    @State private var latestReading = false
    @State private var fields = ReviewInformation()
    @State private var savedFields = ReviewInformation()
    @State private var revision = 0
    @State private var loaded = false
    @State private var working = false
    @State private var publishing = false
    @State private var status = ""
    @State private var problem = false
    @State private var latest: TestFlightReviewInformationDraft?
    @State private var remote: ReviewInformation?
    @State private var review: PublishReview?
    private var dirty: Bool { fields != savedFields }
    private var busy: Bool { working || publishing }
    private var comparison: [SavedValueChange]? {
        guard let latest else { return nil }
        var changes = fields.display.utf8.elementsEqual(latest.fields.display.utf8) ? [] : [SavedValueChange(id: "details", label: "Beta review information", saved: latest.fields.display, edited: fields.display)]
        if !fields.demoAccountPassword.utf8.elementsEqual(latest.fields.demoAccountPassword.utf8) {
            changes.append(SavedValueChange(id: "password", label: "Demo password", saved: latest.fields.demoAccountPassword.isEmpty ? "Missing" : "Set", edited: fields.demoAccountPassword.isEmpty ? "Missing" : "Changed; contents hidden"))
        }
        return changes
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card(title: "TestFlight Beta App Review Information", subtitle: "Contact, demo account and notes for external beta review. Save a local draft, then prepare and approve a separate Publish review.") {
                if loaded {
                Group {
                    StorebenchFormGrid() {
                        StorebenchTextField("First name", text: $fields.contactFirstName)
                        StorebenchTextField("Last name", text: $fields.contactLastName)
                        StorebenchTextField("Phone number", text: $fields.contactPhone)
                        StorebenchTextField("Email", text: $fields.contactEmail)
                    }.environment(\.fieldHintHeight, 17)
                    Toggle("Sign-in required", isOn: $fields.demoAccountRequired)
                    if fields.demoAccountRequired {
                        StorebenchFormGrid() {
                            StorebenchTextField("User name", text: $fields.demoAccountName)
                            StorebenchSecureField("Password", text: $fields.demoAccountPassword)
                        }.environment(\.fieldHintHeight, 17)
                    }
                    Text("Reviewer notes").font(.sbHeadline)
                    StorebenchTextArea(text: $fields.notes, height: StorebenchTheme.textarea(rows: 2)).accessibilityLabel("Beta reviewer notes")
                }.storebenchWorking(busy)
                }
                StorebenchFeedback(text: status, height: 40, error: problem)
                LatestSaveReview(busy: busy || !loaded, reading: latestReading, hasEdits: dirty, available: loaded, changes: comparison, note: latest.map { "Saved draft revision \($0.revision). Password contents stay hidden. Choosing a baseline does not save." }, onRead: { Task { await readLatest() } },
                                 onKeep: latest == nil ? nil : { chooseLatest(useSaved: false) }, onUse: latest == nil ? nil : { chooseLatest(useSaved: true) })
                StorebenchFormFooter { actions }
            }.storebenchWorking(busy)
            if let remote {
                Card(title: "Current beta review details at Apple", subtitle: "Read for comparison. This read does not save a draft or send a change to Apple; demo password contents are hidden.") {
                    ScrollView { Text(remote.display).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 220)
                    StorebenchFormFooter {
                        Button("Keep My Inputs") { if !busy { self.remote = nil } }
                        Button("Use Apple Values") { if !busy { fields = remote; self.remote = nil; review = nil } }.help("Use Apple Values in Editor").accessibilityLabel("Use Apple Values in Editor")
                    }.storebenchWorking(busy)
                }
            }
            ReviewPanel(account: account, app: app, session: session, review: $review, busyChanged: { publishing = $0 })
        }
        .task(id: "\(account.id):\(app.id)") { await load() }
        .trackUnsavedChanges(dirty, busy: busy, problem: { problem ? "TestFlight Beta App Review Information: " + status : nil }, onSave: { await save(); return !dirty })
    }
    @ViewBuilder private var actions: some View {
        if !loaded { Button("Read Saved Draft") { Task { await load() } } }
        if loaded { Button("Compare with Apple") { Task { await readApple() } } }
        Button("Prepare Review") { Task { await prepare() } }.storebenchWorking(!(revision > 0 && !dirty))
        Button("Save Draft") { Task { await save() } }.buttonStyle(StorebenchButtonStyle(.primary)).storebenchWorking(!(loaded && dirty))
    }
    private func load() async {
        guard !busy, let session else { return }
        working = true; defer { working = false }
        do {
            let saved = try await session.testFlightReviewInformationDraft(accountId: account.id, appId: app.id)
            fields = saved.fields; savedFields = fields; revision = saved.revision; loaded = true; status = ""
        } catch { status = "Saved beta review information could not be read. Nothing was changed." }
    }
    private func readLatest() async {
        guard !busy, let session else { return }
        latestReading = true; defer { latestReading = false }
        working = true; defer { working = false }
        do { latest = try await session.testFlightReviewInformationDraft(accountId: account.id, appId: app.id); status = "Latest save read. Your inputs and editor revision are unchanged." }
        catch { latest = nil; status = "Latest saved beta review information could not be read. Your inputs remain here." }
    }
    private func chooseLatest(useSaved: Bool) {
        guard !busy, let latest else { return }
        if useSaved { fields = latest.fields }
        savedFields = latest.fields; revision = latest.revision; self.latest = nil; review = nil
        status = useSaved ? "Saved values loaded into the editor. Nothing was saved." : "Your inputs kept against the chosen saved revision. Nothing was saved."
    }
    private func readApple() async {
        guard !busy, let session else { return }
        working = true; defer { working = false }
        do { remote = try await session.testFlightReviewInformationFromApple(appId: app.id, client: try await session.client(for: account)); status = remote == nil ? "Apple has no beta review information for this app yet." : "Apple values read for comparison; editor inputs are unchanged." }
        catch { remote = nil; status = "Apple's beta review information could not be confirmed. Your inputs remain here." }
    }
    private func save() async {
        guard !busy, loaded, let session else { return }
        working = true; defer { working = false }
        do {
            let saved = try await session.saveTestFlightReviewInformationDraft(accountId: account.id, appId: app.id, fields: fields, expectedRevision: revision)
            fields = saved.fields; savedFields = fields; revision = saved.revision; review = nil; latest = nil; problem = false; status = "Saved encrypted on this Mac. Nothing was sent to Apple."
        } catch let failure as PublishFailure { problem = true; status = "Not saved. " + failure.message }
        catch { problem = true; status = "Not saved. Your inputs remain here; try again." }
    }
    private func prepare() async {
        guard !busy, !dirty, revision > 0 else { return }
        working = true; defer { working = false }
        (review, status) = await prepareTestFlight(account, app, session) { $0.testflightAction = "save-beta-review-details" }
    }
}
