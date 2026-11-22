import Foundation

extension WorkspaceSession {
    /// Brings App Store Connect's text into this Mac's draft for these fields, after it was changed at App Store Connect.
    /// The draft then shows Apple's text, and the field is remembered as Apple's rather than as an edit: a review never sends it,
    /// also when App Store Connect has changed again since. Editing the field afterwards makes it this Mac's again. Only the local draft changes.
    public func useAppStoreConnectText(accountId: String, appId: String, revisionId: String, localizationId: String, scope: TextDrafts.Scope, values: [String: String]) throws {
        guard !values.isEmpty, !localizationId.isEmpty, localizationId.utf16.count <= 256, Set(values.keys).isSubset(of: TextDrafts.fields(scope)),
              values.values.allSatisfy({ $0.utf16.count <= 10_000 }) else { throw DraftFailure.invalid }
        try mutateDraft(accountId: accountId, appId: appId, revisionId: revisionId) { draft, _ in
            var texts = draft["texts"]?[localizationId] ?? .object([]), taken = draft["takenAppleText"]?[localizationId] ?? .object([])
            for (field, value) in values { texts = texts.setting(field, .string(value)); taken = taken.setting(field, .string(JSONText.string(value).rawSHA256)) }
            let updated = draft.setting("texts", (draft["texts"] ?? .object([])).setting(localizationId, texts))
                .setting("takenAppleText", (draft["takenAppleText"] ?? .object([])).setting(localizationId, taken))
            return (Self.forgettingKept(updated, localizationId: localizationId, fields: Set(values.keys)), ())
        }
    }

    /// Keeps this Mac's text for these fields over the App Store Connect text it now differs from, so the next Save sends it.
    /// `apple` is the text App Store Connect had when the person chose; if it changes again, the choice is asked again.
    public func keepDraftText(accountId: String, appId: String, revisionId: String, localizationId: String, scope: TextDrafts.Scope, apple: [String: String]) throws {
        guard !apple.isEmpty, !localizationId.isEmpty, localizationId.utf16.count <= 256, Set(apple.keys).isSubset(of: TextDrafts.fields(scope)) else { throw DraftFailure.invalid }
        try mutateDraft(accountId: accountId, appId: appId, revisionId: revisionId) { draft, _ in
            var kept = draft["keptAppleText"]?[localizationId] ?? .object([])
            for (field, value) in apple { kept = kept.setting(field, .string(JSONText.string(value).rawSHA256)) }
            return (draft.setting("keptAppleText", (draft["keptAppleText"] ?? .object([])).setting(localizationId, kept)), ())
        }
    }

