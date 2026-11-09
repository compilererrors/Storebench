import StorebenchCore
import SwiftUI

@MainActor struct ReviewThemesCard: View {
    let account: Account, app: Account.App, session: WorkspaceSession?, reviews: [CustomerReview]
    @Binding var evidence: Set<String>
    @State private var expanded = false
    @State private var latestReading = false
    @State private var state: ReviewThemeState?
    @State private var latest: ReviewThemeState?
    @State private var review: ReviewThemePreparation?
    @State private var reviewedInput: ReviewThemeInput?
    @State private var editing: String?
    @State private var version = ""
    @State private var theme = ""
    @State private var action = ""
    @State private var decision = ""
    @State private var followUp = ""
    @State private var status = ""
    @State private var original: ReviewThemeInput?
    @State private var evidencePage = 1
    @State private var evidenceQuery = ""
    @State private var working = false
    @State private var operation: Task<Void, Never>?
    @State private var operationId: UUID?
    private var unavailable: Bool { working || session == nil }
    private var input: ReviewThemeInput {
        let parts = version.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        return ReviewThemeInput(id: editing, reviewIds: evidence.sorted(), revisionId: parts.first ?? "", versionId: parts.count == 2 ? parts[1] : "", theme: theme, action: action, decision: decision, followUp: followUp)
    }
    private var dirty: Bool { review != nil || original.map { $0 != input } ?? !evidence.isEmpty }

