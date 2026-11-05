import Foundation

/// Bounded decorative Apple icons. No API token, cookies, redirects or disk cache reach the image host.
public enum AppIcons {
    public static let maximumBytes = 2_000_000
    public static func initial(_ name: String) -> String {
        let units = Array(TextSemantics.trim(name).utf16.prefix(1))
        return units.isEmpty ? "?" : String(decoding: units, as: UTF16.self).uppercased()
    }
    public struct Image: Sendable, Equatable {
        public let data: Data, contentType: String
        public init?(data: Data, contentType: String) {
            let type = contentType.components(separatedBy: ";")[0].lowercased()
            let png: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
            guard data.count <= maximumBytes,
                  type == "image/png" && data.starts(with: png) || type == "image/jpeg" && data.starts(with: [255, 216, 255]) else { return nil }
            self.data = data; self.contentType = type
        }
    }
    public static func assetURL(app: AppStoreConnectClient.Resource, included: [AppStoreConnectClient.Resource]) -> URL? {
        guard case .object(let relation)? = app.relationships?["appStoreIcon"], case .object(let link)? = relation["data"],
              let id = link["id"]?.string, link["type"]?.string == "buildIcons",
              let icon = included.first(where: { $0.id == id && $0.type == "buildIcons" }) else { return nil }
        return assetURL(icon: icon)
    }
    /// A build's own App Store icon, used until the app has a version on the App Store.
    public static func buildAssetURL(included: [AppStoreConnectClient.Resource]) -> URL? {
        let icons = included.filter { $0.type == "buildIcons" }
        return (icons.first { $0.attributes?["iconType"]?.string == "APP_STORE" } ?? icons.first).flatMap(assetURL(icon:))
    }
    static func assetURL(icon: AppStoreConnectClient.Resource) -> URL? {
        guard case .object(let asset)? = icon.attributes?["iconAsset"], let template = asset["templateUrl"]?.string else { return nil }
        let expanded = template.replacingOccurrences(of: "{w}", with: "128").replacingOccurrences(of: "{h}", with: "128")
            .replacingOccurrences(of: "{f}", with: "png").replacingOccurrences(of: "{c}", with: "")
        let whitespace = CharacterSet(charactersIn: String((0...32).compactMap(UnicodeScalar.init).map(Character.init)))
        let normalized = expanded.trimmingCharacters(in: whitespace).replacingOccurrences(of: "\t", with: "").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        guard !normalized.contains("{"), !normalized.contains("}"), var parts = URLComponents(string: normalized),
              parts.scheme?.lowercased() == "https", (parts.user ?? "").isEmpty, (parts.password ?? "").isEmpty,
              parts.port == nil || parts.port == 443, let host = parts.host?.lowercased(),
              host == "mzstatic.com" || host.hasSuffix(".mzstatic.com") || host == "apple.com" || host.hasSuffix(".apple.com") else { return nil }
        parts.scheme = "https"; parts.host = host; parts.user = nil; parts.password = nil; if parts.port == 443 { parts.port = nil }
        if parts.path.isEmpty { parts.path = "/" }
        return parts.url
    }
    struct Cache: Sendable {
        struct Entry: Sendable { let image: Image?, expires: ContinuousClock.Instant }
        var entries: [String: Entry] = [:], order: [String] = []
        func cached(_ key: String, now: ContinuousClock.Instant) -> Entry? {
            guard let entry = entries[key], entry.expires > now else { return nil }; return entry
        }
        mutating func insert(_ image: Image?, key: String, now: ContinuousClock.Instant) {
            if entries[key] == nil { order.append(key) }
            while order.count > 100 { entries.removeValue(forKey: order.removeFirst()) }
            entries[key] = Entry(image: image, expires: now + .seconds(image == nil ? 60 : 3600))
        }
    }
}

