import CryptoKit
import Foundation

public enum ImportFailure: Error, Equatable, CaseIterable {
    case auth, access, agreement, keychain, limit, download, interrupted, busy, request, status

    public var code: String {
        switch self {
        case .auth: "SB-IMPORT-AUTH"
        case .access: "SB-IMPORT-ACCESS"
        case .agreement: "SB-IMPORT-AGREEMENT"
        case .keychain: "SB-IMPORT-KEYCHAIN"
        case .limit: "SB-IMPORT-LIMIT"
        case .download: "SB-IMPORT-DOWNLOAD"
        case .interrupted: "SB-IMPORT-INTERRUPTED"
        case .busy: "SB-IMPORT-BUSY"
        case .request: "SB-IMPORT-REQUEST"
        case .status: "SB-IMPORT-STATUS"
        }
    }

    public var message: String { ReportingMessages.message(code) }

    public init(_ error: Error) {
        switch error {
        case let failure as ImportFailure: self = failure
        case AppStoreConnectClient.Failure.status(401): self = .auth
        case AppStoreConnectClient.Failure.status(403): self = .access
        case AppStoreConnectClient.Failure.agreement, AccountFailure.agreement: self = .agreement
        case AppStoreConnectClient.Failure.status(429): self = .limit
        case ReviewsFailure.noKey, is CredentialAccessFailure, is CredentialVault.Failure, is VaultWriter.Failure: self = .keychain
        case is ReportJobFailure, is JobLock.Failure, is FileMutex.Failure, is EncryptedDocumentStore.Failure, is RevisionHistoryFailure, is AccountFailure: self = .status
        default: self = .download
        }
    }
}

public struct ImportResult: Equatable, Sendable {
    /// The saved revision holding this listing: the new one, or the earlier import when nothing changed.
    public let revisionId: String
    public let changed: Bool
    public let screenshots: Int
}

extension AppStoreConnectClient {
    /// A public image from Apple's asset hosts, without the API token and without redirects.
    func image(_ url: URL, maxBytes: Int = 50_000_000) async throws -> (data: Data, contentType: String) {
        try accessCheck()
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpShouldHandleCookies = false
        let result = try await pool.read(request, maximumBytes: maxBytes)
        try accessCheck()
        let data = result.data, http = result.response
        guard (200..<300).contains(http.statusCode) else { throw ImportFailure.download }
        let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").split(separator: ";").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        guard type == "image/png" || type == "image/jpeg", data.count <= maxBytes else { throw ImportFailure.download }
        return (data, type)
    }
}

extension WorkspaceSession {
    static func fields(_ resource: AppStoreConnectClient.Resource, _ names: [String]) -> JSONText {
        .object(names.compactMap { name -> (String, JSONText)? in
            switch resource.attributes?[name] {
            case .string(let value)?: (name, .string(value))
            case .number(let value)?: (name, .number(value))
            case .null?: (name, .null)
            default: nil
            }
        })
    }

    static func value(_ resource: AppStoreConnectClient.Resource, _ name: String) -> String { resource.attributes?[name]?.string ?? "" }

    struct ScreenshotAsset { let url: URL; let width: Double; let height: Double; let sourceFingerprint: String? }

    static func screenshotAsset(_ resource: AppStoreConnectClient.Resource) throws -> ScreenshotAsset {
        guard case .object(let image)? = resource.attributes?["imageAsset"], let template = image["templateUrl"]?.string,
              case .number(let width)? = image["width"], case .number(let height)? = image["height"],
              width >= 1, height >= 1, width <= 9_007_199_254_740_991, height <= 9_007_199_254_740_991,
              width.rounded() == width, height.rounded() == height else { throw ImportFailure.download }
        let expanded = template.replacingOccurrences(of: "{w}", with: JSONText.number(width)).replacingOccurrences(of: "{h}", with: JSONText.number(height))
            .replacingOccurrences(of: "{f}", with: "png").replacingOccurrences(of: "{c}", with: "")
        guard !expanded.contains("{"), !expanded.contains("}"), let url = URL(string: expanded), url.scheme == "https", url.user == nil, url.password == nil, url.port == nil, url.fragment == nil, let host = url.host?.lowercased(),
              host == "mzstatic.com" || host.hasSuffix(".mzstatic.com") || host == "apple.com" || host.hasSuffix(".apple.com") else { throw ImportFailure.download }
        var fingerprint: String?
        if resource.type == AssetLibrary.Kind.image.resource {
            // A library image's bytes never change after its upload is committed, so its identity and rendition identify it.
            fingerprint = JSONText.array([.string(resource.id), .string("asset-library"), .number(width), .number(height), .string(url.absoluteString)]).sha256
        } else if let checksum = resource.attributes?["sourceFileChecksum"]?.string, checksum.range(of: "^[a-fA-F0-9]{32}$", options: .regularExpression) != nil {
            fingerprint = JSONText.array([.string(resource.id), .string(checksum.lowercased()), .number(width), .number(height), .string(url.absoluteString)]).sha256
        }
        return ScreenshotAsset(url: url, width: width, height: height, sourceFingerprint: fingerprint)
    }

