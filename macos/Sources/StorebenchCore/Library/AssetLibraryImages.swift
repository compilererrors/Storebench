import Foundation

extension WorkspaceSession {
    public func assetLibraryThumbnail(account: Account, appId: String, asset: AssetLibrary.Asset, client: AppStoreConnectClient) async throws -> Data {
        try await assetLibraryRendition(account: account, appId: appId, asset: asset, client: client, size: nil)
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
        let image = fresh.value["attributes"]?[fresh.kind == .image ? "imageAsset" : "previewFrameImage"]
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
        let configuration = client.session.configuration; configuration.httpAdditionalHeaders = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        let reply = try await BoundedResponse.read(request, configuration: configuration, maximumBytes: size == .full ? ScreenshotSpecs.maximumBytes : 8_000_000, check: { response in
            guard (200..<300).contains(response.statusCode), ["image/png", "image/jpeg"].contains((response.value(forHTTPHeaderField: "Content-Type") ?? "").components(separatedBy: ";")[0].lowercased()) else { throw BoundedResponse.Failure.invalidResponse }
        })
        try requirePublishingAccount(account, appId: appId, client: client); try Task.checkCancellation(); return reply.data
    }
}
