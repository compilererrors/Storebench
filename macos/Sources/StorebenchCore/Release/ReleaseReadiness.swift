import Foundation

/// Read-only release guidance. A verified observation never approves an Apple change.
public enum ReleaseReadiness {
    public enum Failure: Error { case invalid }
    public enum State: String, Sendable, CaseIterable {
        case ready, blocked, review, waiting, manual, unknown
        public var label: String {
            switch self { case .ready: "Verified"; case .blocked: "Needs action"; case .review: "Review"; case .waiting: "Waiting for Apple"; case .manual: "Check manually"; case .unknown: "Unknown" }
        }
    }
    public struct Step: Identifiable, Sendable {
        public let id, label, detail, href, action: String
        public let state: State
        public let territories: JSONText?
        public let guideHref: String?
        /// The language's own problems, one per field, so each can be shown and fixed on its own.
        public var issues: [ReleaseMaterial.Issue] = []
        public var json: JSONText {
            var fields: [(String, JSONText)] = [("id", .string(id)), ("label", .string(label)), ("state", .string(state.rawValue)), ("detail", .string(detail)), ("href", .string(href)), ("action", .string(action))]
            if let territories { fields.append(("territories", territories)) }; if let guideHref { fields.append(("guideHref", .string(guideHref))) }
            return .object(fields)
        }
    }
    static let submitted: Set<String> = ["WAITING_FOR_REVIEW", "IN_REVIEW", "PENDING_DEVELOPER_RELEASE", "PENDING_APPLE_RELEASE", "PROCESSING_FOR_DISTRIBUTION", "READY_FOR_DISTRIBUTION", "WAITING_FOR_EXPORT_COMPLIANCE", "PROCESSING_FOR_APP_STORE", "READY_FOR_SALE"]
    static let waiting: Set<String> = ["WAITING_FOR_REVIEW", "IN_REVIEW", "PENDING_APPLE_RELEASE", "PROCESSING_FOR_DISTRIBUTION", "WAITING_FOR_EXPORT_COMPLIANCE", "PROCESSING_FOR_APP_STORE"]
    private static let editable: Set<String> = ["PREPARE_FOR_SUBMISSION", "READY_FOR_REVIEW", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED", "INVALID_BINARY"]
    @inline(never) private static func text(_ value: JSONText?) -> String { (try? LanguageDrafts.originalText(value)) ?? "" }
    private static func encoded(_ text: String) -> String {
        text.utf8.map { byte in
            if (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || [33, 39, 40, 41, 42, 45, 46, 95, 126].contains(byte) { return String(UnicodeScalar(byte)) }
            return String(format: "%%%02X", byte)
        }.joined()
    }
    public static func languageAnchor(_ locale: String) -> String { "release-locale-" + encoded(locale) }
    /// One field, or `screenshots` for the language's media, inside the language editor.
    public static func fieldAnchor(_ locale: String, _ field: String) -> String { "release-field-" + encoded(locale) + "-" + encoded(field) }
    private static func list(_ value: JSONText?) throws -> [JSONText]? {
        if value == .string("unknown") { return nil }
        guard case .array(let values)? = value, values.count <= 2000 else { throw Failure.invalid }; return values
    }
    @inline(never) private static func count(_ value: JSONText?) throws -> Int {
        guard case .number(let number)? = value, let result = Int(exactly: number), (0...100_000).contains(result) else { throw Failure.invalid }; return result
    }
    @inline(never) private static func locales(_ values: [JSONText]?) throws -> [Data: (fields: JSONText, duplicate: Bool)] {
        var result: [Data: (fields: JSONText, duplicate: Bool)] = [:]
        for value in values ?? [] {
            guard let locale = value["locale"]?.text, !locale.isEmpty, locale.utf16.count <= 256, case .object? = value["fields"] else { throw Failure.invalid }
            let key = Data(locale.utf8); result[key] = (value["fields"]!, result[key] != nil)
        }; return result
    }
    /// Several app-info records are comparable only when every locale and all five text fields agree.
    public static func consistentAppInfoLocales(_ records: [[JSONText]]) throws -> [JSONText]? {
        guard records.count <= 2000 else { throw Failure.invalid }; guard let first = records.first else { return [] }
        let baseline = try locales(first); guard baseline.count == first.count, !baseline.values.contains(where: { $0.duplicate }) else { return nil }
        for values in records.dropFirst() {
            let other = try locales(values)
            guard values.count == first.count, other.count == values.count, !other.values.contains(where: { $0.duplicate }) else { return nil }
            for (locale, entry) in other {
                guard let starting = baseline[locale], TextDrafts.appInfoFields.allSatisfy({ TextSemantics.same(text(starting.fields[$0]), text(entry.fields[$0])) }) else { return nil }
            }
        }; return first
    }
    /// Observations come from scoped readers; duplicate remote locales remain explicitly unknown.
    public static func steps(_ input: JSONText, scope: RecoveryGuidance.Scope) throws -> [Step] {
        guard input["root"]?.text == scope.root, case .array(let local)? = input["local"], local.count <= 2000 else { throw Failure.invalid }
        let root = scope.root, target = input["target"] == .null ? nil : input["target"]
        if let target { guard let platform = target["platform"]?.text, let number = target["number"]?.text, !platform.isEmpty, !number.isEmpty, platform.utf16.count <= 100, number.utf16.count <= 100 else { throw Failure.invalid } }
        let versions = try list(input["appleVersions"]), appleLocales = try list(input["appleLocales"]), appInfoLocales = try list(input["appleAppInfoLocales"])
        let configuration = text(input["appConfiguration"]), age = text(input["ageRating"]), review = text(input["reviewInformation"]), build = text(input["attachedBuild"])
        guard ["unknown", "missing", "present"].contains(configuration), ["unknown", "missing", "incomplete", "present"].contains(age),
              ["unknown", "missing", "ready"].contains(review), ["unknown", "missing", "ineligible", "eligible"].contains(build) else { throw Failure.invalid }
        let accessibility = input["accessibility"] ?? .string("unknown"), availability = input["currentAvailability"] ?? .string("unknown")
        let encryption = input["exportCompliance"] ?? .object([("kind", .string("unknown"))])
        let version = target.flatMap { target in versions?.first { TextSemantics.same(text($0["platform"]), text(target["platform"])) && TextSemantics.same(text($0["number"]), text(target["number"])) } }
        let targetName = target.map { "\(Releases.platformName(text($0["platform"]))) \(text($0["number"]))" } ?? ""
        var steps: [Step] = []
        func add(_ id: String, _ label: String, _ state: State, _ detail: String, _ href: String, _ action: String, territories: JSONText? = nil, guide: String? = nil, issues: [ReleaseMaterial.Issue] = []) {
            steps.append(Step(id: id, label: label, detail: detail, href: href, action: action, state: state, territories: territories, guideHref: guide, issues: issues))
        }
        add("plan", "Version plan", target == nil ? .blocked : .ready, target == nil ? "Choose a version number and save a local plan." : "Version draft: \(targetName). This does not create a version in App Store Connect.", root + "/release#release-version", target == nil ? "Create plan" : "Edit plan")
        add("version", "Version at Apple", target == nil || versions == nil ? .unknown : version == nil ? .blocked : .ready,
            target == nil ? "Save a local target before checking its Apple version." : versions == nil ? "Apple version status could not be read. Refresh before drawing a conclusion." : version == nil ? "The target version is not at Apple yet." : "\(targetName) · \(AppStoreNames.primaryState(text(version?["state"]))).",
            root + "/publish?scope=release&draft=1", "Review version setup")
        add("app-configuration", "App categories and content rights", configuration == "unknown" ? .unknown : configuration == "missing" ? .blocked : .review,
            configuration == "unknown" ? "Apple's category or content rights could not be verified. Check them before submission." : configuration == "missing" ? "A primary category or content rights declaration is missing at Apple." : "Apple has a primary category and content rights declaration. Confirm they match this app before submission.", root + "/publish?scope=app-information", "Review app information")
        add("age-rating", "Age rating declaration", age == "unknown" ? .unknown : ["missing", "incomplete"].contains(age) ? .blocked : .review,
            age == "unknown" ? "Apple's age rating declaration could not be verified. Check its answers before submission." : age == "missing" ? "No age rating declaration was returned for this app. Complete the questionnaire before submission." : age == "incomplete" ? "Some Age Ratings questions are not answered yet. Apple adds a version for review only when every question has an answer." : "Apple has an age rating declaration. Compare every answer with the app; Apple calculates the displayed rating.", root + "/publish?scope=age-rating", "Review age rating")
        var accessibilityDetail = "Apple's accessibility declarations could not be read. Check each supported device family before submission."
        if accessibility != .string("unknown") {
            let drafts = try count(accessibility["drafts"]), published = try count(accessibility["published"])
            accessibilityDetail = drafts > 0 ? "\(drafts) device family draft\(drafts == 1 ? "" : "s") need\(drafts == 1 ? "s" : "") review before publication. \(published) published declaration\(published == 1 ? "" : "s") remain at Apple." : published > 0 ? "\(published) device family declaration\(published == 1 ? "" : "s") published at Apple. Check that each answer matches the shipped app." : "No accessibility declaration is published. Review the features of every supported device family and create a declaration where appropriate."
        }
        add("accessibility", "Accessibility declarations", accessibility == .string("unknown") ? .unknown : .review, accessibilityDetail, root + "/publish?scope=accessibility", "Review accessibility")
        let remote = try locales(appleLocales), remoteInfo = try locales(appInfoLocales)
        var seen = Set<Data>()
        for item in local {
            guard let material = item["material"], let code = material["locale"]?.text, !code.isEmpty, code.utf16.count <= 256,
                  seen.insert(Data(code.utf8)).inserted, case .array(let issues)? = material["issues"], issues.count <= 2000, case .object? = item["fields"] else { throw Failure.invalid }
            let changed = try count(material["changedFields"]), screenshots = try count(material["screenshots"]), languageHref = root + "/release#" + languageAnchor(code)
            let problems = issues.map { ReleaseMaterial.Issue(field: text($0["field"]), message: text($0["message"]), section: text($0["section"])) }
            add("local:" + code, code + " · local material", problems.contains(where: { ["text", "screenshots"].contains($0.section) }) ? .blocked : .review,
                problems.isEmpty ? "\(changed) changed text fields and \(screenshots) selected screenshots. These local checks do not prove Apple's submission requirements." : "\(problems.count) local check\(problems.count == 1 ? "" : "s") need attention: " + problems.map(\.message).joined(separator: "; "),
                languageHref, "Edit language", issues: problems)
            if target != nil {
                let media = item["mediaStatus"], state = media?["state"]?.text.flatMap(State.init(rawValue:)) ?? .unknown
                // What Apple lacks travels as issues, which the step's JSON leaves out: "rejected" sizes Apple will not take, "missing" media not sent yet.
                let named = WorkspaceSession.strings(media?["rejected"]).map { ReleaseMaterial.Issue(field: "screenshots", message: $0, section: "rejected") }
                    + WorkspaceSession.strings(media?["missing"]).map { ReleaseMaterial.Issue(field: "screenshots", message: $0, section: "missing") }
                add("media:" + code, code + " · screenshots and previews at Apple", state, media?["detail"]?.text.flatMap { $0.isEmpty ? nil : $0 } ?? "Apple media sets have not been verified for this language.", languageHref, "Inspect media", issues: state == .blocked ? named : [])
            }
            if let source = item["sourceReview"] {
                let stale = try count(source["stale"]), unavailable = try count(source["unavailable"])
                if stale > 0 || unavailable > 0 {
                    add("editorial:" + code, code + " · copied wording", unavailable > 0 ? .unknown : .review,
                        unavailable > 0 ? "\(unavailable) copied source field\(unavailable == 1 ? " is" : "s are") unavailable. The saved destination stays intact; check its starting material in the language editor." : "\(stale) copied field\(stale == 1 ? " has" : "s have") changed source text. Compare and confirm each saved destination field before using this wording.", languageHref, "Review saved wording")
                }
            }
            let value = remote[Data(code.utf8)], info = remoteInfo[Data(code.utf8)], fields = item["fields"], appFields = item["appInfoFields"] == .null ? nil : item["appInfoFields"]
            let textMatches = value.map { entry in !entry.duplicate && TextDrafts.versionFields.allSatisfy { key in TextSemantics.sameStoreText(text(entry.fields[key]), text(fields?[key])) } } == true
            func differing(_ keys: [String], _ apple: JSONText?, _ saved: JSONText?) -> [ReleaseMaterial.Issue] {
                keys.filter { !TextSemantics.sameStoreText(text(apple?[$0]), text(saved?[$0])) }.map { ReleaseMaterial.Issue(field: $0, message: TextDrafts.labels[$0] ?? $0, section: "missing") }
            }
            add("apple-text:" + code, code + " · version text at Apple", version == nil || appleLocales == nil || value?.duplicate == true ? .unknown : textMatches ? .ready : .blocked,
                version == nil ? "Create the target version before comparing its languages." : appleLocales == nil || value?.duplicate == true ? "The version's Apple languages could not be verified." : textMatches ? "The saved version text matches Apple's current values for this language." : "This language is missing at Apple or its version text differs from the local material.", root + "/publish?scope=metadata&draft=1", "Review text upload",
                issues: version == nil || textMatches ? [] : value.map { differing(TextDrafts.versionFields, $0.fields, fields) } ?? [])
            let infoMatches = appFields != nil && info.map { entry in !entry.duplicate && TextDrafts.appInfoFields.allSatisfy { key in TextSemantics.sameStoreText(text(entry.fields[key]), text(appFields?[key])) } } == true
            add("apple-info:" + code, code + " · app information at Apple", version == nil || appInfoLocales == nil || info?.duplicate == true ? .unknown : infoMatches ? .ready : .blocked,
                version == nil ? "Create the target version before comparing its app information." : appInfoLocales == nil || info?.duplicate == true ? "Apple's app information records disagree or could not be verified. Compare them in the Publish review." : appFields == nil ? "Saved app information for this language is missing or duplicated." : info == nil ? "This language's app information is missing at Apple." : infoMatches ? "Saved app name, subtitle and privacy information match Apple's current app information records. This does not prove the live store display." : "Saved app name, subtitle or privacy information differs from Apple's current values.", root + "/publish?scope=metadata&draft=1", "Review app information",
                issues: version == nil || infoMatches || appFields == nil ? [] : info.map { differing(TextDrafts.appInfoFields, $0.fields, appFields) } ?? [])
        }
        let copyright = TextSemantics.trim(text(version?["copyright"]))
        add("copyright", "Version copyright", version == nil ? .unknown : copyright.isEmpty ? .blocked : .ready, version == nil ? "Check after the Apple version exists." : copyright.isEmpty ? "Version copyright is missing at Apple." : "Apple has saved version copyright.", root + "/publish?scope=version-copyright", "Review copyright")
        add("review-info", "App Review Information", version == nil || review == "unknown" ? .unknown : review == "ready" ? .ready : .blocked,
            version == nil ? "Check after the Apple version exists." : review == "unknown" ? "App Review details or attachment processing could not be verified." : review == "ready" ? "Required App Review Information and any attachment processing are complete at Apple." : "Required App Review Information is missing or incomplete at Apple.", root + "/publish?scope=review-info", "Review information",
            issues: version == nil || review != "missing" ? [] : WorkspaceSession.strings(input["reviewMissing"]).map { ReleaseMaterial.Issue(field: "review", message: $0, section: "missing") })
        add("build", "App Store build", version == nil || build == "unknown" ? .unknown : build == "eligible" ? .ready : .blocked,
            version == nil ? "Check after the Apple version exists." : build == "unknown" ? "The attached build could not be verified." : build == "eligible" ? "A processed, App Store eligible build is attached to this version." : build == "missing" ? "No build is attached to this Apple version. Choose an eligible build in the submission review." : "The attached build is not eligible for this platform and version.", root + "/publish?scope=submit", "Choose build")
        let candidate = text(encryption["buildId"]), buildId = candidate.range(of: #"\A[A-Za-z0-9_-]{1,256}\z"#, options: .regularExpression) != nil ? candidate : ""
        let buildHref = root + "/testflight" + (buildId.isEmpty ? "" : "?build=" + buildId + "#selected-build")
        func encryptionAction(_ action: String) -> String { buildId.isEmpty ? buildHref : root + "/publish?scope=testflight&testflightAction=" + action + "&buildId=" + buildId }
        let encryptionStep: (State, String, String, String)
        switch text(encryption["kind"]) {
        case "unknown": encryptionStep = (.unknown, "Apple's build encryption answer or linked declaration could not be verified. Check the selected build.", buildHref, "Check build")
        case "no-build": encryptionStep = (.unknown, "Attach an eligible build before checking its export declaration.", root + "/publish?scope=submit", "Choose build")
        case "unanswered": encryptionStep = (.blocked, "Apple reports no answer to whether this build uses non-exempt encryption. Answer it for the shipped binary.", encryptionAction("set-encryption-use"), "Answer encryption")
        case "no-nonexempt": encryptionStep = (.ready, "Apple records No for non-exempt encryption on this build. Confirm that answer matches the shipped binary.", buildHref, "Inspect build")
        case "unassigned": encryptionStep = (.blocked, "Apple records non-exempt encryption but no declaration is linked to this build. Assign an approved declaration.", encryptionAction("assign-encryption-declaration"), "Assign declaration")
        case "reviewing": encryptionStep = (.waiting, "The linked declaration is awaiting Apple's export compliance decision. Check whether a supporting document is requested.", root + "/publish?scope=export-document", "Check document")
        case "approved": encryptionStep = (.ready, "Apple reports an approved declaration linked to this build and platform. Confirm its answers match the shipped binary.", buildHref, "Inspect build")
        case "invalid": encryptionStep = (.blocked, "The linked declaration is not valid for this build and platform. Review its status and create a replacement if needed.", root + "/publish?scope=export-compliance", "Review declaration")
        default: throw Failure.invalid
        }
        add("export-compliance", "Build export compliance", version == nil ? .unknown : encryptionStep.0, version == nil ? "Create the target Apple version and attach its build before checking export compliance." : encryptionStep.1, encryptionStep.2, encryptionStep.3)
        let state = text(version?["state"]), currentState = state.replacingOccurrences(of: "_", with: " ").lowercased()
        add("submission", "App Review submission", version == nil || state.isEmpty ? .unknown : submitted.contains(state) ? .ready : editable.contains(state) ? .review : .unknown,
            version == nil ? "No target Apple version is available for submission." : submitted.contains(state) ? "The version has entered Apple's review or later release flow." : editable.contains(state) ? "Submission requires a separate, exact Publish review and Apple validation." : "Apple reports \(currentState); check its current review state.", root + "/publish?scope=submit", "Review submission")
        let distributed = ["READY_FOR_DISTRIBUTION", "READY_FOR_SALE"].contains(state), pending = state == "PENDING_DEVELOPER_RELEASE", method = text(version?["releaseType"])
        let manual = pending && method == "MANUAL", scheduled = pending && method == "SCHEDULED"
        add("release", "App Store distribution", version == nil || state.isEmpty ? .unknown : distributed ? .ready : manual ? .review : scheduled ? .waiting : pending ? .unknown : waiting.contains(state) ? .waiting : editable.contains(state) ? .blocked : .unknown,
            version == nil ? "A local plan is not an App Store distribution." : distributed ? "Apple reports this version ready for distribution. Agreements and country availability still need a separate check." : manual ? "Apple approved the version; manual release requires its own Publish review." : scheduled ? "Apple approved the version and reports a scheduled release. Check the date at Apple." : pending ? "Apple approved the version, but its release method could not be confirmed." : waiting.contains(state) ? "Apple is processing or reviewing this version. Distribution is not confirmed." : editable.contains(state) ? "Submit and obtain Apple's approval before release." : state == "ACCEPTED" ? "Apple accepted the version, but other submission items may still need resolution." : "Apple reports \(currentState); distribution is not confirmed here.", root + "/publish?scope=release-version", "Review release")
        var selected = 0, total = 0
        if availability != .string("unknown") {
            guard case .array(let yes)? = availability["selected"], case .array(let no)? = availability["unselected"], yes.count + no.count <= 300,
                  (yes + no).allSatisfy({ $0.text?.range(of: #"\A[A-Z]{3}\z"#, options: .regularExpression) != nil }), Set((yes + no).compactMap(\.text)).count == yes.count + no.count else { throw Failure.invalid }
            selected = yes.count; total = yes.count + no.count
        }
        add("territories", "Current country and region selection", availability == .string("unknown") ? .unknown : selected > 0 ? .ready : .blocked,
            availability == .string("unknown") ? "Apple's current territory settings could not be verified. Refresh before preparing a region change." : selected > 0 ? "Apple marks \(selected) of \(total) returned countries or regions as selected. This verifies the selection, not public availability or regional restrictions." : "Apple marks none of the \(total) returned countries or regions as selected. Review your intended regions before changing them at Apple.", root + "/publish?scope=availability", "Review region selection", territories: availability == .string("unknown") ? nil : availability)
        add("privacy", "App Privacy answers", .manual, "Answer the data collection questions, including third-party code, in App Store changes under App Privacy. It signs in with the Apple ID of an Account Holder or Admin, because the API key cannot answer App Privacy.", "https://appstoreconnect.apple.com/", "Answer App Privacy", guide: "https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/")
        add("tax", "App tax category", .manual, "Check the tax category in App Store changes under Tax Category. It signs in with the Apple ID of an Account Holder or Admin, because the API key cannot read or set it.", "https://appstoreconnect.apple.com/", "Choose Tax Category", guide: "https://developer.apple.com/help/app-store-connect/manage-app-information/set-a-tax-category/")
        return steps
    }
}

extension ReleaseReadiness {
    /// The Apple observations a status read can fetch on its own. Each release step reads only the parts it shows; the rest are filled in the background.
    public struct Parts: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        /// The app's versions: the target's id, App Store Connect state, release type and copyright.
        public static let versions = Parts(rawValue: 1 << 0)
        /// Screenshots and previews at Apple for each planned language.
        public static let media = Parts(rawValue: 1 << 1)
        public static let versionText = Parts(rawValue: 1 << 2)
        public static let appInfoText = Parts(rawValue: 1 << 3)
        /// The attached build and its export compliance.
        public static let build = Parts(rawValue: 1 << 4)
        public static let review = Parts(rawValue: 1 << 5)
        /// Primary category and content rights.
        public static let appConfiguration = Parts(rawValue: 1 << 6)
        public static let ageRating = Parts(rawValue: 1 << 7)
        public static let accessibility = Parts(rawValue: 1 << 8)
        public static let availability = Parts(rawValue: 1 << 9)
        public static let all: Parts = [.versions, .media, .versionText, .appInfoText, .build, .review, .appConfiguration, .ageRating, .accessibility, .availability]
        /// Parts that belong to the target version; reading one reads the app's versions to find it.
        static let versionScoped: Parts = [.versions, .media, .versionText, .build, .review]
        /// Parts read from the app's app information records.
        static let appInfoScoped: Parts = [.appInfoText, .appConfiguration, .ageRating]
        /// Each part's input keys and the value that stands for an unread or unreadable observation. Media statuses are kept per language.
        static let keys: [(part: Parts, key: String, unknown: JSONText)] = [
            (.versions, "appleVersions", .string("unknown")), (.media, "mediaStatus", .object([])), (.versionText, "appleLocales", .string("unknown")),
            (.appInfoText, "appleAppInfoLocales", .string("unknown")), (.build, "attachedBuild", .string("unknown")), (.build, "exportCompliance", .object([("kind", .string("unknown"))])),
            (.review, "reviewInformation", .string("unknown")), (.review, "reviewMissing", .array([])), (.appConfiguration, "appConfiguration", .string("unknown")), (.ageRating, "ageRating", .string("unknown")),
            (.accessibility, "accessibility", .string("unknown")), (.availability, "currentAvailability", .string("unknown")),
        ]
        /// Background reads, cheapest first. Parts that share Apple requests are read together.
        static let fillOrder: [Parts] = [[.versions], [.accessibility], [.versionText], [.availability], [.review], [.appConfiguration, .ageRating], [.appInfoText], [.build], [.media]]
        /// The remaining parts in small batches, those the open step shows first, then cheapest first.
        public static func batches(_ remaining: Parts, first: Parts = []) -> [Parts] {
            let batches = fillOrder.map { $0.intersection(remaining) }.filter { !$0.isEmpty }
            return batches.filter { !$0.isDisjoint(with: first) } + batches.filter { $0.isDisjoint(with: first) }
        }
    }
    /// The status input with Apple observations applied over saved local material. Media statuses are set on their languages.
    static func input(local: JSONText, observations: JSONText) -> JSONText {
        var input = local
        for (_, key, _) in Parts.keys {
            guard let value = observations[key] else { continue }
            if key != "mediaStatus" { input = input.setting(key, value); continue }
            guard case .array(let languages)? = local["local"] else { continue }
            input = input.setting("local", .array(languages.map { item in
                guard let code = item["material"]?["locale"]?.text, let status = value[code] else { return item }
                return item.setting("mediaStatus", status)
            }))
        }
        return input
    }
}