    /// What Apple returned, without the identity and time of this particular import.
    static func revisionContent(_ revision: JSONText) -> String {
        JSONText.object(["account", "app", "appInfos", "versions"].map { ($0, revision[$0] ?? .null) }).sha256
    }

    /// The newest saved Apple import as stored, found through its pointer or by listing. Local drafts never count.
    func latestImport(accountId: String, appId: String) throws -> JSONText? {
        try storeAccess { store in
            func imported(_ saved: EncryptedDocumentStore.Document) throws -> JSONText? {
                let value = try JSONText.parse(saved.payload)
                guard value["origin"] == nil else { return nil }
                guard let id = value["id"]?.text, ReportJobs.uuid(id), saved.key == "\(accountId):\(appId):\(id)",
                      try committedImport(accountId: accountId, appId: appId, revisionId: id, store: store) != nil else { throw ImportFailure.status }
                return value
            }
            if let pointer = try store.document(namespace: "latest_imports", key: "\(accountId):\(appId)"),
               let id = (try? JSONText.parse(pointer.payload))?["revisionId"]?.text, ReportJobs.uuid(id),
               let saved = try store.document(namespace: "revisions", key: "\(accountId):\(appId):\(id)"), let value = try imported(saved) { return value }
            return try store.documents(namespace: "revisions", prefix: "\(accountId):\(appId):").compactMap(imported)
                .max { ($0["importedAt"]?.text ?? "") < ($1["importedAt"]?.text ?? "") }
        }
    }

