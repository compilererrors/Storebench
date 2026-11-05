import StorebenchCore
import SwiftUI

/// App Privacy as App Store Connect has it: the Privacy Policy links, then an Apple ID sign-in, because the API key cannot answer
/// the data questions, the questions with Save and Publish, and the Tax Category with the same sign-in. Each command opens a review to approve first.
struct AppPrivacyView: View {
    let account: Account, app: Account.App, session: WorkspaceSession?
    var done: () -> Void = {}
    /// On App Store Connect's App Privacy page, what is still needed shows first.
    var checklist = false
    @Environment(LibraryModel.self) private var model
    @Environment(\.editorNavigation) private var navigation
    @State private var apple: AppleIDAccount?
    @State private var state: AppPrivacyState?
    @State private var answers = AppPrivacyAnswers(collects: false)
    @State private var latest: PublishReview?
    @State private var links: PrivacyPolicyLinks?
    @State private var linksStatus = ""
    @State private var reading = false
    @State private var problem = ""
    /// The Apple ID whose session Apple ended; the sign-in fields open with it.
    @State private var ended: String?
    /// What App Store Connect last showed for App Privacy and Tax Category, shown while signed out.
    @State private var checks: [SectionCheck.Area: SectionCheck] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if checklist {
                StorebenchChecklist(rows: [
                    .init(id: "policy", title: "Privacy Policy URL", done: links?.policyUrl.isEmpty == false),
                    .init(id: "privacy", title: "App Privacy answers", done: (state?.answers != nil) || checks[.privacy]?.answered == true),
                    .init(id: "tax", title: "Tax Category", done: checks[.tax]?.answered == true),
                ], guide: .release)
            }
            Card(title: "Privacy Policy", subtitle: "The links App Store Connect shows with App Privacy. They belong to the app information of the primary language and are sent with the app's text.",
                 actions: AnyView(StorebenchCommand(title: "Edit", running: "Opening…", busy: false, unavailable: navigation.navigate == nil ? "Open this app to edit its languages." : nil, primary: false) { navigation.open(.localizations, locale: links?.locale) })) {
                StorebenchMetricGrid(maximumColumns: 2, minimumWidth: 230) {
                    Fact(title: "Privacy Policy URL", value: links.map { $0.policyUrl.isEmpty ? "—" : $0.policyUrl } ?? "Unknown", compact: true)
                    Fact(title: "User Privacy Choices URL (Optional)", value: links.map { $0.choicesUrl.isEmpty ? "—" : $0.choicesUrl } ?? "Unknown", compact: true)
                }
                StorebenchTextSlot(text: linksStatus, height: 20, font: .sbCaption, color: StorebenchTheme.muted, live: true)
            }
            AppleIDSignInCard(account: account, session: session, apple: $apple, ended: ended, changed: { ended = nil; Task { await read() } })
            PricingReviewCard(title: "App Privacy", subtitle: "Answer the questions App Store Connect asks about the data this app collects. Save keeps the answers in App Store Connect; Publish also shows them on the App Store product page. Each opens a review to approve first.",
                              command: "Publish", account: account, app: app, session: session, blocked: blocked, request: { try request(publish: true) }, done: { Task { await read() }; done() },
                              secondary: ("Save", { try request(publish: false) })) {
                StorebenchMetricGrid(maximumColumns: 3, minimumWidth: 230) {
                    Fact(title: "Saved at Apple", value: state.map { $0.answers?.summary ?? "Not answered" } ?? Self.lastRead(checks[.privacy]?.summary, checks[.privacy]), compact: true)
                    Fact(title: "Product Page", value: state?.published.map { $0 ? "Published" : "Not published" } ?? Self.lastRead(checks[.privacy]?.detail, checks[.privacy]), compact: true)
                    Fact(title: "Latest Review", value: latest.map { "\($0.title) · \(ReviewPanel.stateLabel($0.state))\n" + LibraryOverview.timestamp($0.completedAt ?? $0.sentAt ?? $0.updatedAt) } ?? "None from Storebench yet",
                         compact: true, info: "The newest App Privacy review in Publishing history below, with its state and time.")
                }
                StorebenchTextSlot(text: reading ? "Reading App Privacy from App Store Connect…" : apple == nil ? "Sign in with an Apple ID above to read and answer App Privacy." : unsaved, height: 20, font: .sbCaption, color: StorebenchTheme.muted, live: true)
                if !problem.isEmpty { StorebenchAttention { Text(problem).fixedSize(horizontal: false, vertical: true) } }
                StorebenchChoicePicker("Do you or your third-party partners collect data from this app?", selection: $answers.collects,
                                       options: [(false, "No, we do not collect data from this app"), (true, "Yes, we collect data from this app")], style: .radio)
                if answers.collects {
                    Text("Select each type of data collected from this app, then answer its questions.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
                    ForEach(AppPrivacyAnswers.groups, id: \.0) { group in
                        StorebenchCardSection(title: group.0) {
                            ForEach(group.1, id: \.0) { code, label in dataType(code, label) }
                        }
                    }
                }
            }
            TaxCategoryView(account: account, app: app, session: session, apple: apple, saved: checks[.tax], done: done, ended: { signedOut() }).id("tax-category")
        }
        .task(id: account.id + "/" + app.id) {
            apple = try? await session?.appleIDAccount(accountId: account.id, writer: model.writer)
            async let policy: Void = readLinks()
            await read(); await policy
        }
    }

    /// A value App Store Connect showed at the last read, with its time, while it cannot be read now.
    static func lastRead(_ value: String?, _ check: SectionCheck?) -> String {
        guard let value, let check else { return "Unknown" }
        return "\(value)\nLast read \(LibraryOverview.timestamp(check.checkedAt))"
    }

    /// Apple ended the Apple ID session: the card asks to sign in again and the last values read stay shown.
    private func signedOut() {
        if let apple { ended = apple.appleId }
        apple = nil; state = nil; problem = ""
    }

    /// Whether the form differs from what App Store Connect has saved, so Save or Publish is still needed.
    private var unsaved: String {
        guard let state else { return "" }
        let chosen = answers.collects ? answers : AppPrivacyAnswers(collects: false)
        if state.answers != chosen { return "These answers are not saved in App Store Connect yet." }
        return state.published == true ? "" : "Saved in App Store Connect. Publish shows them on the product page."
    }

    private var blocked: String? {
        if apple == nil { return "Sign in with an Apple ID first. The API key cannot answer App Privacy." }
        if reading { return "Reading App Privacy from App Store Connect…" }
        if state == nil { return "App Privacy has not been read yet." }
        if answers.collects {
            if answers.items.isEmpty { return "Choose the data types the app collects." }
            if let item = answers.items.first(where: { $0.purposes.isEmpty }) { return "Choose how \(AppPrivacyAnswers.label(item.category)) is used." }
        }
        return nil
    }

    @ViewBuilder private func dataType(_ code: String, _ label: String) -> some View {
        let index = answers.items.firstIndex { $0.category == code }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                StorebenchCheckbox(label, isOn: Binding(get: { index != nil }, set: { on in
                    if on, index == nil { answers.items.append(.init(category: code)) } else if !on { answers.items.removeAll { $0.category == code } }
                }))
                Text(label).font(.sbCallout)
            }
            if let index {
                let name = label.lowercased()
                VStack(alignment: .leading, spacing: 12) {
                    Text("Indicate how \(name) collected from this app is being used by you or your third-party partners.").font(.sbCaption).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
                    StorebenchFlow(spacing: 12) {
                        ForEach(AppPrivacyAnswers.purposes, id: \.0) { purpose, title in
                            HStack(spacing: 4) {
                                StorebenchCheckbox(title, isOn: Binding(get: { answers.items[index].purposes.contains(purpose) }, set: { on in
                                    answers.items[index].purposes.removeAll { $0 == purpose }; if on { answers.items[index].purposes.append(purpose) }
                                }))
                                Text(title).font(.sbCallout)
                            }
                        }
                    }
                    StorebenchChoicePicker("Is the \(name) collected from this app linked to the user's identity?", selection: $answers.items[index].linked,
                                           options: [(true, "Yes, \(name) collected from this app is linked to the user's identity"), (false, "No, \(name) collected from this app is not linked to the user's identity")], style: .radio)
                    StorebenchChoicePicker("Do you or your third-party partners use \(name) for tracking purposes?", selection: $answers.items[index].tracking,
                                           options: [(true, "Yes, we use \(name) for tracking purposes"), (false, "No, we do not use \(name) for tracking purposes")], style: .radio)
                }.padding(.leading, 36)
            }
        }
    }

    private func request(publish: Bool) throws -> PublishRequest {
        var value = PublishRequest(accountId: account.id, appId: app.id, scope: .appPrivacy)
        value.appPrivacy = answers.collects ? answers : AppPrivacyAnswers(collects: false)
        if publish { value.appPrivacyPublish = true }
        return value
    }

    private func readLinks() async {
        guard let session else { return }
        do { links = try await session.privacyPolicyLinks(account: account, appId: app.id); linksStatus = links == nil ? "App Store Connect has no app information for this app yet." : "" }
        catch is CancellationError {}
        catch { linksStatus = "The Privacy Policy links could not be read from App Store Connect." }
    }

    private func read() async {
        latest = (try? await session?.publishHistory(accountId: account.id, appId: app.id))?.first { $0.request.scope == .appPrivacy }
        guard let session else { state = nil; return }
        checks = (try? await session.sectionChecks(accountId: account.id, appId: app.id)) ?? checks
        guard apple != nil else { state = nil; return }
        reading = true; defer { reading = false }
        do {
            let value = try await session.appPrivacyState(account: account, appId: app.id)
            state = value; problem = ""
            if let current = value.answers { answers = current }
        } catch AppleIDFailure.expired { signedOut() }
        catch let failure as AppleIDFailure { problem = failure.message }
        catch let failure as PublishFailure { problem = failure.message }
        catch { problem = "App Privacy could not be read from App Store Connect. Try again, or sign in again." }
        checks = (try? await session.sectionChecks(accountId: account.id, appId: app.id)) ?? checks
    }
}

