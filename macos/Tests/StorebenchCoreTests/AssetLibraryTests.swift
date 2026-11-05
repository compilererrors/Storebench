import CryptoKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import StorebenchCore

/// Every route is served by the owned URLProtocol; unknown routes are refused.
final class SyntheticLibraryApple: @unchecked Sendable {
    let lock = NSLock(), base = SyntheticApple()
    var assets: [[String: Any]] = [], placements: [[String: Any]] = [], submissions: [[String: Any]] = [], members: [[String: Any]] = []
    var writes: [(String, String)] = [], uploaded = Data()
    var assetCounter = 0
    var versionState = "PREPARE_FOR_SUBMISSION"
    var foreignLibrary = false, failUpload = false, wrongSpec = false, approved = true, limit = 3
    let blob = "synthetic-library.blobstore.apple.com"
    func relation(_ type: String, _ id: String) -> [String: Any] { ["data": ["type": type, "id": id]] }
    func asset(_ id: String, name: String = "Synthetic header", kind: String = "appAssetLibraryImages", state: String = "PREPARE_FOR_SUBMISSION") -> [String: Any] {
        ["type": kind, "id": id, "attributes": ["fileName": kind == "appAssetLibraryImages" ? "synthetic.png" : "synthetic.mp4", "fileSize": 100, "referenceName": name, "category": "CREATIVE_ASSETS", "state": state, "specId": kind == "appAssetLibraryImages" ? "synthetic-spec" : "synthetic-video-spec"], "relationships": ["assetLibrary": relation("appAssetLibraries", "library-synthetic")]]
    }
    var catalog: [String: Any] {
        let image: [String: Any] = ["specId": "synthetic-spec", "shortName": "Synthetic image", "dimensions": ["minWidth": 400, "maxWidth": 400, "minHeight": 200, "maxHeight": 200], "aspectRatio": "2:1", "fileExtensions": [".png", ".jpg", ".jpeg"], "maxFileSize": 524288000, "alphaAllowed": false, "compatiblePlacementTypes": ["PRODUCT_PAGE_HEADER_ASSET"]]
        let video: [String: Any] = ["specId": "synthetic-video-spec", "dimensions": ["minWidth": 1920, "maxWidth": 1920, "minHeight": 1080, "maxHeight": 1080], "aspectRatio": "16:9", "fileExtensions": [".mp4", ".mov"], "maxFileSize": 524288000, "duration": ["min": "PT15S", "max": "PT30S"], "frameRates": [["minFps": 23, "maxFps": 30]], "audioRequired": true]
        let type: [String: Any] = ["placementTypeId": "PRODUCT_PAGE_HEADER_ASSET", "acceptsAssetCategories": ["CREATIVE_ASSETS"], "specMappings": [["placementGroupId": "SYNTHETIC_PROFILE", "specs": ["synthetic-spec", "synthetic-video-spec"]]]]
        return ["type": "appAssetLibraryRefData", "id": "catalog-synthetic", "attributes": ["imageSpecs": [image], "videoSpecs": [video], "placementTypes": [type], "placementProfileGroups": [["placementProfileGroupId": "SYNTHETIC_PROFILE", "platform": "MAC_APP_STORE", "displayClassId": "SYNTHETIC_DISPLAY"]], "displayClasses": [], "features": AssetLibrary.Surface.allCases.map { ["featureId": $0.rawValue, "placementPolicies": [["placementType": "PRODUCT_PAGE_HEADER_ASSET", "groupLimits": [["groupIds": ["SYNTHETIC_PROFILE"], "maxCount": limit]]]]] }]]
    }
    func handle(_ request: URLRequest) -> (Int, [String: String], Data) {
        lock.lock(); defer { lock.unlock() }
        let path = request.url!.path, method = request.httpMethod ?? "GET"
        if request.url?.host == blob {
            guard method == "PUT", request.value(forHTTPHeaderField: "Authorization") == nil else { return (400, [:], Data()) }
            if failUpload { failUpload = false; return (503, [:], Data()) }
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var data = Data(), buffer = [UInt8](repeating: 0, count: 32768)
                let deadline = ContinuousClock.now.advanced(by: .seconds(10))
                while stream.streamStatus != .atEnd, stream.streamStatus != .error, ContinuousClock.now < deadline {
                    if !stream.hasBytesAvailable { Thread.sleep(forTimeInterval: 0.001); continue }
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count < 0 { return (400, [:], Data()) }; if count == 0 { break }
                    data.append(buffer, count: count); if data.count > 4_000_000 { return (413, [:], Data()) }
                }
                guard data.count == Int(request.value(forHTTPHeaderField: "Content-Length") ?? "") else { return (400, [:], Data()) }; uploaded += data
            } else { uploaded += base.body(request) }
            return (200, [:], Data())
        }
        if method == "GET" {
            if path == "/v1/apps/1000000001/assetLibrary" { return base.page(["type": "appAssetLibraries", "id": "library-synthetic", "relationships": ["app": relation("apps", foreignLibrary ? "1000000002" : "1000000001")]]) }
            if path == "/v1/appAssetLibraryRefData" { return base.page([catalog]) }
            if path == "/v1/appAssetLibraries/library-synthetic/images" { return base.page(assets.filter { $0["type"] as? String == "appAssetLibraryImages" }) }
            if path == "/v1/appAssetLibraries/library-synthetic/videos" { return base.page(assets.filter { $0["type"] as? String == "appAssetLibraryVideos" }) }
            if path == "/v1/apps/1000000001/appStoreVersions" {
                var versions = base.versions
                if approved { versions.append(["type": "appStoreVersions", "id": "approved-version", "attributes": ["platform": "MAC_OS", "versionString": "0.9", "appVersionState": "READY_FOR_DISTRIBUTION"], "relationships": ["app": relation("apps", "1000000001")]]) }
                versions[0]["attributes"] = ["platform": "MAC_OS", "versionString": "1.0", "appVersionState": versionState]
                return base.page(versions)
            }
            if path == "/v1/appStoreVersions/approved-version/appStoreVersionLocalizations" { return base.page([]) }
            if path == "/v1/apps/1000000001/reviewSubmissions" { return base.page(submissions) }
            for submission in submissions where path == "/v1/reviewSubmissions/\(submission["id"]!)/items" { return base.page(members.filter { (($0["relationships"] as? [String: Any])?["reviewSubmission"] as? [String: Any])?["data"] as? [String: String] == ["type": "reviewSubmissions", "id": submission["id"] as! String] }) }
            for asset in assets {
                let root = "/v1/\(asset["type"]!)/\(asset["id"]!)"
                if path == root { return base.page(asset) }
                if path == root + "/placements" { let id = asset["id"] as! String; return base.page(placements.filter { item in let relations = item["relationships"] as! [String: Any]; return ["image", "video"].contains { ((relations[$0] as? [String: Any])?["data"] as? [String: String])?["id"] == id } }) }
            }
            if path == "/v1/appStoreVersionLocalizations/version-locale-1/placements" { return base.page(placements) }
            if path == "/v1/apps/1000000001/appCustomProductPages" { return base.page([["type": "appCustomProductPages", "id": "page-synthetic", "attributes": ["name": "Synthetic page"], "relationships": ["app": relation("apps", "1000000001")]]]) }
            if path == "/v1/appCustomProductPages/page-synthetic/appCustomProductPageVersions" { return base.page([["type": "appCustomProductPageVersions", "id": "page-version", "attributes": ["state": "PREPARE_FOR_SUBMISSION"], "relationships": ["appCustomProductPage": relation("appCustomProductPages", "page-synthetic")]]]) }
            if path == "/v1/appCustomProductPageVersions/page-version/appCustomProductPageLocalizations" { return base.page([["type": "appCustomProductPageLocalizations", "id": "page-locale", "attributes": ["locale": "en-US"], "relationships": ["appCustomProductPageVersion": relation("appCustomProductPageVersions", "page-version")]]]) }
            if path == "/v1/apps/1000000001/appEvents" { return base.page([["type": "appEvents", "id": "event-synthetic", "attributes": ["referenceName": "Synthetic event", "eventState": "DRAFT"], "relationships": ["app": relation("apps", "1000000001")]]]) }
            if path == "/v1/appEvents/event-synthetic/localizations" { return base.page([["type": "appEventLocalizations", "id": "event-locale", "attributes": ["locale": "en-US"], "relationships": ["appEvent": relation("appEvents", "event-synthetic")]]]) }
            if path == "/v1/apps/1000000001/appStoreVersionExperimentsV2" { return base.page([["type": "appStoreVersionExperiments", "id": "experiment-synthetic", "attributes": ["name": "Synthetic experiment", "platform": "MAC_OS", "state": "PREPARE_FOR_SUBMISSION"], "relationships": ["app": relation("apps", "1000000001")]]]) }
            if path == "/v2/appStoreVersionExperiments/experiment-synthetic/appStoreVersionExperimentTreatments" { return base.page([["type": "appStoreVersionExperimentTreatments", "id": "treatment-synthetic", "attributes": ["name": "Synthetic treatment"], "relationships": ["appStoreVersionExperimentV2": relation("appStoreVersionExperiments", "experiment-synthetic")]]]) }
            if path == "/v1/appStoreVersionExperimentTreatments/treatment-synthetic/appStoreVersionExperimentTreatmentLocalizations" { return base.page([["type": "appStoreVersionExperimentTreatmentLocalizations", "id": "treatment-locale", "attributes": ["locale": "en-US"], "relationships": ["appStoreVersionExperimentTreatment": relation("appStoreVersionExperimentTreatments", "treatment-synthetic")]]]) }
            return base.handle(request)
        }
        writes.append((method, path))
        let body = (try? JSONSerialization.jsonObject(with: base.body(request))) as? [String: Any], data = body?["data"] as? [String: Any]
        if ["/v1/appAssetLibraryImages", "/v1/appAssetLibraryVideos"].contains(path), method == "POST", var created = data {
            var attrs = created["attributes"] as! [String: Any]; let size = attrs["fileSize"] as! Int
            attrs["state"] = "AWAITING_UPLOAD"; attrs["uploadOperations"] = [["method": "PUT", "url": "https://\(blob)/original", "offset": 0, "length": size, "requestHeaders": []]]
            assetCounter += 1; created["id"] = "asset-\(assetCounter)"; created["attributes"] = attrs; assets.append(created); return base.page(created)
        }
        if let index = assets.firstIndex(where: { path == "/v1/\($0["type"]!)/\($0["id"]!)" }) {
            if method == "DELETE" { assets.remove(at: index); return (204, [:], Data()) }
            var attrs = assets[index]["attributes"] as! [String: Any]
            for (key, value) in data?["attributes"] as? [String: Any] ?? [:] { attrs[key] = value }
            if attrs["uploaded"] as? Bool == true { attrs["state"] = "PREPARE_FOR_SUBMISSION"; attrs["specId"] = wrongSpec ? "wrong-synthetic-spec" : assets[index]["type"] as? String == "appAssetLibraryVideos" ? "synthetic-video-spec" : "synthetic-spec" }
            if attrs["archived"] as? Bool == true { attrs["state"] = "ARCHIVED" }
            if attrs["archived"] as? Bool == false, attrs["state"] as? String == "ARCHIVED" { attrs["state"] = "APPROVED" }
            assets[index]["attributes"] = attrs; return base.page(assets[index])
        }
        if path == "/v1/appAssetLibraryPlacements", method == "POST", var item = data {
            var attrs = item["attributes"] as! [String: Any]; attrs["mediaType"] = (item["relationships"] as! [String: Any])["video"] == nil ? "IMAGE" : "VIDEO"; attrs["state"] = "PARENT_PREPARE_FOR_SUBMISSION"
            item["id"] = "placement-\(placements.count + 1)"; item["attributes"] = attrs; placements.append(item); return base.page(item)
        }
        if path.hasPrefix("/v1/appAssetLibraryPlacements/"), method == "DELETE" { placements.removeAll { path.hasSuffix("/\($0["id"]!)") }; return (204, [:], Data()) }
        if path == "/v1/appAssetLibraryPlacementOrderingRequests", method == "POST" {
            let ids = (((data?["relationships"] as? [String: Any])?["orderedPlacements"] as? [String: Any])?["data"] as? [[String: String]] ?? []).compactMap { $0["id"] }
            placements = ids.compactMap { id in placements.first { $0["id"] as? String == id } }; return base.page(["type": "appAssetLibraryPlacementOrderingRequests", "id": "order-synthetic"])
        }
        if path == "/v1/reviewSubmissions", method == "POST", var item = data {
            var attrs = item["attributes"] as! [String: Any]; attrs["state"] = "READY_FOR_REVIEW"; item["attributes"] = attrs; item["id"] = "submission-\(submissions.count + 1)"; submissions.append(item); return base.page(item)
        }
        if path == "/v1/reviewSubmissionItems", method == "POST", var item = data {
            item["id"] = "member-\(members.count + 1)"; members.append(item)
            let relations = item["relationships"] as! [String: Any], assetId = (((relations["appAssetLibraryImage"] ?? relations["appAssetLibraryVideo"]) as? [String: Any])?["data"] as? [String: String])?["id"]
            if let index = assets.firstIndex(where: { $0["id"] as? String == assetId }) { var attrs = assets[index]["attributes"] as! [String: Any]; attrs["state"] = "READY_FOR_REVIEW"; assets[index]["attributes"] = attrs }
            return base.page(item)
        }
        if path.hasPrefix("/v1/reviewSubmissions/"), method == "PATCH", let index = submissions.firstIndex(where: { path.hasSuffix("/\($0["id"]!)") }) {
            var attrs = submissions[index]["attributes"] as! [String: Any]; attrs["state"] = "WAITING_FOR_REVIEW"; submissions[index]["attributes"] = attrs; return base.page(submissions[index])
        }
        return (501, [:], Data())
    }
}

