import StorebenchCore
import SwiftUI

/// How many apps are read ahead so Release and Quick Release open with their material and status already saved, and which
/// apps are always among them.
struct PreparationSettings: View {
    let model: LibraryModel
    @State private var limit = BackgroundPreparation.standard
    @State private var always: Set<String> = []
    @State private var apps: [(key: String, name: String)] = []
    @State private var baseline: BackgroundPreparation?
    private var choice: BackgroundPreparation? {
        let chosen = apps.filter { always.contains($0.key) }.compactMap(Self.app)
        return try? BackgroundPreparation(appLimit: limit, alwaysPrepared: Array(chosen.prefix(BackgroundPreparation.alwaysLimit)))
    }
    @State private var working = false
    @State private var status = ""
    @State private var problem = false
    @State private var issueCode: String?
    var body: some View {
        StorebenchFormSection("Background Preparation") {
            if baseline != nil {
                StorebenchPicker("Apps to Prepare", selection: Binding(get: { limit }, set: { limit = $0; Task { await save() } })) {
                    selectionOptions(BackgroundPreparation.limits) { SelectionOption(Self.label($0), value: $0) }
                }
                StorebenchMultiSelect(title: "Always Prepare", dialogTitle: "Always Prepare",
                                      dialogSubtitle: "These apps are prepared right after the open one, on top of Apps to Prepare.",
                                      selection: Binding(get: { always }, set: { always = $0; Task { await save() } }),
                                      options: apps.map(\.key), name: { key in apps.first { $0.key == key }?.name ?? key },
                                      summary: always.isEmpty ? "None" : always.count == 1 ? (apps.first { always.contains($0.key) }?.name ?? "1 app") : "\(always.count) apps",
                                      controlID: "settings.always-prepare")
                    .storebenchWorking(limit == 0)
            }
            Text("Storebench prepares these apps for Release and Quick Release: the open app, the apps under Always Prepare, then frequently opened apps. While unlocked, it checks for an outdated app list after opening, on returning to the app and periodically. App lists are reused for 15 minutes. Release states are checked after unlock and about once a minute while the app is open. Full preparation follows the app limit above and rechecks recent release plans about every 10 minutes. Background reads yield to open screens. App-list failures use longer retry delays.")
                .font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
            StorebenchFeedback(text: status, height: 40, error: problem)
            RecoveryActions(code: issueCode)
            if problem && baseline != nil && baseline != choice && model.session != nil {
                StorebenchFormFooter {
                    Button("Try Again") { Task { await save() } }.help("Save Apps to Prepare").accessibilityLabel("Save Apps to Prepare").buttonStyle(StorebenchButtonStyle(.primary))
                }
            }
        }
        .trackUnsavedChanges(baseline.map { choice != $0 } ?? false, busy: working, problem: { problem ? "Background preparation: " + status : nil }, onSave: { await save(); return baseline == choice })
        .task {
            guard let session = model.session else { return }
            do {
                let saved = try await session.backgroundPreparation(), accounts = try await session.accounts(); try Task.checkCancellation()
                apps = accounts.flatMap { account in account.apps.map { (key: Self.key(account.id, $0.id), name: accounts.count > 1 ? "\($0.name) · \(account.name)" : $0.name) } }
                limit = saved.appLimit; always = Set(saved.alwaysPrepared.map { Self.key($0.accountId, $0.appId) }); baseline = saved
            }
            catch { issueCode = "SB-SETTINGS-SAVE"; status = "Background preparation could not be read. Reopen this tab to retry." }
        }
    }
    private static func label(_ count: Int) -> String { count == 0 ? "Off" : count == 1 ? "1 app" : "\(count) apps" }
    private static func key(_ accountId: String, _ appId: String) -> String { JSONText.array([.string(accountId), .string(appId)]).stringify() }
    private static func app(_ entry: (key: String, name: String)) -> BackgroundPreparation.App? {
        guard case .array(let parts)? = try? JSONText.parse(Data(entry.key.utf8)), parts.count == 2, let accountId = parts[0].text, let appId = parts[1].text else { return nil }
        return .init(accountId: accountId, appId: appId)
    }
    private func save() async {
        guard !working, baseline != nil, let session = model.session else { return }
        working = true; issueCode = nil; defer { working = false }
        // A choice made while the previous one was saving is saved next.
        while let saved = baseline, let selected = choice, saved != selected {
            do { try await session.setBackgroundPreparation(selected); baseline = selected; problem = false; status = "Background preparation saved." }
            catch { issueCode = "SB-SETTINGS-SAVE"; problem = true; status = "Background preparation was not saved. Your choice is kept; try again."; return }
        }
    }
}
