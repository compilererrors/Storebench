import Foundation

/// How far a Save got with each screenshot and app preview file. App Store Connect keeps the files in Asset Library and
/// shows them on a version only once they are placed there, so each file has three stages: uploaded to Asset Library,
/// processed by Apple and added to the version. Read from the saved review, so it is the same after a restart.
public struct ReleaseMediaProgress: Sendable, Equatable {
    public enum Stage: Sendable, Equatable {
        /// Not part of this Save: the file was already at that stage before it started.
        case skipped
        case waiting, running, done, failed
    }
    public struct File: Sendable, Equatable, Identifiable {
        public let name: String
        public internal(set) var uploaded: Stage, processed: Stage, added: Stage
        /// Apple already had the file where the review wanted it, so the review sent nothing for it.
        public internal(set) var settled = false
        public var id: String { name }
        /// The file is in Asset Library, whether this Save uploaded it or an earlier one did.
        public var inLibrary: Bool { [.done, .skipped].contains(uploaded) }
    }
    public let files: [File]
    public let completed, total: Int
    /// The review stopped, so stages still waiting were not sent.
    public let stopped: Bool
    /// The review waits for approval, so every stage it lists is still to come.
    public let prepared: Bool
    /// An Asset Library upload only: its files are added to App Previews and Screenshots by the next Save.
    public let uploadOnly: Bool

    static let kinds: Set<String> = ["release-media-reserve", "release-media-upload", "asset-library-processed", "release-media-placement", "release-media-order", "release-media-delete", "release-media-abandoned"]
    /// Steps the file rows already show, so a review lists them only on request.
    public static func shows(_ step: PublishStep) -> Bool { step.guardValue?["kind"]?.text.map(kinds.contains) ?? false }

    public init?(_ review: PublishReview) {
        var files: [File] = [], index: [String: Int] = [:]
        var stages: [String: (uploaded: [String], processed: [String], added: [String])] = [:]
        var completed = 0, total = 0
        for step in review.steps {
            let kind = step.guardValue?["kind"]?.text
            let name: String?, stage: WritableKeyPath<(uploaded: [String], processed: [String], added: [String]), [String]>
            switch kind {
            case "release-media-reserve", "release-media-upload": name = step.guardValue?["asset"]?["fileName"]?.text; stage = \.uploaded
            case "asset-library-processed": name = step.guardValue?["fileName"]?.text ?? (step.label.hasPrefix("Verify ") ? String(step.label.dropFirst(7)) : nil); stage = \.processed
            case "release-media-placement": name = step.after; stage = \.added
            case "release-media-order", "release-media-delete", "release-media-abandoned": name = nil; stage = \.added
            default: continue
            }
            total += 1; if step.state == "done" { completed += 1 }
            guard let name, !name.isEmpty else { continue }
            if index[name] == nil { index[name] = files.count; files.append(File(name: name, uploaded: .skipped, processed: .skipped, added: .skipped)) }
            stages[name, default: ([], [], [])][keyPath: stage].append(step.state)
        }
        for name in review.settled where index[name] == nil {
            index[name] = files.count; files.append(File(name: name, uploaded: .skipped, processed: .skipped, added: .skipped, settled: true))
        }
        guard total > 0 || !files.isEmpty else { return nil }
        func stage(_ states: [String]) -> Stage {
            if states.isEmpty { return .skipped }
            if states.contains("failed") { return .failed }
            if states.allSatisfy({ $0 == "done" }) { return .done }
            return states.contains { ["running", "done"].contains($0) } ? .running : .waiting
        }
        for (name, at) in index { guard let value = stages[name] else { continue }; files[at].uploaded = stage(value.uploaded); files[at].processed = stage(value.processed); files[at].added = stage(value.added) }
        self.files = files; self.completed = completed; self.total = total
        stopped = ["failed", "conflict"].contains(review.state); prepared = review.state == "prepared"
        uploadOnly = review.request.mediaStage == PublishRequest.uploadStage
    }

    /// Files Apple has in Asset Library, and files on the version, out of the files in this Save.
    /// Files that are where this review wants them, sent by it or already there.
    public func done(_ file: File) -> Bool { file.settled || file.added == .done || uploadOnly && file.uploaded == .done }

    public var summary: String {
        let library = files.filter(\.inLibrary).count, added = files.filter { $0.added == .done || $0.settled }.count
        if prepared {
            let uploads = files.filter { $0.uploaded != .skipped }.count, adds = files.filter { $0.added != .skipped }.count, settled = files.filter(\.settled).count
            return (uploadOnly ? "\(uploads) of \(files.count) files to upload" : "\(uploads) files to upload · \(adds) to add to App Previews and Screenshots")
                + (settled == 0 ? "" : " · \(settled) already \(uploadOnly ? "in Asset Library" : "added")")
        }
        return uploadOnly ? "\(library) of \(files.count) files in Asset Library" : "\(library) of \(files.count) files in Asset Library · \(added) of \(files.count) added to this version"
    }

    /// One line per file, in App Store Connect's terms.
    public func status(_ file: File) -> String {
        if file.settled { return uploadOnly ? "Already in Asset Library" : "Already in App Previews and Screenshots" }
        if prepared {
            if file.uploaded != .skipped { return uploadOnly ? "Upload to Asset Library" : "Upload to Asset Library, then add to this version" }
            return file.added == .skipped ? "In Asset Library" : "In Asset Library · add to this version"
        }
        if uploadOnly, file.uploaded == .done { return "In Asset Library" }
        switch (file.uploaded, file.processed, file.added) {
        case (_, _, .done): return "Added to this version"
        case (.failed, _, _): return "Upload stopped · not in Asset Library"
        case (_, .failed, _): return "In Asset Library · Apple had not finished processing it"
        case (_, _, .failed): return "In Asset Library · could not be added to this version"
        case (.running, _, _): return "Uploading to Asset Library…"
        case (_, .running, _): return "In Asset Library · Apple is processing it…"
        case (_, _, .running): return "Adding to this version…"
        case (.waiting, _, _): return stopped ? "Not uploaded" : "Waiting to upload"
        case (_, _, .waiting): return stopped ? "In Asset Library · not added to this version yet" : "In Asset Library · waiting to be added to this version"
        case (_, .waiting, _): return stopped ? "In Asset Library · processing not checked" : "In Asset Library · waiting for Apple's processing"
        default: return "In Asset Library"
        }
    }
}