    func importRevision(account: Account, appId: String, revisionId: String, client: AppStoreConnectClient, now: () -> Date, check: @escaping () throws -> Void,
                        progress: (String, Int) throws -> Void) async throws -> ImportResult {
        func list(_ path: String, type: String, parent: (String, String, String)) async throws -> [AppStoreConnectClient.Resource] {
            try check(); let values = try await client.list(path); try check()
            guard values.allSatisfy({ $0.type == type && AnalyticsCatalog.id($0.id) && Apple.within($0, parent.0, parent.1, parent.2) }), Set(values.map(\.id)).count == values.count else { throw ImportFailure.download }
            return values
        }
        try check(); try progress("Reading app information", 0)
        let apps = try await client.get("/v1/apps/\(appId)"); try check()
        guard apps.count == 1, let app = apps.first, app.type == "apps", app.id == appId else { throw ImportFailure.download }
        let previous = try latestImport(accountId: account.id, appId: appId), previousId = previous?["id"]?.text
        var reusable: [String: JSONText] = [:]
        if case .array(let versions)? = previous?["versions"] {
            for version in versions { if case .array(let locales)? = version["localizations"] { for locale in locales { if case .array(let sets)? = locale["screenshotSets"] {
                for set in sets { if case .array(let shots)? = set["screenshots"] { for shot in shots { if let shotId = shot["id"]?.text { reusable[shotId] = shot } } } }
            } } } }
        }

        var appInfos: [JSONText] = []
        for info in try await list("/v1/apps/\(appId)/appInfos?include=app&limit=200", type: "appInfos", parent: ("app", "apps", appId)) {
            try check()
            let localizations = try await list("/v1/appInfos/\(info.id)/appInfoLocalizations?limit=200", type: "appInfoLocalizations", parent: ("appInfo", "appInfos", info.id)).map { locale in
                JSONText.object([("id", .string(locale.id)), ("fields", Self.fields(locale, ["locale", "name", "subtitle", "privacyPolicyUrl", "privacyChoicesUrl", "privacyPolicyText"]))])
            }
            appInfos.append(.object([("id", .string(info.id)), ("fields", Self.fields(info, ["appStoreState", "state"])), ("localizations", .array(localizations))]))
        }

        var versions: [JSONText] = [], hashes: Set<String> = [], screenshotCount = 0
        try progress("Reading versions", 0)
        // Screenshots come from Asset Library placements. The deprecated sets are read only for languages without placements.
        let reader = libraryReader(appId: appId, client: client)
        var images: [String: AppStoreConnectClient.Resource]?
        do {
            let library = try await reader.library(); try check()
            let resources = try await reader.children("/v1/appAssetLibraries/\(library)/images?limit=200", type: AssetLibrary.Kind.image.resource, parent: ("assetLibrary", "appAssetLibraries", library))
            guard (try? resources.map { try AssetLibrary.Asset($0, kind: .image) }) != nil else { throw ImportFailure.download }
            images = Dictionary(uniqueKeysWithValues: resources.map { ($0.id, $0) })
        } catch AppStoreConnectClient.Failure.status(let code) where [403, 404].contains(code) { images = nil }
        try check()
        for version in try await list("/v1/apps/\(appId)/appStoreVersions?include=app&limit=200", type: "appStoreVersions", parent: ("app", "apps", appId)) {
            try check()
            var localizations: [JSONText] = []
            let platform = Self.value(version, "platform")
            for locale in try await list("/v1/appStoreVersions/\(version.id)/appStoreVersionLocalizations?limit=200", type: "appStoreVersionLocalizations", parent: ("appStoreVersion", "appStoreVersions", version.id)) {
                var sets: [JSONText] = []
                if let images {
                    let placements = try await reader.placements(target: .init(id: locale.id, name: "", platform: platform, state: "", surface: .versions)).filter { $0.type == ReleaseMedia.screenshot && $0.kind == .image }
                    try check()
                    var groups: [String] = []
                    for placement in placements where !groups.contains(placement.group) { groups.append(placement.group) }
                    for group in groups {
                        var screenshots: [JSONText] = []
                        for placement in placements where placement.group == group {
                            guard let image = images[placement.assetId] else { throw ImportFailure.download }
                            if screenshotCount == 0 { try progress("Downloading screenshots", 0) }
                            let entry = try await screenshot(image, id: placement.id, reusable: previousId == nil ? nil : reusable[placement.id], client: client, check: check)
                            screenshotCount += 1; try progress("Downloading screenshots", screenshotCount)
                            if let hash = entry["sha256"]?.text { hashes.insert(hash) }
                            screenshots.append(entry)
                        }
                        let size = screenshots.first.flatMap { first in AssetLibrary.integer(first["width"]).flatMap { width in AssetLibrary.integer(first["height"]).map { (width, $0) } } }
                        let type = size.flatMap { ScreenshotSpecs.type(platform: platform, width: $0.0, height: $0.1) } ?? group
                        sets.append(.object([("id", .string("\(locale.id)-\(group)")), ("displayType", .string(type)), ("placementGroup", .string(group)), ("screenshots", .array(screenshots))]))
                    }
                }
                for set in try await (sets.isEmpty ? list("/v1/appStoreVersionLocalizations/\(locale.id)/appScreenshotSets?limit=200", type: "appScreenshotSets", parent: ("appStoreVersionLocalization", "appStoreVersionLocalizations", locale.id)) : []) {
                    var screenshots: [JSONText] = []
                    for shot in try await list("/v1/appScreenshotSets/\(set.id)/appScreenshots?limit=200", type: "appScreenshots", parent: ("appScreenshotSet", "appScreenshotSets", set.id)) {
                        try check()
                        if screenshotCount == 0 { try progress("Downloading screenshots", 0) }
                        let entry = try await screenshot(shot, reusable: previousId == nil ? nil : reusable[shot.id], client: client, check: check)
                        screenshotCount += 1; try progress("Downloading screenshots", screenshotCount)
                        if let hash = entry["sha256"]?.text { hashes.insert(hash) }
                        screenshots.append(entry)
                    }
                    sets.append(.object([("id", .string(set.id)), ("displayType", .string(Self.value(set, "screenshotDisplayType"))), ("screenshots", .array(screenshots))]))
                }
                localizations.append(.object([("id", .string(locale.id)), ("fields", Self.fields(locale, ["locale", "description", "keywords", "marketingUrl", "promotionalText", "supportUrl", "whatsNew"])), ("screenshotSets", .array(sets))]))
            }
            versions.append(.object([("id", .string(version.id)), ("fields", Self.fields(version, ["platform", "versionString", "appStoreState", "appVersionState", "copyright", "createdDate"])), ("localizations", .array(localizations))]))
        }

        let revision = JSONText.object([
            ("schemaVersion", .number(1)), ("id", .string(revisionId)), ("importedAt", .string(CustomerReview.isoString(now()))),
            ("account", .object([("id", .string(account.id)), ("name", .string(account.name))])),
            ("app", .object([("id", .string(appId)), ("name", .string(Self.value(app, "name"))), ("bundleId", .string(Self.value(app, "bundleId"))),
                             ("sku", .string(Self.value(app, "sku"))), ("primaryLocale", .string(Self.value(app, "primaryLocale")))])),
            ("appInfos", .array(appInfos)), ("versions", .array(versions)),
        ])
        try check()
        // An unchanged listing keeps its first import: one revision per change, however often it syncs.
        if let previous, let previousId, Self.revisionContent(previous) == Self.revisionContent(revision) {
            try progress("No changes since the last import", screenshotCount)
            return ImportResult(revisionId: previousId, changed: false, screenshots: screenshotCount)
        }
        for hash in hashes { _ = try media.metadata(hash) }
        try progress("Saving revision", screenshotCount)
        try storeAccess { store in
            try store.transaction { current in
                try check()
                let key = "\(account.id):\(appId):\(revisionId)"
                guard try current("revisions", key) == nil else { throw ImportFailure.status }
                return [.put(namespace: "revisions", key: key, json: revision.data),
                        .put(namespace: "latest_imports", key: "\(account.id):\(appId)", json: JSONText.object([("schemaVersion", .number(1)), ("revisionId", .string(revisionId)), ("importedAt", revision["importedAt"]!)]).data)]
            }
        }
        return ImportResult(revisionId: revisionId, changed: true, screenshots: screenshotCount)
    }

