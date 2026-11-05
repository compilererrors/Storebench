import StorebenchCore
import SwiftUI

struct PricingProfilesSettingsView: View {
    let model: LibraryModel
    @State private var profiles: [PricingProfile] = []
    @State private var defaultId = ""
    @State private var liveIds: Set<String> = []
    @State private var dirtyIds: Set<String> = []
    @State private var busy = false
    @State private var status = ""
    @State private var loaded = false

    var body: some View {
        StorebenchForm {
            VStack(alignment: .leading, spacing: StorebenchTheme.space(1)) {
                Text(!loaded ? "Reading pricing profiles…" : liveIds.count == 1 ? "1 saved profile" : "\(liveIds.count) saved profiles").font(.sbHeadline)
                Text("Shared profiles give apps a reusable guide country, pricing method and country percentages. Each app can save its own model in Pricing.")
                    .font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
                StorebenchFeedback(text: status, height: 34)
            }
            if loaded && profiles.isEmpty { Text("No pricing profiles saved yet.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted) }
            ForEach(profiles) { profile in
                SharedPricingProfileEditor(profile: profile, defaultId: defaultId, removed: !liveIds.contains(profile.id), session: model.session, busy: $busy,
                    onDirty: { if $0 { dirtyIds.insert(profile.id) } else { dirtyIds.remove(profile.id) } },
                    onSaved: { snapshot, message in accept(snapshot); status = message },
                    onDiscard: { profiles.removeAll { $0.id == profile.id }; dirtyIds.remove(profile.id) })
            }
        }.task {
            guard let session = model.session else { return }
            do { accept(try await session.pricingProfiles()); loaded = true }
            catch { status = "Pricing profiles could not be read." }
        }
    }

    private func accept(_ snapshot: (defaultId: String, profiles: [PricingProfile])) {
        let ids = Set(snapshot.profiles.map(\.id))
        profiles = snapshot.profiles + profiles.filter { !ids.contains($0.id) && dirtyIds.contains($0.id) }
        liveIds = ids; defaultId = snapshot.defaultId
    }
}

private struct SharedPricingProfileEditor: View {
    let profile: PricingProfile
    let defaultId: String
    let removed: Bool
    let session: WorkspaceSession?
    @Binding var busy: Bool
    let onDirty: (Bool) -> Void
    let onSaved: ((defaultId: String, profiles: [PricingProfile]), String) -> Void
    let onDiscard: () -> Void
    @State private var latestReading = false
    @State private var editor: SavedValueReview<PricingProfileInputs>
    @State private var startingDefault: String
    @State private var latestDefault: String?
    @State private var status = ""
    @Environment(\.confirmDestructive) private var confirm

    init(profile: PricingProfile, defaultId: String, removed: Bool, session: WorkspaceSession?, busy: Binding<Bool>, onDirty: @escaping (Bool) -> Void,
         onSaved: @escaping ((defaultId: String, profiles: [PricingProfile]), String) -> Void, onDiscard: @escaping () -> Void) {
        self.profile = profile; self.defaultId = defaultId; self.removed = removed; self.session = session; _busy = busy
        self.onDirty = onDirty; self.onSaved = onSaved; self.onDiscard = onDiscard
        _editor = State(initialValue: SavedValueReview(value: PricingProfileInputs(profile), revision: PricingModels.profileRevision(profile)))
        _startingDefault = State(initialValue: defaultId)
    }

    var body: some View {
        Card(title: editor.baseline.value.name, subtitle: profile.id == defaultId ? "Default pricing profile" : "Shared pricing profile") {
            PricingInputFields(inputs: $editor.inputs, identity: true).storebenchWorking(busy)

            LatestSaveReview(busy: busy, reading: latestReading, hasEdits: editor.dirty, changes: editor.comparison.map { PricingInputChanges.compare($0.value, editor.inputs, identity: true) }, note: nil,
                             onRead: { Task { await readLatest() } }, onKeep: removed ? nil : { acceptLatest(useSaved: false) }, onUse: removed ? nil : { acceptLatest(useSaved: true) })
            Text(removed ? "This profile was deleted elsewhere. Your inputs are retained here; copy anything you need before discarding this editor." : editor.dirty ? "Your profile edits are not saved." : "This profile is saved on this Mac.")
                .font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
            StorebenchFeedback(text: status, height: 34)
            if removed { Button("Discard Editor", role: .destructive) {
                if !busy, confirm(.discardChanges, title: "Discard this deleted profile's unsaved edits?", message: "The profile was deleted elsewhere. Its unsaved edits here are discarded.", action: "Discard Edits") { onDiscard() }
            }.help("Discard Deleted Profile Editor").accessibilityLabel("Discard Deleted Profile Editor").storebenchWorking(busy) }
            if !removed && session != nil {
                StorebenchFormFooter {
                    Button("Duplicate") { Task { await change("duplicate") } }
                    if profile.id != defaultId {
                        Button("Make Default") { Task { await change("default") } }
                        Button("Delete", role: .destructive) {
                            if !busy, confirm(.deletePricingProfile, title: "Delete this pricing profile?", message: "Unsaved edits to it are discarded too. Prices at App Store Connect do not change.", action: "Delete Profile") { Task { await change("delete") } }
                        }
                    }
                    Button("Save Profile") { Task { await change("save") } }.buttonStyle(StorebenchButtonStyle(.primary)).storebenchWorking(!(editor.dirty))
                }.storebenchWorking(busy)
            }
        }
        .onChange(of: editor.dirty) { onDirty(editor.dirty) }
        .trackUnsavedChanges(editor.dirty, busy: busy, onSave: { await change("save"); return !editor.dirty })
        .onChange(of: profile) {
            if !editor.dirty { editor = SavedValueReview(value: PricingProfileInputs(profile), revision: PricingModels.profileRevision(profile)); startingDefault = defaultId }
        }
        .onChange(of: defaultId) { if !editor.dirty { startingDefault = defaultId } }
    }

    private func change(_ action: String) async {
        guard !busy, !removed, let session else { return }
        busy = true; defer { busy = false }
        do {
            let saved = action == "save" ? try editor.inputs.validated() : nil
            try await session.updatePricingProfile(action, id: profile.id, profile: saved, revision: editor.baseline.revision, expectedDefault: startingDefault)
            // Accept the exact written value; a later concurrent save must still fail its revision check.
            if let saved { editor = SavedValueReview(value: PricingProfileInputs(saved), revision: PricingModels.profileRevision(saved)); onDirty(false) }
            if action == "delete" { onDirty(false) }
            let snapshot = try await session.pricingProfiles()
            if action == "default" { startingDefault = profile.id }
            latestDefault = nil
            let messages = ["save": "Pricing profile saved.", "duplicate": "Pricing profile duplicated.", "default": "Default pricing profile changed.", "delete": "Pricing profile deleted."]
            status = messages[action] ?? ""; onSaved(snapshot, status)
        } catch PricingFailure.stale { status = "The saved profile or default selection changed. Your inputs remain here. Compare with the latest save before trying again." }
        catch let failure as PricingFailure { status = failure.message }
        catch { status = "The profile change could not be confirmed. Read the latest save to check it." }
    }

    private func readLatest() async {
        guard !busy, let session else { return }
        latestReading = true; defer { latestReading = false }
        busy = true; defer { busy = false }
        do {
            let snapshot = try await session.pricingProfiles()
            guard let latest = snapshot.profiles.first(where: { $0.id == profile.id }) else { status = "This profile is no longer saved. Your inputs remain here."; return }
            editor.compare(value: PricingProfileInputs(latest), revision: PricingModels.profileRevision(latest)); latestDefault = snapshot.defaultId; status = ""
        } catch { status = "The latest saved profile could not be read. Your inputs and revision are unchanged." }
    }

    private func acceptLatest(useSaved: Bool) {
        guard !busy, editor.comparison != nil, let latestDefault else { return }
        editor.acceptLatest(useSaved: useSaved); startingDefault = latestDefault; self.latestDefault = nil
        status = useSaved ? "Saved values loaded. Nothing was saved." : "Your edits are kept against the chosen latest save. Nothing was saved."
    }
}
