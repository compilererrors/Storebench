import Foundation
import Testing
@testable import StorebenchCore

/// A screenshot in Asset Library can carry a description and tags for AI cards, so choosing it brings its message along.
@Suite(.serialized) struct AssetLibraryDescriptionTests {
    init() throws { _ = try TestIsolation.require() }
    private let app = "1000000001"

    @Test func aScreenshotKeepsADescriptionAndTagsForAICards() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first)
        let file = try await AssetLibraryTests().stage(session, account: account)
        #expect(file.aiDescription.isEmpty && file.tags.isEmpty)
        let described = try await session.describeAssetLibraryFile(accountId: account.id, appId: app, id: file.id,
                                                                   description: "Synthetic dashboard with today's tasks", tags: AssetLibrary.tags(from: "dashboard, Tasks, dashboard,  "))
        #expect(described.aiDescription == "Synthetic dashboard with today's tasks" && described.tags == ["dashboard", "Tasks"])
        let reread = try #require(try await session.assetLibraryFiles(accountId: account.id, appId: app).first { $0.id == file.id })
        #expect(reread == described && reread.hash == file.hash && reread.fileName == file.fileName)
        await #expect(throws: (any Error).self) {
            try await session.describeAssetLibraryFile(accountId: account.id, appId: app, id: file.id, description: String(repeating: "x", count: AssetLibrary.descriptionLimit + 1), tags: [])
        }
        #expect(try await session.assetLibraryFiles(accountId: account.id, appId: app).first { $0.id == file.id } == described, "A rejected change keeps the saved one")
    }

    @Test func tagsAreTrimmedUniqueAndBounded() {
        #expect(AssetLibrary.tags(from: " Tasks ,tasks, Calendar,, ") == ["Tasks", "Calendar"])
        let many = AssetLibrary.tags(from: (0..<20).map { "tag\($0)" }.joined(separator: ","))
        #expect(many.count == AssetLibrary.tagLimit)
        #expect(AssetLibrary.tags(from: String(repeating: "x", count: 80)) == [String(repeating: "x", count: AssetLibrary.tagLength)])
    }
}