    /// Quick Release reuses the current listing. Text this Mac never edited takes the text its review leaves or sends for that field,
    /// read from App Store Connect now, so the status afterwards only reports what was typed here and the version can be added for review.
    /// A field typed on this Mac, or kept with Keep Mine, is never touched: that is checked again in the same locked write that
    /// changes the draft. What's New is typed for every version and is never taken. Only the local draft changes.
    /// Returns how many fields took App Store Connect's text.
    @discardableResult public func reuseCurrentAppleText(account: Account, plan: ReleasePlan) async throws -> Int {
        try await reuseCurrentAppleText(account: account, plan: plan, client: try client(for: account))
    }
    @discardableResult public func reuseCurrentAppleText(account: Account, plan: ReleasePlan, client: AppStoreConnectClient) async throws -> Int {
        try requirePublishingAccount(account, appId: plan.appId, client: client)
        let versions = try await client.list("/v1/apps/\(plan.appId)/appStoreVersions?include=app&limit=200")
        guard versions.allSatisfy({ $0.type == "appStoreVersions" && Apple.owned($0, "app", "apps", plan.appId) }), Set(versions.map(\.id)).count == versions.count else { throw PublishFailure.invalid("Apple returned versions outside the selected app.") }
        let targets = versions.filter { $0.attributes?["platform"]?.string == plan.platform && $0.attributes?["versionString"]?.string == plan.targetVersion }
        guard targets.count == 1, let target = targets.first, Apple.editable.contains(Apple.state(target)) else { return 0 }
        func locales(_ versionId: String) async throws -> [AppStoreConnectClient.Resource] {
            let values = try await client.list("/v1/appStoreVersions/\(versionId)/appStoreVersionLocalizations?limit=200")
            guard values.allSatisfy({ $0.type == "appStoreVersionLocalizations" && Apple.within($0, "appStoreVersion", "appStoreVersions", versionId) }), Set(values.map(\.id)).count == values.count,
                  Set(values.compactMap { $0.attributes?["locale"]?.string }).count == values.count else { throw PublishFailure.invalid("Apple returned version languages outside the selected version.") }
            return values
        }
        // The same sources the review uses: the version being changed, and for a new version the version it continues.
        let onTarget = try await locales(target.id)
        let continued = target.id == plan.baseVersionId ? onTarget : versions.contains(where: { $0.id == plan.baseVersionId }) ? try await locales(plan.baseVersionId) : []
        var information: [AppStoreConnectClient.Resource] = []
        let infos = try await client.list("/v1/apps/\(plan.appId)/appInfos?include=app&limit=200")
        guard infos.allSatisfy({ $0.type == "appInfos" && Apple.owned($0, "app", "apps", plan.appId) }) else { throw PublishFailure.invalid("Apple returned app information outside the selected app.") }
        let editable = infos.filter { Apple.editable.contains(Apple.state($0)) }
        if editable.count == 1 {
            information = try await client.list("/v1/appInfos/\(editable[0].id)/appInfoLocalizations?limit=200")
            guard information.allSatisfy({ $0.type == "appInfoLocalizations" && Apple.within($0, "appInfo", "appInfos", editable[0].id) }),
                  Set(information.compactMap { $0.attributes?["locale"]?.string }).count == information.count else { throw PublishFailure.invalid("Apple returned app information languages outside the selected app information.") }
        }
        try requirePublishingAccount(account, appId: plan.appId, client: client)
        struct Unchanged: Error {}
        do {
            return try mutateDraft(accountId: plan.accountId, appId: plan.appId, revisionId: plan.sourceRevisionId) { draft, source in
                var next = draft, count = 0
                func current(_ values: [AppStoreConnectClient.Resource], _ record: JSONText) -> AppStoreConnectClient.Resource? {
                    values.first { $0.attributes?["locale"]?.string == record["fields"]?["locale"]?.text }
                }
                for version in Self.items(source["versions"]) where version["id"]?.text == plan.baseVersionId {
                    for record in Self.items(version["localizations"]) {
                        guard let apple = current(onTarget, record) else { continue }
                        let base = current(continued, record)
                        count += Self.reuseAppleText(&next, record: record, fields: TextDrafts.versionFields.filter { $0 != "whatsNew" }, target: apple) { field, imported in
                            let there = Apple.text(apple.attributes?[field]) ?? ""
                            guard let imported else { return there }
                            if let base { return Apple.text(base.attributes?[field]) ?? "" }
                            return there.isEmpty ? imported : there
                        }
                    }
                }
                for record in Self.items(source["appInfos"]).flatMap({ Self.items($0["localizations"]) }) {
                    guard let apple = current(information, record) else { continue }
                    count += Self.reuseAppleText(&next, record: record, fields: TextDrafts.appInfoFields, target: apple) { field, _ in Apple.text(apple.attributes?[field]) ?? "" }
                }
                guard count > 0 else { throw Unchanged() }
                return (next, count)
            }
        } catch is Unchanged { return 0 }
    }

    /// Sets each unedited field of one saved language to `wanted`, remembered as App Store Connect's text rather than an edit.
    /// A field is unedited when the draft has no value for it, repeats the import, or still holds text taken from App Store Connect earlier.
    /// `wanted` gets the import's text, or nil when the import has none for the field.
    static func reuseAppleText(_ draft: inout JSONText, record: JSONText, fields: [String], target: AppStoreConnectClient.Resource, wanted: (_ field: String, _ imported: String?) -> String) -> Int {
        guard let id = record["id"]?.text, !id.isEmpty else { return 0 }
        let saved = Dictionary(fieldPairs(record["fields"]), uniquingKeysWith: { _, last in last })
        var texts = draft["texts"]?[id] ?? .object([]), taken = draft["takenAppleText"]?[id] ?? .object([]), count = 0
        for field in fields {
            let imported = saved[field], mine = texts[field]?.text, shown = mine ?? imported ?? ""
            // Keep Mine over Apple's exact text is the person's choice to send this Mac's text.
            if draft["keptAppleText"]?[id]?[field]?.text == JSONText.string(Apple.text(target.attributes?[field]) ?? "").rawSHA256 { continue }
            guard mine == nil || TextSemantics.sameStoreText(shown, imported ?? "") || taken[field]?.text == JSONText.string(shown).rawSHA256 else { continue }
            let value = wanted(field, imported)
            guard value.utf16.count <= 10_000, !TextSemantics.sameStoreText(value, shown) else { continue }
            texts = texts.setting(field, .string(value)); taken = taken.setting(field, .string(JSONText.string(value).rawSHA256)); count += 1
        }
        guard count > 0 else { return 0 }
        draft = draft.setting("texts", (draft["texts"] ?? .object([])).setting(id, texts))
            .setting("takenAppleText", (draft["takenAppleText"] ?? .object([])).setting(id, taken))
        return count
    }

    static func forgettingKept(_ draft: JSONText, localizationId: String, fields: Set<String>) -> JSONText {
        guard case .object(let entries)? = draft["keptAppleText"]?[localizationId] else { return draft }
        return draft.setting("keptAppleText", (draft["keptAppleText"] ?? .object([])).setting(localizationId, .object(entries.filter { !fields.contains($0.0) })))
    }
}
