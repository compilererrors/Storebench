import StorebenchCore
import SwiftUI

/// Editable release fields across languages. Save Changes checks and saves them on this Mac in one step.
struct ReleaseTextView: View {
    let plan: ReleasePlan, session: WorkspaceSession?
    var readiness: (() -> Bool)? = nil
    var onBusy: (Bool) -> Void = { _ in }
    var onSaved: (ReleaseTextSaveReceipt) -> Void = { _ in }
    @State private var latestReading = false
    @Environment(\.editorNavigation) private var navigation
    @State private var rows: [ReleaseText.Row] = []
    @State private var source = ""
    @State private var targets = Set<String>()
    @State private var values: [String: ReleaseText.Values] = [:]
    @State private var copied: [String: Set<String>] = [:]
    @State private var replace = false
    @State private var latest: ReleaseText.Snapshot?
    @State private var baselinePlan: ReleasePlan?
    @State private var latestPlan: ReleasePlan?
    @State private var working = false
    @State private var failed = false
    @State private var status = ""
    @State private var problem = false
    @State private var active = true
    @State private var operation: Task<Void, Never>?
    @State private var job: UUID?
    @Environment(\.editorProtection) private var protection
    private var activePlan: ReleasePlan { baselinePlan ?? plan }

    private var original: ReleaseText.Row? { rows.first { $0.locale == source } }
    private var destinations: [ReleaseText.Row] { rows.filter { $0.locale != source } }
    private var dirty: Bool { rows.contains { !ReleaseText.Values.same(values[$0.locale] ?? $0.values, $0.values) } }
    private var exceeded: Bool { destinations.filter { targets.contains($0.locale) }.contains { row in ReleaseText.fields.contains { TextDrafts.used($0, values[row.locale]?[$0] ?? "") > (TextDrafts.limits[$0] ?? 0) } } }
    private var differences: [SavedValueChange]? {
        latest.map { snapshot in snapshot.rows.flatMap { row in ReleaseText.fields.compactMap { field in
            let edited = values[row.locale]?[field] ?? row.values[field]
            return edited.utf8.elementsEqual(row.values[field].utf8) ? nil : SavedValueChange(id: "\(row.id):\(field)", label: "\(StoreLocales.name(row.locale)) · \(TextDrafts.labels[field] ?? field)", saved: row.values[field], edited: edited)
        } } }
    }
    private var canKeepLatest: Bool {
        guard let latest, latest.rows.contains(where: { $0.locale == source }) else { return false }
        return rows.filter { !ReleaseText.Values.same(values[$0.locale] ?? $0.values, $0.values) }.allSatisfy { old in latest.rows.contains { $0.id == old.id && $0.locale == old.locale } }
    }