extension WorkspaceSession {
    public func appIcon(account: Account, appId: String, client: AppStoreConnectClient? = nil) async throws -> AppIcons.Image? {
        try Task.checkCancellation(); try requireSessionAccess(); _ = try currentAccount(account, client: client, exact: true)
        try requireHistoryScope(accountId: account.id, appId: appId)
        let key = account.id + ":" + appId + ":" + Self.json(account).rawSHA256, now = ContinuousClock.now
        if let cached = iconCache.cached(key, now: now) { return cached.image }
        // An icon saved on this Mac shows at once; once it is a day old Apple is asked again in the background.
        if let saved = savedAppIcon(accountId: account.id, appId: appId) {
            iconCache.insert(saved.image, key: key, now: now)
            if Date().timeIntervalSince(saved.fetchedAt) > 86_400, iconTasks[key] == nil {
                _ = try? startIconRead(account: account, appId: appId, client: client, key: key)
            }
            return saved.image
        }
        let task = try iconTasks[key]?.task ?? startIconRead(account: account, appId: appId, client: client, key: key)
        let image = try await task.value
        try Task.checkCancellation(); try requireSessionAccess(); _ = try currentAccount(account, exact: true)
        return image
    }
    /// Forgets the in-memory icons only, as a new launch would; saved icons stay.
    func clearIconMemoryForTesting() { iconCache = AppIcons.Cache() }
    private func startIconRead(account: Account, appId: String, client: AppStoreConnectClient?, key: String) throws -> Task<AppIcons.Image?, Error> {
        let id = UUID()
        let task = try ownedReport { try await self.readAppIcon(account: account, appId: appId, client: client, key: key, id: id) }
        iconTasks[key] = (id, task)
        return task
    }
    private func savedAppIcon(accountId: String, appId: String) -> (image: AppIcons.Image?, fetchedAt: Date)? {
        guard let document = try? storeAccess({ try $0.document(namespace: "app_icons", key: accountId + ":" + appId) }),
              let value = try? JSONText.parse(document.payload), let fetched = value["fetchedAt"]?.text.flatMap(ReportTimestamps.date) else { return nil }
        let image = value["data"]?.text.flatMap { Data(base64Encoded: $0) }.flatMap { AppIcons.Image(data: $0, contentType: value["contentType"]?.text ?? "") }
        return (image, fetched)
    }
    /// The icon, or that Apple has none, is kept in the encrypted store so the next launch shows it without a network read.
    private func saveAppIcon(_ image: AppIcons.Image?, accountId: String, appId: String) {
        let value = JSONText.object([("fetchedAt", .string(ReportTimestamps.isoUtcText(Date()))), ("contentType", image.map { .string($0.contentType) } ?? .null),
                                     ("data", image.map { .string($0.data.base64EncodedString()) } ?? .null)])
        _ = try? storeAccess { store in try store.transaction { _ in [.put(namespace: "app_icons", key: accountId + ":" + appId, json: value.data)] } }
    }
    private func readAppIcon(account: Account, appId: String, client: AppStoreConnectClient?, key: String, id: UUID) async throws -> AppIcons.Image? {
        defer { if iconTasks[key]?.id == id { iconTasks[key] = nil } }
        var image: AppIcons.Image?
        do {
            try Task.checkCancellation(); _ = try currentAccount(account, client: client, exact: true)
            let client = try client ?? self.client(for: account)
            let page = try await client.iconResources(appId: appId)
            try Task.checkCancellation(); _ = try currentAccount(account, client: client, exact: true)
            var url = page.data.first(where: { $0.id == appId && $0.type == "apps" }).flatMap { AppIcons.assetURL(app: $0, included: page.included) }
            if url == nil { url = AppIcons.buildAssetURL(included: try await client.latestBuildIconResources(appId: appId)) }
            if let url {
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
                request.httpShouldHandleCookies = false
                let configuration = client.session.configuration
                configuration.httpAdditionalHeaders = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
                let response = try await BoundedResponse.read(request, configuration: configuration, maximumBytes: AppIcons.maximumBytes, check: { response in
                    let type = (response.value(forHTTPHeaderField: "Content-Type") ?? "").components(separatedBy: ";")[0].lowercased()
                    guard (200..<300).contains(response.statusCode), type == "image/png" || type == "image/jpeg" else { throw BoundedResponse.Failure.invalidResponse }
                })
                if (200..<300).contains(response.response.statusCode) {
                    image = AppIcons.Image(data: response.data, contentType: response.response.value(forHTTPHeaderField: "Content-Type") ?? "")
                }
            }
        } catch {
            try Task.checkCancellation(); try requireSessionAccess(); _ = try currentAccount(account, exact: true)
            // An unavailable decorative icon leaves the ordinary fallback without retaining upstream diagnostics.
        }
        try Task.checkCancellation(); try requireSessionAccess(); _ = try currentAccount(account, exact: true)
        guard iconTasks[key]?.id == id else { throw CancellationError() }
        iconCache.insert(image, key: key, now: .now)
        saveAppIcon(image, accountId: account.id, appId: appId)
        return image
    }
}
