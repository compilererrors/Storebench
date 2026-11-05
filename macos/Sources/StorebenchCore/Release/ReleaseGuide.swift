import Foundation

/// The release flow in the order App Store Connect works through it, built from the readiness checks.
/// Each phase groups its checks; the next step is the first check that needs action, in phase order,
/// so the guide always names one place to continue. A guide never approves or starts an Apple change.
public enum ReleaseGuide {
    public enum Status: String, Sendable {
        /// `differs`: Apple already has this step for a submitted version, so it is complete, but the draft on this Mac does not match it.
        case done, review, current, waiting, unknown, upcoming, differs
        public var label: String {
            switch self {
            case .done: "Done"; case .review: "Check"; case .current: "Next step"; case .waiting: "Waiting for Apple"; case .unknown: "Not verified yet"; case .upcoming: "Later"
            case .differs: "Done at Apple · local draft differs"
            }
        }
    }
    public struct Phase: Identifiable, Sendable {
        public let id: String, number: Int, title: String, purpose: String
        public let status: Status
        /// The status in words: App Store Connect's version state where Apple reports this step, else the status label.
        public let label: String
        /// Apple's version state settles this step: Apple no longer accepts its changes to the version, so nothing here is still needed.
        public let locked: Bool
        public let steps: [ReleaseReadiness.Step]
        /// The check this phase continues with: the first that needs action, else the first to review.
        public let focus: ReleaseReadiness.Step?
    }
    public struct Guide: Sendable {
        public let phases: [Phase]
        /// The first check that needs action, in phase order.
        public let next: ReleaseReadiness.Step?
        /// The target version's raw App Store Connect state, when Apple reported it.
        public let appleState: String?
        public var current: Phase? { phases.first { $0.status == .current } }
        public var completed: Int { phases.filter { [.done, .review, .differs].contains($0.status) }.count }
        /// The version is with App Review or later, so Apple rejects changes to its text, screenshots, build and review details.
        public var submitted: Bool { appleState.map(ReleaseGuide.submitted.contains) == true }
        /// App Store Connect still offers Cancel Submission, which returns the version to an editable state.
        public var removable: Bool { appleState.map(ReleaseGuide.removable.contains) == true }
        /// Why a locked step has nothing to change, in App Store Connect's words.
        public var lockNotice: (title: String, description: String)? {
            guard submitted, let appleState else { return nil }
            let label = AppStoreNames.state(appleState)
            return ("\(label) at Apple", removable
                ? "App Store Connect allows only some changes while a version is \(label). To change this version's text, screenshots or build, remove it from review with Cancel Submission. Edits on this Mac stay saved here."
                : "App Store Connect no longer accepts changes to this version's text, screenshots or build. Edits on this Mac stay saved here for the next version.")
        }
    }

    /// Apple states reached only after a submission, as in `ReleaseReadiness`; the steps before App Review are proven by them.
    static let submitted = ReleaseReadiness.submitted
    static let removable: Set<String> = ["WAITING_FOR_REVIEW", "IN_REVIEW"]
    /// Steps a submission settles. Waiting for Export Compliance still needs the build step.
    static let settled: Set<String> = ["plan", "listing", "send", "build", "review-information", "submit"]
    /// The step that shows Apple's state in App Store Connect's words.
    static func reporting(_ state: String) -> String { removable.contains(state) ? "submit" : state == "WAITING_FOR_EXPORT_COMPLIANCE" ? "build" : "release" }

    struct Definition: Sendable { let id, title, purpose: String; let matches: @Sendable (String) -> Bool }
    static let definitions: [Definition] = [
        .init(id: "plan", title: "New Version", purpose: "Enter the version number and choose how Apple releases it. Text and screenshots are copied from the current version, as in App Store Connect. Nothing is sent to Apple yet.", matches: { $0 == "plan" }),
        .init(id: "listing", title: "Text and Screenshots", purpose: "What's New in This Version, Promotional Text, Description, Keywords, and Previews and Screenshots for each language. Saved on this Mac.", matches: { $0.hasPrefix("local:") || $0.hasPrefix("editorial:") }),
        .init(id: "send", title: "Save to App Store Connect", purpose: "The changes for App Store Connect are listed below as soon as you open this step. Read them, then choose Send to Apple. This creates the version there and saves its text and screenshots.",
              matches: { ["version", "copyright"].contains($0) || $0.hasPrefix("apple-text:") || $0.hasPrefix("apple-info:") || $0.hasPrefix("media:") }),
        .init(id: "build", title: "Build", purpose: "Choose the build for this version and answer its export compliance questions.", matches: { ["build", "export-compliance"].contains($0) }),
        .init(id: "review-information", title: "App Review Information", purpose: "Contact details, sign-in information and notes for Apple's reviewer.", matches: { $0 == "review-info" }),
        .init(id: "submit", title: "Add for Review", purpose: "Add the version for review and Submit for Review. App Information that Apple still needs, such as Age Rating, is shown here first.",
              matches: { ["submission", "app-configuration", "age-rating", "accessibility", "territories", "privacy", "tax"].contains($0) }),
        .init(id: "release", title: "App Store Version Release", purpose: "After App Review approves the version, Apple releases it as you chose: manually, automatically or after a date.", matches: { $0 == "release" }),
    ]

