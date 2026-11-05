import Foundation
import Testing
@testable import StorebenchCore

struct SampleWorkspaceTests {
    private let root: URL
    init() throws { root = try TestIsolation.require() }

    @Test func sampleWorkspaceIsFilledThroughSavesAndHasNoCredentials() async throws {
        let data = root.appendingPathComponent("sample-owner", isDirectory: true)
        let opened = try await SampleWorkspace.open(beside: data, now: Date(timeIntervalSince1970: 1_780_000_000))
        let session = opened.session
        #expect(session.isSample)
        #expect(opened.root.path.hasPrefix(SampleWorkspace.container(beside: data).path))
        #expect(!FileManager.default.fileExists(atPath: data.path))

        let accounts = try await session.accounts()
        #expect(accounts.map(\.id) == [SampleWorkspace.accountId])
        let account = try #require(accounts.first)
        #expect(account.apps.map(\.name) == SampleWorkspace.apps.map(\.name))
        for app in SampleWorkspace.apps {
            let revisions = try await session.revisions(accountId: account.id, appId: app.id)
            #expect(revisions.count == app.changes.count)
            #expect(AsoProgress.rows(revisions).count == app.changes.count)
            #expect(Set(revisions[0].appInfos[0].localizations.compactMap { $0.fields["locale"]?.text }) == Set(app.locales))
            // Every language opens in the language editor, which accepts only Apple-shaped identifiers.
            for revision in revisions { for locale in app.locales { #expect(throws: Never.self) { try LanguageEditorState.selections(revision: revision, versionId: revision.versions[0].id, locale: locale) } } }
            #expect(try await session.salesFileRecords(account: account, appId: app.id).count == 99)
            #expect(try await session.savedAnalyticsFiles(account: account, appId: app.id).partitions.count == 2 * 99)
        }

        // Nothing in the sample can read or write a credential, so nothing can reach Apple.
        await #expect(throws: SampleWorkspace.Failure.sample) { _ = try await session.client(for: account) }
        await #expect(throws: SampleWorkspace.Failure.sample) { _ = try await session.readClient(for: account) }
        await #expect(throws: SampleWorkspace.Failure.sample) { _ = try await session.startSync(account: account, appId: account.appIds[0], mode: .all) }

        // A second owner cannot replace the open sample.
        await #expect(throws: SampleWorkspace.Failure.busy) { _ = try await SampleWorkspace.open(beside: data) }

        try await session.signOut()
        SampleWorkspace.discard(opened)
        #expect(!FileManager.default.fileExists(atPath: opened.root.path))
        #expect(FileManager.default.fileExists(atPath: SampleWorkspace.container(beside: data).appendingPathComponent("sample.mutex").path))
    }
}
