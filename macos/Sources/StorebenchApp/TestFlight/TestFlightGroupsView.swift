import AppKit
import StorebenchCore
import SwiftUI

struct TestFlightGroupsView: View {
    let account: Account, app: Account.App, session: WorkspaceSession?
    /// Internal Testing or External Testing shows only those groups, as App Store Connect does; nil shows both.
    var internalOnly: Bool? = nil
    /// A group to open once the groups are read, such as the one a guide step is about.
    var initialGroupId: String? = nil
    @Environment(\.editorProtection) private var protection
    @State private var working = false
    @State private var preparing = false
    @State private var publishing = false
    @State private var memberState = "loading"
    @State private var nameBaseline = ""
    @State private var limitBaseline = ""
    @State private var groups: [TestFlightGroup] = []
    @State private var builds: [TestFlightBuild] = []
    @State private var testers: [TestFlightTester] = []
    @State private var selected: String?
    @State private var members: (builds: [String], testers: [TestFlightTester])?
    /// Builds and testers were read after the latest groups read.
    @State private var choicesRead = false
    @State private var review: PublishReview?
    @State private var status = ""
    @State private var buildChoice = ""
    @State private var testerChoice = ""
    @State private var newName = ""
    @State private var newInternal = true
    @State private var rename = ""
    @State private var email = ""
    @State private var limit = ""
    @State private var restoring: String??
    @Environment(\.navigationPresentation) private var history
    private struct Read: Codable { let groups: [TestFlightGroup], builds: [TestFlightBuild], testers: [TestFlightTester] }
    private var readKey: String { "testflight-groups/\(account.id)/\(app.id)" }

