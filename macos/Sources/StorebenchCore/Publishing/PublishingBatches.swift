import Foundation

extension WorkspaceSession {
    /// Processing checks are reads, so a full screenshot set can wait on Apple together.
    static func publishingBatchLimit(_ step: PublishStep) -> Int {
        mediaBatchFamily(step) == "processed" ? ScreenshotSpecs.maximum : sendTogetherLimit
    }
    /// Selects a bounded wave from the approved plan. Media files may advance independently inside one upload section;
    /// removals, placements, ordering and other business actions remain separate barriers.
    static func stepsReadyTogether(_ steps: [PublishStep], from start: Int, ids: [String: String]) -> [Int] {
        guard steps.indices.contains(start) else { return [] }
        guard let family = mediaBatchFamily(steps[start]) else {
            var selected: [Int] = [], targets = Set<String>()
            for index in stepsSentTogether(steps, from: start) {
                let step = steps[index]
                guard selected.count < sendTogetherLimit else { break }
                let target = step.guardValue?["kind"]?.text == "pricing-setup"
                    ? JSONText.array([step.guardValue?["subscriptionId"] ?? .null, step.guardValue?["territory"] ?? .null]).stringify()
                    : (try? apiPath(step.path, ids: ids)) ?? ""
                guard targets.insert(target).inserted else { break }
                if step.state == "pending" { selected.append(index) }
            }
            return selected
        }
        var selected: [Int] = [], targets = Set<String>()
        let pipelines = ["reserve", "upload", "commit", "processed"]
        let pipeline = pipelines.contains(family)
        for index in start..<steps.count {
            let step = steps[index], next = mediaBatchFamily(step)
            guard pipeline ? next.map(pipelines.contains) == true : next == family else { break }
            guard next == family, step.state == "pending" else { continue }
            // Same-file steps have implicit dependencies as well as references: commit must follow upload.
            let owner = mediaBatchOwner(step)
            guard !steps[..<index].contains(where: { mediaBatchOwner($0) == owner && $0.state != "done" }),
                  let path = try? apiPath(step.path, ids: ids) else { continue }
            let body: JSONText?
            do { body = try step.body.map { try resolve($0, ids: ids) } } catch { continue }
            let target: String
            if family == "reserve" {
                target = step.guardValue?["asset"]?.stringify() ?? path
            } else if family == "place" {
                target = body?["data"]?["relationships"]?.stringify() ?? path
            } else { target = path }
            guard targets.insert(target).inserted else { continue }
            selected.append(index)
            if selected.count == publishingBatchLimit(steps[start]) { break }
        }
        return selected.first == start ? selected : [start]
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
