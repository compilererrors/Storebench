import StorebenchCore
import SwiftUI

struct OverviewSection: View {
    let account: Account, app: Account.App, session: WorkspaceSession?
    @Binding var snapshot: AppOverviewMaterial.Snapshot?
    let changed: () -> Void, openSource: (String) -> Void, openCancellation: (AppOverviewVersions.Cancellation) -> Void
    @State private var reading = false
    @State private var failed = false
    @State private var status = ""
    @State private var managing = false
    @State private var deleting = false
    @Environment(\.editorNavigation) private var navigation
    @Environment(\.navigationPresentation) private var history

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            AppSyncCard(account: account, app: app, session: session, changed: materialChanged, openSource: openSource)
            MaterialImportCard(account: account, app: app, session: session, changed: materialChanged, onlyWhenNeeded: true)
            AppLiveVersionsView(account: account, app: app, session: session, plan: snapshot?.plan, openCancellation: openCancellation)
            Card(title: "Saved on this Mac", subtitle: "This app's App Store text and screenshots that Storebench has saved: synced versions and drafts.", actions: AnyView(
                StorebenchBusyButton(title: "Refresh", loadingTitle: "Reading…", busy: reading || deleting) { Task { await load() } }.help("Refresh what is saved on this Mac").accessibilityLabel("Refresh what is saved on this Mac")
            )) {
                StorebenchTextSlot(text: status, height: 48, font: .sbCallout, color: StorebenchTheme.muted, live: true)
            }
            if let snapshot {
                if let latest = snapshot.latest {
                    StorebenchMetricGrid(maximumColumns: 3) {
                        Fact(title: latest.local ? "Local draft created" : "Latest import", value: LibraryOverview.timestamp(latest.importedAt), compact: true)
                        Fact(title: "Bundle ID", value: snapshot.bundleId.isEmpty ? "—" : snapshot.bundleId, compact: true)
                        Fact(title: "Primary locale", value: snapshot.primaryLocale.isEmpty ? "—" : snapshot.primaryLocale, compact: true)
                    }
                    Card(title: "Continue working", subtitle: "Prepare the next version, adjust country prices or review sales for this app.") {
                        StorebenchCardList {
                            related(.release, description: "Create a version draft and prepare its languages, screenshots and previews.")
                            StorebenchDivider()
                            related(.pricing, description: "Compare the pricing model and country overrides before publishing.")
                            StorebenchDivider()
                            related(.sales, description: "Import reports once and use the same country totals in Pricing.")
                        }
                    }
                    Card(title: "App Information", subtitle: "Localized app name and subtitle from this saved snapshot.") {
                        ForEach(Array(snapshot.information.enumerated()), id: \.offset) { _, info in
                            HStack(alignment: .top, spacing: 16) {
                                ScrollView { Text(info.locale).font(.sbHeadline).frame(maxWidth: .infinity, alignment: .leading) }.frame(width: 120, height: 48)
                                VStack(alignment: .leading, spacing: 4) {
                                    StorebenchTextSlot(text: info.name, height: 40, font: nil, color: nil)
                                    StorebenchTextSlot(text: info.subtitle, height: 40, font: .sbCallout, color: StorebenchTheme.muted)
                                }
                            }
                            StorebenchDivider()
                        }
                    }
                    SavedVersionBrowser(revision: latest, account: account, app: app, session: session, available: !failed && !reading && !deleting).id(latest.id + "/" + String(latest.documentRevision))
                } else if !failed {
                    Card(title: "Nothing saved yet", subtitle: "Sync the app to bring in its App Store text and screenshots, or start a new version in Release.") {
                        StorebenchFormFooter {
                            Button("New Version") { navigation.open(.release, locale: nil) }
                        }
                    }
                }
                if snapshot.latest != nil || managing {
                    Card(title: "Saved versions", subtitle: "Each sync is kept separately, so you can compare them.") {
                        DisclosureGroup("Manage saved versions", isExpanded: $managing) {
                            SavedRevisionList(account: account, app: app, session: session, revisions: snapshot.history, planSourceId: snapshot.plan?.sourceRevisionId,
                                available: !failed && !reading, busy: reading, busyChanged: { deleting = $0 }, removed: { message in
                                    status = message; changed(); Task { await load(preserveStatus: true) }
                                })
                        }
                        StorebenchFormFooter {
                            Button("Compare Versions") { navigation.open(.history, locale: nil) }
                        }
                    }
                }
            } else if !failed && session != nil {
                // The section's own card with a status line until the saved material is read; nothing stands in for it.
                Card(title: "Saved on this Mac", subtitle: "This app's App Store text and screenshots that Storebench has saved.") { StorebenchLoadingStatus(message: "Reading what is saved…", surface: false) }
            }
        }.task {
            if snapshot == nil { snapshot = history?.rememberedRead("app-material/\(account.id)/\(app.id)", as: AppOverviewMaterial.Snapshot.self) }
            await load()
        }.trackUnsavedChanges(false, busy: reading)
    }
    private func related(_ section: AppNavigation.Section, description: String) -> some View {
        StorebenchNavigationCard(title: section.title, description: description, action: "Open", activate: { navigation.open(section, locale: nil) }) {
            StorebenchIcon(name: section.designIcon, size: 20).foregroundStyle(StorebenchTheme.color("color-accent-medium"))
                .frame(width: 42, height: 42).background(StorebenchTheme.color("color-surface-accent"), in: RoundedRectangle(cornerRadius: 12))
        }
    }
    private func materialChanged() { changed(); Task { await load() } }
    private func load(preserveStatus: Bool = false) async {
        guard !reading, !deleting, let session else { return }; reading = true
        defer { reading = false }
        do {
            let value = try await session.appOverviewMaterial(accountId: account.id, appId: app.id); try Task.checkCancellation()
            snapshot = value; failed = false; history?.rememberRead(value, "app-material/\(account.id)/\(app.id)")
            if !preserveStatus { status = "Up to date with what is saved on this Mac." }
        } catch is CancellationError { }
        catch { failed = true; status = "What is saved could not be read. What you saw before is kept; refresh before opening details or deleting saved versions." }
    }
}

