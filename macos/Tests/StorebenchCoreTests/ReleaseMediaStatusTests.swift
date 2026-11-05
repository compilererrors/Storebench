import CryptoKit
import Foundation
import Testing
@testable import StorebenchCore

@Suite struct ReleaseMediaStatusTests {
    init() throws { _ = try TestIsolation.require() }
    private func sets(_ value: JSONText?) throws -> [ReleaseMediaStatus.MediaSet] {
        guard case .array(let values)? = value else { throw ReleaseReadiness.Failure.invalid }
        return try values.map { item in
            guard let type = item["displayType"]?.text, let items = item["items"] else { throw ReleaseReadiness.Failure.invalid }
            return .init(displayType: type, items: try JSONDecoder().decode([AppStoreConnectClient.Resource].self, from: items.data))
        }
    }
    @Test func deliveryOrderAndExactAssetEvidenceMatchThePrimaryStatus() throws {
        let fixture = try JSONText.parse(Data(contentsOf: TestIsolation.require().appendingPathComponent("native-fixtures/release-readiness.json")))
        guard case .array(let values)? = fixture["media"] else { throw ReleaseReadiness.Failure.invalid }
        #expect(values.count >= 26)
        for item in values {
            let locale = try #require(item["locale"]), draft = try #require(item["draft"]), apple = try #require(item["apple"])
            let snapshot: ReleaseMediaStatus.Snapshot? = apple == .string("unknown") ? nil : try .init(screenshots: sets(apple["screenshots"]), previews: sets(apple["previews"]))
            #expect(ReleaseMediaStatus.status(locale: locale, draft: draft, apple: snapshot).json == item["expected"], "Synthetic release media: \(item["name"]?.text ?? "unknown")")
        }
    }

