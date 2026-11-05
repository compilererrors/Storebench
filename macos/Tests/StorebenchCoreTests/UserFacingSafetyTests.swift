import CryptoKit
import Foundation
import Testing
@testable import StorebenchCore

/// Synthetic end-to-end guards for totals, key setup, account switching, archive imports and Apple text rules.
@Suite(.serialized) struct UserFacingSafetyTests {
    init() throws { _ = try TestIsolation.require() }

    // MARK: Sales and proceeds

    private func dailyRecords(from first: Int, count: Int, row: [String]) throws -> [SalesRecord] {
        let columns = ["Apple Identifier", "Product Type Identifier", "Units", "Country Code", "Customer Price", "Begin Date", "End Date", "Developer Proceeds", "Currency of Proceeds"]
        return try (first..<first + count).map { number in
            let parts = PeriodDates.text(number).split(separator: "-"), day = "\(parts[1])/\(parts[2])/\(parts[0])"
            let table = ReportTable(columns: columns, rows: [Array(row.prefix(5)) + [day, day] + Array(row.suffix(2))])
            return try SalesReports.summary(table, appId: "1000000001", accountId: "synthetic-account", importedAt: "2026-10-19T12:00:00.000Z", appSku: "synthetic-app", scope: ProductScope(ids: ["2000000001"], complete: true))
        }
    }

    @Test func undeliveredFinalDaysOfANinetyDayRangeStayUnknownAndNeverCompleteTheTotal() throws {
        let begin = try #require(PeriodDates.number("2026-07-21")), range = try SalesPresentation.Range(beginDate: "2026-07-21", endDate: "2026-10-18")
        // Apple has delivered 87 of the 90 requested days; each paid unit costs 4.99 and earns 3.49 Developer Proceeds.
        let paid = try SalesPresentation.prepare(dailyRecords(from: begin, count: 87, row: ["1000000001", "1", "2", "US", "4.99", "3.49", "USD"]), accountId: "synthetic-account", appId: "1000000001")
        let selected = try SalesPresentation.select(paid, range: range)
        #expect(selected.requestedDays == 90 && selected.coveredDays == 87 && selected.missingDays == ["2026-10-16", "2026-10-17", "2026-10-18"])
        #expect(!selected.complete && !selected.moneyComplete)
        #expect(selected.analysis.paid == 174 && selected.analysis.coverage?.hasGaps == false)
        // Undelivered days produce no trend points rather than zero-valued days.
        #expect(SalesPresentation.series(selected.analysis, measure: .paid).count == 87)
        #expect(SalesPresentation.series(selected.analysis, measure: .paid).allSatisfy { $0.value == 2 })
        // Totals use Developer Proceeds, never the customer price.
        #expect(selected.analysis.proceeds.map(\.currency) == ["USD"])
        #expect(ReportDecimal(try #require(selected.analysis.proceeds.first).amount) == ReportDecimal("607.26"))
        #expect(ReportDecimal(try #require(selected.analysis.proceeds.first).amount) != ReportDecimal("868.26"))
        let context = ReportMoney.Context(currency: "USD"), converted = ReportMoney.convert(selected.analysis.proceeds, context: context)
        #expect(SalesPresentation.estimateText(converted, context: context, complete: selected.moneyComplete, available: true).hasSuffix(" · Partial"))
        let csv = String(decoding: SalesPresentation.analysisCSV(selected, context: context), as: UTF8.self), lines = csv.split(whereSeparator: \.isNewline)
        let header = try #require(lines.first).split(separator: ",").map(String.init), row = try #require(lines.dropFirst().first).split(separator: ",").map(String.init)
        let estimated = try #require(header.firstIndex(of: "estimate_complete")), covered = try #require(header.firstIndex(of: "covered_days"))
        #expect(row[estimated] == "false" && row[covered] == "87")
        #expect(header.contains("reported_proceeds") && !header.contains { $0.contains("revenue") || $0.contains("customer_price") || $0 == "sales" })
        let freshness = SalesPresentation.freshness(paid, completedThrough: "2026-10-18")
        #expect(freshness.latestSavedDay == "2026-10-15" && freshness.daysAfterLatest == 3 && freshness.message.contains("Totals may be lower"))

        // A free-only app has no proceeds; with missing days that is unknown, not "No proceeds reported".
        let free = try SalesPresentation.prepare(dailyRecords(from: begin, count: 87, row: ["1000000001", "1", "3", "US", "0", "0", "USD"]), accountId: "synthetic-account", appId: "1000000001")
        let quiet = try SalesPresentation.select(free, range: range)
        #expect(quiet.analysis.proceeds.isEmpty && quiet.analysis.moneyComplete && !quiet.moneyComplete)
        #expect(SalesPresentation.proceedsText(quiet.analysis.proceeds, complete: quiet.moneyComplete) != "No proceeds reported")
        let whole = try SalesPresentation.select(free, range: .init(beginDate: "2026-07-21", endDate: "2026-10-15"))
        #expect(whole.complete && whole.moneyComplete && SalesPresentation.proceedsText(whole.analysis.proceeds, complete: whole.moneyComplete) == "No proceeds reported")

        let portfolio = try SalesPortfolio.analyze([.init(accountId: "synthetic-account", appId: "1000000001", title: "Synthetic app", periods: paid)], range: range)
        let app = try #require(portfolio.rows.first)
        #expect(app.coveredDays == 87 && !app.complete && portfolio.completeApps == 0 && !portfolio.moneyComplete)

        // Unit measures never present proceeds, revenue or sales amounts; the proceeds chart says which amount it shows.
        #expect(SalesPresentation.Measure.allCases.allSatisfy { measure in ["roceeds", "evenue", "Sales", "price"].allSatisfy { !measure.label.contains($0) } })
        let chart = try #require(try ReportCharts.salesProceeds(paid, currency: "USD").first)
        #expect(chart.label == "Reported proceeds · USD" && chart.points.count == 87)
    }

