import Foundation

/// Step-by-step navigation over the release guide's phases. Moving between phases never approves or starts an Apple change;
/// every write still goes through a prepared review.
public enum ReleaseWizard {
    /// Where inside a phase to continue.
    public enum Focus: Equatable, Sendable {
        case plan, language(String), information(String), build(id: String?, action: String?), reviewInformation(String?), publish(PublishRequest)
    }
    public enum Destination: Equatable, Sendable {
        case phase(String, Focus?)
        case external(URL)
    }

    public static var phaseIds: [String] { ReleaseGuide.definitions.map(\.id) }

    /// The Apple parts a phase shows, read before it opens; the rest are read in the background. Each phase includes the app's versions,
    /// which name the target version and its state. Local material is always read again from this Mac.
    public static func reads(_ phase: String) -> ReleaseReadiness.Parts {
        switch phase {
        case "plan", "release": [.versions]
        case "listing": [.versions, .media]
        case "send": [.versions, .versionText, .appInfoText]
        case "build": [.versions, .build]
        case "review-information": [.versions, .review]
        case "submit": [.versions, .appConfiguration, .ageRating, .accessibility, .availability]
        default: .all
        }
    }

    /// Opens on the first step not yet done when it comes before the phase that needs action, else that phase, else the step where
    /// Apple reports a submitted version, else the last. Steps are worked through in order, so a later step never opens past an earlier one.
    public static func initialPhase(_ guide: ReleaseGuide.Guide) -> String {
        let open = guide.phases.first { !$0.locked && ![.done, .review, .differs].contains($0.status) }
        if let open, guide.current.map({ open.number < $0.number }) ?? !guide.submitted { return open.id }
        return guide.current?.id ?? (guide.submitted ? guide.appleState.map(ReleaseGuide.reporting) : nil) ?? open?.id ?? guide.phases.last?.id ?? "plan"
    }

    public static func neighbors(_ id: String) -> (previous: String?, next: String?) {
        let ids = phaseIds
        guard let index = ids.firstIndex(of: id) else { return (nil, nil) }
        return (index > 0 ? ids[index - 1] : nil, index + 1 < ids.count ? ids[index + 1] : nil)
    }

    /// The phase a readiness check belongs to, in the guide's own grouping.
    public static func phase(containing stepId: String) -> String? {
        ReleaseGuide.definitions.first { $0.matches(stepId) }?.id
    }

    /// Checks in a phase that must be fixed before submitting. A step Apple's version state settles needs nothing more.
    public static func missing(_ phase: ReleaseGuide.Phase) -> [ReleaseReadiness.Step] {
        phase.locked ? [] : phase.steps.filter { $0.state == .blocked }
    }

    /// The first earlier step that still needs action. Apple refuses to add a version for review while its text, screenshots,
    /// build or App Review Information are incomplete, so Add for Review waits for every step before it.
    public static func unfinished(before phase: String, in guide: ReleaseGuide.Guide) -> ReleaseGuide.Phase? {
        guard let index = guide.phases.firstIndex(where: { $0.id == phase }) else { return nil }
        return guide.phases[..<index].first { !$0.locked && ![.done, .review, .differs].contains($0.status) }
    }

