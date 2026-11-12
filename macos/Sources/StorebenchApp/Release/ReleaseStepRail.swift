import StorebenchCore
import SwiftUI

struct ReleaseStepRail: View {
    let guide: ReleaseGuide.Guide
    let selected: String
    let select: (String) -> Void
    /// The steps are drawn at once with their real names; until their status is known each says Checking.
    var checking = false
    var body: some View {
        StorebenchStepRail(title: "Release steps", items: guide.phases.map { phase in
            StorebenchStepRail.Item(id: phase.id, number: phase.number, title: phase.title, label: checking ? "Checking…" : phase.label,
                                    complete: !checking && (phase.status == .done || phase.status == .differs), current: !checking && phase.status == .current)
        }, selected: selected, select: select, identifierPrefix: "release.step.")
    }
}
