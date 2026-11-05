import Foundation
import Testing
@testable import StorebenchCore

@Suite struct AssetLibraryTableTests {
    init() throws { _ = try TestIsolation.require() }
    let utc = TimeZone(identifier: "UTC")!
    func at(_ text: String) -> Date { ISODateParser.date(text)! }
    func seen(_ text: String, _ versions: [(String, String)], platform: String = "MAC_OS") -> AssetLibraryVersions.Observation {
        .init(at: at(text), versions: versions.map { .init(platform: platform, number: $0.0, state: $0.1) })
    }
    func outcome(_ modified: String?, _ observations: [AssetLibraryVersions.Observation]) -> AssetLibraryVersions.Outcome {
        AssetLibraryVersions.outcome(modified: modified, observations: observations, timeZone: utc)
    }

    @Test func liveVersionNeedsAgreeingObservationsOnBothSides() {
        let history = [seen("2026-09-01T10:00:00Z", [("1.6", "READY_FOR_DISTRIBUTION"), ("1.7", "PREPARE_FOR_SUBMISSION")]),
                       seen("2026-10-26T08:00:00Z", [("1.6", "READY_FOR_DISTRIBUTION"), ("1.7", "WAITING_FOR_REVIEW")])]
        let known = outcome("2026-10-25T12:00:00.000+00:00", history)
        #expect(known.known && known.summary == "1.6 Ready for Distribution")
        #expect(known.detail.contains("Sep 1, 2026") && known.detail.contains("Oct 26, 2026"))
        let after = outcome("2026-10-26T09:00:00Z", history)
        #expect(!after.known && after.summary == "Unknown" && after.detail.contains("Oct 26, 2026"))
        let before = outcome("2026-08-01T09:00:00Z", history)
        #expect(!before.known && before.summary == "Unknown")
        #expect(!outcome(nil, history).known && !outcome("not a date", history).known && !outcome("2026-10-25T12:00:00Z", []).known)
    }

    @Test func pendingDeveloperReleaseIsShownBesideTheLiveVersion() {
        let history = [seen("2026-10-20T10:00:00Z", [("1.6", "READY_FOR_DISTRIBUTION"), ("1.7", "PENDING_DEVELOPER_RELEASE")]),
                       seen("2026-10-30T10:00:00Z", [("1.6", "READY_FOR_DISTRIBUTION"), ("1.7", "PENDING_DEVELOPER_RELEASE")])]
        let result = outcome("2026-10-25T12:00:00Z", history)
        #expect(result.known && result.summary == "1.6 Ready for Distribution · 1.7 Pending Developer Release")
        let approvedLater = [seen("2026-10-20T10:00:00Z", [("1.6", "READY_FOR_DISTRIBUTION"), ("1.7", "WAITING_FOR_REVIEW")]),
                             seen("2026-10-30T10:00:00Z", [("1.6", "READY_FOR_DISTRIBUTION"), ("1.7", "PENDING_DEVELOPER_RELEASE")])]
        let partly = outcome("2026-10-25T12:00:00Z", approvedLater)
        #expect(partly.summary == "1.6 Ready for Distribution · 1.7 approval unknown" && partly.detail.contains("unknown"))
    }

    @Test func aReleaseBetweenObservationsStaysUnknown() {
        let history = [seen("2026-10-20T10:00:00Z", [("1.6", "READY_FOR_DISTRIBUTION"), ("1.7", "PENDING_DEVELOPER_RELEASE")]),
                       seen("2026-10-30T10:00:00Z", [("1.6", "REPLACED_WITH_NEW_VERSION"), ("1.7", "READY_FOR_DISTRIBUTION")])]
        let result = outcome("2026-10-25T12:00:00Z", history)
        #expect(!result.known && result.summary == "Unknown" && result.detail.contains("1.6 → 1.7"))
        let exact = outcome("2026-10-30T10:00:00Z", history)
        #expect(exact.known && exact.summary == "1.7 Ready for Distribution")
    }

