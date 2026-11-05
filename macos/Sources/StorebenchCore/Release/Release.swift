import Foundation

public enum ReleaseFailure: Error, Equatable {
    case conflict(String), invalid(String), sourceUnavailable

    public var message: String {
        switch self {
        case .conflict(let text), .invalid(let text): text
        case .sourceUnavailable: "Choose an available starting version or start with an empty draft."
        }
    }
}

/// The local plan for the next App Store version of one app, stored in the `release_plans` document.
public struct ReleasePlan: Equatable, Sendable {
    public let accountId, appId, sourceRevisionId, baseVersionId, platform, targetVersion, updatedAt: String
    public let releaseType: String?
    public let earliestReleaseDate: String?
    /// The stored JSON, used as the editor's token.
    public let token: String

    public init?(_ value: JSONText) {
        guard let account = value["accountId"]?.text, let app = value["appId"]?.text, let source = value["sourceRevisionId"]?.text, let base = value["baseVersionId"]?.text,
              let platform = value["platform"]?.text, let target = value["targetVersion"]?.text, let updated = value["updatedAt"]?.text else { return nil }
        accountId = account; appId = app; sourceRevisionId = source; baseVersionId = base; self.platform = platform; targetVersion = target; updatedAt = updated
        releaseType = value["releaseType"]?.text; earliestReleaseDate = value["earliestReleaseDate"]?.text; token = value.stringify()
    }

    public var label: String { "\(Releases.platformName(platform)) \(targetVersion)" }
    public var settings: String {
        let type = releaseType ?? "MANUAL"
        return (Releases.releaseTypes.first { $0.0 == type }?.1 ?? type) + (earliestReleaseDate.map { " · \($0) (UTC)" } ?? "")
    }
}

public enum Releases {
    public static let releaseTypes = [("MANUAL", "Manually release this version"), ("AFTER_APPROVAL", "Automatically release this version"),
                                      ("SCHEDULED", "Automatically release this version after App Review, no earlier than a chosen date")]
    public static let platforms = [("IOS", "iOS"), ("MAC_OS", "macOS"), ("TV_OS", "tvOS"), ("VISION_OS", "visionOS")]
    public static func platformName(_ code: String) -> String { platforms.first { $0.0 == code }?.1 ?? code }
    /// Apple states reached once a version has been submitted to App Review.
    static let submitted: Set<String> = ["WAITING_FOR_REVIEW", "IN_REVIEW", "PENDING_DEVELOPER_RELEASE", "PENDING_APPLE_RELEASE", "PROCESSING_FOR_APP_STORE", "PROCESSING_FOR_DISTRIBUTION",
                                         "READY_FOR_SALE", "READY_FOR_DISTRIBUTION", "ACCEPTED", "REPLACED_WITH_NEW_VERSION"]

    /// True when version number `a` comes before `b`, comparing each number part as a number (1.9 before 1.10).
    public static func earlier(_ a: String, _ b: String) -> Bool { a.compare(b, options: .numeric) == .orderedAscending }

