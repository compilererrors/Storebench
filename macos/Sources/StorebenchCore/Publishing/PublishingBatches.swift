import Foundation

extension WorkspaceSession {
    /// Processing checks are reads, so a full screenshot set can wait on Apple together.
    static func publishingBatchLimit(_ step: PublishStep) -> Int {
        mediaBatchFamily(step) == "processed" ? ScreenshotSpecs.maximum : sendTogetherLimit
    }
    /// Selects a bounded wave from the approved plan. Media files may advance independently inside one upload section;
    /// removals, placements, ordering and other business actions remain separate barriers.
    static func stepsReadyTogether(_ steps: [PublishStep], from start: Int, ids: [String: String], active: Set<Int> = [], rolling: Bool = false) -> [Int] {
        guard steps.indices.contains(start) else { return [] }
        let occupied = Set(active.compactMap { publishingBatchTarget(steps[$0], ids: ids) })
        guard let family = mediaBatchFamily(steps[start]) else {
            var selected: [Int] = [], targets = occupied
            for index in stepsSentTogether(steps, from: start) {
                let step = steps[index]
                guard step.state == "pending" else { continue }
                guard selected.count + active.count < sendTogetherLimit else { break }
                guard let target = publishingBatchTarget(step, ids: ids), targets.insert(target).inserted else { break }
                selected.append(index)
            }
            return selected
        }
        var selected: [Int] = [], targets = occupied
        let pipelines = ["reserve", "upload", "commit", "processed"]
        let pipeline = pipelines.contains(family)
        for index in start..<steps.count {
            let step = steps[index], next = mediaBatchFamily(step)
            guard pipeline ? next.map(pipelines.contains) == true : next == family else { break }
            guard (rolling && pipeline || next == family), step.state == "pending" else { continue }
            // Same-file steps have implicit dependencies as well as references: commit must follow upload.
            let owner = mediaBatchOwner(step)
            guard !steps[..<index].contains(where: { mediaBatchOwner($0) == owner && $0.state != "done" }),
                  let target = publishingBatchTarget(step, ids: ids), !targets.contains(target) else { continue }
            let processing = next == "processed"
            let used = (Array(active) + selected).filter { (mediaBatchFamily(steps[$0]) == "processed") == processing }.count
            guard used < publishingBatchLimit(step) else { continue }
            selected.append(index); targets.insert(target)
            if !rolling, selected.count == publishingBatchLimit(steps[start]) { break }
        }
        return rolling ? selected : selected.first == start ? selected : [start]
    }

    private static func publishingBatchTarget(_ step: PublishStep, ids: [String: String]) -> String? {
        guard let path = try? apiPath(step.path, ids: ids) else { return nil }
        let body: JSONText?
        do { body = try step.body.map { try resolve($0, ids: ids) } } catch { return nil }
        switch mediaBatchFamily(step) {
        case "reserve": return step.guardValue?["asset"]?.stringify() ?? path
        case "place": return body?["data"]?["relationships"]?.stringify() ?? path
        default:
            if step.guardValue?["kind"]?.text == "pricing-setup" {
                return JSONText.array([step.guardValue?["subscriptionId"] ?? .null, step.guardValue?["territory"] ?? .null]).stringify()
            }
            return path
        }
    }

    private static func mediaBatchOwner(_ step: PublishStep) -> String {
        step.group ?? reservation(step.path) ?? step.key
    }

    private static func mediaBatchFamily(_ step: PublishStep) -> String? {
        let root = step.path.first?.text, guardKind = step.guardValue?["kind"]?.text
        let asset = root == AssetLibrary.Kind.image.resource || root == AssetLibrary.Kind.video.resource
        if asset {
            if step.kind == .api && step.method == "POST" && guardKind == "release-media-reserve" { return "reserve" }
            if step.kind == .upload && guardKind == "release-media-upload" { return "upload" }
            if step.kind == .api && step.method == "PATCH" && guardKind == "release-media-upload" { return "commit" }
            if step.kind == .verify && guardKind == "asset-library-processed" { return "processed" }
            if step.kind == .api && step.method == "DELETE" && guardKind == "release-media-abandoned" { return "cleanup" }
        }
        if step.kind == .api && root == "appAssetLibraryPlacements" {
            if step.method == "DELETE" && guardKind == "release-media-delete" { return "remove" }
            if step.method == "POST" && guardKind == "release-media-placement" { return "place" }
        }
        return nil
    }
}