    @Test func noLiveVersionIsKnownOnlyWhenNothingWasReleasedInBetween() {
        let unreleased = [seen("2026-10-20T10:00:00Z", [("1.0", "PREPARE_FOR_SUBMISSION")]), seen("2026-10-30T10:00:00Z", [("1.0", "WAITING_FOR_REVIEW")])]
        #expect(outcome("2026-10-25T12:00:00Z", unreleased).summary == "No version Ready for Distribution")
        let releasedAndRemoved = [seen("2026-10-20T10:00:00Z", [("1.0", "PREPARE_FOR_SUBMISSION")]), seen("2026-10-30T10:00:00Z", [("1.0", "DEVELOPER_REMOVED_FROM_SALE")])]
        #expect(!outcome("2026-10-25T12:00:00Z", releasedAndRemoved).known)
    }

    @Test func platformsAreNamedWhenAnAppHasSeveral() {
        let history = [AssetLibraryVersions.Observation(at: at("2026-10-20T10:00:00Z"), versions: [.init(platform: "MAC_OS", number: "1.6", state: "READY_FOR_DISTRIBUTION"), .init(platform: "IOS", number: "2.0", state: "READY_FOR_SALE")]),
                       AssetLibraryVersions.Observation(at: at("2026-10-30T10:00:00Z"), versions: [.init(platform: "MAC_OS", number: "1.6", state: "READY_FOR_DISTRIBUTION"), .init(platform: "IOS", number: "2.1", state: "READY_FOR_DISTRIBUTION")])]
        let result = outcome("2026-10-25T12:00:00Z", history)
        #expect(!result.known && result.summary == "iOS Unknown · macOS 1.6 Ready for Distribution")
    }

    @Test func savedImportsBecomeObservationsButLocalDraftsDoNot() throws {
        func revision(_ id: String, origin: String?, at: String, state: String) throws -> Revision {
            var value: [String: Any] = ["schemaVersion": 1, "id": id, "importedAt": at, "app": ["id": "1000000001", "name": "Synthetic App", "bundleId": "com.example.synthetic", "sku": "SYNTHETIC", "primaryLocale": "en-US"],
                                        "appInfos": [], "versions": [["id": "version-\(id)", "fields": ["platform": "MAC_OS", "versionString": "1.6", "appVersionState": state], "localizations": []]]]
            if let origin { value["origin"] = origin }
            return try JSONDecoder().decode(Revision.self, from: JSONSerialization.data(withJSONObject: value))
        }
        let observations = AssetLibraryVersions.observations([
            try revision("b", origin: nil, at: "2026-10-30T10:00:00.000Z", state: "READY_FOR_DISTRIBUTION"),
            try revision("draft", origin: "local", at: "2026-10-25T10:00:00.000Z", state: "PREPARE_FOR_SUBMISSION"),
            try revision("a", origin: nil, at: "2026-10-20T10:00:00.000Z", state: "READY_FOR_DISTRIBUTION"),
        ])
        #expect(observations.map(\.at) == [at("2026-10-20T10:00:00Z"), at("2026-10-30T10:00:00Z")])
        #expect(outcome("2026-10-25T12:00:00Z", observations).summary == "1.6 Ready for Distribution")
        let current = AssetLibraryVersions.observation(current: [.init(id: "v", platform: "MAC_OS", number: "1.7", state: "WAITING_FOR_REVIEW", releaseType: "MANUAL", copyright: "")], at: at("2026-10-31T10:00:00Z"))
        #expect(current.versions == [.init(platform: "MAC_OS", number: "1.7", state: "WAITING_FOR_REVIEW")])
    }

