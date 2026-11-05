import StorebenchCore
import SwiftUI

/// The screenshot and app preview files of a review, folded under one line that says how many are in Asset Library and
/// on this version. Open, each file shows its stage on one line. It is read from the saved review, so it is the same after a restart.
struct ReleaseMediaFiles: View {
    let progress: ReleaseMediaProgress
    @State private var open: Bool

    init(progress: ReleaseMediaProgress) {
        self.progress = progress
        _open = State(initialValue: progress.files.contains(where: Self.failed))
    }

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            ForEach(progress.files) { file in
                StorebenchFact(label: file.name, value: progress.status(file), problem: Self.failed(file), done: progress.done(file))
            }
        } label: {
            Text("\(progress.uploadOnly ? "Asset Library" : "App Previews and Screenshots") · \(progress.summary)")
        }.accessibilityLabel(progress.uploadOnly ? "Asset Library files" : "App Previews and Screenshots files")
            // The list keeps its place and openness while a Save advances; a file that fails opens it.
            .onChange(of: progress.files.contains(where: Self.failed)) { _, failed in if failed { open = true } }
    }

    private static func failed(_ file: ReleaseMediaProgress.File) -> Bool { [file.uploaded, file.processed, file.added].contains(.failed) }
}