    /// A screenshot already saved with the same source checksum is reused; anything else is downloaded and encrypted.
    func screenshot(_ resource: AppStoreConnectClient.Resource, id: String? = nil, reusable: JSONText?, client: AppStoreConnectClient, check: () throws -> Void) async throws -> JSONText {
        try check()
        let asset = try Self.screenshotAsset(resource), fileName = Self.value(resource, "fileName")
        if let reusable, let fingerprint = asset.sourceFingerprint, reusable["sourceFingerprint"]?.text == fingerprint,
           let hash = reusable["sha256"]?.text, let type = reusable["contentType"]?.text, ["image/png", "image/jpeg"].contains(type), (try? media.read(hash)) != nil,
           case .object(let pairs) = reusable {
            return .object(pairs.map { $0.0 == "fileName" ? ($0.0, .string(fileName)) : $0 })
        }
        let (bytes, type) = try await client.image(asset.url)
        try check()
        let saved = try media.write(bytes, limit: 50_000_000)
        guard saved.length == bytes.count else { throw ImportFailure.download }
        var fields: [(String, JSONText)] = []
        if let fingerprint = asset.sourceFingerprint { fields.append(("sourceFingerprint", .string(fingerprint))) }
        fields += [("id", .string(id ?? resource.id))]
        if id != nil { fields.append(("assetId", .string(resource.id))) }
        fields += [("fileName", .string(fileName)), ("sha256", .string(saved.hash)), ("contentType", .string(type)),
                   ("width", .number(asset.width)), ("height", .number(asset.height))]
        return .object(fields)
    }

    /// A saved screenshot or preview image from the encrypted media files.
    public func mediaBytes(_ hash: String) throws -> Data { try requireSessionAccess(); return try media.read(hash) }
}