@Suite(.serialized) struct AssetLibraryTests {
    init() throws { _ = try TestIsolation.require() }
    let app = "1000000001"
    func client(_ account: Account, _ apple: SyntheticLibraryApple) throws -> AppStoreConnectClient {
        let host = "asset-library-\(UUID().uuidString.lowercased()).test"
        StubProtocol.handle(host) { apple.handle($0) }; StubProtocol.handle(apple.blob) { apple.handle($0) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        return AppStoreConnectClient(token: try AppleToken(account: account, privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation), origin: URL(string: "https://\(host)")!, configuration: config)
    }
    func png(width: Int = 400, height: Int = 200, alpha: Bool = false) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: alpha ? 0.4 : 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData(), destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil); #expect(CGImageDestinationFinalize(destination)); return data as Data
    }
    func stage(_ session: WorkspaceSession, account: Account, data: Data? = nil) async throws -> AssetLibrary.File {
        let url = try TestIsolation.require().appendingPathComponent("synthetic-\(UUID().uuidString).png")
        try (data ?? png()).write(to: url)
        return try await session.stageAssetLibraryFile(accountId: account.id, appId: app, url: url, category: .creative, name: "Synthetic creative")
    }
    func request(_ account: Account, _ change: AssetLibrary.Change) -> PublishRequest { var request = PublishRequest(accountId: account.id, appId: app, scope: .assetLibrary); request.assetLibraryChange = change; return request }
    func apply(_ session: WorkspaceSession, _ account: Account, _ client: AppStoreConnectClient, _ change: AssetLibrary.Change) async throws -> PublishReview {
        let review = try await session.preparePublishing(account: account, request: request(account, change), client: client)
        return try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: client)
    }
    @Test func uploadRequiresApprovalAndReusesAnInterruptedReservation() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), file = try await stage(session, account: account), apple = SyntheticLibraryApple(), client = try client(account, apple)
        var change = AssetLibrary.Change(action: .upload); change.fileId = file.id
        let review = try await session.preparePublishing(account: account, request: request(account, change), client: client)
        #expect(apple.writes.isEmpty && review.steps.count == 4)
        apple.failUpload = true
        let failed = try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: client)
        #expect(failed.state == "failed" && apple.assets.count == 1)
        let resumed = try await apply(session, account, client, change)
        #expect(resumed.state == "complete" && apple.assets.count == 1 && apple.uploaded.count == file.size)
        #expect(apple.writes.filter { $0 == ("POST", "/v1/appAssetLibraryImages") }.count == 1)
        let commit = try #require(resumed.steps.first { $0.method == "PATCH" }.flatMap(\.body))
        #expect(commit["data"]?["attributes"] == .object([("uploaded", .bool(true))]))
        let duplicate = try await session.preparePublishing(account: account, request: request(account, change), client: client)
        #expect(duplicate.steps.isEmpty)
        await #expect(throws: PublishFailure.used) { try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: client) }
        let reader = try await session.openSavedMedia(.init(accountId: account.id, appId: app, revisionId: file.id, itemId: file.id, kind: .assetLibrary))
        #expect(try await reader.imageBytes().count == file.size); reader.close()
    }
    @Test func specificationsScopeAndMatchedSpecAreChecked() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticLibraryApple(), client = try client(account, apple), file = try await stage(session, account: account)
        let snapshot = try await session.assetLibrary(account: account, appId: app, client: client)
        #expect(snapshot.catalog.matching(file).map(\.id) == ["synthetic-spec"])
        let transparent = try await stage(session, account: account, data: png(alpha: true))
        #expect(snapshot.catalog.matching(transparent).isEmpty)
        var change = AssetLibrary.Change(action: .upload); change.fileId = transparent.id
        await #expect(throws: (any Error).self) { try await session.preparePublishing(account: account, request: request(account, change), client: client) }
        apple.foreignLibrary = true
        await #expect(throws: (any Error).self) { try await session.assetLibrary(account: account, appId: app, client: client) }
        apple.foreignLibrary = false; apple.wrongSpec = true; change.fileId = file.id
        #expect(try await apply(session, account, client, change).state == "failed")
        #expect(apple.assets.count == 1)
    }
    @Test func editedCreativeImagesKeepOriginalsAndExportOpaquePNG() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), originalBytes = try png(width: 500, height: 500, alpha: true), original = try await stage(session, account: account, data: originalBytes)
        let source = try ScreenshotRenderer.load(originalBytes), edits = ScreenshotEdits(width: 400, height: 200)
        let encoded = try ScreenshotRenderer.export(source, edits: edits, png: true)
        let edited = try await session.stageEditedLibraryImage(accountId: account.id, appId: app, sourceId: original.id, bytes: encoded)
        let files = try await session.assetLibraryFiles(accountId: account.id, appId: app)
        #expect(files.count == 2 && files.contains(original) && files.contains(edited))
        #expect(edited.ext == "png" && edited.width == 400 && edited.height == 200 && !edited.hasAlpha)
        let apple = SyntheticLibraryApple(), client = try client(account, apple), snapshot = try await session.assetLibrary(account: account, appId: app, client: client)
        #expect(snapshot.catalog.matching(edited).map(\.id) == ["synthetic-spec"])
        #expect(snapshot.catalog.matching(original).isEmpty)
        #expect(snapshot.catalog.editingTargets(category: .creative).map { ($0.width, $0.height) }.count == 1)
        try await session.removeAssetLibraryFile(accountId: account.id, appId: app, id: original.id)
        await #expect(throws: (any Error).self) { try await session.stageEditedLibraryImage(accountId: account.id, appId: app, sourceId: original.id, bytes: encoded) }
    }
    @Test func videoAudioDurationAndPosterAreValidatedBeforeUpload() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticLibraryApple(), client = try client(account, apple), snapshot = try await session.assetLibrary(account: account, appId: app, client: client)
        let withoutAudio = try PreviewTests().file(syntheticMovie(width: 1920, height: 1080), "synthetic-no-audio.mp4")
        let rejected = try await session.stageAssetLibraryFile(accountId: account.id, appId: app, url: withoutAudio, category: .creative, name: "Silent synthetic video")
        #expect(snapshot.catalog.matching(rejected).isEmpty)
        let withAudio = try PreviewTests().file(syntheticMovie(width: 1920, height: 1080, audio: true), "synthetic-with-audio.mp4")
        let accepted = try await session.stageAssetLibraryFile(accountId: account.id, appId: app, url: withAudio, category: .creative, name: "Synthetic video", timeCode: "00:00:05:00")
        #expect(accepted.hasAudio && snapshot.catalog.matching(accepted).map(\.id) == ["synthetic-video-spec"])
        await #expect(throws: (any Error).self) { try await session.stageAssetLibraryFile(accountId: account.id, appId: app, url: withAudio, category: .creative, name: "Synthetic video", timeCode: "00:00:50:00") }
        var upload = AssetLibrary.Change(action: .upload); upload.kind = .video; upload.fileId = accepted.id
        #expect(try await apply(session, account, client, upload).state == "complete")
        var poster = AssetLibrary.Change(action: .poster); poster.kind = .video; poster.assetId = "asset-1"; poster.timeCode = "00:00:06:00"
        #expect(try await apply(session, account, client, poster).state == "complete")
        #expect((apple.assets[0]["attributes"] as! [String: Any])["previewFrameTimeCode"] as? String == "00:00:06:00")
    }
    @Test func placementsReuseOriginalReorderAndPreventDeletingUsedAssets() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticLibraryApple(), client = try client(account, apple)
        apple.assets = [apple.asset("synthetic-one"), apple.asset("synthetic-two", name: "Synthetic second")]
        var place = AssetLibrary.Change(action: .place); place.targetId = "version-locale-1"; place.assetId = "synthetic-one"; place.placementType = "PRODUCT_PAGE_HEADER_ASSET"; place.placementGroup = "SYNTHETIC_PROFILE"
        #expect(try await apply(session, account, client, place).state == "complete")
        place.assetId = "synthetic-two"; #expect(try await apply(session, account, client, place).state == "complete")
        #expect(apple.assets.count == 2 && apple.uploaded.isEmpty)
        var deletion = AssetLibrary.Change(action: .delete); deletion.assetId = "synthetic-one"
        await #expect(throws: (any Error).self) { try await session.preparePublishing(account: account, request: request(account, deletion), client: client) }
        var order = AssetLibrary.Change(action: .reorder); order.targetId = place.targetId; order.placementGroup = place.placementGroup; order.orderedIds = ["placement-2", "placement-1"]
        #expect(try await apply(session, account, client, order).state == "complete")
        #expect(apple.placements.map { $0["id"] as! String } == order.orderedIds)
        var remove = AssetLibrary.Change(action: .removePlacement); remove.targetId = place.targetId; remove.placementId = "placement-1"
        #expect(try await apply(session, account, client, remove).state == "complete")
        #expect(apple.assets.count == 2)
        #expect(try await apply(session, account, client, deletion).state == "complete")
        #expect(apple.assets.count == 1)
    }
    @Test func liveCreativePlacementsRequireApprovedAssetsAndFreshPublishApproval() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticLibraryApple(), client = try client(account, apple)
        apple.versionState = "READY_FOR_DISTRIBUTION"
        apple.assets = [apple.asset("synthetic-ready"), apple.asset("synthetic-approved", state: "APPROVED")]
        var place = AssetLibrary.Change(action: .place); place.targetId = "version-locale-1"; place.assetId = "synthetic-ready"; place.placementType = "PRODUCT_PAGE_HEADER_ASSET"; place.placementGroup = "SYNTHETIC_PROFILE"
        await #expect(throws: (any Error).self) { try await session.preparePublishing(account: account, request: request(account, place), client: client) }
        #expect(apple.writes.isEmpty)
        place.assetId = "synthetic-approved"
        let review = try await session.preparePublishing(account: account, request: request(account, place), client: client)
        #expect(review.steps.count == 1 && apple.writes.isEmpty && apple.placements.isEmpty)
        #expect(try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: client).state == "complete")
        #expect(apple.placements.count == 1)
        var reorder = AssetLibrary.Change(action: .reorder); reorder.targetId = place.targetId; reorder.placementGroup = place.placementGroup; reorder.orderedIds = ["placement-1"]
        await #expect(throws: (any Error).self) { try await session.preparePublishing(account: account, request: request(account, reorder), client: client) }
        var remove = AssetLibrary.Change(action: .removePlacement); remove.targetId = place.targetId; remove.placementId = "placement-1"
        #expect(try await apply(session, account, client, remove).state == "complete")
        #expect(apple.placements.isEmpty && apple.assets.count == 2)
        let stale = try await session.preparePublishing(account: account, request: request(account, place), client: client), before = apple.writes.count
        apple.assets[1] = apple.asset("synthetic-approved", state: "PREPARE_FOR_SUBMISSION")
        await #expect(throws: (any Error).self) { try await session.approvePublishing(account: account, appId: app, id: stale.id, fingerprint: stale.fingerprint, client: client) }
        #expect(apple.writes.count == before && apple.placements.isEmpty)
    }
    @Test @MainActor func dragOrderSavesLocallyAndOnlyAnApprovedFreshReviewChangesApple() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticLibraryApple(), client = try client(account, apple)
        apple.assets = [apple.asset("synthetic-one"), apple.asset("synthetic-two")]
        var place = AssetLibrary.Change(action: .place); place.targetId = "version-locale-1"; place.assetId = "synthetic-one"; place.placementType = "PRODUCT_PAGE_HEADER_ASSET"; place.placementGroup = "SYNTHETIC_PROFILE"
        _ = try await apply(session, account, client, place); place.assetId = "synthetic-two"; _ = try await apply(session, account, client, place)
        let target = try #require(try await session.assetLibraryTargets(account: account, appId: app, surface: .versions, client: client).first { $0.id == "version-locale-1" })
        let placements = try await session.assetLibraryPlacements(account: account, appId: app, target: target, client: client)
        let scope = try AssetLibrary.OrderScope(accountId: account.id, appId: app, surface: .versions, targetId: target.id, group: "SYNTHETIC_PROFILE")
        let editor = try AssetLibraryOrderEditor(scope: scope, placements: placements, saved: nil), drag = MaterialReorder(), original = editor.order
        let token = try #require(drag.begin(original[0], order: original, context: editor.context, enabled: true))
        drag.hover(original[1], after: true, order: original, context: editor.context, enabled: true)
        let next = try #require(drag.commit(token: token, order: original, context: editor.context, enabled: true))
        #expect(editor.reorder(next, expected: original, context: editor.context))
        let writes = apple.writes.count
        #expect(editor.dirty && !editor.canReview)
        #expect(await editor.save { saved in try await session.saveAssetLibraryOrder(scope, baseline: editor.baseline, baselineDigest: editor.baselineDigest, order: next, expectedRevision: saved?.revision) })
        #expect(apple.writes.count == writes && editor.canReview)
        var change = AssetLibrary.Change(action: .reorder); change.targetId = scope.targetId; change.placementGroup = scope.group; change.orderedIds = next; change.expectedPlacements = editor.baselineDigest
        let prepared = try await session.preparePublishing(account: account, request: request(account, change), client: client)
        #expect(apple.writes.count == writes && prepared.steps.count == 1)
        let confirmed = try await session.approvePublishing(account: account, appId: app, id: prepared.id, fingerprint: prepared.fingerprint, client: client)
        #expect(confirmed.state == "complete" && apple.placements.map { $0["id"] as! String } == next)
        await #expect(throws: PublishFailure.used) { try await session.approvePublishing(account: account, appId: app, id: prepared.id, fingerprint: prepared.fingerprint, client: client) }
        await #expect(throws: (any Error).self) { try await session.preparePublishing(account: account, request: request(account, change), client: client) }
        #expect(try await session.assetLibraryOrder(scope)?.order == next)
    }
    @Test func approvedAssetsRejectDeletionAndPosterEditsWithoutWriting() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticLibraryApple(), client = try client(account, apple)
        apple.assets = [apple.asset("synthetic-approved", state: "APPROVED"), apple.asset("synthetic-approved-video", kind: "appAssetLibraryVideos", state: "APPROVED")]
        var deletion = AssetLibrary.Change(action: .delete); deletion.assetId = "synthetic-approved"
        await #expect(throws: (any Error).self) { try await session.preparePublishing(account: account, request: request(account, deletion), client: client) }
        var poster = AssetLibrary.Change(action: .poster); poster.assetId = "synthetic-approved-video"; poster.kind = .video; poster.timeCode = "00:00:05:00"
        await #expect(throws: (any Error).self) { try await session.preparePublishing(account: account, request: request(account, poster), client: client) }
        #expect(apple.writes.isEmpty)
    }
    @Test func changedNamesAndPlacementLimitsRefuseStaleApproval() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticLibraryApple(), client = try client(account, apple)
        apple.assets = [apple.asset("synthetic-one")]
        var rename = AssetLibrary.Change(action: .rename); rename.assetId = "synthetic-one"; rename.name = "New synthetic name"
        let review = try await session.preparePublishing(account: account, request: request(account, rename), client: client)
        apple.assets = [apple.asset("synthetic-one", name: "Changed externally")]
        await #expect(throws: PublishFailure.conflict) { try await session.approvePublishing(account: account, appId: app, id: review.id, fingerprint: review.fingerprint, client: client) }
        #expect(apple.writes.isEmpty)
        var place = AssetLibrary.Change(action: .place); place.assetId = "synthetic-one"; place.targetId = "version-locale-1"; place.placementType = "PRODUCT_PAGE_HEADER_ASSET"; place.placementGroup = "SYNTHETIC_PROFILE"
        let prepared = try await session.preparePublishing(account: account, request: request(account, place), client: client)
        apple.limit = 1
        await #expect(throws: PublishFailure.conflict) { try await session.approvePublishing(account: account, appId: app, id: prepared.id, fingerprint: prepared.fingerprint, client: client) }
        #expect(apple.writes.isEmpty)
    }
    @Test func standaloneReviewUsesAssetRelationshipsAndRequiresAnApprovedVersion() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticLibraryApple(), client = try client(account, apple)
        apple.assets = [apple.asset("synthetic-one"), apple.asset("synthetic-two")]
        var change = AssetLibrary.Change(action: .submit); change.assetIds = ["synthetic-one", "synthetic-two"]; change.platform = "MAC_OS"
        apple.approved = false
        await #expect(throws: (any Error).self) { try await session.preparePublishing(account: account, request: request(account, change), client: client) }
        #expect(apple.writes.isEmpty)
        apple.approved = true
        let review = try await apply(session, account, client, change)
        #expect(review.state == "complete")
        #expect(apple.members.count == 2 && (apple.submissions[0]["attributes"] as! [String: Any])["state"] as? String == "WAITING_FOR_REVIEW")
        #expect(apple.members.allSatisfy { ($0["relationships"] as! [String: Any])["appAssetLibraryImage"] != nil })
    }
    @Test func destinationsCoverAllFourSurfacesAndInvalidRequestsAreRejected() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticLibraryApple(), client = try client(account, apple)
        for surface in AssetLibrary.Surface.allCases {
            let targets = try await session.assetLibraryTargets(account: account, appId: app, surface: surface, client: client)
            #expect(!targets.isEmpty && targets.allSatisfy { $0.surface == surface })
        }
        var invalid = AssetLibrary.Change(action: .reorder); invalid.targetId = "version-locale-1"; invalid.placementGroup = "SYNTHETIC_PROFILE"; invalid.orderedIds = ["duplicate", "duplicate"]
        #expect(throws: (any Error).self) { try request(account, invalid).validated() }
        var mixed = request(account, .init(action: .upload)); mixed.versionId = "version-1"
        #expect(throws: (any Error).self) { try mixed.validated() }
        #expect(AppNavigation.Section.assetLibrary.designIcon == "screenshots")
    }
    @Test func versionReviewIncludesLibraryMaterialAndRejectsIncompleteProcessing() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticLibraryApple(), client = try client(account, apple)
        apple.assets = [apple.asset("synthetic-one")]
        apple.placements = [["type": "appAssetLibraryPlacements", "id": "placement-one", "attributes": ["placementType": "PRODUCT_PAGE_HEADER_ASSET", "placementGroup": "SYNTHETIC_PROFILE", "mediaType": "IMAGE", "state": "PARENT_PREPARE_FOR_SUBMISSION"], "relationships": ["image": apple.relation("appAssetLibraryImages", "synthetic-one"), "appStoreVersionLocalization": apple.relation("appStoreVersionLocalizations", "version-locale-1")]]]
        let reader = await session.libraryReader(appId: app, client: client), version = try JSONDecoder().decode(AppStoreConnectClient.Resource.self, from: JSONSerialization.data(withJSONObject: apple.base.versions[0]))
        let initial = try await session.versionLibraryReview(reader: reader, version: version)
        #expect(initial.descriptions.count == 1 && initial.descriptions[0].contains("Synthetic header"))
        apple.assets = [apple.asset("synthetic-one", name: "New synthetic content")]
        #expect(try await session.versionLibraryReview(reader: reader, version: version).digest != initial.digest)
        apple.assets = [apple.asset("synthetic-one", state: "UPLOAD_COMPLETE")]
        await #expect(throws: (any Error).self) { try await session.versionLibraryReview(reader: reader, version: version) }
        #expect(apple.writes.isEmpty)
    }
    @Test func mixedAssetsCanShareOneSubmissionAndApprovedAssetsCanBeArchived() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticLibraryApple(), client = try client(account, apple)
        apple.assets = [apple.asset("synthetic-image"), apple.asset("synthetic-video", kind: "appAssetLibraryVideos"), apple.asset("synthetic-approved", state: "APPROVED")]
        var change = AssetLibrary.Change(action: .submit); change.assetIds = ["synthetic-image", "synthetic-video"]; change.platform = "MAC_OS"
        #expect(try await apply(session, account, client, change).state == "complete")
        #expect(apple.members.count == 2)
        #expect(apple.members.contains { ($0["relationships"] as! [String: Any])["appAssetLibraryImage"] != nil })
        #expect(apple.members.contains { ($0["relationships"] as! [String: Any])["appAssetLibraryVideo"] != nil })
        apple.placements = [["type": "appAssetLibraryPlacements", "id": "approved-placement", "attributes": ["placementType": "PRODUCT_PAGE_HEADER_ASSET", "placementGroup": "SYNTHETIC_PROFILE", "mediaType": "IMAGE", "state": "PARENT_APPROVED"], "relationships": ["image": apple.relation("appAssetLibraryImages", "synthetic-approved"), "appStoreVersionLocalization": apple.relation("appStoreVersionLocalizations", "version-locale-1")]]]
        var archive = AssetLibrary.Change(action: .archive); archive.assetId = "synthetic-approved"
        #expect(try await apply(session, account, client, archive).state == "complete")
        #expect((apple.assets[2]["attributes"] as! [String: Any])["state"] as? String == "ARCHIVED")
        #expect(apple.placements.count == 1)
    }
    @Test func restoreRequiresApprovalRevalidatesAndCannotBeReplayed() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticLibraryApple(), client = try client(account, apple)
        apple.assets = [apple.asset("synthetic-archived", state: "ARCHIVED")]
        var restore = AssetLibrary.Change(action: .restore); restore.assetId = "synthetic-archived"
        let prepared = try await session.preparePublishing(account: account, request: request(account, restore), client: client)
        #expect((apple.assets[0]["attributes"] as! [String: Any])["state"] as? String == "ARCHIVED")
        #expect(prepared.steps.count == 1)
        #expect(prepared.steps[0].body?["data"]?["attributes"]?["archived"] == .bool(false))
        #expect(try await session.approvePublishing(account: account, appId: app, id: prepared.id, fingerprint: prepared.fingerprint, client: client).state == "complete")
        #expect((apple.assets[0]["attributes"] as! [String: Any])["state"] as? String == "APPROVED")
        await #expect(throws: (any Error).self) { try await session.approvePublishing(account: account, appId: app, id: prepared.id, fingerprint: prepared.fingerprint, client: client) }
        await #expect(throws: (any Error).self) { try await session.preparePublishing(account: account, request: request(account, restore), client: client) }
        apple.assets = [apple.asset("synthetic-archived", state: "ARCHIVED")]
        let stale = try await session.preparePublishing(account: account, request: request(account, restore), client: client)
        apple.assets = [apple.asset("synthetic-archived", state: "APPROVED")]
        await #expect(throws: (any Error).self) { try await session.approvePublishing(account: account, appId: app, id: stale.id, fingerprint: stale.fingerprint, client: client) }
    }
    @Test func existingDraftItemsAreReviewedAndRevalidatedBeforeSubmittingTogether() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticLibraryApple(), client = try client(account, apple)
        apple.assets = [apple.asset("existing-asset", state: "READY_FOR_REVIEW"), apple.asset("new-asset")]
        apple.submissions = [["type": "reviewSubmissions", "id": "existing-submission", "attributes": ["platform": "MAC_OS", "state": "READY_FOR_REVIEW"], "relationships": ["app": apple.relation("apps", app)]]]
        apple.members = [["type": "reviewSubmissionItems", "id": "existing-member", "attributes": ["state": "READY_FOR_REVIEW"], "relationships": ["reviewSubmission": apple.relation("reviewSubmissions", "existing-submission"), "appAssetLibraryImage": apple.relation("appAssetLibraryImages", "existing-asset")]]]
        var change = AssetLibrary.Change(action: .submit); change.assetIds = ["new-asset"]; change.platform = "MAC_OS"; change.submissionId = "existing-submission"
        let stale = try await session.preparePublishing(account: account, request: request(account, change), client: client)
        #expect(stale.steps.count == 2 && stale.steps.last?.after?.contains("existing-member") == true)
        apple.members[0]["attributes"] = ["state": "CHANGED_SYNTHETIC_STATE"]
        await #expect(throws: PublishFailure.conflict) { try await session.approvePublishing(account: account, appId: app, id: stale.id, fingerprint: stale.fingerprint, client: client) }
        #expect(apple.writes.isEmpty)
        apple.members[0]["attributes"] = ["state": "READY_FOR_REVIEW"]
        #expect(try await apply(session, account, client, change).state == "complete")
        #expect(apple.submissions.count == 1 && apple.members.count == 2)
        #expect(!apple.writes.contains { $0 == ("POST", "/v1/reviewSubmissions") })
    }
    @Test func anUnconfirmedReservationCannotCreateADuplicateAndConfirmedDeletionAllowsReupload() async throws {
        let (session, root) = try DraftTests().session(); defer { try? FileManager.default.removeItem(at: root) }
        let account = try #require(try await session.accounts().first), apple = SyntheticLibraryApple(), client = try client(account, apple), file = try await stage(session, account: account)
        var upload = AssetLibrary.Change(action: .upload); upload.fileId = file.id
        let completed = try await apply(session, account, client, upload)
        var interrupted = completed; interrupted.state = "failed"; interrupted.steps[0].state = "failed"; interrupted.steps[0].resultId = nil
        let revision = try await session.storeAccess { try $0.document(namespace: "publish_reviews", key: "\(account.id):\(app):\(completed.id)")?.revision }
        _ = try await session.savePublishReview(interrupted, expected: revision)
        let writeCount = apple.writes.count
        await #expect(throws: (any Error).self) { try await session.preparePublishing(account: account, request: request(account, upload), client: client) }
        #expect(apple.writes.count == writeCount && apple.assets.count == 1)
        var deletion = AssetLibrary.Change(action: .delete); deletion.assetId = "asset-1"
        #expect(try await apply(session, account, client, deletion).state == "complete")
        #expect(try await apply(session, account, client, upload).state == "complete")
        #expect(apple.assets.count == 1 && apple.assets[0]["id"] as? String == "asset-2")
    }
}
