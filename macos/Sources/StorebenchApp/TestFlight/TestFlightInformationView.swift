import AppKit
import StorebenchCore
import SwiftUI

struct TestFlightInformationView: View {
    let account: Account, app: Account.App, session: WorkspaceSession?
    @Environment(\.editorProtection) private var protection
    @State private var draft: LocalEditorDraftEditor?
    @State private var localizations: [TestFlightLocalization] = []
    @State private var license: String?
    @State private var agreement = ""
    @State private var licenseReview: PublishReview?
    @State private var status = ""
    @State private var licenseStatus = ""
    @State private var informationReady = false
    @State private var licenseReady = false
    @State private var working = false
    @State private var publishingLicense = false
    @State private var newLocale = "en-US"
    @State private var addedLocales: Set<String> = []
    @State private var busyLocales: Set<String> = []
    @State private var summaries: [String: String] = [:]
    @Environment(\.navigationPresentation) private var history
    private struct Read: Codable, Sendable { var localizations: [TestFlightLocalization]?, license: String?? }
    private var readKey: String { "testflight-information/\(account.id)/\(app.id)" }
    private var codes: [String] { Array(Set(localizations.map(\.locale)).union(addedLocales)).sorted() }
    private var available: [String] { StoreLocales.codes.filter { !codes.contains($0) } }
    private var busy: Bool { working || !busyLocales.isEmpty || publishingLicense }
    private var dirty: Bool { !agreement.utf8.elementsEqual((license ?? "").utf8) }
    private var draftValue: JSONText { .object([("license", .string(agreement)), ("languages", .array(addedLocales.sorted().map(JSONText.string)))]) }
    private func restoreDraft(_ value: JSONText) {
        agreement = value["license"]?.text ?? ""
        if case .array(let languages)? = value["languages"] { addedLocales = Set(languages.compactMap(\.text)) }
        licenseReview = nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            TestFlightReviewInformationView(account: account, app: app, session: session)
            Card(title: "Beta App Information", subtitle: "Each TestFlight language has its own card. Changes are reviewed separately before sending them to Apple.") {
                if informationReady && !available.isEmpty {
                    StorebenchFormGrid {
                        StorebenchPicker("Add a language card", selection: $newLocale) { selectionOptions(available) { SelectionOption(StoreLocales.name($0), value: $0) } }
                        if available.contains(newLocale) {
                            Button("Add Language Card") { guard !busy, available.contains(newLocale) else { return }; addedLocales.insert(newLocale); newLocale = available.first ?? "" }.padding(.top, StorebenchTheme.measure("fieldLabel") + StorebenchTheme.measure("fieldGap"))
                        }
                    }.environment(\.fieldHintHeight, 0).storebenchWorking(busy || draft?.loaded != true)
                }
                StorebenchActionGroup {
                    StorebenchReadButton(informationReady ? "Reload Languages" : "Read Languages") { if !busy, protection?.allowLeaving() != false { await loadInformation() } }.help(informationReady ? "Reload languages from Apple" : "Read Languages from Apple").accessibilityLabel(informationReady ? "Reload languages from Apple" : "Read Languages from Apple").storebenchWorking(busy)
                }
                StorebenchFeedback(text: status, height: 40)
                if let draft { LocalDraftActions(editor: draft, value: draftValue, restore: restoreDraft, blocked: busy) }
                StorebenchCollection(items: codes.map { StorebenchCollectionEntry(id: $0, value: $0) }, title: { StoreLocales.name($0.value) }, subtitle: { $0.value + " · " + (summaries[$0.value] ?? "Open to edit TestFlight information") },
                                     empty: informationReady ? "No TestFlight languages yet. Choose a language above, then Add Language Card." : "TestFlight languages have not been read. Choose Read Languages.") { entry in
                    TestFlightLanguageInformationEditor(account: account, app: app, session: session,
                        source: localizations.first { $0.locale == entry.value } ?? TestFlightLocalization(locale: entry.value, description: "", feedbackEmail: ""),
                        available: informationReady, parentBusy: busy, summaryChanged: { summaries[entry.value] = $0 }, busyChanged: { value in
                            if value { busyLocales.insert(entry.value) } else { busyLocales.remove(entry.value) }
                        })
                }
            }
            Card(title: "License Agreement", subtitle: "The beta license agreement testers accept for this app.") {
                if licenseReady { StorebenchTextArea(text: $agreement, height: 160).accessibilityLabel("Beta license agreement").storebenchWorking(busy || draft?.loaded != true) }
                StorebenchTextSlot(text: licenseReady && dirty ? (agreement.isEmpty ? "Enter the license agreement text, then choose Prepare Review." : "Not sent yet. Save Draft keeps this change on this Mac. Sync to Apple prepares it for your approval.") : "",
                                   height: 34, font: .sbCaption, color: agreement.isEmpty ? StorebenchTheme.color("color-danger") : StorebenchTheme.muted, live: true)
                StorebenchFeedback(text: licenseStatus, height: 40)
                StorebenchFormFooter {
                    Button("Read from Apple") { if !busy, protection?.allowLeaving() != false { Task { await loadLicense(fresh: true) } } }

                }.storebenchWorking(busy)
                if let draft { LocalDraftActions(editor: draft, value: draftValue, restore: restoreDraft, blocked: busy, sync: { await prepareLicense() }, syncBlocked: !licenseReady || agreement.isEmpty || !dirty) }
            }
            ReviewPanel(account: account, app: app, session: session, review: $licenseReview, done: { if licenseReview?.state == "complete" { Task { await loadLicense() } } }, busyChanged: { publishingLicense = $0 }, syncConfirmation: true, localDraft: draft, draftPaths: [["license"]])
        }
        .task(id: "\(account.id):\(app.id)") { await showRemembered(); guard !Task.isCancelled else { return }; await loadInformation(); await loadLicense()
            if let session {
                let owner = LocalEditorDraftEditor(scope: .init(accountId: account.id, appId: app.id, editor: "testflight-information", resource: "license-and-languages"), session: session)
                draft = owner
                if let saved = await owner.load(initial: draftValue) { restoreDraft(saved) }
            }
        }
        .onChange(of: Data(agreement.utf8)) { if !busy, licenseReview?.state == "prepared" { licenseReview = nil } }
        .trackUnsavedChanges(draft?.dirty(draftValue) == true, busy: busy || draft?.busy == true, onSave: { await draft?.saveCurrent(value: { draftValue }) == true })
    }
    private func loadInformation() async {
        guard !working, let session else { return }
        working = true; defer { working = false }
        do {
            localizations = try await session.testFlightAppInformation(account: account, appId: app.id)
            informationReady = true; status = ""; newLocale = available.first ?? ""
            remember { $0.localizations = localizations }
        } catch { status = "Test information could not be read. Your inputs are kept." }
    }
    private func loadLicense(fresh: Bool = false) async {
        await ScreenReads.reading(fresh: fresh) {
            guard !working, let session else { return }
            working = true; defer { working = false }
            do {
                license = try await session.testFlightBetaLicense(account: account, appId: app.id)
                if draft?.dirty(draftValue) != true { agreement = license ?? "" }; licenseReady = license != nil
                licenseStatus = license == nil ? "Apple has not provided a beta license agreement for this app." : ""
                remember { $0.license = .some(license) }
            } catch { licenseStatus = "The license could not be read. Your inputs are kept." }
        }
    }
    private func remember(_ change: (inout Read) -> Void) {
        var read = history?.rememberedRead(readKey, as: Read.self) ?? Read(); change(&read); history?.rememberRead(read, readKey)
    }
    /// The languages and license last read show at once. Languages stay read-only until Apple's current answer arrives.
    private func showRemembered() async {
        guard !informationReady, !licenseReady, let read = await history?.rememberedDecodedRead(readKey, as: Read.self), !Task.isCancelled, !informationReady, !licenseReady else { return }
        if let saved = read.localizations, localizations.isEmpty { localizations = saved }
        if case .some(.some(let text)) = read.license { license = text; agreement = text; licenseReady = true }
    }
    private func prepareLicense() async {
        guard !busy, licenseReady else { return }
        working = true; defer { working = false }
        guard await draft?.save(draftValue) == true, draft?.dirty(draftValue) == false else { return }
        (licenseReview, licenseStatus) = await prepareTestFlight(account, app, session) { $0.testflightAction = "save-beta-license"; $0.agreementText = agreement }
    }
}