    public static func validateVersion(_ value: String) throws {
        guard value.utf16.count <= 32, value.range(of: #"^[0-9]+(?:\.[0-9]+){0,2}\z"#, options: .regularExpression) != nil else { throw ReleaseFailure.invalid("Use a version number such as 1.0, 2.0 or 2.0.1.") }
    }

    static var iso: ISO8601DateFormatter { let format = ISO8601DateFormatter(); format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return format }

    static func parsedDate(_ text: String) -> Date? {
        guard text.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,3})?Z\z"#, options: .regularExpression) != nil else { return nil }
        let formatter = iso
        if !text.contains(".") { formatter.formatOptions = [.withInternetDateTime] }
        guard let value = formatter.date(from: text), value.timeIntervalSince1970.isFinite,
              iso.string(from: value).prefix(19) == text.prefix(19) else { return nil }
        return value
    }

    /// Release settings: a scheduled release needs a future UTC date and time; the others take none.
    static func settings(type: String, date: Date?, now: Date) throws -> [(String, JSONText)] {
        guard releaseTypes.contains(where: { $0.0 == type }) else { throw ReleaseFailure.invalid("Choose a valid release method.") }
        guard type == "SCHEDULED" else {
            guard date == nil else { throw ReleaseFailure.invalid("A release date is only used for scheduled releases.") }
            return [("releaseType", .string(type))]
        }
        guard let date, date.timeIntervalSince1970.isFinite, now.timeIntervalSince1970.isFinite,
              date.timeIntervalSince1970 >= -62_167_219_200, date.timeIntervalSince1970 < 253_402_300_800 else { throw ReleaseFailure.invalid("Choose a valid release date and time.") }
        guard date > now else { throw ReleaseFailure.invalid("Choose a release date and time in the future.") }
        let whole = Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded(.down) / 1000)
        return [("releaseType", .string(type)), ("earliestReleaseDate", .string(iso.string(from: whole)))]
    }
}

public enum ReleaseStart: Sendable, Equatable { case reuse, copy, empty(platform: String, locale: String) }

public enum NewVersionAvailability: Equatable, Sendable { case available(submittedDraft: String?), unavailable(draft: String) }

extension WorkspaceSession {
    func plansDocument(_ store: EncryptedDocumentStore) throws -> (document: EncryptedDocumentStore.Document?, plans: [JSONText]) {
        let document = try store.document(namespace: "release_plans", key: "all")
        guard let document else { return (nil, []) }
        let value = try JSONText.parse(document.payload)
        guard value["schemaVersion"] == .number(1), case .array(let plans)? = value["plans"] else { throw ReleaseFailure.invalid("Invalid release plans.") }
        return (document, plans)
    }

    public func releasePlan(accountId: String, appId: String) throws -> ReleasePlan? {
        try storeAccess { store in
            let matches = try plansDocument(store).plans.filter { $0["accountId"]?.text == accountId && $0["appId"]?.text == appId }
            guard !matches.isEmpty else { return nil }
            guard matches.count == 1, let plan = ReleasePlan(matches[0]), !plan.sourceRevisionId.isEmpty, !plan.baseVersionId.isEmpty,
                  Releases.platforms.contains(where: { $0.0 == plan.platform }) else { throw ReleaseFailure.invalid("The saved version plan is invalid.") }
            try Releases.validateVersion(plan.targetVersion)
            let date = try plan.earliestReleaseDate.map { text in
                guard let date = Releases.parsedDate(text) else { throw ReleaseFailure.invalid("The saved release date is invalid.") }
                return date
            }
            _ = try Releases.settings(type: plan.releaseType ?? "MANUAL", date: date, now: date?.addingTimeInterval(-1) ?? Date())
            return plan
        }
    }

    /// One local draft at a time: New version is available once the draft's version has been submitted, per the latest Apple import.
    public func newVersionAvailability(accountId: String, appId: String) -> NewVersionAvailability {
        guard let plan = try? releasePlan(accountId: accountId, appId: appId) else { return .available(submittedDraft: nil) }
        let latest = (try? revisions(accountId: accountId, appId: appId))?.first { !$0.isLocalDraft }
        let submitted = latest?.versions.contains { $0.platform == plan.platform && $0.number == plan.targetVersion
            && Releases.submitted.contains($0.fields["appVersionState"]?.text ?? $0.fields["appStoreState"]?.text ?? "") } ?? false
        return submitted ? .available(submittedDraft: plan.label) : .unavailable(draft: plan.label)
    }

