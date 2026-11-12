import StorebenchCore
import SwiftUI

struct ReleaseMediaEditingGuide: View {
    let locale: String
    var busy = false
    var finish: (() -> Void)? = nil
    var body: some View {
        StorebenchEditorGuide(title: "App Previews and Screenshots · " + StoreLocales.name(locale),
            detail: "Add or arrange this language’s screenshots and previews below.",
            hint: finish == nil ? "Changes stay on this Mac. Sync to Apple opens a review before sending them."
                : "Done saves media on this Mac and returns to the release checklist. Sync to Apple opens a separate review.",
            identifier: "release.media-guide." + locale) {
            if let finish {
                StorebenchBusyButton(title: "Done", loadingTitle: "Saving…", busy: busy, action: finish)
                    .help("Save this language’s media and return to the release checklist. Nothing is sent to Apple.")
                    .storebenchControlID("release.media-done." + locale)
                    .storebenchWorking(busy)
            }
        }
    }
}