    var body: some View {
        Card(title: "Release text across languages", subtitle: "\(activePlan.label) · edit What’s New and Promotional Text together. Copying does not translate text.", help: "listing") {
            VStack(alignment: .leading, spacing: 14) {
                if failed { Text("The saved release fields could not be read. Your edits are kept. Read the latest save before continuing.").foregroundStyle(StorebenchTheme.muted) }
                if !rows.isEmpty && rows.count < 2 {
                    StorebenchNotice(title: "Add a second language first", description: "Release text is copied and edited across languages. This version has one language; add another in Localizations, then come back here.", icon: "languages") {
                        if navigation.navigate != nil { Button("Open Localizations") { navigation.open(.localizations, locale: nil) } }
                    }
                } else if !failed {
                StorebenchSetupStep(number: 1, title: "Choose the source language", detail: "Its saved What’s New and Promotional Text are copied to the languages you choose next.") {
                    StorebenchPicker("Saved source language", selection: Binding(get: { source }, set: { value in
                        guard value != source, !working, protection?.allowLeaving() != false else { return }
                        source = value; resetValues(); resetReview()
                    })) { selectionOptions(rows) { SelectionOption(StoreLocales.name($0.locale), value: $0.locale) } }.labelsHidden().storebenchFormColumn().storebenchWorking(working)
                    if let original {
                        ForEach(ReleaseText.fields, id: \.self) { field in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(TextDrafts.labels[field] ?? field).font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
                                StorebenchTextSlot(text: original.values[field].isEmpty ? "Empty" : original.values[field], height: 20, font: nil, color: nil)
                            }
                        }
                    }
                }
                StorebenchSetupStep(number: 2, title: "Choose destination languages", detail: "\(targets.count) of \(destinations.count) selected. Only selected languages can be edited and saved.") {
                    StorebenchActionGroup {
                        if targets.count < destinations.count { Button("Select All") { targets = Set(destinations.map(\.locale)); resetReview() } }
                        if !targets.isEmpty { Button("Clear") { targets = []; resetReview() } }
                    }.storebenchWorking(working)
                }
                StorebenchCollection(items: destinations, title: { StoreLocales.name($0.locale) }, subtitle: { $0.locale + (targets.contains($0.locale) ? " · Selected destination" : "") },
                                     empty: "No other languages yet. Add a language in Localizations, then copy or edit its release text here.") { row in
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(StoreLocales.name(row.locale), isOn: Binding(get: { targets.contains(row.locale) }, set: { if $0 { targets.insert(row.locale) } else { targets.remove(row.locale) }; resetReview() })).toggleStyle(StorebenchToggleStyle()).storebenchWorking(working)
                        ForEach(ReleaseText.fields, id: \.self) { field in
                            VStack(alignment: .leading, spacing: 4) {
                                let used = TextDrafts.used(field, values[row.locale]?[field] ?? ""), limit = TextDrafts.limits[field] ?? 0
                                HStack { Text(TextDrafts.labels[field] ?? field).font(.sbCaption.weight(.semibold)); Spacer(); Text("\(used) / \(limit)").font(.sbCaption.monospacedDigit()).foregroundStyle(used > limit ? StorebenchTheme.color("color-danger") : StorebenchTheme.muted) }
                                if targets.contains(row.locale) {
                                    StorebenchTextArea(text: binding(row.locale, field), height: StorebenchTheme.textarea(rows: field == "whatsNew" ? 4 : 3))
                                        .accessibilityLabel("\(StoreLocales.name(row.locale)) · \(TextDrafts.labels[field] ?? field)").storebenchWorking(working)
                                } else {
                                    let text = values[row.locale]?[field] ?? ""
                                    Text(text.isEmpty ? "Empty" : text).font(.sbCallout).foregroundStyle(StorebenchTheme.muted).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                }
                                if let review = row.reviews[field] {
                                    CopiedTextReviewView(review: review, disabled: working || dirty || failed) { Task { await acknowledge(review) } }
                                }
                            }
                        }
                        StorebenchDivider()
                    }
                }
                StorebenchSetupStep(number: 3, title: "Copy or edit, then save", detail: targets.isEmpty ? "Select at least one destination language in step 2." : "Copy the source text into the selected languages, or edit them above. Save Changes keeps them on this Mac.") {
                    Toggle("Replace filled fields when copying", isOn: $replace).storebenchWorking(working)
                    StorebenchTextSlot(text: exceeded ? "Shorten the text that is over Apple's limit, then save." : "", height: 20, font: .sbCallout, color: StorebenchTheme.color("color-danger"), live: true)
                    if !targets.isEmpty || dirty {
                        StorebenchActionGroup {
                            if !targets.isEmpty { Button("Copy Saved Source") { copySource() }.storebenchWorking(working) }
                            StorebenchBusyButton(title: "Save Changes", loadingTitle: "Saving…", busy: working, variant: .primary) { operation = Task { _ = await save() } }.help("Save Release Text on This Mac").accessibilityLabel("Save Release Text on This Mac").storebenchWorking(!(dirty || working))
                        }
                    }
                }
                }
                StorebenchTextSlot(text: status.isEmpty ? (dirty ? "Unsaved release text. Save Changes keeps it on this Mac." : "Release text is saved on this Mac. Nothing is sent to Apple until you upload and approve it.") : status,
                                   height: 44, font: .sbCallout, color: problem ? StorebenchTheme.color("color-danger") : StorebenchTheme.muted, live: true)
                LatestSaveReview(busy: working, reading: latestReading, hasEdits: dirty || failed, changes: differences, note: canKeepLatest || latest == nil ? nil : "A language containing edits is unavailable or has changed identity. Copy the wording before choosing the latest save.",
                                 onRead: { Task { await readLatest() } }, onKeep: canKeepLatest ? { acceptLatest(keep: true) } : nil,
                                 onUse: latest == nil ? nil : { acceptLatest(keep: false) })
            }
        }
        .task(id: plan.token) {
            if rows.isEmpty { await load() }
            else if activePlan.token != plan.token { failed = true; resetReview(); status = "The version plan changed. Your edits are kept. Compare the latest save before continuing." }
        }
        .onChange(of: replace) { resetReview() }
        .onAppear { active = true }
        .onDisappear { active = false; operation?.cancel() }
        .trackUnsavedChanges(dirty, busy: working, problem: { problem ? "Release text across languages: " + status : nil }, onSave: { await save() })
    }
    private func resetReview() { latest = nil; latestPlan = nil; status = ""; problem = false }
    private func resetValues() { values = Dictionary(uniqueKeysWithValues: rows.map { ($0.locale, $0.values) }); targets = Set(destinations.map(\.locale)); copied = [:] }
    private func binding(_ locale: String, _ field: String) -> Binding<String> {
        Binding(get: { values[locale]?[field] ?? "" }, set: { values[locale, default: ReleaseText.Values()][field] = $0; copied[locale]?.remove(field); resetReview() })
    }
    private func copySource() {
        guard let original, !working else { return }
        for row in destinations where targets.contains(row.locale) {
            let result = ReleaseText.copySource(original.values, into: values[row.locale] ?? row.values, replace: replace)
            values[row.locale] = result.values; copied[row.locale, default: []].formUnion(result.copied)
        }
        resetReview()
    }
    private func selection() -> ReleaseText.Selection? {
        guard let original else { return nil }
        return ReleaseText.Selection(versionId: activePlan.baseVersionId, sourceLocale: source, sourceBaseline: original.values,
                                     targets: saveTargets, replaceExisting: ReleaseText.replacesExisting(saveTargets, replace: replace))
    }
    /// Selected languages plus any language that still holds edits, so no edit is left behind unsaved.
    private var saveTargets: [ReleaseText.Target] {
        destinations.filter { targets.contains($0.locale) || !ReleaseText.Values.same(values[$0.locale] ?? $0.values, $0.values) }.map { row in
            ReleaseText.Target(locale: row.locale, baseline: row.values, values: values[row.locale] ?? row.values, copied: ReleaseText.fields.filter { copied[row.locale]?.contains($0) == true })
        }
    }
    private func load() async {
        guard active, !Task.isCancelled, !working, let session else { return }; let ticket = begin(); defer { finish(ticket) }
        do {
            let snapshot = try await session.releaseText(accountId: plan.accountId, appId: plan.appId, revisionId: plan.sourceRevisionId, planToken: plan.token)
            try Task.checkCancellation(); guard owns(ticket) else { return }; baselinePlan = plan; rows = snapshot.rows; source = rows.first { $0.locale == snapshot.primaryLocale }?.locale ?? rows.first?.locale ?? ""; resetValues(); failed = false
        } catch { if owns(ticket), !Task.isCancelled { failed = true; status = "The saved release fields could not be read." } }
    }
    /// Checks and saves every edited release field on this Mac. Anything that cannot be saved stays in place with the reason in red.
    private func save() async -> Bool {
        guard active, !Task.isCancelled, !working else { return false }
        func fail(_ message: String) -> Bool { status = message; problem = true; return false }
        guard dirty else { return true }
        if failed { return fail("Read the latest save below and choose which text to keep, then save again. Your edits are kept.") }
        if exceeded { return fail("Shorten the text that is over Apple's limit, then save again. Your edits are kept.") }
        guard readiness?() != false else { return fail("Save or fix the language editors above first, then save release text again. Your edits are kept.") }
        guard let session, let chosen = selection() else { return fail("Release text could not be saved. Your edits are kept.") }
        let ticket = begin(); defer { finish(ticket) }
        do {
            let preview = try await session.previewReleaseText(accountId: activePlan.accountId, appId: activePlan.appId, revisionId: activePlan.sourceRevisionId, planToken: activePlan.token, selection: chosen)
            try Task.checkCancellation(); guard owns(ticket) else { return false }
            let receipt = try await session.applyReleaseTextWithReceipt(accountId: activePlan.accountId, appId: activePlan.appId, revisionId: activePlan.sourceRevisionId, planToken: activePlan.token, selection: chosen, fingerprint: preview.fingerprint)
            try Task.checkCancellation(); guard owns(ticket) else { return false }
            let result = receipt.preview; onSaved(receipt)
            rows = rows.map { row in
                var next = row.values, reviews = row.reviews
                for change in result.changes where change.localizationId == row.id { next[change.field] = change.after; reviews.removeValue(forKey: change.field); copied[row.locale]?.remove(change.field) }
                return ReleaseText.Row(id: row.id, locale: row.locale, values: next, reviews: reviews)
            }
            latest = nil; problem = false
            status = (result.changes.count == 1 ? "1 release field" : "\(result.changes.count) release fields") + " saved on this Mac. Nothing is sent to Apple until you upload and approve it."
            // Refresh provenance without accepting unrelated text changes as editor baselines.
            await refreshReviews()
            return !dirty
        } catch {
            guard owns(ticket), !Task.isCancelled else { return false }
            return fail((error as? ReleaseTextFailure).map { $0.message + " Your edits are kept." } ?? (error as? DraftFailure)?.message ?? "Release text could not be saved. Your edits are kept; try again.")
        }
    }
    private func refreshReviews() async {
        guard let session else { return }
        guard let snapshot = try? await session.releaseText(accountId: activePlan.accountId, appId: activePlan.appId, revisionId: activePlan.sourceRevisionId, planToken: activePlan.token) else { return }
        guard active, !Task.isCancelled else { return }
        rows = rows.map { row in
            guard let latest = snapshot.rows.first(where: { $0.id == row.id }), ReleaseText.Values.same(latest.values, row.values) else { return row }
            return ReleaseText.Row(id: row.id, locale: row.locale, values: row.values, reviews: latest.reviews)
        }
    }
    private func acknowledge(_ review: CopiedText.Review) async {
        guard active, !Task.isCancelled, readiness?() != false, let session, !working, !dirty else { return }; let ticket = begin(); defer { finish(ticket) }
        do {
            try await session.acknowledgeReleaseTextSource(accountId: activePlan.accountId, appId: activePlan.appId, revisionId: activePlan.sourceRevisionId, planToken: activePlan.token, review: review)
            try Task.checkCancellation(); guard owns(ticket) else { return }
            await refreshReviews(); guard owns(ticket), !Task.isCancelled else { return }; status = "Source comparison saved. Destination wording was preserved."; problem = false
        } catch {
            guard owns(ticket), !Task.isCancelled else { return }
            status = (error as? CopiedTextFailure)?.message ?? (error as? ReleaseTextFailure)?.message ?? "The source comparison could not be saved. Read the latest save and compare again."
        }
    }
    private func readLatest() async {
        guard active, !Task.isCancelled, let session, !working else { return }; let ticket = begin(); latest = nil; latestPlan = nil; defer { finish(ticket) }
        latestReading = true; defer { latestReading = false }
        do {
            let snapshot = try await session.releaseText(accountId: plan.accountId, appId: plan.appId, revisionId: plan.sourceRevisionId, planToken: plan.token)
            try Task.checkCancellation(); guard owns(ticket) else { return }; latest = snapshot; latestPlan = plan
        } catch { if owns(ticket), !Task.isCancelled { status = (error as? ReleaseTextFailure)?.message ?? "The latest save could not be read. Your edits are kept." } }
    }
    private func acceptLatest(keep: Bool) {
        guard active, !working, let latest, let latestPlan, !keep || canKeepLatest else { return }
        let retained = values; rows = latest.rows; baselinePlan = latestPlan
        if !rows.contains(where: { $0.locale == source }) { source = rows.first?.locale ?? "" }
        if keep {
            values = Dictionary(uniqueKeysWithValues: rows.map { ($0.locale, $0.locale == source ? $0.values : retained[$0.locale] ?? $0.values) })
            targets = targets.intersection(Set(destinations.map(\.locale)))
        } else { resetValues() }
        failed = false; resetReview(); status = keep ? "Latest save compared. Your edits are kept; save them when ready." : "Latest saved release fields loaded. Nothing was saved by the comparison."
    }
    private func begin() -> UUID { let ticket = UUID(); job = ticket; working = true; onBusy(true); return ticket }
    private func owns(_ ticket: UUID) -> Bool { active && job == ticket }
    private func finish(_ ticket: UUID) { if job == ticket { job = nil; working = false; onBusy(false) } }
}