    /// A check that needs nothing more from you: ready, a language whose local text and screenshots have no problems, or a language
    /// whose screenshots Apple has complete for every selected display size, even when the exact files are not proven equal.
    static func satisfied(_ step: ReleaseReadiness.Step) -> Bool {
        step.state == .ready || (step.id.hasPrefix("local:") || step.id.hasPrefix("media:")) && step.state == .review
    }

    /// `steps` are the readiness checks of a saved plan; without them only the plan phase can start.
    /// `appleState` is the target version's state at Apple. Once it shows a submission, every step before App Review is settled at Apple:
    /// those steps name no next action, and a draft on this Mac that does not match Apple stays marked as differing, never as saved.
    public static func guide(_ steps: [ReleaseReadiness.Step]?, appleState: String? = nil) -> Guide {
        guard let steps else {
            let phases = definitions.enumerated().map { index, item in
                let status: Status = index == 0 ? .current : .upcoming
                return Phase(id: item.id, number: index + 1, title: item.title, purpose: item.purpose, status: status, label: status.label, locked: false, steps: [], focus: nil)
            }
            return Guide(phases: phases, next: nil, appleState: nil)
        }
        let state = appleState.flatMap { $0.isEmpty ? nil : $0 }, submitted = state.map(Self.submitted.contains) == true
        func locked(_ id: String) -> Bool { submitted && settled.contains(id) && !(id == "build" && state == "WAITING_FOR_EXPORT_COMPLIANCE") }
        let grouped = definitions.map { item in steps.filter { item.matches($0.id) } }
        // Before a submission the release check is blocked only because the version is not submitted yet, so it waits for every
        // earlier step Apple has not confirmed rather than becoming the next step past them.
        func waits(_ index: Int) -> Bool {
            definitions[index].id == "release" && !submitted
                && definitions.indices.contains { $0 < index && !locked(definitions[$0].id) && grouped[$0].contains { [.waiting, .unknown].contains($0.state) } }
        }
        let blockedNext = definitions.indices.lazy.filter { !locked(definitions[$0].id) && !waits($0) }.compactMap { grouped[$0].first { $0.state == .blocked } }.first
        // With nothing blocked, the next step is the first one still open in order, such as Add for Review before submitting,
        // so the steps are worked through from top to bottom and each turns green when its checks are settled.
        let openIndex = definitions.indices.first { index in
            !locked(definitions[index].id) && !waits(index) && !grouped[index].isEmpty && !grouped[index].allSatisfy(satisfied) && !grouped[index].contains { [.waiting, .unknown].contains($0.state) }
        }
        let next = blockedNext ?? openIndex.flatMap { index in grouped[index].first { !satisfied($0) } }
        let currentIndex = blockedNext.flatMap { step in grouped.firstIndex { group in group.contains { $0.id == step.id } } } ?? openIndex
        let phases = definitions.enumerated().map { index, item -> Phase in
            let group = grouped[index], later = currentIndex.map { index > $0 } == true
            let status: Status
            if locked(item.id) {
                // Apple's submission proves the version, its build, App Review Information and App Information. Only local material can still differ.
                if !["listing", "send"].contains(item.id) { status = .done }
                else if group.contains(where: { $0.state == .blocked }) { status = .differs }
                else if group.allSatisfy(satisfied) { status = .done }
                else if group.isEmpty || group.contains(where: { $0.state == .unknown }) { status = .unknown }
                else { status = .review }
            }
            else if index == currentIndex { status = .current }
            else if group.contains(where: { $0.state == .blocked }) { status = .upcoming }
            else if group.isEmpty { status = later ? .upcoming : .unknown }
            else if group.allSatisfy(satisfied) { status = .done }
            else if group.contains(where: { $0.state == .waiting }) { status = .waiting }
            else if group.contains(where: { $0.state == .unknown }) { status = later ? .upcoming : .unknown }
            else { status = .review }
            let label = state.flatMap { submitted && reporting($0) == item.id ? AppStoreNames.state($0) : nil } ?? status.label
            let focus = group.first { $0.state == .blocked } ?? group.first { [.review, .manual, .waiting, .unknown].contains($0.state) } ?? group.first
            return Phase(id: item.id, number: index + 1, title: item.title, purpose: item.purpose, status: status, label: label, locked: locked(item.id), steps: group, focus: focus)
        }
        return Guide(phases: phases, next: next, appleState: state)
    }
}