    var body: some View {
        Card(title: "Feedback follow-up", subtitle: "Optional local notes that group saved reviews with an intended action and a release. These notes do not affect ratings or reports.") {
            StorebenchDisclosureButton(isExpanded: $expanded) { Text(expanded ? "Hide feedback planning" : "Open feedback planning") }
            VStack(alignment: .leading, spacing: StorebenchTheme.gap) {
            savedThemes
            Text(editing == nil ? "New theme" : "Edit theme").font(.sbHeadline)
            StorebenchPicker("Release", selection: $version) {
                SelectionOption("Choose a version", value: "")
                selectionOptions(state?.versions ?? []) { item in SelectionOption(item.label, value: item.id) }
            }.storebenchFormColumn().storebenchWorking(unavailable)
            fields
            evidencePicker
            if state != nil && (evidence.isEmpty || version.isEmpty) { Text("Choose a release and at least one review as evidence to prepare a theme review.").font(.sbCaption).foregroundStyle(StorebenchTheme.muted) }
            StorebenchActionGroup { editorActions }
            StorebenchTextSlot(text: status, height: 64, font: .sbCallout, color: StorebenchTheme.muted, live: true).accessibilityLabel("Theme operation status")
            LatestSaveReview(busy: unavailable, reading: latestReading, hasEdits: dirty, available: original != nil, changes: latest.map(changes), note: latest == nil ? nil : "Choose the new baseline explicitly; this comparison saves nothing.",
                             onRead: { run { id in await readLatest(id) } }, onKeep: latest == nil ? nil : { acceptLatest(useSaved: false) }, onUse: latest == nil ? nil : { acceptLatest(useSaved: true) })
            if let review {
                StorebenchDivider()
                Text("Review before saving locally").font(.sbHeadline)
                themeDetails(review.theme)
                Text("Expires at \(review.expiresAt). Changed feedback, releases or saved themes require a new review.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
                Button("Save Theme") { run { id in await save(review, id) } }.help("Save Reviewed Theme Locally").accessibilityLabel("Save Reviewed Theme Locally").buttonStyle(StorebenchButtonStyle(.primary)).storebenchWorking(unavailable)
            }
            }.collectionVisibility(expanded)
        }
        .historyDisclosure("feedback-follow-up", isExpanded: $expanded)
        .trackUnsavedChanges(dirty, busy: working)
        .task(id: "\(account.id):\(app.id)") {
            operationId = nil; operation?.cancel(); operation = nil; working = true; state = nil; latest = nil; review = nil
            editing = nil; version = ""; theme = ""; action = ""; decision = ""; followUp = ""; status = ""; original = input
            if let session {
                do { let loaded = try await session.reviewThemes(account: account, appId: app.id); guard !Task.isCancelled else { return }; state = loaded }
                catch { if !Task.isCancelled { status = message(error) } }
            }
            if !Task.isCancelled { working = false }
        }
        .onChange(of: input) { if input != reviewedInput { review = nil; reviewedInput = nil }; latest = nil }
        .onChange(of: evidenceQuery) { evidencePage = 1 }
        .onDisappear { operationId = nil; operation?.cancel(); operation = nil }
    }
    private var savedThemes: some View {
        Group {
            if state?.themes.isEmpty == true { Text("No themes saved for this app.").foregroundStyle(StorebenchTheme.muted) }
            if let themes = state?.themes, !themes.isEmpty {
                StorebenchCollection(items: themes, title: { $0.theme }, preferenceID: "saved-feedback", empty: "No themes saved for this app.") { item in
                    themeDetails(item)
                    if editing == item.id { Text("Editing").font(.sbCallout).foregroundStyle(StorebenchTheme.muted) }
                    else {
                        Button("Edit Theme") {
                            guard !unavailable, canDiscard() else { return }; setFields(item); original = input; review = nil; latest = nil; status = ""
                        }.storebenchWorking(unavailable)
                    }
                }
            }
        }
    }
    private var fields: some View {
        VStack(alignment: .leading, spacing: 8) {
            field("Theme", $theme); field("Intended action", $action); field("Decision", $decision); field("Follow-up", $followUp)
            Text("Complete each field with up to 1,000 characters.").font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
        }.storebenchWorking(unavailable)
    }
    private func field(_ label: String, _ text: Binding<String>) -> some View {
        StorebenchTextArea(title: label, text: text, height: StorebenchTheme.textarea())
    }
    private var evidencePicker: some View {
        let rows = ReviewsPresentation.filter(state?.snapshot?.reviews ?? reviews, .init(query: evidenceQuery))
        return VStack(alignment: .leading, spacing: 8) {
            Text("\(evidence.count) reviews selected (up to 50)").font(.sbHeadline)
            StorebenchTextField("Search all saved feedback", text: $evidenceQuery).storebenchWorking(unavailable)
            StorebenchCollection(items: rows, title: { $0.title.isEmpty ? "Review evidence" : $0.title }, subtitle: { "\($0.rating) / 5 · \($0.territory)" }, preferenceID: "evidence-chooser", empty: "No saved feedback matches. Change or clear the search.") { row in
                evidenceDetails(row)
                StorebenchToggle("Use as theme evidence", isOn: Binding(get: { evidence.contains(row.id) }, set: { selected in
                    if selected { if evidence.count < 50 { evidence.insert(row.id) } } else { evidence.remove(row.id) }
                })).storebenchWorking(unavailable)
                    .opacity(evidence.count >= 50 && !evidence.contains(row.id) ? 0 : 1).allowsHitTesting(evidence.count < 50 || evidence.contains(row.id)).accessibilityHidden(evidence.count >= 50 && !evidence.contains(row.id))
            }

            DisclosureGroup("Read selected evidence") {
                StorebenchCollection(items: (state?.snapshot?.reviews ?? reviews).filter { evidence.contains($0.id) }, title: { $0.title.isEmpty ? "Review evidence" : $0.title }, preferenceID: "selected-evidence", empty: "No reviews selected yet. Select reviews above to use them as evidence.") { row in evidenceDetails(row) }
                let missing = evidence.subtracting(Set((state?.snapshot?.reviews ?? reviews).map(\.id)))
                if !missing.isEmpty { Text("\(missing.count) selected reviews are unavailable. Compare the latest save before reviewing.").foregroundStyle(StorebenchTheme.muted) }
            }
        }
    }
    private var editorActions: some View {
        Group {
            if state != nil && !evidence.isEmpty && !version.isEmpty { Button("Review Theme") { run { id in await prepare(id) } }.help("Prepare Theme Review").accessibilityLabel("Prepare Theme Review") }
            Button("New Theme") {
                guard !unavailable, canDiscard() else { return }; setFields(nil); original = input; review = nil; latest = nil; status = ""
            }
            Button("Read Review") {
                guard !unavailable, canDiscard() else { return }; run { id in await readPending(id) }
            }.help("Read Pending Theme Review").accessibilityLabel("Read Pending Theme Review")
        }.storebenchWorking(unavailable)
    }
    private func scrollText(_ value: String, height: CGFloat) -> some View {
        StorebenchTextSlot(text: value, height: height, font: .sbCallout, color: nil)
    }
    private func evidenceDetails(_ row: CustomerReview) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(row.rating)/5 · \(row.territory) · \(row.createdDate)").font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
            scrollText(row.title + "\n" + row.body, height: 100)
        }
    }
    private func themeDetails(_ item: ReviewTheme) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(item.versionLabel) · saved \(item.savedAt)").font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
            ForEach(Array([("Theme", item.theme), ("Intended action", item.action), ("Decision", item.decision), ("Follow-up", item.followUp)].enumerated()), id: \.offset) { _, pair in
                Text(pair.0).font(.sbHeadline); scrollText(pair.1, height: 64)
            }
            Text("Feedback checked \(item.snapshotCheckedAt). \(item.limited ? "Older reviews may be missing." : "Snapshot is not marked as limited.")").font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
            StorebenchCollection(items: item.evidence, title: { $0.title.isEmpty ? "Review evidence" : $0.title }, preferenceID: "saved-evidence", empty: "No evidence saved with this theme.") { row in evidenceDetails(row) }
        }
    }
    private func canDiscard() -> Bool { !unavailable && (!dirty || EditorProtection.confirm(.confirmDiscard)) }
    private func setFields(_ item: ReviewTheme?) {
        editing = item?.id; version = item.map { "\($0.revisionId)|\($0.versionId)" } ?? ""
        theme = item?.theme ?? ""; action = item?.action ?? ""; decision = item?.decision ?? ""; followUp = item?.followUp ?? ""
        evidence = Set(item?.evidence.map(\.id) ?? []); evidencePage = 1
    }
    private func run(_ action: @escaping @MainActor (UUID) async -> Void) {
        guard !unavailable else { return }; let id = UUID(); operationId = id; working = true
        operation = Task { await action(id); if operationId == id { working = false; operationId = nil; operation = nil } }
    }
    private func prepare(_ id: UUID) async {
        guard let session, let state else { return }; let submitted = input
        do {
            let value = try await session.prepareReviewTheme(account: account, appId: app.id, input: submitted, baseline: state)
            guard operationId == id, !Task.isCancelled else { return }; self.state = value.baseline
            if submitted == input { reviewedInput = submitted; review = value; status = "Read the exact evidence and decision below, then save the reviewed theme locally." }
            else { review = nil; status = "Inputs changed during preparation. Prepare another review." }
        } catch { if operationId == id { review = nil; status = message(error) } }
    }
    private func save(_ value: ReviewThemePreparation, _ id: UUID) async {
        guard let session else { return }
        do {
            _ = try await session.saveReviewTheme(account: account, appId: app.id, preparation: value)
            guard operationId == id, !Task.isCancelled else { return }; setFields(nil); original = input; review = nil; latest = nil
            let loaded = try await session.reviewThemes(account: account, appId: app.id)
            guard operationId == id, !Task.isCancelled else { return }; state = loaded; status = "Theme saved locally."
        } catch { if operationId == id { review = nil; status = message(error) } }
    }
    private func readLatest(_ id: UUID) async {
        guard let session else { return }
        latestReading = true; defer { latestReading = false }
        do {
            let value = try await session.reviewThemes(account: account, appId: app.id)
            guard operationId == id, !Task.isCancelled else { return }; latest = value; status = "Latest save read. Compare and choose your baseline; nothing has been saved."
        } catch { if operationId == id { status = message(error) } }
    }
    private func readPending(_ id: UUID) async {
        guard let session else { return }
        do {
            let value = try await session.pendingReviewTheme(account: account, appId: app.id)
            guard operationId == id, !Task.isCancelled else { return }
            if let value { state = value.baseline; setFields(value.theme); original = input; reviewedInput = input; latest = nil; review = value; status = "Read this pending review before explicitly saving it locally." }
            else { status = "No pending theme review is saved." }
        } catch { if operationId == id { status = message(error) } }
    }
    private func changes(_ saved: ReviewThemeState) -> [SavedValueChange] {
        let item = saved.themes.first { $0.id == editing }
        let savedVersion = item.map { "\($0.revisionId)|\($0.versionId)" } ?? ""
        let savedIds = (item?.evidence.map(\.id) ?? []).sorted().joined(separator: "\n")
        let values: [(String, String, String, String)] = [("theme", "Theme", item?.theme ?? "", theme), ("action", "Intended action", item?.action ?? "", action), ("decision", "Decision", item?.decision ?? "", decision),
                      ("followUp", "Follow-up", item?.followUp ?? "", followUp), ("release", "Release", savedVersion, version),
                      ("reviews", "Selected feedback IDs", savedIds, evidence.sorted().joined(separator: "\n"))]
        var result = values.filter { !$0.2.utf8.elementsEqual($0.3.utf8) }.map { SavedValueChange(id: $0.0, label: $0.1, saved: $0.2, edited: $0.3) }
        for id in evidence.sorted() {
            let old = state?.snapshot?.reviews.first { $0.id == id }?.json.stringify() ?? "Unavailable", new = saved.snapshot?.reviews.first { $0.id == id }?.json.stringify() ?? "Unavailable"
            if !old.utf8.elementsEqual(new.utf8) { result.append(SavedValueChange(id: "feedback:" + id, label: "Feedback " + id, saved: new, edited: old)) }
        }
        return result
    }
    private func acceptLatest(useSaved: Bool) {
        guard let latest, !unavailable else { return }
        if useSaved { setFields(latest.themes.first { $0.id == editing }); original = input }
        state = latest; self.latest = nil; review = nil; status = "Baseline chosen. Prepare a new review before saving locally."
    }
    private func message(_ error: Error) -> String { (error as? ReviewThemeFailure)?.message ?? "Saved themes could not be verified. Existing saves are kept." }
}
