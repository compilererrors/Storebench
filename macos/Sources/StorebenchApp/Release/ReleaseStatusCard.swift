import StorebenchCore
import SwiftUI

/// The planned version's release status per part and language, from the last check, with the step that opens each fix.
/// It only reads what is saved on this Mac; Release and Quick Release check App Store Connect again.
struct ReleaseStatusCard: View {
    let account: Account, app: Account.App, session: WorkspaceSession?
    @State private var summary: ReleaseStatusSummary?
    @Environment(\.editorNavigation) private var navigation

    var body: some View {
        Group {
            if let summary {
                Card(title: "Release Status for \(Releases.platformName(summary.platform)) \(summary.version)",
                     subtitle: "From the last check on this Mac. Release checks App Store Connect again when it opens; nothing here changes anything at Apple.", help: "release-material") {
                    StorebenchReadAge(readAt: summary.checkedAt, reading: false)
                    StorebenchTextSlot(text: summary.next.map { "Next: \($0.label). \($0.detail)" } ?? "Every part is verified or waiting for Apple.",
                                       height: 40, font: .sbCallout, color: StorebenchTheme.ink, live: true)
                    StorebenchCardList {
                        ForEach(Array(summary.versionParts.enumerated()), id: \.element.id) { index, part in
                            row(part.label, detail: part.detail, state: part.state, separator: index < summary.versionParts.count - 1 || !summary.languages.isEmpty) {
                                Button("Open Release") { navigation.open(.release, locale: nil) }.help("Open Release to work on \(part.label)")
                            }
                        }
                        ForEach(Array(summary.languages.enumerated()), id: \.element.id) { index, language in
                            row(StoreLocales.name(language.locale), detail: language.parts.map { "\($0.label): \($0.state.label)" }.joined(separator: " · "),
                                state: language.state, separator: index < summary.languages.count - 1) {
                                Button("Open Language") { navigation.open(.localizations, locale: language.locale) }.help("Open \(StoreLocales.name(language.locale)) in Localizations")
                            }
                        }
                    }
                }
            }
        }
        .task(id: "\(account.id)/\(app.id)") {
            guard let session else { return }
            summary = await session.releaseStatusSummary(accountId: account.id, appId: app.id)
        }
    }

    private func row(_ title: String, detail: String, state: ReleaseReadiness.State, separator: Bool, @ViewBuilder action: () -> some View) -> some View {
        let command = action()
        return StorebenchStatusRow(title: title, detail: detail, separator: separator) {
            StorebenchTextSlot(text: state.label, height: StorebenchTheme.controlHeight, font: .sbCaption.weight(.semibold),
                               color: state == .blocked ? StorebenchTheme.color("color-danger") : StorebenchTheme.muted, centered: true)
        } action: { command } details: { EmptyView() }
    }
}
