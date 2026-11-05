import CryptoKit
import Foundation
import Testing
@testable import StorebenchCore

@Suite(.serialized) struct AppImportTests {
    init() throws { _ = try TestIsolation.require() }
    func session() throws -> (WorkspaceSession, URL) {
        let root = (try TestIsolation.require()).appendingPathComponent("storebench-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("state-v2"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.copyItem(at: try SyntheticFixtures.database(), to: EncryptedDocumentStore.databaseURL(root: root))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: EncryptedDocumentStore.databaseURL(root: root).path)
        let key = Data(0..<32).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let record = #"{\"schemaVersion\":1,\"phase\":\"ready\",\"envelope\":{\"version\":1,\"mode\":\"device\",\"key\":\"\#(key)\"}}"#
        let vault = try CredentialVault(json: Data(#"{"version":1,"entries":{"\#(CredentialVault.databaseEntry(root: root))":"\#(record)"}}"#.utf8))
        return (try WorkspaceSession(workspace: Workspace(root: root), vault: vault), root)
    }

    static let syntheticBytes: Data = Data((0..<(5 * 1024 * 1024 / 2)).map { UInt8(truncatingIfNeeded: $0 * 31 + 7) })

    @Test func syntheticMediaDecryptsAndWritesUseTheExpectedFileName() async throws {
        let (session, root) = try session(); defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("state-v2/media")
        let name = "80290ebad2a7031b8764d58564a82d5285d0ae19b230af6244e31f4fdba00fa6.sbmedia", target = media.appendingPathComponent(name)
        try FileManager.default.copyItem(at: try SyntheticFixtures.media(), to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        let hash = "a1a81b0201e686d9d62a38c2121217a3d25fe66bf3747a8df8b6de1b1c1ac91b"
        #expect(try await session.mediaBytes(hash) == Self.syntheticBytes)

        try FileManager.default.removeItem(at: target)
        let store = try EncryptedMediaStore(directory: media, key: Data(0..<32))
        let saved = try store.write(Self.syntheticBytes)
        #expect(saved.hash == hash && FileManager.default.fileExists(atPath: target.path))
        #expect(try store.read(hash) == Self.syntheticBytes)
        _ = try store.write(Self.syntheticBytes)
        var bytes = try Data(contentsOf: target); bytes[200] ^= 0xff; try bytes.write(to: target)
        #expect(throws: EncryptedMediaStore.Failure.authentication) { try store.read(hash) }
    }

    @Test func orderedJSONRoundTripsStoredDocuments() throws {
        let text = #"{"b":1,"a":[true,null,-1.5e3,"xå\n\"y🎉"],"c":{"z":"","y":0.1}}"#
        let value = try JSONText.parse(Data(text.utf8))
        #expect(value.stringify() == #"{"b":1,"a":[true,null,-1500,"xå\n\"y🎉"],"c":{"z":"","y":0.1}}"#)
        #expect(throws: JSONText.ParseFailure.self) { try JSONText.parse(Data(#"{"a":1,}"#.utf8)) }
    }

    @Test func importSavesOneRevisionPerChangeAndReusesScreenshots() async throws {
        let (session, root) = try session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first)
        let api = "import.appstoreconnect.test", images = "is1-ssl.mzstatic.com"
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data("synthetic screenshot".utf8)
        nonisolated(unsafe) var description = "A synthetic description."
        func page(_ data: Any) -> (Int, [String: String], Data) { (200, [:], try! JSONSerialization.data(withJSONObject: ["data": data, "links": [:]])) }
        StubProtocol.handle(api) { request in
            switch request.url!.path {
            case "/v1/apps/1000000001": return page(["type": "apps", "id": "1000000001", "attributes": ["name": "Sample App", "bundleId": "example.synthetic.app", "sku": "SYNTHETIC", "primaryLocale": "en-US"]])
            case "/v1/apps/1000000001/assetLibrary": return (404, [:], Data())
            case "/v1/apps/1000000001/appInfos": return page([["type": "appInfos", "id": "info-1", "attributes": ["appStoreState": "READY_FOR_SALE", "state": "READY_FOR_DISTRIBUTION"]]])
            case "/v1/appInfos/info-1/appInfoLocalizations": return page([["type": "appInfoLocalizations", "id": "info-locale-1", "attributes": ["locale": "en-US", "name": "Sample App", "subtitle": NSNull(), "privacyPolicyUrl": "https://example.com/privacy"]]])
            case "/v1/apps/1000000001/appStoreVersions": return page([["type": "appStoreVersions", "id": "version-9", "attributes": ["platform": "IOS", "versionString": "2.0", "appStoreState": "PREPARE_FOR_SUBMISSION", "appVersionState": "PREPARE_FOR_SUBMISSION", "createdDate": "2026-03-01T10:00:00-08:00", "releaseType": "MANUAL"]]])
            case "/v1/appStoreVersions/version-9/appStoreVersionLocalizations": return page([["type": "appStoreVersionLocalizations", "id": "version-locale-9", "attributes": ["locale": "en-US", "description": description, "keywords": "sample,test", "whatsNew": NSNull()]]])
            case "/v1/appStoreVersionLocalizations/version-locale-9/appScreenshotSets": return page([["type": "appScreenshotSets", "id": "set-9", "attributes": ["screenshotDisplayType": "APP_IPHONE_67"]]])
            case "/v1/appScreenshotSets/set-9/appScreenshots": return page([["type": "appScreenshots", "id": "shot-9", "attributes": ["fileName": "first.png", "sourceFileChecksum": "0123456789abcdef0123456789ABCDEF",
                "imageAsset": ["templateUrl": "https://\(images)/image/thumb/synthetic/{w}x{h}bb.{f}", "width": 1290, "height": 2796]]]])
            default: Issue.record("Unexpected request \(request.url!.path)"); return (404, [:], Data())
            }
        }
        StubProtocol.handle(images) { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil && request.url!.path == "/image/thumb/synthetic/1290x2796bb.png")
            return (200, ["Content-Type": "image/png"], png)
        }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubProtocol.self]
        let client = AppStoreConnectClient(token: try AppleToken(account: account, privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation), origin: URL(string: "https://\(api)")!, configuration: configuration)

        let first = try await session.importApp(account: account, appId: "1000000001", client: client)
        #expect(first.changed && first.screenshots == 1)
        let revisions = try await session.revisions(accountId: account.id, appId: "1000000001")
        #expect(revisions.first?.id == first.revisionId && revisions.first?.versions.first?.number == "2.0")
        let shot = try #require(revisions.first?.versions.first?.localizations.first?.screenshotSets.first?.screenshots.first)
        #expect(try await session.mediaBytes(shot.sha256) == png)
        let job = try await session.storeAccess { try $0.document(namespace: "jobs", key: "import:\(account.id):1000000001") }.map { try JSONText.parse($0.payload) }
        #expect(job?["state"]?.text == "complete" && job?["phase"]?.text == "Revision saved" && job?["revisionId"]?.text == first.revisionId)

        let again = try await session.importApp(account: account, appId: "1000000001", client: client)
        #expect(again == ImportResult(revisionId: first.revisionId, changed: false, screenshots: 1))
        #expect(StubProtocol.requests(images).count == 1)

        description = "A changed synthetic description."
        let changed = try await session.importApp(account: account, appId: "1000000001", client: client)
        #expect(changed.changed && changed.revisionId != first.revisionId)
        #expect(try await session.revisions(accountId: account.id, appId: "1000000001").first?.id == changed.revisionId)

        let requestsBeforeRelease = StubProtocol.requests(api).count
        let releaseHistory = try await session.releaseStartingHistory(account: account, appId: "1000000001", client: client)
        #expect(releaseHistory.first?.id == changed.revisionId && releaseHistory.first?.versions.first?.localizations.first?.screenshotSets.first?.screenshots.first?.sha256 == shot.sha256)
        #expect(StubProtocol.requests(api).count == requestsBeforeRelease)
        #expect(StubProtocol.requests(images).count == 1)
        let directory = root.appendingPathComponent("state-v2"), lockName = "import_" + JSONText.string("\(account.id)\u{0}1000000001").rawSHA256.prefix(48)
        let release = try #require(try JobLock.acquire(directory: directory, name: String(lockName), id: UUID().uuidString.lowercased()))
        await #expect(throws: ImportFailure.busy) { try await session.importApp(account: account, appId: "1000000001", client: client) }
        release()
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(lockName).lock").path))
    }

    @Test func importReadsAssetLibraryPlacementsAndFallsBackToTheDeprecatedSetsOnlyWithoutPlacements() async throws {
        let (session, root) = try session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first)
        let api = "library-import.appstoreconnect.test", images = "is2-ssl.mzstatic.com"
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data("synthetic library screenshot".utf8)
        func page(_ data: Any, included: [Any] = []) -> (Int, [String: String], Data) { (200, [:], try! JSONSerialization.data(withJSONObject: ["data": data, "included": included, "links": [:]])) }
        let image: [String: Any] = ["type": "appAssetLibraryImages", "id": "image-1", "attributes": ["fileName": "placed.png", "fileSize": 1000, "category": "APP_SCREENSHOTS_AND_PREVIEWS", "state": "PREPARE_FOR_SUBMISSION", "specId": "spec-iphone",
            "imageAsset": ["templateUrl": "https://\(images)/image/thumb/library/{w}x{h}bb.{f}", "width": 1290, "height": 2796]], "relationships": ["assetLibrary": ["data": ["type": "appAssetLibraries", "id": "library-1"]]]]
        StubProtocol.handle(api) { request in
            switch request.url!.path {
            case "/v1/apps/1000000001": return page(["type": "apps", "id": "1000000001", "attributes": ["name": "Sample App", "bundleId": "example.synthetic.app", "sku": "SYNTHETIC", "primaryLocale": "en-US"]])
            case "/v1/apps/1000000001/appInfos": return page([])
            case "/v1/apps/1000000001/assetLibrary": return page(["type": "appAssetLibraries", "id": "library-1"])
            case "/v1/appAssetLibraries/library-1/images": return page([image])
            case "/v1/apps/1000000001/appStoreVersions": return page([["type": "appStoreVersions", "id": "version-9", "attributes": ["platform": "IOS", "versionString": "2.0", "appVersionState": "PREPARE_FOR_SUBMISSION"]]])
            case "/v1/appStoreVersions/version-9/appStoreVersionLocalizations": return page([["type": "appStoreVersionLocalizations", "id": "locale-en", "attributes": ["locale": "en-US", "description": "Synthetic"]],
                                                                                              ["type": "appStoreVersionLocalizations", "id": "locale-sv", "attributes": ["locale": "sv", "description": "Syntetisk"]]])
            case "/v1/appStoreVersionLocalizations/locale-en/placements":
                return page([["type": "appAssetLibraryPlacements", "id": "placement-1", "attributes": ["mediaType": "IMAGE", "placementType": "APP_SCREENSHOT", "placementGroup": "IPHONE_SYNTHETIC_PROFILE", "state": "PARENT_PREPARE_FOR_SUBMISSION"],
                              "relationships": ["image": ["data": ["type": "appAssetLibraryImages", "id": "image-1"]]]]], included: [image])
            case "/v1/appStoreVersionLocalizations/locale-sv/placements": return page([])
            case "/v1/appStoreVersionLocalizations/locale-sv/appScreenshotSets": return page([["type": "appScreenshotSets", "id": "set-sv", "attributes": ["screenshotDisplayType": "APP_IPHONE_67"]]])
            case "/v1/appScreenshotSets/set-sv/appScreenshots": return page([["type": "appScreenshots", "id": "shot-sv", "attributes": ["fileName": "legacy.png", "sourceFileChecksum": "0123456789abcdef0123456789abcdef", "imageAsset": ["templateUrl": "https://\(images)/image/thumb/legacy/{w}x{h}bb.{f}", "width": 1290, "height": 2796]]]])
            default: Issue.record("Unexpected request \(request.url!.path)"); return (404, [:], Data())
            }
        }
        StubProtocol.handle(images) { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            return (200, ["Content-Type": "image/png"], png)
        }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubProtocol.self]
        let client = AppStoreConnectClient(token: try AppleToken(account: account, privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation), origin: URL(string: "https://\(api)")!, configuration: configuration)
        let result = try await session.importApp(account: account, appId: "1000000001", client: client)
        #expect(result.changed && result.screenshots == 2)
        let saved = try #require(try await session.latestImport(accountId: account.id, appId: "1000000001"))
        let locales = WorkspaceSession.items(WorkspaceSession.items(saved["versions"]).first?["localizations"])
        let placed = try #require(locales.first.flatMap { WorkspaceSession.items($0["screenshotSets"]).first }), legacy = try #require(locales.last.flatMap { WorkspaceSession.items($0["screenshotSets"]).first })
        #expect(placed["id"]?.text == "locale-en-IPHONE_SYNTHETIC_PROFILE" && placed["placementGroup"]?.text == "IPHONE_SYNTHETIC_PROFILE" && placed["displayType"]?.text == "APP_IPHONE_67")
        let shot = try #require(WorkspaceSession.items(placed["screenshots"]).first)
        #expect(shot["id"]?.text == "placement-1" && shot["assetId"]?.text == "image-1" && shot["fileName"]?.text == "placed.png" && shot["sourceFingerprint"]?.text != nil)
        #expect(legacy["id"]?.text == "set-sv" && legacy["placementGroup"] == nil && WorkspaceSession.items(legacy["screenshots"]).first?["id"]?.text == "shot-sv")
        #expect(!StubProtocol.requests(api).contains { $0.url!.path == "/v1/appStoreVersionLocalizations/locale-en/appScreenshotSets" })
        #expect(StubProtocol.requests(api).allSatisfy { $0.httpMethod == "GET" })

        let again = try await session.importApp(account: account, appId: "1000000001", client: client)
        #expect(!again.changed && StubProtocol.requests(images).count == 2)
    }
}