struct AppLiveVersionsView: View {
    let account: Account, app: Account.App, session: WorkspaceSession?, plan: ReleasePlan?
    let openCancellation: (AppOverviewVersions.Cancellation) -> Void
    @State private var entries: [AppOverviewVersions.Entry]?
    @State private var readId: UUID?
    @State private var listHeight: Double = 160
    @State private var reading = false
    @State private var failed = false
    @Environment(\.navigationPresentation) private var history
    private var readKey: String { "apple-versions/\(account.id)/\(app.id)" }
    private var available: Bool { !reading && !failed && entries != nil }
    var body: some View {
        Card(title: "Versions at Apple", subtitle: "Read directly from App Store Connect. Local drafts are listed separately below.", help: "versions", actions: AnyView(
            StorebenchBusyButton(title: "Sync Versions", loadingTitle: "Syncing Versions…", busy: reading) { Task { await load(fresh: true) } }
                .help("Reads the versions and their states from App Store Connect. Nothing is sent to Apple; changes are sent in App Store changes.")
        )) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Versions last read stay listed while they are read again; Cancel Submission waits for Apple's current answer.
                    if entries == nil && !failed { Text("Syncing versions from App Store Connect…").foregroundStyle(StorebenchTheme.muted) }
                    else if failed { Text("Could not sync versions from App Store Connect. Choose Sync Versions to try again.").foregroundStyle(StorebenchTheme.muted) }
                    else if entries?.isEmpty == true { Text("No Apple versions were returned.").foregroundStyle(StorebenchTheme.muted) }
                    if !failed {
                        ForEach(entries ?? []) { entry in
                            HStack(alignment: .firstTextBaseline) {
                                Text(entry.value.name).font(.sbHeadline).fixedSize(horizontal: false, vertical: true)
                                Text(entry.state).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
                                Spacer()
                                if entry.inReview, let scope = try? RecoveryGuidance.Scope(accountId: account.id, appId: app.id), let destination = try? AppOverviewVersions.Cancellation(scope: scope, version: entry) {
                                    if available { Button("Cancel Submission") { openCancellation(destination) }.fixedSize() }
                                }
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: (entries == nil && !failed || entries?.isEmpty == false && !failed) ? listHeight : StorebenchTheme.measure("fieldHint"))
            if entries?.isEmpty == false && !failed {
                DisclosureGroup("Adjust list size") {
                    StorebenchStepper("List height", value: $listHeight, in: 96...800, step: 40)
                        .font(.sbCaption).storebenchFormColumn().accessibilityLabel("Versions at Apple list height")
                }
            }
            if let plan {
                StorebenchTextSlot(text: "Version draft: \(plan.label). " + planStatus(plan), height: 64, font: .sbCallout, color: StorebenchTheme.muted)
            }
        }.task {
            if entries == nil { entries = history?.rememberedRead(readKey, as: [AppOverviewVersions.Entry].self) }
            await load()
        }.trackUnsavedChanges(false, busy: reading)
    }
    private func planStatus(_ plan: ReleasePlan) -> String {
        guard available, let entries else { return "Apple has not confirmed whether this version exists there. Saved text and media stay local until reviewed and uploaded." }
        guard let target = AppOverviewVersions.target(plan, versions: entries) else {
            return "This version does not exist at Apple yet. Saving or refreshing local data does not create it."
        }
        // Once submitted, Apple has the version's material; only an editable version still waits for the local text and media.
        return ["PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED", "INVALID_BINARY"].contains(target.value.state)
            ? "Apple has this version as \(target.state). Save to App Store Connect in Release sends its text and media."
            : "Apple has this version as \(target.state). Its text and media are with Apple; edits on this Mac stay saved here."
    }
    private func load(fresh: Bool = false) async {
        guard let session, !reading, !Task.isCancelled else { return }; let id = UUID(); readId = id; reading = true; defer { if readId == id { reading = false } }
        if fresh { await session.invalidateAppleReads() }
        do {
            let values = try await session.currentAppVersions(account: account, appId: app.id, client: try await session.readClient(for: account))
            try Task.checkCancellation(); guard readId == id else { return }; entries = values.map(AppOverviewVersions.Entry.init); failed = false
            history?.rememberRead(entries ?? [], readKey)
        } catch is CancellationError { } catch { if readId == id { failed = true } }
    }
}