    /// Changes the plans under the `release_plans` mutex; `expected` is the editor's token for this app's plan.
    func mutatePlans<T>(accountId: String, appId: String, expected: String?, _ change: (_ existing: JSONText?, _ store: EncryptedDocumentStore) throws -> (JSONText?, T)) throws -> T {
        try storeAccess { store in
            try FileMutex.withLock(store.directory.appendingPathComponent("release_plans.mutex")) {
                let (document, plans) = try plansDocument(store)
                let existing = plans.first { $0["accountId"]?.text == accountId && $0["appId"]?.text == appId }
                if let expected, expected != (existing?.stringify() ?? "null") { throw ReleaseFailure.conflict("The release plan changed in another window. Reload before saving; your entries are still here.") }
                let (next, result) = try change(existing, store)
                let others = plans.filter { !($0["accountId"]?.text == accountId && $0["appId"]?.text == appId) }
                let value = JSONText.object([("schemaVersion", .number(1)), ("plans", .array(others + (next.map { [$0] } ?? [])))])
                try store.transaction { current in
                    guard try current("release_plans", "all")?.revision == document?.revision else { throw ReleaseFailure.conflict("The release plan changed in another window. Reload before saving; your entries are still here.") }
                    return [.put(namespace: "release_plans", key: "all", json: value.data)]
                }
                return result
            }
        }
    }

    /// Saves the release plan, creating its local version first when it starts empty or as a copy.
    /// Nothing is sent to App Store Connect.
    public func saveReleasePlan(account: Account, appId: String, start: ReleaseStart, sourceRevisionId: String?, baseVersionId: String?, targetVersion rawTarget: String,
                                releaseType: String, earliestReleaseDate: Date?, expected: String?, now: Date = Date()) throws -> ReleasePlan {
        guard account.appIds.contains(appId) else { throw ReleaseFailure.invalid("App not found.") }
        let target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        try Releases.validateVersion(target)
        var created: String?
        do {
            return try mutatePlans(accountId: account.id, appId: appId, expected: expected) { existing, store in
                let existingPlan = existing.flatMap(ReleasePlan.init)
                let settings = try Releases.settings(type: releaseType, date: earliestReleaseDate, now: now)
                let history = try revisions(accountId: account.id, appId: appId)
                var sourceId = sourceRevisionId, versionId = baseVersionId, platform: String?
                if let source = history.first(where: { $0.id == sourceRevisionId }), let version = source.versions.first(where: { $0.id == baseVersionId }) { platform = version.platform }
                if case .empty(let emptyPlatform, let locale) = start {
                    guard existing == nil else { throw ReleaseFailure.conflict("A release plan already exists. Continue that plan or remove it before starting another version.") }
                    let id = UUID().uuidString.lowercased()
                    let revision = try Self.emptyVersion(id: id, account: account, appId: appId, appName: account.appNames?[appId] ?? history.first?.app.name ?? "App \(appId)",
                                                          platform: emptyPlatform, locale: locale, target: target, createdAt: CustomerReview.isoString(now))
                    sourceId = id; versionId = "local-version-\(id)"; platform = emptyPlatform
                    if history.contains(where: { !$0.isLocalDraft && $0.versions.contains { $0.platform == emptyPlatform && $0.number == target } }) { throw ReleaseFailure.invalid("That version number already exists in an import. Enter a new version number.") }
                    try store.transaction { current in
                        guard try current("revisions", "\(account.id):\(appId):\(id)") == nil else { throw ReleaseFailure.invalid("The new release already exists.") }
                        return [.put(namespace: "revisions", key: "\(account.id):\(appId):\(id)", json: revision.data)]
                    }
                    created = id
                }
                guard let sourceId, let versionId, let platform else { throw ReleaseFailure.sourceUnavailable }
                // Continuing a version keeps its own number: that version is the one in the imports, not another one.
                if case .empty = start {} else if target != existingPlan?.targetVersion,
                    history.contains(where: { !$0.isLocalDraft && $0.versions.contains { $0.platform == platform && $0.number == target && !(start == .reuse && $0.id == versionId) } }) {
                    throw ReleaseFailure.invalid("That version number already exists in an import. Enter a new version number.")
                }
                if let existingPlan, existingPlan.sourceRevisionId != sourceId || existingPlan.baseVersionId != versionId {
                    throw ReleaseFailure.conflict("The plan uses another starting version. Continue it or remove the plan first.")
                }
                var finalSource = sourceId, finalVersion = versionId
                if start == .copy {
                    guard existing == nil else { throw ReleaseFailure.conflict("A release plan already exists. Continue it or remove the plan before creating a copy.") }
                    let copy = UUID().uuidString.lowercased()
                    created = copy
                    try copyRelease(store: store, accountId: account.id, appId: appId, sourceId: sourceId, versionId: versionId, target: target, copyId: copy, now: now)
                    finalSource = copy; finalVersion = "local-version-\(copy)"
                }
                var plan = JSONText.object([("accountId", .string(account.id)), ("appId", .string(appId)), ("sourceRevisionId", .string(finalSource)), ("baseVersionId", .string(finalVersion)),
                                            ("platform", .string(platform)), ("targetVersion", .string(target))] + settings + [("updatedAt", .string(CustomerReview.isoString(now)))])
                if let existing, let existingPlan, existingPlan.targetVersion == target, existingPlan.platform == platform, (existingPlan.releaseType ?? "MANUAL") == settings[0].1.text,
                   existingPlan.earliestReleaseDate == settings.dropFirst().first?.1.text { plan = existing }
                // Persist even a completely empty draft before the plan points to it; existing drafts are kept as they are.
                let key = "\(account.id):\(appId):\(finalSource)"
                if try store.document(namespace: "drafts", key: key) == nil {
                    try store.transaction { current in
                        guard try current("revisions", key) != nil else { throw DraftFailure.sourceMissing }
                        // Continuing a version Apple created starts with every field it left empty filled from the version before, so saving never blanks one.
                        let initial = start == .reuse ? Self.carriedText(history, revisionId: finalSource, versionId: finalVersion) : TextDrafts.empty(finalSource)
                        return try current("drafts", key) == nil ? [.put(namespace: "drafts", key: key, json: initial.data)] : []
                    }
                }
                return (plan, ReleasePlan(plan)!)
            }
        } catch {
            // A local version saved before a later step failed is removed again.
            if let created { _ = try? storeAccess { store in try store.transaction { _ in [.delete(namespace: "drafts", key: "\(account.id):\(appId):\(created)"), .delete(namespace: "revisions", key: "\(account.id):\(appId):\(created)")] } } }
            throw error
        }
    }

