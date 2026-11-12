import Foundation

extension QuickRelease {
    public enum Status: String, Sendable, Equatable { case ready, review, missing }
    public struct Check: Sendable, Equatable {
        public let status: Status, label: String, detail: String
        public init(_ status: Status, _ label: String, _ detail: String) { self.status = status; self.label = label; self.detail = detail }
    }
    public struct Phase: Identifiable, Sendable, Equatable {
        public let id: String, number: Int, title: String, purpose: String, check: Check
        public var complete: Bool { check.status == .ready }
    }
    /// Readiness, pending sync and missing required input are separate. Unknown observations never turn green.
    public static func check(_ steps: [ReleaseReadiness.Step], excluding fields: Set<String> = []) -> Check {
        guard !steps.isEmpty else { return .init(.review, "Not Checked", "This information has not been confirmed yet.") }
        let classified = steps.map { step -> Status in
            switch step.state {
            case .ready: return .ready
            case .review:
                return step.id.hasPrefix("editorial:") ? .review : .ready
            case .unknown, .waiting, .manual: return .review
            case .blocked:
                if !step.issues.isEmpty, step.issues.allSatisfy({ fields.contains($0.field) }) { return .ready }
                if step.id.hasPrefix("apple-text:") || step.id.hasPrefix("apple-info:") || step.id == "version" { return .review }
                if step.id.hasPrefix("media:") && !step.issues.contains(where: { $0.section == "rejected" }) { return .review }
                return .missing
            }
        }
        if classified.contains(.missing) {
            return .init(.missing, "Needs Action", steps.first { $0.state == .blocked }?.detail ?? "Required information is missing.")
        }
        if classified.allSatisfy({ $0 == .ready }) { return .init(.ready, "Ready", "The checked information is ready to use.") }
        let waiting = steps.contains { $0.state == .waiting }
        let differs = steps.contains { $0.state == .blocked }
        return .init(.review, waiting ? "Waiting for Apple" : differs ? "Sync Needed" : "Check Needed",
                     steps.first { [.unknown, .manual, .waiting, .blocked].contains($0.state) }?.detail ?? "Review this information before continuing.")
    }
    public static func progress(plan: ReleasePlan?, snapshot: ReleaseReadinessSnapshot?, edited: Bool = false,
                                notes values: [String: String]? = nil, notesEdited: Bool = false, notesRequired: Bool = true) -> [Phase] {
        let snapshot = snapshot.flatMap { value -> ReleaseReadinessSnapshot? in
            guard let plan, value.plan.token == plan.token, value.scope.accountId == plan.accountId, value.scope.appId == plan.appId else { return nil }
            return value
        }
        let steps = snapshot?.steps ?? [], submitted = snapshot.map { if case .submitted = stage($0) { return true }; return false } ?? false
        let unknown = Check(.review, "Not Checked", "Checking this version against App Store Connect.")
        let prepared: Check
        if plan == nil { prepared = .init(.review, "Start Here", "Choose the version number and prepare the release on this Mac.") }
        else if edited { prepared = .init(.review, "Save Draft", "The version settings have unsaved changes.") }
        else if submitted { prepared = .init(.ready, "Ready", "Apple has this submitted version.") }
        else if let snapshot, let blocker = ReleaseCreation.blocker(snapshot) { prepared = .init(blocker.version.state.isEmpty ? .review : .missing, blocker.version.state.isEmpty ? "Check Current Version" : "Resolve Current Version", blocker.detail) }
        else if let snapshot, snapshot.targetVersionId != nil {
            let target = WorkspaceSession.items(snapshot.observations["appleVersions"]).first { $0["id"]?.text == snapshot.targetVersionId }
            prepared = target?["releaseType"]?.text.map { !$0.isEmpty && $0 != (plan?.releaseType ?? "MANUAL") } == true
                ? .init(.review, "Sync Needed", "Review the saved release option and sync it to Apple.") : .init(.ready, "Ready", "The version is prepared in App Store Connect.")
        } else { prepared = .init(.review, "Sync Needed", "The local version is saved. Approve its creation in App Store Connect here.") }
        let locals = steps.filter { $0.id.hasPrefix("local:") }
        let missingNotes = locals.flatMap(\.issues).filter { $0.field == "whatsNew" }
        let notes: Check
        if submitted { notes = .init(.ready, "Ready", "Apple has the text for this submitted version.") }
        else if !notesRequired { notes = .init(.ready, "Not Required", "App Store Connect does not require release notes for a first version.") }
        else if let values, !values.isEmpty, values.values.contains(where: { releaseNotesIssue($0) != nil }) {
            notes = .init(.missing, "What's New Needs Action", "Add valid release notes within Apple's text limit for every language.")
        }
        else if values != nil && notesEdited { notes = .init(.review, "Save Draft", "The release notes have unsaved changes. Save them here, then sync to Apple.") }
        else if !missingNotes.isEmpty { notes = .init(.missing, "What's New Is Missing", "Add What's New in This Version for each language that needs it.") }
        else if locals.isEmpty || locals.contains(where: { $0.state == .unknown }) { notes = unknown }
        else {
            let remote = steps.filter { $0.id.hasPrefix("apple-text:") }
            let differs = remote.contains { $0.state == .blocked && ($0.issues.isEmpty || $0.issues.contains { $0.field == "whatsNew" }) }
            notes = remote.isEmpty || remote.contains(where: { $0.state == .unknown }) || differs
                ? .init(.review, "Sync Needed", "The local release notes are ready. Review and sync them to Apple.")
                : .init(.ready, "Ready", "The release notes are saved at Apple.")
        }
        let build: Check
        if submitted && snapshot?.targetState != "WAITING_FOR_EXPORT_COMPLIANCE" { build = .init(.ready, "Ready", "Apple has the build for this submitted version.") }
        else if snapshot?.parts.contains(.versions) == true && snapshot?.targetVersionId == nil {
            build = .init(.missing, "Build Is Missing", "Choose and add the processed build for the new version.")
        } else { build = check(steps.filter { ["build", "export-compliance"].contains($0.id) }) }
        let remaining = check(steps.filter { !handledHere($0.id) }, excluding: ["whatsNew"])
        let review = submitted ? Check(.ready, AppStoreNames.state(snapshot?.targetState ?? ""), "Apple has this version from its submission.")
            : Check(.review, prepared.status == .ready && notes.status == .ready && build.status == .ready && remaining.status == .ready ? "Ready for Review" : "Waiting for Required Items",
                    "Review the release requirements, then approve Add for Review. Nothing is submitted automatically.")
        return [
            .init(id: "version", number: 1, title: "Prepare Release", purpose: "Prepare the version and reuse its existing listing and screenshots.", check: prepared),
            .init(id: "text", number: 2, title: "What's New in This Version", purpose: "Add release notes. Other listing text is kept in the collapsed section below.", check: notes),
            .init(id: "build", number: 3, title: "Add Build", purpose: "Choose the processed build and confirm its export compliance.", check: build),
            .init(id: "submit", number: 4, title: "Add for Review", purpose: "Check the remaining requirements and approve the submission here.", check: review),
        ]
    }
    public static func initialStep(_ phases: [Phase]) -> String {
        if phases.first?.check.status != .ready { return "version" }
        return phases.first { $0.check.status == .missing }?.id ?? phases.first { $0.check.status != .ready }?.id ?? "submit"
    }
}