    func asset(_ id: String, name: String, state: String, modified: String?, category: String = "APP_SCREENSHOTS_AND_PREVIEWS", spec: String? = "synthetic-mac") throws -> AssetLibrary.Asset {
        var attributes: [String: Any] = ["fileName": name, "fileSize": 2048, "category": category, "state": state]
        if let modified { attributes["lastModifiedDate"] = modified }
        if let spec { attributes["specId"] = spec }
        let data = try JSONSerialization.data(withJSONObject: ["type": "appAssetLibraryImages", "id": id, "attributes": attributes])
        return try AssetLibrary.Asset(JSONDecoder().decode(AppStoreConnectClient.Resource.self, from: data), kind: .image)
    }
    func catalog() throws -> AssetLibrary.Catalog {
        let mac: [String: Any] = ["specId": "synthetic-mac", "dimensions": ["minWidth": 2880, "maxWidth": 2880, "minHeight": 1800, "maxHeight": 1800], "aspectRatio": "16:9", "maxFileSize": 1000,
                                  "fileExtensions": [".png"], "compatiblePlacementTypes": ["APP_SCREENSHOT", "IMESSAGE_APP_SCREENSHOT"]]
        let header: [String: Any] = ["specId": "synthetic-header", "dimensions": ["minWidth": 3840, "maxWidth": 3840, "minHeight": 1646, "maxHeight": 1646], "aspectRatio": "7:3", "maxFileSize": 1000, "fileExtensions": [".png"]]
        let types: [[String: Any]] = [
            ["placementTypeId": "APP_SCREENSHOT", "acceptsAssetCategories": ["APP_SCREENSHOTS_AND_PREVIEWS"], "specMappings": [["placementGroupId": "SYNTHETIC_MAC", "specs": ["synthetic-mac"]]]],
            ["placementTypeId": "IMESSAGE_APP_SCREENSHOT", "acceptsAssetCategories": ["APP_SCREENSHOTS_AND_PREVIEWS"], "specMappings": [["placementGroupId": "SYNTHETIC_PHONE", "specs": ["synthetic-mac"]]]],
            ["placementTypeId": "PRODUCT_PAGE_HEADER_ASSET", "acceptsAssetCategories": ["CREATIVE_ASSETS"], "specMappings": [["placementGroupId": "SYNTHETIC_MAC", "specs": ["synthetic-header"]]]],
        ]
        let groups: [[String: Any]] = [["placementProfileGroupId": "SYNTHETIC_MAC", "platform": "MAC_APP_STORE"], ["placementProfileGroupId": "SYNTHETIC_PHONE", "platform": "IPHONE_APP_STORE"]]
        let value: [String: Any] = ["type": "appAssetLibraryRefData", "id": "synthetic-catalog", "attributes": ["features": [], "placementProfileGroups": groups, "imageSpecs": [mac, header], "videoSpecs": [], "placementTypes": types, "displayClasses": []]]
        return try AssetLibrary.Catalog([JSONDecoder().decode(AppStoreConnectClient.Resource.self, from: JSONSerialization.data(withJSONObject: value))])
    }

