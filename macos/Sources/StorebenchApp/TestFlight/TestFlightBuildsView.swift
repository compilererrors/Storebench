import AppKit
import StorebenchCore
import SwiftUI

struct TestFlightBuildsView: View {
    let account: Account, app: Account.App, session: WorkspaceSession?
    var initialBuildId: String? = nil
    var initialAction: String? = nil
    var didSelectInitial: () -> Void = {}
    @Environment(\.editorProtection) private var protection
    @Environment(\.pageScroll) private var pageScroll
    @State private var loading = false
    @State private var selecting = false
    @State private var preparing = false
    @State private var publishing = false
    @State private var builds: [TestFlightBuild] = []
    @State private var confirmed = false
    @State private var readProblem = ""
    @State private var state = "loading"
    @State private var review: PublishReview?
    @State private var accessBusy = false
    @State private var encryptionBusy = false
    @State private var answering: TestFlightBuild?
    @State private var selected: TestFlightBuild?
    @State private var draft: LocalEditorDraftEditor?
    @State private var draftNotes: [String: String] = [:]
    @State private var notes: [String: String] = [:]
    @State private var locale = "en-US"
    @State private var whatToTest = ""
    @State private var status = ""
    @State private var readAt: Date?
    @State private var restoring: Choices?
    @Environment(\.navigationPresentation) private var history
    private struct Choices: Equatable { var selectedId, answeringId: String?; var locale: String }
    private var readKey: String { "testflight-builds/\(account.id)/\(app.id)" }
    /// Back reopens the build or compliance answer that was open; it is applied once the build list is read.
    private var choiceValue: Binding<Choices> {
        Binding(get: { restoring ?? Choices(selectedId: selected?.id, answeringId: answering?.id, locale: locale) }, set: { value in locale = value.locale; restoring = value })
    }
    private var busy: Bool { loading || selecting || preparing || publishing }
    private var notesChanged: Bool { !whatToTest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && whatToTest != notes[locale] }