    private var busy: Bool { working || preparing || publishing }
    private var shown: [TestFlightGroup] { groups.filter { internalOnly == nil || $0.internalGroup == internalOnly } }
    private var title: String { internalOnly == true ? "Internal Testing" : internalOnly == false ? "External Testing" : "Testing groups" }
    private var subtitle: String {
        switch internalOnly {
        case true: "Groups for your App Store Connect team, up to 100 testers. Builds reach them without Beta App Review."
        case false: "Groups for anyone with an email address or a public link. The first build for these testers needs Beta App Review."
        default: "Internal groups are for your App Store Connect team; external groups can include anyone with an email address."
        }
    }
    private var edited: [Data] { [newName, rename, email, limit, buildChoice, testerChoice].map { Data($0.utf8) } }
    private var dirty: Bool { !newName.isEmpty || newInternal != (internalOnly ?? true) || !email.isEmpty || !rename.utf8.elementsEqual(nameBaseline.utf8) || !limit.utf8.elementsEqual(limitBaseline.utf8) || !buildChoice.isEmpty || !testerChoice.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Card(title: title, subtitle: subtitle, help: "testflight") {
                StorebenchCollection(items: shown, title: { $0.name }, subtitle: summary, empty: status.isEmpty ? "No groups yet. Create one below." : status) { group in
                    StorebenchFormFooter {
                        if selected != group.id { Button("View Group") { Task { await select(group) } }.fixedSize() }
                    }
                }
                Text("Create Group").font(.sbHeadline)
                StorebenchFormGrid {
                    StorebenchTextField("Group name", text: $newName)
                    if internalOnly == nil { StorebenchChoicePicker("Type", selection: $newInternal, options: [(true, "Internal Testing"), (false, "External Testing")]) }
                }
                StorebenchFeedback(text: status, height: 40)
                if !newName.trimmingCharacters(in: .whitespaces).isEmpty {
                    StorebenchFormFooter {
                        Button("Create Group") { Task { await prepare { $0.testflightAction = "create-group"; $0.groupName = newName; $0.internalGroup = newInternal } } }
                            .buttonStyle(StorebenchButtonStyle(.primary))
                    }
                }
            }
            .storebenchWorking(busy)
            ReviewPanel(account: account, app: app, session: session, review: $review, done: { Task { await didPublish() } }, busyChanged: { publishing = $0 }).storebenchWorking(working || preparing)
            if let selected, let group = groups.first(where: { $0.id == selected }) { groupCard(group).storebenchWorking(busy) }
        }
        .task {
            if let internalOnly, newName.isEmpty { newInternal = internalOnly }
            if groups.isEmpty, let read = history?.rememberedRead(readKey, as: Read.self) { groups = read.groups; builds = read.builds; testers = read.testers }
            await load()
            // Back reopens the group that was open, with its members read again.
            if case .some(let id) = restoring { restoring = nil; if let id, let group = groups.first(where: { $0.id == id }) { await select(group) } }
            else if selected == nil, let id = initialGroupId, let group = groups.first(where: { $0.id == id }) { await select(group) }
        }
        .historyValue("testflight-groups", Binding(get: { restoring ?? selected }, set: { restoring = .some($0) }))
        .trackUnsavedChanges(dirty, busy: busy)
        .onChange(of: edited) { if !busy, review?.state == "prepared" { review = nil } }
        .onChange(of: newInternal) { if !busy, review?.state == "prepared" { review = nil } }
    }

    private func summary(_ group: TestFlightGroup) -> String {
        var parts = [group.internalGroup == true ? "Internal group" : group.internalGroup == false ? "External group" : "Unknown type",
                     "Feedback \(group.feedbackEnabled == true ? "on" : group.feedbackEnabled == false ? "off" : "unknown")"]
        if group.hasAccessToAllBuilds == true { parts.append("Automatic build distribution") }
        if group.publicLinkEnabled == true { parts.append("Public link on\(group.publicLinkLimit.map { " · limit \($0) testers" } ?? "")") }
        return parts.joined(separator: " · ")
    }

    private func groupCard(_ group: TestFlightGroup) -> some View {
        Card(title: group.name, subtitle: "Group settings, build access and testers. Every change is prepared as a review first.") {
            Text("Settings").font(.sbHeadline)
            StorebenchInputActions {
                StorebenchTextField("Group name", text: $rename)
            } actions: {
                if !rename.trimmingCharacters(in: .whitespaces).isEmpty && rename != group.name { Button("Rename") { Task { await prepare { $0.testflightAction = "rename-group"; $0.groupId = group.id; $0.groupName = rename } } }.fixedSize() }
            }
            HStack(spacing: 12) {
                Text("Tester feedback: \(group.feedbackEnabled == true ? "On" : group.feedbackEnabled == false ? "Off" : "Unknown")")
                Button(group.feedbackEnabled == true ? "Turn Off Feedback" : "Turn On Feedback") { Task { await setting(group, "feedback", .bool(group.feedbackEnabled != true)) } }.fixedSize()
            }
            if group.internalGroup == false {
                HStack(spacing: 12) {
                    Text("Public link: \(group.publicLinkEnabled == true ? "On" : "Off")")
                    Button(group.publicLinkEnabled == true ? "Disable Public Link" : "Enable Public Link") { Task { await setting(group, "public-link", .bool(group.publicLinkEnabled != true)) } }.fixedSize()
                }
                if let link = group.publicLink, group.publicLinkEnabled == true { Text(link).font(.sbCallout).textSelection(.enabled) }
                StorebenchInputActions {
                    StorebenchTextField("Tester limit", text: $limit, hint: "Leave empty for no limit.", placeholder: "No limit")
                } actions: {
                    if (limit.isEmpty || Int(limit) != nil) && limit != limitBaseline { Button("Set Tester Limit") { Task { await setting(group, "public-link-limit", .number(Double(Int(limit) ?? 0))) } }.fixedSize() }
                }
            }
            StorebenchDivider()
            if let members {
                Text("Builds").font(.sbHeadline)
                if members.builds.isEmpty { Text("No builds assigned.").foregroundStyle(StorebenchTheme.muted) }
                ForEach(members.builds, id: \.self) { id in
                    HStack {
                        Text(builds.first { $0.id == id }?.title ?? "Build \(id)")
                        Spacer()
                        Button("Remove Access", role: .destructive) { Task { await prepare(buildId: id) { $0.testflightAction = "remove-build"; $0.groupId = group.id } } }.buttonStyle(StorebenchButtonStyle(.quiet)).fixedSize()
                    }
                }
                StorebenchInputActions {
                    StorebenchPicker("Add build", selection: $buildChoice) { SelectionOption("Choose a build", value: ""); selectionOptions(builds.filter { $0.processed && $0.betaReviewState != "REJECTED" && $0.externalState != "BETA_REJECTED" && (group.internalGroup == true ? ["INTERNAL_ONLY", "APP_STORE_ELIGIBLE"].contains($0.audience) : group.internalGroup == false && $0.audience == "APP_STORE_ELIGIBLE") && !members.builds.contains($0.id) }) { SelectionOption($0.title, value: $0.id) } }
                } actions: {
                    if !buildChoice.isEmpty { Button("Add Build") { Task { await prepare(buildId: buildChoice) { $0.testflightAction = "add-build"; $0.groupId = group.id } } }.fixedSize() }
                }
                StorebenchDivider()
                Text("Testers").font(.sbHeadline)
                StorebenchCollection(items: members.testers, title: { $0.email }, subtitle: { $0.name }, empty: "No testers in this group.") { tester in
                    StorebenchFormFooter {
                        Button("Remove from Group", role: .destructive) { Task { await prepare { $0.testflightAction = "remove-tester"; $0.groupId = group.id; $0.testerId = tester.id } } }.buttonStyle(StorebenchButtonStyle(.quiet)).fixedSize()
                    }
                }
                StorebenchInputActions {
                    StorebenchTextField("Tester email", text: $email, placeholder: "tester@example.com")
                } actions: {
                    if email.contains("@") { Button("Add Tester") { Task { await prepare { $0.testflightAction = "invite-tester"; $0.groupId = group.id; $0.testerEmail = email.trimmingCharacters(in: .whitespaces) } } }.fixedSize() }
                }
                let others = testers.filter { tester in !members.testers.contains { $0.id == tester.id } }
                if !others.isEmpty {
                    StorebenchInputActions {
                        StorebenchPicker("Existing tester", selection: $testerChoice) { SelectionOption("Choose a tester", value: ""); selectionOptions(others) { SelectionOption($0.email, value: $0.id) } }
                    } actions: {
                        if !testerChoice.isEmpty { Button("Add to Group") { Task { await prepare { $0.testflightAction = "add-tester"; $0.groupId = group.id; $0.testerId = testerChoice } } }.fixedSize() }
                    }
                }
            } else if memberState == "failed" {
                Text("Group access could not be confirmed. Reload before choosing a build or tester.").foregroundStyle(StorebenchTheme.muted)
                Button("Reload Group") { Task { await loadMembers() } }.fixedSize()
            } else {
                Group {
                    Text("Builds").font(.sbHeadline)
                    Text("Placeholder for assigned builds").foregroundStyle(StorebenchTheme.muted)
                    StorebenchPicker("Add build", selection: .constant("")) { SelectionOption("Choose a build", value: "") }.storebenchFormColumn()
                    StorebenchDivider()
                    Text("Testers").font(.sbHeadline)
                    StorebenchCollectionPlaceholder(rows: 1)
                    StorebenchTextField("Tester email", text: .constant(""), placeholder: "tester@example.com")
                }.storebenchPlaceholder()
            }
            StorebenchDivider()
            Text("Deleting the group removes its testers' access to its builds through this group.").font(.sbCallout).foregroundStyle(StorebenchTheme.muted).fixedSize(horizontal: false, vertical: true)
            StorebenchFeedback(text: status, height: 40)
            StorebenchFormFooter {
                Button("Delete Group", role: .destructive) { Task { await prepare { $0.testflightAction = "delete-group"; $0.groupId = group.id } } }.fixedSize()
            }
        }
    }

    private func select(_ group: TestFlightGroup) async {
        guard !busy, protection?.allowLeaving() != false else { return }
        selected = group.id; review = nil; buildChoice = ""; testerChoice = ""; email = ""
        newName = ""; newInternal = internalOnly ?? true
        rename = group.name; nameBaseline = rename
        limit = group.publicLinkLimit.map(String.init) ?? ""; limitBaseline = limit
        await loadMembers()
    }
    private func didPublish() async {
        guard review?.state == "complete" else { return }
        let action = review?.request.testflightAction
        if action == "create-group" { newName = ""; newInternal = internalOnly ?? true }
        if action == "invite-tester" { email = "" }
        if ["add-build", "remove-build"].contains(action ?? "") { buildChoice = "" }
        if ["add-tester", "remove-tester"].contains(action ?? "") { testerChoice = "" }
        if action == "rename-group" { nameBaseline = rename }
        if action == "set-group-setting", review?.request.groupSetting == "public-link-limit" { limitBaseline = limit }
        await load(); await loadMembers()
    }

    private func setting(_ group: TestFlightGroup, _ name: String, _ value: JSONText) async {
        await prepare { $0.testflightAction = "set-group-setting"; $0.groupId = group.id; $0.groupSetting = name; $0.groupSettingValue = value }
    }

    private func prepare(buildId: String? = nil, _ configure: (inout PublishRequest) -> Void) async {
        guard !busy else { return }
        preparing = true; defer { preparing = false }
        (review, status) = await prepareTestFlight(account, app, session, buildId: buildId, configure)
    }

    /// Opening reads only the groups. Builds and testers fill the open group's pickers, so they are read when a group opens.
    private func load() async {
        guard !working, let session else { return }
        working = true; defer { working = false }
        do {
            let nextGroups = try await session.testFlightGroups(account: account, appId: app.id)
            groups = nextGroups; choicesRead = false
            history?.rememberRead(Read(groups: nextGroups, builds: builds, testers: testers), readKey)
            if let selected, !groups.contains(where: { $0.id == selected }) { self.selected = nil; members = nil }
            status = ""
        } catch { status = "TestFlight groups could not be loaded from App Store Connect." }
    }

    private func loadMembers() async {
        guard !working, let session, let selected else { return }
        working = true; defer { working = false }
        members = nil; memberState = "loading"
        // The app's builds and testers to add are read once per groups read, alongside the group's members.
        let readChoices = !choicesRead
        async let nextBuilds = readChoices ? session.testFlightBuilds(account: account, appId: app.id) : []
        async let nextTesters = readChoices ? session.allTesters(account: account, appId: app.id) : []
        do { members = try await session.groupMembers(account: account, appId: app.id, groupId: selected); memberState = "ready"; status = "" }
        catch { memberState = "failed"; status = "This group's builds and testers could not be loaded."; return }
        guard readChoices else { return }
        do {
            let (nextBuilds, nextTesters) = try await (nextBuilds, nextTesters)
            builds = nextBuilds; testers = nextTesters; choicesRead = true
            history?.rememberRead(Read(groups: groups, builds: nextBuilds, testers: nextTesters), readKey)
        } catch { status = "The builds and testers to add could not be loaded." }
    }
}
