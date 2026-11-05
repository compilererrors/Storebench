import Foundation

/// Version screenshots and previews live in the App Asset Library as placements. The deprecated set resources are only read,
/// for languages Apple has not moved to placements; Storebench never writes them.
enum ReleaseMedia {
    static let screenshot = "APP_SCREENSHOT", preview = "APP_PREVIEW"
    static let legacyRoots: Set<String> = ["appScreenshotSets", "appScreenshots", "appPreviewSets", "appPreviews"]

    static func placementType(_ kind: AssetLibrary.Kind) -> String { kind == .image ? screenshot : preview }

    /// Placement groups whose specifications accept every file, read from Apple's live catalog for this platform.
    static func groups(_ catalog: AssetLibrary.Catalog, kind: AssetLibrary.Kind, platform: String, files: [(width: Int, height: Int, ext: String?)]) -> [String] {
        let type = placementType(kind)
        let slots = catalog.slots(surface: .versions, platform: platform.isEmpty ? nil : platform, category: AssetLibrary.Category.listing.rawValue).filter { $0.type == type }
        var result: [String] = []
        for slot in slots where !result.contains(slot.group) && !files.isEmpty {
            let specs = catalog.specs.filter { $0.kind == kind && slot.specs.contains($0.id) }
            if files.allSatisfy({ file in specs.contains { accepts($0, width: file.width, height: file.height, ext: file.ext) } }) { result.append(slot.group) }
        }
        return result
    }

    static func accepts(_ spec: AssetLibrary.Spec, width: Int, height: Int, ext: String?) -> Bool {
        guard let d = spec.value["dimensions"], let minW = AssetLibrary.integer(d["minWidth"]), let maxW = AssetLibrary.integer(d["maxWidth"]),
              let minH = AssetLibrary.integer(d["minHeight"]), let maxH = AssetLibrary.integer(d["maxHeight"]), (minW...maxW).contains(width), (minH...maxH).contains(height) else { return false }
        guard let ext else { return true }
        let allowed = AssetLibrary.strings(spec.value["fileExtensions"]).map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        return allowed.contains(ext.lowercased()) || ext.lowercased() == "jpg" && allowed.contains("jpeg")
    }

    /// The legacy delivery vocabulary for a placed library asset, so release status reads both models the same way.
    static func delivery(asset: AssetLibrary.Asset?, placement: AssetLibrary.Placement) -> String {
        guard let asset else { return "" }
        if ["FAILED", "REJECTED"].contains(asset.state) { return "FAILED" }
        if ["AWAITING_UPLOAD", "UPLOAD_COMPLETE"].contains(asset.state) || placement.state == "ASSET_PROCESSING" { return "PROCESSING" }
        return ["PREPARE_FOR_SUBMISSION", "READY_FOR_REVIEW", "WAITING_FOR_REVIEW", "IN_REVIEW", "ACCEPTED", "APPROVED"].contains(asset.state) ? "COMPLETE" : ""
    }

    /// A poster time in seconds as the library's HH:MM:SS:FF frame time code.
    static func timeCode(_ seconds: Double, frameRate: Double) throws -> String {
        guard seconds.isFinite, seconds >= 0, seconds <= 30, frameRate.isFinite, frameRate > 0, frameRate <= 240 else { throw PublishFailure.invalid("Invalid preview poster time.") }
        let whole = Int(seconds), frame = min(Int(((seconds - Double(whole)) * frameRate).rounded(.down)), Int(frameRate.rounded(.up)) - 1)
        return String(format: "00:00:%02d:%02d", whole, max(frame, 0))
    }

    static func label(_ group: String) -> String { group.replacingOccurrences(of: "_", with: " ").localizedCapitalized }

    /// The specifications Apple's current catalog accepts for this platform's version media, described in its own sizes and formats.
    static func acceptedSizes(_ catalog: AssetLibrary.Catalog, kind: AssetLibrary.Kind, platform: String) -> [String] {
        let type = placementType(kind)
        let slots = catalog.slots(surface: .versions, platform: platform.isEmpty ? nil : platform, category: AssetLibrary.Category.listing.rawValue).filter { $0.type == type }
        var result: [String] = []
        for spec in catalog.specs where spec.kind == kind && slots.contains(where: { $0.specs.contains(spec.id) }) && !result.contains(spec.description) { result.append(spec.description) }
        return result
    }

    /// "Mac screenshots are 2000 × 1220 px. Apple accepts …" for media no placement takes.
    static func sizes(name: String, files: [(width: Int, height: Int, ext: String?)], accepted: [String]) -> String {
        var seen: [String] = []
        for file in files where !seen.contains("\(file.width) × \(file.height) px") { seen.append("\(file.width) × \(file.height) px") }
        let taken = accepted.isEmpty ? "Apple's current specifications list no \(name) size for this platform." : "Apple accepts " + accepted.joined(separator: "; ") + "."
        return "\(name) screenshots are \(seen.joined(separator: ", ")). " + taken
    }

    /// Why no single placement takes the selected files: their sizes, or a platform Apple's catalog does not list.
    static func unplaced(_ catalog: AssetLibrary.Catalog, kind: AssetLibrary.Kind, platform: String, displayType: String, localeName: String, files: [(name: String, width: Int, height: Int, ext: String)]) -> String {
        let name = StoreLocales.displayTypeName(displayType), plural = kind == .image ? "screenshots" : "app previews", type = placementType(kind)
        let accepted = acceptedSizes(catalog, kind: kind, platform: platform)
        if accepted.isEmpty {
            var platforms: [String] = []
            for slot in catalog.slots(surface: .versions, category: AssetLibrary.Category.listing.rawValue) where slot.type == type && !platforms.contains(slot.platform) { platforms.append(slot.platform) }
            return "Apple's current specifications list no \(plural) for \(AppStoreNames.platform(platform)) (\(platform)), only for \(platforms.isEmpty ? "no platform" : platforms.joined(separator: ", ")). Nothing was sent."
        }
        let slots = catalog.slots(surface: .versions, platform: platform.isEmpty ? nil : platform, category: AssetLibrary.Category.listing.rawValue).filter { $0.type == type }
        let specs = catalog.specs.filter { spec in spec.kind == kind && slots.contains { $0.specs.contains(spec.id) } }
        let refused = files.filter { file in !specs.contains { accepts($0, width: file.width, height: file.height, ext: file.ext) } }
        func shown(_ list: [(name: String, width: Int, height: Int, ext: String)]) -> String {
            list.prefix(5).map { "\($0.name) (\($0.width) × \($0.height) px, \($0.ext))" }.joined(separator: "; ") + (list.count > 5 ? "; and \(list.count - 5) more" : "")
        }
        let fix = " Replace them in step 2, Text and Screenshots, then prepare the review again. Nothing was sent."
        if refused.isEmpty {
            return "The \(name) \(plural) for \(localeName) mix sizes that Apple places in different groups: \(shown(files)). Choose \(plural) of one size." + fix
        }
        return "Apple does not accept these \(name) \(plural) for \(localeName): \(shown(refused)). Apple accepts " + accepted.joined(separator: "; ") + "." + fix
    }
}
