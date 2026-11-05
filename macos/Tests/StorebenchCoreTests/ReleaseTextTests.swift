import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct ReleaseTextTests {
    init() throws { _ = try TestIsolation.require() }
    func fixture() throws -> JSONText { try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/release-text.json"))) }
    func prepared() async throws -> (WorkspaceSession, URL, ReleasePlan) {
        let (session, root) = try DraftTests().session()
        let account = try #require(try await session.accounts().first)
        let plan = try await session.saveReleasePlan(account: account, appId: "1000000001", start: .reuse,
                                                     sourceRevisionId: "00000000-0000-4000-8000-000000000002", baseVersionId: "version-1", targetVersion: "2.0",
                                                     releaseType: "MANUAL", earliestReleaseDate: nil, expected: "null")
        for locale in ["sv", "fr-FR", "de-DE", "es-ES", "it", "ja"] {
            _ = try await session.addLanguage(accountId: account.id, appId: plan.appId, revisionId: plan.sourceRevisionId, versionId: plan.baseVersionId, locale: locale, copyFrom: nil)
        }
        let original = try await session.textDraft(accountId: account.id, appId: plan.appId, revisionId: plan.sourceRevisionId, localizationId: "version-locale-1", scope: .version)
        var fields = original.fields; fields["whatsNew"] = "Synthetic release wording"; fields["promotionalText"] = "Synthetic promotion"
        try await session.saveTextDraft(accountId: account.id, appId: plan.appId, revisionId: plan.sourceRevisionId, localizationId: "version-locale-1", scope: .version, fields: fields, fingerprint: original.fingerprint)
        return (session, root, plan)
    }
    func snapshot(_ session: WorkspaceSession, _ plan: ReleasePlan) async throws -> ReleaseText.Snapshot {
        try await session.releaseText(accountId: plan.accountId, appId: plan.appId, revisionId: plan.sourceRevisionId, planToken: plan.token)
    }
    func selection(_ snapshot: ReleaseText.Snapshot, _ plan: ReleasePlan) throws -> ReleaseText.Selection {
        let source = try #require(snapshot.rows.first { $0.locale == "en-US" })
        return ReleaseText.Selection(versionId: plan.baseVersionId, sourceLocale: source.locale, sourceBaseline: source.values,
                                     targets: snapshot.rows.filter { $0.id != source.id }.map { ReleaseText.Target(locale: $0.locale, baseline: $0.values, values: source.values, copied: ReleaseText.fields) })
    }
    func preview(_ session: WorkspaceSession, _ plan: ReleasePlan, _ selection: ReleaseText.Selection) async throws -> ReleaseText.Preview {
        try await session.previewReleaseText(accountId: plan.accountId, appId: plan.appId, revisionId: plan.sourceRevisionId, planToken: plan.token, selection: selection)
    }
    func apply(_ session: WorkspaceSession, _ plan: ReleasePlan, _ selection: ReleaseText.Selection, _ preview: ReleaseText.Preview) async throws -> ReleaseText.Preview {
        try await session.applyReleaseText(accountId: plan.accountId, appId: plan.appId, revisionId: plan.sourceRevisionId, planToken: plan.token, selection: selection, fingerprint: preview.fingerprint)
    }

    @Test func changesFingerprintsAndDocumentsMatchWebVectors() throws {
        let vector = try fixture(), source = try JSONDecoder().decode(Revision.self, from: #require(vector["source"]).data)
        let draft = try #require(vector["draft"]), release = try #require(vector["plan"].flatMap(ReleasePlan.init))
        for item in WorkspaceSession.items(vector["vectors"]) {
            let selection = try ReleaseText.Selection(json: item["selection"])
            let plan = try ReleaseText.plan(source: source, draft: draft, selection: selection, release: release)
            #expect(plan.preview.fingerprint == item["fingerprint"]?.text)
            #expect(JSONText.array(plan.preview.changes.map(\.json)).data == item["changes"]?.data)
            #expect(ReleaseText.apply(plan, draft: draft).data == item["applied"]?.data)
        }
    }

    @Test func explicitReplacementExactUnicodeAndCopiedValuesAreEnforced() throws {
        let vector = try fixture(), source = try JSONDecoder().decode(Revision.self, from: #require(vector["source"]).data)
        let draft = try #require(vector["draft"]), release = try #require(vector["plan"].flatMap(ReleasePlan.init))
        let item = try #require(WorkspaceSession.items(vector["vectors"]).dropFirst().first)
        let selection = try ReleaseText.Selection(json: item["selection"])
        let notReplacing = ReleaseText.Selection(versionId: selection.versionId, sourceLocale: selection.sourceLocale, sourceBaseline: selection.sourceBaseline, targets: selection.targets)
        #expect(throws: ReleaseTextFailure.replacement) { try ReleaseText.plan(source: source, draft: draft, selection: notReplacing, release: release) }
        let row = try #require(selection.targets.first)
        let stale = ReleaseText.Selection(versionId: selection.versionId, sourceLocale: selection.sourceLocale, sourceBaseline: selection.sourceBaseline,
                                         targets: [.init(locale: row.locale, baseline: .init(whatsNew: row.baseline.whatsNew, promotionalText: "é"), values: row.values)], replaceExisting: true)
        #expect(throws: ReleaseTextFailure.stale) { try ReleaseText.plan(source: source, draft: draft, selection: stale, release: release) }
        let overLimit = ReleaseText.Selection(versionId: selection.versionId, sourceLocale: selection.sourceLocale, sourceBaseline: selection.sourceBaseline,
                                             targets: [.init(locale: row.locale, baseline: row.baseline, values: .init(whatsNew: String(repeating: "a", count: 4001)))], replaceExisting: true)
        #expect(throws: ReleaseTextFailure.limit) { try ReleaseText.plan(source: source, draft: draft, selection: overLimit, release: release) }
        let fakeCopy = ReleaseText.Selection(versionId: selection.versionId, sourceLocale: selection.sourceLocale, sourceBaseline: selection.sourceBaseline,
                                            targets: [.init(locale: row.locale, baseline: row.baseline, values: .init(whatsNew: "Synthetic edited wording"), copied: ["whatsNew"])], replaceExisting: true)
        #expect(throws: ReleaseTextFailure.copied) { try ReleaseText.plan(source: source, draft: draft, selection: fakeCopy, release: release) }
        let duplicate = ReleaseText.Selection(versionId: selection.versionId, sourceLocale: selection.sourceLocale, sourceBaseline: selection.sourceBaseline, targets: [row, row], replaceExisting: true)
        #expect(throws: ReleaseTextFailure.invalid) { try ReleaseText.plan(source: source, draft: draft, selection: duplicate, release: release) }
        let wrongField = ReleaseText.Selection(versionId: selection.versionId, sourceLocale: selection.sourceLocale, sourceBaseline: selection.sourceBaseline,
                                              targets: [.init(locale: row.locale, baseline: row.baseline, values: row.values, copied: ["description"])], replaceExisting: true)
        #expect(throws: ReleaseTextFailure.invalid) { try ReleaseText.plan(source: source, draft: draft, selection: wrongField, release: release) }
    }

    @Test func copyingUsesWebWhitespaceAndPreservesManualWordingByDefault() {
        let source = ReleaseText.Values(whatsNew: "\u{0085}", promotionalText: "\u{feff}")
        let filled = ReleaseText.Values(whatsNew: "Synthetic working wording", promotionalText: "Synthetic promotion")
        #expect(ReleaseText.copySource(source, into: filled, replace: false).copied.isEmpty)
        let replaced = ReleaseText.copySource(source, into: filled, replace: true)
        #expect(replaced.copied == ["whatsNew"] && replaced.values.whatsNew == "\u{0085}" && replaced.values.promotionalText == filled.promotionalText)
        let empty = ReleaseText.copySource(.init(whatsNew: "Synthetic source", promotionalText: "Synthetic promotion"), into: .init(whatsNew: "\u{feff}"), replace: false)
        #expect(empty.copied == ReleaseText.fields)
    }

    @Test func typedEditsReplaceFilledTextButCopyingOverFilledTextNeedsReplace() {
        let filled = ReleaseText.Values(whatsNew: "Synthetic saved wording", promotionalText: "Synthetic saved promotion")
        let typed = ReleaseText.Target(locale: "sv", baseline: filled, values: .init(whatsNew: "Synthetic typed wording", promotionalText: filled.promotionalText))
        let copiedIntoEmpty = ReleaseText.Target(locale: "fr-FR", baseline: .init(), values: .init(whatsNew: "Synthetic source"), copied: ["whatsNew"])
        let copiedOverFilled = ReleaseText.Target(locale: "de-DE", baseline: filled, values: .init(whatsNew: "Synthetic source", promotionalText: filled.promotionalText), copied: ["whatsNew"])
        #expect(ReleaseText.replacesExisting([typed, copiedIntoEmpty], replace: false))
        #expect(!ReleaseText.replacesExisting([typed, copiedOverFilled], replace: false))
        #expect(ReleaseText.replacesExisting([copiedOverFilled], replace: true))
    }

    @Test func sixLanguageReviewIsReadOnlyAndSavesExactlyItsFields() async throws {
        let (session, root, plan) = try await prepared(); defer { try? FileManager.default.removeItem(at: root) }
        let before = try await snapshot(session, plan), chosen = try selection(before, plan), review = try await preview(session, plan, chosen)
        #expect(review.changes.count == 12)
        let unchanged = try await snapshot(session, plan)
        #expect(unchanged.rows.map(\.values) == before.rows.map(\.values))
        let target = try #require(before.rows.first { $0.locale == "sv" })
        let prior = try await session.textDraft(accountId: plan.accountId, appId: plan.appId, revisionId: plan.sourceRevisionId, localizationId: target.id, scope: .version)
        var extra = prior.fields; extra["keywords"] = "synthetic,retained"
        try await session.saveTextDraft(accountId: plan.accountId, appId: plan.appId, revisionId: plan.sourceRevisionId, localizationId: target.id, scope: .version, fields: extra, fingerprint: prior.fingerprint)
        _ = try await apply(session, plan, chosen, review)
        let saved = try await session.textDraft(accountId: plan.accountId, appId: plan.appId, revisionId: plan.sourceRevisionId, localizationId: target.id, scope: .version)
        #expect(saved.fields["keywords"] == "synthetic,retained" && saved.fields["whatsNew"] == chosen.sourceBaseline.whatsNew)
        let after = try await snapshot(session, plan)
        #expect(after.rows.first { $0.locale == "sv" }?.reviews["whatsNew"]?.needsReview == false)
        await #expect(throws: ReleaseTextFailure.stale) { try await apply(session, plan, chosen, review) }
        await #expect(throws: RevisionHistoryFailure.invalid) { try await session.releaseText(accountId: "synthetic-other-account", appId: plan.appId, revisionId: plan.sourceRevisionId, planToken: plan.token) }
    }

    @Test func sourceDestinationMarkerAndPlanChangesRejectOldReviews() async throws {
        let (session, root, plan) = try await prepared(); defer { try? FileManager.default.removeItem(at: root) }
        var before = try await snapshot(session, plan), chosen = try selection(before, plan), review = try await preview(session, plan, chosen)
        let original = try await session.textDraft(accountId: plan.accountId, appId: plan.appId, revisionId: plan.sourceRevisionId, localizationId: "version-locale-1", scope: .version)
        var fields = original.fields; fields["whatsNew"] = "Later synthetic source"
        try await session.saveTextDraft(accountId: plan.accountId, appId: plan.appId, revisionId: plan.sourceRevisionId, localizationId: "version-locale-1", scope: .version, fields: fields, fingerprint: original.fingerprint)
        await #expect(throws: ReleaseTextFailure.stale) { try await apply(session, plan, chosen, review) }
        before = try await snapshot(session, plan); chosen = try selection(before, plan); review = try await preview(session, plan, chosen)
        let target = try #require(before.rows.first { $0.locale == "sv" })
        let prior = try await session.textDraft(accountId: plan.accountId, appId: plan.appId, revisionId: plan.sourceRevisionId, localizationId: target.id, scope: .version)
        var local = prior.fields; local["promotionalText"] = "Local synthetic wording"
        let saved = try await session.saveTextDraft(accountId: plan.accountId, appId: plan.appId, revisionId: plan.sourceRevisionId, localizationId: target.id, scope: .version, fields: local, fingerprint: prior.fingerprint)
        await #expect(throws: ReleaseTextFailure.stale) { try await apply(session, plan, chosen, review) }
        try await session.saveTextDraft(accountId: plan.accountId, appId: plan.appId, revisionId: plan.sourceRevisionId, localizationId: target.id, scope: .version, fields: prior.fields, fingerprint: saved)
        before = try await snapshot(session, plan); chosen = try selection(before, plan); review = try await preview(session, plan, chosen)
        try await session.mutateDraft(accountId: plan.accountId, appId: plan.appId, revisionId: plan.sourceRevisionId) { draft, _ in
            let sources = draft["textSources"] ?? .object([])
            let marker = JSONText.object([("revisionId", .string(plan.sourceRevisionId)), ("localizationId", .string("version-locale-1")), ("copiedValue", .string("Earlier synthetic value")), ("reviewedValue", .string("Earlier synthetic value"))])
            return (draft.setting("textSources", sources.setting(target.id, .object([("whatsNew", marker)]))), ())
        }
        await #expect(throws: ReleaseTextFailure.stale) { try await apply(session, plan, chosen, review) }
        review = try await preview(session, plan, chosen)
        let account = try #require(try await session.accounts().first)
        _ = try await session.saveReleasePlan(account: account, appId: plan.appId, start: .reuse, sourceRevisionId: plan.sourceRevisionId, baseVersionId: plan.baseVersionId,
                                            targetVersion: "2.1", releaseType: "MANUAL", earliestReleaseDate: nil, expected: plan.token)
        await #expect(throws: ReleaseTextFailure.stale) { try await apply(session, plan, chosen, review) }
        let preserved = try await session.textDraft(accountId: plan.accountId, appId: plan.appId, revisionId: plan.sourceRevisionId, localizationId: target.id, scope: .version)
        #expect(preserved.fields["whatsNew"] == "" && preserved.fields["promotionalText"] == "")
    }

    @Test func manualWordingRemovesOnlyItsCopiedMarker() throws {
        let vector = try fixture(), source = try JSONDecoder().decode(Revision.self, from: #require(vector["source"]).data)
        let draft = try #require(vector["copiedDraft"]), release = try #require(vector["plan"].flatMap(ReleasePlan.init))
        let selection = ReleaseText.Selection(versionId: "version-1", sourceLocale: "en-US", sourceBaseline: .init(whatsNew: "Later synthetic source", promotionalText: "é"),
                                             targets: [.init(locale: "fr-FR", baseline: .init(whatsNew: "\u{0085}", promotionalText: "é"), values: .init(whatsNew: "Synthetic translation", promotionalText: "é"))], replaceExisting: true)
        let result = ReleaseText.apply(try ReleaseText.plan(source: source, draft: draft, selection: selection, release: release), draft: draft)
        #expect(result["textSources"]?["synthetic-fr-FR"]?["whatsNew"] == nil)
        #expect(result["textSources"]?["synthetic-fr-FR"]?["promotionalText"] == draft["textSources"]?["synthetic-fr-FR"]?["promotionalText"])
        #expect(result["texts"]?["synthetic-de-DE"] == draft["texts"]?["synthetic-de-DE"])
    }

    @Test func concurrentSessionsConsumeOneReviewedDraftBaseline() async throws {
        let (session, root, plan) = try await prepared(); defer { try? FileManager.default.removeItem(at: root) }
        let key = Data(0..<32).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let record = JSONText.object([("schemaVersion", .number(1)), ("phase", .string("ready")), ("envelope", .object([("version", .number(1)), ("mode", .string("device")), ("key", .string(key))]))])
        let vault = try CredentialVault(json: JSONText.object([("version", .number(1)), ("entries", .object([(CredentialVault.databaseEntry(root: root), .string(record.stringify()))]))]).data)
        let second = try WorkspaceSession(workspace: Workspace(root: root), vault: vault)
        let loaded = try await snapshot(session, plan), chosen = try selection(loaded, plan), review = try await preview(session, plan, chosen)
        let successes = try await withThrowingTaskGroup(of: Bool.self) { group in
            for owner in [session, second] {
                group.addTask { () async throws -> Bool in
                    do { _ = try await apply(owner, plan, chosen, review); return true }
                    catch ReleaseTextFailure.stale { return false }
                }
            }
            var count = 0
            for try await success in group { if success { count += 1 } }
            return count
        }
        #expect(successes == 1)
        let saved = try await snapshot(second, plan)
        #expect(saved.rows.filter { $0.locale != "en-US" }.allSatisfy { ReleaseText.Values.same($0.values, chosen.sourceBaseline) })
    }

    @Test func releaseSourceAcknowledgementChecksThePlanAndLeavesTextUntouched() async throws {
        let (session, root, plan) = try await prepared(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try await snapshot(session, plan), chosen = try selection(first, plan), review = try await preview(session, plan, chosen)
        _ = try await apply(session, plan, chosen, review)
        let source = try await session.textDraft(accountId: plan.accountId, appId: plan.appId, revisionId: plan.sourceRevisionId, localizationId: "version-locale-1", scope: .version)
        var fields = source.fields; fields["whatsNew"] = "Later synthetic release source"
        try await session.saveTextDraft(accountId: plan.accountId, appId: plan.appId, revisionId: plan.sourceRevisionId, localizationId: "version-locale-1", scope: .version, fields: fields, fingerprint: source.fingerprint)
        let changed = try await snapshot(session, plan), destination = try #require(changed.rows.first { $0.locale == "sv" })
        let comparison = try #require(destination.reviews["whatsNew"])
        #expect(comparison.needsReview && destination.reviews["promotionalText"]?.needsReview == false)
        try await session.acknowledgeReleaseTextSource(accountId: plan.accountId, appId: plan.appId, revisionId: plan.sourceRevisionId, planToken: plan.token, review: comparison)
        let acknowledged = try await snapshot(session, plan)
        #expect(acknowledged.rows.first { $0.id == destination.id }?.values == destination.values)
        #expect(acknowledged.rows.first { $0.id == destination.id }?.reviews["whatsNew"]?.needsReview == false)
        let another = try #require(changed.rows.first { $0.locale == "fr-FR" }?.reviews["whatsNew"])
        try await session.removeReleasePlan(accountId: plan.accountId, appId: plan.appId, expected: plan.token)
        await #expect(throws: ReleaseTextFailure.stale) { try await session.acknowledgeReleaseTextSource(accountId: plan.accountId, appId: plan.appId, revisionId: plan.sourceRevisionId, planToken: plan.token, review: another) }
    }
}
