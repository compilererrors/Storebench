import Foundation

extension WorkspaceSession {
    /// The preview through the session's shared reads, so one read of an app's asset list serves every thumbnail of that library.
    public func assetLibraryThumbnail(account: Account, appId: String, asset: AssetLibrary.Asset) async throws -> Data {
        let client = try (try? readClient(for: account)) ?? self.client(for: account)
        return try await assetLibraryThumbnail(account: account, appId: appId, asset: asset, client: client)
    }
    /// Apple's processed preview of a library asset. The bytes are kept for the session, so a thumbnail shown again is not downloaded
    /// again. With a client that shares reads, every thumbnail of one library uses the same read of its asset list.
    public func assetLibraryThumbnail(account: Account, appId: String, asset: AssetLibrary.Asset, client: AppStoreConnectClient) async throws -> Data {
        try requirePublishingAccount(account, appId: appId, client: client)
        let scope = account.id + ":" + appId
        let key = scope + ":" + asset.id + ":" + asset.value.sha256
        if let kept = libraryThumbnails.value(for: key) { return kept }
        let reader = libraryReader(appId: appId, client: client)
        // The asset list is read per app, including every page, so the asset is known to belong to this app before its preview is fetched.
        func listed() async throws -> AssetLibrary.Asset? {
            let library = try await reader.library()
            return try await reader.assets(libraryId: library, kind: asset.kind).first { $0.id == asset.id }
        }
        var current = try await listed()
        // A shared list read before this asset was added or changed is read once more, at most every few seconds per app.
        if client.readCache != nil, current?.value != asset.value, libraryThumbnailRefreshed[scope].map({ ContinuousClock.now - $0 > .seconds(10) }) ?? true {
            libraryThumbnailRefreshed[scope] = .now
            current = try await AppStoreReadCache.refreshing { try await listed() }
        }
        guard var current else { throw AssetLibrary.failure("The library asset no longer belongs to this app.") }
        if Self.libraryImage(current)?["templateUrl"]?.text == nil { current = try await reader.asset(asset.id, kind: asset.kind) }
        let bytes = try await assetLibraryImage(account: account, appId: appId, asset: current, client: client, size: nil)
        libraryThumbnails.insert(bytes, for: key, cost: bytes.count)
        return bytes
    }
    /// Apple's processed image of a screenshot in Asset Library at its own size, to show and order it in a draft. The draft keeps
    /// the file's Asset Library ID, so a Save adds that file to the version and never uploads these bytes.
    public func assetLibraryScreenshot(account: Account, appId: String, asset: AssetLibrary.Asset, client: AppStoreConnectClient) async throws -> Data {
        guard asset.kind == .image, asset.ready, asset.category == AssetLibrary.Category.listing.rawValue else { throw AssetLibrary.failure("Choose a processed screenshot from Asset Library.") }
        return try await assetLibraryRendition(account: account, appId: appId, asset: asset, client: client, size: .full)
    }
    private enum Rendition { case full }
    private func assetLibraryRendition(account: Account, appId: String, asset: AssetLibrary.Asset, client: AppStoreConnectClient, size: Rendition?) async throws -> Data {
        try requirePublishingAccount(account, appId: appId, client: client)
        let fresh = try await libraryReader(appId: appId, client: client).asset(asset.id, kind: asset.kind)
        return try await assetLibraryImage(account: account, appId: appId, asset: fresh, client: client, size: size)
    }
    private static func libraryImage(_ asset: AssetLibrary.Asset) -> JSONText? {
        asset.value["attributes"]?[asset.kind == .image ? "imageAsset" : "previewFrameImage"]
    }
    /// Downloads the image Apple names for an asset that was just read for this app.
    private func assetLibraryImage(account: Account, appId: String, asset fresh: AssetLibrary.Asset, client: AppStoreConnectClient, size: Rendition?) async throws -> Data {
        let image = Self.libraryImage(fresh)
        guard let template = image?["templateUrl"]?.text else { throw AssetLibrary.failure("Apple has not provided a processed preview for this asset.") }
        var width = "800", height = "800"
        if size == .full {
            guard let w = AssetLibrary.integer(image?["width"]), let h = AssetLibrary.integer(image?["height"]), (1...12_000).contains(w), (1...12_000).contains(h) else { throw AssetLibrary.failure("Apple has not provided this screenshot's size.") }
            width = String(w); height = String(h)
        }
        let expanded = template.replacingOccurrences(of: "{w}", with: width).replacingOccurrences(of: "{h}", with: height).replacingOccurrences(of: "{f}", with: "png").replacingOccurrences(of: "{c}", with: "")
        guard !expanded.contains("{"), !expanded.contains("}"), let url = URL(string: expanded), url.scheme == "https", url.user == nil, url.password == nil, url.port == nil, url.fragment == nil,
              let host = url.host?.lowercased(), host == "mzstatic.com" || host.hasSuffix(".mzstatic.com") else { throw AssetLibrary.failure("Apple's asset preview address could not be verified.") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30); request.httpShouldHandleCookies = false
        let reply = try await client.files.read(request, maximumBytes: size == .full ? ScreenshotSpecs.maximumBytes : 8_000_000, check: { response in
            guard (200..<300).contains(response.statusCode), ["image/png", "image/jpeg"].contains((response.value(forHTTPHeaderField: "Content-Type") ?? "").components(separatedBy: ";")[0].lowercased()) else { throw BoundedResponse.Failure.invalidResponse }
        })
        try requirePublishingAccount(account, appId: appId, client: client); try Task.checkCancellation(); return reply.data
    }
}
