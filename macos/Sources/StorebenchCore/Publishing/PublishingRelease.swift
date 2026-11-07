import Foundation

extension WorkspaceSession {
    /// Published text validation: only known fields, within App Store Connect's limits, without control characters.
    static func publishedText(_ input: [(String, String)], appInfo: Bool) throws -> [(String, String)] {
        let allowed = appInfo ? TextDrafts.appInfoFields : TextDrafts.versionFields
        var fields: [(String, String)] = []
        for (field, value) in input where allowed.contains(field) {
            if let limit = TextDrafts.limits[field], TextDrafts.used(field, value) > limit { throw PublishFailure.invalid("Check \(field): Apple allows up to \(limit) \(field == "keywords" ? "bytes" : "characters").") }
            if !TextSemantics.validControlText(value) { throw PublishFailure.invalid("Remove control characters from \(field).") }
            if field.hasSuffix("Url"), !value.isEmpty {
                guard let url = URLComponents(string: value), ["https", "http"].contains(url.scheme ?? ""), url.host != nil, url.user == nil, url.password == nil else { throw PublishFailure.invalid("Enter a public HTTP or HTTPS URL for \(field).") }
            }
            if let index = fields.firstIndex(where: { $0.0 == field }) { fields[index].1 = value } else { fields.append((field, value)) }
        }
        if appInfo, let name = fields.first(where: { $0.0 == "name" }), name.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw PublishFailure.invalid("App name cannot be empty.") }
        return fields
    }

    static func describe(_ fields: [(String, String)]) -> String { fields.map { "\($0.0): \($0.1)" }.joined(separator: "\n\n") }

    static func fieldPairs(_ value: JSONText?) -> [(String, String)] {
        guard case .object(let pairs)? = value else { return [] }
        return pairs.compactMap { pair in
            switch pair.1 { case .string(let text): (pair.0, text); case .number(let number): (pair.0, JSONText.number(number)); default: nil }
        }
    }

    static func addTextChange(_ planner: Planner, current: AppStoreConnectClient.Resource, fields: [(String, String)], code: String) {
        let changed = fields.filter { !TextSemantics.sameStoreText(Apple.text(current.attributes?[$0.0]) ?? "", $0.1) }
        guard !changed.isEmpty else { return }
        planner.add(.api, method: "PATCH", path: [.string(current.type), .string(current.id)], label: "Update \(current.type == "appInfoLocalizations" ? "app information" : "version text") · \(code)",
                    detail: changed.map(\.0).joined(separator: ", "), before: describe(changed.map { ($0.0, Apple.text(current.attributes?[$0.0]) ?? "") }), after: describe(changed),
                    body: .object([("data", .object([("type", .string(current.type)), ("id", .string(current.id)), ("attributes", .object(changed.map { ($0.0, .string($0.1)) }))]))]))
    }

    func planRelease(_ planner: Planner, account: Account) async throws -> String {
        let request = planner.request
        let versions = try await planner.list("/v1/apps/\(request.appId)/appStoreVersions?include=app&limit=200")
        guard versions.allSatisfy({ $0.type == "appStoreVersions" && Apple.owned($0, "app", "apps", request.appId) }), Set(versions.map(\.id)).count == versions.count else { throw PublishFailure.invalid("Apple returned versions outside the selected app.") }
        if [.submit, .cancelSubmission, .releaseVersion, .versionBuild].contains(request.scope) { return try await planSubmission(planner, versions: versions) }
        let plan = try releasePlan(accountId: request.accountId, appId: request.appId)
        if request.scope == .release || request.targetMode == "release-plan" { planner.evidence.append(.object([("plan", plan.map { (try? JSONText.parse(Data($0.token.utf8))) ?? .null } ?? .null)])) }
        if request.scope == .release {
            guard let plan else { throw PublishFailure.invalid("Save a new version number in Version setup first.") }
            try Releases.validateVersion(plan.targetVersion)
            let matches = versions.filter { $0.attributes?["platform"]?.string == plan.platform && $0.attributes?["versionString"]?.string == plan.targetVersion }
            guard matches.count <= 1 else { throw PublishFailure.invalid("Apple returned several versions for the planned platform and number.") }
            let date = plan.earliestReleaseDate.flatMap { ISO8601DateFormatter.storebench.date(from: $0) }
            let settings = try Releases.settings(type: plan.releaseType ?? "MANUAL", date: date, now: Date())
            let after = plan.settings
            if let existing = matches.first {
                let previousType = existing.attributes?["releaseType"]?.string, previousDate = existing.attributes?["earliestReleaseDate"]?.string.flatMap { ISO8601DateFormatter.storebench.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
                let desiredDate = settings.first { $0.0 == "earliestReleaseDate" }?.1.text
                if previousType == (plan.releaseType ?? "MANUAL"), previousDate.map({ ISO8601DateFormatter.storebench.string(from: $0) }) == desiredDate {
                    planner.notes.append("Version \(plan.targetVersion) already exists with these release settings. Choose Languages & media to publish its material.")
                    return "Version \(plan.targetVersion) already created"
                }
                guard Apple.editable.contains(Apple.state(existing)) else { throw PublishFailure.invalid("This version's release settings cannot be edited in its current Apple state.") }
                let digest = try Apple.releaseDigest(existing.attributes)
                planner.add(.api, method: "PATCH", path: [.string("appStoreVersions"), .string(existing.id)], label: "Update release settings · \(plan.targetVersion)", detail: "Applies after Apple approves this version.",
                            before: "\(Releases.releaseTypes.first { $0.0 == previousType }?.1 ?? previousType ?? "")\(previousDate.map { " · \(ISO8601DateFormatter.storebench.string(from: $0)) (UTC)" } ?? "")", after: after,
                            body: .object([("data", .object([("type", .string("appStoreVersions")), ("id", .string(existing.id)), ("attributes", .object([("releaseType", settings[0].1), ("earliestReleaseDate", desiredDate.map { .string($0) } ?? .null)]))]))]),
                            guard: .object([("kind", .string("release-settings")), ("digest", .string(digest))]))
                return "Release settings · \(plan.targetVersion)"
            }
            planner.add(.api, method: "POST", path: [.string("appStoreVersions")], label: "Create \(Releases.platformName(plan.platform)) version \(plan.targetVersion)",
                        detail: "Create a version in App Store Connect with the release method below. This does not submit it for review.", after: "\(plan.targetVersion) · \(after)",
                        body: .object([("data", .object([("type", .string("appStoreVersions")), ("attributes", .object([("platform", .string(plan.platform)), ("versionString", .string(plan.targetVersion))] + settings)),
                                                          ("relationships", .object([("app", Apple.relationship("apps", .string(request.appId)))]))]))]))
            planner.notes.append("This review only creates the Apple version. Apple can leave fields such as Promotional Text and What's New empty on it. Save to App Store Connect, the next step, sends every field, screenshot and app preview of this plan, so nothing stays empty.")
            return "Create version \(plan.targetVersion)"
        }

        let history = try revisions(accountId: request.accountId, appId: request.appId)
        guard let sourceMeta = request.revisionId.map({ id in history.first { $0.id == id } }) ?? history.first(where: { !$0.isLocalDraft }) ?? history.first else { throw PublishFailure.invalid("Import the app, or select an available source revision, first.") }
        let key = "\(request.accountId):\(request.appId):\(sourceMeta.id)"
        let (sourceJSON, draftJSON) = try storeAccess { store in
            (try store.document(namespace: "revisions", key: key).map { try JSONText.parse($0.payload) }, try store.document(namespace: "drafts", key: key).map { try JSONText.parse($0.payload) })
        }
        guard let sourceJSON else { throw PublishFailure.invalid("Import the app, or select an available source revision, first.") }
        let draft = draftJSON ?? TextDrafts.empty(sourceMeta.id)
        let working = Self.overlayJSON(sourceJSON, draft: draft)
        let workingVersions = Self.items(working["versions"])
        guard let local = request.versionId.map({ id in workingVersions.first { $0["id"]?.text == id } }) ?? workingVersions.first else { throw PublishFailure.invalid("Choose a version from this imported revision.") }
        let localId = local["id"]?.text ?? ""
        let usesPlan = request.targetMode == "release-plan"
        if usesPlan, plan?.sourceRevisionId != sourceMeta.id || plan?.baseVersionId != localId { throw PublishFailure.invalid("The selected material is not attached to the version draft. Choose its source or review the Apple version instead.") }
        let targets = usesPlan ? versions.filter { $0.attributes?["platform"]?.string == plan!.platform && $0.attributes?["versionString"]?.string == plan!.targetVersion } : versions.filter { $0.id == localId }
        guard targets.count <= 1 else { throw PublishFailure.invalid("Apple returned several versions for the selected platform and number.") }
        guard let remote = targets.first else {
            if usesPlan { throw PublishFailure.versionRequired }
            throw PublishFailure.invalid("The selected version does not exist at Apple. Choose an imported Apple version, or explicitly select the version draft.")
        }
        guard Apple.editable.contains(Apple.state(remote)) else { throw PublishFailure.invalid("This Apple version is \(Apple.state(remote).isEmpty ? "not editable" : AppStoreNames.state(Apple.state(remote))). Prepare a new version or cancel its review submission first.") }
        planner.evidence.append(.object([("source", sourceJSON), ("draft", draft)]))
        let copyAll = remote.id != localId
        var archive: [String: JSONText] = [:]
        for version in Self.items(sourceJSON["versions"]) { for locale in Self.items(version["localizations"]) { for set in Self.items(locale["screenshotSets"]) { for image in Self.items(set["screenshots"]) { if let hash = image["sha256"]?.text { archive[hash] = image } } } } }
        let media = ReleaseMediaPlan(platform: remote.attributes?["platform"]?.string ?? "")
        let uploadOnly = request.mediaStage == PublishRequest.uploadStage
        let screenshotsOnly = request.mediaStage == PublishRequest.screenshotsStage, quick = request.mediaStage == PublishRequest.quickStage
        let textOnly = request.mediaStage == PublishRequest.textStage || quick
        media.uploadOnly = uploadOnly
        let remoteLocales = try await planner.list("/v1/appStoreVersions/\(remote.id)/appStoreVersionLocalizations?limit=200")
        guard remoteLocales.allSatisfy({ $0.type == "appStoreVersionLocalizations" && Apple.within($0, "appStoreVersion", "appStoreVersions", remote.id) }), Set(remoteLocales.map(\.id)).count == remoteLocales.count,
              Set(remoteLocales.compactMap { $0.attributes?["locale"]?.string }).count == remoteLocales.count else { throw PublishFailure.invalid("Apple returned version languages outside the selected version.") }
        let texts = draft["texts"]
        // Apple has no What's New for an app's first version on a platform, so it is never sent there.
        let platform = remote.attributes?["platform"]?.string ?? ""
        let firstVersion = !versions.contains { $0.id != remote.id && $0.attributes?["platform"]?.string == platform }
        func sendable(_ fields: [(String, String)]) -> [(String, String)] { firstVersion ? fields.filter { $0.0 != "whatsNew" } : fields }
        var addedLanguages: [String] = []
        for locale in Self.items(local["localizations"]) {
            let code = locale["fields"]?["locale"]?.text ?? "", id = locale["id"]?.text ?? ""
            let current = remoteLocales.first { $0.attributes?["locale"]?.string == code }
            let drafted = texts?[id].map(Self.fieldPairs)
            var text: [(String, String)]?
            // A full Save compares every local field with Apple, as step 3's check does, so a value only on this Mac is always sent;
            // Quick Release sends only what was edited.
            if copyAll || current == nil || !quick {
                var merged = Self.fieldPairs(locale["fields"])
                for (field, value) in drafted ?? [] { if let index = merged.firstIndex(where: { $0.0 == field }) { merged[index].1 = value } else { merged.append((field, value)) } }
                text = merged
            } else { text = drafted }
            let remoteLocale: JSONText
            if uploadOnly {
                // Asset Library belongs to the app, so files upload before their language exists on the version.
                remoteLocale = current.map { .string($0.id) } ?? .null
            } else if let current {
                remoteLocale = .string(current.id)
                if !screenshotsOnly, let text {
                    let fields = try Self.publishedText(sendable(text), appInfo: false)
                    Self.addTextChange(planner, current: current, fields: quick ? QuickRelease.sent(fields, appInfo: false) : fields, code: code)
                }
            } else {
                // A language new to this version is added with its text in either part, since screenshots need the language to exist.
                let fields = try Self.publishedText(sendable(text ?? []), appInfo: false)
                addedLanguages.append(code)
                remoteLocale = Apple.ref(planner.add(.api, method: "POST", path: [.string("appStoreVersionLocalizations")], label: "Add language · \(code)", detail: "Version \(remote.attributes?["versionString"]?.string ?? "")",
                                                     after: Self.describe(fields), body: .object([("data", .object([("type", .string("appStoreVersionLocalizations")), ("attributes", .object([("locale", .string(code))] + fields.map { ($0.0, .string($0.1)) })),
                                                                                                                  ("relationships", .object([("appStoreVersion", Apple.relationship("appStoreVersions", .string(remote.id)))]))]))])))
            }
            if !textOnly { try await planMedia(planner, media: media, locale: locale, remoteLocale: remoteLocale, draft: draft, revisionId: sourceMeta.id, copyAll: copyAll || current == nil, archive: archive) }
        }
        if screenshotsOnly {
            guard !planner.steps.isEmpty else { throw PublishFailure.noChanges }
            let text = addedLanguages.isEmpty ? "Text and copyright are saved in step 3."
                : "Screenshots need their language on the version, so this Save also adds \(addedLanguages.joined(separator: ", ")) with its text. Copyright and other text changes are saved in step 3."
            planner.notes.append("Save uploads files Apple does not have yet to Asset Library, then adds them to App Previews and Screenshots in the order you chose. " + text)
            return "Save to App Previews and Screenshots · \(Releases.platformName(remote.attributes?["platform"]?.string ?? "")) \(remote.attributes?["versionString"]?.string ?? "")"
        }
        if uploadOnly {
            // Every file is already in Asset Library: there is nothing to upload, and Save adds them to the version.
            guard !planner.steps.isEmpty else { throw PublishFailure.noChanges }
            planner.notes.append("Upload only saves these files in Asset Library. Save to App Store Connect then adds them to App Previews and Screenshots in your order, with the text.")
            return "Upload to Asset Library · \(Releases.platformName(remote.attributes?["platform"]?.string ?? "")) \(remote.attributes?["versionString"]?.string ?? "")"
        }
        // Quick Release sends Subtitle only, so a language without a subtitle draft needs no app information at all. A full Save also
        // compares a language's only local app information with Apple, as step 3's check does, so values only on this Mac are sent.
        let localInfos = Self.items(working["appInfos"]).flatMap { Self.items($0["localizations"]) }
        func onlyRecord(_ locale: JSONText) -> Bool { localInfos.filter { TextSemantics.same($0["fields"]?["locale"]?.text, locale["fields"]?["locale"]?.text) }.count == 1 }
        let infoEdits = localInfos.filter { locale in
            let drafted = texts?[locale["id"]?.text ?? ""]
            return quick ? drafted?["subtitle"] != nil : drafted != nil || onlyRecord(locale)
        }
        if !infoEdits.isEmpty {
            let infos = try await planner.list("/v1/apps/\(request.appId)/appInfos?include=app&limit=200")
            guard infos.allSatisfy({ $0.type == "appInfos" && Apple.owned($0, "app", "apps", request.appId) }), Set(infos.map(\.id)).count == infos.count else { throw PublishFailure.invalid("Apple returned app information outside the selected app.") }
            let editable = infos.filter { Apple.editable.contains(Apple.state($0)) }
            guard !editable.isEmpty else { throw PublishFailure.invalid("Apple's app information is not editable. Create a new version before publishing name, subtitle or privacy changes.") }
            guard editable.count == 1, let info = editable.first else { throw PublishFailure.invalid("Choose one editable app information record at Apple before publishing name, subtitle or privacy changes.") }
            let remoteInfo = try await planner.list("/v1/appInfos/\(info.id)/appInfoLocalizations?limit=200")
            guard remoteInfo.allSatisfy({ $0.type == "appInfoLocalizations" && Apple.within($0, "appInfo", "appInfos", info.id) }), Set(remoteInfo.map(\.id)).count == remoteInfo.count,
                  Set(remoteInfo.compactMap { $0.attributes?["locale"]?.string }).count == remoteInfo.count else { throw PublishFailure.invalid("Apple returned app information languages outside the selected app information.") }
            var seen = Set<String>()
            for locale in infoEdits {
                let code = locale["fields"]?["locale"]?.text ?? ""
                guard seen.insert(code).inserted else { throw PublishFailure.invalid("Several app information drafts exist for \(code). Keep one source before publishing.") }
                let current = remoteInfo.first { $0.attributes?["locale"]?.string == code }
                var merged = current == nil || !quick ? Self.fieldPairs(locale["fields"]) : []
                for (field, value) in Self.fieldPairs(texts?[locale["id"]?.text ?? ""]) { if let index = merged.firstIndex(where: { $0.0 == field }) { merged[index].1 = value } else { merged.append((field, value)) } }
                let fields = try Self.publishedText(merged, appInfo: true)
                if let current { Self.addTextChange(planner, current: current, fields: quick ? QuickRelease.sent(fields, appInfo: true) : fields, code: code) }
                else {
                    guard fields.contains(where: { $0.0 == "name" }) else { throw PublishFailure.invalid("Add the app name for \(code) in Localizations before publishing.") }
                    planner.add(.api, method: "POST", path: [.string("appInfoLocalizations")], label: "Add app information · \(code)", detail: "Name, subtitle and privacy information.", after: Self.describe(fields),
                                body: .object([("data", .object([("type", .string("appInfoLocalizations")), ("attributes", .object([("locale", .string(code))] + fields.map { ($0.0, .string($0.1)) })),
                                                                  ("relationships", .object([("appInfo", Apple.relationship("appInfos", .string(info.id)))]))]))]))
                }
            }
        }
        if quick {
            guard !planner.steps.isEmpty else { throw PublishFailure.noChanges }
            if !addedLanguages.isEmpty { planner.notes.append("\(addedLanguages.joined(separator: ", ")) is new to this version. Save adds it with every text field it has on this Mac, not only the four below.") }
            planner.notes.append("Quick Release saves Description, Subtitle, Keywords and What's New only. Screenshots, Promotional Text and other local drafts stay on this Mac and are not sent.")
            return "Save text to App Store Connect · \(Releases.platformName(remote.attributes?["platform"]?.string ?? "")) \(remote.attributes?["versionString"]?.string ?? "")"
        }
        planner.notes.append("Saved local drafts are retained. Only the changes listed below are sent. Import again after publishing to archive Apple's updated material.")
        if planner.steps.contains(where: { $0.path.first?.text?.hasPrefix("appAssetLibrary") == true }) { planner.notes.append("Screenshots and app previews are saved once in Asset Library and placed on this version. Removed media leaves this version only; its files stay in Asset Library. If a later step fails, completed steps remain applied; review again to finish the remaining changes.") }
        return "Publish material · \(Releases.platformName(remote.attributes?["platform"]?.string ?? "")) \(remote.attributes?["versionString"]?.string ?? "")"
    }

    func planMedia(_ planner: Planner, media: ReleaseMediaPlan, locale: JSONText, remoteLocale: JSONText, draft: JSONText, revisionId: String, copyAll: Bool, archive: [String: JSONText]) async throws {
        let localeName = locale["fields"]?["locale"]?.text ?? "", localeId = locale["id"]?.text ?? ""
        func size(_ value: JSONText?) -> (Int, Int) { (AssetLibrary.integer(value?["width"]) ?? 0, AssetLibrary.integer(value?["height"]) ?? 0) }
        func sized(_ items: [ReleaseMediaPlan.Item]) throws -> [ReleaseMediaPlan.Item] {
            if let item = items.first(where: { $0.width < 1 || $0.height < 1 }) { throw PublishFailure.invalid("Add \(item.fileName) again so its pixel size is known before publishing.") }
            return items
        }
        for set in Self.items(locale["screenshotSets"]) {
            let setId = set["id"]?.text ?? ""
            let uploads = Self.uploads(draft).filter { $0.1["setId"]?.text == setId }
            let savedLayout = draft["screenshotLayouts"]?[setId]
            if !copyAll && savedLayout == nil && uploads.isEmpty { continue }
            var images: [ReleaseMediaPlan.Item] = Self.items(set["screenshots"]).compactMap { image in
                guard let id = image["id"]?.text, let hash = image["sha256"]?.text else { return nil }
                let ext = image["contentType"]?.text == "image/jpeg" ? "jpg" : "png", fileName = image["fileName"]?.text.flatMap { $0.isEmpty ? nil : $0 } ?? "screenshot.\(ext)", (width, height) = size(image)
                return .init(originalId: id, hash: hash, storage: "archive", ext: ext, fileName: fileName, width: width, height: height, assetId: image["assetId"]?.text, poster: nil)
            }
            for (id, upload) in uploads {
                guard let hash = upload["sha256"]?.text else { continue }
                let source = upload["archiveSource"] == .bool(true) ? archive[hash] : nil
                let ext = (source?["contentType"]?.text ?? (source == nil ? upload["contentType"]?.text : nil)) == "image/jpeg" ? "jpg" : "png"
                let fileName = upload["fileName"]?.text.flatMap { $0.isEmpty ? nil : $0 } ?? "screenshot.\(ext)", (width, height) = size(upload["width"] == nil ? source : upload)
                images.append(.init(originalId: id, hash: hash, storage: upload["archiveSource"] == .bool(true) ? "archive" : "image", ext: ext, fileName: fileName, width: width, height: height, assetId: source?["assetId"]?.text ?? upload["assetId"]?.text, poster: nil))
            }
            let order = savedLayout.map { Self.strings($0["order"]) } ?? images.map(\.originalId), hidden = Set(Self.strings(savedLayout?["hidden"]))
            guard Set(images.map(\.originalId)).subtracting(hidden).count <= ScreenshotSpecs.maximum else { throw PublishFailure.invalid("Select no more than 10 screenshots per language and display size.") }
            let positions = Dictionary(order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
            let selected = images.enumerated().sorted { (positions[$0.element.originalId] ?? Int.max, $0.offset) < (positions[$1.element.originalId] ?? Int.max, $1.offset) }.map(\.element).filter { !hidden.contains($0.originalId) }
            try await planPlacements(planner, media: media, remoteLocale: remoteLocale, localeName: localeName, kind: .image, displayType: set["displayType"]?.text ?? "", group: set["placementGroup"]?.text, items: try sized(selected), related: images, revisionId: revisionId)
        }
        guard case .object(let videos)? = draft["previewUploads"] else { return }
        let local = videos.filter { $0.1["localizationId"]?.text == localeId }
        var types: [String] = []
        for video in local { if let type = video.1["previewType"]?.text, !types.contains(type) { types.append(type) } }
        for type in types {
            let available = local.filter { $0.1["previewType"]?.text == type }
            let layout = draft["previewLayouts"]?["\(localeId):\(type)"]
            let order = layout.map { Self.strings($0["order"]) } ?? available.map(\.0), hidden = Set(Self.strings(layout?["hidden"]))
            let related = try order.compactMap { id -> ReleaseMediaPlan.Item? in
                guard let video = available.first(where: { $0.0 == id })?.1, let hash = video["sha256"]?.text, let ext = video["extension"]?.text else { return nil }
                var time = 5.0
                if case .number(let saved)? = layout?["posterTimes"]?[id] { time = saved }
                let fileName = video["fileName"]?.text ?? "preview.\(ext)", (width, height) = size(video)
                guard let frameRate = AssetLibrary.number(video["frameRate"]) else { throw PublishFailure.invalid("Add \(fileName) again so its frame rate is known before publishing.") }
                return .init(originalId: id, hash: hash, storage: "preview", ext: ext, fileName: fileName, width: width, height: height, assetId: nil, poster: try ReleaseMedia.timeCode(time, frameRate: frameRate))
            }
            try await planPlacements(planner, media: media, remoteLocale: remoteLocale, localeName: localeName, kind: .video, displayType: type, group: nil, items: try sized(related.filter { !hidden.contains($0.originalId) }), related: related, revisionId: revisionId)
        }
    }

    /// The build step's Add Build: only the version's build relationship changes. Submitting stays a separate review.
    func planVersionBuild(_ planner: Planner, version: AppStoreConnectClient.Resource, name: String) async throws -> String {
        let request = planner.request
        let attached = try await attachedBuild(versionId: version.id, appId: request.appId, client: planner.client)
        guard let buildId = request.buildId else { throw PublishFailure.invalid("Choose the build to add to this version.") }
        let page = try await planner.listWithIncluded("/v1/builds?filter%5Bapp%5D=\(request.appId)&filter%5Bid%5D=\(buildId)&include=preReleaseVersion&limit=200")
        guard let build = page.data.first(where: { $0.id == buildId }), Apple.owner(build, "app").map({ $0 == ("apps", request.appId) }) ?? true, Self.eligible(build, included: page.included, version: version) else {
            throw PublishFailure.invalid("Choose a processed, App Store eligible build for this app, platform and version.")
        }
        selectBuild(planner, build: build, attached: attached, version: version, name: name)
        planner.notes.append("This adds the build to the version at Apple. It does not submit the version; Add for Review is a separate step.")
        return "Add Build \(build.attributes?["version"]?.string ?? build.id) · \(name)"
    }

    private func selectBuild(_ planner: Planner, build: AppStoreConnectClient.Resource, attached: AppStoreConnectClient.Resource?, version: AppStoreConnectClient.Resource, name: String) {
        planner.evidence.append(.object([("attachedBuildId", attached.map { .string($0.id) } ?? .null)]))
        guard attached?.id != build.id else { return }
        planner.add(.api, method: "PATCH", path: [.string("appStoreVersions"), .string(version.id)], label: "Select build \(build.attributes?["version"]?.string ?? build.id)", detail: name,
                    before: attached.map { "Build \($0.attributes?["version"]?.string ?? $0.id)" } ?? "No build selected", after: "Build \(build.attributes?["version"]?.string ?? build.id)",
                    body: .object([("data", .object([("type", .string("appStoreVersions")), ("id", .string(version.id)), ("relationships", .object([("build", Apple.relationship("builds", .string(build.id)))]))]))]),
                    guard: .object([("kind", .string("submission-build")), ("digest", .string(Apple.jsonDigest(attached.map { .string($0.id) } ?? .null)))]))
    }

    /// What Add for Review's review below verifies at Apple before it adds a version, in its order: the version's copyright, Age Ratings,
    /// App Review Information with its attachments, the version's Asset Library media, then the build and its export compliance.
    /// Release reads the screens for these ahead, so a refusal opens its fix at once; keep this list in step with `planSubmission`.
    public static let submissionChecks: [AppleProblem.Area] = [.copyright, .ageRating, .reviewInformation, .listing, .build, .exportCompliance]
    /// The checks that follow the build chosen in Build, which only a confirmed build and compliance answer settle.
    public static let submissionBuildChecks: Set<AppleProblem.Area> = [.build, .exportCompliance]

    func planSubmission(_ planner: Planner, versions: [AppStoreConnectClient.Resource]) async throws -> String {
        let request = planner.request
        guard let version = versions.first(where: { $0.id == request.versionId }) else { throw PublishFailure.invalid("Choose an Apple version belonging to this app.") }
        let platform = version.attributes?["platform"]?.string ?? "", name = "\(Releases.platformName(platform)) \(version.attributes?["versionString"]?.string ?? "")"
        let client = planner.client
        if request.scope == .cancelSubmission {
            let submissions = try await planner.list("/v1/apps/\(request.appId)/reviewSubmissions?filter%5Bplatform%5D=\(platform)&limit=200")
            guard submissions.allSatisfy({ $0.type == "reviewSubmissions" && Apple.within($0, "app", "apps", request.appId) }) else { throw PublishFailure.invalid("Apple returned review submissions outside the selected app.") }
            var matching: [(AppStoreConnectClient.Resource, [AppStoreConnectClient.Resource])] = []
            for submission in submissions where !["COMPLETE", "CANCELED"].contains(submission.attributes?["state"]?.string ?? "") {
                let items = try await planner.list("/v1/reviewSubmissions/\(submission.id)/items?include=appStoreVersion&limit=200")
                guard items.allSatisfy({ $0.type == "reviewSubmissionItems" && Apple.within($0, "reviewSubmission", "reviewSubmissions", submission.id) }) else { throw PublishFailure.invalid("Apple returned review items outside the selected submission.") }
                if items.contains(where: { Apple.owned($0, "appStoreVersion", "appStoreVersions", version.id) }) { matching.append((submission, items)) }
            }
            guard matching.count == 1, let (submission, items) = matching.first else { throw PublishFailure.invalid("Choose a version with exactly one active App Review submission.") }
            let digest = try Self.cancellationDigest(submission, items: items, appId: request.appId, versionId: version.id)
            planner.add(.api, method: "PATCH", path: [.string("reviewSubmissions"), .string(submission.id)], label: "Cancel Submission · \(name)",
                        detail: "This cancels the entire submission, which contains only this app version. Apple will restart review if you submit it again.",
                        before: "\(name) · \((submission.attributes?["state"]?.string ?? "").lowercased().replacingOccurrences(of: "_", with: " "))", after: "Cancellation requested · version returns to Developer Rejected",
                        body: .object([("data", .object([("type", .string("reviewSubmissions")), ("id", .string(submission.id)), ("attributes", .object([("canceled", .bool(true))]))]))]),
                        guard: .object([("kind", .string("submission-cancel")), ("digest", .string(digest)), ("versionId", .string(version.id))]))
            return "Cancel Submission · \(name)"
        }
        if request.scope == .releaseVersion {
            guard Apple.state(version) == "PENDING_DEVELOPER_RELEASE" else { throw PublishFailure.invalid("Apple must approve the version and mark it Pending Developer Release first.") }
            guard version.attributes?["releaseType"]?.string == "MANUAL" else { throw PublishFailure.invalid("Apple must set this approved version to manual release before Storebench can release it.") }
            planner.add(.api, method: "POST", path: [.string("appStoreVersionReleaseRequests")], label: "Release \(name)", detail: "Make this approved version available on the App Store.",
                        body: .object([("data", .object([("type", .string("appStoreVersionReleaseRequests")), ("relationships", .object([("appStoreVersion", Apple.relationship("appStoreVersions", .string(version.id)))]))]))]))
            return "Release \(name)"
        }
        guard Apple.editable.contains(Apple.state(version)) else { throw PublishFailure.invalid("This version is not ready to prepare for review.") }
        if request.scope == .versionBuild { return try await planVersionBuild(planner, version: version, name: name) }
        guard case .string(let copyright)? = version.attributes?["copyright"], !copyright.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw PublishFailure.invalid("Version copyright is missing at Apple. In App Store Connect, click this version in the app's sidebar and add Copyright, then submit this version.")
        }
        // Apple adds a version for review only when every Age Ratings question is answered, so say which ones before anything is sent.
        if let declaration = try? await ageRatingDeclaration(appId: request.appId, client: client, planner: planner) {
            let unanswered = AgeRating.unanswered(Planner.resource(declaration)["attributes"])
            if !unanswered.isEmpty { throw PublishFailure.refused("Answer \(unanswered.count) Age Ratings \(unanswered.count == 1 ? "question" : "questions") first: " + unanswered.map(AgeRating.label).joined(separator: ", ") + ". Apple adds a version for review only when every question has an answer.", problems: unanswered.map { AppleProblem(code: "ENTITY_ERROR.ATTRIBUTE.REQUIRED", resource: "ageRatingDeclarations", field: $0) }) }
        }
        let incomplete = "App Review Information is incomplete at Apple. In App Store Connect, click this version in the app's sidebar and complete App Review Information, then submit this version."
        guard let detail = try await reviewDetail(versionId: version.id, client: client) else { throw PublishFailure.invalid(incomplete) }
        planner.evidence.append(.object([("reviewDetail", Planner.resource(detail))]))
        let informationDigest: String
        do { informationDigest = try Self.reviewInformationDigest(detail) } catch { throw PublishFailure.invalid(incomplete) }
        let attachmentsDigest = try Self.attachmentsDigest(try await planner.list("/v1/appStoreReviewDetails/\(detail.id)/appStoreReviewAttachments?limit=200"), detailId: detail.id)
        let libraryReview = try await versionLibraryReview(reader: libraryReader(planner), version: version)
        if !libraryReview.descriptions.isEmpty { planner.notes.append("Assigned Asset Library media included in this version's review:\n" + libraryReview.descriptions.joined(separator: "\n")) }
        let attached = try await attachedBuild(versionId: version.id, appId: request.appId, client: client)
        guard let buildId = request.buildId ?? attached?.id else { throw PublishFailure.invalid("Select a processed build belonging to this app before submitting for review.") }
        let page = try await planner.listWithIncluded("/v1/builds?filter%5Bapp%5D=\(request.appId)&filter%5Bid%5D=\(buildId)&include=preReleaseVersion&limit=200")
        guard let build = page.data.first(where: { $0.id == buildId }), Apple.owner(build, "app").map({ $0 == ("apps", request.appId) }) ?? true, Self.eligible(build, included: page.included, version: version) else {
            throw PublishFailure.invalid("Choose a processed, App Store eligible build for this app, platform and version.")
        }
        selectBuild(planner, build: build, attached: attached, version: version, name: name)
        let submissions = try await planner.list("/v1/apps/\(request.appId)/reviewSubmissions?filter%5Bplatform%5D=\(platform)&limit=200")
        guard submissions.allSatisfy({ $0.type == "reviewSubmissions" && Apple.within($0, "app", "apps", request.appId) }) else { throw PublishFailure.invalid("Apple returned review submissions outside the selected app.") }
        let active = submissions.filter { !["COMPLETE", "CANCELED"].contains($0.attributes?["state"]?.string ?? "") }
        guard active.count <= 1, active.allSatisfy({ $0.attributes?["state"]?.string == "READY_FOR_REVIEW" }) else { throw PublishFailure.invalid("An Apple review submission is already in progress. Resolve it under App Review in the app's sidebar in App Store Connect first.") }
        var submission: JSONText, hasItem = false
        if let existing = active.first {
            submission = .string(existing.id)
            let items = try await planner.list("/v1/reviewSubmissions/\(existing.id)/items?include=appStoreVersion&limit=200")
            guard items.allSatisfy({ $0.type == "reviewSubmissionItems" && Apple.within($0, "reviewSubmission", "reviewSubmissions", existing.id) && Apple.owned($0, "appStoreVersion", "appStoreVersions", version.id) }) else {
                throw PublishFailure.invalid("The existing review submission contains other material. Review it under App Review in the app's sidebar in App Store Connect before proceeding.")
            }
            hasItem = !items.isEmpty
        } else {
            submission = Apple.ref(planner.add(.api, method: "POST", path: [.string("reviewSubmissions")], label: "Add for Review · \(name)", detail: "Create the review submission.",
                                               body: .object([("data", .object([("type", .string("reviewSubmissions")), ("attributes", .object([("platform", .string(platform))])), ("relationships", .object([("app", Apple.relationship("apps", .string(request.appId)))]))]))])))
        }
        if !hasItem {
            planner.add(.api, method: "POST", path: [.string("reviewSubmissionItems")], label: "Add \(name) to the submission", detail: "Only this version is included.",
                        body: .object([("data", .object([("type", .string("reviewSubmissionItems")), ("relationships", .object([("reviewSubmission", Apple.relationship("reviewSubmissions", submission)), ("appStoreVersion", Apple.relationship("appStoreVersions", .string(version.id)))]))]))]))
        }
        planner.add(.api, method: "PATCH", path: [.string("reviewSubmissions"), submission], label: "Submit to App Review · \(name)",
                    detail: "Apple validates required metadata, agreements, build and review information. If rejected, completed preparation steps remain saved.",
                    body: .object([("data", .object([("type", .string("reviewSubmissions")), ("id", submission), ("attributes", .object([("submitted", .bool(true))]))]))]),
                    guard: .object([("kind", .string("submission-final")), ("versionId", .string(version.id)), ("digest", .string(Apple.jsonDigest(.string(build.id)))), ("copyrightDigest", .string(Apple.jsonDigest(.string(copyright)))),
                                     ("reviewInformationDigest", .string(informationDigest)), ("reviewAttachmentsDigest", .string(attachmentsDigest)), ("assetLibraryDigest", .string(libraryReview.digest))]))
        return "Submit to App Review · \(name)"
    }
}
