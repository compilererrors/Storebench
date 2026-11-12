import StorebenchCore
import SwiftUI

/// The version that must be resolved before Apple can accept this local plan.
struct ReleaseCreationNotice: View {
    let snapshot: ReleaseReadinessSnapshot
    var body: some View {
        if let blocker = ReleaseCreation.blocker(snapshot) {
            Card(title: "Current Version at Apple", subtitle: blocker.detail) {
                StorebenchFact(label: "Version", value: blocker.version.name)
                StorebenchFact(label: "Status", value: blocker.version.state.isEmpty ? "Not Checked" : AppStoreNames.state(blocker.version.state), problem: !blocker.version.state.isEmpty)
                if let url = ReleaseCreation.versionURL(appId: snapshot.scope.appId, platform: blocker.version.platform) {
                    StorebenchFormFooter {
                        StorebenchActionLink("Open Version", destination: url, help: "Open this platform's current version in App Store Connect")
                            .storebenchControlID("release.current-version.open")
                    }
                }
            }.storebenchControlID("release.creation-blocked")
        }
    }
}