    // MARK: Account setup

    @Test func keySetupFailuresNameTheRequiredKeyType() throws {
        let root = try TestIsolation.require(), key = P256.Signing.PrivateKey(), pem = key.pemRepresentation
        for wrong in ["", "synthetic text, not a key", "-----BEGIN CERTIFICATE-----\nU3ludGhldGlj\n-----END CERTIFICATE-----\n", P384.Signing.PrivateKey().pemRepresentation,
                      key.publicKey.pemRepresentation, pem.replacingOccurrences(of: "PRIVATE KEY-----\n", with: "PRIVATE KEY-----\nAAAA")] {
            #expect(throws: AccountFailure.keyContent) { try AppleAccountInputs.privateKey(wrong) }
            #expect(throws: AccountFailure.keyContent) { try AppleAccountInputs.account(name: "", keyType: "individual", issuerId: nil, keyId: "SYNTH12345", pem: wrong) }
        }
        #expect(AccountFailure.keyContent.message.contains("Individual API key") && AccountFailure.keyContent.message.contains("Team API key"))

        // In-App Purchase keys are valid P-256 files too; Apple's download name identifies them.
        let purchase = root.appendingPathComponent("SubscriptionKey_SYNTH12345.p8"), api = root.appendingPathComponent("AuthKey_SYNTH12345.p8")
        defer { try? FileManager.default.removeItem(at: purchase); try? FileManager.default.removeItem(at: api) }
        try Data(pem.utf8).write(to: purchase); try Data(pem.utf8).write(to: api)
        #expect(throws: AccountFailure.purchaseKey) { try AppleAccountInputs.privateKeyFile(purchase) }
        #expect(AppleAccountInputs.keyId(filename: purchase.lastPathComponent) == nil)
        #expect(try AppleAccountInputs.privateKeyFile(api) == pem && AppleAccountInputs.keyId(filename: api.lastPathComponent) == "SYNTH12345")
        let purchaseMessage = AccountFailure.purchaseKey.message
        #expect(purchaseMessage.contains("In-App Purchase key") && purchaseMessage.contains("Individual API key or Team API key"))

        for issuer in [nil, "", "   ", "not-an-issuer"] as [String?] {
            #expect(throws: AccountFailure.issuerRequired) { try AppleAccountInputs.account(name: "", keyType: "team", issuerId: issuer, keyId: "SYNTH12345", pem: pem) }
        }
        #expect(AccountFailure.issuerRequired.message.contains("Team API key needs its Issuer ID"))
        let team = try AppleAccountInputs.account(name: "", keyType: "team", issuerId: "00000000-0000-4000-8000-00000000000a", keyId: "SYNTH12345", pem: pem)
        #expect(team.issuerId == "00000000-0000-4000-8000-00000000000a")
        #expect(AccountFailure.auth.message.contains("Team API key") && AccountFailure.auth.message.contains("Individual API key"))

        // Pasted text keeps the key while adding, removing or changing line breaks.
        let lines = pem.split(whereSeparator: \.isNewline).map(String.init), body = lines.dropFirst().dropLast().joined()
        let narrow = stride(from: 0, to: body.count, by: 40).map { String(body.dropFirst($0).prefix(40)) }
        let pasted: [String] = [
            lines.joined(separator: "\r\n\r\n") + "\r\n",
            "\n\n" + lines.map { "  " + $0 + " " }.joined(separator: "\n\n") + "\n\n",
            [lines[0], body, lines[lines.count - 1]].joined(separator: "\n"),
            ([lines[0]] + narrow + [lines[lines.count - 1]]).joined(separator: "\n"),
        ]
        for text in pasted {
            let accepted = try AppleAccountInputs.privateKey(text)
            #expect(try P256.Signing.PrivateKey(pemRepresentation: accepted).rawRepresentation == key.rawRepresentation)
            #expect(try AppleAccountInputs.account(name: "", keyType: "individual", issuerId: nil, keyId: "SYNTH12345", pem: text).keyId == "SYNTH12345")
        }
        #expect(try AppleAccountInputs.privateKey(pem) == pem)
    }