    @Test func rowsUseAppStoreConnectColumnsDatesAndStatusNames() throws {
        let history = [seen("2026-09-01T10:00:00Z", [("1.6", "READY_FOR_DISTRIBUTION")]), seen("2026-10-26T08:00:00Z", [("1.6", "READY_FOR_DISTRIBUTION"), ("1.7", "WAITING_FOR_REVIEW")])]
        let assets = [
            try asset("a1", name: "synthetic-benchmark.png", state: "WAITING_FOR_REVIEW", modified: "2026-10-25T12:00:00.000Z"),
            try asset("a2", name: "synthetic-tools.png", state: "APPROVED", modified: "2026-09-11T09:00:00.000Z"),
            try asset("a3", name: "synthetic-old.png", state: "ARCHIVED", modified: "2026-09-02T09:00:00.000Z"),
            try asset("a4", name: "synthetic-header.png", state: "PREPARE_FOR_SUBMISSION", modified: nil, category: "CREATIVE_ASSETS", spec: "synthetic-header"),
            try asset("a5", name: "synthetic-processing.png", state: "UPLOAD_COMPLETE", modified: "2026-10-26T07:00:00.000Z", spec: nil),
        ]
        let rows = AssetLibraryTable.rows(assets, catalog: try catalog(), observations: history, timeZone: utc)
        let first = try #require(rows.first)
        #expect(first.sizeText == "16:9" && first.worksWithText == "App Screenshots" && first.modifiedText == "Oct 25, 2026" && first.status == "Waiting for Review" && first.tone == .pending)
        #expect(first.version.summary == "1.6 Ready for Distribution")
        #expect(rows[1].status == "Approved" && rows[1].tone == .complete && rows[1].modifiedText == "Sep 11, 2026")
        #expect(rows[3].worksWithText == "Product Page Header" && rows[3].modifiedText == "Unknown" && !rows[3].version.known)
        #expect(rows[4].sizeText == "Unknown" && rows[4].worksWithText == "Unknown" && rows[4].status == "Processing")
        #expect(AssetLibraryTable.Column.allCases.map(\.title) == ["Name", "Size", "Works With", "Modified", "Status", "Live Version"])

        var filters = AssetLibraryTable.Filters()
        #expect(AssetLibraryTable.filtered(rows, filters).map(\.id) == ["a1", "a2", "a4", "a5"])
        filters.status = "ARCHIVED"
        #expect(AssetLibraryTable.filtered(rows, filters).map(\.id) == ["a3"])
        filters = .init(); filters.type = "CREATIVE_ASSETS"
        #expect(AssetLibraryTable.filtered(rows, filters).map(\.id) == ["a4"])
        filters = .init(); filters.worksWith = "APP_SCREENSHOT"; filters.size = "16:9"
        #expect(AssetLibraryTable.filtered(rows, filters).map(\.id) == ["a1", "a2"])
        #expect(AssetLibraryTable.choices(rows).worksWith == ["APP_SCREENSHOT", "PRODUCT_PAGE_HEADER_ASSET"] && AssetLibraryTable.choices(rows).sizes == ["7:3", "16:9"])

        #expect(AssetLibraryTable.sorted(rows, by: .modified, descending: true).map(\.id) == ["a5", "a1", "a2", "a3", "a4"])
        #expect(AssetLibraryTable.sorted(rows, by: .modified, descending: false).map(\.id) == ["a3", "a2", "a1", "a5", "a4"])
        #expect(AssetLibraryTable.sorted(rows, by: .name, descending: false).map(\.id) == ["a1", "a4", "a3", "a5", "a2"])
        #expect(AssetLibraryTable.sorted(rows, by: .status, descending: false).map(\.id) == ["a5", "a4", "a1", "a2", "a3"])
    }

    @Test func sharedLabelsMatchAppStoreConnect() {
        #expect(AppStoreNames.date(at("2026-10-25T23:30:00Z"), timeZone: utc) == "Oct 25, 2026")
        #expect(AppStoreNames.date("2026-10-25T23:30:00-02:00", timeZone: utc) == "Oct 26, 2026")
        #expect(AppStoreNames.state("AWAITING_UPLOAD") == "Uploading" && AppStoreNames.state("ARCHIVED") == "Archived" && AppStoreNames.state("INVITED") == "Invited")
        #expect(AppStoreNames.tone("APPROVED") == .complete && AppStoreNames.tone("READY_FOR_DISTRIBUTION") == .complete)
        #expect(AppStoreNames.tone("WAITING_FOR_REVIEW") == .pending && AppStoreNames.tone("PENDING_DEVELOPER_RELEASE") == .pending)
        #expect(AppStoreNames.tone("REJECTED") == .problem && AppStoreNames.tone("ARCHIVED") == .inactive)
        #expect(AppStoreNames.placementType("APP_PREVIEW") == "App Previews" && AppStoreNames.placementType("NEW_SURFACE_ASSET") == "New Surface Asset")
    }
}