    private var draftValue: JSONText {
        var values = notes.merging(draftNotes) { _, changed in changed }; values[locale] = whatToTest
        return .object([("locale", .string(locale)), ("notes", .object(values.sorted { $0.key < $1.key }.map { ($0.key, .string($0.value)) }))])
    }
    private func restoreDraft(_ value: JSONText) {
        if case .object(let values)? = value["notes"] { draftNotes = Dictionary(uniqueKeysWithValues: values.compactMap { key, value in value.text.map { (key, $0) } }) }
        locale = value["locale"]?.text ?? locale; whatToTest = draftNotes[locale] ?? notes[locale] ?? ""; review = nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            StorebenchMetricGrid(maximumColumns: 3) {
                    Fact(title: "Builds", value: state == "ready" ? "\(builds.count)" : "—")
                    Fact(title: "Missing Compliance", value: state == "ready" ? "\(builds.filter(\.missingCompliance).count)" : "—", info: "Builds that need an answer about encryption before testers can install them.")
                    Fact(title: "Expired", value: state == "ready" ? "\(builds.filter { $0.expired == true }.count)" : "—")
            }
            if let build = answering, state != "failed" {
                BuildEncryptionAnswerCard(account: account, app: app, session: session, build: build, shared: .init(review: $review, status: $status), blocked: !confirmed || busy || accessBusy || encryptionBusy,
                                          busyChanged: { preparing = $0 }, answered: { answering = nil }, cancel: { answering = nil })
                    .id("selected-build").storebenchWorking(!confirmed || busy || accessBusy || encryptionBusy)
            }
            if let selected, state != "failed" {
                buildCard(selected).id("selected-build").storebenchWorking(!confirmed || accessBusy || encryptionBusy || busy)
                TestFlightBuildAccessView(account: account, app: app, build: selected, session: session, busyChanged: { accessBusy = $0 }, didPublish: { Task { await load() } }).id(selected.id).storebenchWorking(!confirmed || loading)
                TestFlightEncryptionView(account: account, app: app, build: selected, session: session, busyChanged: { encryptionBusy = $0 }, didPublish: { Task { await load() } }).id(selected.id).storebenchWorking(!confirmed || loading)
                TestFlightMetricsView(account: account, app: app, build: selected, session: session).id(selected.id)
            }
            ReviewPanel(account: account, app: app, session: session, review: $review, done: { Task { await load() } }, busyChanged: { publishing = $0 }, syncConfirmation: true, localDraft: review?.request.testflightAction == "save-build-notes" ? draft : nil, draftPaths: [["notes", review?.request.locale ?? locale]]).storebenchWorking(!confirmed || loading)
            // The builds you test come first; uploading a new package and Apple's delivery records follow.
            Card(title: "Uploaded builds", subtitle: "Processed builds delivered through Storebench, Xcode or Transporter. Apple controls beta review and approval.", help: "testflight", actions: AnyView(
                Button(loading ? "Reading Builds…" : "Refresh Builds") { if !busy, !accessBusy, !encryptionBusy { Task { await load(fresh: true) } } }.storebenchWorking(busy || accessBusy || encryptionBusy)
            )) {
                StorebenchReadAge(readAt: state == "ready" ? readAt : nil, reading: loading)
                StorebenchFeedback(text: readProblem, height: 40)
                switch state {
                case "failed": EmptyView()
                case "ready" where builds.isEmpty: Text("No builds yet. Upload a build to App Store Connect to make it available for TestFlight groups.").foregroundStyle(StorebenchTheme.muted)
                case "ready":
                    StorebenchCollection(items: builds, title: { $0.title }, subtitle: description, empty: "No builds yet.") { build in
                        StorebenchFormFooter {
                            if build.missingCompliance && build.canManage { Button("Manage Compliance") { if confirmed, !accessBusy, !encryptionBusy, !busy, protection?.allowLeaving() != false { answering = build; selected = nil; review = nil; reveal("selected-build") } }.help("Manage Missing Compliance").accessibilityLabel("Manage Missing Compliance").buttonStyle(StorebenchButtonStyle(.primary)).storebenchWorking(!confirmed || accessBusy || encryptionBusy || busy).fixedSize() }
                            else if build.processed && build.canManage { Button("Export Compliance") { if confirmed, !accessBusy, !encryptionBusy, !busy, protection?.allowLeaving() != false { answering = build; selected = nil; review = nil; reveal("selected-build") } }.help("Export Compliance Information").accessibilityLabel("Export Compliance Information").storebenchWorking(!confirmed || accessBusy || encryptionBusy || busy).fixedSize() }
                            if selected?.id != build.id { Button("View Build") { Task { await select(build) } }.storebenchWorking(accessBusy || encryptionBusy || busy).fixedSize() }
                        }
                    }
                default: StorebenchCollectionPlaceholder()
                }
            }
            BuildDeliveryView(account: account, app: app, session: session)
        }
        .task {
            await showRemembered()
            guard !Task.isCancelled else { return }
            await load(); guard !Task.isCancelled, state == "ready" else { return }
            if restoring != nil { await applyRestoring(); return }
            guard let id = initialBuildId, let build = builds.first(where: { $0.id == id }) else { return }
            if initialAction == "set-encryption-use" { answering = build; selected = nil }
            else { await select(build) }
            guard !Task.isCancelled else { return }; didSelectInitial()
        }
        .historyValue("testflight-builds", choiceValue)
        .trackUnsavedChanges(draft?.dirty(draftValue) == true, busy: busy || draft?.busy == true, onSave: { await draft?.saveCurrent(value: { draftValue }) == true })
        .onChange(of: Data(whatToTest.utf8)) { if !busy, review?.state == "prepared" { review = nil } }
    }

    /// A card opened from the list appears above it, so the page moves to it instead of leaving the click without a visible result.
    private func reveal(_ id: String) {
        Task { @MainActor in try? await Task.sleep(for: .milliseconds(150)); pageScroll?(id, .top) }
    }

    private func description(_ build: TestFlightBuild) -> String {
        let processing = AppStoreNames.state(build.processingState)
        var parts = [processing, "Uploaded " + (AppStoreNames.date(build.uploadedDate) ?? String(build.uploadedDate.prefix(10)))]
        if !build.expirationDate.isEmpty { parts.append(build.expired == true ? "Expired" : "Expires " + (AppStoreNames.date(build.expirationDate) ?? String(build.expirationDate.prefix(10)))) }
        if build.expired == nil { parts.append("Expiry status unavailable at Apple") }
        if build.audience == "INTERNAL_ONLY" { parts.append("Internal only") }
        else if build.audience != "APP_STORE_ELIGIBLE" { parts.append("Build audience unavailable at Apple") }
        parts.append(build.exportState.description)
        parts.append(build.betaReviewDescription)
        if let state = build.externalState { parts.append("External testing: " + AppStoreNames.state(state)) }
        if let flag = build.autoNotifyEnabled { parts.append("Automatic notice: " + (flag ? "on" : "off")) }
        return parts.joined(separator: " · ")
    }

    private func buildCard(_ build: TestFlightBuild) -> some View {
        Card(title: build.title, subtitle: description(build)) {
            Text("What to Test").font(.sbHeadline)
            StorebenchPicker("Language", selection: Binding(get: { locale }, set: { next in
                guard !busy, next != locale, protection?.allowLeaving() != false else { return }
                draftNotes[locale] = whatToTest; locale = next; whatToTest = draftNotes[locale] ?? notes[locale] ?? ""; review = nil
            })) { selectionOptions(TestFlightActions.buildLocales) { SelectionOption(StoreLocales.name($0), value: $0) } }.storebenchFormColumn()
            if build.canManage {
                StorebenchTextArea(text: $whatToTest, height: StorebenchTheme.textarea(rows: 2)).accessibilityLabel("What to Test")
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(whatToTest.utf16.count) of 4,000 characters").font(.sbCaption).foregroundStyle(whatToTest.utf16.count > 4000 ? StorebenchTheme.color("color-danger") : StorebenchTheme.muted)
                    if let draft {
                        LocalDraftActions(editor: draft, value: draftValue, restore: restoreDraft, blocked: busy || accessBusy || encryptionBusy, sync: {
                            await prepare(build) { $0.testflightAction = "save-build-notes"; $0.locale = locale; $0.whatsNew = whatToTest }
                        }, syncBlocked: !notesChanged)
                    }
                }
            } else {
                Text(whatToTest.isEmpty ? "No What to Test text for this language." : whatToTest).font(.sbCallout).fixedSize(horizontal: false, vertical: true)
                Text("Apple does not allow changes to this build's What to Test text.").font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
            }
            StorebenchDivider()
            Text("Testing").font(.sbHeadline)
            Text("Beta review checks fresh Apple prerequisites before preparing a Publish review. Expiring a build cannot be undone.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
            Text("Manual notification requires a build ready for external testing with automatic notification off. Publish reviews show the affected testing groups and direct assignments.").font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
            StorebenchFeedback(text: status, height: 34)
            if build.canManage || build.canNotifyTesters || build.canCheckBetaReview { StorebenchFormFooter { buildActions(build) } }
            else { Text("Apple offers no testing actions for this build right now.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted) }
        }
    }

    @ViewBuilder private func buildActions(_ build: TestFlightBuild) -> some View {
        if build.canManage { Button("Expire Build", role: .destructive) { Task { await prepare(build) { $0.testflightAction = "expire-build" } } }.fixedSize() }
        if build.canNotifyTesters { Button("Notify Testers") { Task { await prepare(build) { $0.testflightAction = "notify-build-testers" } } }.fixedSize() }
        if build.canCheckBetaReview { Button(build.canSubmitForBetaReview ? "Review Beta Build" : "Check Beta Review") { Task { await prepare(build) { $0.testflightAction = "submit-beta-review" } } }.buttonStyle(StorebenchButtonStyle(.primary)).fixedSize() }
    }

    private func prepare(_ build: TestFlightBuild, _ configure: (inout PublishRequest) -> Void) async {
        guard confirmed, !busy, !accessBusy, !encryptionBusy else { return }
        preparing = true; defer { preparing = false }
        if let draft { guard await draft.save(draftValue), !draft.dirty(draftValue) else { return } }
        (review, status) = await prepareTestFlight(account, app, session, buildId: build.id, configure)
    }

    private func select(_ build: TestFlightBuild) async {
        guard !accessBusy, !encryptionBusy, !busy, let session, protection?.allowLeaving() != false else { return }
        selecting = true; defer { selecting = false }
        selected = build; answering = nil; review = nil; status = ""; notes = [:]; whatToTest = ""; draftNotes = [:]; draft = nil
        do { notes = try await session.whatToTest(appId: app.id, buildId: build.id, client: try await session.readClient(for: account)); whatToTest = notes[locale] ?? "" }
        catch { status = "What to Test could not be loaded for this build." }
        let owner = LocalEditorDraftEditor(scope: .init(accountId: account.id, appId: app.id, editor: "testflight-build-notes", resource: build.id), session: session)
        draft = owner
        if let saved = await owner.load(initial: draftValue) { restoreDraft(saved) }
    }

    private func showRemembered() async {
        guard builds.isEmpty, let remembered = await history?.rememberedDecodedRead(readKey, as: [TestFlightBuild].self), !Task.isCancelled, builds.isEmpty else { return }
        builds = remembered; state = "ready"; readAt = history?.rememberedReadAt(readKey)
    }
    private func applyRestoring() async {
        guard let choice = restoring else { return }
        restoring = nil
        if let id = choice.answeringId, let build = builds.first(where: { $0.id == id }) { answering = build; selected = nil }
        else if let id = choice.selectedId, let build = builds.first(where: { $0.id == id }), selected?.id != id { await select(build) }
    }

    private func load(fresh: Bool = false) async {
        await ScreenReads.reading(fresh: fresh) {
            guard !loading, let session else { return }
            // A list already shown stays visible while it is read again; actions wait for the read.
            loading = true; confirmed = false; readProblem = ""; if readAt == nil { state = "loading" }; if review?.state == "prepared" { review = nil }
            defer { loading = false }
            do {
                let latest = try await session.testFlightBuilds(appId: app.id, client: try await session.readClient(for: account))
                try Task.checkCancellation()
                builds = latest; status = ""; state = "ready"; confirmed = true; readAt = Date()
                if let current = selected { selected = builds.first { $0.id == current.id } }
                history?.rememberRead(latest, readKey)
            }
            catch is CancellationError { }
            catch {
                guard !Task.isCancelled else { return }
                if let failure = error as? AppStoreConnectClient.Failure, case .status(let code) = failure, code == 401 || code == 403 { readProblem = "Apple did not allow this API key to read TestFlight builds." }
                else { readProblem = "TestFlight builds could not be loaded from App Store Connect." }
                state = readAt == nil ? "failed" : "ready"
                if readAt != nil { readProblem += " The last builds read are shown. Refresh Builds before changing testing access." }
            }
        }
    }
}