    /// The wizard's Build step adds the build itself, so a missing build names that action instead of the submission review.
    /// A language's own check is named after the language and what it covers; each of its problems gets its own Fix.
    public static func presented(_ step: ReleaseReadiness.Step) -> ReleaseReadiness.Step {
        if step.id.hasPrefix("local:") {
            let locale = String(step.id.dropFirst("local:".count))
            var named = ReleaseReadiness.Step(id: step.id, label: "\(StoreLocales.name(locale)) (\(locale)) · Text and Screenshots", detail: step.detail, href: step.href,
                                              action: "Edit Language", state: step.state, territories: step.territories, guideHref: step.guideHref)
            named.issues = step.issues.map(ReleaseMaterial.presented)
            return named
        }
        // Step 3's own checks name what is only on this Mac and that saving on this step uploads it; there is nothing to open elsewhere.
        for (prefix, what) in [("apple-text:", "Version text"), ("apple-info:", "Name, subtitle and privacy policy"), ("media:", "Screenshots and app previews")] where step.id.hasPrefix(prefix) && step.state == .blocked {
            let locale = String(step.id.dropFirst(prefix.count))
            return ReleaseReadiness.Step(id: step.id, label: "\(StoreLocales.name(locale)) (\(locale)) · \(what)", detail: localOnly(step, prefix: prefix),
                                         href: step.href, action: step.action, state: step.state, territories: step.territories, guideHref: step.guideHref)
        }
        if step.id == "review-info", step.state == .blocked {
            let named = step.issues.map(\.message)
            return ReleaseReadiness.Step(id: step.id, label: step.label,
                                         detail: (named.isEmpty ? "App Store Connect does not have complete App Review Information for this version yet." : "Missing at App Store Connect: " + named.joined(separator: ", ") + ".")
                                            + " Fill it in below, choose Save, then Send to Apple in the list of changes to send it.",
                                         href: step.href, action: step.action, state: step.state, territories: step.territories, guideHref: step.guideHref)
        }
        guard step.id == "build", step.state == .blocked, step.detail.hasPrefix("No build is attached") else { return step }
        return ReleaseReadiness.Step(id: step.id, label: step.label, detail: "No build is added to this version at Apple. Add Build prepares the review that adds the chosen build. It is not submitted for review yet.",
                                     href: step.href, action: "Add Build", state: step.state, territories: step.territories, guideHref: step.guideHref)
    }

    /// What step 3 still has to upload, by name: "Only on this Mac, not in App Store Connect yet: Promotional Text, Keywords."
    /// Sizes Apple will not take come first, since saving cannot send them.
    static func localOnly(_ step: ReleaseReadiness.Step, prefix: String) -> String {
        let save = " Prepare Review below lists the changes, and Save uploads them."
        let rejected = step.issues.filter { $0.section == "rejected" }.map(\.message)
        if !rejected.isEmpty { return "Apple does not accept these sizes. " + rejected.joined(separator: " ") + " Replace the screenshots in step 2, Text and Screenshots, before saving." }
        let named = step.issues.filter { $0.section == "missing" }.map(\.message)
        if !named.isEmpty { return "Only on this Mac, not in App Store Connect yet: " + named.joined(separator: ", ") + "." + save }
        switch prefix {
        case "apple-text:": return "This language is not in the version at App Store Connect yet. Its text is only on this Mac." + save
        case "apple-info:": return "This language's name, subtitle and privacy policy are only on this Mac." + save
        default: return step.detail.hasPrefix("This language is missing") ? "This language is not in the version at App Store Connect yet, so its screenshots are only on this Mac." + save : step.detail
        }
    }

    /// A check's action stays inside the wizard: the phase comes from the check, the focus from its target.
    public static func destination(stepId: String, target: ReleaseReadinessAction.Target) -> Destination {
        if case .external(let url) = target { return .external(url) }
        let focus: Focus
        switch target {
        case .plan: focus = .plan
        case .language(let locale): focus = .language(locale)
        case .information(let anchor): focus = .information(anchor)
        case .reviewInformation(let version): focus = .reviewInformation(version)
        case .publishing(let request): focus = .publish(request)
        case .build(let id, let action): focus = .build(id: id, action: action)
        case .external: preconditionFailure("handled above")
        }
        return .phase(phase(containing: stepId) ?? fallbackPhase(focus), focus)
    }

    static func fallbackPhase(_ focus: Focus) -> String {
        switch focus {
        case .plan: "plan"
        case .language: "listing"
        case .information(let anchor): anchor == "export-compliance" ? "build" : "submit"
        case .build: "build"
        case .reviewInformation: "review-information"
        case .publish(let request):
            switch request.scope {
            case .submit, .cancelSubmission: "submit"
            case .releaseVersion: "release"
            default: "send"
            }
        }
    }

    /// The change the send phase starts with: create the version, then text and media, then copyright.
    public static func sendScope(_ phase: ReleaseGuide.Phase) -> PublishRequest.Scope {
        let open = phase.steps.filter { $0.state != .ready }
        if open.contains(where: { $0.id == "version" }) { return .release }
        if open.contains(where: { ["apple-text:", "apple-info:", "media:"].contains(where: $0.id.hasPrefix) }) { return .metadata }
        if open.contains(where: { $0.id == "copyright" }) { return .versionCopyright }
        return .metadata
    }
}