/// Where the Apple ID session and a saved password are kept: the Mac Keychain, or the password-protected storage chosen instead of it.
struct AppleIDStorageText: Equatable {
    let passwordFile: Bool
    var place: String { passwordFile ? "Storebench's password-protected storage" : "your Mac Keychain" }
    var subtitle: String { "App Privacy and Tax Category can only be answered with an Apple ID of the app's Account Holder or an Admin. Storebench keeps the signed-in session in \(place), and the password only when you choose Save Password." }
    func passwordHint(saving: Bool) -> String { saving ? "Kept only in \(place) for the next sign-in." : "Used to sign in; not stored." }
    var saveHelp: String { "Keeps this Apple ID and password in \(place) for the next sign-in. Apple still asks for the verification code when it needs one." }
    var signedIn: String { "Signed in. The session is kept in \(place)." }
    var passwordNotRemoved: String { "The saved password could not be removed from \(place). Try again." }
    var sessionNotRemoved: String { "The Apple ID session could not be removed from \(place). Try again." }
}

/// Apple ID sign-in in Storebench's own fields: Apple ID and password, then the two-factor code. The session is kept in the chosen credential
/// storage, and the password only when Save Password is on. An ended session opens the fields again with its Apple ID.
struct AppleIDSignInCard: View {
    let account: Account, session: WorkspaceSession?
    @Binding var apple: AppleIDAccount?
    /// The Apple ID of a session Apple ended; nil while signed in or never signed in.
    var ended: String? = nil
    var changed: () -> Void = {}
    @Environment(LibraryModel.self) private var model
    @State private var appleId = ""
    @State private var password = ""
    @State private var savePassword = false
    @State private var code = ""
    @State private var phone = 0
    @State private var challenge: AppleIDPendingSignIn?
    @State private var working = ""
    @State private var problem = ""
    @State private var status = ""
    private var storage: AppleIDStorageText { AppleIDStorageText(passwordFile: model.writer.usesPasswordFile) }

