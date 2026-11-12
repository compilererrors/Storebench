import StorebenchCore
import SwiftUI

/// Each version keeps its own disclosure choice even when its plan or Apple status changes.
struct ReleaseOverviewList: View {
    let releases: [LibraryOverview.Release]
    let session: WorkspaceSession?
    let unavailable: Bool
    let icon: (ConnectedApps.Row) -> AnyView
    let open: (LibraryOverview.Release) -> Void
    @State private var editor: ReleaseCardsEditor?
    @State private var suggestion = false
    @State private var optionsFocus = StorebenchScrollFocus()
    @Environment(\.pageFocusInteraction) private var interaction
    private var keys: [String] { releases.map { key($0) } }
    var body: some View {
        Card(title: "Continue Preparing", subtitle: "Open a release to continue where you left off. Expand a card to see its requirements.",
             help: "versions", actions: AnyView(options)) {
            if let editor, let preferences = editor.preferences {
                if releases.count <= 3 {
                    VStack(alignment: .leading, spacing: StorebenchTheme.gap) {
                        ForEach(releases) { release in card(release, editor: editor, preferences: preferences) }
                    }
                } else {
                    StorebenchCollection(items: releases, title: { $0.title }, cardSurface: false, standalone: true,
                                         preferenceID: "overview-release-cards", empty: "No release plans yet.") {
                        card($0, editor: editor, preferences: preferences)
                    }
                }
                if !editor.status.isEmpty {
                    StorebenchFeedback(text: editor.status, error: true)
                    StorebenchActionGroup { Button("Try Again") { editor.retry(); Task { await editor.load(keys: keys) } } }
                }
            } else {
                StorebenchLoadState(state: editor?.status.isEmpty == false
                    ? .failed(editor?.status ?? "Release cards could not be read.", retry: { await reload() })
                    : .loading("Reading your release card layout…")) { EmptyView() }
            }
        }
        .background(StorebenchNativeQuestion(presented: $suggestion, identifier: "release.cards.suggestion", title: "Minimize all by default?",
            message: "Start new release cards minimized. Existing releases keep your choices. You can change this in Settings → General → Release Cards.",
            choices: [.init(id: "release.cards.suggestion.yes", title: "Yes", isDefault: true),
                      .init(id: "release.cards.suggestion.later", title: "Ask Later", isCancel: true),
                      .init(id: "release.cards.suggestion.no", title: "No")], select: { id in
                let answer: ReleaseCardPreferences.Answer = id.hasSuffix(".yes") ? .yes : id.hasSuffix(".no") ? .no : .later
                editor?.change(.answer(answer, Date()))
            }).frame(width: 0, height: 0))
        .task(id: "\(session.map { String(describing: ObjectIdentifier($0)) } ?? "")/\(keys.joined(separator: "/"))") {
            if let session, editor?.session !== session { editor = ReleaseCardsEditor(session: session); suggestion = false }
            await StorebenchPolling.repeating(every: .seconds(2), while: { !Task.isCancelled }) { await reload() }
        }
        .onChange(of: editor?.preferences) {
            if editor?.preferences?.canSuggest(at: Date()) != true || keys.contains(where: { editor?.preferences?.expanded($0) != false }) { suggestion = false }
        }
        .onChange(of: keys) { suggestion = false }
    }
    private var options: some View {
        StorebenchIconMenu(title: "Release Card Options", icon: "sort") {
            Button("Expand All") { interaction?(); optionsFocus.reveal(.preserve); expand(keys, true) }
                .storebenchWorking(editor?.preferences == nil || keys.allSatisfy { editor?.preferences?.expanded($0) == true })
            Button("Minimize All") { interaction?(); optionsFocus.reveal(.preserve); expand(keys, false) }
                .storebenchWorking(editor?.preferences == nil || keys.allSatisfy { editor?.preferences?.expanded($0) == false })
        }.storebenchControlID("release.cards.options").background(StorebenchScrollFocusAnchor(focus: optionsFocus))
    }
    private func key(_ release: LibraryOverview.Release) -> String {
        ReleaseCardPreferences.key(accountId: release.plan.accountId, appId: release.plan.appId, platform: release.plan.platform, version: release.plan.targetVersion)
    }
    private func expand(_ keys: [String], _ value: Bool) {
        guard let editor, let previous = editor.preferences else { return }
        let closedSomething = !value && keys.contains { previous.expanded($0) }
        editor.change(.expanded(keys, value))
        if value { suggestion = false }
        else if closedSomething, !self.keys.isEmpty, self.keys.allSatisfy({ editor.preferences?.expanded($0) == false }), previous.canSuggest(at: Date()) { suggestion = true }
    }
    private func reload() async {
        await editor?.load(keys: keys)
    }
    private func card(_ release: LibraryOverview.Release, editor: ReleaseCardsEditor, preferences: ReleaseCardPreferences) -> some View {
        ReleaseOverviewDisclosureCard(title: release.title, overview: release.app.release, icon: icon(release.app),
            expanded: Binding(get: { editor.preferences?.expanded(key(release)) ?? preferences.expanded(key(release)) }, set: { expand([key(release)], $0) }),
            unavailable: unavailable, identifier: "continue.release." + release.id, open: { open(release) })
    }
}

struct ReleaseOverviewDisclosureCard: View {
    let title: String, overview: ReleaseOverview?, icon: AnyView
    @Binding var expanded: Bool
    var unavailable = false
    var identifier = "release.card"
    let open: () -> Void
    var body: some View {
        StorebenchDisclosureCard(expanded: $expanded) {
            HStack(spacing: StorebenchTheme.gap) {
                icon.frame(width: 42, height: 42).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    StorebenchAdaptiveText(text: title, font: .sbHeadline)
                    StorebenchTextSlot(text: overview.map { $0.status + " · " + $0.detail } ?? "Status Unavailable", height: 34, font: .sbCaption, color: StorebenchTheme.muted, live: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.accessibilityLabel(title).storebenchControlID(identifier + ".disclosure")
        } action: {
            Button(action: open) { StorebenchLabel(overview?.action ?? "Open Release", icon: "right", size: 14) }
                .buttonStyle(StorebenchButtonStyle(.quiet)).storebenchWorking(unavailable)
                .storebenchControlID(identifier + ".open")
        } content: {
            VStack(alignment: .leading, spacing: 4) {
                if overview?.submitted != true {
                    ForEach(0..<3, id: \.self) { index in
                        let item = overview?.preview.indices.contains(index) == true ? overview!.preview[index] : nil
                        StorebenchTextSlot(text: item.map { "• " + $0.title } ?? "", height: 30, font: .sbCaption,
                            color: item?.kind == "blocked" ? StorebenchTheme.color("color-danger") : StorebenchTheme.muted)
                            .help(item?.detail ?? "").storebenchControlID(identifier + ".item.\(index)")
                    }
                }
                StorebenchTextSlot(text: feedback, height: 34, font: .sbCaption, color: StorebenchTheme.muted, live: true)
            }.storebenchControlID(identifier + ".details")
        }.storebenchControlID(identifier)
    }
    private var feedback: String {
        guard let overview else { return "Open Release to check this app." }
        let more = overview.moreCount > 0 ? "And \(overview.moreCount) More in Release\n" : ""
        if overview.checking { return more + "Checking App Store Connect…" }
        if overview.failed { return more + "Latest Check Failed · Open Release to Retry" }
        return more + (overview.checkedAt.map { "Status Checked " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "App Store Connect has not been checked yet")
    }
}