    @Test func libraryPlacementsProveEqualityAndDeprecatedSetsNeedReview() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), host = "release-media.appstoreconnect.test"
        let image: [String: Any] = ["type": "appAssetLibraryImages", "id": "image-1", "attributes": ["fileName": "placed.png", "fileSize": 1000, "category": "APP_SCREENSHOTS_AND_PREVIEWS", "state": "PREPARE_FOR_SUBMISSION", "specId": "spec-iphone",
            "imageAsset": ["templateUrl": "https://is1-ssl.mzstatic.com/image/thumb/status/{w}x{h}bb.{f}", "width": 1290, "height": 2796]]]
        let placement: [String: Any] = ["type": "appAssetLibraryPlacements", "id": "placement-1", "attributes": ["mediaType": "IMAGE", "placementType": "APP_SCREENSHOT", "placementGroup": "IPHONE_SYNTHETIC_PROFILE", "state": "PARENT_PREPARE_FOR_SUBMISSION"],
            "relationships": ["image": ["data": ["type": "appAssetLibraryImages", "id": "image-1"]], "appStoreVersionLocalization": ["data": ["type": "appStoreVersionLocalizations", "id": "locale-1"]]]]
        nonisolated(unsafe) var placed = true
        StubProtocol.handle(host) { request in
            func page(_ data: Any, included: [Any] = []) -> (Int, [String: String], Data) { (200, [:], try! JSONSerialization.data(withJSONObject: ["data": data, "included": included, "links": [:]])) }
            switch request.url!.path {
            case "/v1/appStoreVersionLocalizations/locale-1/placements": return placed ? page([placement], included: [image]) : page([])
            case "/v1/appAssetLibraryRefData": return page([SyntheticApple.catalog])
            case "/v1/appStoreVersionLocalizations/locale-1/appScreenshotSets":
                return page([["type": "appScreenshotSets", "id": "set-1", "attributes": ["screenshotDisplayType": "APP_IPHONE_67"], "relationships": ["appStoreVersionLocalization": ["data": ["type": "appStoreVersionLocalizations", "id": "locale-1"]]]]])
            case "/v1/appScreenshotSets/set-1/appScreenshots":
                return page([["type": "appScreenshots", "id": "shot-1", "attributes": ["fileName": "legacy.png", "assetDeliveryState": ["state": "COMPLETE"]], "relationships": ["appScreenshotSet": ["data": ["type": "appScreenshotSets", "id": "set-1"]]]]])
            case "/v1/appStoreVersionLocalizations/locale-1/appPreviewSets": return page([])
            default: Issue.record("Unexpected release media read \(request.url!.path)"); return (404, [:], Data())
            }
        }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubProtocol.self]
        let client = AppStoreConnectClient(token: try AppleToken(account: account, privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation), origin: URL(string: "https://\(host)")!, configuration: configuration)
        let resource = try JSONDecoder().decode(AppStoreConnectClient.Resource.self, from: JSONSerialization.data(withJSONObject: image))
        let fingerprint = try #require(try WorkspaceSession.screenshotAsset(resource).sourceFingerprint)
        func locale(_ id: String, _ fingerprint: String) -> JSONText {
            .object([("id", .string("local-1")), ("screenshotSets", .array([.object([("id", .string("set-local")), ("displayType", .string("APP_IPHONE_67")), ("screenshots", .array([.object([
                ("id", .string(id)), ("sha256", .string(String(repeating: "a", count: 64))), ("sourceFingerprint", .string(fingerprint)), ("width", .number(1290)), ("height", .number(2796))])]))])]))])
        }
        // A local display size without an imported group is matched to Apple's placement group through the live catalog.
        let library = try await ReleaseMediaStatus.read(localizationId: "locale-1", platform: "IOS", client: client)
        #expect(!library.legacy && library.screenshots.first?.group == "IPHONE_SYNTHETIC_PROFILE")
        #expect(ReleaseMediaStatus.status(locale: locale("placement-1", fingerprint), draft: .object([]), apple: library).state == .ready)
        #expect(ReleaseMediaStatus.status(locale: locale("placement-1", String(repeating: "b", count: 64)), draft: .object([]), apple: library).state == .review)

        // Without placements the deprecated sets are read, and complete media there still needs a review.
        placed = false
        let legacy = try await ReleaseMediaStatus.read(localizationId: "locale-1", platform: "IOS", client: client)
        let status = ReleaseMediaStatus.status(locale: locale("shot-1", fingerprint), draft: .object([]), apple: legacy)
        #expect(legacy.legacy && status.state == .review && status.detail.contains("deprecated"))
        #expect(StubProtocol.requests(host).allSatisfy { $0.httpMethod == "GET" })
    }

    @Test func mediaApplesSpecificationsRejectIsNamedWithItsSizesAndWhatAppleAccepts() throws {
        let catalog = try AssetLibrary.Catalog([JSONDecoder().decode(AppStoreConnectClient.Resource.self, from: JSONSerialization.data(withJSONObject: SyntheticApple.catalog))])
        let locale = JSONText.object([("id", .string("local-1")), ("screenshotSets", .array([.object([("id", .string("set-local")), ("displayType", .string("APP_IPHONE_67")), ("screenshots", .array([1, 2].map { index in
            .object([("id", .string("wide-\(index)")), ("width", .number(2000)), ("height", .number(1220))]) }))])]))])
        let status = ReleaseMediaStatus.status(locale: locale, draft: .object([]), apple: .init(screenshots: [], previews: [], legacy: false, catalog: catalog, platform: "IOS"))
        #expect(status.state == .blocked && status.missing == ["2 iPhone large display screenshots"])
        #expect(status.rejected == ["iPhone large display screenshots are 2000 × 1220 px. Apple accepts 1290 × 2796 px · .png, .jpg · up to 50 MiB · no transparency."])
        // The fixture's status stays as it was; the names travel only in the record the release check reads.
        #expect(status.json == .object([("state", .string("blocked")), ("detail", .string(status.detail))]) && status.record["rejected"] != nil)

        let refused = ReleaseMedia.unplaced(catalog, kind: .image, platform: "IOS", displayType: "APP_IPHONE_67", localeName: "British English (en-GB)", files: [("wide.png", 2000, 1220, "png")])
        #expect(refused.hasPrefix("Apple does not accept these iPhone large display screenshots for British English (en-GB): wide.png (2000 × 1220 px, png). Apple accepts 1290 × 2796 px"))
        #expect(refused.hasSuffix("Replace them in step 2, Text and Screenshots, then prepare the review again. Nothing was sent."))
        let platform = ReleaseMedia.unplaced(catalog, kind: .image, platform: "MAC_OS", displayType: "APP_DESKTOP", localeName: "British English (en-GB)", files: [("mac.png", 2880, 1800, "png")])
        #expect(platform == "Apple's current specifications list no screenshots for macOS (MAC_OS), only for IPHONE_APP_STORE. Nothing was sent.")
    }

    /// Versions name their platform IOS or MAC_OS, while Apple's catalog names the store, such as IPHONE_APP_STORE or MAC_APP_STORE.
    @Test func versionPlatformsFindTheirStoresPlacementsInApplesCatalog() throws {
        let catalog = try AssetLibrary.Catalog([JSONDecoder().decode(AppStoreConnectClient.Resource.self, from: JSONSerialization.data(withJSONObject: SyntheticApple.catalog))])
        #expect(ReleaseMedia.groups(catalog, kind: .image, platform: "IOS", files: [(1290, 2796, "png")]) == ["IPHONE_SYNTHETIC_PROFILE"])
        #expect(ReleaseMedia.groups(catalog, kind: .image, platform: "MAC_OS", files: [(1290, 2796, "png")]).isEmpty)
        #expect(AssetLibrary.placementPlatforms("MAC_OS") == ["MAC_OS", "MAC_APP_STORE", "ANY"])
        #expect(AssetLibrary.placementPlatforms("IOS").isSuperset(of: ["IPHONE_APP_STORE", "IPAD_APP_STORE"]))
    }
}