    /// A first draft for a continued version: each language's empty listing field takes the value the previous version of the same platform had
    /// in that language. What's New belongs to each version and stays as it is.
    static func carriedText(_ history: [Revision], revisionId: String, versionId: String) -> JSONText {
        let draft = TextDrafts.empty(revisionId)
        guard let revision = history.first(where: { $0.id == revisionId }), let version = revision.versions.first(where: { $0.id == versionId }),
              let previous = revision.versions.filter({ $0.platform == version.platform && Releases.earlier($0.number, version.number) }).max(by: { Releases.earlier($0.number, $1.number) })
        else { return draft }
        var texts: [(String, JSONText)] = []
        for localization in version.localizations {
            guard let earlier = previous.localizations.first(where: { $0.locale == localization.locale }) else { continue }
            let carried = TextDrafts.versionFields.filter { $0 != "whatsNew" }.compactMap { field -> (String, JSONText)? in
                let now = localization.fields[field]?.text ?? "", before = earlier.fields[field]?.text ?? ""
                return TextSemantics.trim(now).isEmpty && !TextSemantics.trim(before).isEmpty ? (field, .string(before)) : nil
            }
            if !carried.isEmpty { texts.append((localization.id, .object(carried))) }
        }
        return draft.setting("texts", .object(texts))
    }

    /// Removes the plan only. Its local version and drafts stay saved.
    public func removeReleasePlan(accountId: String, appId: String, expected: String) throws {
        try mutatePlans(accountId: accountId, appId: appId, expected: expected) { existing, _ in
            guard existing != nil else { throw ReleaseFailure.conflict("The release plan changed in another window. Reload before saving; your entries are still here.") }
            return (nil, ())
        }
    }