    var body: some View {
        Card(title: "Apple ID", subtitle: storage.subtitle,
             actions: AnyView(StorebenchCommand(title: "Sign Out", running: "Signing Out…", busy: working == "sign-out", unavailable: apple == nil && challenge == nil ? "Not signed in." : nil, primary: false) { signOut() })) {
            StorebenchMetricGrid(maximumColumns: 2, minimumWidth: 230) {
                Fact(title: "Signed in as", value: apple?.appleId ?? ended.map { "Signed out · \($0)" } ?? "Not signed in", compact: true)
                Fact(title: "Teams", value: apple.map { $0.teams.joined(separator: ", ") } ?? "—", compact: true)
            }
            StorebenchCardSection(title: "1. Apple ID and Password") {
                StorebenchMetricGrid(maximumColumns: 2, minimumWidth: 230) {
                    StorebenchTextField("Apple ID", text: $appleId, hint: "The email address of your Apple Account.", contentType: .username).disabled(apple != nil || challenge != nil)
                    StorebenchSecureField("Password", text: $password, hint: storage.passwordHint(saving: savePassword), contentType: .password).disabled(apple != nil || challenge != nil)
                }
                HStack(spacing: 8) {
                    StorebenchCheckbox("Save Password", isOn: $savePassword)
                    Text("Save Password").font(.sbCallout)
                }.help(storage.saveHelp)
                StorebenchActionGroup {
                    StorebenchCommand(title: "Sign In", running: "Signing In…", busy: working == "sign-in", unavailable: apple != nil ? "Already signed in. Sign out to use another Apple ID." : challenge != nil ? "Enter the verification code in step 2." : appleId.isEmpty || password.isEmpty ? "Enter the Apple ID and password." : session == nil ? "Connect the workspace first." : nil) { Task { await start() } }
                }
            }
            StorebenchCardSection(title: "2. Verification Code", description: "After Sign In, Apple asks on your Mac, iPhone or iPad whether to allow the sign-in. Choose Allow, then enter the code it shows. To get the code by text message instead, choose the phone number and Text Me a Code.") {
                StorebenchMetricGrid(maximumColumns: 2, minimumWidth: 230) {
                    StorebenchTextField("Verification Code", text: $code, hint: challenge.map { "The \($0.codeLength)-digit code \(phone == 0 ? "shown on your device" : "texted to your phone")." } ?? "Available after Sign In.", contentType: .oneTimeCode).disabled(challenge == nil)
                    StorebenchPicker("Get the Code By", selection: $phone, hint: challenge == nil ? "Available after Sign In." : "Apple's own trusted devices, or a text message.") {
                        SelectionOption("Sign-in request on a trusted device", value: 0)
                        selectionOptions(challenge?.phones ?? []) { SelectionOption("Text message to \($0.number)", value: $0.id) }
                    }.disabled(challenge == nil)
                }
                StorebenchActionGroup {
                    StorebenchCommand(title: "Verify", running: "Verifying…", busy: working == "verify", unavailable: challenge == nil ? "Sign in first; Apple then sends a code." : code.count < (challenge?.codeLength ?? 6) ? "Enter the verification code." : nil) { Task { await verify() } }
                    StorebenchCommand(title: "Text Me a Code", running: "Sending…", busy: working == "text", unavailable: challenge == nil ? "Sign in first." : phone == 0 ? "Choose a phone number under Get the Code By." : nil, primary: false) { Task { await text() } }
                }
            }
            StorebenchTextSlot(text: status.isEmpty && apple == nil && ended != nil ? "Signed out · sign in to check or change App Privacy and Tax Category." : status, height: 20, font: .sbCaption, color: StorebenchTheme.muted, live: true)
            if !problem.isEmpty { StorebenchAttention { Text(problem).fixedSize(horizontal: false, vertical: true) } }
        }
        .task(id: account.id) { await loadSaved() }
        .onChange(of: ended) { _, value in if let value, appleId.isEmpty { appleId = value } }
        .onChange(of: savePassword) { _, on in if !on { forgetPassword() } }
    }