    @Test func pastedKeyIsSavedInItsParsedFormAndWrongContentWritesNothing() async throws {
        let lifecycle = try AccountLifecycleTests(), f = try await lifecycle.fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let key = P256.Signing.PrivateKey(), lines = key.pemRepresentation.split(whereSeparator: \.isNewline).map(String.init)
        let pasted = lines.joined(separator: "\r\n\r\n") + "\r\n", host = "account-pasted.appstoreconnect.test"
        let page = lifecycle.page(["1000000003"], name: "Synthetic pasted app")
        StubProtocol.handle(host) { _ in (200, [:], page) }
        let before = try f.writer.read().entries
        await #expect(throws: AccountFailure.keyContent) {
            try await f.session.connectAccount(name: "", keyType: "individual", issuerId: nil, keyId: "SYNTH12345", privateKeyPEM: "synthetic text", writer: f.writer, origin: URL(string: "https://\(host)")!, configuration: lifecycle.configuration())
        }
        await #expect(throws: AccountFailure.issuerRequired) {
            try await f.session.connectAccount(name: "", keyType: "team", issuerId: "", keyId: "SYNTH12345", privateKeyPEM: pasted, writer: f.writer, origin: URL(string: "https://\(host)")!, configuration: lifecycle.configuration())
        }
        #expect(try f.writer.read().entries == before)
        let account = try await f.session.connectAccount(name: "", keyType: "individual", issuerId: nil, keyId: "SYNTH12345", privateKeyPEM: pasted, writer: f.writer, origin: URL(string: "https://\(host)")!, configuration: lifecycle.configuration())
        let saved = try #require(try f.writer.read().entries["apple:\(account.id)"])
        #expect(try P256.Signing.PrivateKey(pemRepresentation: saved).rawRepresentation == key.rawRepresentation)
        #expect(account.apps == [.init(id: "1000000003", name: "Synthetic pasted app")])
    }

    // MARK: Account and app switching

    @Test func switchingAccountOrAppCarriesNoVersionOrReleasePlanContext() throws {
        let first = try RecoveryGuidance.Scope(accountId: "synthetic-individual", appId: "1000000001")
        let sameAccount = try RecoveryGuidance.Scope(accountId: "synthetic-individual", appId: "1000000002")
        let otherAccount = try RecoveryGuidance.Scope(accountId: "synthetic-team", appId: "1000000001")
        let context = try AppNavigation.Context(scope: first, locale: "sv", version: "version-a", draft: true)
        for target in [sameAccount, otherAccount] {
            for section in AppNavigation.Section.allCases {
                for switching in [true, false] {
                    let destination = AppNavigation.Destination(source: first, scope: target, section: section, context: context, switchingApp: switching)
                    #expect(destination.context?.version == nil && destination.context?.draft != true)
                    #expect(!destination.href.contains("version=") && !destination.href.contains("draft=1") && destination.href.hasPrefix(target.root))
                }
            }
        }
        // A carried release-plan context cannot select or filter the next app's versions.
        let next = Revision.Version(id: "version-b", fields: [:], localizations: [.init(id: "next-en", fields: ["locale": .text("en-US")], screenshotSets: [])])
        let selection = AppNavigation.selection(scope: otherAccount, versions: [next], appInfos: [], context: context, section: .localizations, planVersionId: "version-a")
        #expect(selection.versionId == "version-b" && selection.locale == "en-US")

        // The same app ID in two accounts keeps each account's name and release plan.
        let individual = Account(id: first.accountId, name: "Synthetic individual", keyId: "SYNTHKEY01", keyType: "individual", issuerId: nil, appIds: ["1000000001"], appNames: ["1000000001": "Synthetic A"])
        let teamAccount = Account(id: otherAccount.accountId, name: "Synthetic team", keyId: "SYNTHKEY02", keyType: "team", issuerId: "00000000-0000-4000-8000-00000000000b", appIds: ["1000000001"], appNames: ["1000000001": "Synthetic B"])
        let rows = try [individual, teamAccount].map { account in try ConnectedApps.Row(account: account, app: #require(account.apps.first), savedName: nil, revisionCount: 1) }
        let plan = JSONText.object([("accountId", .string(first.accountId)), ("appId", .string("1000000001")), ("sourceRevisionId", .string("00000000-0000-4000-8000-000000000002")),
                                    ("baseVersionId", .string("version-a")), ("platform", .string("IOS")), ("targetVersion", .string("2.0")), ("updatedAt", .string("2026-10-01T00:00:00.000Z"))])
        let snapshot = try LibraryOverview.Snapshot(apps: rows, plans: LibraryOverview.plans([plan]), accountCount: 2)
        #expect(snapshot.releases.count == 1 && snapshot.releases.first?.app.account.id == first.accountId && snapshot.releases.first?.title == "Synthetic A · 2.0")
        #expect(rows.map(\.name) == ["Synthetic A", "Synthetic B"])
    }

    @Test func refreshedAppListReplacesNamesTogether() async throws {
        let lifecycle = try AccountLifecycleTests(), f = try await lifecycle.fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let host = "account-replaced.appstoreconnect.test", client = try lifecycle.client(f, host: host)
        let page = try JSONSerialization.data(withJSONObject: ["data": [["type": "apps", "id": "1000000007", "attributes": ["name": "Synthetic replacement"]], ["type": "apps", "id": "1000000008", "attributes": [:]]], "links": [:]])
        StubProtocol.handle(host) { _ in (200, [:], page) }
        let refreshed = try await f.session.refreshAccountApps(f.account, client: client)
        let saved = try #require(try await f.session.accounts().first { $0.id == f.account.id })
        let expected: [Account.App] = [.init(id: "1000000007", name: "Synthetic replacement"), .init(id: "1000000008", name: "App 1000000008")]
        #expect(refreshed.apps == expected && saved.apps == expected)
        #expect(Set(saved.appNames?.keys.map { $0 } ?? []) == ["1000000007"])
    }

    // MARK: Fastlane imports

    @Test func fastlaneArchivesMissingAppInformationOrALanguageNeverPlanADeletion() async throws {
        let vector = try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/fastlane.json")))
        let source = try JSONDecoder().decode(Revision.self, from: try #require(vector["source"]).data)
        var draft = try #require(vector["draft"])
        draft = try WorkspaceSession.addingLanguage(draft, source: source, revisionId: source.id, versionId: "version-1", locale: "sv", copyFrom: "en-US").0
        let before = Transfer.materialTable(.languages, source: source, draft: draft, versionId: "version-1")
        #expect(Set(before.rows.map { $0[2] }) == ["en-US", "sv"] && before.rows.contains { $0[3] == "appInfo" })

        // No app information files and no Swedish folder: only the provided English version text may change.
        let archive = FastlaneMetadata.storedZip([("fastlane/metadata/en-US/description.txt", Data("Synthetic replacement description".utf8)),
                                                  ("fastlane/metadata/en-US/keywords.txt", Data("synthetic,sample".utf8))])
        let parsed = try FastlaneMetadata.parse(archive, appId: "1000000001", versionId: "version-1")
        #expect(parsed.locales == ["en-US"] && parsed.clears == 0)
        #expect(["en-US/name.txt", "en-US/subtitle.txt", "en-US/privacy_url.txt"].allSatisfy(parsed.omitted.contains))
        let result = try Transfer.importMaterials(.languages, parsed.table, source: source, draft: draft, versionId: "version-1")
        let after = Transfer.materialTable(.languages, source: source, draft: result.draft, versionId: "version-1")
        func keyed(_ table: Delimited.Table) -> [String: String] { Dictionary(uniqueKeysWithValues: table.rows.map { ($0[2...4].joined(separator: "/"), $0[5]) }) }
        let old = keyed(before), new = keyed(after)
        #expect(Set(new.keys) == Set(old.keys) && result.added == 0)
        let changed = Set(old.keys.filter { old[$0] != new[$0] })
        #expect(changed == ["en-US/version/description", "en-US/version/keywords"])
        #expect(Transfer.changes(.languages, before: before, after: after).allSatisfy { !$0.after.isEmpty })

        // The workspace review shows the same two changes for the saved fixture revision.
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first)
        let preview = try await session.importFastlaneMetadata(account: account, appId: "1000000001", versionId: "version-1", archive: archive, revisionId: "00000000-0000-4000-8000-000000000002")
        #expect(!preview.transfer.saved && preview.transfer.added == 0 && preview.transfer.changes.count == 2 && preview.transfer.changes.allSatisfy { !$0.after.isEmpty })
    }

    // MARK: Text Apple rejects

    @Test func controlCharactersInWhatToTestKeywordsAndPromotionalTextAreCaughtBeforeReview() throws {
        for bad in ["Synthetic\u{0}notes", "Synthetic\u{7}notes", "Synthetic\u{7f}notes", "Synthetic\u{1b}[0mnotes"] {
            #expect(throws: PublishFailure.self) { try TestFlightMetadata.text(bad, label: "What to Test text") }
            for field in ["keywords", "promotionalText", "whatsNew"] {
                #expect(throws: PublishFailure.self) { try WorkspaceSession.publishedText([(field, bad)], appInfo: false) }
            }
        }
        for good in ["Synthetic notes\nwith a second line\tand a tab", "Synthetic notes 🎉 å"] {
            #expect(try TestFlightMetadata.text(good, label: "What to Test text") == good)
            #expect(try WorkspaceSession.publishedText([("promotionalText", good)], appInfo: false).first?.1 == good)
        }
        #expect(try WorkspaceSession.publishedText([("keywords", "synthetic,sample")], appInfo: false).first?.1 == "synthetic,sample")

        // The release check reports the same characters before a Publish review is prepared.
        let fixture = try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/release-readiness.json")))
        guard case .array(let cases)? = fixture["material"], let item = cases.first else { Issue.record("Missing synthetic release fixture"); return }
        let source = try #require(item["source"]), draft = try #require(item["draft"]), versionId = try #require(item["versionId"]?.text)
        let version = try #require(WorkspaceSession.items(source["versions"]).first { $0["id"]?.text == versionId })
        let localization = try #require(WorkspaceSession.items(version["localizations"]).first?["id"]?.text)
        for field in ["keywords", "promotionalText"] {
            let texts = JSONText.object([(localization, .object([(field, .string("synthetic\u{7f}value"))]))])
            let languages = try ReleaseMaterial.languages(source: source, draft: draft.setting("texts", texts), versionId: versionId)
            #expect(languages.contains { $0.issues.contains { $0.field == field && $0.message.hasSuffix("remove control characters") } })
        }
    }
}
