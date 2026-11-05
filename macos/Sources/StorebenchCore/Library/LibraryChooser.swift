import Foundation

/// Local library entry points share the configured scope and the complete immutable archive contract.
public enum LibraryChooser {
    public static let sections: [AppNavigation.Section] = [.journal, .release, .quickRelease, .startTesting, .pricing, .createMedia, .setUpReports, .localizations, .keywords, .media, .reviewInfo, .information,
                                                            .pricingAvailability, .appPrivacy, .accessibility, .inAppPurchases, .subscriptions, .publish, .analytics, .aso, .asoDiff, .finance, .reviews,
                                                            .builds, .feedback, .groups, .externalTesting, .testers, .testInformation]
    public static func selection(_ section: AppNavigation.Section) -> String { "library:section:" + section.key }
    public static func selected(_ value: String?) -> AppNavigation.Section? { sections.first { selection($0) == value } }
    public struct Shot: Identifiable, Sendable, Equatable {
        public let index: Int, value: JSONText, source: SavedMediaSource
        public var id: String { source.revisionId + "/" + String(index) }
        public var fileName: String { value["fileName"]?.text ?? "Screenshot" }
        public var width: Int { if case .number(let number)? = value["width"], let result = Int(exactly: number) { return result }; return 0 }
        public var height: Int { if case .number(let number)? = value["height"], let result = Int(exactly: number) { return result }; return 0 }
        public var galleryItem: ScreenshotSetDraft.Item { .init(id: id, fileName: fileName, sha256: value["sha256"]?.text ?? "", width: width > 0 ? width : nil, height: height > 0 ? height : nil, local: false) }
    }
    static func images(_ revision: ArchivedRevision) throws -> [Shot] {
        func array(_ value: JSONText?) throws -> [JSONText] { guard case .array(let result)? = value else { throw RevisionHistoryFailure.invalid }; return result }
        let account = try required(revision.value["account"]?["id"]), app = try required(revision.value["app"]?["id"])
        var result: [Shot] = []
        for version in try array(revision.value["versions"]) {
            for locale in try array(version["localizations"]) {
                for set in try array(locale["screenshotSets"]) {
                    for image in try array(set["screenshots"]) {
                        let hash = try required(image["sha256"]), id = try required(image["id"]), index = result.count
                        result.append(Shot(index: index, value: image, source: .init(accountId: account, appId: app, revisionId: revision.id, itemId: id,
                            kind: .archivedScreenshot(index: index, hash: hash, documentRevision: revision.documentRevision))))
                    }
                }
            }
        }
        return result
    }
    static func required(_ value: JSONText?) throws -> String { guard let value = value?.text else { throw RevisionHistoryFailure.invalid }; return value }
    public struct Entry: Identifiable, Sendable, Equatable {
        public let row: ConnectedApps.Row, languages: [String]?, screenshots: [Shot]?
        public var id: String { row.id }
        public var preview: [Shot]? { screenshots.map { Array($0.prefix(5)) } }
        public func name(for section: AppNavigation.Section) -> String {
            section == .pricing ? ConnectedApps.name(saved: nil, configured: row.account.appNames?[row.app.id], appId: row.app.id) : row.name
        }
        public init(row: ConnectedApps.Row, latest: JSONText?, documentRevision: Int = 1) throws {
            self.row = row
            guard let count = row.revisionCount else {
                guard latest == nil else { throw ConnectedApps.Failure.changed }; languages = nil; screenshots = nil; return
            }
            guard count > 0 else {
                guard latest == nil else { throw ConnectedApps.Failure.changed }; languages = []; screenshots = []; return
            }
            guard let latest, let id = latest["id"]?.text, documentRevision > 0 else { throw ConnectedApps.Failure.changed }
            let revision = try ConnectedApps.savedRevision(latest, accountId: row.account.id, appId: row.app.id, id: id, documentRevision: documentRevision)
            guard row.latestImportedAt == nil || row.latestImportedAt == revision.importedAt,
                  TextSemantics.same(row.name, ConnectedApps.name(saved: latest["app"]?["name"]?.text, configured: row.account.appNames?[row.app.id], appId: row.app.id)) else { throw ConnectedApps.Failure.changed }
            var seen = Set<Data>(), labels: [String] = []
            for version in WorkspaceSession.items(latest["versions"]) {
                guard case .array(let localizations)? = version["localizations"] else { throw RevisionHistoryFailure.invalid }
                for locale in localizations {
                    let value = locale["fields"]?["locale"], fallback = try LibraryChooser.required(locale["id"])
                    let label = value == .bool(true) ? "true" : value == .bool(false) ? fallback : RevisionComparison.fallback(value, fallback)
                    if seen.insert(Data(label.utf8)).inserted { labels.append(label) }
                }
            }
            languages = labels; screenshots = try LibraryChooser.images(revision)
        }
        public func destination(_ section: AppNavigation.Section) throws -> LibraryOverview.Destination { try .init(row: row, section: section) }
    }
}

extension WorkspaceSession {
    public func libraryChooser(_ section: AppNavigation.Section) throws -> [LibraryChooser.Entry] {
        guard LibraryChooser.sections.contains(section) else { throw ConnectedApps.Failure.changed }
        let configured = try accounts(); var result: [LibraryChooser.Entry] = []
        guard Set(configured.map(\.id)).count == configured.count else { throw ConnectedApps.Failure.changed }
        for account in configured {
            let snapshot = ConnectedApps.AccountSnapshot(account)
            var seen = Set<String>()
            for app in account.apps where seen.insert(app.id).inserted {
                try Task.checkCancellation(); _ = try currentAccount(account, exact: true)
                var history: [ArchivedRevision]?
                if ![.pricing, .pricingAvailability, .inAppPurchases, .subscriptions].contains(section) {
                    do { history = try connectedAppHistory(accountId: account.id, appId: app.id) }
                    catch { try requireSessionAccess(); try Task.checkCancellation(); _ = try currentAccount(account, exact: true) }
                }
                let latest = history?.first
                let row = try ConnectedApps.Row(snapshot: snapshot, app: app, savedName: latest?.value["app"]?["name"]?.text, revisionCount: history?.count, latestImportedAt: latest?.importedAt)
                result.append(try .init(row: row, latest: latest?.value, documentRevision: latest?.documentRevision ?? 1))
            }
        }
        for account in configured { _ = try currentAccount(account, exact: true) }
        guard try accounts() == configured else { throw ConnectedApps.Failure.changed }
        try Task.checkCancellation(); try requireSessionAccess(); return result
    }
}
