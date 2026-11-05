import Foundation

/// App Store Connect's Asset Library list: Name, Size, Works With, Modified and Status, with its Type and Status filters.
/// Storebench adds Live Version after Status. Values come from Apple's asset and specification reads only.
public enum AssetLibraryTable {
    public enum Column: String, Sendable, CaseIterable {
        case name, size, worksWith, modified, status, version
        public var title: String {
            switch self { case .name: "Name"; case .size: "Size"; case .worksWith: "Works With"; case .modified: "Modified"; case .status: "Status"; case .version: "Live Version" }
        }
    }
    public struct Row: Sendable, Identifiable, Equatable {
        public let asset: AssetLibrary.Asset
        public let size: String?, worksWith: [String], modified: String?, modifiedAt: Date?
        public let version: AssetLibraryVersions.Outcome
        public var id: String { asset.id }
        public var status: String { AppStoreNames.state(asset.state) }
        public var tone: AppStoreNames.Tone { AppStoreNames.tone(asset.state) }
        public var sizeText: String { size ?? "Unknown" }
        public var worksWithText: String { worksWith.isEmpty ? "Unknown" : worksWith.map(AppStoreNames.placementType).joined(separator: ", ") }
        public var modifiedText: String { modified ?? "Unknown" }
    }
    public struct Filters: Sendable, Equatable {
        /// Asset category raw value, or empty for All.
        public var type = ""
        /// Asset state code, or empty for All. All leaves out Archived assets, as App Store Connect does.
        public var status = ""
        public var worksWith = "", size = "", media = ""
        public init() {}
        public var added: [String] { [worksWith.isEmpty ? nil : "worksWith", size.isEmpty ? nil : "size", media.isEmpty ? nil : "media"].compactMap { $0 } }
    }
    /// Statuses in App Store Connect's order, so the filter lists them the same way.
    public static let statuses = ["AWAITING_UPLOAD", "UPLOAD_COMPLETE", "PREPARE_FOR_SUBMISSION", "READY_FOR_REVIEW", "WAITING_FOR_REVIEW", "IN_REVIEW", "ACCEPTED", "APPROVED", "REJECTED", "ARCHIVED", "FAILED"]

    public static func rows(_ assets: [AssetLibrary.Asset], catalog: AssetLibrary.Catalog?, observations: [AssetLibraryVersions.Observation], timeZone: TimeZone = .current) -> [Row] {
        let platforms = Set(observations.flatMap { $0.versions.map(\.platform) }.filter { !$0.isEmpty })
        return assets.map { asset in
            let spec = asset.specId.flatMap { id in catalog?.specs.first { $0.id == id } }
            return Row(asset: asset, size: spec?.value["aspectRatio"]?.text, worksWith: spec.map { worksWith($0, category: asset.category, catalog: catalog, platforms: platforms) } ?? [],
                       modified: AppStoreNames.date(asset.modified, timeZone: timeZone), modifiedAt: asset.modified.flatMap(ISODateParser.date),
                       version: AssetLibraryVersions.outcome(modified: asset.modified, observations: observations, timeZone: timeZone))
        }
    }
    /// The specification's own compatible placement types, or the catalog's placement types that map it and accept the asset's category.
    /// With known app platforms, a type counts only when the catalog maps this specification to one of their placement groups.
    static func worksWith(_ spec: AssetLibrary.Spec, category: String, catalog: AssetLibrary.Catalog?, platforms: Set<String> = []) -> [String] {
        let types = AssetLibrary.items(catalog?.value["placementTypes"]), profiles = AssetLibrary.items(catalog?.value["placementProfileGroups"])
        func mapped(_ type: JSONText) -> Bool {
            AssetLibrary.items(type["specMappings"]).contains { mapping in
                AssetLibrary.strings(mapping["specs"]).contains(spec.id) && (platforms.isEmpty || profiles.contains { profile in profile["placementProfileGroupId"] == mapping["placementGroupId"] && platforms.contains { AssetLibrary.placementPlatforms($0).contains(profile["platform"]?.text ?? "") } })
            }
        }
        let listed = unique(AssetLibrary.strings(spec.value["compatiblePlacementTypes"]))
        if !listed.isEmpty {
            guard !platforms.isEmpty else { return listed }
            let onPlatform = listed.filter { code in types.contains { $0["placementTypeId"]?.text == code && mapped($0) } }
            return onPlatform.isEmpty ? listed : onPlatform
        }
        return unique(types.filter { AssetLibrary.strings($0["acceptsAssetCategories"]).contains(category) && mapped($0) }.compactMap { $0["placementTypeId"]?.text })
    }
    static func unique(_ values: [String]) -> [String] { var seen = Set<String>(); return values.filter { seen.insert($0).inserted } }

    public static func filtered(_ rows: [Row], _ filters: Filters) -> [Row] {
        rows.filter { row in
            (filters.type.isEmpty || row.asset.category == filters.type)
                && (filters.status.isEmpty ? row.asset.state != "ARCHIVED" : row.asset.state == filters.status)
                && (filters.worksWith.isEmpty || row.worksWith.contains(filters.worksWith))
                && (filters.size.isEmpty || row.size == filters.size)
                && (filters.media.isEmpty || row.asset.kind.rawValue == filters.media)
        }
    }
    public static func sorted(_ rows: [Row], by column: Column, descending: Bool) -> [Row] {
        DataTablePresentation.sorted(rows, descending: descending) { row in
            switch column {
            case .name: .text(row.asset.name)
            case .size: row.size.map { .text($0) } ?? .unknown
            case .worksWith: row.worksWith.isEmpty ? .unknown : .text(row.worksWithText)
            case .modified: row.modifiedAt.map { .number($0.timeIntervalSince1970) } ?? .unknown
            case .status: .number(Double(statuses.firstIndex(of: row.asset.state) ?? statuses.count))
            case .version: row.version.known ? .text(row.version.summary) : .unknown
            }
        }
    }
    /// Choices offered by Add Filters, from the values the current rows actually have.
    public static func choices(_ rows: [Row]) -> (worksWith: [String], sizes: [String]) {
        (unique(rows.flatMap(\.worksWith)).sorted { AppStoreNames.placementType($0) < AppStoreNames.placementType($1) },
         unique(rows.compactMap(\.size)).sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }
}
