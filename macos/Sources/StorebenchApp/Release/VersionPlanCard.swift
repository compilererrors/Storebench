import StorebenchCore
import SwiftUI

struct VersionPlanCard: View {
    let model: ReleasePlanEditor
    let history: [Revision]
    let availability: NewVersionAvailability
    let protectionId: String
    let didSave: (_ creating: Bool) async -> Void
    /// Quick Release keeps the version's starting point and a valid release option as they are, and only names them.
    var quick = false
    private enum Start: String, CaseIterable { case reuse = "Continue a version", copy = "Copy an earlier version", empty = "Start empty" }
    private typealias Base = ReleaseSetup.Candidate
    @State private var latestReading = false
    @State private var operation: Task<Void, Never>?
    @Environment(\.editorProtection) private var protection
    @Environment(\.confirmDestructive) private var confirm

    var body: some View {
        Card(title: model.plan.map { "Version \($0.targetVersion)" } ?? "New Version",
             subtitle: quick ? (model.plan == nil ? "Enter the version number and choose how Apple releases it, then click Create. The version starts from the current text and keeps everything else. App Store Connect changes only when you approve the reviews below." : "Change the number or release option here, then Save. This app's next version starts with the same release option. App Store Connect changes only when you approve the reviews below.")
                : model.plan == nil ? "Enter the version number and choose how Apple releases it, then click Create. The version is kept on this Mac until you save it to App Store Connect in step 3." : "Change the number or release option here. App Store Connect changes only when you approve them in step 3.",
             help: "versions") {
            if !model.loaded { Text("Reading the saved version…").font(.sbCallout).foregroundStyle(StorebenchTheme.muted) }
            if model.loaded && model.needsComparison {
                Text("This version changed elsewhere. Compare it with the latest save below, then choose which values to keep.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
                comparison(model)
            }
            if model.loaded && !model.needsComparison {
                if let plan = model.plan { workingOn(plan) } else { starting(model) }
                Text("Version").font(.sbCallout.weight(.semibold))
                numberField(model)
                if !quick { Text("App Store Version Release").font(.sbCallout.weight(.semibold)) }
                releaseFields(model)
            }
            if !model.status.isEmpty { StorebenchTextSlot(text: model.status, height: 40, font: .sbCallout, color: StorebenchTheme.muted, live: true) }
            if case .available(let submitted?) = availability {
                Text("\(submitted) has been submitted in App Store Connect. You can remove this version and start a new one.").font(.sbCallout).fixedSize(horizontal: false, vertical: true)
            }
            if model.loaded && !model.needsComparison {
                StorebenchFormFooter {
                    if model.plan == nil || model.dirty || model.busy {
                        StorebenchBusyButton(title: model.plan == nil ? "Create" : "Save", loadingTitle: "Saving…", busy: model.busy, variant: .primary) { run(model, removing: false) }
                            .help(model.plan == nil ? "Create the new version on this Mac and continue" : "Save the version on this Mac")
                    }
                    if model.dirty && !model.busy && model.plan != nil { Button("Revert") { model.revert() }.help("Revert to the saved version") }
                    if model.plan != nil && !model.busy { Button("Remove", role: .destructive) {
                        guard let plan = model.plan, confirm(.removeVersion, title: "Remove version \(plan.targetVersion) from this Mac?",
                                                             message: "The version plan is removed from this Mac. Its text and screenshots stay saved as a local draft. Nothing changes at App Store Connect.", action: "Remove") else { return }
                        run(model, removing: true)
                    }.help("Remove this version from this Mac. Nothing changes at Apple.") }
                }
            }
        }
        .onDisappear { operation?.cancel() }
    }
    @ViewBuilder private func starting(_ model: ReleasePlanEditor) -> some View {
        let first = mode(model.inputs) == .empty && ReleaseSetup.candidates(history).isEmpty
        if quick {
            Text(startSummary(model)).font(.sbCallout).foregroundStyle(StorebenchTheme.muted).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        } else if first {
            Text("This is the app's first version. Choose its platform and language.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
            startingFields(model)
        } else {
            Text(startSummary(model)).font(.sbCallout).foregroundStyle(StorebenchTheme.muted).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Start from another version") {
                VStack(alignment: .leading, spacing: 12) {
                    Text(startDetail(model)).font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
                    startingFields(model)
                }.padding(.top, 8)
            }
        }
    }
    private func startSummary(_ model: ReleasePlanEditor) -> String {
        let base = selectedBase(model).map { ReleaseSetup.describe($0) }
        switch mode(model.inputs) {
        case .reuse: return base.map { "Continues \($0), already in App Store Connect." } ?? "Continues the existing version in App Store Connect."
        case .copy: return base.map { "Text and screenshots are copied from \($0), as App Store Connect does for a new version." } ?? "Text and screenshots are copied from the current version, as App Store Connect does for a new version."
        case .empty: return "Starts empty: you write the text and add screenshots yourself."
        }
    }
    private func mode(_ input: ReleasePlanInputs) -> Start {
        switch input.start { case .reuse: .reuse; case .copy: .copy; case .empty: .empty }
    }
    private func key(_ base: Base) -> String { JSONText.array([.string(base.revision.id), .string(base.version.id)]).stringify() }
    /// Continuing lists Apple versions with the ones still being prepared first; a copy can start from any version or local draft.
    private func bases(_ model: ReleasePlanEditor) -> [Base] {
        let all = ReleaseSetup.candidates(history)
        if mode(model.inputs) == .copy { return all }
        let imported = all.filter { !$0.revision.isLocalDraft }
        return imported.filter(\.canContinue) + imported.filter { !$0.canContinue }
    }
    private func selectedBase(_ model: ReleasePlanEditor) -> Base? {
        ReleaseSetup.candidates(history).first { $0.revision.id == model.inputs.sourceRevisionId && $0.version.id == model.inputs.baseVersionId }
    }
    private func suggestion(_ model: ReleasePlanEditor) -> String {
        ReleaseSetup.suggestedNumber(model.inputs.start, base: mode(model.inputs) == .empty ? nil : selectedBase(model), history: history)
    }
    /// Changing what to work on fills in its version number, unless a number was typed by hand.
    private func change(_ model: ReleasePlanEditor, _ update: (inout ReleasePlanInputs) -> Void) {
        let before = suggestion(model), typed = model.inputs.targetVersion.trimmingCharacters(in: .whitespaces)
        var next = model.inputs; update(&next); model.inputs = next
        if typed.isEmpty || typed == before { model.inputs.targetVersion = suggestion(model) }
    }
    private func startDetail(_ model: ReleasePlanEditor) -> String {
        switch mode(model.inputs) {
        case .reuse: "Work on a version that already exists at Apple, such as one in Prepare for Submission. Its text and screenshots are your starting point."
        case .copy: "Start the next version from an earlier one. Its text and screenshots are copied into a new version number."
        case .empty: "For an app or platform with no version at Apple yet. You write the text and add screenshots from scratch."
        }
    }
    private func numberConflict(_ model: ReleasePlanEditor) -> String? {
        let number = model.inputs.targetVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !number.isEmpty else { return nil }
        let platform: String
        if case .empty(let value, _) = model.inputs.start { platform = value } else { guard let base = selectedBase(model) else { return nil }; platform = base.version.platform }
        let clash = ReleaseSetup.candidates(history).first { !$0.revision.isLocalDraft && $0.version.platform == platform && $0.version.number == number }
        guard let clash, !(mode(model.inputs) == .reuse && clash.version.id == model.inputs.baseVersionId), number != model.plan?.targetVersion else { return nil }
        return clash.canContinue
            ? "\(clash.version.title) already has an active release in App Store Connect. Choose Continue a version under Start from another version, or enter another number."
            : "\(clash.version.title) already exists at Apple. Enter a higher number."
    }
    @ViewBuilder private func workingOn(_ plan: ReleasePlan) -> some View {
        let base = ReleaseSetup.candidates(history).first { $0.revision.id == plan.sourceRevisionId && $0.version.id == plan.baseVersionId }
        HStack(alignment: .top, spacing: StorebenchTheme.space(3)) {
            StorebenchIcon(name: "release", size: 20).foregroundStyle(StorebenchTheme.color("color-accent-medium"))
                .frame(width: 40, height: 40).background(StorebenchTheme.color("color-surface-accent-strong"), in: RoundedRectangle(cornerRadius: 10)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: StorebenchTheme.space(1)) {
                Text("Working on \(plan.label)").font(.sbHeadline).fixedSize(horizontal: false, vertical: true)
                Text(plan.settings).font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
                if let base { Text("Started from " + ReleaseSetup.describe(base)).font(.sbCallout).foregroundStyle(StorebenchTheme.muted).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.accessibilityElement(children: .combine)
    }
    @ViewBuilder private func startingFields(_ model: ReleasePlanEditor) -> some View {
        StorebenchChoicePicker("Start", selection: Binding(get: { mode(model.inputs) }, set: { value in
            change(model) { inputs in
                inputs.start = value == .empty ? .empty(platform: "IOS", locale: "en-US") : value == .copy ? .copy : .reuse
                let candidates = value == .copy ? ReleaseSetup.candidates(history) : ReleaseSetup.candidates(history).filter { !$0.revision.isLocalDraft }
                if value != .empty, !candidates.contains(where: { $0.revision.id == inputs.sourceRevisionId && $0.version.id == inputs.baseVersionId }) || value == .reuse {
                    let preferred = value == .reuse ? candidates.first(where: \.canContinue) ?? candidates.first : candidates.first
                    if value == .reuse || !candidates.contains(where: { $0.revision.id == inputs.sourceRevisionId && $0.version.id == inputs.baseVersionId }) {
                        inputs.sourceRevisionId = preferred?.revision.id; inputs.baseVersionId = preferred?.version.id
                    }
                }
            }
        }), options: Start.allCases.map { ($0, $0.rawValue) }).labelsHidden().storebenchFormColumn().storebenchWorking(model.busy)
        if case .empty(let platform, let locale) = model.inputs.start {
            StorebenchFormGrid { emptyFields(model, platform: platform, locale: locale) }.storebenchWorking(model.busy)
        } else {
            StorebenchPicker(mode(model.inputs) == .reuse ? "Version to continue" : "Copy from", selection: Binding(get: {
                JSONText.array([.string(model.inputs.sourceRevisionId ?? ""), .string(model.inputs.baseVersionId ?? "")]).stringify()
            }, set: { value in
                guard let selected = bases(model).first(where: { key($0) == value }) else { return }
                change(model) { $0.sourceRevisionId = selected.revision.id; $0.baseVersionId = selected.version.id }
            })) {
                selectionOptions(bases(model)) { item in SelectionOption(ReleaseSetup.describe(item), value: key(item)) }
            }.storebenchFormColumn().storebenchWorking(model.busy)
            if bases(model).isEmpty {
                Text(mode(model.inputs) == .reuse ? "No version from App Store Connect is saved yet. Sync the app first, or choose Start empty." : "No saved versions are available. Choose Start empty.")
                    .font(.sbCallout).foregroundStyle(StorebenchTheme.muted)
            } else if mode(model.inputs) == .reuse, selectedBase(model)?.canContinue == false {
                Text("This version has no active release in the saved App Store Connect status. Refresh its status, or choose Copy an earlier version to ship new changes.").font(.sbCallout).foregroundStyle(StorebenchTheme.color("color-danger")).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    @ViewBuilder private func emptyFields(_ model: ReleasePlanEditor, platform: String, locale: String) -> some View {
        StorebenchPicker("Platform", selection: Binding(get: { platform }, set: { value in change(model) { $0.start = .empty(platform: value, locale: locale) } })) {
            selectionOptions(Releases.platforms) { SelectionOption($0.1, value: $0.0) }
        }
        StorebenchPicker("Language", selection: Binding(get: { locale }, set: { model.inputs.start = .empty(platform: platform, locale: $0) })) {
            selectionOptions(StoreLocales.codes) { SelectionOption(StoreLocales.name($0), value: $0) }
        }
    }
    @ViewBuilder private func numberField(_ model: ReleasePlanEditor) -> some View {
        @Bindable var model = model
        StorebenchTextField("Version number", text: $model.inputs.targetVersion, placeholder: suggestion(model).isEmpty ? "2.0" : suggestion(model)).labelsHidden().storebenchFormColumn()
            .accessibilityLabel("Version number").storebenchWorking(model.busy)
        if let conflict = numberConflict(model) {
            Text(conflict).font(.sbCallout).foregroundStyle(StorebenchTheme.color("color-danger")).fixedSize(horizontal: false, vertical: true)
        }
    }
    @ViewBuilder private func releaseFields(_ model: ReleasePlanEditor) -> some View {
        @Bindable var model = model
        if quick {
            // Saved with the version, and remembered for this app's next version.
            StorebenchPicker("App Store Version Release", selection: $model.inputs.releaseType) {
                selectionOptions(Releases.releaseTypes) { SelectionOption($0.1, value: $0.0) }
            }.storebenchFormColumn().storebenchWorking(model.busy)
        } else {
            StorebenchChoicePicker("Version Release", selection: $model.inputs.releaseType, options: Releases.releaseTypes, style: .radio).labelsHidden().storebenchWorking(model.busy)
        }
        if model.inputs.releaseType == "SCHEDULED" {
            StorebenchDateField("Earliest release", selection: $model.inputs.date, in: Date()...).storebenchFormColumn().storebenchWorking(model.busy)
        }
    }
    @ViewBuilder private func comparison(_ model: ReleasePlanEditor) -> some View {
        LatestSaveReview(busy: model.busy, reading: latestReading, hasEdits: model.dirty || model.needsComparison, available: model.loaded, changes: model.latestInputs.map { comparisons($0, model.inputs) },
            note: model.latestRead ? (model.latest == nil ? "No version plan is currently saved." : "Keeping edits uses this saved plan's starting version.") : nil,
            onRead: { operation = Task { latestReading = true; defer { latestReading = false }; await model.readLatest() } },
            onKeep: model.latestRead ? { accept(model, keep: true) } : nil,
            onUse: model.latestRead ? { accept(model, keep: false) } : nil)
    }
    private func comparisons(_ saved: ReleasePlanInputs, _ edited: ReleasePlanInputs) -> [SavedValueChange] {
        let fields = [("version", "Version number", saved.targetVersion, edited.targetVersion),
                      ("method", "Release method", saved.releaseType, edited.releaseType),
                      ("date", "Earliest release", saved.releaseType == "SCHEDULED" ? ISO8601DateFormatter.fractional.string(from: saved.date) : "", edited.releaseType == "SCHEDULED" ? ISO8601DateFormatter.fractional.string(from: edited.date) : ""),
                      ("source", "Starting version", "\(saved.sourceRevisionId ?? "Empty") · \(saved.baseVersionId ?? "")", "\(edited.sourceRevisionId ?? "Empty") · \(edited.baseVersionId ?? "")")]
        return fields.filter { !$0.2.utf8.elementsEqual($0.3.utf8) }.map { .init(id: $0.0, label: $0.1, saved: $0.2, edited: $0.3) }
    }
    private func accept(_ model: ReleasePlanEditor, keep: Bool) {
        guard model.active, !model.busy, model.latestRead else { return }
        if model.plan?.sourceRevisionId != model.latest?.sourceRevisionId || model.plan?.baseVersionId != model.latest?.baseVersionId {
            guard protection?.allowLeaving(excluding: protectionId) != false else { return }
        }
        model.acceptLatest(keepEdits: keep)
    }
    private func run(_ model: ReleasePlanEditor, removing: Bool) {
        guard model.ready else { return }
        if removing { guard protection?.allowLeaving() != false else { return } }
        let creating = !removing && model.plan == nil
        operation = Task {
            let saved = removing ? await model.remove() : await model.save()
            guard saved, model.active, !Task.isCancelled else { return }
            await didSave(creating)
        }
    }
}