    /// Fills the fields from the saved password, or with the Apple ID of an ended session.
    private func loadSaved() async {
        if let saved = try? await session?.savedAppleIDPassword(accountId: account.id, writer: model.writer) {
            appleId = saved.appleId; password = saved.password; savePassword = true
        } else if appleId.isEmpty, let value = ended ?? apple?.appleId { appleId = value }
    }

    private func forgetPassword() {
        Task {
            do { try await session?.saveAppleIDPassword(nil, appleId: appleId, accountId: account.id, writer: model.writer) }
            catch { problem = storage.passwordNotRemoved }
        }
    }

    private func start() async {
        guard working.isEmpty else { return }
        working = "sign-in"; defer { working = "" }
        guard let session else { return }
        do {
            let step = try await session.signInAppleID(appleId, password: password, savePassword: savePassword, accountId: account.id, writer: model.writer)
            if !savePassword { password = "" }
            switch step {
            case .verify(let next): challenge = next; phone = 0; status = next.deviceCode ? "Apple sent a sign-in request to your trusted devices. Choose Allow there, then enter the code." : "Choose a phone number under Get the Code By, then Text Me a Code."; problem = ""
            case .signedIn(let value): signedIn(value)
            }
        } catch let failure as AppleIDFailure { problem = failure.message; if !savePassword || failure == .rejected { password = "" } }
        catch { problem = "Signing in did not finish. Try again."; if !savePassword { password = "" } }
    }

    private func verify() async {
        guard working.isEmpty, let challenge, let session else { return }
        working = "verify"; defer { working = "" }
        do { signedIn(try await session.verifyAppleID(challenge, code: code, phone: phone == 0 ? nil : phone, writer: model.writer)) }
        catch let failure as AppleIDFailure { problem = failure.message; if case .verificationEnded = failure { restart() } }
        catch { problem = "The code could not be verified. Try again." }
    }

    private func text() async {
        guard working.isEmpty, let challenge, let session, phone != 0 else { return }
        working = "text"; defer { working = "" }
        do { try await session.textAppleIDCode(challenge, phone: phone); status = "Apple is texting a code to the chosen phone number."; problem = "" }
        catch let failure as AppleIDFailure { problem = failure.message; if case .verificationEnded = failure { restart() } } catch { problem = "The text could not be sent. Try again." }
    }

    /// Apple ended the verification: the fields open for a new sign-in, keeping the Apple ID.
    private func restart() { challenge = nil; code = ""; phone = 0; status = "" }

    private func signedIn(_ value: AppleIDAccount) {
        apple = value; challenge = nil; code = ""; problem = ""; status = storage.signedIn; changed()
    }

    private func signOut() {
        guard working.isEmpty else { return }
        working = "sign-out"
        Task {
            defer { working = "" }
            do { try await session?.signOutAppleID(accountId: account.id, writer: model.writer); apple = nil; challenge = nil; code = ""; status = "Signed out."; problem = ""; changed() }
            catch { problem = storage.sessionNotRemoved }
        }
    }
}