    static func emptyVersion(id: String, account: Account, appId: String, appName: String, platform: String, locale: String, target: String, createdAt: String) throws -> JSONText {
        try Releases.validateVersion(target)
        guard Releases.platforms.contains(where: { $0.0 == platform }) else { throw ReleaseFailure.invalid("Choose a supported platform.") }
        guard StoreLocales.codes.contains(locale) else { throw ReleaseFailure.invalid("Choose an App Store language.") }
        return .object([
            ("schemaVersion", .number(1)), ("origin", .string("local")), ("id", .string(id)), ("importedAt", .string(createdAt)),
            ("account", .object([("id", .string(account.id)), ("name", .string(account.name))])),
            ("app", .object([("id", .string(appId)), ("name", .string(appName)), ("primaryLocale", .string(locale)), ("bundleId", .string("")), ("sku", .string(""))])),
            ("appInfos", .array([.object([("id", .string("local-app-info")), ("fields", .object([])), ("localizations", .array([.object([("id", .string("local-app-info-\(locale)")), ("fields", .object([("locale", .string(locale))]))])]))])])),
            ("versions", .array([.object([("id", .string("local-version-\(id)")), ("fields", .object([("platform", .string(platform)), ("versionString", .string(target)), ("appStoreState", .string("LOCAL_DRAFT"))])),
                                         ("localizations", .array([.object([("id", .string("local-locale-\(id)")), ("fields", .object([("locale", .string(locale))])),
                                                                            ("screenshotSets", .array([.object([("id", .string("local-set-\(id)")), ("displayType", .string(StoreLocales.screenshotTypes(platform: platform).first ?? "")), ("screenshots", .array([]))])]))])]))])])),
        ])
    }

    /// The workspace revision on stored JSON: added languages and screenshot sizes join the revision.
    static func overlayJSON(_ source: JSONText, draft: JSONText) -> JSONText {
        let added = items(draft["addedLocalizations"]), sets = items(draft["addedScreenshotSets"])
        var codes: [String] = []
        let infos = items(source["appInfos"])
        for item in added { if let code = item["locale"]?.text, !codes.contains(code), !infos.contains(where: { items($0["localizations"]).contains { $0["fields"]?["locale"]?.text == code } }) { codes.append(code) } }
        let appInfos = infos + (codes.isEmpty ? [] : [.object([("id", .string("local-app-info")), ("fields", .object([])), ("localizations", .array(codes.map { .object([("id", .string("local-app-info-\($0)")), ("fields", .object([("locale", .string($0))]))]) }))])])
        let versions = items(source["versions"]).map { version -> JSONText in
            let id = version["id"]?.text ?? ""
            let locales = items(version["localizations"]) + added.filter { $0["versionId"]?.text == id }.map { item in
                JSONText.object([("id", item["id"] ?? .null), ("fields", .object([("locale", item["locale"] ?? .null)])), ("screenshotSets", .array([]))])
            }
            return version.setting("localizations", .array(locales.map { locale in
                locale.setting("screenshotSets", .array(items(locale["screenshotSets"]) + sets.filter { $0["localizationId"]?.text == locale["id"]?.text }.map {
                    JSONText.object([("id", $0["id"] ?? .null), ("displayType", $0["displayType"] ?? .null), ("screenshots", .array([]))])
                }))
            }))
        }
        return source.setting("appInfos", .array(appInfos)).setting("versions", .array(versions))
    }

