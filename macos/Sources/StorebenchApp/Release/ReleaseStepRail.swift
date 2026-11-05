import StorebenchCore
import SwiftUI

struct ReleaseStepRail: View {
    let guide: ReleaseGuide.Guide
    let selected: String
    let select: (String) -> Void
    /// The steps are drawn at once with their real names; until their status is known each says so beside a small spinner.
    var checking = false
    var body: some View {
        VStack(alignment: .leading, spacing: StorebenchTheme.space(1)) {
            Text("Release steps").font(.sbHeadline)
            Text(checking ? "Checking App Store Connect…" : "\(guide.completed) of \(guide.phases.count) complete").font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
                .padding(.bottom, StorebenchTheme.space(2))
            ForEach(guide.phases) { phase in item(phase) }
        }
        .padding(StorebenchTheme.space(3))
        .background(StorebenchTheme.color("color-surface"), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain).accessibilityLabel("Release steps, \(guide.completed) of \(guide.phases.count) complete")
    }
    private func item(_ item: ReleaseGuide.Phase) -> some View {
        let selected = item.id == self.selected, complete = !checking && (item.status == .done || item.status == .differs)
        let current = !checking && item.status == .current
        return Button { select(item.id) } label: {
            HStack(alignment: .top, spacing: StorebenchTheme.space(2)) {
                ZStack {
                    Circle().fill(StorebenchTheme.color(complete ? "color-success" : selected || current ? "color-accent" : "color-surface-accent-strong"))
                    if complete { StorebenchIcon(name: "check", size: 12).foregroundStyle(StorebenchTheme.color("color-on-accent")) }
                    else {
                        Text("\(item.number)").font(.sbCaption.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(StorebenchTheme.color(selected || current ? "color-on-accent" : "color-accent-muted"))
                    }
                }.frame(width: 24, height: 24).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.sbCallout.weight(selected ? .semibold : .regular)).fixedSize(horizontal: false, vertical: true)
                    if checking {
                        HStack(spacing: StorebenchTheme.space(1)) {
                            StorebenchActivityIcon(size: 11, active: true).foregroundStyle(StorebenchTheme.muted)
                            Text("Checking…").font(.sbCaption).foregroundStyle(StorebenchTheme.muted)
                        }
                    } else {
                        Text(item.label).font(.sbCaption).fixedSize(horizontal: false, vertical: true)
                            .foregroundStyle(current ? StorebenchTheme.color("color-accent-deep") : StorebenchTheme.muted)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, StorebenchTheme.space(2)).padding(.horizontal, StorebenchTheme.space(2))
            .background(selected ? StorebenchTheme.color("color-surface-accent-strong") : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(StorebenchPressStyle())
        .accessibilityLabel("Step \(item.number): \(item.title), \(checking ? "checking" : item.label)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
