import StorebenchCore
import SwiftUI

/// The active release flow owns its version command; other pages can explicitly open Release.
struct ReleaseVersionButton: View {
    let section: AppNavigation.Section
    let hasPlan: Bool
    let continueHere: () -> Void
    let openRelease: () -> Void
    private var quick: Bool { section == .quickRelease }
    var body: some View {
        Button {
            if section == .release || quick { continueHere() } else { openRelease() }
        } label: {
            StorebenchLabel(hasPlan ? "Continue Release" : quick ? "Prepare Release" : "New Version",
                            icon: hasPlan ? "release" : "plus", size: 16)
        }
        .help(quick ? "Continue this update in Quick Release" : hasPlan ? "Continue the release in progress" : "Prepare a new version")
        .storebenchControlID("workspace.version")
    }
}