    /// Copies one version's material into a new local revision and draft.
    /// Every referenced media file is decrypted and verified before the copy refers to it.
    func copyRelease(store: EncryptedDocumentStore, accountId: String, appId: String, sourceId: String, versionId: String, target: String, copyId: String, now: Date) throws {
        let sourceKey = "\(accountId):\(appId):\(sourceId)", targetKey = "\(accountId):\(appId):\(copyId)"
        guard let sourceDocument = try store.document(namespace: "revisions", key: sourceKey) else { throw ReleaseFailure.invalid("The saved source is unavailable. Reload before copying.") }
        let source = try JSONText.parse(sourceDocument.payload), before = try store.document(namespace: "drafts", key: sourceKey)
        let saved = try before.map { try JSONText.parse($0.payload) } ?? TextDrafts.empty(sourceId)
        let working = Self.overlayJSON(source, draft: saved)
        guard let selected = Self.items(working["versions"]).first(where: { $0["id"]?.text == versionId }) else { throw ReleaseFailure.invalid("Choose a saved version to copy.") }
        var fields: [(String, JSONText)] = [("platform", selected["fields"]?["platform"] ?? .null), ("versionString", .string(target)), ("appStoreState", .string("LOCAL_DRAFT"))]
        if let copyright = selected["fields"]?["copyright"], copyright != .null, copyright != .string("") { fields.append(("copyright", copyright)) }
        let codes = Set(Self.items(selected["localizations"]).compactMap { $0["fields"]?["locale"]?.text })
        let appInfos = Self.items(working["appInfos"]).map { info in info.setting("localizations", .array(Self.items(info["localizations"]).filter { codes.contains($0["fields"]?["locale"]?.text ?? "") })) }
            .filter { !Self.items($0["localizations"]).isEmpty }
        let localeIds = Set(Self.items(selected["localizations"]).compactMap { $0["id"]?.text })
        let textIds = localeIds.union(appInfos.flatMap { Self.items($0["localizations"]).compactMap { $0["id"]?.text } })
        var draft = TextDrafts.empty(copyId)
        if case .object(let texts)? = saved["texts"] {
            draft = draft.setting("texts", .object(texts.filter { textIds.contains($0.0) }.map { id, fields in
                (id, localeIds.contains(id) ? fields.setting("whatsNew", .string("")) : fields)
            }))
        }
        var sources: [(String, JSONText)] = []
        if case .object(let saved)? = saved["textSources"] {
            for (id, value) in saved where textIds.contains(id) {
                guard case .object(let markers) = value else { continue }
                sources.append((id, .object(markers.filter { (!localeIds.contains(id) || $0.0 != "whatsNew") && textIds.contains($0.1["localizationId"]?.text ?? "") }.map { ($0.0, $0.1.setting("revisionId", .string(copyId))) })))
            }
        }
        draft = draft.setting("textSources", .object(sources))
        var archived: [String: JSONText] = [:]
        for version in Self.items(source["versions"]) { for locale in Self.items(version["localizations"]) { for set in Self.items(locale["screenshotSets"]) { for image in Self.items(set["screenshots"]) { if let hash = image["sha256"]?.text { archived[hash] = image } } } } }
        var assets = Set<String>(), layouts: [(String, JSONText)] = []
        let uploads = Self.uploads(saved)
        let localizations = try Self.items(selected["localizations"]).map { locale in
            locale.setting("fields", (locale["fields"] ?? .object([])).setting("whatsNew", .string("")))
                .setting("screenshotSets", .array(try Self.items(locale["screenshotSets"]).map { set -> JSONText in
                let setId = set["id"]?.text ?? ""
                var screenshots = Self.items(set["screenshots"])
                for image in screenshots {
                    guard ["image/png", "image/jpeg"].contains(image["contentType"]?.text ?? ""), let hash = image["sha256"]?.text else { throw ReleaseFailure.invalid("The saved screenshot format is unsupported.") }
                    assets.insert(hash)
                }
                for (id, upload) in uploads where upload["setId"]?.text == setId {
                    guard let hash = upload["sha256"]?.text else { continue }
                    let original = upload["archiveSource"] == .bool(true) ? archived[hash] : nil
                    if upload["archiveSource"] == .bool(true) && original == nil { throw ReleaseFailure.invalid("A reused screenshot has no saved original. Restore its source before copying.") }
                    let type = original?["contentType"]?.text ?? upload["contentType"]?.text ?? "image/png"
                    guard ["image/png", "image/jpeg"].contains(type) else { throw ReleaseFailure.invalid("The saved screenshot format is unsupported.") }
                    screenshots.append(.object([("id", .string(id)), ("fileName", upload["fileName"] ?? .string("")), ("sha256", .string(hash)), ("width", upload["width"] ?? .null), ("height", upload["height"] ?? .null), ("contentType", .string(type))]))
                    assets.insert(hash)
                }
                let available = screenshots.compactMap { $0["id"]?.text }
                let old = saved["screenshotLayouts"]?[setId]
                let layout = ScreenshotSpecs.layout(available, saved: old.map { (order: Self.strings($0["order"]), hidden: Self.strings($0["hidden"])) })
                let hidden = Self.strings(old?["hidden"]).filter(available.contains)
                guard Set(available).subtracting(hidden).count <= ScreenshotSpecs.maximum else { throw ScreenshotFailure.limit("Select no more than 10 screenshots per language and display size.") }
                layouts.append((setId, .object([("order", .array(layout.order.map { .string($0) })), ("hidden", .array(hidden.map { .string($0) }))])))
                return set.setting("screenshots", .array(screenshots))
            }))
        }
        draft = draft.setting("screenshotLayouts", .object(layouts))
        var previews: [(String, JSONText)] = []
        if case .object(let videos)? = saved["previewUploads"] { previews = videos.filter { localeIds.contains($0.1["localizationId"]?.text ?? "") } }
        for video in previews { if let hash = video.1["sha256"]?.text { assets.insert(hash) } }
        let previewKeys = Set(previews.map { "\($0.1["localizationId"]?.text ?? ""):\($0.1["previewType"]?.text ?? "")" })
        var previewLayouts: [(String, JSONText)] = []
        if case .object(let saved)? = saved["previewLayouts"] { previewLayouts = saved.filter { previewKeys.contains($0.0) } }
        draft = draft.setting("previewUploads", .object(previews)).setting("previewLayouts", .object(previewLayouts))
        let version = selected.setting("id", .string("local-version-\(copyId)")).setting("fields", .object(fields)).setting("localizations", .array(localizations))
        let revision = JSONText.object([("schemaVersion", .number(1)), ("origin", .string("local")), ("id", .string(copyId)), ("importedAt", .string(CustomerReview.isoString(now))),
                                        ("account", source["account"] ?? .null), ("app", source["app"] ?? .null), ("appInfos", .array(appInfos)), ("versions", .array([version])),
                                        ("copiedFrom", .object([("revisionId", .string(sourceId)), ("versionId", .string(versionId)), ("version", .string(selected["fields"]?["versionString"].map { $0.text ?? $0.stringify() } ?? "")),
                                                                ("platform", .string(selected["fields"]?["platform"]?.text ?? ""))]))])
        guard draft.data.count <= 20_000_000 else { throw ReleaseFailure.invalid("Copied release material is too large.") }
        // Verify the authenticated source bytes before another version references them.
        for hash in assets {
            guard hash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw ReleaseFailure.invalid("Invalid saved media reference.") }
            guard (try? media.read(hash)) != nil else { throw ReleaseFailure.invalid("A saved media file changed or is damaged. Restore or upload it again before copying.") }
        }
        try store.transaction { current in
            guard try current("revisions", sourceKey) != nil, try current("drafts", sourceKey)?.revision == before?.revision else { throw ReleaseFailure.invalid("The saved source changed. Reload before copying.") }
            guard try current("revisions", targetKey) == nil, try current("drafts", targetKey) == nil else { throw ReleaseFailure.invalid("The new release already exists.") }
            return [.put(namespace: "revisions", key: targetKey, json: revision.data), .put(namespace: "drafts", key: targetKey, json: draft.data)]
        }
    }
}
